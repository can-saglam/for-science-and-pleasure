import Foundation
import Observation

/// Display names for the people in your library — "Added by Can",
/// "Edited by Joyce" — cached in the App Group so they survive offline.
///
/// Names come from `profiles` (RLS: your group only), keyed by user id.
/// Rows saved before Phase 1b only carry an email; for those the bit before
/// the @ is shown, so nothing ever renders as a raw address.
@Observable
@MainActor
final class MembersStore {
    static let shared = MembersStore()

    private static let profilesCacheKey = "profileNames"

    /// user id (lowercased uuid string) → display name.
    private(set) var namesByUser: [String: String]

    private init() {
        let defaults = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
        namesByUser = defaults.dictionary(forKey: Self.profilesCacheKey) as? [String: String] ?? [:]
    }

    /// Who saved an item: profile name when the row carries a user id,
    /// otherwise derived from the legacy email. Nil when there's neither.
    func saverName(for item: Item) -> String? {
        if let id = item.createdBy, let name = name(forUser: id) { return name }
        if let email = item.addedByEmail { return name(for: email) }
        return nil
    }

    /// Fallback for legacy email-only rows: the bit before the @, capitalised.
    func name(for email: String) -> String {
        String(email.split(separator: "@").first ?? "").capitalized
    }

    /// Display name for a user id, or nil when we don't know them (yet).
    func name(forUser id: UUID) -> String? {
        let name = namesByUser[id.uuidString.lowercased()]
        return (name?.isEmpty == false) ? name : nil
    }

    func refresh() async {
        guard SupabaseAuth.shared.signedIn else { return }
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

    /// RLS scopes the table to the caller's group; a failure just leaves
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
