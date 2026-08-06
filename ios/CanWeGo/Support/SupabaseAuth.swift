import Foundation
import Observation

/// Email/password session against the same Supabase project as the web app,
/// so both people sign in with the accounts they already have. The anon key
/// is the public "publishable" key — it ships in the web bundle too; RLS
/// (membership by email) is what actually protects the data.
@Observable
final class SupabaseAuth {
    static let shared = SupabaseAuth()

    // Mirrors web/src/lib/supabase.ts — both values are public.
    static let baseURL = URL(string: "https://gvewzvcvmeztqyfwkgwa.supabase.co")!
    static let anonKey = "sb_publishable_YAVYAVXfyuBDnlK2JxLGTQ_rfnuD5_M"

    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var email: String
    }

    struct AuthError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var session: Session? {
        didSet { persist() }
    }

    var signedIn: Bool { session != nil }
    var email: String? { session?.email }

    private static let storeKey = "supabaseSession"
    private var defaults: UserDefaults {
        UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
    }

    private init() {
        if let data = defaults.data(forKey: Self.storeKey),
           let stored = try? JSONDecoder().decode(Session.self, from: data) {
            session = stored
        }
    }

    private func persist() {
        if let session, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: Self.storeKey)
        } else {
            defaults.removeObject(forKey: Self.storeKey)
        }
    }

    // MARK: - Flows

    func signIn(email: String, password: String) async throws {
        session = try await Self.token(
            grant: "password",
            body: ["email": email, "password": password]
        )
    }

    func signOut() {
        session = nil
    }

    /// A usable access token, refreshing when within a minute of expiry.
    func validToken() async throws -> String {
        guard let current = session else { throw AuthError(message: "Signed out.") }
        if current.expiresAt > Date.now.addingTimeInterval(60) {
            return current.accessToken
        }
        let fresh = try await Self.token(
            grant: "refresh_token",
            body: ["refresh_token": current.refreshToken]
        )
        session = fresh
        return fresh.accessToken
    }

    private static func token(grant: String, body: [String: String]) async throws -> Session {
        var components = URLComponents(
            url: baseURL.appending(path: "auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [.init(name: "grant_type", value: grant)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Double
            struct User: Decodable { let email: String? }
            let user: User
        }
        guard status == 200,
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else {
            struct Failure: Decodable {
                let msg: String?
                let error_description: String?
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw AuthError(
                message: failure?.error_description ?? failure?.msg
                    ?? "Sign-in failed (\(status))."
            )
        }
        return Session(
            accessToken: token.access_token,
            refreshToken: token.refresh_token,
            expiresAt: .now.addingTimeInterval(token.expires_in),
            email: token.user.email ?? ""
        )
    }
}
