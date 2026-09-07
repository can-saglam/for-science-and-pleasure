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

    static func normalizeTitle(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Joyce saved this 2 weeks ago." — who, when, and whether it has since
    /// moved to the journal.
    @MainActor
    static func describe(_ existing: Item) -> String {
        let who: String
        if let email = existing.addedByEmail {
            who = email == SupabaseAuth.shared.email ? "You" : MembersStore.shared.name(for: email)
        } else {
            who = "Someone"
        }
        let when = existing.createdAt.formatted(.relative(presentation: .named))
        var line = "\(who) saved this \(when)."
        if existing.isDone { line += " It's in We Did Go." }
        return line
    }
}
