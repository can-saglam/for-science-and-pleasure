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

/// Pull-to-refresh, felt: light ticks that firm up as the list is pulled
/// further, then one solid knock when the refresh catches. Ticks only count
/// on the way down, so letting go and springing back stays quiet; after
/// the knock it waits for the list to come home before ticking again.
@MainActor
final class PullFeedback {
    /// Points of pull between ticks, and where the system refresh control
    /// catches (measured: about 174), so the ticks firm up all the way to it.
    private static let spacing: CGFloat = 16
    private static let reach: CGFloat = 170

    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let knock = UIImpactFeedbackGenerator(style: .rigid)
    private var step = 0
    private var armed = true
    /// A finger on the list. A fling that bounces off the top overshoots
    /// too, and that isn't a pull.
    var dragging = false

    func pulled(to points: CGFloat) {
        guard points > 0 else {
            step = 0
            armed = true
            return
        }
        guard armed, dragging else { return }
        if step == 0 {
            tick.prepare()
            knock.prepare()
        }
        let reached = Int(points / Self.spacing)
        guard reached > step else { return }
        step = reached
        tick.impactOccurred(intensity: 0.25 + 0.6 * min(points / Self.reach, 1))
    }

    func caught() {
        guard armed else { return }
        armed = false
        knock.impactOccurred(intensity: 1)
    }
}
