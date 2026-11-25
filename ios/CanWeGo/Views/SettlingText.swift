import SwiftUI

/// Which word of its text a run belongs to, counted from the start.
struct WordOrder: TextAttribute {
    let index: Int
}

extension Text {
    /// The same words, each marked with its place in line, so that
    /// `WordsSettle` can bring them in one after another. Reads, wraps and
    /// is spoken exactly as `Text(string)` would be.
    init(words string: String) {
        let pieces = string.split(separator: " ", omittingEmptySubsequences: false)
        guard pieces.count > 1 else {
            self = Text(verbatim: string).customAttribute(WordOrder(index: 0))
            return
        }
        let marked = pieces.enumerated().map { index, piece in
            // Each word keeps the space after it, so the pieces add up to
            // the string.
            Text(verbatim: index < pieces.count - 1 ? piece + " " : String(piece))
                .customAttribute(WordOrder(index: index))
        }
        self = Self.joined(marked[...])
    }

    /// Halves at a time, so a long description nests a few levels deep
    /// rather than once per word.
    private static func joined(_ parts: ArraySlice<Text>) -> Text {
        guard parts.count > 1 else { return parts.first ?? Text(verbatim: "") }
        let middle = parts.startIndex + parts.count / 2
        return Text("\(joined(parts[..<middle]))\(joined(parts[middle...]))")
    }
}

/// Text arriving the way it's read: each word comes in soft and a touch
/// low, then sharpens into place, one after another from the first.
/// Text that isn't marked word by word settles a line at a time.
struct SettleRenderer: TextRenderer, Animatable {
    /// Seconds since the text arrived.
    var elapsed: Double

    /// How long one word takes, and the longest the last word waits for
    /// its turn: a long description takes no longer than a short line.
    static let wordTime = 0.42
    static let spread = 0.5
    static let span = wordTime + spread
    private static let step = 0.045

    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    /// Room for the blur to spill past the text's own bounds.
    var displayPadding: EdgeInsets { EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard elapsed < Self.span else {
            for line in layout { context.draw(line) }
            return
        }
        var units: [(run: Text.Layout.Run, order: Int)] = []
        for (row, line) in layout.enumerated() {
            for run in line {
                units.append((run, run[WordOrder.self]?.index ?? row))
            }
        }
        let last = units.map(\.order).max() ?? 0
        let step = last > 0 ? min(Self.step, Self.spread / Double(last)) : 0
        for unit in units {
            let progress = (elapsed - Double(unit.order) * step) / Self.wordTime
            guard progress > 0 else { continue }
            guard progress < 1 else {
                context.draw(unit.run)
                continue
            }
            let eased = UnitCurve.easeOut.value(at: progress)
            var copy = context
            copy.opacity = min(1, eased * 1.4)
            copy.translateBy(x: 0, y: (1 - eased) * 5)
            copy.addFilter(.blur(radius: (1 - eased) * 5))
            copy.draw(unit.run)
        }
    }
}

/// Text settling in word by word as it's added. Nothing moves once it's
/// in, and leaving is someone else's business: pair it with a removal.
struct WordsSettle: Transition {
    /// Seconds before the first word, for fields that land together.
    var delay: Double = 0

    static var properties: TransitionProperties { TransitionProperties(hasMotion: true) }

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.transaction { transaction in
            if !transaction.disablesAnimations {
                transaction.animation = .linear(duration: SettleRenderer.span).delay(delay)
            }
        } body: { view in
            view.textRenderer(SettleRenderer(elapsed: phase.isIdentity ? SettleRenderer.span : 0))
        }
    }
}
