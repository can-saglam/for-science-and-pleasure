import Foundation
import SwiftData

/// Two-way sync with the shared Supabase `items` table — the same one the
/// web app reads. SwiftData stays the source for the UI; this engine pushes
/// anything edited since the last sync and pulls everyone else's changes.
///
/// Conflict policy is last-write-wins by `updated_at`, and deletions travel
/// as the web's soft delete (`deleted_at`), so nothing is lost to races.
@MainActor
enum SupabaseSync {
    private static let cursorKey = "supabaseLastSyncAt"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
    }

    private static var lastSyncAt: Date {
        get { defaults.object(forKey: cursorKey) as? Date ?? .distantPast }
        set {
            defaults.set(newValue, forKey: cursorKey)
            SyncStatus.shared.lastSyncedAt = newValue
        }
    }

    static func resetCursor() {
        defaults.removeObject(forKey: cursorKey)
        SyncStatus.shared.lastSyncedAt = nil
    }

    // MARK: - Triggers

    private static var pending: Task<Void, Never>?
    private static var running = false

    /// Debounced sync — safe to call on every local save.
    static func schedule(context: ModelContext) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await sync(context: context)
        }
    }

    static func sync(context: ModelContext) async {
        guard SupabaseAuth.shared.signedIn, !running else { return }
        running = true
        SyncStatus.shared.syncing = true
        defer {
            running = false
            SyncStatus.shared.syncing = false
        }
        // The kill switch: an old build never gets as far as a push.
        guard await buildIsCurrent() else { return }
        do {
            let cursor = lastSyncAt
            var pushError: Error?
            if cursor == .distantPast {
                // First sync after sign-in: the server is canonical (it may
                // be newer than a seeded store), so pull before pushing
                // whatever only exists locally.
                try await pull(context: context)
                do { try await push(context: context, since: cursor) } catch { pushError = error }
            } else {
                // Push and pull fail independently: one stuck local row must
                // never block receiving the partner's saves.
                do { try await push(context: context, since: cursor) } catch { pushError = error }
                try await pull(context: context)
            }
            // Only a fully clean round advances the cursor — a failed push
            // leaves its dirty items behind it, retried on the next sync.
            if let pushError { throw pushError }
            lastSyncAt = .now
            SyncStatus.shared.problem = nil
        } catch {
            // Offline is routine and the next trigger retries — but keep
            // the reason visible in Settings instead of failing silently.
            SyncStatus.shared.problem = error.localizedDescription
        }
    }

    // MARK: - Kill switch

    /// This build's number, as App Store Connect counts it.
    static let buildNumber: Int =
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0

    private struct AppConfig: Decodable {
        var min_build: Int
        var store_url: String
    }

    /// Reads `app_config.min_build` and compares it to this build. Below it,
    /// the app flips to the update screen and this returns false — the
    /// caller must not touch the server. Fails *open*: if the row can't be
    /// fetched (offline, transient error) the sync proceeds as normal; the
    /// switch is for dormant clients waking up, not for a flaky connection.
    private static func buildIsCurrent() async -> Bool {
        do {
            var request = try await request(path: "rest/v1/app_config", query: [
                .init(name: "select", value: "min_build,store_url"),
                .init(name: "limit", value: "1"),
            ])
            request.httpMethod = "GET"
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let config = try JSONDecoder().decode([AppConfig].self, from: data).first
            else { return true }
            SyncStatus.shared.storeURL = URL(string: config.store_url)
            let current = buildNumber >= config.min_build
            SyncStatus.shared.updateRequired = !current
            return current
        } catch {
            return true
        }
    }

    // MARK: - Wire format

    private struct Row: Codable {
        var id: UUID
        var kind: String
        var status: String
        var title: String
        var summary: String?
        var venue: String?
        var area: String?
        var address: String?
        var category: String?
        var price: String?
        var url: String?
        var image_url: String?
        var starts_on: String?
        var ends_on: String?
        var notes: String?
        var color: String?
        var lat: Double?
        var lng: Double?
        var added_by_email: String?
        var created_at: Date
        var updated_at: Date
        var deleted_at: Date?
    }

    /// Postgres timestamps come back with fractional seconds; sometimes not.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            var s = try decoder.singleValueContainer().decode(String.self)
            // Postgres may emit microseconds; ISO8601DateFormatter only
            // reliably takes milliseconds. Trim the fraction to 3 digits.
            if let range = s.range(of: #"\.\d{4,}"#, options: .regularExpression) {
                s = s.replacingCharacters(in: range, with: String(s[range].prefix(4)))
            }
            if let date = isoFractional.date(from: s) ?? isoPlain.date(from: s) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unparseable date: \(s)"
            ))
        }
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFractional.string(from: date))
        }
        return e
    }

    private static func request(path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        let token = try await SupabaseAuth.shared.validToken()
        var components = URLComponents(
            url: SupabaseAuth.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Push

    private static func push(context: ModelContext, since cursor: Date) async throws {
        let locals = try context.fetch(FetchDescriptor<Item>())
        let dirty = locals.filter { $0.updatedAt > cursor }
        guard !dirty.isEmpty else { return }
        try await upsert(rows: dirty.map(row(from:)))
    }

    private static func upsert(rows: [Row]) async throws {
        var request = try await request(path: "rest/v1/items")
        request.httpMethod = "POST"
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try encoder.encode(rows)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SupabaseAuth.AuthError(
                message: "Push failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")"
            )
        }
    }

    // MARK: - Partner notification

    /// A brand-new save: put it on the server right away, then ask
    /// notify-save to ping the other member's devices (never our own).
    static func announceSave(_ item: Item) async {
        guard SupabaseAuth.shared.signedIn, !SyncStatus.shared.updateRequired else { return }
        do {
            try await upsert(rows: [row(from: item)])
            var request = try await request(path: "functions/v1/notify-save")
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "item_id": item.id.uuidString.lowercased(),
            ])
            _ = try await URLSession.shared.data(for: request)
        } catch {
            // The regular sync still carries the item; only the ping is lost.
        }
    }

    private static func row(from item: Item) -> Row {
        Row(
            id: item.id,
            kind: item.kind,
            status: item.status,
            title: item.title,
            summary: item.summary,
            venue: item.venue,
            area: item.area,
            address: item.address,
            category: item.category,
            price: item.price,
            url: item.url,
            image_url: item.imageUrl,
            starts_on: item.startsOn,
            ends_on: item.endsOn,
            notes: item.notes,
            color: item.colorHex,
            lat: item.lat,
            lng: item.lng,
            added_by_email: item.addedByEmail ?? SupabaseAuth.shared.email,
            created_at: item.createdAt,
            updated_at: item.updatedAt,
            deleted_at: nil
        )
    }

    // MARK: - Pull

    private static func pull(context: ModelContext) async throws {
        // The whole table, soft-deleted rows included, so removals propagate.
        // Fine at this scale (two people's saves).
        var request = try await request(path: "rest/v1/items", query: [
            .init(name: "select", value: "*"),
            .init(name: "order", value: "updated_at.asc"),
        ])
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SupabaseAuth.AuthError(message: "Pull failed.")
        }
        // Row-by-row tolerance: one malformed row (an odd date, a null in a
        // required field) must not poison the entire pull for everyone.
        struct Lenient: Decodable {
            let row: Row?
            init(from decoder: Decoder) { row = try? Row(from: decoder) }
        }
        let rows = try decoder.decode([Lenient].self, from: data).compactMap(\.row)

        let locals = try context.fetch(FetchDescriptor<Item>())
        let byID = Dictionary(locals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for row in rows {
            if row.deleted_at != nil {
                if let local = byID[row.id] { context.delete(local) }
                continue
            }
            if let local = byID[row.id] {
                if row.updated_at > local.updatedAt {
                    apply(row, to: local)
                }
            } else {
                let item = Item()
                apply(row, to: item)
                context.insert(item)
            }
        }
        if context.hasChanges { try context.save() }
    }

    private static func apply(_ row: Row, to item: Item) {
        item.id = row.id
        item.kind = row.kind
        item.status = row.status
        item.title = row.title
        item.summary = row.summary
        item.venue = row.venue
        item.area = row.area
        item.address = row.address
        item.category = row.category
        item.price = row.price
        item.url = row.url
        item.imageUrl = row.image_url
        item.startsOn = row.starts_on
        item.endsOn = row.ends_on
        item.notes = row.notes
        item.colorHex = row.color
        item.lat = row.lat
        item.lng = row.lng
        item.addedByEmail = row.added_by_email
        item.createdAt = row.created_at
        item.updatedAt = row.updated_at
    }

    // MARK: - Column patches

    /// Writes just the given columns of one row. This is how machine-derived
    /// data (a backfilled thumbnail) and fill-only enrichment reach the
    /// server: a full-row push would carry every other field as this phone
    /// last saw it and could overwrite a partner's fresher edit. Values are
    /// JSON-ready (String, Double, NSNull). Returns whether the write landed.
    @discardableResult
    static func patch(_ id: UUID, _ fields: [String: Any]) async -> Bool {
        guard SupabaseAuth.shared.signedIn, !SyncStatus.shared.updateRequired else { return false }
        do {
            var request = try await request(
                path: "rest/v1/items",
                query: [.init(name: "id", value: "eq.\(id.uuidString.lowercased())")]
            )
            request.httpMethod = "PATCH"
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
            let (_, response) = try await URLSession.shared.data(for: request)
            return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return false
        }
    }

    /// Column patch with a safety net for edits that must reach the partner:
    /// if it can't land now (offline, signed out), the item is stamped so
    /// the next regular sync carries the change as a full row instead.
    static func patchOrSync(_ item: Item, _ fields: [String: Any], context: ModelContext) async {
        let landed = await patch(item.id, fields)
        if !landed {
            item.updatedAt = .now
            try? context.save()
        }
    }

    // MARK: - Deletes

    /// Mirrors the web's soft delete; `undelete` covers the 5-second Undo.
    static func setDeleted(_ id: UUID, _ deleted: Bool) {
        let stamp: Any = deleted ? isoFractional.string(from: .now) : NSNull()
        Task { await patch(id, ["deleted_at": stamp]) }
    }
}
