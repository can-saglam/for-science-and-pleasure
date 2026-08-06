import Foundation

/// Hand-off lane between the share extension and the app. The extension
/// can't touch the CloudKit-synced store directly, so it drops parsed cards
/// as JSON files into the App Group container; the app sweeps them into
/// SwiftData whenever it comes to the foreground.
enum SharedInbox {
    static let groupID = "group.com.cansaglam.CanWeGo"

    struct PendingSave: Codable {
        var kind: String
        var title: String
        var summary: String?
        var venue: String?
        var area: String?
        var address: String?
        var category: String?
        var price: String?
        var startsOn: String?
        var endsOn: String?
        var url: String?
        var notes: String?
        var lat: Double?
        var lng: Double?
        var colorHex: String?
        var imageUrl: String?
        var savedAt: Date = .now
    }

    private static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appending(path: "PendingSaves", directoryHint: .isDirectory)
    }

    static func write(_ save: PendingSave) throws {
        guard let directory else {
            throw NSError(
                domain: "CanWeGo", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable."]
            )
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(UUID().uuidString).json")
        try JSONEncoder().encode(save).write(to: file, options: .atomic)
    }

    /// Returns all pending saves and removes them from the container.
    static func drain() -> [PendingSave] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              )
        else { return [] }

        var saves: [PendingSave] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let save = try? JSONDecoder().decode(PendingSave.self, from: data) {
                saves.append(save)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return saves.sorted { $0.savedAt < $1.savedAt }
    }
}

extension Item {
    /// Materialise a pending share-extension save as a real model object.
    convenience init(pending: SharedInbox.PendingSave) {
        self.init()
        kind = pending.kind
        title = pending.title
        summary = pending.summary
        venue = pending.venue
        area = pending.area
        address = pending.address
        category = pending.category
        price = pending.price
        startsOn = pending.startsOn
        endsOn = pending.endsOn
        url = pending.url
        notes = pending.notes
        lat = pending.lat
        lng = pending.lng
        colorHex = pending.colorHex
        imageUrl = pending.imageUrl
        createdAt = pending.savedAt
        updatedAt = pending.savedAt
    }
}
