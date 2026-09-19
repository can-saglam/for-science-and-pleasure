import UIKit

/// One small vocabulary of touches, used everywhere so the app feels
/// consistent under the finger: light taps for buttons, ticks for
/// selections, a thump for wins.
enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Something physical settling back into place — a card landing.
    /// Intensity follows how hard it comes down, 0…1.
    static func settle(_ intensity: CGFloat = 0.8) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: min(max(intensity, 0.2), 1))
    }
}
