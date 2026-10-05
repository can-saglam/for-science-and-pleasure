import Foundation
import MapKit
import SwiftData

/// Saves that carry a street address but no pin — the server's geocoder was
/// down when they were parsed — are looked up again on the phone with
/// Apple's geocoder. No AI call, so nothing comes off the daily allowance.
/// Only a street- or postcode-level match is kept: a city-centre guess is a
/// wrong pin, and a wrong pin is worse than none.
enum LocationBackfill {
    /// Same back-off as thumbnails: an address that found nothing is tried
    /// again after an hour, then a day, then weekly.
    private static let attemptsKey = "locationBackfillAttempts"
    private static let attemptCountsKey = "locationBackfillAttemptCounts"
    /// Apple throttles geocoding per app; a few lookups a launch stay well under it.
    private static let perRun = 5

    private static func retryAfter(misses: Int) -> TimeInterval {
        switch misses {
        case ..<2: return 3600
        case 2: return 24 * 3600
        default: return 7 * 24 * 3600
        }
    }

    /// One run at a time, as with thumbnails.
    @MainActor private static var running = false

    @MainActor
    static func run(context: ModelContext) async {
        guard !running else { return }
        running = true
        defer { running = false }
        guard let all = try? context.fetch(FetchDescriptor<Item>()) else { return }
        let missing = all.filter { item in
            item.deletedAt == nil && item.lat == nil && item.lng == nil
                && !(item.address?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        let defaults = UserDefaults.standard
        var attempts = defaults.dictionary(forKey: attemptsKey) as? [String: Date] ?? [:]
        var counts = defaults.dictionary(forKey: attemptCountsKey) as? [String: Int] ?? [:]
        let liveKeys = Set(missing.map(\.id.uuidString))
        attempts = attempts.filter { liveKeys.contains($0.key) }
        counts = counts.filter { liveKeys.contains($0.key) }

        let home = HomeStore.shared.home
        var found: [(id: UUID, lat: Double, lng: Double)] = []
        var tried = 0
        let queue = missing.map { (id: $0.id, address: $0.address) }
        for entry in queue where tried < perRun {
            guard let address = entry.address else { continue }
            let key = entry.id.uuidString
            let misses = counts[key] ?? 0
            if let last = attempts[key], Date.now.timeIntervalSince(last) < retryAfter(misses: misses) {
                continue
            }
            tried += 1
            if let spot = await coordinate(for: address, home: home) {
                guard let item = context.item(entry.id) else { continue }
                item.lat = spot.latitude
                item.lng = spot.longitude
                found.append((entry.id, spot.latitude, spot.longitude))
                attempts.removeValue(forKey: key)
                counts.removeValue(forKey: key)
            } else {
                attempts[key] = .now
                counts[key] = misses + 1
            }
        }
        defaults.set(attempts, forKey: attemptsKey)
        defaults.set(counts, forKey: attemptCountsKey)
        guard !found.isEmpty else { return }
        try? context.save()
        // A column patch that only lands while the row has no pin: the server
        // counts filling a missing pin as machine work (no "Edited by", no
        // updated_at bump), and a partner's phone that got there first wins.
        for (id, lat, lng) in found {
            await SupabaseSync.patch(id, ["lat": lat, "lng": lng], only: [URLQueryItem(name: "lat", value: "is.null")])
        }
    }

    /// The server's rule for whether an address already names its city
    /// (`namesCity` in home.ts): if not, the home is appended first, and the
    /// bare address is the fallback — a Paris address is never forced home.
    static func queries(for address: String, home: HomeStore.Home) -> [String] {
        let lower = address.lowercased()
        let parts = address.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let namesCity = home.locality.isEmpty
            || lower.contains(home.locality.lowercased())
            || (!home.country.isEmpty && lower.contains(home.country.lowercased()))
            || parts.count >= 3
        return namesCity ? [address] : ["\(address), \(home.locality), \(home.country)", address]
    }

    @MainActor
    private static func coordinate(for address: String, home: HomeStore.Home) async -> CLLocationCoordinate2D? {
        for query in queries(for: address, home: home) {
            guard let request = MKGeocodingRequest(addressString: query),
                  let items = try? await request.mapItems
            else { continue }
            if let match = items.first(where: isStreetLevel) {
                return match.location.coordinate
            }
        }
        return nil
    }

    private static func isStreetLevel(_ item: MKMapItem) -> Bool {
        item.placemark.thoroughfare != nil || item.placemark.postalCode != nil
    }
}
