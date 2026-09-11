import SwiftUI

/// The wait, made pleasant: a slim spinning gradient ring over the app
/// blue, with rotating status copy underneath. Shared by the capture sheet
/// and the share extension.
struct ParsingIndicator: View {
    @State private var spinning = false

    var body: some View {
        VStack(spacing: 18) {
            Circle()
                .trim(from: 0.14, to: 1)
                .stroke(
                    AngularGradient(
                        colors: [AppBackground.ink.opacity(0.04), AppBackground.ink.opacity(0.9)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .frame(width: 40, height: 40)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(
                    .linear(duration: 1.1).repeatForever(autoreverses: false),
                    value: spinning
                )
                .onAppear { spinning = true }

            ParsingPhrases()
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Status copy that moves while the parser works.
struct ParsingPhrases: View {
    private static let phrases = [
        "Reading it…",
        "Finding the details…",
        "Checking the map…",
        "Nearly there…",
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2.4)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 2.4)
            Text(Self.phrases[step % Self.phrases.count])
                .id(step)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
                .animation(.snappy, value: step)
        }
    }
}
