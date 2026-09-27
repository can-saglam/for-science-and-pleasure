import Foundation
import Observation

/// The home city's chips: things on now or soon, and places worth going
/// to. The server keeps the pool fresh; this keeps the last one on the
/// phone so the chips are there the moment an empty tab or the first-save
/// page appears, and asks again at most every few hours.
@Observable
@MainActor
final class Suggestions {
    static let shared = Suggestions()
    typealias Pick = ParseClient.Suggestion

    private struct Stored: Codable {
        var city: String
        var fetchedAt: Date
        var events: [Pick]
        var places: [Pick]
    }

    private static let storeKey = "suggestionPool"
    private static let maxAge: TimeInterval = 6 * 3600

    private(set) var events: [Pick] = []
    private(set) var places: [Pick] = []
    /// "London|United Kingdom": the city the pool is about.
    private(set) var city: String?
    private(set) var loading = false
    private var fetchedAt = Date.distantPast
    private var task: Task<Void, Never>?

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        city = stored.city
        fetchedAt = stored.fetchedAt
        events = stored.events
        places = stored.places
    }

    static func key(for home: HomeStore.Home) -> String {
        "\(home.locality)|\(home.country.isEmpty ? home.locality : home.country)"
    }

    /// Ask the server, unless this city's pool is recent or on its way.
    /// A city with no events yet has a search running there: one more ask
    /// a minute and a half later picks them up, and until they're in, the
    /// pool counts as recent for ten minutes, not hours.
    func load(for home: HomeStore.Home) {
        let key = Self.key(for: home)
        let maxAge = events.isEmpty ? 600 : Self.maxAge
        if key == city, loading || Date.now.timeIntervalSince(fetchedAt) < maxAge { return }
        if key != city {
            city = key
            events = []
            places = []
            fetchedAt = .distantPast
        }
        loading = true
        task?.cancel()
        let country = home.country.isEmpty ? home.locality : home.country
        task = Task {
            let pool = try? await ParseClient.suggestions(locality: home.locality, country: country)
            guard !Task.isCancelled, city == key else { return }
            loading = false
            guard let pool else { return }
            take(pool, for: key)
            guard pool.eventsComing == true else { return }
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, city == key,
                  let again = try? await ParseClient.suggestions(locality: home.locality, country: country),
                  city == key
            else { return }
            take(again, for: key)
        }
    }

    private func take(_ pool: ParseClient.SuggestionPool, for key: String) {
        events = pool.events
        places = pool.places
        fetchedAt = .now
        let stored = Stored(city: key, fetchedAt: fetchedAt, events: events, places: places)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    /// Up to `count` for one tab: nothing that's ended, nothing already
    /// saved, and a new order each day that holds steady within it.
    func picks(kind: String, for home: HomeStore.Home, excluding saved: [Item], count: Int = 4) -> [Pick] {
        guard city == Self.key(for: home) else { return [] }
        let today = DayString.today()
        var savedLinks = Set<String>()
        var savedTitles = Set<String>()
        for item in saved where !item.isDeleted {
            if let link = item.url.flatMap(Self.linkKey) { savedLinks.insert(link) }
            savedTitles.insert(item.title.lowercased())
        }
        let pool = kind == Item.Kind.event ? events : places
        return pool
            .filter { s in
                if s.kind == Item.Kind.event, (s.endsOn ?? s.startsOn ?? "") < today { return false }
                if let link = Self.linkKey(s.url), savedLinks.contains(link) { return false }
                return !savedTitles.contains(s.title.lowercased())
            }
            .sorted { Self.dayOrder($0.url, today) < Self.dayOrder($1.url, today) }
            .prefix(count)
            .map(\.self)
    }

    /// The first-save page's three: events first, places to fill.
    func mixed(for home: HomeStore.Home, count: Int = 3) -> [Pick] {
        let on = picks(kind: Item.Kind.event, for: home, excluding: [], count: 2)
        return on + picks(kind: Item.Kind.place, for: home, excluding: [], count: count - on.count)
    }

    /// "until 2 Nov", "from 3 Oct", "tomorrow", "Sat 4 Oct".
    static func when(_ s: Pick) -> String? {
        guard s.kind == Item.Kind.event, let start = s.startsOn else { return nil }
        let today = DayString.today()
        if let end = s.endsOn, end != start {
            return start <= today
                ? DayString.text(end).map { "until \($0)" }
                : DayString.text(start).map { "from \($0)" }
        }
        if start == today { return "today" }
        if DayString.daysFromToday(start) == 1 { return "tomorrow" }
        return DayString.text(start, .dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Two spellings of one page compare equal: no scheme, www or trailing
    /// slash.
    private static func linkKey(_ raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host()?.lowercased() else { return nil }
        let path = url.path().hasSuffix("/") ? String(url.path().dropLast()) : url.path()
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path
    }

    /// FNV-1a over the day and the link: stable across launches, unlike
    /// `hashValue`.
    private static func dayOrder(_ url: String, _ day: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(day)|\(url)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }
}
