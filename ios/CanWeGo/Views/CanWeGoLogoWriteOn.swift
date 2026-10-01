// CanWeGoLogoWriteOn.swift
//
// Draws the CanWeGo? logo as if it were being written by hand, then rests on the exact
// outline from the logo PDF. Port of the web prototype (reference/canwego-handwriting.html).
//
// How it works: each letter's real outline is filled with the ink colour, but only where the
// pen has already been. The pen is a wide round-capped stroke trimmed along a centre line.
// Some strokes are split into segments, and a segment may only reveal its own `area` of the
// letter, which keeps e.g. the A's crossbar hidden until its own stroke draws it.
// Colour is never baked in: pass any `Color`, including one from the asset catalog that has
// light and dark variants, and it adapts instantly, even mid-animation.

import SwiftUI

// MARK: - Timing

struct CanWeGoLogoTiming: Sendable {
    /// Pen speed in logo units per second.
    var pace: Double
    /// Pause between strokes of the same letter, in seconds.
    var lift: Double
    /// Pause between letters, in seconds.
    var gap: Double
    /// How long the question-mark dot takes to tap in.
    var dotDuration: Double = 0.26

    /// About 2.5 s. Use this for app launch.
    static let launch = CanWeGoLogoTiming(pace: 3200, lift: 0.04, gap: 0.04)
    /// About 4.4 s. The "Normal" speed in the web prototype.
    static let standard = CanWeGoLogoTiming(pace: 1700, lift: 0.10, gap: 0.15)
}

struct CanWeGoLogoTimeline: Sendable {
    struct Item: Sendable {
        let letter: Int
        let stroke: Int
        let segment: Int
        let start: Double
        let duration: Double
        let isDot: Bool
    }

    let items: [Item]
    /// Total length of the animation in seconds.
    let total: Double

    init(timing: CanWeGoLogoTiming, letters: [CanWeGoLogoLetter] = CanWeGoLogoData.letters) {
        var items: [Item] = []
        var t = 0.0
        for (li, letter) in letters.enumerated() {
            if letter.dotCenterX != nil {
                items.append(Item(letter: li, stroke: 0, segment: 0, start: t, duration: timing.dotDuration, isDot: true))
                t += timing.dotDuration
                continue
            }
            for (si, segments) in letter.strokes.enumerated() {
                for (gi, segment) in segments.enumerated() {
                    // Every segment is its own eased movement, so the pen slows into corners.
                    let duration = max(0.08, segment.length / timing.pace * 1.12)
                    items.append(Item(letter: li, stroke: si, segment: gi, start: t, duration: duration, isDot: false))
                    t += duration
                }
                t += (si == letter.strokes.count - 1) ? timing.gap : timing.lift
            }
        }
        self.items = items
        self.total = items.map { $0.start + $0.duration }.max() ?? 0
    }

    /// For pen segments: how much of the segment is drawn, 0...1 (minimum-jerk easing, like a reaching hand).
    /// For the dot: its size factor, with a small overshoot before settling at 1.
    func progress(of item: Item, at time: Double) -> Double {
        let raw = min(1, max(0, (time - item.start) / item.duration))
        if item.isDot {
            return raw < 1 ? max(0, 1 - pow(1 - raw, 2) * (1 - 2.2 * raw)) : 1
        }
        return raw * raw * raw * (10 - 15 * raw + 6 * raw * raw)
    }
}

// MARK: - Geometry (parsed once)

enum CanWeGoLogoGeometry {
    struct Segment: Sendable {
        let pen: Path
        let area: Path?
    }

    struct Letter: Sendable {
        let outline: Path
        let segments: [[Segment]]
        let dotCenter: CGPoint?
    }

    static let letters: [Letter] = CanWeGoLogoData.letters.map { letter in
        Letter(
            outline: CanWeGoLogoGeometry.path(letter.outline),
            segments: letter.strokes.map { stroke in
                stroke.map { Segment(pen: CanWeGoLogoGeometry.path($0.pen), area: $0.area.map { CanWeGoLogoGeometry.path($0) }) }
            },
            dotCenter: letter.dotCenterX.map { CGPoint(x: $0, y: letter.dotCenterY ?? 0) }
        )
    }

    /// Parses the strict path format used in CanWeGoLogoData: absolute M / L / C / Z,
    /// every command written out, tokens separated by single spaces.
    static func path(_ data: String) -> Path {
        let tokens = data.split(separator: " ")
        var index = 0
        func number() -> CGFloat {
            defer { index += 1 }
            return CGFloat(Double(tokens[index]) ?? 0)
        }
        func point() -> CGPoint {
            let x = number()
            let y = number()
            return CGPoint(x: x, y: y)
        }
        var path = Path()
        while index < tokens.count {
            let command = tokens[index]
            index += 1
            switch command {
            case "M":
                path.move(to: point())
            case "L":
                path.addLine(to: point())
            case "C":
                let c1 = point()
                let c2 = point()
                let end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
            case "Z":
                path.closeSubpath()
            default:
                assertionFailure("Unexpected path command \(command)")
                return path
            }
        }
        return path
    }
}

