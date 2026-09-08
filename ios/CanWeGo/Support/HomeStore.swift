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

    struct Home: Codable, Equatable {
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

    private init() {
        home = Self.cached() ?? .london
        DayString.use(timeZone: home.timeZone)
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
            // Anything the group hasn't set falls back to London, same as
            // the server's homeFromRow().
            let fresh = Home(
                locality: row.home_locality?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? Home.london.locality,
                country: row.home_country?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? Home.london.country,
                timezone: row.home_timezone?.nilIfEmpty ?? Home.london.timezone,
                lat: row.home_lat,
                lng: row.home_lng
            )
            guard fresh != home else { return }
            home = fresh
            DayString.use(timeZone: fresh.timeZone)
            if let data = try? JSONEncoder().encode(fresh) {
                (UserDefaults(suiteName: SharedInbox.groupID) ?? .standard).set(data, forKey: Self.cacheKey)
            }
        } catch {
            // Offline: the cached home stands.
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
