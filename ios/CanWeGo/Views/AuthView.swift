import AuthenticationServices
import SwiftUI

/// The front door. Sign in with Apple creates a library or opens the one
/// already on that Apple ID. Shown once — the session persists and
/// refreshes itself from then on.
struct AuthView: View {
    @State private var busy = false
    @State private var errorMessage: String?
    /// One nonce per Apple attempt; regenerated when the sheet is requested.
    @State private var nonce = AppleSignIn.makeNonce()
    private var auth: SupabaseAuth { SupabaseAuth.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 18) {
                    LogoTitle(height: 46)
                    Text(auth.sessionExpired
                         ? "Your session expired. Sign in again to keep syncing. Everything you saved is still here."
                         : "Sign in with Apple to start a library, or open the one you already have.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 36)
                .padding(.top, 72)

                SignInWithAppleButton(.continue) { request in
                    nonce = AppleSignIn.makeNonce()
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = AppleSignIn.sha256(nonce)
                } onCompletion: { result in
                    Task { await finishApple(result) }
                }
                .signInWithAppleButtonStyle(AppBackground.theme.isLight ? .black : .white)
                .frame(height: 50)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .disabled(busy)
                .accessibilityHint("Uses your Apple Account")

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(AppBackground.warning)
                        .padding(.top, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { ThemeFill(color: AppBackground.base) }
        .appColorScheme()
    }

    private func finishApple(_ result: Result<ASAuthorization, Error>) async {
        if case .failure(let error) = result, AppleSignIn.isCancellation(error) { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await AppleSignIn.complete(result, nonce: nonce)
            Haptics.success()
        } catch {
            errorMessage = AppleSignIn.message(for: error)
        }
    }
}

#Preview {
    AuthView()
}
