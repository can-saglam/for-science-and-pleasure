import Foundation
import Observation

/// The weekly digest's send time — one shared row in Supabase that both
/// members read and write, so the notification always lands on both phones
/// at the same moment. ISO weekday: Monday = 1.
@Observable
@MainActor
final class DigestScheduleStore {
    static let shared = DigestScheduleStore()

    var dayOfWeek = 4
    var hour = 10
    var minute = 0
    var loaded = false

    private static let cacheKey = "digestSchedule"

    private init() {
        // Last synced value — shown instantly instead of the hard-coded
        // default, so the row never flashes a wrong day while the fresh
        // value is still in flight.
        if let cached = UserDefaults.standard.array(forKey: Self.cacheKey) as? [Int],
           cached.count == 3, (1...7).contains(cached[0]) {
            dayOfWeek = cached[0]
            hour = cached[1]
            minute = cached[2]
            loaded = true
        }
    }

    private func cache() {
        UserDefaults.standard.set([dayOfWeek, hour, minute], forKey: Self.cacheKey)
    }

    static let dayNames = [
        "Monday", "Tuesday", "Wednesday", "Thursday",
        "Friday", "Saturday", "Sunday",
    ]

    private struct Row: Codable {
        var day_of_week: Int
        var hour: Int
        var minute: Int
    }

    func pull() async {
        guard SupabaseAuth.shared.signedIn else { return }
        do {
            let request = try await request(query: "select=day_of_week,hour,minute&limit=1")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let row = try JSONDecoder().decode([Row].self, from: data).first else { return }
            dayOfWeek = row.day_of_week
            hour = row.hour
            minute = row.minute
            loaded = true
            cache()
        } catch {
            // Offline: keep showing the last known (or default) time.
        }
    }

    func push() async {
        guard SupabaseAuth.shared.signedIn else { return }
        do {
            var request = try await request(query: "id=eq.true")
            request.httpMethod = "PATCH"
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONEncoder().encode(
                Row(day_of_week: dayOfWeek, hour: hour, minute: minute)
            )
            _ = try await URLSession.shared.data(for: request)
            cache()
        } catch {
            // The next successful save wins; this is not critical data.
        }
    }

    private func request(query: String) async throws -> URLRequest {
        let jwt = try await SupabaseAuth.shared.validToken()
        var components = URLComponents(
            url: SupabaseAuth.baseURL.appending(path: "rest/v1/digest_schedule"),
            resolvingAgainstBaseURL: false
        )!
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!)
        request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
