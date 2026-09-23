import Foundation
import SwiftData

/// Free groups keep four active saves per category (`0030_plus_cap.sql`).
/// The trigger is the rule; this is its mirror, so the app can show the
/// paywall before a save is refused instead of after.
///
/// Active means saved, not deleted and not ended — the same three tests the
/// lists use to decide what's "on". Uncategorised saves never count.
enum CategoryCap {
    static let limit = 4

    /// The trigger's `category_key`: trimmed, lowercased.
    nonisolated static func key(_ category: String?) -> String {
        (category ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func counts(_ item: Item) -> Bool {
        !item.isDeleted && !item.isDone && !item.isMissed
    }

    /// Whether this phone should hold back: a known free group. With no
    /// card yet (offline first launch) the server decides.
    @MainActor
    static var applies: Bool {
        guard let card = GroupStore.shared.card else { return false }
        return !card.isPlus
    }

    /// Active saves per category key.
    static func tally(_ items: [Item]) -> [String: Int] {
        var result: [String: Int] = [:]
        for item in items where counts(item) {
            let k = key(item.category)
            if !k.isEmpty { result[k, default: 0] += 1 }
        }
        return result
    }

    /// The category `item` would overflow by becoming active — a new save,
    /// a put-back — or nil when there's room. Ended saves never count, so
    /// they're never held back.
    @MainActor
    static func overflow(_ item: Item, context: ModelContext) -> String? {
        guard applies, let category = item.category else { return nil }
        let k = key(category)
        guard !k.isEmpty, !item.isDeleted, item.timeBucket != .past else { return nil }
        let others = ((try? context.fetch(FetchDescriptor<Item>())) ?? [])
            .filter { $0.id != item.id && counts($0) && key($0.category) == k }
        return others.count >= limit ? category : nil
    }

    /// "Gigs", "Galleries", "Cafés": how a full category is named.
    static func plural(_ category: String) -> String {
        let label = Item.categoryLabel(category)
        if label.hasSuffix("s") { return label }
        if label.hasSuffix("y") { return String(label.dropLast()) + "ies" }
        return label + "s"
    }

    // MARK: - For the share extension

    /// The extension has no store of its own, so the app leaves it the
    /// counts after every sync and import. Only used for wording: the
    /// extension parks every save in the inbox either way.
    private static let snapshotKey = "categoryCapSnapshot"
    private static var defaults: UserDefaults { UserDefaults(suiteName: SharedInbox.groupID) ?? .standard }

    @MainActor
    static func publish(_ items: [Item]) {
        let snapshot: [String: Int] = applies ? tally(items) : [:]
        if defaults.dictionary(forKey: snapshotKey) as? [String: Int] != snapshot {
            defaults.set(snapshot, forKey: snapshotKey)
        }
    }

    /// True when the last snapshot says `category` is already full.
    static func lastKnownFull(_ category: String?) -> Bool {
        let k = key(category)
        guard !k.isEmpty, let snapshot = defaults.dictionary(forKey: snapshotKey) as? [String: Int] else { return false }
        return (snapshot[k] ?? 0) >= limit
    }
}
