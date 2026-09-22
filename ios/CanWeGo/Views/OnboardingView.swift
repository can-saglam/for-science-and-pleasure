import AuthenticationServices
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UserNotifications

/// What the account already has on record. Founders and second devices
/// have both a name and a home and skip straight to the library; a brand
/// new Apple account has neither. Each missing piece is one page.
@MainActor
enum OnboardingGate {
    static var hasName: Bool {
        guard let uid = SupabaseAuth.shared.userId else { return false }
        return MembersStore.shared.name(forUser: uid)?.isEmpty == false
    }

    /// A real home on the card, or a deliberate "skip for now" from this
    /// account. Skipping is remembered per user so the first-run doesn't
    /// come back every launch; Settings can still set the city later.
    static var hasHome: Bool {
        GroupStore.shared.card?.homeLocality?.isEmpty == false
            || HomeStore.shared.isSet
            || skippedHome
    }

    static var isComplete: Bool { hasName && hasHome }

    private static var skipKey: String? {
        SupabaseAuth.shared.userId.map { "skippedHome.\($0.uuidString.lowercased())" }
    }

    static var skippedHome: Bool {
        guard let key = skipKey else { return false }
        return (UserDefaults(suiteName: SharedInbox.groupID) ?? .standard).bool(forKey: key)
    }

    static func skipHome() {
        guard let key = skipKey else { return }
        (UserDefaults(suiteName: SharedInbox.groupID) ?? .standard).set(true, forKey: key)
    }

    static func clearSkip() {
        guard let key = skipKey else { return }
        (UserDefaults(suiteName: SharedInbox.groupID) ?? .standard).removeObject(forKey: key)
    }
}

/// First run. One question a page, centred on a soft wash of the theme:
/// a welcome, Sign in with Apple, then only what the account still lacks
/// (a name if Apple didn't hand one over, a home city), the person's own
/// first save, and only after that the ask for notifications, once
/// there's a real card to be notified about.
///
/// The look is not a question: a fresh install takes a theme from the
/// system appearance, and the page that shows the first real card offers
/// a row of swatches to repaint it. The first question after sign-in is
/// who it's for: just them, or with someone. Only "with someone" leads to
/// the code, framed as whether one of them has already started; an
/// invite link skips the question and opens on the code. A join swaps
/// the first-save page for a look at what the group already has.
///
/// Someone who already has an account never sees a page past sign-in:
/// the moment the session lands and the card says name and home are on
/// record, the view hands straight over to the library. A run cut short
/// (app killed, call taken) resumes on the page it left.
///
/// Navigation lives in one bottom bar: back, dots, forward. The forward
/// control is an arrow until a step has a named outcome ("Set as home",
/// "Save it"), when it grows into a pill. Pages are reordered so the
/// home guess leads when location is already allowed. `preview` runs the
/// same pages from Settings without touching the account.
struct OnboardingView: View {
    var onFinished: () -> Void
    var preview = false

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var members = MembersStore.shared
    @State private var group = GroupStore.shared
    @State private var themes = ThemeStore.shared
    @State private var auth = SupabaseAuth.shared

    enum Page: String, Hashable { case welcome, together, home, name, code, save, joined, notify }
    @State private var pages: [Page] = [.welcome, .together, .name, .home, .save, .notify]
    @State private var index = 0

    // Sign in (the welcome page is the front door when there's no session)
    @State private var nonce = AppleSignIn.makeNonce()
    @State private var signingIn = false
    /// The session landed but the library couldn't be reached, so we
    /// can't tell what the account already has. Retry rather than guess.
    @State private var unreachable = false
    private var needsSignIn: Bool { !preview && !auth.signedIn }

    // Name
    @State private var name = ""

    // Together
    private enum Together: String { case solo, someone }
    @State private var together: Together?

    // Code
    private enum CodeChoice: String { case haveCode, first }
    @State private var codeChoice: CodeChoice?
    @State private var codeDraft = ""
    @State private var codePreview: GroupStore.JoinPreview?
    @State private var lookingUp = false
    @State private var clipboardHasText = false
    @State private var joined = false

    // Home
    @State private var guessing = false
    @State private var guessed = false
    @State private var manualHome = false
    @State private var cityDraft = ""
    @State private var matches: [HomeStore.Home] = []
    @State private var picked: HomeStore.Home?
    @State private var wider: HomeStore.Home?
    @State private var locating = false
    @State private var camera: MapCameraPosition = .region(OnboardingView.worldRegion)

    // First save
    @State private var linkDraft = ""
    @State private var linkImage: Data?
    @State private var parsing = false
    @State private var parseTask: Task<Void, Never>?
    @State private var parsed: Item?
    /// Three real things in the home city, fetched the moment a home is
    /// known so they're waiting when the save page comes up.
    @State private var starters: [ParseClient.Starter] = []
    @State private var startersTask: Task<Void, Never>?
    @State private var startersFor: String?
    @State private var startersLoading = false

    // Joined
    @State private var groupCards: [Item] = []

    // Notify
    @State private var notifyStatus: UNAuthorizationStatus = .notDetermined

    // Welcome
    @State private var legal: LegalPage?
    @State private var drift = false
    /// Welcome's card fan has been dealt (once per run of the flow).
    @State private var dealt = false
    /// A finger on one of the fan's cards: how far it's been pulled from
    /// its seat, and which one is up off the table.
    @State private var pulled: [Int: CGSize] = [:]
    @State private var lifted: Int?

    @State private var busy = false
    /// Everything that should freeze the bottom bar, not just server writes.
    private var frozen: Bool { busy || signingIn }
    @State private var note: String?
    @State private var originalTheme: AppTheme?
    @FocusState private var focus: Field?
    private enum Field { case name, code, city }

    private var page: Page { pages[min(index, pages.count - 1)] }
    private var isLast: Bool { index == pages.count - 1 }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var code: String? { GroupStore.normaliseCode(codeDraft) }

