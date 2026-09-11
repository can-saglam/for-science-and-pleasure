import Foundation

/// Normalized URLs of everything in the library, mirrored into the App
/// Group so the share extension can spot duplicates without access to the
/// CloudKit-synced store.
enum SavedURLIndex {
    private static let key = "savedItemURLs"
    private static let idKey = "savedItemIDs"
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

    static func rebuild(from items: [Item], extraURLs: [String] = []) {
        var urls = Set(items.compactMap { $0.url.map(normalize) })
        for url in extraURLs { urls.insert(normalize(url)) }
        var ids: [String: String] = [:]
        for item in items {
            guard let url = item.url, !url.isEmpty else { continue }
            ids[normalize(url)] = item.id.uuidString
        }
        defaults?.set(Array(urls), forKey: key)
        defaults?.set(ids, forKey: idKey)
    }

    /// Older call sites that only had the URL list.
    static func rebuild(from urls: [String]) {
        defaults?.set(Array(Set(urls.map(normalize))), forKey: key)
    }

    static func contains(_ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return false }
        let saved = Set(defaults?.stringArray(forKey: key) ?? [])
        return saved.contains(normalize(url))
    }

    /// The existing save this URL belongs to, so the share sheet can open it.
    static func id(for url: String?) -> UUID? {
        guard let url, !url.isEmpty else { return nil }
        let ids = defaults?.dictionary(forKey: idKey) as? [String: String]
        return ids?[normalize(url)].flatMap(UUID.init(uuidString:))
    }
}
