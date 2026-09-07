import Foundation
import Observation

/// The weekly digest's send time — one row per group in Supabase
/// (`digest_schedules`, RLS: yours only) that every member reads and
/// writes, so the notification lands on all phones at the same moment.
/// ISO weekday: Monday = 1.
@Observable
@MainActor
final class DigestScheduleStore {
    static let shared = DigestScheduleStore()

    var dayOfWeek = 4
    var hour = 10
    var minute = 0
    var loaded = false
    /// The group the row belongs to — learned on pull, used to target the
    /// PATCH. RLS would scope an unfiltered PATCH anyway; this is belt and braces.
    private var groupId: UUID?

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

    private struct PulledRow: Decodable {
        var group_id: UUID
        var day_of_week: Int
        var hour: Int
        var minute: Int
    }

    func pull() async {
        guard SupabaseAuth.shared.signedIn else { return }
        do {
            let request = try await request(query: "select=group_id,day_of_week,hour,minute&limit=1")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let row = try JSONDecoder().decode([PulledRow].self, from: data).first else { return }
            groupId = row.group_id
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
            let filter = groupId.map { "group_id=eq.\($0.uuidString.lowercased())" } ?? "group_id=not.is.null"
            var request = try await request(query: filter)
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
            url: SupabaseAuth.baseURL.appending(path: "rest/v1/digest_schedules"),
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
