import Foundation
import SwiftData

/// A plain copy of an item's fields, so a swipe-delete can be taken back
/// after the model object itself is gone.
struct ItemSnapshot {
    var id: UUID
    var kind: String
    var title: String
    var summary: String?
    var venue: String?
    var area: String?
    var address: String?
    var url: String?
    var imageUrl: String?
    var startsOn: String?
    var endsOn: String?
    var price: String?
    var category: String?
    var notes: String?
    var status: String
    var colorHex: String?
    var lat: Double?
    var lng: Double?
    var addedByEmail: String?
    var createdAt: Date
    var updatedAt: Date
}

extension Item {
    var snapshot: ItemSnapshot {
        ItemSnapshot(
            id: id, kind: kind, title: title, summary: summary, venue: venue,
            area: area, address: address, url: url, imageUrl: imageUrl,
            startsOn: startsOn, endsOn: endsOn, price: price,
            category: category, notes: notes, status: status,
            colorHex: colorHex, lat: lat, lng: lng,
            addedByEmail: addedByEmail, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    convenience init(restoring s: ItemSnapshot) {
        self.init()
        id = s.id
        kind = s.kind
        title = s.title
        summary = s.summary
        venue = s.venue
        area = s.area
        address = s.address
        url = s.url
        imageUrl = s.imageUrl
        startsOn = s.startsOn
        endsOn = s.endsOn
        price = s.price
        category = s.category
        notes = s.notes
        status = s.status
        colorHex = s.colorHex
        lat = s.lat
        lng = s.lng
        addedByEmail = s.addedByEmail
        createdAt = s.createdAt
        updatedAt = s.updatedAt
    }
}

/// Holds the most recent deletion for a few seconds so the toast in
/// ContentView can offer an Undo.
@Observable
final class UndoBin {
    static let shared = UndoBin()

    private(set) var deleted: ItemSnapshot?
    private var expiry: Task<Void, Never>?

    func stash(_ snapshot: ItemSnapshot) {
        deleted = snapshot
        expiry?.cancel()
        expiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self.deleted = nil
        }
    }

    func restore(into context: ModelContext) {
        guard let deleted else { return }
        let item = Item(restoring: deleted)
        // Fresh timestamp so the resurrected item wins over the remote
        // soft delete instead of being re-deleted on the next pull.
        item.updatedAt = .now
        context.insert(item)
        try? context.save()
        Task { @MainActor in SupabaseSync.setDeleted(item.id, false) }
        clear()
    }

    func clear() {
        expiry?.cancel()
        deleted = nil
    }
}
