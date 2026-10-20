import Foundation

/// "Have we already got this?" — the one matcher behind Capture's warning
/// today and, later, bring-my-saves when someone joins a group. Two people
/// sharing a library routinely send each other the same link, or the same
/// gig from two different ticket sites; both should surface the existing
/// save rather than a quiet second copy.
enum DuplicateFinder {
    /// A match is the same normalized URL, or the same title on the same
    /// start date. Places carry no date, so for them the same title is
    /// enough. Titles compare case-, accent- and punctuation-insensitively
    /// ("Poliça" == "polica").
    static func match(
        url: String?,
        title: String?,
        startsOn: String?,
        kind: String?,
        in items: [Item]
    ) -> Item? {
        let target = url.flatMap { $0.isEmpty ? nil : SavedURLIndex.normalize($0) }
        if let target, let hit = items.first(where: { $0.url.map(SavedURLIndex.normalize) == target }) {
            return hit
        }
        guard let title else { return nil }
        let key = normalizeTitle(title)
        guard !key.isEmpty else { return nil }
        return items.first { item in
            guard normalizeTitle(item.title) == key, item.kind == kind else { return false }
            if item.isPlace { return true }
            return startsOn != nil && item.startsOn == startsOn
        }
    }

    /// Letters and digits of any script, so a title in Japanese still has
    /// a key.
    static func normalizeTitle(_ raw: String) -> String {
        fold(raw)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Case, accents and width set aside: "Kadıköy", "KADIKÖY" and
    /// "kadikoy" are one. Turkish's dotless ı has no accent to drop, so it
    /// is mapped by hand.
    static func fold(_ raw: String) -> String {
        raw.replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// "Joyce saved this 2 weeks ago." — who, when, and whether it has since
    /// moved to the journal.
    @MainActor
    static func describe(_ existing: Item) -> String {
        let mine = (existing.createdBy != nil && existing.createdBy == SupabaseAuth.shared.userId)
            || (existing.createdBy == nil && existing.addedByEmail != nil
                && existing.addedByEmail == SupabaseAuth.shared.email)
        let who = mine ? "You" : (MembersStore.shared.saverName(for: existing) ?? "Someone")
        let when = existing.createdAt.formatted(.relative(presentation: .named))
        var line = "\(who) saved this \(when)."
        if existing.isDone { line += " It's in \(Voice.didGoSection)." }
        return line
    }
}
