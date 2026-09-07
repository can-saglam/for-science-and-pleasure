import SwiftUI

/// The front door: same two accounts as the web app. Shown once — the
/// session persists and refreshes itself from then on.
struct AuthView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        email.contains("@") && !password.isEmpty && !busy
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                LogoTitle(height: 46)
                Text("Sign in to your shared library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 36)

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

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Haptics.tap()
                Task { await signIn() }
            } label: {
                Group {
                    if busy {
                        ProgressView().tint(AppBackground.base)
                    } else {
                        Text("Sign in")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppBackground.base)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.white)
            .controlSize(.large)
            .disabled(!canSubmit)
            .padding(.top, 22)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .background(AppBackground.base.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
                .padding(14)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
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
