import Foundation
import SwiftData

/// Ten new saves a day each, fifty in a Plus group (`0043_daily_adds.sql`).
/// The trigger is the rule; this is its mirror, so the drawer shows when
/// Save is tapped instead of the save being refused later.
///
/// What counts is what this person added today, on the home clock, that's
/// still in the library: every route the same, and deleting one frees it.
enum DailyCap {
    static let free = 10
    static let plus = 50

    @MainActor
    static var limit: Int { GroupStore.shared.card?.isPlus == true ? plus : free }

    /// Whether this phone should hold back. With no card yet (offline
    /// first launch) the server decides.
    @MainActor
    static var applies: Bool { GroupStore.shared.card != nil && SupabaseAuth.shared.userId != nil }

    static var startOfToday: Date { DayString.calendar.startOfDay(for: .now) }

    /// Today's adds by `me`, newest first.
    static func today(_ items: [Item], me: UUID?) -> [Item] {
        guard let me else { return [] }
        let start = startOfToday
        return items
            .filter { $0.createdBy == me && !$0.isDeleted && $0.createdAt >= start }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// True when adding `item` would go past today's limit. Only new saves
    /// are asked about; the item itself never counts against itself.
    @MainActor
    static func isFull(adding item: Item, context: ModelContext) -> Bool {
        guard applies else { return false }
        let all = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        return today(all, me: SupabaseAuth.shared.userId).filter { $0.id != item.id }.count >= limit
    }
}
