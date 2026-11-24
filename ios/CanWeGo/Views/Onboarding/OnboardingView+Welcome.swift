import AuthenticationServices
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UserNotifications

extension OnboardingView {
    // MARK: Welcome

    /// The front door: the wordmark, one line, and Sign in with Apple.
    /// The same button whether this is a brand new account or a returning
    /// one, because Apple knows which and we don't until the session
    /// lands. New accounts arrive with a name, so the name page is never
    /// asked of them; returning ones skip the whole run.
    var welcomePage: some View {
        Group {
            if sideBySide {
                // The fan on one side of the fold, the door on the other:
                // the library's list and pane, before there's a library.
                HStack(spacing: 0) {
                    deckSlot(.welcome, height: 270)
                    frontDoor
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 22) {
                    deckSlot(.welcome, height: 250)
                        .padding(.bottom, 18)
                    frontDoor
                }
            }
        }
        .frame(maxWidth: .infinity)
        // A tall phone wants it a little above centre. iPhone Duo's
        // displays are near square: dead centre, the home indicator's
        // inset evened out.
        .padding(Foldable.rotates(Foldable.sceneSize) ? .top : .bottom,
                 Foldable.rotates(Foldable.sceneSize) ? 20 : 40)
        .animation(ease, value: signingIn)
        .animation(ease, value: unreachable)
        .onAppear {
            guard !dealt else { return }
            if reduceMotion {
                dealt = true
                return
            }
            // Deal the hand, then let it breathe once the last card has
            // settled.
            dealt = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.3))
                drift = true
            }
        }
    }

    /// iPhone Duo open and held sideways: too wide for one column.
    var sideBySide: Bool { pageWidth >= 760 }

    /// Short of a phone's height: iPhone Duo open or folded, iPhone SE.
    /// The page's height, less the bar and the room over it: ~630 on a
    /// Pro, ~580 on a mini, ~510 folded.
    var tight: Bool { sideBySide || pageHeight < 560 }

    var frontDoor: some View {
        VStack(spacing: 22) {
            LogoTitle(height: 52, writes: .onboarding)
            Text(auth.sessionExpired && !preview
                 ? "Your session expired.\nSign in again to keep syncing.\nEverything you saved is still here."
                 : "For all the places you\u{2019}ll go!")
                .font(.displaySmallBold(23, relativeTo: .title3))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if needsSignIn || unreachable || signingIn || preview || auth.signedIn {
                signInBlock
                    .frame(maxWidth: sideBySide ? 312 : nil)
                    .padding(.top, 12)
            }

            legalLine
        }
    }

    /// The fan's seats, back to front: (tilt°, x, y). A cascade rather
    /// than a spread, so each card behind shows its title line above the
    /// one in front, and the front card sits straight and whole.
    static let seats: [(Double, Double, Double)] = [
        (-4.0, -30.0, -56.0),
        (3.0, 26.0, -20.0),
        (-2.0, -22.0, 16.0),
        (0.0, 12.0, 58.0),
    ]

    /// The intro's row: the welcome four across the screen, then a few more
    /// waiting off its right edge to drift in. Unscaled points, a card's
    /// width plus a gap apart.
    static let stripPitch: Double = 298
    static let stripSeats: [(Double, Double, Double)] =
        (0..<(sampleCards.count + stripExtras.count)).map { (0.0, (Double($0) - 1.5) * stripPitch, 0.0) }
    static let stripScale: CGFloat = 0.74
    /// One height for every card in the row, whatever lines it has.
    static let stripCardHeight: CGFloat = 100

    /// `x` brought into the loop's span, which starts at `start`.
    static func wrapped(_ x: Double, in loop: Double, from start: Double) -> Double {
        let r = (x - start).truncatingRemainder(dividingBy: loop)
        return start + (r < 0 ? r + loop : r)
    }

    /// How far the strip has run. It sets off while the cards are still
    /// landing, its speed rising along a smooth curve with no kick at
    /// either end, so settling and drifting read as one motion.
    func stripTravel(at date: Date) -> CGFloat {
        guard let stripStart, !reduceMotion else { return 0 }
        let t = date.timeIntervalSince(stripStart) - 0.35
        guard t > 0 else { return 0 }
        let speed = 36.0, ramp = 2.6
        if t >= ramp { return CGFloat(speed * (t - ramp / 2)) }
        let u = t / ramp
        return CGFloat(speed * ramp * (u * u * u - u * u * u * u / 2))
    }

    /// Where the welcome cards sit on a page. The deck itself is drawn
    /// above the pages and follows whichever slot is showing.
    func deckSlot(_ page: Page, height: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .anchorPreference(key: DeckSlotKey.self, value: .bounds) { [page: $0] }
            .accessibilityHidden(true)
    }

    /// Loose on the front door; once signed in, a row that runs across
    /// the screen on a loop. Above the pages, so a card pulled down
    /// travels across the page rather than under it.
    var showcaseDeck: some View {
        let strip = page == .intro
        return TimelineView(.animation(paused: !strip || reduceMotion)) { context in
            cardFan(strip ? Self.sampleCards + Self.stripExtras : Self.sampleCards,
                    seats: strip ? Self.stripSeats : Self.seats,
                    dealt: dealt, key: 0, still: strip,
                    slide: strip ? stripTravel(at: context.date) : 0,
                    loop: strip ? Self.stripPitch * Double(Self.stripSeats.count) : 0)
        }
        // The cascade is ~340pt across; a small phone's margins hold
        // less, so it shrinks to fit rather than bleed.
        .scaleEffect(min(1, (pageWidth - 56) / 340) * (strip ? Self.stripScale : 1))
        .accessibilityHidden(true)
    }

    /// Seats for up to three real cards, back to front: the welcome
    /// cascade's front three, tilted and shifted half as much, as the
    /// cards are wider and a tilt would dip a title under the next card.
    /// Their heights come from `fanOverlap` instead, as real titles run to
    /// one line or two.
    static func joinedSeats(_ count: Int) -> [(Double, Double, Double)] {
        seats.suffix(count).map { ($0.0 * 0.5, $0.1 * 0.5, 0) }
    }

    /// How far a real card tucks under the one behind it: the place line
    /// goes under whole, so only the title shows.
    static let fanOverlap: CGFloat = 36
    /// A short display's fan is shrunk whole, so the titles keep their
    /// phone lines.
    var fanScale: CGFloat { tight ? 0.84 : 1 }

    /// "+2" on the front card's corner: saves beyond the ones a fan shows.
    /// Lands after the last card does.
    @ViewBuilder
    func moreBadge(_ count: Int, dealt: Bool) -> some View {
        if count > 0 {
            Text("+\(count)")
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(AppBackground.base)
                .frame(width: 34, height: 34)
                .background(AppBackground.ink, in: .circle)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .offset(x: 0, y: -5)
                .scaleEffect(dealt ? 1 : 0.4)
                .opacity(dealt ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.4).delay(0.5), value: dealt)
                .accessibilityLabel("and \(count) more")
        }
    }

    /// Cards dealt into a loose stack, then drifting a little: welcome's
    /// made-up saves, and the joined page's real ones. Real `ItemCard`s,
    /// so the look is exactly the library's — countdown badge, melt and
    /// all. Each one can be picked up and pulled about; it springs back to
    /// its seat. `items` and `seats` run back to front; `key` keeps each
    /// fan's pulls apart; cards in `reading` shimmer until their page is in.
    /// With `overlap`, the seats' heights are ignored: each card tucks that
    /// far under the one behind it, however many lines their titles run to.
    /// `still` stops the drift, and the cards settle into new seats one
    /// after another rather than all at once. With a `loop` length, the
    /// seats run `slide` to the left and wrap round to the right.
    func cardFan(
        _ items: [Item], seats: [(Double, Double, Double)], dealt: Bool, key: Int, width: CGFloat = 280,
        reading: Set<UUID> = [], overlap: CGFloat? = nil, still: Bool = false,
        slide: CGFloat = 0, loop: Double = 0
    ) -> some View {
        let count = min(items.count, seats.count)
        var seats = Array(seats.prefix(count))
        var total: CGFloat = 0
        if let overlap {
            let heights: [CGFloat] = (0..<count).map { cardHeights[key + $0] ?? 100 }
            var tops: [CGFloat] = []
            var top: CGFloat = 0
            for height in heights {
                tops.append(top)
                top += height - overlap
            }
            total = top + overlap
            for n in 0..<count {
                seats[n].2 = Double(tops[n] + heights[n] / 2 - total / 2)
            }
        }
        // A card wraps half a gap past the leftmost seat, out of sight.
        let loopStart = (seats.map(\.1).min() ?? 0) - loop / Double(max(count, 1)) / 2
        // A running row lines up the cards' tops (at the largest text
        // sizes they keep their own heights).
        return ZStack(alignment: loop > 0 ? .top : .center) {
            ForEach(Array(items.prefix(count).enumerated()), id: \.offset) { index, item in
                let i = key + index
                let seat = seats[index]
                let front = index == min(items.count, seats.count) - 1
                let sway = front || still ? 0.0 : (index.isMultiple(of: 2) ? 1.0 : -1.0)
                let pull = pulled[i] ?? .zero
                let held = lifted == i
                let travel = loop > 0 ? Self.wrapped(seat.1 - slide, in: loop, from: loopStart) - seat.1 : 0
                ItemCard(item: item, oneLineTitle: loop > 0, awayHint: false, fillsHeight: loop > 0)
                    .overlay {
                        if reading.contains(item.id) {
                            Shimmer(highlight: .white.opacity(themes.current.isLight ? 0.55 : 0.14))
                                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .animation(ease, value: reading.contains(item.id))
                    .frame(width: width,
                           height: loop > 0 && !typeSize.isAccessibilitySize ? Self.stripCardHeight : nil)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        // A card's seat follows the heights, and moved a third
                        // of a point its own height can snap the other way: a
                        // loop that never draws a frame. Real changes are bigger.
                        if abs((cardHeights[i] ?? 0) - height) >= 1 { cardHeights[i] = height }
                    }
                    // A held card tilts with the pull, like a card on a
                    // table dragged from one edge.
                    .rotationEffect(.degrees((dealt ? seat.0 + (drift ? 1.2 : -1.2) * sway : 0) + pull.width / 16))
                    .offset(
                        x: (dealt ? seat.1 : 0) + pull.width,
                        y: (dealt ? seat.2 + (drift ? -3 : 3) * sway : 110) + pull.height
                    )
                    .scaleEffect(dealt ? (held ? 1.03 : 1) : 0.86)
                    .opacity(dealt ? 1 : 0)
                    .shadow(
                        color: .black.opacity(themes.current.isLight ? (held ? 0.16 : 0.10) : (held ? 0.5 : 0.35)),
                        radius: held ? 24 : 16, y: held ? 14 : 8
                    )
                    // Depth is fixed: a card pulled out from the middle
                    // of the stack stays in the middle of the stack.
                    .zIndex(Double(index))
                    // Dealt back to front, a beat apart.
                    .animation(
                        reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.26).delay(Double(index) * 0.13),
                        value: dealt
                    )
                    // Into new seats left to right, without overshoot.
                    .animation(
                        reduceMotion ? nil : .spring(duration: 1.0, bounce: 0).delay(Double(index) * 0.04),
                        value: still
                    )
                    .animation(reduceMotion ? nil : .spring(duration: 0.3), value: held)
                    // Below the animations: the strip moves every frame and
                    // wraps out of sight, so it must never spring.
                    .offset(x: travel)
                    // Ahead of the page's scroll view, which has nothing
                    // to scroll here but would still claim a vertical pull.
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                if lifted != i {
                                    lifted = i
                                    Haptics.tap()
                                }
                                pulled[i] = value.translation
                            }
                            .onEnded { value in
                                // Springs home, overshooting a touch, and
                                // lands with a soft thud sized to how far
                                // it had to travel.
                                let distance = hypot(value.translation.width, value.translation.height)
                                withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(duration: 0.6, bounce: 0.45)) {
                                    pulled[i] = .zero
                                }
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(reduceMotion ? 0.25 : 0.3))
                                    if pulled[i] == .zero {
                                        Haptics.settle(0.4 + min(distance / 200, 0.6))
                                        if lifted == i { lifted = nil }
                                    }
                                }
                            }
                    )
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 5).repeatForever(autoreverses: true), value: drift)
        .frame(height: overlap == nil ? nil : total)
    }

    /// Four saves that read like a real week, back to front: an
    /// exhibition with days left, a gig this week, a supper booked, and a
    /// festival that's on today. Their photos come
    /// from the bundle, handed to the image cache under made-up URLs so
    /// the cards render them through the ordinary melt.
    static let sampleCards: [Item] = {
        let day = { (n: Int) in DayString.addingDays(n, to: DayString.today()) }
        let photo = { (asset: String) -> String? in
            let url = URL(string: "cwg-sample://\(asset.lowercased())")!
            guard let image = UIImage(named: asset) else { return nil }
            ImageStore.seed(image, for: url)
            return url.absoluteString
        }
        let a = Item()
        a.kind = Item.Kind.event
        a.title = "Anish Kapoor"
        a.venue = "Hayward Gallery"
        a.area = "Southbank"
        a.category = "exhibition"
        a.startsOn = day(-40)
        a.endsOn = day(9)
        a.colorHex = "#B44A2C"
        a.imageUrl = photo("SampleAnish")
        let b = Item()
        b.kind = Item.Kind.event
        b.title = "Sessions Arts Club"
        b.venue = "Sessions Arts Club"
        b.area = "Clerkenwell"
        b.category = "restaurant"
        b.startsOn = day(6)
        b.endsOn = day(6)
        b.colorHex = "#2C7A6B"
        b.imageUrl = photo("SampleSessions")
        let c = Item()
        c.kind = Item.Kind.event
        c.title = "Open House Festival"
        c.area = "London"
        c.category = "festival"
        c.startsOn = day(0)
        c.endsOn = day(0)
        c.colorHex = "#7A4FB4"
        c.imageUrl = photo("SampleOpenHouse")
        let d = Item()
        d.kind = Item.Kind.event
        d.title = "Poliça"
        d.venue = "EartH"
        d.area = "Dalston"
        d.category = "gig"
        d.startsOn = day(4)
        d.endsOn = day(4)
        d.colorHex = "#B8892E"
        d.imageUrl = photo("SampleGig")
        return [a, d, b, c]
    }()

    /// More for the intro's strip, drifting in after the welcome four.
    /// Like them, each has a photo and a date, so every card in the row
    /// fills its three lines.
    static let stripExtras: [Item] = {
        let day = { (n: Int) in DayString.addingDays(n, to: DayString.today()) }
        let a = Item()
        a.kind = Item.Kind.event
        a.title = "Salman Toor"
        a.venue = "Courtauld Gallery"
        a.area = "Strand"
        a.category = "exhibition"
        a.startsOn = day(-20)
        a.endsOn = day(23)
        a.colorHex = "#3F6E4A"
        let url = URL(string: "cwg-sample://sampletoor")!
        if let image = UIImage(named: "SampleToor") {
            ImageStore.seed(image, for: url)
            a.imageUrl = url.absoluteString
        }
        return [a]
    }()

    /// The two links App Review looks for under a sign-in button. The
    /// pages ship in the bundle, so this works offline too.
    var legalLine: some View {
        Text("By continuing you agree to the [Terms](cwg://terms) and [Privacy Policy](cwg://privacy).")
            .font(.caption)
            .foregroundStyle(AppBackground.secondaryInk)
            .tint(AppBackground.ink.opacity(0.8))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                legal = url.host() == "terms" ? .terms : .privacy
                return .handled
            })
    }

    var signInBlock: some View {
        VStack(spacing: 14) {
            if unreachable {
                Label("Signed in, but your library couldn't be reached. Check the connection and try again.",
                      systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                quiet("Try again") {
                    Task { await openLibrary() }
                }
            } else if signingIn || (auth.signedIn && !preview && note == nil) {
                // Signed in, this page has nothing left to ask: it moves
                // on by itself to the first unanswered question.
                HStack(spacing: 10) {
                    ProgressView().tint(AppBackground.ink)
                    Text("Opening your library…")
                        .font(.subheadline)
                        .foregroundStyle(AppBackground.secondaryInk)
                }
                .frame(height: 50)
            } else if auth.signedIn, !preview {
                quiet("Try again") {
                    Task { await openLibrary() }
                }
            } else {
                SignInWithAppleButton(.continue) { request in
                    AppleSignIn.prepare(request)
                } onCompletion: { result in
                    Task { await finishApple(result) }
                }
                .signInWithAppleButtonStyle(themes.current.isLight ? .black : .white)
                .frame(height: 50)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .accessibilityHint("Uses your Apple Account")
                .disabled(!needsSignIn)
                .opacity(needsSignIn || preview ? 1 : 0.6)
                // Previewing the run (Settings, screenshots): Apple's
                // button is inert, so a tap on it just turns the page.
                .overlay {
                    if preview {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { advance() }
                    }
                }
            }

            if let note {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    func finishApple(_ result: Result<ASAuthorization, Error>) async {
        if case .failure(let error) = result, AppleSignIn.isCancellation(error) { return }
        signingIn = true
        note = nil
        do {
            // `complete` returns only after Apple's one-time name has
            // been written, so the page order below can trust `hasName`.
            try await AppleSignIn.complete(result)
            Haptics.success()
            await signedInFromFrontDoor()
        } catch {
            note = AppleSignIn.message(for: error)
        }
        signingIn = false
    }

    func openLibrary() async {
        signingIn = true
        note = nil
        await signedInFromFrontDoor()
        signingIn = false
    }

    /// The session just landed. Pull the card, the names and home, then
    /// either hand a returning person straight to the library, or carry
    /// on with only the pages the account still can't answer. If the
    /// card can't be fetched we don't know which pages those are, so
    /// stop here and offer a retry instead of asking a returning person
    /// for a name they already have.
    func signedInFromFrontDoor() async {
        unreachable = false
        await group.refresh()
        // Every account has a group (provisioned at sign-up), so no card
        // means the server wasn't reached, not that there's nothing there.
        guard group.card != nil else {
            unreachable = true
            return
        }
        await members.refresh()
        await HomeStore.shared.refresh()
        if OnboardingGate.isComplete {
            finish()
            return
        }
        if let uid = auth.userId, let existing = members.name(forUser: uid) {
            name = existing
        }
        // Straight from the front door to the first question the account
        // can't answer (a new account arrives with Apple's name, so that
        // is never the name page).
        withAnimation(ease) {
            pages = pageOrder()
            // They came by invite link: `pageOrder` put the code page first,
            // already answered, with the group looked up.
            if let code = JoinGate.pendingCode {
                together = .code
                codeDraft = JoinSheet.formatTyping(code)
                Task { await lookup(code) }
            }
            index = min(1, pages.count - 1)
        }
        if !pages.contains(.home), let home = chosenHome {
            fetchStarters(for: home)
        }
    }
}
