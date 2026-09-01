import SwiftUI

/// The app's reading face — Post (Medium) — used for body copy like
/// summaries and notes: editorial warmth for the content itself, while
/// all the chrome stays on the system font.
extension Font {
    static func post(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Post-TRIAL-Medium", size: size, relativeTo: style)
    }
}
