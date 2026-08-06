import SwiftUI

/// The handwritten wordmark. The source art is black, so it's rendered as
/// a template and tinted white — legible on every theme's dark base.
struct LogoTitle: View {
    var height: CGFloat = 24

    var body: some View {
        Image("Logo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(.white)
            .accessibilityLabel("Can We Go?")
    }
}

extension View {
    /// Puts the wordmark where the inline navigation title would sit.
    func logoTitle() -> some View {
        toolbar {
            ToolbarItem(placement: .principal) { LogoTitle() }
        }
    }
}
