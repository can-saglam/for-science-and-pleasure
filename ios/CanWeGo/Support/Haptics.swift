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
}
