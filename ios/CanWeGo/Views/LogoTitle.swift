import SwiftUI

/// The handwritten wordmark. The source art is black, so it's rendered as
/// a template and tinted white — legible on every theme's dark base.
struct LogoTitle: View {
    var height: CGFloat = 28

    var body: some View {
        Image("Logo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            // Both dimensions pinned: a bare toolbar slot proposes almost
            // no width, and scaledToFit would shrink the mark to a speck.
            .frame(width: height * 4.83, height: height)
            .foregroundStyle(.white)
            .accessibilityLabel("Can We Go?")
    }
}

extension View {
    /// Puts the wordmark at the leading edge of the navigation bar; all
    /// the controls group at the trailing end. No glass behind it — the
    /// system capsule would squeeze the wide mark into a circle.
    func logoTitle() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) { LogoTitle() }
                .sharedBackgroundVisibility(.hidden)
        }
    }
}