    private var ease: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.3) }

    var body: some View {
        ZStack {
            backdrop
            if page == .home { cityMap }

            GeometryReader { geo in
                ScrollView {
                    pageBody
                        .id(page)
                        .transition(.opacity)
                        .padding(.horizontal, 28)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
                // The front door is a single screen. The later pages still
                // scroll, so a keyboard can get out of the way.
                .scrollDisabled(page == .welcome)
            }
            .safeAreaPadding(.bottom, page == .welcome ? 0 : 84)

            if preview {
                closeButton
            }
        }
        .safeAreaInset(edge: .bottom) {
            if page != .welcome { bottomBar }
        }
        .foregroundStyle(AppBackground.ink)
        .tint(AppBackground.accent)
        // Scoped to theme changes only: scroll offsets and typing stay
        // untouched, but every ink/base/accent eases together.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: themes.current)
        .appColorScheme()
        .task { setUp() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshOffers() }
            if phase == .background { saveResume() }
        }
        // An invite link tapped while the first run is up.
        .onReceive(NotificationCenter.default.publisher(for: .cwgJoinCode)) { note in
            if let code = note.object as? String { takeInviteCode(code) }
        }
        .onChange(of: codeDraft) { _, new in codeTyped(new) }
        .onChange(of: page) { _, _ in
            refreshOffers()
            saveResume()
        }
        .sheet(item: $legal) { LegalSheet(page: $0) }
    }

    // MARK: Chrome

    /// The theme base with two soft pools of its accent and ink, blurred
    /// into a wash. They drift a little as the pages turn. The orbs
    /// jump to a new colour instead of interpolating — a live 90pt blur
    /// every frame of a theme ease is what made the slider hitch on
    /// device.
    private var backdrop: some View {
        ZStack {
            AppBackground.base
            orbs
                .transaction { $0.animation = nil }
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: index)
        .accessibilityHidden(true)
    }

    private var orbs: some View {
        ZStack {
            Circle()
                .fill(AppBackground.accent.opacity(themes.current.isLight ? 0.10 : 0.28))
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: -110 + CGFloat(index) * 18, y: -260 + CGFloat(index) * 24)
            Circle()
                .fill(AppBackground.ink.opacity(themes.current.isLight ? 0.08 : 0.14))
                .frame(width: 380, height: 380)
                .blur(radius: 100)
                .offset(x: 150 - CGFloat(index) * 14, y: 200 - CGFloat(index) * 20)
        }
    }

    /// The map's centre (the chosen city) sits in the top fifth of the
    /// screen, above the headline, rather than behind the copy: the map
    /// is drawn taller than the screen and lifted, then masked in screen
    /// terms so the fade lands where it always did.
    private var cityMap: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let mapHeight = h * 1.6
            let centreY = h * 0.2
            Map(position: $camera, interactionModes: []) {
                if let c = picked?.coordinate {
                    // The same pin the library map draws: accent disc,
                    // white ring, a house for home.
                    Annotation("", coordinate: c) {
                        ZStack {
                            Circle().fill(AppBackground.accent)
                            Circle().strokeBorder(.white, lineWidth: 3)
                            Image(systemName: "house.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .frame(width: geo.size.width, height: mapHeight)
            .position(x: geo.size.width / 2, y: centreY)
        }
        .opacity(0.55)
        .mask(
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.26),
                .init(color: .clear, location: 0.6),
            ], startPoint: .top, endPoint: .bottom)
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    Haptics.tap()
                    finish()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close preview")
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
    }

    /// Back · dots · forward. Everything that moves the flow lives here.
    private var bottomBar: some View {
        HStack {
            Button {
                Haptics.tap()
                back()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: Self.control, height: Self.control)
                    // Plain buttons only hit-test painted pixels; make
                    // the whole circle tappable, not just the glyph.
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .opacity(index > 0 && !frozen ? 1 : 0)
            .disabled(index == 0 || frozen)
            .accessibilityLabel("Back")
            .accessibilityHidden(index == 0)

            Spacer()

            // Until there's a session the step count isn't known (the
            // account may already answer most of it), so no dots yet.
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule()
                        .fill(AppBackground.ink.opacity(i == index ? 0.9 : 0.3))
                        .frame(width: i == index ? 20 : 6, height: 6)
                }
            }
            .animation(ease, value: index)
            .opacity(needsSignIn ? 0 : 1)
            .accessibilityElement()
            .accessibilityLabel("Step \(index + 1) of \(pages.count)")
            .accessibilityHidden(needsSignIn)

            Spacer()

            // Without a session the only way forward is the Apple button.
            forwardButton
                .opacity(gatedBySignIn ? 0 : 1)
                .disabled(gatedBySignIn)
                .accessibilityHidden(gatedBySignIn)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
    }

    private static let control: CGFloat = 56

    private var gatedBySignIn: Bool { page == .welcome && (needsSignIn || unreachable) }

    /// An arrow until a step has an outcome to name — then a pill. Same
    /// height and glass as the back button, so the pair reads as one bar.
    /// At accessibility text sizes the title can't share the bar with the
    /// dots, so the pill falls back to the arrow and VoiceOver keeps the
    /// full name.
    private var forwardButton: some View {
        let action = forwardAction
        let title = typeSize.isAccessibilitySize ? nil : action.title
        return Button {
            Haptics.tap()
            action.run()
        } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(AppBackground.base)
                } else if let title {
                    Text(title).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.85)
                }
                if !busy {
                    Image(systemName: isLast && title == nil ? "checkmark" : "chevron.right")
                        .font(.body.weight(.semibold))
                }
            }
            .padding(.horizontal, title == nil ? 0 : 22)
            .frame(minWidth: Self.control)
            .frame(height: Self.control)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppBackground.base)
        .glassEffect(.regular.tint(AppBackground.ink).interactive(), in: .capsule)
        .disabled(action.disabled || frozen)
        .opacity(action.disabled ? 0.45 : 1)
        .accessibilityLabel(action.title ?? (isLast ? "Finish" : "Continue"))
    }

    private struct Forward {
        var title: String? = nil
        var disabled = false
        var run: () -> Void
    }

    private var forwardAction: Forward {
        switch page {
        case .welcome:
            return Forward(title: "Get started", disabled: needsSignIn || unreachable, run: advance)
        case .joined:
            return Forward(run: advance)
        case .together:
            if together == nil { return Forward(disabled: true, run: {}) }
            return Forward(title: "Continue", run: advance)
        case .name:
            return Forward(disabled: trimmedName.isEmpty, run: commitName)
        case .code:
            if joined { return Forward(run: advance) }
            if codeChoice == .haveCode, let p = codePreview, p.canJoin {
                // The card above already names the group; keep the pill short.
                return Forward(title: "Join") { Task { await join() } }
            }
            if codeChoice == .first { return Forward(title: "Continue", run: advance) }
            return Forward(disabled: true, run: {})
        case .home:
            if let picked, homeVariant != .finding {
                // The headline or the ticked row already names the city.
                return Forward(title: "Set as home") { Task { await commitHome(picked) } }
            }
            return Forward(disabled: true, run: {})
        case .save:
            if parsed != nil { return Forward(title: "Save it", run: commitSave) }
            return Forward(disabled: parsing, run: advance)
        case .notify:
            // Only ask when asking will do something: the system prompt
            // shows once, for `.notDetermined`. Otherwise just finish.
            if notifyStatus == .notDetermined {
                return Forward(title: "Notify me") { Task { await askNotifications() } }
            }
            return Forward(title: "Done", run: finish)
        }
    }

    /// The system prompt comes up over this page — the one that explained
    /// it — and the run finishes once it's answered, not underneath it.
    private func askNotifications() async {
        if preview { finish(); return }
        busy = true
        await PushRegistrar.requestNow()
        busy = false
        finish()
    }

    // MARK: Pages

    @ViewBuilder
    private var pageBody: some View {
        switch page {
        case .welcome: welcomePage
        case .together: togetherPage
        case .name: namePage
        case .code: codePage
        case .home: homePage
        case .save: savePage
        case .joined: joinedPage
        case .notify: notifyPage
        }
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.displaySmallBold(38, relativeTo: .largeTitle))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lede(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One glass slab for fields and lists.
    private func slab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// Optional ways out — "Somewhere else", "Not now": a small glass pill.
    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .disabled(frozen)
    }

    /// A small glass chip: clipboard offers, location, wider-city hint.
    private func chip(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .disabled(frozen)
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Always two lines tall, so an error arriving under centered content
    /// doesn't shove the page upward. Empty, it's invisible.
    private var noteLine: some View {
        Text(note ?? " ")
            .font(.footnote)
            .foregroundStyle(note == nil ? Color.clear : AppBackground.warning)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            .accessibilityHidden(note == nil)
    }

    // MARK: Welcome

    /// The front door: the wordmark, one line, and Sign in with Apple.
    /// The same button whether this is a brand new account or a returning
    /// one, because Apple knows which and we don't until the session
    /// lands. New accounts arrive with a name, so the name page is never
    /// asked of them; returning ones skip the whole run.
    private var welcomePage: some View {
        VStack(spacing: 22) {
            cardFan
                .padding(.bottom, 18)
                // Drawn over the wordmark and button below, so a card
                // pulled down travels across the page, not under it.
                .zIndex(1)
            LogoTitle(height: 52)
            Text(auth.sessionExpired && !preview
                 ? "Your session expired.\nSign in again to keep syncing.\nEverything you saved is still here."
                 : "Save the things you want to go to.\nShare them. Get a nudge\nbefore they close.")
                .font(.displaySmallBold(23, relativeTo: .title3))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if needsSignIn || unreachable || signingIn || preview || auth.signedIn {
                signInBlock
                    .padding(.top, 12)
            }

            legalLine
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 40)
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

    /// The fan's seats, back to front: (tilt°, x, y). A cascade rather
    /// than a spread, so each card behind shows its title line above the
    /// one in front, and the front card sits straight and whole.
    private static let seats: [(Double, Double, Double)] = [
        (-4.0, -30.0, -56.0),
        (3.0, 26.0, -20.0),
        (-2.0, -22.0, 16.0),
        (0.0, 12.0, 58.0),
    ]

    /// What the app makes, before anyone is asked for anything: four
    /// cards dealt into a loose stack, then drifting a little. Real
    /// `ItemCard`s on made-up saves with bundled photos, so the look is
    /// exactly the library's — countdown badge, melt and all. Each one
    /// can be picked up and pulled about; it springs back to its seat.
    private var cardFan: some View {
        ZStack {
            ForEach(Array(Self.sampleCards.enumerated()), id: \.offset) { i, item in
                let seat = Self.seats[i]
                let front = i == Self.seats.count - 1
                let sway = front ? 0.0 : (i.isMultiple(of: 2) ? 1.0 : -1.0)
                let pull = pulled[i] ?? .zero
                let held = lifted == i
                ItemCard(item: item)
                    .frame(width: 280)
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
                    .zIndex(Double(i))
                    // Dealt back to front, a beat apart.
                    .animation(
                        reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.26).delay(Double(i) * 0.13),
                        value: dealt
                    )
                    .animation(reduceMotion ? nil : .spring(duration: 0.3), value: held)
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
        .frame(height: 250)
        .animation(reduceMotion ? nil : .easeInOut(duration: 5).repeatForever(autoreverses: true), value: drift)
        .accessibilityHidden(true)
    }

    /// Four saves that read like a real week, back to front: an
    /// exhibition with days left, a gig this week, a place to eat, and a
    /// festival that's on today. Their photos come
    /// from the bundle, handed to the image cache under made-up URLs so
    /// the cards render them through the ordinary melt.
    private static let sampleCards: [Item] = {
        let day = { (n: Int) in DayString.addingDays(n, to: DayString.today()) }
        let photo = { (asset: String) -> String? in
            let url = URL(string: "cwg-sample://\(asset.lowercased())")!
            guard let image = UIImage(named: asset) else { return nil }
            ImageStore.seed(image, for: url)
            return url.absoluteString
        }
        let a = Item()
        a.kind = Item.Kind.event
        a.title = "Anish Kapoor at Hayward Gallery"
        a.venue = "Hayward Gallery"
        a.area = "Southbank"
        a.category = "exhibition"
        a.startsOn = day(-40)
        a.endsOn = day(9)
        a.colorHex = "#B44A2C"
        a.imageUrl = photo("SampleAnish")
        let b = Item()
        b.kind = Item.Kind.place
        b.title = "Sessions Arts Club"
        b.venue = "Sessions Arts Club"
        b.area = "Clerkenwell"
        b.category = "restaurant"
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

    /// The two links App Review looks for under a sign-in button. The
    /// pages ship in the bundle, so this works offline too.
    private var legalLine: some View {
        Text("By continuing you agree to the [Terms](cwg://terms) and [Privacy Policy](cwg://privacy).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .tint(AppBackground.ink.opacity(0.8))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                legal = url.host() == "terms" ? .terms : .privacy
                return .handled
            })
    }

    private var signInBlock: some View {
        VStack(spacing: 14) {
            if unreachable {
                Label("Signed in, but your library couldn't be reached. Check the connection and try again.",
                      systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                quiet("Try again") {
                    Task {
                        signingIn = true
                        await signedInFromFrontDoor()
                        signingIn = false
                    }
                }
            } else if signingIn {
                HStack(spacing: 10) {
                    ProgressView().tint(AppBackground.ink)
                    Text("Opening your library…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 50)
            } else if auth.signedIn, !preview {
                // A relaunch after sign-in used to hide Apple's button
                // and leave no way off this page. Continue picks up
                // the first unanswered question.
                Button {
                    Haptics.tap()
                    Task {
                        signingIn = true
                        await signedInFromFrontDoor()
                        signingIn = false
                    }
                } label: {
                    Text("Continue")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.glass)
            } else {
                SignInWithAppleButton(.continue) { request in
                    nonce = AppleSignIn.makeNonce()
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = AppleSignIn.sha256(nonce)
                } onCompletion: { result in
                    Task { await finishApple(result) }
                }
                .signInWithAppleButtonStyle(themes.current.isLight ? .black : .white)
                .frame(height: 50)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .accessibilityHint("Uses your Apple Account")
                .disabled(!needsSignIn)
                .opacity(needsSignIn ? 1 : 0.6)
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

    private func finishApple(_ result: Result<ASAuthorization, Error>) async {
        if case .failure(let error) = result, AppleSignIn.isCancellation(error) { return }
        signingIn = true
        note = nil
        do {
            // `complete` returns only after Apple's one-time name has
            // been written, so the page order below can trust `hasName`.
            try await AppleSignIn.complete(result, nonce: nonce)
            Haptics.success()
            await signedInFromFrontDoor()
        } catch {
            note = AppleSignIn.message(for: error)
        }
        signingIn = false
    }

    /// The session just landed. Pull the card, the names and home, then
    /// either hand a returning person straight to the library, or carry
    /// on with only the pages the account still can't answer. If the
    /// card can't be fetched we don't know which pages those are, so
    /// stop here and offer a retry instead of asking a returning person
    /// for a name they already have.
    private func signedInFromFrontDoor() async {
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
                together = .someone
                codeChoice = .haveCode
                codeDraft = JoinSheet.formatTyping(code)
                Task { await lookup(code) }
            }
            index = min(1, pages.count - 1)
        }
        if !pages.contains(.home), let home = chosenHome {
            fetchStarters(for: home)
        }
    }

    // MARK: Name

    private var namePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("What should we\ncall you?")
            lede("First name is plenty. It's how you show up on the things you save: “Added by \(trimmedName.isEmpty ? "you" : trimmedName)”.")

            slab {
                TextField("", text: $name, prompt: AppBackground.fieldPrompt("Your first name"))
                    .font(.title3)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .name)
                    .foregroundStyle(AppBackground.ink)
                    .onSubmit(commitName)
                    .onChange(of: name) { _, new in
                        note = nil
                        if new.unicodeScalars.count > 24 {
                            name = String(String.UnicodeScalarView(new.unicodeScalars.prefix(24)))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
            }

            noteLine
        }
    }

    private func commitName() {
        guard !trimmedName.isEmpty, !busy else { return }
        if preview { advance(); return }
        busy = true
        note = nil
        Task {
            // Always unlocks, including when the request is cancelled, so
            // a failed attempt can't leave the forward button dead.
            defer { busy = false }
            if let error = await members.setDisplayName(trimmedName) {
                note = error
                return
            }
            advance()
        }
    }

    // MARK: Theme

    /// The look is chosen for them once, from the system appearance, and
    /// only on a fresh install — never over a choice already on disk.
    private func preselectTheme() {
        guard !preview, !themes.hasStoredChoice else { return }
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
        let dark = (screen?.traitCollection.userInterfaceStyle ?? .dark) != .light
        themes.select(dark ? .midnight : .oat)
    }

    /// A row of swatches under the first real card: tap one and the card,
    /// the page and the rest of the app repaint. Lives on the two pages
    /// that show real cards, so the choice is made looking at the thing
    /// it changes.
    private var themeSwatches: some View {
        ThemeSwatchRow { option in
            // `preview` paints, `commit` writes: same pair the settings
            // picker uses, without the window snapshot `select` takes.
            themes.preview(option)
            themes.commit()
        }
        .padding(.top, 4)
    }

    // MARK: Together

    private var togetherPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("Just you, or\nwith someone?")
            lede("Either works, and you can change it later in Settings.")

            choiceTile("person.fill", "Just me",
                       "Your own library of things you want to go to.",
                       selected: together == .solo) { chooseTogether(.solo) }
                .disabled(joined)
            choiceTile("person.2.fill", "With someone",
                       "A partner, a friend, housemates: one shared library you all add to.",
                       selected: together == .someone) { chooseTogether(.someone) }
        }
    }

    /// One answer to a page's question: a glass slab with a radio mark.
    /// Picking only selects; the bottom bar's Continue turns the page.
    private func choiceTile(
        _ icon: String, _ title: String, _ detail: String,
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                row(icon, title, detail)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(selected ? .semibold : .regular))
                    .foregroundStyle(AppBackground.ink.opacity(selected ? 1 : 0.4))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(
            selected ? .regular.tint(AppBackground.accent.opacity(0.3)).interactive() : .regular.interactive(),
            in: .rect(cornerRadius: 18)
        )
        .disabled(frozen)
        .animation(ease, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "With someone" puts the code page next; "Just me" takes it out.
    private func chooseTogether(_ choice: Together) {
        withAnimation(ease) {
            together = choice
            if choice == .someone {
                if !pages.contains(.code), let i = pages.firstIndex(of: .together) {
                    pages.insert(.code, at: i + 1)
                }
            } else if let i = pages.firstIndex(of: .code) {
                pages.remove(at: i)
            }
        }
    }

    // MARK: Code

    private var codePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("Has one of you\nalready started?")
            lede("One of you starts the library, then invites the other with a code from Settings. After that it's shared: you both see, add and edit everything.")

            choiceTile("envelope.open.fill", "Yes, they sent me a code",
                       "Type or paste it in. Codes look like KV7-P2M.",
                       selected: codeChoice == .haveCode, action: pickHaveCode)
                .disabled(joined)

            if codeChoice == .haveCode {
                codeEntry
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !joined {
                choiceTile("sparkles", "No, I'll start it",
                           "Set up your library now, then invite them from Settings when you're ready.",
                           selected: codeChoice == .first, action: pickFirst)
            }

            noteLine
        }
        .animation(ease, value: codePreview?.status)
        .animation(ease, value: codeChoice)
    }

    private func pickHaveCode() {
        note = nil
        codeChoice = .haveCode
        refreshOffers()
        if codeDraft.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus = .code }
        }
    }

    private func pickFirst() {
        focus = nil
        note = nil
        codeChoice = .first
    }

    /// The field, the paste offer and the group it opens — shown once
    /// they've said they have a code.
    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 18) {
            slab {
                // Formatting happens in the binding's setter, in the same
                // pass as the keystroke, so fast typing never lands on a
                // draft that's about to be rewritten (and lose a letter).
                TextField(
                    "",
                    text: Binding(
                        get: { codeDraft },
                        set: { codeDraft = JoinSheet.formatTyping($0) }
                    ),
                    prompt: AppBackground.fieldPrompt("KV7-P2M")
                )
                    .accessibilityLabel("Invite code")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .foregroundStyle(AppBackground.ink)
                    .focused($focus, equals: .code)
                    .padding(.vertical, 16)
                    .overlay(alignment: .trailing) {
                        if lookingUp {
                            ProgressView().controlSize(.small).padding(.trailing, 18)
                        }
                    }
                    .disabled(joined)
            }

            if clipboardHasText, codeDraft.isEmpty, !joined {
                chip("Paste the code you were sent", icon: "doc.on.clipboard") {
                    // Read only now, on the tap: reading earlier would put
                    // up the system paste prompt the moment the page opened.
                    if let s = UIPasteboard.general.string, let c = GroupStore.normaliseCode(s) {
                        codeDraft = JoinSheet.formatTyping(c)
                    } else {
                        clipboardHasText = false
                        note = "Nothing that looks like a code on the clipboard."
                    }
                }
            }

            if let p = codePreview {
                codePreviewCard(p)
            }

            if preview, codePreview != nil, !joined {
                lede("Preview: any code opens Joyce's library. Nothing is joined for real.")
            }
        }
    }

    private func codePreviewCard(_ p: GroupStore.JoinPreview) -> some View {
        slab {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Text(joined ? "You're in with" : "You'll be joining")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let home = p.homeLocality, !home.isEmpty {
                        homeBadge(home)
                    }
                }
                // One row per person: a group holds at most four, so the
                // list never outgrows the card.
                if let members = p.members, !members.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(members.prefix(4).enumerated()), id: \.offset) { i, m in
                            if i > 0 {
                                Divider().overlay(AppBackground.wash(0.10)).padding(.leading, 50)
                            }
                            memberRow(m, invitedYou: m.displayName != nil && m.displayName == p.inviter)
                        }
                    }
                }
                if joined {
                    Label("You're in", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                } else if !p.canJoin {
                    Text(p.message())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private func memberRow(_ m: GroupStore.JoinPreview.PreviewMember, invitedYou: Bool) -> some View {
        HStack(spacing: 12) {
            Text(m.initial)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AvatarColour.initial(m.avatarColour))
                .frame(width: 38, height: 38)
                .background(AvatarColour.color(m.avatarColour), in: .circle)
                .accessibilityHidden(true)
            Text(m.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if invitedYou {
                Text("Invited you")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(AppBackground.wash(0.08), in: .capsule)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// The group's home as a small pill: an ink disc with the house cut
    /// out of it, then the city.
    private func homeBadge(_ city: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "house.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppBackground.base)
                .frame(width: 20, height: 20)
                .background(AppBackground.ink, in: .circle)
            Text(city)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 11)
        .padding(.vertical, 4)
        .background(AppBackground.wash(0.08), in: .capsule)
        .overlay(Capsule().strokeBorder(AppBackground.wash(0.14), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Home: \(city)")
    }

    private func codeTyped(_ raw: String) {
        // The paste chip and programmatic sets bypass the binding.
        let formatted = JoinSheet.formatTyping(raw)
        if formatted != raw { codeDraft = formatted; return }
        codePreview = nil
        note = nil
        guard let code else { return }
        Task { await lookup(code) }
    }

    /// In the preview any well-formed code "belongs" to Joyce, so the
    /// join flow can be walked end to end without a second account.
    private static let previewInvite = GroupStore.JoinPreview(
        status: "ok",
        inviter: "Joyce",
        name: "Joyce's library",
        homeLocality: "London",
        capacity: 2,
        isPlus: false,
        members: [.init(displayName: "Joyce", avatarColour: "coral")]
    )

    private func lookup(_ code: String) async {
        lookingUp = true
        defer { lookingUp = false }
        do {
            if preview {
                try await Task.sleep(for: .milliseconds(600))
                guard self.code == code else { return }
                codePreview = Self.previewInvite
                Haptics.tap()
                return
            }
            let p = try await group.preview(code: code)
            guard self.code == code else { return }
            codePreview = p
            Haptics.tap()
        } catch {
            guard self.code == code else { return }
            note = "Couldn't look that code up. Check the connection and try again."
        }
    }

    private func join() async {
        guard let code else { return }
        if preview {
            // Pretend: the same state changes a real join produces, none
            // of the network. Their group already has a home, so that
            // page drops out exactly as it would for real.
            focus = nil
            Haptics.success()
            joined = true
            note = nil
            drop(.home)
            showJoined()
            return
        }
        busy = true
        defer { busy = false }
        focus = nil
        do {
            guard await SupabaseSync.flush(context: context) else {
                note = "Couldn't sync your latest edits. Try again once you're back online."
                return
            }
            try await group.join(code: code, keepCopy: false)
            let landed = await SupabaseSync.replaceLibrary(context: context)
            guard landed else {
                note = "You're in the group, but this phone couldn't refresh the library. Open the app again when you're online."
                return
            }
            await members.refresh()
            // Their group's home is now ours: the clock on every card
            // should tick in that city from the very first save.
            await HomeStore.shared.refresh()
            Haptics.success()
            joined = true
            note = nil
            JoinGate.pendingCode = nil
            // Their group already knows where home is.
            if OnboardingGate.hasHome { drop(.home) }
            showJoined()
        } catch {
            note = "Couldn't join. \(SyncProblem(error).message)"
        }
    }

    /// A join answers "what's the first thing you'd go to?" better than
    /// any typed link could: the library is already full of their saves.
    /// The save page gives way to a look at it.
    private func showJoined() {
        let all = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        groupCards = all
            .filter { $0.status == Item.Status.saved && $0.deletedAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
        withAnimation(ease) {
            if let i = pages.firstIndex(of: .save) {
                pages[i] = .joined
            } else if !pages.contains(.joined), let n = pages.firstIndex(of: .notify) {
                pages.insert(.joined, at: n)
            }
        }
    }

    // MARK: Joined

    private var joinedName: String {
        codePreview?.inviter ?? codePreview?.name ?? "they"
    }

    private var joinedPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("You're in.")
            if groupCards.isEmpty {
                lede("Nothing saved yet — you'll be the first. Anything either of you shares into the app lands here for both of you.")
            } else {
                lede("Some of what \(joinedName) has saved so far. It's your library now too: edit anything, add anything.")
                ForEach(groupCards.prefix(3)) { item in
                    ItemCard(item: item)
                }
                if groupCards.count > 3 {
                    Text("…and \(groupCards.count - 3) more in the library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            themeSwatches
        }
    }

    // MARK: Home

    private enum HomeVariant { case finding, confirm, manual }
    private var homeVariant: HomeVariant {
        if guessing, !guessSlow { return .finding }
        if guessed, !manualHome, picked != nil { return .confirm }
        return .manual
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch homeVariant {
            case .finding: headline("Finding\nyour city…")
            case .confirm: headline("Looks like\n\(picked?.locality ?? ""), right?")
            case .manual: headline("Where's home?")
            }
            lede("The city you go out in. It sets the clock on your cards and where the map opens.")

            switch homeVariant {
            case .finding:
                ProgressView().controlSize(.small).padding(.vertical, 8)

            case .confirm:
                widerHint
                quiet("Somewhere else") {
                    manualHome = true
                    picked = nil
                    wider = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus = .city }
                }

            case .manual:
                slab {
                    HStack(spacing: 10) {
                        TextField("", text: $cityDraft, prompt: AppBackground.fieldPrompt("City"))
                            .font(.title3)
                            .foregroundStyle(AppBackground.ink)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .focused($focus, equals: .city)
                            .onSubmit { Task { await lookupCity() } }
                        if locating {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                Haptics.tap()
                                Task { await lookupCity() }
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.body.weight(.semibold))
                            }
                            .disabled(cityDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityLabel("Look up")
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                }

                if !matches.isEmpty {
                    slab {
                        VStack(spacing: 0) {
                            ForEach(matches, id: \.self) { m in
                                Button {
                                    Haptics.tap()
                                    pick(m)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(m.locality).font(.body.weight(.medium))
                                            Text(m.country).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if picked == m {
                                            Image(systemName: "checkmark").font(.body.weight(.semibold))
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                                if m != matches.last {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                    }
                }

                widerHint

                HStack(spacing: 8) {
                    if !LocationStore.shared.denied, matches.isEmpty {
                        chip(locating ? "Locating…" : "Use my location", icon: "location") {
                            Task { await useLocation() }
                        }
                        .disabled(locating)
                    }
                    // Never a dead end: offline, or a city the geocoder
                    // can't place, shouldn't hold the whole first run.
                    if picked == nil {
                        quiet("Skip for now") { skipHome() }
                    }
                }
            }

            noteLine
        }
        .animation(ease, value: homeVariant)
        .animation(ease, value: matches)
    }

    /// Carries on without a home. Remembered per account so the gate
    /// doesn't bring the page back every launch; Settings can set it.
    private func skipHome() {
        if !preview { OnboardingGate.skipHome() }
        advance()
    }

    @ViewBuilder
    private var widerHint: some View {
        if let wider, let picked, wider != picked {
            chip("\(picked.locality) is part of \(wider.locality). Use \(wider.locality) instead", icon: "arrow.up.left.and.arrow.down.right") {
                pick(wider)
            }
        }
    }

    private func pick(_ home: HomeStore.Home) {
        picked = home
        wider = HomeStore.widerCity(for: home)
        note = nil
        frame(home)
        focus = nil
        // Start the city search now, not on "Set as home" — a cold miss
        // is a model call and the name page is the wait.
        fetchStarters(for: home)
    }

    private func frame(_ home: HomeStore.Home) {
        guard let c = home.coordinate else { return }
        let isLondon = home.locality.compare("London", options: .caseInsensitive) == .orderedSame
        let span: CLLocationDistance = isLondon ? 60_000 : 22_000
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.0)) {
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: span, longitudinalMeters: span))
        }
    }

    /// Location was already allowed — try to name the city before asking.
    /// A cold GPS start can take a while, and this runs behind the
    /// welcome page and the sign-in anyway, so give it a real chance.
    private func guessHome() async {
        guessing = true
        defer { guessing = false; guessSlow = false }
        LocationStore.shared.refresh()
        // Nobody should watch a spinner for long: after a few seconds
        // the page opens the manual field while the guess keeps going.
        let slow = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { guessSlow = true }
        }
        defer { slow.cancel() }
        guard let loc = await awaitFix(seconds: 12) else { return }
        await reverse(loc)
        // A late guess only lands if they haven't started typing.
        guard let first = matches.first, picked == nil, cityDraft.isEmpty else { return }
        pick(first)
        guessed = true
        manualHome = false
    }

    @State private var guessSlow = false

    /// The chip: may raise the system permission prompt first. People
    /// read prompts at their own pace, so wait on the *answer*, then on
    /// the fix; only a denial or a genuinely missing fix gives up.
    private func useLocation() async {
        locating = true
        defer { locating = false }
        note = nil
        LocationStore.shared.ask()
        if LocationStore.shared.authorization == .notDetermined {
            _ = await awaitAuthorizationAnswer(seconds: 90)
        }
        if LocationStore.shared.denied {
            note = "Location is off for this app. Type your city instead."
            return
        }
        if let loc = await awaitFix(seconds: 15) {
            await reverse(loc)
            if let first = matches.first { pick(first) }
            return
        }
        note = "Couldn't get a fix. Type your city instead."
    }

    /// Polls for a location until one arrives or `seconds` pass.
    private func awaitFix(seconds: Double) async -> CLLocation? {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if let loc = LocationStore.shared.location { return loc }
            if LocationStore.shared.denied { return nil }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return LocationStore.shared.location
    }

    /// Waits for the permission prompt to be answered either way.
    private func awaitAuthorizationAnswer(seconds: Double) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if LocationStore.shared.authorization != .notDetermined { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    private func reverse(_ location: CLLocation) async {
        do {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                note = "Couldn't read that location."
                return
            }
            present(try await request.mapItems)
        } catch {
            note = "Couldn't read that location. Type your city instead."
        }
    }

    private func lookupCity() async {
        let query = cityDraft.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        locating = true
        defer { locating = false }
        note = nil
        matches = []
        picked = nil
        wider = nil
        do {
            guard let request = MKGeocodingRequest(addressString: query) else {
                note = "Couldn't look that up."
                return
            }
            present(try await request.mapItems)
            if matches.isEmpty {
                note = "No city matched “\(query)”. Try the city name on its own."
            } else if matches.count == 1, let only = matches.first {
                pick(only)
            }
        } catch {
            note = "Couldn't look that up. Check the connection and try again."
        }
    }

    private func present(_ items: [MKMapItem]) {
        var seen = Set<String>()
        var homes: [HomeStore.Home] = []
        for item in items {
            guard let home = HomeStore.from(item.placemark) else { continue }
            let key = "\(home.locality)|\(home.country)"
            if seen.insert(key).inserted { homes.append(home) }
        }
        matches = Array(homes.prefix(5))
    }

    private func commitHome(_ home: HomeStore.Home) async {
        fetchStarters(for: home)
        if preview { advance(); return }
        busy = true
        defer { busy = false }
        if let error = await HomeStore.shared.save(home) {
            note = error
            return
        }
        Haptics.success()
        advance()
    }

    /// Ask the server for the city's three chips now, so they're on the
    /// save page by the time it comes up. One in-flight fetch per city;
    /// an empty result (cold miss still running, or a failed call) is
    /// retried when the save page appears.
    private func fetchStarters(for home: HomeStore.Home) {
        let country = home.country.isEmpty ? home.locality : home.country
        let key = "\(home.locality)|\(country)"
        if startersFor == key, startersLoading || !starters.isEmpty { return }
        startersFor = key
        starters = []
        startersLoading = true
        startersTask?.cancel()
        startersTask = Task {
            defer {
                if !Task.isCancelled, startersFor == key { startersLoading = false }
            }
            let found = try? await ParseClient.starters(locality: home.locality, country: country)
            guard !Task.isCancelled, startersFor == key else { return }
            withAnimation(ease) { starters = found ?? [] }
        }
    }

    // MARK: First save

    /// Instant chips while the server answers — and the fallback if it
    /// doesn't. Same cities as `_shared/starters.ts`.
    private static let cityStarters: [String: [ParseClient.Starter]] = [
        "london": [
            .init(title: "Photographers' Gallery", url: "https://thephotographersgallery.org.uk", kind: "place"),
            .init(title: "Sessions Arts Club", url: "https://sessionsartsclub.com", kind: "place"),
            .init(title: "Roundhouse", url: "https://www.roundhouse.org.uk", kind: "place"),
        ],
        "singapore": [
            .init(title: "National Gallery", url: "https://www.nationalgallery.sg", kind: "place"),
            .init(title: "Atlas", url: "https://www.atlasbar.sg", kind: "place"),
            .init(title: "The Projector", url: "https://theprojector.sg", kind: "place"),
        ],
        "lisbon": [
            .init(title: "MAAT", url: "https://www.maat.pt", kind: "place"),
            .init(title: "Cervejaria Ramiro", url: "https://www.cervejariaramiro.pt", kind: "place"),
            .init(title: "Lux Frágil", url: "https://www.luxfragil.com", kind: "place"),
        ],
        "paris": [
            .init(title: "Musée d'Orsay", url: "https://www.musee-orsay.fr", kind: "place"),
            .init(title: "Septime", url: "https://www.septime-charonne.fr", kind: "place"),
            .init(title: "Centre Pompidou", url: "https://www.centrepompidou.fr", kind: "place"),
        ],
        "new york": [
            .init(title: "MoMA", url: "https://www.moma.org", kind: "place"),
            .init(title: "Katz's Delicatessen", url: "https://www.katzsdelicatessen.com", kind: "place"),
            .init(title: "Film Forum", url: "https://www.filmforum.org", kind: "place"),
        ],
        "tokyo": [
            .init(title: "Mori Art Museum", url: "https://www.mori.art.museum", kind: "place"),
            .init(title: "teamLab Planets", url: "https://www.teamlab.art/e/planets/", kind: "place"),
            .init(title: "Unit", url: "https://www.unit-tokyo.com", kind: "place"),
        ],
        "hong kong": [
            .init(title: "M+", url: "https://www.mplus.org.hk", kind: "place"),
            .init(title: "Yardbird", url: "https://www.yardbirdrestaurant.com", kind: "place"),
            .init(title: "Broadway Cinematheque", url: "https://www.cinema.com.hk", kind: "place"),
        ],
        "san francisco": [
            .init(title: "SFMOMA", url: "https://www.sfmoma.org", kind: "place"),
            .init(title: "Zuni Café", url: "https://zunicafe.com", kind: "place"),
            .init(title: "Roxie Theater", url: "https://roxie.com", kind: "place"),
        ],
        "los angeles": [
            .init(title: "The Broad", url: "https://www.thebroad.org", kind: "place"),
            .init(title: "République", url: "https://republiquela.com", kind: "place"),
            .init(title: "New Beverly Cinema", url: "https://thenewbev.com", kind: "place"),
        ],
    ]

    /// Only a home that was actually chosen counts; `HomeStore.home` falls
    /// back to London when nothing is set, and that must not show London
    /// starters to someone in Lisbon who hasn't picked yet.
    private var chosenHome: HomeStore.Home? {
        picked ?? (HomeStore.shared.isSet ? HomeStore.shared.home : nil)
    }

    /// The chips: the city's own from the server, then the built-in set
    /// for that city (so Singapore isn't a blank wait), nothing if we
    /// have no home and no fallback.
    private var starterChips: [ParseClient.Starter] {
        if !starters.isEmpty { return starters }
        return Self.fallbackStarters(for: chosenHome)
    }

    private static func fallbackStarters(for home: HomeStore.Home?) -> [ParseClient.Starter] {
        guard let home else { return [] }
        let aliases = [
            "new york city": "new york", "nyc": "new york",
            "sf": "san francisco", "la": "los angeles",
            "republic of singapore": "singapore",
        ]
        let city = aliases[home.locality.lowercased()] ?? home.locality.lowercased()
        let country = aliases[home.country.lowercased()] ?? home.country.lowercased()
        if let chips = cityStarters[city] { return chips }
        if ["singapore", "hong kong", "monaco"].contains(country) {
            return cityStarters[country] ?? []
        }
        return []
    }

    /// The city the chips are actually about — the one they were fetched
    /// for, which can differ from a guess that landed since.
    private var starterCity: String? {
        if !starters.isEmpty { return startersFor?.split(separator: "|").first.map(String.init) }
        return chosenHome?.locality
    }

    private var savePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let parsed {
                headline("There it is.")
                lede("A real save. Everything you add lands in the library looking like this.")
                ItemCard(item: parsed)
                quiet("Try another") {
                    self.parsed = nil
                    linkDraft = ""
                    linkImage = nil
                    note = nil
                    refreshOffers()
                }
                themeSwatches
            } else {
                headline("What's the first thing\nyou'd go to?")
                lede("Paste a link or just name it: a gig, a show, somewhere to eat. We look it up and make the card. Or skip and add one later.")

                if parsing {
                    formingCard
                        .transition(.opacity)
                    // Some pages take a while to read; nobody has to wait.
                    quiet("Skip this") {
                        parseTask?.cancel()
                        parsing = false
                        advance()
                    }
                } else {
                    // The same composer as the app's add sheet, so the
                    // first save teaches the real thing.
                    Composer(text: $linkDraft, imageJPEG: $linkImage, busy: false) {
                        startParse()
                    }

                    if linkDraft.isEmpty, linkImage == nil {
                        if !starterChips.isEmpty, let city = starterCity {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Or try one of these in \(city)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal) {
                                    HStack(spacing: 8) {
                                        ForEach(starterChips) { s in
                                            Button {
                                                Haptics.tap()
                                                linkDraft = s.url
                                                startParse()
                                            } label: {
                                                Label(s.title, systemImage: s.kind == "event" ? "ticket" : "mappin.and.ellipse")
                                                    .font(.footnote.weight(.medium))
                                                    .lineLimit(1)
                                            }
                                            .buttonStyle(.glass)
                                        }
                                    }
                                }
                                .scrollIndicators(.hidden)
                                .scrollClipDisabled()
                            }
                            .transition(.opacity)
                        } else if startersLoading, let city = chosenHome?.locality {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Looking up a few things in \(city)…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .transition(.opacity)
                        }
                    }

                    // The share-sheet lesson isn't here: it arrives as a
                    // tip in the library on the second launch (ShareTip).
                }
            }

            noteLine
        }
        .animation(ease, value: parsing)
        .animation(ease, value: parsed?.id)
        .animation(ease, value: starterChips)
        .animation(ease, value: startersLoading)
        .onAppear {
            if let home = chosenHome { fetchStarters(for: home) }
        }
    }

    /// The card, forming. Sits exactly where the field was and where the
    /// real card will land: what they typed becomes the title, the lines
    /// the parser will fill sit beneath as shimmering placeholders, and
    /// the status copy runs along the bottom.
    private var formingCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(formingTitle)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            SkeletonLine(width: 172)
            SkeletonLine(width: 104)
            HStack(spacing: 8) {
                SmallRing()
                ParsingPhrases(text: linkDraft, hasImage: linkImage != nil)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { Shimmer(highlight: .white.opacity(themes.current.isLight ? 0.55 : 0.10)) }
        .clipShape(.rect(cornerRadius: 18))
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Making the card for \(formingTitle)")
    }

    /// A link shows as its site while we read it; a name shows as itself;
    /// a photo on its own is called that.
    private var formingTitle: String {
        if let host = linkURL?.host() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return query ?? (linkImage != nil ? "Your photo" : "")
    }

    /// Whatever they typed, trimmed: a link or a plain name. The parser
    /// takes both, same as the capture sheet.
    private var query: String? {
        let raw = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// True only when the draft is a real link; the paste chip uses this
    /// to decide whether the clipboard was worth offering.
    private var linkURL: URL? {
        guard let raw = query else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: withScheme), url.host() != nil, !raw.contains(" ") else { return nil }
        return url
    }

    /// One parse at a time, and cancellable from "Skip this".
    private func startParse() {
        parseTask?.cancel()
        parseTask = Task { await parse() }
    }

    private func parse() async {
        guard query != nil || linkImage != nil else { return }
        focus = nil
        parsing = true
        note = nil
        defer { if !Task.isCancelled { parsing = false } }
        do {
            let card = try await ParseClient.parse(text: query, imageJPEG: linkImage)
            // Skipped meanwhile: the page has moved on; drop the result.
            guard !Task.isCancelled else { return }
            let item = Item()
            item.kind = card.kind
            item.title = card.title
            item.summary = card.summary
            item.venue = card.venue
            item.area = card.area
            item.address = card.address
            item.category = card.category
            item.price = card.price
            item.startsOn = card.starts_on
            item.endsOn = card.ends_on
            item.url = card.url
            item.lat = card.lat
            item.lng = card.lng
            item.colorHex = card.color
            item.imageUrl = card.image_url
            item.source = card.source
            parsed = item
            Haptics.success()
        } catch {
            guard !Task.isCancelled else { return }
            let why = (error as? ParseClient.ParseError)?.errorDescription ?? SyncProblem(error).message
            note = "\(why) Try something else, or carry on and add one later."
        }
    }

    private func commitSave() {
        guard let item = parsed else { return }
        if preview { advance(); return }
        item.createdAt = .now
        item.updatedAt = .now
        item.stampAuthor()
        context.insert(item)
        do {
            try context.save()
        } catch {
            note = "Couldn't save that. Try again."
            return
        }
        Haptics.success()
        Task { await SupabaseSync.announceSave(item) }
        advance()
    }

    // MARK: Notify

    private var partnerName: String? {
        guard !preview, let card = group.card, card.members.count > 1 else {
            return joined ? codePreview?.members?.first?.name : nil
        }
        let me = SupabaseAuth.shared.userId
        return card.members.first { $0.userId != me }?.name
    }

    private var notifyPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("Want a nudge before\nit closes?")
            lede(partnerName == nil
                 ? "Ask for a reminder on anything you save and one ping arrives before it ends. Never a nag, nothing else. Yours to change any time in iOS Settings."
                 : "Ask for a reminder on anything you save and one ping arrives before it ends, plus one when \(partnerName ?? "someone") adds to the library. Never a nag. Yours to change any time in iOS Settings.")

            mockBanner

            switch notifyStatus {
            case .denied:
                // Asking again would do nothing; iOS only prompts once.
                // Say so, and point at the switch that actually works.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) {
                        row("bell.slash", "Notifications are off for this app",
                            "Turn them on in iOS Settings and pings arrive from then on.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(AppBackground.wash(0.12), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            case .authorized, .provisional, .ephemeral:
                Label("Already on. Nothing more to do.", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
            default:
                quiet("Not now") {
                    if !preview { PushRegistrar.declinePrime() }
                    finish()
                }
            }
        }
        .task {
            // Preview shows the ask as a new person would see it.
            guard !preview else { return }
            notifyStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    /// The example ping is a reminder, the one kind everyone can get on
    /// their own: the save's title as the notification title, the
    /// server's own wording as the body (`reminderBody`, "Closes in a
    /// week"). Their real first save stands in when it's an event with
    /// an end; a believable exhibition otherwise.
    private var bannerTitle: String {
        if let parsed, parsed.isEvent, parsed.endsOn != nil { return parsed.title }
        return "Anish Kapoor at Hayward Gallery"
    }
    private var bannerLine: String { "Closes in a week" }

    /// What the ping will look like, laid out the way iOS lays one out: the
    /// app icon, the title in bold with the time opposite, and the body.
    /// Nothing iOS wouldn't show.
    private var mockBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            // The home-screen icon for this theme. Icon sets can't be
            // loaded as images, so a small copy of each ships as a
            // regular asset (IconPreview*).
            Image(themes.current.iconPreviewName)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(.rect(cornerRadius: 8.5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bannerTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("now").font(.caption).foregroundStyle(.secondary)
                }
                Text(bannerLine)
                    .font(.subheadline)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example notification: \(bannerTitle). \(bannerLine)")
    }

    // MARK: Flow

    /// The code from an invite link goes into the field now; the page it
    /// belongs to comes up as soon as there's a session to join with.
    private func takeInviteCode(_ code: String) {
        codeDraft = JoinSheet.formatTyping(code)
        guard !needsSignIn else { return }
        // A link answers both questions: with someone, and they've started.
        together = .someone
        codeChoice = .haveCode
        if !pages.contains(.code) {
            withAnimation(ease) { pages.insert(.code, at: min(max(index, 1), pages.count)) }
        }
        if let i = pages.firstIndex(of: .code) {
            withAnimation(ease) { index = i }
            note = nil
            Task { await lookup(code) }
        }
    }

    private func setUp() {
        if preview { originalTheme = themes.current }
        if !preview, let code = JoinGate.pendingCode {
            codeDraft = JoinSheet.formatTyping(code)
            together = .someone
            codeChoice = .haveCode
        }
        if !preview, let uid = SupabaseAuth.shared.userId, let existing = members.name(forUser: uid) {
            name = existing
        }
        preselectTheme()
        // Before sign-in the account is unknown, so the run is the full
        // one; `signedInFromFrontDoor` trims it once the card is in.
        pages = pageOrder()
        // Preview only: `CWG_ONBOARDING_PAGE=home` (any Page name) opens
        // straight on that page, for checking one screen at a time.
        if preview, let raw = ProcessInfo.processInfo.environment["CWG_ONBOARDING_PAGE"],
           let i = pages.firstIndex(where: { $0.rawValue == raw }) {
            index = i
        }
        // Preview of the code page answered: `CWG_ONBOARDING_CODE=KV7P2M`.
        if preview, let raw = ProcessInfo.processInfo.environment["CWG_ONBOARDING_CODE"] {
            together = .someone
            codeChoice = .haveCode
            codeDraft = JoinSheet.formatTyping(raw)
        }
        // Preview of the joined page: pretend the code was accepted.
        if preview, ProcessInfo.processInfo.environment["CWG_ONBOARDING_PAGE"] == "joined" {
            codePreview = Self.previewInvite
            joined = true
            showJoined()
            if let i = pages.firstIndex(of: .joined) { index = i }
        }
        // Signed in but never finished: pick up where it left off.
        if !preview, auth.signedIn { restoreResume() }
        // Signed in but still on welcome (no resume, or a failed first
        // pull): don't leave them with only the legal links.
        if !preview, auth.signedIn, page == .welcome {
            Task { await signedInFromFrontDoor() }
        }
        if locationAllowed, pages.contains(.home) {
            Task { await guessHome() }
        }
        // A home already on record (a join, a second device mid-run)
        // wants its chips ready before the save page. The preview fetches
        // for the account's home so the page can be checked for real.
        if preview || !pages.contains(.home), let home = chosenHome {
            fetchStarters(for: home)
        }
        refreshOffers()
    }

    private var locationAllowed: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(LocationStore.shared.authorization)
    }

    /// Who it's for comes first: joining someone brings their home and
    /// their saves, which answer two of the pages after it. Home leads the
    /// rest when it can be guessed; pages the account already answers are
    /// dropped (never in preview, which shows them all). An invite link
    /// skips the question and opens on the code.
    private func pageOrder() -> [Page] {
        var order: [Page] = locationAllowed
            ? [.welcome, .home, .name, .save, .notify]
            : [.welcome, .name, .home, .save, .notify]
        if preview {
            order.insert(contentsOf: [.together, .code], at: 1)
        } else if JoinGate.pendingCode != nil {
            order.insert(.code, at: 1)
        } else if !alreadyShared {
            order.insert(.together, at: 1)
            if together == .someone { order.insert(.code, at: 2) }
        }
        if !preview {
            if OnboardingGate.hasName { order.removeAll { $0 == .name } }
            if OnboardingGate.hasHome { order.removeAll { $0 == .home } }
        }
        return order
    }

    /// Already in a group with someone (joined from another device mid-run):
    /// the question has been answered.
    private var alreadyShared: Bool {
        (group.card?.members.count ?? 0) > 1
    }

    // MARK: Resume

    /// The page and the drafts, per account, so a run cut short comes
    /// back where it was. Cleared when the run finishes.
    private struct Resume: Codable {
        var page: String
        var name: String
        var codeDraft: String
        var cityDraft: String
        var linkDraft: String
        var together: String?
        var codeChoice: String?
    }

    private var resumeKey: String? {
        auth.userId.map { "onboarding.resume.\($0.uuidString.lowercased())" }
    }

    private var resumeDefaults: UserDefaults {
        UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
    }

    private func saveResume() {
        guard !preview, let key = resumeKey, page != .welcome else { return }
        let state = Resume(page: page.rawValue, name: name, codeDraft: codeDraft,
                           cityDraft: cityDraft, linkDraft: linkDraft,
                           together: together?.rawValue, codeChoice: codeChoice?.rawValue)
        if let data = try? JSONEncoder().encode(state) {
            resumeDefaults.set(data, forKey: key)
        }
    }

    private func restoreResume() {
        guard let key = resumeKey,
              let data = resumeDefaults.data(forKey: key),
              let state = try? JSONDecoder().decode(Resume.self, from: data),
              let target = Page(rawValue: state.page)
        else { return }
        if name.isEmpty { name = state.name }
        cityDraft = state.cityDraft
        linkDraft = state.linkDraft
        together = state.together.flatMap(Together.init(rawValue:))
        codeChoice = state.codeChoice.flatMap(CodeChoice.init(rawValue:))
        if !state.codeDraft.isEmpty {
            codeDraft = state.codeDraft
            together = .someone
            if codeChoice == nil { codeChoice = .haveCode }
        }
        if together == .someone, !pages.contains(.code) {
            let after = pages.firstIndex(of: .together).map { $0 + 1 } ?? min(1, pages.count)
            pages.insert(.code, at: after)
        }
        // The page may have been answered since (a second device): then
        // land on the first one still open rather than a page that's gone.
        // A joined page can't be rebuilt from cold; its neighbour will do.
        if let i = pages.firstIndex(of: target) {
            index = i
        } else if target == .joined || target == .save || target == .notify,
                  let i = pages.firstIndex(of: .save) ?? pages.firstIndex(of: .notify) {
            index = i
        } else {
            index = min(1, pages.count - 1)
        }
    }

    private func clearResume() {
        guard let key = resumeKey else { return }
        resumeDefaults.removeObject(forKey: key)
    }

    /// Decides whether to offer the code page's paste chip without reading
    /// the clipboard — `hasStrings`/`hasURLs` never raise the system paste
    /// prompt. The contents are read only on the tap.
    private func refreshOffers() {
        let board = UIPasteboard.general
        // A link is never a code; anything else that's text might be.
        clipboardHasText = page == .code && board.hasStrings && !board.hasURLs
    }

    /// Removes a page without moving the reader: if it sat before the
    /// current one, the index shifts with it so the same page stays up.
    private func drop(_ page: Page) {
        guard let i = pages.firstIndex(of: page) else { return }
        withAnimation(ease) {
            pages.remove(at: i)
            if i < index { index -= 1 }
        }
    }

    private func advance() {
        note = nil
        focus = nil
        // Leaving the code page, joined or not, settles the invite link.
        if page == .code { JoinGate.pendingCode = nil }
        guard index + 1 < pages.count else { finish(); return }
        withAnimation(ease) { index += 1 }
        if page == .name, trimmedName.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focus = .name }
        }
    }

    private func back() {
        guard index > 0 else { return }
        note = nil
        focus = nil
        withAnimation(ease) { index -= 1 }
    }

    private func finish() {
        if preview, let originalTheme {
            themes.select(originalTheme)
        } else if !preview {
            // The look they chose should be the icon on the home screen
            // too — swapped in the background, so the library, not the
            // system's "you changed the icon" alert, is what comes next.
            themes.deferIconSync()
            clearResume()
        }
        onFinished()
    }

    // MARK: Helpers

    private var displayName: String {
        if !trimmedName.isEmpty { return trimmedName }
        if let uid = SupabaseAuth.shared.userId, let n = members.name(forUser: uid) { return n }
        return "you"
    }

    private static let worldRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 30, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 110, longitudeDelta: 110)
    )
}
