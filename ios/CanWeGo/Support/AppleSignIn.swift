import AuthenticationServices
import CryptoKit
import Foundation

/// The Sign in with Apple handshake, from nonce to Supabase session.
///
/// Apple returns an identity token (a JWT signed by Apple) whose audience is
/// this app's bundle id. Supabase verifies it and returns a session. The
/// nonce is generated here, hashed into the request, and sent raw to
/// Supabase so it can confirm the token was minted for exactly this attempt.
@MainActor
enum AppleSignIn {
    /// A raw nonce for one attempt; the request carries its SHA-256.
    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Completes the sign-in from Apple's credential. Throws with a message
    /// fit for the sign-in screen. Cancelling the Apple sheet is not an
    /// error worth showing, so callers should check `isCancellation` first.
    static func complete(_ result: Result<ASAuthorization, Error>, nonce: String) async throws {
        let authorization: ASAuthorization
        switch result {
        case .success(let a): authorization = a
        case .failure(let e): throw e
        }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8)
        else {
            throw Failure(message: "Apple didn't return a sign-in token. Please try again.")
        }

        try await SupabaseAuth.shared.signInWithApple(
            identityToken: identityToken,
            nonce: nonce,
            appleUserID: credential.user
        )

        // The one and only time Apple provides the name. Persist before
        // anything else can render — a killed app mid-onboarding must not
        // lose it. Existing in-app names win (claimDisplayName is fill-only).
        if let components = credential.fullName {
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .short // "Can", not "Can Saglam" — that's how partners refer to each other
            let name = formatter.string(from: components)
            if !name.isEmpty { await MembersStore.shared.claimDisplayName(name) }
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }

    /// Sign-in-screen wording for whatever went wrong. Apple's own errors
    /// are terse codes; the network/Supabase ones already read well.
    static func message(for error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        if let auth = error as? SupabaseAuth.AuthError { return auth.message }
        if let apple = error as? ASAuthorizationError {
            switch apple.code {
            case .unknown:
                // What Apple returns when the device has no Apple Account
                // signed in (the system sheet has already said so).
                return "Sign in to your Apple Account in Settings first, then try again."
            case .notInteractive:
                return "Sign in with Apple needs the screen — please try again."
            default:
                return "Apple couldn't complete the sign-in. Please try again."
            }
        }
        return SyncProblem(error).message
    }

    /// Asks Apple whether the stored credential is still good. Apple lets
    /// people revoke an app's access in Settings, and a revoked account must
    /// not keep syncing on a token that still happens to refresh. Only
    /// `.revoked` and `.notFound` sign out — `.transferred` and any lookup
    /// failure (offline) leave the session alone.
    static func checkCredentialState() async {
        guard let userID = SupabaseAuth.appleUserID else { return }
        let state: ASAuthorizationAppleIDProvider.CredentialState
        do {
            state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
        } catch {
            return
        }
        if state == .revoked || state == .notFound {
            SupabaseAuth.shared.signOut()
        }
    }
}
