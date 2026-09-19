import SwiftUI

/// The wait, made pleasant: a slim spinning gradient ring over the app
/// blue, with rotating status copy underneath. Shared by the capture sheet
/// and the share extension.
struct ParsingIndicator: View {
    /// What's being read, for the first line of the ticker.
    var text: String? = nil
    var hasImage = false
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

            ParsingPhrases(text: text, hasImage: hasImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// A save button's face: the words give way to a single checkmark that
/// bounces in when `saved` flips, then the sheet leaves. The
/// acknowledgement is the button itself; the library's toast says the rest.
struct SaveMorphLabel: View {
    let title: String
    let systemImage: String
    let saved: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, systemImage: String, saved: Bool) {
        self.title = title
        self.systemImage = systemImage
        self.saved = saved
    }

    var body: some View {
        ZStack {
            Label(title, systemImage: systemImage)
                .opacity(saved ? 0 : 1)
            Image(systemName: "checkmark")
                .font(.body.weight(.bold))
                .symbolEffect(.bounce, value: saved)
                .opacity(saved ? 1 : 0)
                .scaleEffect(saved ? 1 : 0.6)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.35), value: saved)
        .accessibilityLabel(saved ? "Saved" : title)
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

/// Status copy that moves while the parser works. The first line names
/// what's being read — "Reading timeout.com…", "Reading the photo…" —
/// when the caller knows; the rest are the same for everything.
struct ParsingPhrases: View {
    /// What was sent: the text (a link or a name) and whether a picture
    /// came with it. Nil keeps the generic first line.
    var text: String? = nil
    var hasImage = false

    private static let rest = [
        "Finding the details…",
        "Checking the map…",
        "Nearly there…",
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phrases: [String] {
        [Self.opener(text: text, hasImage: hasImage)] + Self.rest
    }

    /// "Reading timeout.com…" for a link, "Reading the photo…" for a
    /// picture (with or without words), "Reading it…" otherwise.
    static func opener(text: String?, hasImage: Bool) -> String {
        if let host = text.flatMap(firstHost) { return "Reading \(host)…" }
        if hasImage { return "Reading the photo…" }
        return "Reading it…"
    }

    /// The first link's host, without "www." — the site as people say it.
    private static func firstHost(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let host = detector?.firstMatch(in: text, range: range)?.url?.host() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bare.isEmpty ? nil : bare
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2.4)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 2.4)
            Text(phrases[step % phrases.count])
                .id(step)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
                .animation(.snappy, value: step)
        }
    }
}
