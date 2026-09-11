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

    /// Back to "never synced" — on sign-out, and before a library swap. The
    /// status the last account left behind goes with it.
    static func resetCursor() {
        defaults.removeObject(forKey: cursorKey)
        SyncStatus.shared.lastSyncedAt = nil
        SyncStatus.shared.problem = nil
        SyncStatus.shared.librarySwappedTo = nil
        SyncStatus.shared.staleBannerDismissedAt = nil
    }

    // MARK: - Library ownership
    //
    // The local store belongs to whichever account and group last pulled
    // it (`GroupStore.libraryGroupId` / `libraryUserId`). When that no
    // longer matches the signed-in account — a membership change, or a
    // different person signing in on this phone — the engine replaces the
    // library: wipe, full pull, then rebuild everything derived from it
    // (Spotlight, the widget, the share extension's URL index) so the
    // old group's saves stop surfacing anywhere.
    // Nothing outside this file ever deletes the store.

    /// Pushes this account's unsynced edits now. Returns false if any are
    /// still stuck — the caller should not leave a group with edits that
    /// would be refused once the membership has moved.
    static func flush(context: ModelContext) async -> Bool {
        guard SupabaseAuth.shared.signedIn, !SyncStatus.shared.updateRequired else { return false }
        while running { try? await Task.sleep(for: .milliseconds(100)) }
        do {
            // A cursor at the epoch (signed out and back in) means every
            // row counts as unsynced; the server ignores what it already has.
            try await push(context: context, since: lastSyncAt)
            return rejected.isEmpty
        } catch {
            SyncStatus.shared.problem = SyncProblem(error)
            return false
        }
    }

    /// Runs a sync that replaces the library whatever the ownership record
    /// says (the caller knows the membership just moved), without the
    /// mid-session notice (it has its own words for what happened).
    /// Returns whether the new library actually arrived.
    static func replaceLibrary(context: ModelContext) async -> Bool {
        while running { try? await Task.sleep(for: .milliseconds(100)) }
        swapQuietly = true
        forceSwap = true
        await sync(context: context)
        swapQuietly = false
        forceSwap = false
        let group = GroupStore.shared
        return SyncStatus.shared.problem == nil
            && group.card != nil && group.libraryGroupId == group.card?.groupId
    }

    private static var swapQuietly = false
    private static var forceSwap = false

    /// Before a library is wiped, whatever this person changed in it and
    /// hasn't synced yet gets one push. Rows that were theirs to edit land;
    /// rows the server refuses (403: a group they've since left) are set
    /// aside and go with the wipe. Only network trouble stops the swap —
    /// the wipe waits for a moment when nothing can be lost.
    private static func salvage(context: ModelContext) async throws {
        let me = SupabaseAuth.shared.userId
        let email = SupabaseAuth.shared.email
        let locals = try context.fetch(FetchDescriptor<Item>())
        let mine = locals.filter { item in
            guard !isQuarantined(item) else { return false }
            if let me, item.createdBy == me || item.updatedBy == me { return true }
            // Saves made before the app stamped ids, or offline before the
            // first pull: the email is the only attribution they carry.
            return item.createdBy == nil && item.addedByEmail != nil && item.addedByEmail == email
        }
        guard !mine.isEmpty else { return }
        do {
            try await upsert(rows: mine.map(row(from:)))
        } catch let error as SyncProblem where error.rowRejected {
            for item in mine {
                do { try await upsert(rows: [row(from: item)]) } catch let e as SyncProblem where e.rowRejected {
                    continue
                }
            }
        }
    }

    private static func hasLocals(context: ModelContext) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<Item>())) ?? 0) > 0
    }

    private static func wipeLocals(context: ModelContext) {
        let locals = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        for item in locals { context.delete(item) }
        if context.hasChanges { try? context.save() }
        defaults.removeObject(forKey: rejectedKey)
        UndoBin.shared.clearAll()
    }

    /// Everything that mirrors the library, rebuilt from the store.
    private static func rebuildDerived(context: ModelContext) async {
        let fresh = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        SavedURLIndex.rebuild(from: fresh)
        SpotlightIndex.sync(items: fresh)
        WidgetStore.sync(items: fresh)
        await MembersStore.shared.refresh()
        await HomeStore.shared.refresh()
    }

    // MARK: - Triggers

    private static var debounce: Task<Void, Never>?
    private static var running = false
    /// A sync was asked for while one was running: run again when it ends,
    /// so an edit made mid-sync (or a membership change spotted mid-sync)
    /// is never dropped.
    private static var rerun = false

    /// Debounced sync — safe to call on every local save. The debounce is
    /// only the wait; the sync itself runs in its own task, so a later
    /// save cancelling the wait can never cancel a request in flight.
    static func schedule(context: ModelContext) {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            Task { await sync(context: context) }
        }
    }

    static func sync(context: ModelContext) async {
        guard SupabaseAuth.shared.signedIn else { return }
        if running { rerun = true; return }
        running = true
        SyncStatus.shared.syncing = true
        defer {
            running = false
            SyncStatus.shared.syncing = false
            if rerun {
                rerun = false
                Task { await sync(context: context) }
            }
        }
        // The kill switch: an old build never gets as far as a push.
        guard await buildIsCurrent() else { return }
        do {
            let cursor = lastSyncAt
            let fresh = cursor == .distantPast
            let group = GroupStore.shared
            // A session's first sync learns the group before anything else;
            // later syncs rely on the card ContentView refreshes on every
            // foreground.
            if fresh { await group.refresh() }
            // Whose library is this? Another account's, another group's, or
            // — a store from before ownership was tracked (which may hold
            // anything, including the iCloud-era duplicates) — nobody's. In
            // each case it goes before the pull, so nothing of theirs is
            // shown as ours or pushed as ours.
            let untracked = group.libraryGroupId == nil && hasLocals(context: context)
            let foreign = forceSwap || group.libraryIsForeign || untracked
            if fresh || foreign {
                // Ownership is only ever recorded against a known group.
                guard group.card != nil else {
                    throw SyncProblem(message: "Couldn\u{2019}t load your group. Try again in a moment.")
                }
            }
            if foreign {
                // This person's own unsynced edits first — then the wipe.
                try await salvage(context: context)
                if !fresh {
                    // Give any open item sheet a moment to close.
                    NotificationCenter.default.post(name: .cwgLibraryWillSwap, object: nil)
                    try? await Task.sleep(for: .milliseconds(350))
                }
                wipeLocals(context: context)
                resetCursor()
            }

            var pushError: Error?
            if fresh || foreign {
                // The server is canonical (it may be newer than a seeded
                // store), so pull before pushing whatever only exists locally.
                try await pull(context: context)
                // Worth a word only when it's the same person whose group
                // changed under them; a different account signing in, or a
                // store nobody had claimed, is simply shown its own library.
                let sameAccount = group.libraryUserId != nil && group.libraryUserId == SupabaseAuth.shared.userId
                group.libraryReplaced()
                if foreign, !untracked, sameAccount, !swapQuietly {
                    SyncStatus.shared.librarySwappedTo = group.card?.name
                }
                // After a wipe nothing local can be ahead of the server.
                if !foreign {
                    do { try await push(context: context, since: cursor) } catch { pushError = error }
                }
            } else {
                // Push and pull fail independently: one stuck local row must
                // never block receiving the partner's saves.
                do { try await push(context: context, since: cursor) } catch { pushError = error }
                try await pull(context: context)
                // An empty store nobody had claimed is this account's now.
                if group.libraryGroupId == nil, group.card != nil { group.libraryReplaced() }
            }
            // Only a fully clean round advances the cursor — a failed push
            // leaves its dirty items behind it, retried on the next sync.
            if let pushError { throw pushError }
            lastSyncAt = .now
            // A row the server refused on its own merits is set aside
            // (see `upsert`) so it can't hold everything else hostage — but
            // it stays visible in Settings until the item is edited again.
            SyncStatus.shared.problem = quarantineProblem(context: context)
            if foreign { await rebuildDerived(context: context) }
        } catch {
            // Offline is routine and the next trigger retries — but keep
            // the reason visible instead of failing silently.
            SyncStatus.shared.problem = SyncProblem(error)
        }
    }

    // MARK: - Quarantine

    /// Rows the server rejected individually, keyed by item id, valued by
    /// the `updatedAt` that was refused. A later edit changes the stamp and
    /// the row is tried again; until then it's skipped so the cursor can
    /// advance and everyone else's saves keep flowing.
    private static let rejectedKey = "supabaseRejectedRows"
    private static var rejected: [String: Date] {
        get { defaults.dictionary(forKey: rejectedKey) as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: rejectedKey) }
    }

    private static func isQuarantined(_ item: Item) -> Bool {
        rejected[item.id.uuidString] == item.updatedAt
    }

    private static func quarantineProblem(context: ModelContext) -> SyncProblem? {
        guard !rejected.isEmpty else { return nil }
        let locals = try? context.fetch(FetchDescriptor<Item>())
        let stuck = (locals ?? []).filter(isQuarantined)
        // Rows that were edited (or deleted) since drop out of the record.
        if stuck.count != rejected.count {
            rejected = Dictionary(uniqueKeysWithValues: stuck.map { ($0.id.uuidString, $0.updatedAt) })
        }
        guard let first = stuck.first else { return nil }
        let title = first.title.isEmpty ? "One save" : "“\(first.title)”"
        let more = stuck.count > 1 ? " and \(stuck.count - 1) more" : ""
        return SyncProblem(
            message: "\(title)\(more) couldn't be synced. Editing it will retry.",
            detail: rejectedDetail
        )
    }
    private static var rejectedDetail: String?

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
        var reminder_offset_days: Int?
        var reminder_anchor: String?
        var remind_at: String?
        var notes: String?
        var color: String?
        var lat: Double?
        var lng: Double?
        var added_by_email: String?
        var group_id: UUID?
        var updated_by: UUID?
        var created_by: UUID?
        var created_at: Date
        var updated_at: Date
        var deleted_at: Date?

        /// PostgREST insists every object in a bulk upsert has the *same*
        /// keys ("All object keys must match"). The synthesised encoder
        /// drops nil optionals, so two rows with different empty fields —
        /// one with notes, one without — made the whole batch a 400 while
        /// single-row pushes sailed through. Write every column, nulls
        /// included, so the shape is identical for every row.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encode(status, forKey: .status)
            try c.encode(title, forKey: .title)
            try c.encode(summary, forKey: .summary)
            try c.encode(venue, forKey: .venue)
            try c.encode(area, forKey: .area)
            try c.encode(address, forKey: .address)
            try c.encode(category, forKey: .category)
            try c.encode(price, forKey: .price)
            try c.encode(url, forKey: .url)
            try c.encode(image_url, forKey: .image_url)
            try c.encode(starts_on, forKey: .starts_on)
            try c.encode(ends_on, forKey: .ends_on)
            try c.encode(reminder_offset_days, forKey: .reminder_offset_days)
            try c.encode(reminder_anchor, forKey: .reminder_anchor)
            try c.encode(remind_at, forKey: .remind_at)
            try c.encode(notes, forKey: .notes)
            try c.encode(color, forKey: .color)
            try c.encode(lat, forKey: .lat)
            try c.encode(lng, forKey: .lng)
            try c.encode(added_by_email, forKey: .added_by_email)
            try c.encode(group_id, forKey: .group_id)
            try c.encode(updated_by, forKey: .updated_by)
            try c.encode(created_by, forKey: .created_by)
            try c.encode(created_at, forKey: .created_at)
            try c.encode(updated_at, forKey: .updated_at)
            try c.encode(deleted_at, forKey: .deleted_at)
        }
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
        let dirty = locals.filter { $0.updatedAt > cursor && !isQuarantined($0) }
        guard !dirty.isEmpty else { return }
        do {
            try await upsert(rows: dirty.map(row(from:)))
        } catch let error as SyncProblem where error.rowRejected && dirty.count > 1 {
            // The server rejected the batch. Find out which row: push them
            // one at a time so the good ones land now and only the culprit
            // is set aside. Network trouble (no status) isn't isolated —
            // that's just retried whole next time.
            var refused: [(Item, SyncProblem)] = []
            for item in dirty {
                do { try await upsert(rows: [row(from: item)]) } catch let e as SyncProblem where e.rowRejected {
                    refused.append((item, e))
                }
            }
            guard !refused.isEmpty else { return }
            quarantine(refused)
        } catch let error as SyncProblem where error.rowRejected {
            quarantine(dirty.map { ($0, error) })
        }
    }

    private static func quarantine(_ refused: [(Item, SyncProblem)]) {
        var record = rejected
        for (item, _) in refused { record[item.id.uuidString] = item.updatedAt }
        rejected = record
        rejectedDetail = refused.first?.1.detail
    }

    private static func upsert(rows: [Row]) async throws {
        var request = try await request(path: "rest/v1/items")
        request.httpMethod = "POST"
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try encoder.encode(rows)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SyncProblem(
                message: "Changes on this phone haven't reached the server yet.",
                detail: "Push failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")",
                status: status
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
            reminder_offset_days: item.reminderOffsetDays,
            reminder_anchor: item.reminderAnchor,
            remind_at: item.remindAt,
            notes: item.notes,
            color: item.colorHex,
            lat: item.lat,
            lng: item.lng,
            added_by_email: item.addedByEmail ?? SupabaseAuth.shared.email,
            group_id: item.groupId,
            updated_by: item.updatedBy,
            created_by: item.createdBy,
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw SyncProblem(
                message: "Couldn't fetch the latest saves.",
                detail: "Pull failed (\(status)): \(String(data: data.prefix(300), encoding: .utf8) ?? "")",
                status: status
            )
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
        item.reminderOffsetDays = row.reminder_offset_days
        item.reminderAnchor = row.reminder_anchor
        item.remindAt = row.remind_at
        item.notes = row.notes
        item.colorHex = row.color
        item.lat = row.lat
        item.lng = row.lng
        item.addedByEmail = row.added_by_email
        item.groupId = row.group_id
        item.updatedBy = row.updated_by
        item.createdBy = row.created_by
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
