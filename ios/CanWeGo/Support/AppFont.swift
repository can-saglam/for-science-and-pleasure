import SwiftUI

/// The app's reading face — Post (Medium) — used for body copy like
/// summaries and notes: editorial warmth for the content itself, while
/// all the chrome stays on the system font.
extension Font {
    static func post(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Post-TRIAL-Medium", size: size, relativeTo: style)
    }

    // MARK: Display face — PP Neue Gstaad

    /// Big titles: the first-run headlines, drawer titles, the detail
    /// card's name. Bold, normal width.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("PPNeueGstaad-Bold", size: size, relativeTo: style)
    }

    /// Small titles: the name on a card in the list. The family ships no
    /// plain Regular, so this is the Condensed cut, which at 15 to 18 pt
    /// reads as a normal-width regular and keeps two-line titles short.
    static func displaySmall(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("PPNeueGstaad-CondensedRegular", size: size, relativeTo: style)
    }
}

extension View {
    /// A drawer's title, left of the close button, in the display face.
    /// Lives in the content (not the leading toolbar slot): that slot
    /// hugs its capsule and was clipping "Where are we going?" to "W…".
    func sheetTitle(_ title: String) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            Text(title)
                .font(.display(26, relativeTo: .title2))
                .foregroundStyle(AppBackground.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
