import Foundation
import Observation

/// Display names for the two members ("Added by Can"), fetched once from
/// the members table and cached in the App Group so names survive offline.
@Observable
@MainActor
final class MembersStore {
    static let shared = MembersStore()

    private static let cacheKey = "memberNames"

    /// email → display name.
    private(set) var names: [String: String]

    private init() {
        let defaults = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
        names = defaults.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
    }

    /// "Added by Can" — display name if known, otherwise the bit before
    /// the @, capitalised, so the row never shows a raw address.
    func name(for email: String) -> String {
        if let name = names[email.lowercased()], !name.isEmpty { return name }
        return String(email.split(separator: "@").first ?? "").capitalized
    }

    func refresh() async {
        guard SupabaseAuth.shared.signedIn else { return }
        struct Row: Decodable {
            let email: String
            let display_name: String?
        }
        do {
            let jwt = try await SupabaseAuth.shared.validToken()
            var request = URLRequest(
                url: SupabaseAuth.baseURL
                    .appending(path: "rest/v1/members")
                    .appending(queryItems: [.init(name: "select", value: "email,display_name")])
            )
            request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            let rows = try JSONDecoder().decode([Row].self, from: data)
            guard !rows.isEmpty else { return }
            names = Dictionary(
                uniqueKeysWithValues: rows.map {
                    ($0.email.lowercased(), $0.display_name ?? "")
                }
            )
            let defaults = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
            defaults.set(names, forKey: Self.cacheKey)
        } catch {
            // The cached (or derived) names keep working offline.
        }
    }
}
