import SwiftUI

/// The app's reading face — Post (Medium) — used for body copy like
/// summaries and notes: editorial warmth for the content itself, while
/// all the chrome stays on the system font.
extension Font {
    static func post(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Post-TRIAL-Medium", size: size, relativeTo: style)
    }

    // MARK: Display face — PP Neue Gstaad

    /// The normal-width bold cut. Kept for one-offs; titles across the
    /// app (drawers, first-run, detail) now use `displaySmallBold`.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("PPNeueGstaad-Bold", size: size, relativeTo: style)
    }

    /// Small titles: the name on a card in the list. The family ships no
    /// plain Regular, so this is the Condensed cut, which at 15 to 18 pt
    /// reads as a normal-width regular and keeps two-line titles short.
    static func displaySmall(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("PPNeueGstaad-CondensedRegular", size: size, relativeTo: style)
    }

    /// Same condensed cut as the card titles, in bold — every title:
    /// the detail drawer name, sheet headers, first-run headlines.
    static func displaySmallBold(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom("PPNeueGstaad-CondensedBold", size: size, relativeTo: style)
    }
}

extension View {
    /// A drawer's header: the title and the close button on one line, in
    /// the display face. Replaces the navigation bar (hidden here) so the
    /// title gets the full width — the leading toolbar slot hugs its
    /// capsule and was clipping "Where are we going?" to "W…".
    func sheetTitle(_ title: String, onClose: @escaping () -> Void) -> some View {
        toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Text(title)
                        .font(.displaySmallBold(30, relativeTo: .title2))
                        .foregroundStyle(AppBackground.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                        // Sits on the button's optical centre line.
                        .padding(.top, 7)
                    Button {
                        Haptics.tap()
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppBackground.ink)
                            // Same 44pt circle the toolbar used to draw.
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 20)
                // Clears the sheet's drag indicator with room to breathe.
                .padding(.top, 30)
                .padding(.bottom, 8)
            }
    }
}
