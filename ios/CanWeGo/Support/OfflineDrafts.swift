import Foundation
import Network
import SwiftData

/// Saves made without a connection, finished once it's back. An on-device
/// draft is already in the library and gets the parser's card written onto
/// it (all of it if nobody has touched the draft since, otherwise only the
/// empty fields). Input with no draft (no Apple Intelligence) is looked up
/// and dropped in the inbox, like a shared link.
@MainActor
enum OfflineDrafts {
    struct Entry: Codable {
        /// The draft's id, or a fresh one naming the stored picture.
        var id: UUID
        var text: String?
        var inLibrary: Bool
        var attempts = 0
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OfflineDrafts", directoryHint: .isDirectory)
    }

    private static var queueFile: URL { directory.appending(path: "queue.json") }

    private static func pictureFile(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).jpg")
    }

    static var entries: [Entry] {
        (try? Data(contentsOf: queueFile)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    private static func store(_ entries: [Entry]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: queueFile, options: .atomic)
    }

    static func enqueue(id: UUID, text: String?, imageJPEG: Data?, inLibrary: Bool) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let imageJPEG { try? imageJPEG.write(to: pictureFile(id), options: .atomic) }
        store(entries + [Entry(id: id, text: text, inLibrary: inLibrary)])
    }

    private static func remove(_ id: UUID) {
        store(entries.filter { $0.id != id })
        try? FileManager.default.removeItem(at: pictureFile(id))
    }

    // MARK: - Connection

    private static let monitor = NWPathMonitor()
    private static var watching = false
    private static var online = true

    /// No connection at all, as opposed to a server that answered badly.
    static func isOffline(_ error: Error) -> Bool {
        if let url = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff].contains(url.code) {
            return true
        }
        return !online
    }

    /// Finishes the queue whenever the connection comes back.
    static func watch(context: ModelContext) {
        guard !watching else { return }
        watching = true
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                online = satisfied
                if satisfied { await resume(context: context) }
            }
        }
        monitor.start(queue: .main)
    }

    // MARK: - Finishing

    private static var running = false

    static func resume(context: ModelContext) async {
        guard !running, online, SupabaseAuth.shared.signedIn, let userId = SupabaseAuth.shared.userId else { return }
        let queue = entries
        guard !queue.isEmpty else { return }
        running = true
        defer { running = false }
        for entry in queue {
            let picture = try? Data(contentsOf: pictureFile(entry.id))
            do {
                let card = try await ParseClient.parse(text: entry.text, imageJPEG: picture)
                if entry.inLibrary {
                    fill(entry.id, with: card, context: context)
                } else {
                    try SharedInbox.write(SharedInbox.PendingSave(card: card, url: card.url, userId: userId))
                    NotificationCenter.default.post(name: .cwgInboxChanged, object: nil)
                }
                remove(entry.id)
            } catch where isOffline(error) {
                return
            } catch {
                // A real answer ("couldn't make sense of that") won't change
                // on a retry; anything else gets a few more goes. A draft
                // stays in the library either way.
                var tried = entry
                tried.attempts += 1
                if case ParseClient.ParseError.server(_, let status) = error, (400..<500).contains(status), status != 429 {
                    remove(entry.id)
                } else if tried.attempts >= 5 {
                    remove(entry.id)
                } else {
                    store(entries.map { $0.id == entry.id ? tried : $0 })
                }
            }
        }
    }

    private static func fill(_ id: UUID, with card: ParseClient.Card, context: ModelContext) {
        guard let item = try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first,
              item.deletedAt == nil
        else { return }
        let untouched = item.updatedAt <= item.createdAt.addingTimeInterval(10)
        func put<Value>(_ field: ReferenceWritableKeyPath<Item, Value?>, _ value: Value?) {
            guard let value, untouched || item[keyPath: field] == nil else { return }
            item[keyPath: field] = value
        }
        if untouched {
            item.kind = card.kind
            item.title = card.title
        }
        put(\.summary, card.summary)
        put(\.venue, card.venue)
        put(\.area, card.area)
        put(\.address, card.address)
        put(\.category, card.category)
        put(\.price, card.price)
        put(\.startsOn, card.starts_on)
        put(\.endsOn, card.ends_on)
        put(\.url, card.url)
        put(\.lat, card.lat)
        put(\.lng, card.lng)
        put(\.colorHex, card.color)
        put(\.imageUrl, card.image_url)
        put(\.source, card.source)
        item.reconcileReminder()
        item.updatedAt = .now
        try? context.save()
        SupabaseSync.schedule(context: context)
    }
}
