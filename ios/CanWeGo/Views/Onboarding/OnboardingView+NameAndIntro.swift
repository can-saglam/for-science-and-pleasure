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

    // MARK: Intro

    /// Straight after sign-in, before any question: what the app is for,
    /// ending on sharing so the next page's question has its context.
    var introPage: some View {
        let points = [
            ("square.and.arrow.down", "Save it from anywhere",
             "Share a link from Instagram, TikTok, Safari or Maps, snap a poster, or search. It becomes a card with the dates."),
            ("hourglass", "See what\u{2019}s closing",
             "What ends soon rises to the top, and you can get a nudge before it\u{2019}s gone."),
            ("person.2.fill", "Share it with your people",
             "Keep one list with a partner or friends, so plans stop getting lost in the group chat."),
        ]
        return VStack(alignment: .leading, spacing: 18) {
            deckSlot(.intro, height: 80)
                .padding(.top, tight ? 8 : 24)
                .padding(.bottom, tight ? 8 : 16)
            headline(firstName.map { "Hi \($0).\nHere\u{2019}s the idea." } ?? "Here\u{2019}s\nthe idea.")
            lede("One list for the exhibitions, gigs, restaurants and bars you mean to get to.")

            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(points.enumerated()), id: \.offset) { i, point in
                    row(point.0, point.1, point.2)
                        // In one by one once the cards have squared up.
                        .opacity(introShown ? 1 : 0)
                        .offset(y: introShown ? 0 : 10)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.55 + Double(i) * 0.15),
                                   value: introShown)
                }
            }
            .padding(.top, 8)
        }
        .onAppear {
            dealt = true
            introShown = true
            stripStart = .now
        }
        .onDisappear { stripStart = nil }
    }

    var firstName: String? {
        trimmedName.split(separator: " ").first.map(String.init)
    }
}
