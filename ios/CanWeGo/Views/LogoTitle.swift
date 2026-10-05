import SwiftUI

/// The handwritten wordmark. The source art is black, so it's rendered as
/// a template and tinted in the theme ink — cream on midnight and forest,
/// black on cream, white on ink and wine.
///
/// Two small moments live here. The library header, the welcome page and
/// Settings write the mark in by hand the first time each shows in a
/// session (`CanWeGoLogoWriteOn`). And on the library, the "?" is turned
/// by pull-to-refresh: clockwise on its dot as the finger pulls, rocking
/// while the answer is fetched, then springing home.
struct LogoTitle: View {
    /// Where a mark writes itself in. Each place does it once per session;
    /// the next time it shows, the mark is simply there.
    enum Moment { case library, onboarding, settings }

    var height: CGFloat = 28
    /// The list is pulling from the server: the "?" rocks until it's done.
    var refreshing = false
    /// How far the list is pulled past its top.
    var pull: PullDistance? = nil
    /// Writes in by hand rather than standing still. Only the three places
    /// above ask; a mark rendered offscreen (the share postcard) must never
    /// start blank.
    var writes: Moment? = nil

    @State private var animates: Bool
    /// When each place first started writing this session.
    private static var written: [Moment: Date] = [:]

    init(height: CGFloat = 28, refreshing: Bool = false, pull: PullDistance? = nil, writes: Moment? = nil) {
        self.height = height
        self.refreshing = refreshing
        self.pull = pull
        self.writes = writes
        _animates = State(initialValue: writes.map(Self.mayWrite) ?? false)
    }

    /// Copies that show up together write together: the toolbar builds the
    /// library header twice at launch, and only one of them is on screen.
    /// Any later copy (another tab, coming back) is simply written.
    private static func mayWrite(_ moment: Moment) -> Bool {
        written[moment].map { Date.now.timeIntervalSince($0) < 0.3 } ?? true
    }
    /// The "?"'s rock on its dot while refreshing, in degrees.
    @State private var sway: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pull as a turn, in degrees clockwise: close to the finger at
    /// first, giving less the further it goes, never past 75°.
    private var turn: Double {
        guard !reduceMotion, let points = pull?.points, points > 0 else { return 0 }
        return 75 * (1 - 1 / (1 + points / 70))
    }

    var body: some View {
        let turn = turn
        ZStack {
            // The letters, with the "?" cut out…
            mark.mask {
                QuestionMarkRegion(inverted: true)
                    .fill(.black, style: FillStyle(eoFill: true))
            }
            // …and the "?" alone, free to turn on its dot. One element for
            // VoiceOver: this copy stays silent.
            mark
                .mask { QuestionMarkRegion().fill(.black) }
                .rotationEffect(.degrees(turn + sway), anchor: QuestionMarkRegion.pivot)
                // A soft spring behind the finger: it trails a beat and
                // settles with a little wobble, on the way round and back.
                .animation(.spring(response: 0.32, dampingFraction: 0.58), value: turn)
                .accessibilityHidden(writes != nil)
        }
        .frame(width: height * 5.01, height: height)
        .modifier(StaticLabel(applies: writes == nil))
        .onAppear {
            guard let writes else { return }
            // A copy made before an earlier one had written (another tab's
            // header) would otherwise write again.
            if !Self.mayWrite(writes) {
                animates = false
            } else if Self.written[writes] == nil {
                Self.written[writes] = .now
            }
        }
        .onChange(of: refreshing) { _, now in
            guard !reduceMotion else { return }
            if now {
                // Let go: back past upright, then rocking until it's done.
                withAnimation(.spring(duration: 0.35, bounce: 0.3)) { sway = -9 }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.35))
                    guard refreshing else { return }
                    withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { sway = 9 }
                }
            } else {
                withAnimation(.spring(duration: 0.55, bounce: 0.5)) { sway = 0 }
            }
        }
    }

    @ViewBuilder
    private var mark: some View {
        if writes != nil {
            // The write-on's frame carries a margin round the artwork; sized
            // so the artwork is exactly the PDF's, and nudged so its centre
            // is too — the letters land where the static mark's do.
            let unit = height / Self.artHeight
            CanWeGoLogoWriteOn(
                ink: AppBackground.ink,
                timing: .launch,
                animates: animates
            )
            .frame(width: CanWeGoLogoData.viewBoxWidth * unit, height: CanWeGoLogoData.viewBoxHeight * unit)
            .offset(
                x: (CanWeGoLogoData.viewBoxX + CanWeGoLogoData.viewBoxWidth / 2 - Self.artWidth / 2) * unit,
                y: (CanWeGoLogoData.viewBoxY + CanWeGoLogoData.viewBoxHeight / 2 - Self.artHeight / 2) * unit
            )
            .frame(width: height * 5.01, height: height)
        } else {
            Image("Logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                // Both dimensions pinned: a bare toolbar slot proposes almost
                // no width, and scaledToFit would shrink the mark to a speck.
                .frame(width: height * 5.01, height: height)
                .foregroundStyle(AppBackground.ink)
        }
    }

    /// The artwork box of `Logo.pdf`, in the write-on's units.
    private static let artWidth = 1855.379883
    private static let artHeight = 370.670044

    /// The static mark is one element with its own label; the write-on
    /// brings its own ("CanWeGo?", as a header).
    private struct StaticLabel: ViewModifier {
        var applies: Bool
        func body(content: Content) -> some View {
            if applies {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Can We Go?")
            } else {
                content
            }
        }
    }
}

extension LogoTitle {
    /// Where the "?" sits in the mark, in unit coordinates: the hook
    /// reaches left over the O's shoulder, so the region is the far right
    /// column plus a shelf across the top for the hook. Measured off the
    /// art; `inverted` adds the whole rect so an even-odd fill gives the
    /// rest of the mark.
    struct QuestionMarkRegion: Shape {
        var inverted = false

        /// The dot of the "?": the point it turns on.
        static let pivot = UnitPoint(x: 0.965, y: 0.97)

        func path(in rect: CGRect) -> Path {
            var p = Path()
            if inverted { p.addRect(rect) }
            // The two rects don't overlap, so the even-odd fill stays honest.
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.888, y: rect.minY,
                width: rect.width * (0.94 - 0.888), height: rect.height * 0.22
            ))
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.94, y: rect.minY,
                width: rect.width * (1 - 0.94), height: rect.height
            ))
            return p
        }
    }
}

extension View {
    /// Puts the wordmark at the leading edge of the navigation bar; all
    /// the controls group at the trailing end. No glass behind it — the
    /// system capsule would squeeze the wide mark into a circle.
    func logoTitle(refreshing: Bool = false, pull: PullDistance? = nil) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                LogoTitle(refreshing: refreshing, pull: pull, writes: .library)
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// How far a list is pulled down past its top, in points. Its own object
/// so the frame-by-frame updates redraw the wordmark alone, not the list.
@Observable
final class PullDistance {
    var points: CGFloat = 0
}