// MARK: - View

struct CanWeGoLogoWriteOn: View {
    /// Ink colour. Use a colour with light and dark variants (e.g. Color("LogoInk")).
    var ink: Color
    var timing: CanWeGoLogoTiming = .launch
    /// false = show the finished logo straight away (e.g. after the first launch animation has played).
    var animates: Bool = true
    /// Change this value to play the animation again.
    var replayTrigger: Int = 0
    /// Called once the logo has finished writing (immediately when Reduce Motion is on or `animates` is false).
    var onFinish: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()
    @State private var finished = false

    private var timeline: CanWeGoLogoTimeline { CanWeGoLogoTimeline(timing: timing) }

    var body: some View {
        let timeline = self.timeline
        let showFinished = finished || reduceMotion || !animates
        TimelineView(.animation(paused: showFinished)) { context in
            let time = showFinished ? Double.infinity : max(0, context.date.timeIntervalSince(startDate))
            canvas(time: time, timeline: timeline)
        }
        .aspectRatio(CanWeGoLogoData.viewBoxWidth / CanWeGoLogoData.viewBoxHeight, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CanWeGo?")
        .accessibilityAddTraits(.isHeader)
        .task(id: replayTrigger) {
            if reduceMotion || !animates {
                finished = true
                onFinish()
                return
            }
            finished = false
            startDate = Date()
            try? await Task.sleep(for: .seconds(timeline.total))
            guard !Task.isCancelled else { return }
            finished = true
            onFinish()
        }
    }

    private func canvas(time: Double, timeline: CanWeGoLogoTimeline) -> some View {
        Canvas { context, size in
            // Fit the logo's frame into the available size, centred.
            let scale = min(size.width / CanWeGoLogoData.viewBoxWidth, size.height / CanWeGoLogoData.viewBoxHeight)
            context.translateBy(
                x: (size.width - CanWeGoLogoData.viewBoxWidth * scale) / 2,
                y: (size.height - CanWeGoLogoData.viewBoxHeight * scale) / 2
            )
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -CanWeGoLogoData.viewBoxX, y: -CanWeGoLogoData.viewBoxY)

            let penStyle = StrokeStyle(lineWidth: CanWeGoLogoData.penWidth, lineCap: .round, lineJoin: .round)
            let letters = CanWeGoLogoGeometry.letters

            for (li, letter) in letters.enumerated() {
                // At rest, the exact outline: the per-segment area clips meet
                // on antialiased edges that leave faint seams inside letters.
                if time >= timeline.total {
                    context.fill(letter.outline, with: .color(ink))
                    continue
                }
                let items = timeline.items.filter { $0.letter == li }
                guard items.contains(where: { time > $0.start }) else { continue }

                context.drawLayer { layer in
                    // 1. Paint where the pen has been, in white (acts as a mask).
                    // A clip layer rather than `.sourceIn`: Canvas blends only
                    // inside the shape being filled, so `.sourceIn` left the pen
                    // strokes standing in white outside the letter.
                    layer.clipToLayer { mask in
                        for item in items {
                            let progress = timeline.progress(of: item, at: time)
                            guard progress > 0 else { continue }

                            if item.isDot, let centre = letter.dotCenter {
                                let d = CanWeGoLogoData.dotDiameter * progress
                                mask.fill(
                                    Path(ellipseIn: CGRect(x: centre.x - d / 2, y: centre.y - d / 2, width: d, height: d)),
                                    with: .color(.white)
                                )
                                continue
                            }

                            let segment = letter.segments[item.stroke][item.segment]
                            mask.drawLayer { pen in
                                if let area = segment.area { pen.clip(to: area) }
                                pen.stroke(segment.pen.trimmedPath(from: 0, to: progress), with: .color(.white), style: penStyle)
                            }
                        }
                    }
                    // 2. Keep the real letter outline only where the mask is painted.
                    layer.fill(letter.outline, with: .color(ink))
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Write-on, light and dark") {
    struct Demo: View {
        @State private var replay = 0
        var body: some View {
            VStack(spacing: 24) {
                CanWeGoLogoWriteOn(ink: Color(red: 42.0 / 255, green: 23.0 / 255, blue: 13.0 / 255), replayTrigger: replay)
                    .frame(width: 300)
                    .padding(24)
                    .background(Color(red: 246.0 / 255, green: 235.0 / 255, blue: 221.0 / 255))
                CanWeGoLogoWriteOn(ink: Color(red: 251.0 / 255, green: 239.0 / 255, blue: 227.0 / 255), replayTrigger: replay)
                    .frame(width: 300)
                    .padding(24)
                    .background(Color(red: 129.0 / 255, green: 66.0 / 255, blue: 33.0 / 255))
                Button("Replay") { replay += 1 }
            }
        }
    }
    return Demo()
}
