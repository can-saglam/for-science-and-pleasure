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

/// A line of text changing places with the next, a letter at a time: the
/// old one lifts away and blurs out from its first letter, the new one
/// rises into focus behind it.
struct TickerRenderer: TextRenderer, Animatable {
    /// -1 not in yet, 0 in place, 1 gone.
    var phase: Double

    /// The share of the change one letter takes; the rest is the wait
    /// between the first letter's turn and the last's.
    private static let letter = 0.55
    /// Lands a hair past its place and settles back.
    private static let rise = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.25, y: 1),
        endControlPoint: UnitPoint(x: 0.4, y: 1.25)
    )

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    /// Room for the blur and the travel past the text's own bounds.
    var displayPadding: EdgeInsets { EdgeInsets(top: 14, leading: 8, bottom: 14, trailing: 8) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard phase != 0 else {
            for line in layout { context.draw(line) }
            return
        }
        var letters: [Text.Layout.RunSlice] = []
        for line in layout {
            for run in line {
                letters.append(contentsOf: run)
            }
        }
        let leaving = phase > 0
        let time = leaving ? phase : 1 + phase
        let gap = letters.count > 1 ? (1 - Self.letter) / Double(letters.count - 1) : 0
        for (index, letter) in letters.enumerated() {
            let progress = min(1, max(0, (time - Double(index) * gap) / Self.letter))
            var copy = context
            if leaving {
                guard progress < 1 else { continue }
                let eased = UnitCurve.easeIn.value(at: progress)
                copy.opacity = 1 - eased
                copy.translateBy(x: 0, y: -9 * eased)
                copy.addFilter(.blur(radius: 5 * eased))
            } else {
                guard progress > 0 else { continue }
                let eased = UnitCurve.easeOut.value(at: progress)
                copy.opacity = eased
                copy.translateBy(x: 0, y: 11 * (1 - Self.rise.value(at: progress)))
                copy.addFilter(.blur(radius: 5 * (1 - eased)))
            }
            copy.draw(letter)
        }
    }
}

/// One line ticking over to the next: see `TickerRenderer`. The new line
/// starts a beat after the old one has begun to go.
struct TickerTransition: Transition {
    static var properties: TransitionProperties { TransitionProperties(hasMotion: true) }

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.transaction { transaction in
            guard !transaction.disablesAnimations else { return }
            transaction.animation = phase.isIdentity
                ? .linear(duration: 0.55).delay(0.12)
                : .linear(duration: 0.26)
        } body: { view in
            view.textRenderer(TickerRenderer(phase: phase.value))
        }
    }
}
