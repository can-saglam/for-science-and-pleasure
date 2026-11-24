import Foundation
import SwiftData

/// Two-way sync with the shared Supabase `items` table — the same one the
/// web app reads. SwiftData stays the source for the UI; this engine pushes
/// anything edited since the last sync and pulls everyone else's changes.
///
/// Conflicts are settled column by column (`RowMerge`): the phone remembers
/// each save as the server last had it, sends only the columns it changed,
/// and a pull keeps its unsent edits over the server's copy. A save with no
/// such memory yet falls back to last-write-wins by `updated_at`. Deletions
/// travel as the web's soft delete (`deleted_at`), so nothing is lost to
/// races.
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
        defaults.removeObject(forKey: pullCursorKey)
        defaults.removeObject(forKey: fullPullKey)
        bases = [:]
        saveBases()
        SyncStatus.shared.lastSyncedAt = nil
        SyncStatus.shared.problem = nil
        SyncStatus.shared.librarySwappedTo = nil
        SyncStatus.shared.staleBannerDismissedAt = nil
    }

    // MARK: - Bases

    /// Each save as the server last had it, as this phone saw it, in the
    /// phone's own form (`localForm`). In a file of its own rather than the
    /// store: losing it only means a round of whole-row last-write-wins.
    private static let basesURL = URL.applicationSupportDirectory.appending(path: "sync-bases.json")
    private static var bases: [UUID: Fields] = loadBases()

    private static func loadBases() -> [UUID: Fields] {
        guard let data = try? Data(contentsOf: basesURL),
              let raw = try? JSONDecoder().decode([String: Fields].self, from: data)
        else { return [:] }
        return Dictionary(raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }) { a, _ in a }
    }

    private static func saveBases() {
        let raw = Dictionary(bases.map { ($0.key.uuidString, $0.value) }) { a, _ in a }
        do {
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(raw).write(to: basesURL, options: .atomic)
        } catch {
            print("[sync] couldn't save bases: \(error)")
        }
    }

    /// A row as columns, in the wire format.
    private static func fields(_ row: Row) -> Fields {
        (try? JSONDecoder().decode(Fields.self, from: encoder.encode(row))) ?? [:]
    }

    /// The server's row as this phone would hold it: through `apply` and
    /// back, so times, showings and defaults compare like for like with an
    /// item's own columns.
    private static func localForm(_ row: Row) -> Fields {
        let scratch = Item()
        apply(row, to: scratch)
        return fields(self.row(from: scratch))
    }

    private static func row(_ fields: Fields) -> Row? {
        guard let data = try? JSONEncoder().encode(fields) else { return nil }
        return try? decoder.decode(Row.self, from: data)
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
        guard SupabaseAuth.shared.signedIn, !SyncStatus.shared.updateRequired, !StandInStore.active else {
            return false
        }
        while running, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
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

    /// Sign-out's last chance for this account's unsynced edits: once
    /// another account signs in here, the store is replaced. A few seconds
    /// at most, so the button never hangs on a bad connection. False when
    /// something may not have landed, so sign-out can say so first.
    static func flushBeforeSignOut(context: ModelContext) async -> Bool {
        let flushing = Task { await flush(context: context) }
        let limit = Task {
            try? await Task.sleep(for: .seconds(6))
            flushing.cancel()
        }
        let landed = await flushing.value
        limit.cancel()
        return landed
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
    /// rows for a group they've since left (403) go with the wipe; any other
    /// refused row is written to a file first. Network trouble, or every
    /// row refused, stops the swap: the wipe waits for a moment when
    /// nothing can be lost.
    private static func salvage(context: ModelContext) async throws {
        let me = SupabaseAuth.shared.userId
        let email = SupabaseAuth.shared.email
        // Sign-out resets the cursor, so after another account's session
        // every row looks unsynced. Those are the last person's, not this
        // one's to push into their own group.
        let owner = GroupStore.shared.libraryUserId
        let sameAccount = owner == nil || owner == me
        let locals = try context.fetch(FetchDescriptor<Item>())
        let mine = locals.filter { item in
            guard !isQuarantined(item) else { return false }
            if let me, item.createdBy == me || item.updatedBy == me { return true }
            if sameAccount, item.updatedAt > lastSyncAt { return true }
            if sameAccount, case .columns = pending(item, since: lastSyncAt) { return true }
            // Saves made before the app stamped ids, or offline before the
            // first pull: the email is the only attribution they carry.
            return item.createdBy == nil && item.addedByEmail != nil && item.addedByEmail == email
        }
        guard !mine.isEmpty else { return }
        var refused: [Row] = []
        do {
            try await upsert(rows: mine.map(row(from:)))
        } catch let error as SyncProblem where error.rowRejected {
            for item in mine {
                do { try await upsert(rows: [row(from: item)]) } catch let e as SyncProblem where e.rowRejected {
                    // 403 is a library they've left: not theirs to keep.
                    if e.status != 403 { refused.append(row(from: item)) }
                }
            }
        }
        guard !refused.isEmpty else { return }
        // Refused as a whole is the server, not the rows: hold the swap.
        if refused.count == mine.count {
            throw SyncProblem(message: "Couldn\u{2019}t save your latest changes. Try again in a moment.")
        }
        keepAside(refused)
    }

    /// Edits the server wouldn't take, written out before a wipe so they
    /// can still be recovered by hand (Application Support/Set aside).
    private static func keepAside(_ rows: [Row]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let folder = URL.applicationSupportDirectory.appending(path: "Set aside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "\(Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).json"
            try encoder.encode(rows).write(to: folder.appending(path: name), options: .atomic)
        } catch {
            print("[sync] couldn't set aside \(rows.count) refused edit(s): \(error)")
        }
    }

    private static func hasLocals(context: ModelContext) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<Item>())) ?? 0) > 0
    }

    /// Empties the local library (account deletion, or a successful swap).
    static func wipeLocalLibrary(context: ModelContext) {
        wipeLocals(context: context)
        resetCursor()
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

    /// Saves the pull made whose notices haven't arrived yet. What a pull
    /// writes is already the server's, so it needs no sync of its own.
    private static var pullSaves = 0

    /// For each `ModelContext.didSave`: schedules a sync unless the save
    /// was the pull's own. Notices arrive in order, so the count holds
    /// even when a person's edit lands while one is in flight.
    static func saved(context: ModelContext) {
        if pullSaves > 0 {
            pullSaves -= 1
            return
        }
        schedule(context: context)
    }

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
        guard SupabaseAuth.shared.signedIn, !StandInStore.active else { return }
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
            // The next cursor. Taken before anything is read, so an edit
            // stamped while this round is in flight is still ahead of it.
            let started = Date.now
            let fresh = cursor == .distantPast
            let group = GroupStore.shared
            guard await group.refresh() else {
                throw SyncProblem(message: "Couldn\u{2019}t load your group. Try again in a moment.")
            }
            // Whose library is this? Another account's, another group's, or
            // — a store from before ownership was tracked (which may hold
            // anything, including the iCloud-era duplicates) — nobody's. In
            // each case it goes before the pull, so nothing of theirs is
            // shown as ours or pushed as ours.
            let locals = (try? context.fetch(FetchDescriptor<Item>())) ?? []
            let otherGroup = group.card.map { gid in
                locals.contains { $0.groupId != nil && $0.groupId != gid.groupId }
                    && !locals.contains { $0.groupId == gid.groupId || $0.groupId == nil }
            } ?? false
            let untracked = group.libraryGroupId == nil && hasLocals(context: context)
            let foreign = forceSwap || group.libraryIsForeign || untracked || otherGroup
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
                let serverTimes = try await pull(context: context)
                // Worth a word only when it's the same person whose group
                // changed under them; a different account signing in, or a
                // store nobody had claimed, is simply shown its own library.
                let sameAccount = group.libraryUserId != nil && group.libraryUserId == SupabaseAuth.shared.userId
                group.libraryReplaced()
                if foreign, !untracked, sameAccount, !swapQuietly {
                    SyncStatus.shared.librarySwappedTo = group.card?.name
                }
                // After a wipe nothing local can be ahead of the server.
                // After a fresh cursor, only rows newer than the snapshot.
                if !foreign {
                    do { try await push(context: context, since: cursor, serverTimes: serverTimes) } catch { pushError = error }
                }
            } else {
                // Push first, so what this phone changed is on the server
                // before the pull. A pull still keeps unsent edits.
                do { try await push(context: context, since: cursor) } catch { pushError = error }
                _ = try await pull(context: context, full: fullPullDue)
                // An empty store nobody had claimed is this account's now.
                if group.libraryGroupId == nil, group.card != nil { group.libraryReplaced() }
            }
            // Only a fully clean round advances the cursor — a failed push
            // leaves its dirty items behind it, retried on the next sync.
            if let pushError { throw pushError }
            lastSyncAt = started
            // A row the server refused on its own merits is set aside
            // (see `upsert`) so it can't hold everything else hostage — but
            // it stays visible in Settings until the item is edited again.
            let problem = quarantineProblem(context: context)
            if SyncStatus.shared.problem != problem { SyncStatus.shared.problem = problem }
            if foreign { await rebuildDerived(context: context) }
        } catch {
            // Offline is routine and the next trigger retries — but keep
            // the reason visible instead of failing silently.
            let problem = SyncProblem(error)
            if SyncStatus.shared.problem != problem { SyncStatus.shared.problem = problem }
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

    /// Local edits the server hasn't seen yet: what the next push would
    /// carry. For Settings, so "synced 2 minutes ago" can also say whether
    /// anything is still waiting to leave this phone.
    @MainActor
    static func pendingCount(context: ModelContext) -> Int {
        guard SupabaseAuth.shared.signedIn,
              let locals = try? context.fetch(FetchDescriptor<Item>()) else { return 0 }
        let cursor = lastSyncAt
        return locals.filter { item in
            guard !isQuarantined(item) else { return false }
            if case .clean = pending(item, since: cursor) { return false }
            return true
        }.count
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
        // The category cap trigger: someone else took the last slot first.
        if rejectedDetail?.contains("category_full") == true, let category = first.category {
            return SyncProblem(
                message: "\(title)\(more) is only on this phone: \(CategoryCap.plural(category)) is full on the free plan. Plus removes the limit.",
                detail: rejectedDetail
            )
        }
        // The daily add trigger: another phone of theirs added the last one.
        if rejectedDetail?.contains("daily_full") == true {
            return SyncProblem(
                message: "\(title)\(more) is only on this phone for now: that\u{2019}s as many new things as you can add in a day. It\u{2019}ll sync tomorrow.",
                detail: rejectedDetail
            )
        }
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

    private static var configCheckedAt: Date?

    private struct AppConfig: Decodable {
        var min_build: Int
        var store_url: String?
    }

    /// Reads `app_config.min_build` and compares it to this build. Below it,
    /// the app flips to the update screen and this returns false — the
    /// caller must not touch the server. Fails *open*: if the row can't be
    /// fetched (offline, transient error) the sync proceeds as normal; the
    /// switch is for dormant clients waking up, not for a flaky connection.
    private static func buildIsCurrent() async -> Bool {
        // Checked once per launch, then every six hours: not a request
        // ahead of every sync.
        if let at = configCheckedAt, Date.now.timeIntervalSince(at) < 6 * 3600, !SyncStatus.shared.updateRequired {
            return true
        }
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
            let raw = config.store_url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let store = raw.isEmpty || raw.hasPrefix("itms") ? nil : URL(string: raw)
            if SyncStatus.shared.storeURL != store { SyncStatus.shared.storeURL = store }
            let current = buildNumber >= config.min_build
            if SyncStatus.shared.updateRequired == current { SyncStatus.shared.updateRequired = !current }
            configCheckedAt = .now
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
        var remind_time: String?
        var plan_on: String?
        var plan_time: String?
        var planned_by: UUID?
        var went_on: String?
        var notes: String?
        var color: String?
        var source: String?
        var lat: Double?
        var lng: Double?
        var place_id: String?
        var showings: ShowingsColumn?
        var added_by_email: String?
        var group_id: UUID?
        var updated_by: UUID?
        var created_by: UUID?
        var created_at: Date
        var updated_at: Date
        var deleted_at: Date?
        /// Read, never written: the server's own clock of the row's last
        /// write of any kind (0056), for pulling only what changed.
        var touched_at: Date?

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
            try c.encode(remind_time, forKey: .remind_time)
            try c.encode(plan_on, forKey: .plan_on)
            try c.encode(plan_time, forKey: .plan_time)
            // The server stamps who planned it from the login (0042).
            try c.encode(planned_by, forKey: .planned_by)
            try c.encode(went_on, forKey: .went_on)
            try c.encode(notes, forKey: .notes)
            try c.encode(color, forKey: .color)
            // `source` is NOT NULL on the server; rows from before the
            // field existed are by definition the old default.
            try c.encode(source ?? "manual", forKey: .source)
            try c.encode(lat, forKey: .lat)
            try c.encode(lng, forKey: .lng)
            // Null never clears the server's (0041): only moving the save does.
            try c.encode(place_id, forKey: .place_id)
            // Nor does it clear showings (0044).
            try c.encode(showings, forKey: .showings)
            // added_by_email is read, never written: the server keeps no email (0053).
            try c.encode(group_id, forKey: .group_id)
            try c.encode(updated_by, forKey: .updated_by)
            try c.encode(created_by, forKey: .created_by)
            try c.encode(created_at, forKey: .created_at)
            try c.encode(updated_at, forKey: .updated_at)
            try c.encode(deleted_at, forKey: .deleted_at)
        }
    }

    /// `items.showings`, read leniently: a list this build can't read is no
    /// list, never a failed pull.
    private struct ShowingsColumn: Codable {
        let list: [Showing]

        init(_ list: [Showing]) { self.list = list }

        init(from decoder: Decoder) throws {
            list = (try? decoder.singleValueContainer().decode([Showing].self)) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(list)
        }
    }

    /// Postgres timestamps come back with fractional seconds; sometimes not.
    /// ISO8601DateFormatter is thread-safe; the pull decodes off the main actor.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    nonisolated private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = trimmedFraction(try decoder.singleValueContainer().decode(String.self))
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

    /// Postgres may emit microseconds; ISO8601DateFormatter only reliably
    /// takes milliseconds. Cuts the fraction to 3 digits.
    nonisolated private static func trimmedFraction(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        let digitsStart = s.index(after: dot)
        let digitsEnd = s[digitsStart...].firstIndex { !$0.isASCII || !$0.isNumber } ?? s.endIndex
        guard s.distance(from: digitsStart, to: digitsEnd) > 3 else { return s }
        let keep = s.index(digitsStart, offsetBy: 3)
        return String(s[..<keep]) + s[digitsEnd...]
    }

    private struct LenientRow: Decodable {
        let row: Row?
        /// Even a row that doesn't decode is still on the server.
        let id: UUID?
        private enum Key: CodingKey { case id }
        init(from decoder: Decoder) {
            row = try? Row(from: decoder)
            id = try? decoder.container(keyedBy: Key.self).decode(UUID.self, forKey: .id)
        }
    }

    /// One pull page, decoded off the main actor. `served` counts every row
    /// the server sent, including any that didn't decode, for paging; `ids`
    /// is nil when one came without a readable id.
    nonisolated private static func decodePage(_ data: Data) throws -> (rows: [Row], served: Int, ids: [UUID]?) {
        let page = try decoder.decode([LenientRow].self, from: data)
        let ids = page.compactMap(\.id)
        return (page.compactMap(\.row), page.count, ids.count == page.count ? ids : nil)
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

    /// What of a save hasn't reached the server: the columns changed since
    /// its base, or, with no base, the whole row when it's newer than what
    /// the server had (or than the cursor).
    private enum Pending {
        case clean
        case columns(Fields)
        case whole
    }

    private static func pending(_ item: Item, since cursor: Date, serverTimes: [UUID: Date] = [:]) -> Pending {
        if let base = bases[item.id] {
            let changes = RowMerge.changes(base: base, local: fields(row(from: item)))
            return changes.isEmpty ? .clean : .columns(changes)
        }
        if let server = serverTimes[item.id] { return item.updatedAt > server ? .whole : .clean }
        return item.updatedAt > cursor ? .whole : .clean
    }

    private static func push(
        context: ModelContext, since cursor: Date, serverTimes: [UUID: Date] = [:]
    ) async throws {
        releaseDailyRefusals()
        releaseStaleRefusals()
        let locals = try context.fetch(FetchDescriptor<Item>())
        var whole: [Item] = []
        var columns: [(Item, Fields)] = []
        for item in locals where !isQuarantined(item) {
            switch pending(item, since: cursor, serverTimes: serverTimes) {
            case .clean: break
            case .whole: whole.append(item)
            case .columns(let changes): columns.append((item, changes))
            }
        }
        guard !whole.isEmpty || !columns.isEmpty else { return }
        defer { saveBases() }
        var refused: [(Item, SyncProblem)] = []
        if !whole.isEmpty {
            do {
                try await upsert(rows: whole.map(row(from:)))
                for item in whole { landedWhole(item) }
            } catch let error as SyncProblem where error.rowRejected && whole.count > 1 {
                // The server rejected the batch. Find out which row: push them
                // one at a time so the good ones land now and only the culprit
                // is set aside. Network trouble (no status) isn't isolated —
                // that's just retried whole next time.
                for item in whole {
                    do {
                        try await upsert(rows: [row(from: item)])
                        landedWhole(item)
                    } catch let e as SyncProblem where e.rowRejected {
                        refused.append((item, e))
                    }
                }
            } catch let error as SyncProblem where error.rowRejected {
                refused.append((whole[0], error))
            }
        }
        // A save the server already has gets only what changed here, so a
        // partner's edit to another column of it is never written over.
        for (item, changes) in columns {
            do {
                try await update(item.id, changes)
                landed(item.id, changes)
            } catch let e as SyncProblem where e.rowRejected {
                refused.append((item, e))
            }
        }
        guard !refused.isEmpty else { return }
        // Every row refused, and not for a limit: that's the server (a
        // bad deploy), not the rows. Nothing is set aside, and the
        // cursor stays put so they all go again next time.
        let tried = whole.count + columns.count
        if tried > 1, refused.count == tried, !refused.contains(where: { $0.1.isLimit }) {
            throw SyncProblem(
                message: "Couldn\u{2019}t save your latest changes. They\u{2019}re kept on this phone and will try again.",
                detail: refused.first?.1.detail,
                status: refused.first?.1.status ?? 0
            )
        }
        quarantine(refused)
    }

    /// A whole row the server took: it's the base now.
    private static func landedWhole(_ item: Item) {
        bases[item.id] = fields(row(from: item))
    }

    /// Columns the server took, on top of the base.
    private static func landed(_ id: UUID, _ changes: Fields) {
        guard var base = bases[id] else { return }
        for (key, value) in changes { base[key] = value }
        bases[id] = base
    }

    /// Writes some columns of one row. The server stamps who and when.
    private static func update(_ id: UUID, _ changes: Fields) async throws {
        var request = try await request(
            path: "rest/v1/items",
            query: [.init(name: "id", value: "eq.\(id.uuidString.lowercased())")]
        )
        request.httpMethod = "PATCH"
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(changes)
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

    private static func quarantine(_ refused: [(Item, SyncProblem)]) {
        var record = rejected
        for (item, _) in refused { record[item.id.uuidString] = item.updatedAt }
        if rejected.isEmpty {
            defaults.set(Date.now, forKey: rejectedSinceKey)
            defaults.set(buildNumber, forKey: rejectedBuildKey)
        }
        rejected = record
        rejectedDetail = refused.first?.1.detail
        if refused.contains(where: { $0.1.detail?.contains("daily_full") == true }) {
            defaults.set(DayString.today(), forKey: dailyRefusedKey)
        }
    }

    /// The day a row was last refused for the daily add limit. Those rows
    /// go back in the next day without needing an edit.
    private static let dailyRefusedKey = "supabaseDailyRefusedDay"

    private static func releaseDailyRefusals() {
        guard let day = defaults.string(forKey: dailyRefusedKey), day != DayString.today() else { return }
        rejected = [:]
        defaults.removeObject(forKey: dailyRefusedKey)
    }

    /// When the set-aside rows were first refused, and by which build.
    /// A day later, or once the app has been updated, they're tried again
    /// without waiting for an edit: a fix on either side lets them through.
    private static let rejectedSinceKey = "supabaseRejectedSince"
    private static let rejectedBuildKey = "supabaseRejectedBuild"

    private static func releaseStaleRefusals() {
        guard !rejected.isEmpty else { return }
        let since = defaults.object(forKey: rejectedSinceKey) as? Date ?? .distantPast
        let build = defaults.integer(forKey: rejectedBuildKey)
        guard Date.now.timeIntervalSince(since) > 86_400 || build != buildNumber else { return }
        rejected = [:]
        defaults.removeObject(forKey: rejectedSinceKey)
        defaults.removeObject(forKey: rejectedBuildKey)
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
        await announce(item, topic: "save")
    }

    /// Same for a day just planned: the row goes up first, so the server
    /// reads the new day and who set it.
    static func announcePlan(_ item: Item) async {
        await announce(item, topic: "plan")
    }

    private static func announce(_ item: Item, topic: String) async {
        guard SupabaseAuth.shared.signedIn, !SyncStatus.shared.updateRequired else { return }
        // Undone before the request left: don't put it back.
        if item.isTrashed { return }
        let id = item.id
        let context = item.modelContext
        do {
            switch pending(item, since: .distantPast) {
            case .columns(let changes):
                try await update(id, changes)
                landed(id, changes)
            case .whole:
                let row = row(from: item)
                try await upsert(rows: [row])
                bases[id] = fields(row)
            case .clean:
                // The regular sync already carried it.
                break
            }
            saveBases()
            // Gone in a library swap meanwhile: it landed, nothing to add.
            guard let item = context?.item(id) else { return }
            // Undone while the upsert was in flight. That write can land
            // after the delete and resurrect the save, so put the delete back.
            if item.isTrashed {
                setDeleted(id, true)
                return
            }
            var request = try await request(path: "functions/v1/notify-save")
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "item_id": id.uuidString.lowercased(),
                "topic": topic,
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
            remind_time: item.remindTime,
            plan_on: item.planOn,
            plan_time: item.planOn == nil ? nil : item.planTime,
            planned_by: item.plannedBy,
            went_on: item.wentOn,
            notes: item.notes,
            color: item.colorHex,
            source: item.source,
            lat: item.lat,
            lng: item.lng,
            place_id: item.placeId,
            showings: item.showingsJSON == nil ? nil : ShowingsColumn(item.showings),
            added_by_email: nil,
            group_id: item.groupId,
            updated_by: item.updatedBy,
            created_by: item.createdBy,
            created_at: item.createdAt,
            updated_at: item.updatedAt,
            deleted_at: item.deletedAt
        )
    }

    // MARK: - Pull

    private static let pageSize = 1000

    /// Where the last pull got to, on the server's clock (`touched_at`).
    /// Nil until a pull has seen the column, so a server without it keeps
    /// getting whole snapshots.
    private static let pullCursorKey = "supabasePullCursor"
    /// When the last whole snapshot was taken. One a day catches what an
    /// incremental pull can't see: rows that are gone altogether.
    private static let fullPullKey = "supabaseFullPullAt"
    /// Rows written in a transaction that commits late carry an earlier
    /// stamp; pulling a little behind the cursor still catches them.
    private static let pullOverlap: TimeInterval = 300

    private static var fullPullDue: Bool {
        guard defaults.object(forKey: pullCursorKey) is Date,
              let last = defaults.object(forKey: fullPullKey) as? Date else { return true }
        return Date.now.timeIntervalSince(last) > 86_400
    }

    /// Pulls the server's rows: all of them, or with `full` false only
    /// those written since the last pull. Returns each row's server
    /// `updated_at` so a fresh-cursor push only sends locals that are
    /// actually newer.
    @discardableResult
    private static func pull(context: ModelContext, full: Bool = true) async throws -> [UUID: Date] {
        let since = (defaults.object(forKey: pullCursorKey) as? Date)?.addingTimeInterval(-pullOverlap)
        guard full || since != nil else { return try await pull(context: context, full: true) }
        // Saves the server had before this pull: only those can have gone.
        let known = Set(bases.keys)
        var rows: [Row] = []
        var present: Set<UUID>? = []
        var offset = 0
        while true {
            let end = offset + pageSize - 1
            var query: [URLQueryItem] = [.init(name: "select", value: "*")]
            if !full, let since {
                query.append(.init(name: "touched_at", value: "gte.\(isoFractional.string(from: since))"))
                query.append(.init(name: "order", value: "touched_at.asc,id.asc"))
            } else {
                query.append(.init(name: "order", value: "updated_at.asc,id.asc"))
            }
            var request = try await request(path: "rest/v1/items", query: query)
            request.httpMethod = "GET"
            request.setValue("\(offset)-\(end)", forHTTPHeaderField: "Range")
            request.setValue("count=exact", forHTTPHeaderField: "Prefer")

            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            // A server without the column (rolled back) answers 400: back
            // to whole snapshots.
            if !full, status == 400 {
                defaults.removeObject(forKey: pullCursorKey)
                return try await pull(context: context, full: true)
            }
            guard status == 200 || status == 206 else {
                throw SyncProblem(
                    message: "Couldn't fetch the latest saves.",
                    detail: "Pull failed (\(status)): \(String(data: data.prefix(300), encoding: .utf8) ?? "")",
                    status: status
                )
            }
            let page = try await Task.detached(priority: .userInitiated) {
                try decodePage(data)
            }.value
            rows.append(contentsOf: page.rows)
            if let ids = page.ids { present?.formUnion(ids) } else { present = nil }

            let range = http?.value(forHTTPHeaderField: "Content-Range")
            if let total = contentRangeTotal(range) {
                // Paged by what was served: a row that didn't decode must
                // not send the next request past the end (a 416).
                if offset + page.served >= total || page.served == 0 { break }
                offset += page.served
                continue
            }
            // A full page with no range would be silently truncated — fail
            // rather than treat the server as empty or complete.
            if page.served >= pageSize {
                throw SyncProblem(
                    message: "Couldn't fetch the latest saves.",
                    detail: "Pull truncated without a Content-Range."
                )
            }
            break
        }

        var serverTimes: [UUID: Date] = [:]
        let locals = try context.fetch(FetchDescriptor<Item>())
        var byID = Dictionary(locals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for row in rows {
            serverTimes[row.id] = row.updated_at
            let server = localForm(row)
            guard let local = byID[row.id] else {
                // Deleted before this phone ever had it: nothing to show.
                if row.deleted_at != nil { continue }
                let item = Item()
                apply(row, to: item)
                context.insert(item)
                byID[row.id] = item
                bases[row.id] = server
                continue
            }
            let mine = fields(self.row(from: local))
            let merged: Fields
            if let base = bases[row.id] {
                merged = RowMerge.merge(base: base, local: mine, server: server)
                bases[row.id] = server
            } else {
                merged = RowMerge.wholeRow(
                    local: mine, server: server, localStamp: local.updatedAt, serverStamp: row.updated_at
                )
                // A newer local copy has yet to land; until it does, the
                // server's isn't the base of anything here.
                if row.updated_at >= local.updatedAt { bases[row.id] = server }
            }
            // Assigning an unchanged value still dirties the model, and
            // every save schedules a sync: a row rewritten on each pull
            // kept syncing forever.
            guard merged != mine, let next = self.row(merged) else { continue }
            apply(next, to: local)
        }

        if full {
            // After a complete snapshot, drop leftovers from another group.
            if let gid = GroupStore.shared.card?.groupId {
                let leftover = ((try? context.fetch(FetchDescriptor<Item>())) ?? [])
                    .filter { $0.groupId != nil && $0.groupId != gid }
                if !leftover.isEmpty {
                    // One may be open: its sheet closes before the row goes.
                    NotificationCenter.default.post(name: .cwgLibraryWillSwap, object: nil)
                    try? await Task.sleep(for: .milliseconds(350))
                    for local in leftover { context.delete(local) }
                }
            }
            if let present { await dropGone(context: context, present: present, known: known) }
            defaults.set(Date.now, forKey: fullPullKey)
        }
        if context.hasChanges {
            pullSaves += 1
            do { try context.save() } catch { pullSaves -= 1; throw error }
        }
        if let newest = rows.compactMap(\.touched_at).max(),
           newest > (defaults.object(forKey: pullCursorKey) as? Date ?? .distantPast) {
            defaults.set(newest, forKey: pullCursorKey)
        }
        saveBases()
        return serverTimes
    }

    /// Saves the server no longer has at all: deleted long enough ago to be
    /// purged (90 days), or removed by hand. A save goes only when this
    /// phone knew the server had it and holds nothing unsent for it; a
    /// trashed save with no record goes when nothing about it is unsent.
    private static func dropGone(context: ModelContext, present: Set<UUID>, known: Set<UUID>) async {
        let locals = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        let cursor = lastSyncAt
        let gone = locals.filter { item in
            guard !present.contains(item.id), !isQuarantined(item) else { return false }
            if known.contains(item.id), bases[item.id] != nil {
                if case .clean = pending(item, since: cursor) { return true }
                return false
            }
            return bases[item.id] == nil && item.isTrashed && item.updatedAt <= cursor
        }.map(\.id)
        // A row can slip between pages when another is written or purged
        // mid-pull: only what the server confirms it lacks goes.
        let confirmed = gone.isEmpty ? [] : await absent(gone)
        if !confirmed.isEmpty {
            NotificationCenter.default.post(name: .cwgLibraryWillSwap, object: nil)
            try? await Task.sleep(for: .milliseconds(350))
            for id in confirmed {
                bases[id] = nil
                // Looked up again: a model deleted meanwhile traps when touched.
                if let current = context.item(id) { context.delete(current) }
            }
        }
        // Nothing to remember for saves this phone no longer has.
        let ids = Set(((try? context.fetch(FetchDescriptor<Item>())) ?? []).map(\.id))
        bases = bases.filter { ids.contains($0.key) }
    }

    /// Of these ids, the ones the server has no row for. Empty when it
    /// can't be asked: nothing is dropped on a guess.
    private static func absent(_ ids: [UUID]) async -> [UUID] {
        var missing: [UUID] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            let list = chunk.map { $0.uuidString.lowercased() }.joined(separator: ",")
            do {
                var request = try await request(path: "rest/v1/items", query: [
                    .init(name: "select", value: "id"),
                    .init(name: "id", value: "in.(\(list))"),
                ])
                request.httpMethod = "GET"
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
                struct Found: Decodable { let id: UUID }
                let found = Set(try JSONDecoder().decode([Found].self, from: data).map(\.id))
                missing += chunk.filter { !found.contains($0) }
            } catch {
                return []
            }
        }
        return missing
    }

    /// PostgREST `Content-Range: 0-999/1234` (or `*/0`).
    private static func contentRangeTotal(_ header: String?) -> Int? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        let total = header[header.index(after: slash)...]
        return Int(total)
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
        // Postgres `time` comes back as HH:MM:SS; keep the HH:mm the app writes.
        item.remindTime = row.remind_time.map { String($0.prefix(5)) }
        item.planOn = row.plan_on
        item.planTime = row.plan_time.map { String($0.prefix(5)) }
        item.plannedBy = row.planned_by
        item.wentOn = row.went_on
        item.notes = row.notes
        item.colorHex = row.color
        item.source = row.source
        item.lat = row.lat
        item.lng = row.lng
        item.placeId = row.place_id
        item.showingsJSON = Showing.encode(row.showings?.list)
        item.addedByEmail = row.added_by_email
        item.groupId = row.group_id
        item.updatedBy = row.updated_by
        item.createdBy = row.created_by
        item.createdAt = row.created_at
        item.updatedAt = row.updated_at
        item.deletedAt = row.deleted_at
    }

    // MARK: - Column patches

    /// Writes just the given columns of one row. This is how machine-derived
    /// data (a backfilled thumbnail) and fill-only enrichment reach the
    /// server: a full-row push would carry every other field as this phone
    /// last saw it and could overwrite a partner's fresher edit. Values are
    /// JSON-ready (String, Double, NSNull). Returns whether the write landed.
    @discardableResult
    static func patch(_ id: UUID, _ fields: [String: Any], only filters: [URLQueryItem] = []) async -> Bool {
        guard SupabaseAuth.shared.signedIn, !SyncStatus.shared.updateRequired else { return false }
        do {
            var request = try await request(
                path: "rest/v1/items",
                query: [.init(name: "id", value: "eq.\(id.uuidString.lowercased())")] + filters
            )
            request.httpMethod = "PATCH"
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return false }
            // What landed is the server's now, so the next push doesn't
            // send it again. A fill-only patch that matched nothing is put
            // right by the next pull: the server's value differs from it.
            if let data = try? JSONSerialization.data(withJSONObject: fields),
               let sent = try? JSONDecoder().decode(Fields.self, from: data) {
                landed(id, sent)
                saveBases()
            }
            return true
        } catch {
            return false
        }
    }

    /// Column patch with a safety net for edits that must reach the partner:
    /// if it can't land now (offline, signed out), the item is stamped so
    /// the next regular sync carries the change as a full row instead.
    static func patchOrSync(_ item: Item, _ fields: [String: Any], context: ModelContext) async {
        let id = item.id
        let landed = await patch(id, fields)
        if !landed, let item = context.item(id) {
            item.updatedAt = .now
            try? context.save()
        }
    }

    // MARK: - Deletes

    /// Mirrors the web's soft delete; `undelete` covers the 5-second Undo.
    static func setDeleted(_ id: UUID, _ deleted: Bool) {
        let stamp: Any = deleted ? isoFractional.string(from: .now) : NSNull()
        // In order per save: an Undo's restore must never land before the
        // delete it undoes and leave the save deleted for everyone else.
        let previous = deletePatches[id]
        let next = Task {
            await previous?.value
            _ = await patch(id, ["deleted_at": stamp])
        }
        deletePatches[id] = next
        Task {
            await next.value
            if deletePatches[id] == next { deletePatches[id] = nil }
        }
    }

    private static var deletePatches: [UUID: Task<Void, Never>] = [:]
}

extension ModelContext {
    /// The save as the store has it now, or nil once it's gone. Anything
    /// that waits on the network holds the id, not the `Item`, and looks
    /// it up again after: a library swap deletes every row meanwhile, and
    /// touching a deleted model traps.
    func item(_ id: UUID) -> Item? {
        var fetch = FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 1
        return try? self.fetch(fetch).first
    }
}
