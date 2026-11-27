import AuthenticationServices
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UserNotifications

extension OnboardingView {
    // MARK: Name

    var namePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("What should we\ncall you?")
            lede("First name is plenty. It's how you show up on the things you save: “Added by \(trimmedName.isEmpty ? "you" : trimmedName)”.")

            slab {
                TextField("", text: $name, prompt: AppBackground.fieldPrompt("Your first name"))
                    .font(.title3)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .name)
                    .foregroundStyle(AppBackground.ink)
                    .onSubmit(commitName)
                    .onChange(of: name) { _, new in
                        note = nil
                        if new.unicodeScalars.count > 24 {
                            name = String(String.UnicodeScalarView(new.unicodeScalars.prefix(24)))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
            }

            noteLine
        }
    }

    func commitName() {
        guard !trimmedName.isEmpty, !busy else { return }
        if preview { advance(); return }
        busy = true
        note = nil
        Task {
            // Always unlocks, including when the request is cancelled, so
            // a failed attempt can't leave the forward button dead.
            defer { busy = false }
            if let error = await members.setDisplayName(trimmedName) {
                note = error
                return
            }
            advance()
        }
    }

    // MARK: Theme

    /// The look is chosen for them once, from the system appearance, and
    /// only on a fresh install — never over a choice already on disk.
    func preselectTheme() {
        guard !preview, !themes.hasStoredChoice else { return }
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
        let dark = (screen?.traitCollection.userInterfaceStyle ?? .dark) != .light
        themes.select(dark ? .midnight : .oat)
    }

    /// A row of swatches under the first real card: tap one and the card,
    /// the page and the rest of the app repaint. Lives on the two pages
    /// that show real cards, so the choice is made looking at the thing
    /// it changes.
    var themeSwatches: some View {
        ThemeSwatchRow { option in
            // `preview` paints, `commit` writes: same pair the settings
            // picker uses, without the window snapshot `select` takes.
            themes.preview(option)
            themes.commit()
        }
        .modifier(ColumnClip(on: sideBySide))
        .padding(.top, 4)
    }
}
