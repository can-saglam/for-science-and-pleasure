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
        /// HTTP status when the server itself rejected us; 0 otherwise.
        var status = 0
        var errorDescription: String? { message }
    }

    private(set) var session: Session? {
        didSet {
            persist()
            if session != nil { sessionExpired = false }
        }
    }

    /// Set when the server refused to renew the session (revoked token
    /// family, deleted account…) and the app signed itself out. The sign-in
    /// screen reads it to explain the sudden front door — and to say that
    /// nothing local was lost, because it wasn't: the store stays put.
    private(set) var sessionExpired = false

    var signedIn: Bool { session != nil && !Self.signedOutFlag }
    var email: String? { session?.email }

    /// The signed-in user's id, read from the access token's `sub` claim
    /// (so it needs no extra field in the stored session).
    var userId: UUID? {
        guard let token = session?.accessToken else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = claims["sub"] as? String
        else { return nil }
        return UUID(uuidString: sub)
    }

    private static let storeKey = "supabaseSession"
    private var defaults: UserDefaults {
        UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
    }

    /// Written on sign-out so the Share Extension cannot refresh an old
    /// in-memory token and put the session back in the keychain.
    private static var signedOutFlag: Bool {
        get {
            (UserDefaults(suiteName: SharedInbox.groupID) ?? .standard)
                .bool(forKey: KeychainSession.signedOutKey)
        }
        set {
            let d = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
            if newValue { d.set(true, forKey: KeychainSession.signedOutKey) }
            else { d.removeObject(forKey: KeychainSession.signedOutKey) }
        }
    }

    private init() {
        if Self.signedOutFlag {
            KeychainSession.delete()
            defaults.removeObject(forKey: Self.storeKey)
            session = nil
            return
        }
        session = storedSession()
    }

    /// The session as persisted right now — which may be newer than the one
    /// in memory, because the share extension rotates tokens in its own
    /// process and this one only reads the store at launch.
    private func storedSession() -> Session? {
        if let data = KeychainSession.load(),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            return session
        }
        guard let data = defaults.data(forKey: Self.storeKey),
              let session = try? JSONDecoder().decode(Session.self, from: data)
        else { return nil }
        KeychainSession.save(data)
        defaults.removeObject(forKey: Self.storeKey)
        return session
    }

    private func persist() {
        if Self.signedOutFlag || session == nil {
            KeychainSession.delete()
            defaults.removeObject(forKey: Self.storeKey)
            return
        }
        if let session, let data = try? JSONEncoder().encode(session) {
            KeychainSession.save(data)
            defaults.removeObject(forKey: Self.storeKey)
        }
    }

    // MARK: - Flows

    /// Sign in with Apple: the identity token Apple hands the app is
    /// exchanged at the same token endpoint (`grant_type=id_token`). Supabase
    /// verifies it against Apple's keys and the bundle id, and — because the
    /// email is verified by Apple — links it to an existing account with that
    /// email rather than creating a second one. The nonce ties the token to
    /// this request so a captured one can't be replayed.
    func signInWithApple(identityToken: String, nonce: String, appleUserID: String) async throws {
        Self.signedOutFlag = false
        session = try await Self.token(
            grant: "id_token",
            body: ["provider": "apple", "id_token": identityToken, "nonce": nonce]
        )
        Self.appleUserID = appleUserID
    }

    func signOut() {
        let refresh = session?.refreshToken
        let access = session?.accessToken
        Self.signedOutFlag = true
        session = nil
        Self.appleUserID = nil
        KeychainSession.delete()
        SharedInbox.removeAll()
        if let refresh {
            Task { await Self.logoutRemote(refresh: refresh, access: access) }
        }
    }

    /// Best-effort server revoke. Offline still clears local state above.
    private static func logoutRemote(refresh: String, access: String?) async {
        var request = URLRequest(url: baseURL.appending(path: "auth/v1/logout"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let access {
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONEncoder().encode(["refresh_token": refresh])
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Apple credential state

    /// Apple's stable per-app user identifier, kept only so the app can ask
    /// Apple on launch whether the user has since revoked access in
    /// Settings → Apple Account → Sign in with Apple. Nil for password sessions.
    private static let appleUserKey = "appleUserID"
    static var appleUserID: String? {
        get { (UserDefaults(suiteName: SharedInbox.groupID) ?? .standard).string(forKey: appleUserKey) }
        set {
            let d = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
            if let newValue { d.set(newValue, forKey: appleUserKey) } else { d.removeObject(forKey: appleUserKey) }
        }
    }

    /// True when the session was started with Apple, so the UI can say
    /// "Signed in with Apple" and the launch check knows to run.
    var usesApple: Bool { signedIn && Self.appleUserID != nil }

    /// One renewal at a time: concurrent callers must share a single
    /// rotation, because burning the same refresh token twice more than ten
    /// seconds apart makes Supabase revoke the whole session.
    @MainActor private var refreshTask: Task<Session, Error>?

    /// A usable access token, refreshing when within a minute of expiry.
    ///
    /// Renewal is the one fragile spot in the app: Supabase rotates the
    /// refresh token on every renewal, and replaying a stale one revokes
    /// the entire session — after which every sync fails silently while
    /// the UI still says "signed in". Three defenses:
    ///  1. always prefer the newest persisted session (the share extension
    ///     rotates tokens behind this process's back),
    ///  2. serialize renewals so concurrent syncs share one rotation,
    ///  3. when the server genuinely rejects the renewal, sign out — the
    ///     login screen is recoverable, a zombie session is not.
    ///  4. a signed-out flag beats any in-memory token, so the extension
    ///     cannot write the session back after Settings signs out.
    @MainActor
    func validToken() async throws -> String {
        if Self.signedOutFlag {
            session = nil
            throw AuthError(message: "Signed out.")
        }
        if let stored = storedSession(),
           stored.expiresAt > (session?.expiresAt ?? .distantPast) {
            session = stored
        }
        guard let current = session, !Self.signedOutFlag else {
            session = nil
            throw AuthError(message: "Signed out.")
        }
        if current.expiresAt > Date.now.addingTimeInterval(60) {
            return current.accessToken
        }

        let task = refreshTask ?? Task { [token = current.refreshToken] in
            if Self.signedOutFlag { throw AuthError(message: "Signed out.") }
            return try await Self.token(grant: "refresh_token", body: ["refresh_token": token])
        }
        refreshTask = task
        do {
            let fresh = try await task.value
            refreshTask = nil
            if Self.signedOutFlag {
                session = nil
                throw AuthError(message: "Signed out.")
            }
            session = fresh
            return fresh.accessToken
        } catch {
            refreshTask = nil
            // 4xx means the token family is dead — no retry can save it.
            // Anything else (offline, 5xx) keeps the session for next time.
            if let rejection = error as? AuthError, (400...499).contains(rejection.status) {
                signOut()
                sessionExpired = true
            }
            throw error
        }
    }

    private static func token(grant: String, body: [String: String]) async throws -> Session {
        var components = URLComponents(
            url: baseURL.appending(path: "auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [.init(name: "grant_type", value: grant)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
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
                    ?? "Sign-in failed (\(status)).",
                status: status
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
