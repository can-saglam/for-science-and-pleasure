import AuthenticationServices
import SwiftUI

/// The front door. Sign in with Apple is the way in; email/password stays
/// underneath for the two founding accounts until both are linked to Apple
/// (the launch plan then switches the password grant off). Shown once — the
/// session persists and refreshes itself from then on.
struct AuthView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var showEmail = false
    /// One nonce per Apple attempt; regenerated when the sheet is requested.
    @State private var nonce = AppleSignIn.makeNonce()
    @FocusState private var focused: Field?
    private var auth: SupabaseAuth { SupabaseAuth.shared }

    private enum Field { case email, password }

    private var canSubmit: Bool {
        email.contains("@") && !password.isEmpty && !busy
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 18) {
                    LogoTitle(height: 46)
                    Text(auth.sessionExpired
                         ? "Your session expired — sign in again to keep syncing. Everything you saved is still here."
                         : "Sign in to your shared library.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 36)
                .padding(.top, 72)

                SignInWithAppleButton(.signIn) { request in
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

                if !showEmail {
                    Button {
                        withAnimation(.snappy) { showEmail = true }
                    } label: {
                        Text("Sign in with email instead")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)
                } else {
                    Button {
                        focused = nil
                        withAnimation(.snappy) {
                            showEmail = false
                            errorMessage = nil
                        }
                    } label: {
                        Text("Use Apple instead")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)
                }

                if showEmail {
                    VStack(spacing: 12) {
                        field("Email") {
                            TextField("you@example.com", text: $email)
                                .textContentType(.username)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focused, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focused = .password }
                        }
                        field("Password") {
                            SecureField("••••••••", text: $password)
                                .textContentType(.password)
                                .focused($focused, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { if canSubmit { Task { await signIn() } } }
                        }
                    }
                    .padding(.top, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(AppBackground.warning)
                        .padding(.top, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if showEmail {
                    Button {
                        Haptics.tap()
                        Task { await signIn() }
                    } label: {
                        Group {
                            if busy {
                                ProgressView().tint(AppBackground.onProminent)
                            } else {
                                Text("Sign in")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .prominentGlass()
                    .controlSize(.large)
                    .disabled(!canSubmit)
                    .padding(.top, 22)
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

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
                .padding(14)
                .background(AppBackground.wash(0.08), in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AppBackground.wash(0.12), lineWidth: 1)
                )
        }
    }

    private func finishApple(_ result: Result<ASAuthorization, Error>) async {
        if case .failure(let error) = result, AppleSignIn.isCancellation(error) { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await AppleSignIn.complete(result, nonce: nonce)
            Haptics.success()
        } catch let error as SupabaseAuth.AuthError
            where error.message.localizedCaseInsensitiveContains("signups not allowed") {
            // Until onboarding ships, sign-ups are closed: an Apple Account
            // only gets in when its email matches an existing account — which
            // also rules out "Hide My Email". Say so instead of GoTrue's
            // "Signups not allowed for this instance".
            errorMessage = "That Apple Account isn't linked to a library yet. Use the Apple Account with the same email as your Can We Go account, and choose Share My Email."
        } catch {
            errorMessage = AppleSignIn.message(for: error)
        }
    }

    private func signIn() async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await SupabaseAuth.shared.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
            Haptics.success()
        } catch {
            // GoTrue's own messages ("Invalid login credentials") are fine
            // as-is; network failures get the human translation.
            errorMessage = (error as? SupabaseAuth.AuthError)?.message ?? SyncProblem(error).message
        }
    }
}

#Preview {
    AuthView()
}
