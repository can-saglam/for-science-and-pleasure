import Foundation
import SwiftData

/// One-off migration from the web app: `scripts/export-items.ts` writes
/// seed-items.json (gitignored — it's personal data) into the bundle, and
/// this imports it into an empty store on first launch.
///
/// Run the seed on ONE device only — CloudKit sync then carries the items
/// to the rest. Seeding two devices before first sync would duplicate.
enum SeedImporter {
    /// Wire format: the Supabase items table, snake_case, dates as strings.
    private struct SeedItem: Decodable {
        let id: UUID
        let kind: String
        let title: String
        let summary: String?
        let venue: String?
        let area: String?
        let address: String?
        let url: String?
        let image_url: String?
        let starts_on: String?
        let ends_on: String?
        let price: String?
        let category: String?
        let notes: String?
        let status: String
        let color: String?
        let lat: Double?
        let lng: Double?
        let added_by_email: String?
        let created_at: Date
        let updated_at: Date
    }

    static func runIfNeeded(context: ModelContext) {
        guard let url = Bundle.main.url(forResource: "seed-items", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return }

        // Only seed a genuinely empty store (fresh install, pre-sync). A
        // failed count is not an empty store — fail closed rather than pour
        // seeds over a library we couldn't see.
        var descriptor = FetchDescriptor<Item>()
        descriptor.propertiesToFetch = [\.id]
        guard let existing = try? context.fetch(descriptor), existing.isEmpty else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let seeds = try? decoder.decode([SeedItem].self, from: data) else { return }

        // Seeds carry the same UUIDs as the synced rows, and `id` is not a
        // unique attribute (CloudKit forbids it), so never insert one twice.
        var seen = Set(existing.map(\.id))
        for seed in seeds where !seen.contains(seed.id) {
            seen.insert(seed.id)
            let item = Item()
            item.id = seed.id
            item.kind = seed.kind
            item.title = seed.title
            item.summary = seed.summary
            item.venue = seed.venue
            item.area = seed.area
            item.address = seed.address
            item.url = seed.url
            item.imageUrl = seed.image_url
            item.startsOn = seed.starts_on
            item.endsOn = seed.ends_on
            item.price = seed.price
            item.category = seed.category
            item.notes = seed.notes
            item.status = seed.status
            item.colorHex = seed.color
            item.lat = seed.lat
            item.lng = seed.lng
            item.addedByEmail = seed.added_by_email
            item.createdAt = seed.created_at
            item.updatedAt = seed.updated_at
            context.insert(item)
        }
        try? context.save()
    }
}
