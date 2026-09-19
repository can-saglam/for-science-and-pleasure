import SwiftUI

/// The handwritten wordmark. The source art is black, so it's rendered as
/// a template and tinted in the theme ink — cream on midnight and forest,
/// black on cream, white on ink and wine.
///
/// Two small moments live here. On a cold launch the mark fades and
/// settles into place once, so the app is alive from the first frame. And
/// while the library is refreshing, the "?" rocks on its dot — the mark
/// asking the question while the answer is fetched.
struct LogoTitle: View {
    var height: CGFloat = 28
    /// The list is pulling from the server: the "?" rocks until it's done.
    var refreshing = false
    /// Fade-and-settle on first appearance. Only the library header asks
    /// for it; a mark rendered offscreen (the share postcard) must not
    /// start invisible.
    var settles = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One settle per process, whichever copy of the mark gets there first.
    @State private var settled: Bool
    private static var hasSettled = false

    init(height: CGFloat = 28, refreshing: Bool = false, settles: Bool = false) {
        self.height = height
        self.refreshing = refreshing
        self.settles = settles
        // Starts hidden only for the one settle; everything else is
        // simply there.
        _settled = State(initialValue: !(settles && !Self.hasSettled))
    }
    /// The "?"'s lean, in degrees.
    @State private var tilt: Double = 0

    var body: some View {
        ZStack {
            // The letters, with the "?" cut out…
            mark.mask {
                QuestionMarkRegion(inverted: true)
                    .fill(.black, style: FillStyle(eoFill: true))
            }
            // …and the "?" alone, free to rock on its dot.
            mark
                .mask { QuestionMarkRegion().fill(.black) }
                .rotationEffect(.degrees(tilt), anchor: QuestionMarkRegion.pivot)
        }
        .frame(width: height * 5.01, height: height)
        .opacity(settled ? 1 : 0)
        .offset(y: settled ? 0 : 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Can We Go?")
        .onAppear {
            guard !settled else { return }
            Self.hasSettled = true
            if reduceMotion {
                settled = true
            } else {
                withAnimation(.spring(duration: 0.55, bounce: 0.15).delay(0.05)) { settled = true }
            }
        }
        .onChange(of: refreshing) { _, now in
            guard !reduceMotion else { return }
            if now {
                // Lean one way, then sway between the two until it's done.
                withAnimation(.easeInOut(duration: 0.28)) { tilt = -11 }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.28))
                    guard refreshing else { return }
                    withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { tilt = 11 }
                }
            } else {
                withAnimation(.spring(duration: 0.5, bounce: 0.45)) { tilt = 0 }
            }
        }
    }

    private var mark: some View {
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

extension LogoTitle {
    /// Where the "?" sits in the mark, in unit coordinates: the hook
    /// reaches left over the O's shoulder, so the region is the far right
    /// column plus a shelf across the top for the hook. Measured off the
    /// art; `inverted` adds the whole rect so an even-odd fill gives the
    /// rest of the mark.
    struct QuestionMarkRegion: Shape {
        var inverted = false

        /// The dot of the "?": the point it rocks on.
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
    func logoTitle(refreshing: Bool = false) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) { LogoTitle(refreshing: refreshing, settles: true) }
                .sharedBackgroundVisibility(.hidden)
        }
    }
}
