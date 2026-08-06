import Foundation

/// Normalized URLs of everything in the library, mirrored into the App
/// Group so the share extension can spot duplicates without access to the
/// CloudKit-synced store.
enum SavedURLIndex {
    private static let key = "savedItemURLs"
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedInbox.groupID)
    }

    /// Scheme, www and trailing slashes don't make a link a different save.
    /// Query strings stay — they distinguish real pages on ticketing sites.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func rebuild(from urls: [String]) {
        defaults?.set(Array(Set(urls.map(normalize))), forKey: key)
    }

    static func contains(_ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return false }
        let saved = Set(defaults?.stringArray(forKey: key) ?? [])
        return saved.contains(normalize(url))
    }
}
