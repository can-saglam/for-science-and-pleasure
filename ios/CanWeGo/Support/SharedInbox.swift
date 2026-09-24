import Foundation

/// Hand-off lane between the share extension and the app. The extension
/// can't touch the CloudKit-synced store directly, so it drops parsed cards
/// as JSON files into the App Group container; the app claims them into
/// SwiftData whenever it comes to the foreground — one file at a time,
/// deleted only after that row has been saved.
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
        var reminderOffsetDays: Int?
        var reminderAnchor: String?
        var remindAt: String?
        var remindTime: String?
        var url: String?
        var notes: String?
        var lat: Double?
        var lng: Double?
        var colorHex: String?
        var imageUrl: String?
        var source: String?
        var status: String?
        /// Share-sheet "Save anyway" after a duplicate warning.
        var allowDuplicate: Bool?
        var savedAt: Date = .now
        /// Who was signed in when the extension wrote this. A different
        /// account on the same phone must not claim it.
        var userId: String?
        var groupId: String?
        /// Set when whoever parked it already told someone the save's id
        /// (Siri answers with the save it added).
        var id: UUID?
    }

    struct Claim {
        let save: PendingSave
        let file: URL
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

    /// Files this account may import. Decode failures and other people's
    /// saves stay on disk. The caller deletes a file only after a successful
    /// `context.save()` — or after deciding a duplicate should be dropped.
    static func claim(for userId: UUID?) -> [Claim] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              )
        else { return [] }

        var claims: [Claim] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let save = try? JSONDecoder().decode(PendingSave.self, from: data)
            else { continue }
            if let owner = save.userId, let me = userId, owner.lowercased() != me.uuidString.lowercased() {
                continue
            }
            claims.append(Claim(save: save, file: file))
        }
        return claims.sorted { $0.save.savedAt < $1.save.savedAt }
    }

    static func acknowledge(_ claim: Claim) {
        try? FileManager.default.removeItem(at: claim.file)
    }

    static func removeAll() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              )
        else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}

extension Item {
    /// Materialise a pending share-extension save as a real model object.
    convenience init(pending: SharedInbox.PendingSave) {
        self.init()
        if let id = pending.id { self.id = id }
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
        reminderOffsetDays = pending.reminderOffsetDays
        reminderAnchor = pending.reminderAnchor
        remindAt = pending.remindAt
        remindTime = pending.remindTime
        url = pending.url
        notes = pending.notes
        lat = pending.lat
        lng = pending.lng
        colorHex = pending.colorHex
        imageUrl = pending.imageUrl
        source = pending.source
        if let status = pending.status { self.status = status }
        createdAt = pending.savedAt
        updatedAt = pending.savedAt
        if let gid = pending.groupId { groupId = UUID(uuidString: gid) }
        if let uid = pending.userId { createdBy = UUID(uuidString: uid); updatedBy = createdBy }
    }
}
