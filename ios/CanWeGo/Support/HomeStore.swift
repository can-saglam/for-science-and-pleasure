import CoreLocation
import Foundation
import Observation

/// The group's home: the city the library is about. Read from `groups`
/// (RLS: your group only) and cached in the App Group so the share sheet
/// and a cold launch agree with the app.
///
/// Home does three things here and nothing more (launch plan, Phase 1a):
///  * it is the clock — "today", "Last Day", This Week and the widget's
///    labels are all measured in the home timezone, so the shared library
///    reads the same on every member's phone wherever they happen to be;
///  * it is where the map opens when you're far from it;
///  * it tells the parser which city to assume (sent server-side via the JWT).
/// It never moves a saved pin.
@Observable
@MainActor
final class HomeStore {
    static let shared = HomeStore()

    struct Home: Codable, Hashable {
        var locality: String
        var country: String
        var timezone: String
        var lat: Double?
        var lng: Double?

        static let london = Home(
            locality: "London", country: "United Kingdom",
            timezone: "Europe/London", lat: 51.5074, lng: -0.1278
        )

        var timeZone: TimeZone { TimeZone(identifier: timezone) ?? TimeZone(identifier: "Europe/London")! }

        var coordinate: CLLocationCoordinate2D? {
            guard let lat, let lng else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
    }

    nonisolated private static let cacheKey = "groupHome"

    private(set) var home: Home
    /// True only when this group has a real home on the server — not the
    /// London fallback used so the clock always has *somewhere* to tick.
    /// Onboarding reads it (alongside the group card) to skip the home
    /// page; `signedOut()` clears it so a leftover cache from the previous
    /// account can't skip the first-run.
    private(set) var isSet = false

    private init() {
        if let cached = Self.cached() {
            home = cached
            isSet = true
        } else {
            home = .london
        }
        DayString.use(timeZone: home.timeZone)
    }

    func signedOut() {
        home = .london
        isSet = false
        DayString.use(timeZone: home.timeZone)
        (UserDefaults(suiteName: SharedInbox.groupID) ?? .standard).removeObject(forKey: Self.cacheKey)
    }

    /// City, country, timezone and pin from a geocoded placemark. Prefers
    /// the locality (the city), never a county or country.
    static func from(_ placemark: CLPlacemark) -> Home? {
        let skipAdmin: Set<String> = [
            "England", "Scotland", "Wales", "Northern Ireland",
        ]
        let locality = placemark.locality?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? placemark.subLocality?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? placemark.administrativeArea.flatMap {
                skipAdmin.contains($0) ? nil : $0.trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
        guard let locality else { return nil }
        return Home(
            locality: locality,
            country: placemark.country?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "",
            timezone: placemark.timeZone?.identifier ?? TimeZone.current.identifier,
            lat: placemark.location?.coordinate.latitude,
            lng: placemark.location?.coordinate.longitude
        )
    }

    /// Boroughs inside Greater London (Hackney, Camden) should be offered
    /// as London — that's the city the library is about, not the ward.
    /// Manchester or Edinburgh keep their own name.
    static func widerCity(for home: Home) -> Home? {
        guard let lat = home.lat, let lng = home.lng,
              (51.28...51.70).contains(lat), (-0.52...0.33).contains(lng),
              home.locality.compare("London", options: .caseInsensitive) != .orderedSame
        else { return nil }
        return .london
    }

    /// Whatever the last refresh left in the App Group; nil on a fresh install.
    nonisolated static func cached() -> Home? {
        let defaults = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(Home.self, from: data)
    }

    /// Roughly how far the user is from home; nil when either is unknown.
    func distance(from location: CLLocation?) -> CLLocationDistance? {
        guard let location, let c = home.coordinate else { return nil }
        return location.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    /// Within ~100 km of home counts as "at home": the map opens on the
    /// user, distance chips show. Beyond it the map opens on home and the
    /// chips (which would all read "1,200 km") hide.
    func isNearHome(_ location: CLLocation?) -> Bool {
        guard let d = distance(from: location) else { return true }
        return d < 100_000
    }

    func refresh() async {
        guard SupabaseAuth.shared.signedIn else { return }
        struct Row: Decodable {
            let home_locality: String?
            let home_country: String?
            let home_timezone: String?
            let home_lat: Double?
            let home_lng: Double?
        }
        do {
            let jwt = try await SupabaseAuth.shared.validToken()
            var request = URLRequest(
                url: SupabaseAuth.baseURL
                    .appending(path: "rest/v1/groups")
                    .appending(queryItems: [
                        .init(name: "select", value: "home_locality,home_country,home_timezone,home_lat,home_lng"),
                        .init(name: "limit", value: "1"),
                    ])
            )
            request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let row = try JSONDecoder().decode([Row].self, from: data).first
            else { return }
            let named = row.home_locality?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            isSet = named != nil
            // Anything the group hasn't set falls back to London, same as
            // the server's homeFromRow(). The cache only keeps a real home
            // so a fresh account on this phone doesn't inherit the last one.
            let fresh = Home(
                locality: named ?? Home.london.locality,
                country: row.home_country?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? Home.london.country,
                timezone: row.home_timezone?.nilIfEmpty ?? Home.london.timezone,
                lat: row.home_lat,
                lng: row.home_lng
            )
            apply(fresh, persist: isSet)
        } catch {
            // Offline: the cached home stands.
        }
    }

    /// Writes the group's home. Members can edit their own group.
    @discardableResult
    func save(_ next: Home) async -> String? {
        guard let groupId = GroupStore.shared.card?.groupId,
              let jwt = try? await SupabaseAuth.shared.validToken()
        else { return "Couldn\u{2019}t reach your group. Try again once you\u{2019}re online." }
        var request = URLRequest(
            url: SupabaseAuth.baseURL
                .appending(path: "rest/v1/groups")
                .appending(queryItems: [.init(name: "id", value: "eq.\(groupId.uuidString)")])
        )
        request.httpMethod = "PATCH"
        request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        var body: [String: Any] = [
            "home_locality": next.locality,
            "home_country": next.country,
            "home_timezone": next.timezone,
        ]
        if let lat = next.lat { body["home_lat"] = lat }
        if let lng = next.lng { body["home_lng"] = lng }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        else { return "Couldn\u{2019}t save the city. Try again." }
        isSet = true
        apply(next, persist: true)
        GroupStore.shared.homeSaved(locality: next.locality, country: next.country)
        return nil
    }

    private func apply(_ fresh: Home, persist: Bool) {
        if fresh != home {
            home = fresh
            DayString.use(timeZone: fresh.timeZone)
        }
        let defaults = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
        if persist, let data = try? JSONEncoder().encode(fresh) {
            defaults.set(data, forKey: Self.cacheKey)
        } else if !persist {
            defaults.removeObject(forKey: Self.cacheKey)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
