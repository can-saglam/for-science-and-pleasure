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

/// A placeholder for a line of text the parser hasn't filled yet.
struct SkeletonLine: View {
    var width: CGFloat
    var height: CGFloat = 10

    var body: some View {
        Capsule()
            .fill(AppBackground.ink.opacity(0.10))
            .frame(width: width, height: height)
    }
}

/// A soft band of light that sweeps across whatever it overlays, once
/// every couple of seconds. Holds still under Reduce Motion.
struct Shimmer: View {
    /// The band's colour at its brightest; the caller picks something
    /// that reads as light on its surface (a soft white on both paper
    /// and dark glass, at different strengths).
    var highlight: Color = .white.opacity(0.12)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: highlight, location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: w * 0.7)
            .offset(x: phase * w)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                    phase = 1.15
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The spinner at caption size, for sitting beside a line of text.
struct SmallRing: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.18, to: 1)
            .stroke(
                AngularGradient(
                    colors: [AppBackground.ink.opacity(0.05), AppBackground.ink.opacity(0.85)],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
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
