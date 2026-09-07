import Foundation
import Observation

/// Display names for the people in your library — "Added by Can",
/// "Edited by Joyce" — cached in the App Group so they survive offline.
///
/// Two lookups for now: by email (the legacy `members` table and
/// `items.added_by_email`) and by user id (`profiles`, which replaces it
/// from Phase 1a). The email path goes away with the `members` table in 1b.
@Observable
@MainActor
final class MembersStore {
    static let shared = MembersStore()

    private static let cacheKey = "memberNames"
    private static let profilesCacheKey = "profileNames"

    /// email → display name.
    private(set) var names: [String: String]
    /// user id (lowercased uuid string) → display name.
    private(set) var namesByUser: [String: String]

    private init() {
        let defaults = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
        names = defaults.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
        namesByUser = defaults.dictionary(forKey: Self.profilesCacheKey) as? [String: String] ?? [:]
    }

    /// "Added by Can" — display name if known, otherwise the bit before
    /// the @, capitalised, so the row never shows a raw address.
    func name(for email: String) -> String {
        if let name = names[email.lowercased()], !name.isEmpty { return name }
        return String(email.split(separator: "@").first ?? "").capitalized
    }

    /// Display name for a user id, or nil when we don't know them (yet).
    func name(forUser id: UUID) -> String? {
        let name = namesByUser[id.uuidString.lowercased()]
        return (name?.isEmpty == false) ? name : nil
    }

    func refresh() async {
        guard SupabaseAuth.shared.signedIn else { return }
        await refreshMembers()
        await refreshProfiles()
    }

    private func refreshMembers() async {
        struct Row: Decodable {
            let email: String
            let display_name: String?
        }
        guard let rows: [Row] = await fetch(table: "members", select: "email,display_name"),
              !rows.isEmpty else { return }
        names = Dictionary(
            uniqueKeysWithValues: rows.map { ($0.email.lowercased(), $0.display_name ?? "") }
        )
        (UserDefaults(suiteName: SharedInbox.groupID) ?? .standard).set(names, forKey: Self.cacheKey)
    }

    private func refreshProfiles() async {
        struct Row: Decodable {
            let user_id: UUID
            let display_name: String?
        }
        guard let rows: [Row] = await fetch(table: "profiles", select: "user_id,display_name"),
              !rows.isEmpty else { return }
        namesByUser = Dictionary(
            uniqueKeysWithValues: rows.map { ($0.user_id.uuidString.lowercased(), $0.display_name ?? "") }
        )
        (UserDefaults(suiteName: SharedInbox.groupID) ?? .standard).set(namesByUser, forKey: Self.profilesCacheKey)
    }

    /// RLS scopes both tables to the caller's group; a failure just leaves
    /// the cached (or derived) names in place.
    private func fetch<T: Decodable>(table: String, select: String) async -> [T]? {
        do {
            let jwt = try await SupabaseAuth.shared.validToken()
            var request = URLRequest(
                url: SupabaseAuth.baseURL
                    .appending(path: "rest/v1/\(table)")
                    .appending(queryItems: [.init(name: "select", value: select)])
            )
            request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            return nil
        }
    }
}
