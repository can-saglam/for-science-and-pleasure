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

    static var skipKey: String? {
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

/// First run, on a soft wash of the theme. Three pages show what the app
/// does before anything is asked (saving from anywhere, the list knowing
/// when, sharing it), the third with Sign in with Apple. Then one
/// question a page, only what the account still lacks: who it's for, a
/// name if Apple didn't hand one over, a home city, the person's own
/// first saves (typed, or ticked from the city's picks), the invite for
/// someone starting a shared list, and the ask for notifications once
/// there's a real card to be notified about. The share sheet is taught
/// by a tip on the list itself.
///
/// The look is not a question: a fresh install takes a theme from the
/// system appearance, and the page that shows the first real card offers
/// a row of swatches to repaint it. The first question after sign-in is
/// who it's for: just them, starting a shared library, or joining one
/// with a code; an invite link answers it and opens on the code. A join
/// swaps the first-save page for a look at what the group already has.
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

    @Environment(\.modelContext) var context
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var typeSize
    @State var members = MembersStore.shared
    @State var group = GroupStore.shared
    @State var themes = ThemeStore.shared
    @State var auth = SupabaseAuth.shared

    enum Page: String, Hashable {
        case anywhere, when, welcome, together, home, name, save, joined, invite, notify

        /// Before sign-in: the three pages that show what it does.
        var isBeat: Bool { [.anywhere, .when, .welcome].contains(self) }
    }
    @State var pages: [Page] = [.anywhere, .when, .welcome, .together, .name, .home, .save, .notify]
    @State var index = 0

    // Sign in (the welcome page is the front door when there's no session)
    @State var signingIn = false
    /// The session landed but the library couldn't be reached, so we
    /// can't tell what the account already has. Retry rather than guess.
    @State var unreachable = false
    var needsSignIn: Bool { !preview && !auth.signedIn }

    // Name
    @State var name = ""

    // Together: just them, starting a shared library, or joining one
    enum Together: String { case solo, start, code }
    @State var together: Together?

    // Code
    @State var codeDraft = ""
    @State var codePreview: GroupStore.JoinPreview?
    @State var lookingUp = false
    @State var clipboardHasText = false
    @State var joined = false

    // Home
    @State var guessing = false
    @State var guessed = false
    @State var manualHome = false
    @State var cityDraft = ""
    @State var matches: [HomeStore.Home] = []
    @State var picked: HomeStore.Home?
    /// Cities shown in place of the ward a lookup named, framed wider.
    @State var wholeCities: Set<HomeStore.Home> = []
    @State var locating = false
    @State var guessSlow = false
    @State var camera: MapCameraPosition = .region(OnboardingView.worldRegion)

    // First save
    @State var linkDraft = ""
    @State var linkImage: Data?
    @State var parsing = false
    @State var parseTask: Task<Void, Never>?
    @State var parsed: Item?
    /// The home city's suggestions, fetched the moment a home is known so
    /// they're waiting when the save page comes up.
    @State var suggestions = Suggestions.shared
    /// City picks ticked to save alongside (or instead of) a typed one.
    @State var tickedPicks: [ParseClient.Suggestion] = []
    /// The ticked picks once saved, shown as cards before moving on.
    @State var savedPicks: [Item] = []
    /// Each fan card's measured height, by its fan key plus index.
    @State var cardHeights: [Int: CGFloat] = [:]
    /// Saved picks whose pages are still being read.
    @State var reading: Set<UUID> = []

    // Invite (only for someone starting a shared library)
    @State var invite: GroupStore.InviteResult?
    @State var inviteFailed = false
    @State var sharingInvite = false
    @State var copiedCode = false

    // Joined
    @State var groupCards: [Item] = []

    // Notify
    @State var notifyStatus: UNAuthorizationStatus = .notDetermined

    // Welcome
    @State var legal: LegalPage?
    @State var drift = false
    /// The joined page's fan of the group's own saves, dealt on arrival.
    @State var joinedDealt = false
    @State var savedDealt = false
    /// A finger on one of the fan's cards: how far it's been pulled from
    /// its seat, and which one is up off the table.
    @State var pulled: [Int: CGSize] = [:]
    @State var lifted: Int?

    @State var busy = false
    @State var pageWidth: CGFloat = 402
    @State var pageHeight: CGFloat = 720
    /// Everything that should freeze the bottom bar, not just server writes.
    var frozen: Bool { busy || signingIn }
    @State var note: String?
    @State var originalTheme: AppTheme?
    @FocusState var focus: Field?
    enum Field { case name, code, city }

    var page: Page { pages[min(index, pages.count - 1)] }
    var isLast: Bool { index == pages.count - 1 }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var code: String? { GroupStore.normaliseCode(codeDraft) }

    var ease: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.3) }

    var body: some View {
        ZStack {
            backdrop
            if page == .home { cityMap }

            GeometryReader { geo in
                ScrollView {
                    // The front door is centred; every question starts at
                    // the same height, so headlines don't hop as pages turn —
                    // except home, which sits lower to leave the map in view.
                    // Side by side the questions are a phone's width, centred.
                    pageBody
                        .id(page)
                        .transition(.opacity)
                        .frame(maxWidth: sideBySide && !page.isBeat ? 440 : .infinity)
                        .padding(.horizontal, 28)
                        .padding(.top, topInset(in: geo.size.height))
                        .padding(.top, sideBySide ? 36 : 0)
                        .padding(.bottom, sideBySide ? 12 : 0)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geo.size.height,
                            alignment: centred ? .center : .top
                        )
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
                // The pages before sign-in are single screens. The later
                // pages scroll, so a keyboard can get out of the way.
                .scrollDisabled(page.isBeat)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
            }
            // Open, iPhone Duo is short for its width: the tiles and a code
            // only fit with less air over the bar.
            .safeAreaPadding(.bottom, page.isBeat ? 0 : sideBySide ? 24 : 84)
            // The demo lives above the pages and follows a slot on each,
            // so its cards carry over from one page to the next.
            .overlayPreferenceValue(DeckSlotKey.self) { slots in
                GeometryReader { proxy in
                    if let anchor = slots[page], let beat {
                        let rect = proxy[anchor]
                        BeatDemo(beat: beat, still: reduceMotion)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .animation(reduceMotion ? nil : .spring(duration: 1.0, bounce: 0), value: page)
                            .transition(.opacity)
                    }
                }
            }

            if preview {
                closeButton
            } else if page == .anywhere || page == .when {
                skipButton
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Signed in, the welcome page has nothing behind it to go back to.
            if page != .welcome || index > 0 { bottomBar }
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
    /// device. The orbs are wider than a small phone, so they're an
    /// overlay: in a ZStack their size would widen the whole page and eat
    /// its margins.
    var backdrop: some View {
        AppBackground.base
            .overlay {
                orbs
                    .transaction { $0.animation = nil }
            }
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: index)
            .accessibilityHidden(true)
    }

    var orbs: some View {
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
    var cityMap: some View {
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
        .task { await frameCountry() }
        .opacity(0.55)
        .mask(
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.32),
                .init(color: .clear, location: 0.62),
            ], startPoint: .top, endPoint: .bottom)
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    /// Past the two pages that show it, straight to signing in.
    var skipButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    Haptics.tap()
                    guard let i = pages.firstIndex(of: .welcome) else { return }
                    withAnimation(ease) { index = i }
                } label: {
                    Text("Skip")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
    }

    var closeButton: some View {
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
    var bottomBar: some View {
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
            .opacity(canGoBack && !frozen ? 1 : 0)
            .disabled(!canGoBack || frozen)
            .accessibilityLabel("Back")
            .accessibilityHidden(!canGoBack)

            Spacer(minLength: 0)

            if offersNotNow {
                // The way out sits beside the ask, not up in the page.
                // Back, dots and two pills don't fit one bar, so the
                // dots step aside on this page.
                notNowButton
                    .padding(.trailing, 2)
            } else {
                // The pages before sign-in count among themselves. After
                // it, the questions do, once there's a session: until then
                // the step count isn't known (the account may already
                // answer most of it).
                let steps = dotSteps
                HStack(spacing: 6) {
                    ForEach(steps, id: \.self) { i in
                        Capsule()
                            .fill(AppBackground.ink.opacity(i == index ? 0.9 : 0.3))
                            .frame(width: i == index ? 20 : 6, height: 6)
                    }
                }
                .animation(ease, value: index)
                .opacity(needsSignIn && !page.isBeat ? 0 : 1)
                .accessibilityElement()
                .accessibilityLabel("Step \((steps.firstIndex(of: index) ?? 0) + 1) of \(steps.count)")
                .accessibilityHidden(needsSignIn && !page.isBeat)

                Spacer()
            }

            // Without a session the only way forward is the Apple button.
            forwardButton
                .opacity(gatedBySignIn ? 0 : 1)
                .disabled(gatedBySignIn)
                .accessibilityHidden(gatedBySignIn)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
        // iPhone Duo's status column only fills the top of its side;
        // the bar runs under it, the full width of the display.
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    var dotSteps: [Int] {
        pages.indices.filter { pages[$0].isBeat == page.isBeat }
    }

    static let control: CGFloat = 56
    /// Clears the preview's close button with room to spare.
    static let headlineTop: CGFloat = 100

    var centred: Bool {
        page == .notify || sideBySide && page != .home
    }

    func topInset(in height: CGFloat) -> CGFloat {
        if centred { return 0 }
        return switch page {
        case .anywhere, .when, .welcome: tight ? 8 : 24
        case .home: max(Self.headlineTop, height * 0.34)
        default: tight ? Self.headlineTop - 28 : Self.headlineTop
        }
    }

    var gatedBySignIn: Bool { page == .welcome && (needsSignIn || unreachable) }

    /// Only while the system prompt is still ahead: once it's been
    /// answered, the forward button already reads "Done".
    var offersNotNow: Bool { page == .notify && notifyStatus == .notDetermined }

    var notNowButton: some View {
        Button {
            Haptics.tap()
            advance()
        } label: {
            Text("Not now")
                .fontWeight(.semibold)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .frame(height: Self.control)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(frozen)
    }

    /// An arrow until a step has an outcome to name — then a pill. Same
    /// height and glass as the back button, so the pair reads as one bar.
    /// At accessibility text sizes the title can't share the bar with the
    /// dots, so the pill falls back to the arrow and VoiceOver keeps the
    /// full name.
    var forwardButton: some View {
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

    struct Forward {
        var title: String? = nil
        var disabled = false
        var run: () -> Void
    }

    var forwardAction: Forward {
        switch page {
        case .welcome:
            return Forward(title: "Get started", disabled: needsSignIn || unreachable, run: advance)
        case .anywhere, .when, .joined:
            return Forward(run: advance)
        case .together:
            switch together {
            case nil:
                return Forward(disabled: true, run: {})
            case .code where !joined:
                if let p = codePreview, p.canJoin {
                    // The card above already names the group; keep the pill short.
                    return Forward(title: "Join") { Task { await join() } }
                }
                return Forward(disabled: true, run: {})
            default:
                return Forward(title: "Continue", run: advance)
            }
        case .name:
            return Forward(disabled: trimmedName.isEmpty, run: commitName)
        case .home:
            if let picked, homeVariant != .finding {
                // The headline or the ticked row already names the city.
                return Forward(title: "Set as home") { Task { await commitHome(picked) } }
            }
            return Forward(disabled: true, run: {})
        case .save:
            if parsed != nil {
                return Forward(title: tickedPicks.isEmpty ? "Save it" : "Save \(tickedPicks.count + 1)", run: commitSave)
            }
            if !savedPicks.isEmpty { return Forward(title: "Continue", run: advance) }
            if !tickedPicks.isEmpty, !parsing { return Forward(title: "Save \(tickedPicks.count)", run: commitPicks) }
            return Forward(disabled: parsing, run: advance)
        case .invite:
            if invite != nil { return Forward(title: "Send invite") { sharingInvite = true } }
            if inviteFailed { return Forward(title: "Continue", run: advance) }
            return Forward(disabled: true, run: {})
        case .notify:
            // Only ask when asking will do something: the system prompt
            // shows once, for `.notDetermined`. Otherwise just carry on.
            if notifyStatus == .notDetermined {
                return Forward(title: "Notify me") { Task { await askNotifications() } }
            }
            return Forward(title: isLast ? "Start" : "Continue", run: advance)
        }
    }

    /// The system prompt comes up over this page — the one that explained
    /// it — and the run moves on once it's answered, not underneath it.
    func askNotifications() async {
        if preview { advance(); return }
        busy = true
        await PushRegistrar.requestNow()
        busy = false
        advance()
    }

    // MARK: Pages

    @ViewBuilder
    var pageBody: some View {
        switch page {
        case .anywhere: anywherePage
        case .when: whenPage
        case .welcome: welcomePage
        case .together: togetherPage
        case .name: namePage
        case .home: homePage
        case .save: savePage
        case .joined: joinedPage
        case .invite: invitePage
        case .notify: notifyPage
        }
    }

    /// The breaks are a phone's; the open Duo's column is wide enough
    /// to run most on one line, and short enough that it needs to.
    func headline(_ text: String) -> some View {
        Text(sideBySide ? text.replacingOccurrences(of: "\n", with: " ") : text)
            .font(.displaySmallBold(38, relativeTo: .largeTitle))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A fixed share of the ink, like the home city sheet's intro: the
    /// system secondary sank into the blue wash.
    func lede(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(AppBackground.ink.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One glass slab for fields and lists.
    func slab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// Optional ways out — "Somewhere else", "Skip for now": a small glass pill.
    func quiet(_ title: String, action: @escaping () -> Void) -> some View {
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

    /// A small glass chip: clipboard offers, location.
    func chip(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
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

    func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(AppBackground.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Always two lines tall, so an error arriving under centered content
    /// doesn't shove the page upward. Empty, it's invisible.
    var noteLine: some View {
        Text(note ?? " ")
            .font(.footnote)
            .foregroundStyle(note == nil ? Color.clear : AppBackground.warning)
            .fixedSize(horizontal: false, vertical: true)
            // Held open so a note doesn't push the page, except side by
            // side, where the height is short and the page is centred anyway.
            .frame(maxWidth: .infinity, minHeight: sideBySide && note == nil ? 0 : 36, alignment: .topLeading)
            .accessibilityHidden(note == nil)
    }

    // MARK: Flow

    /// The code from an invite link goes into the field now; the page it
    /// belongs to comes up as soon as there's a session to join with.
    func takeInviteCode(_ code: String) {
        codeDraft = JoinSheet.formatTyping(code)
        guard !needsSignIn else { return }
        // A link answers the question: they're joining someone.
        together = .code
        placeInvitePage()
        if !pages.contains(.together) {
            withAnimation(ease) { pages.insert(.together, at: min(max(index, 1), pages.count)) }
        }
        if let i = pages.firstIndex(of: .together) {
            withAnimation(ease) { index = i }
            note = nil
            Task { await lookup(code) }
        }
    }

    func setUp() {
        if preview { originalTheme = themes.current }
        if !preview, let code = JoinGate.pendingCode {
            codeDraft = JoinSheet.formatTyping(code)
            together = .code
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
            together = .code
            codeDraft = JoinSheet.formatTyping(raw)
        }
        // Preview of the invite page: `CWG_ONBOARDING_TOGETHER=start`.
        if preview, let raw = ProcessInfo.processInfo.environment["CWG_ONBOARDING_TOGETHER"],
           let choice = Together(rawValue: raw) {
            together = choice
            placeInvitePage()
            if let page = ProcessInfo.processInfo.environment["CWG_ONBOARDING_PAGE"],
               let i = pages.firstIndex(where: { $0.rawValue == page }) {
                index = i
            }
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
            Task { await openLibrary() }
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

    var locationAllowed: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(LocationStore.shared.authorization)
    }

    /// Who it's for comes first: joining someone brings their home and
    /// their saves, which answer two of the pages after it. Home leads the
    /// rest when it can be guessed; pages the account already answers are
    /// dropped (never in preview, which shows them all). An invite link
    /// opens the question already answered, on the code. Starting a
    /// shared list adds the invite after the first save. The two pages
    /// that show the app come before sign-in, and not for someone whose
    /// session merely expired.
    func pageOrder() -> [Page] {
        var order: [Page] = locationAllowed
            ? [.welcome, .home, .name, .save, .notify]
            : [.welcome, .name, .home, .save, .notify]
        if preview || JoinGate.pendingCode != nil || !alreadyShared {
            order.insert(.together, at: 1)
        }
        if together == .start, !joined, preview || !alreadyShared, let i = order.firstIndex(of: .notify) {
            order.insert(.invite, at: i)
        }
        if !preview {
            if OnboardingGate.hasName { order.removeAll { $0 == .name } }
            if OnboardingGate.hasHome { order.removeAll { $0 == .home } }
        }
        if preview || needsSignIn && !auth.sessionExpired {
            order.insert(contentsOf: [.anywhere, .when], at: 0)
        }
        return order
    }

    /// Already in a group with someone (joined from another device mid-run):
    /// the question has been answered.
    var alreadyShared: Bool {
        (group.card?.members.count ?? 0) > 1
    }

    // MARK: Resume

    /// The page and the drafts, per account, so a run cut short comes
    /// back where it was. Cleared when the run finishes.
    struct Resume: Codable {
        var page: String
        var name: String
        var codeDraft: String
        var cityDraft: String
        var linkDraft: String
        var together: String?
        /// Before the two questions became one: "haveCode" or "first".
        var codeChoice: String?
    }

    var resumeKey: String? {
        auth.userId.map { "onboarding.resume.\($0.uuidString.lowercased())" }
    }

    var resumeDefaults: UserDefaults {
        UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
    }

    func saveResume() {
        guard !preview, let key = resumeKey, !page.isBeat else { return }
        let state = Resume(page: page.rawValue, name: name, codeDraft: codeDraft,
                           cityDraft: cityDraft, linkDraft: linkDraft,
                           together: together?.rawValue, codeChoice: nil)
        if let data = try? JSONEncoder().encode(state) {
            resumeDefaults.set(data, forKey: key)
        }
    }

    func restoreResume() {
        guard let key = resumeKey,
              let data = resumeDefaults.data(forKey: key),
              let state = try? JSONDecoder().decode(Resume.self, from: data),
              let target = Page(rawValue: state.page == "code" ? Page.together.rawValue : state.page)
        else { return }
        if name.isEmpty { name = state.name }
        cityDraft = state.cityDraft
        linkDraft = state.linkDraft
        switch (state.together, state.codeChoice) {
        case ("someone", "first"): together = .start
        case ("someone", _): together = .code
        default: together = state.together.flatMap(Together.init(rawValue:))
        }
        if !state.codeDraft.isEmpty {
            codeDraft = state.codeDraft
            if together == nil { together = .code }
        }
        placeInvitePage()
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

    func clearResume() {
        guard let key = resumeKey else { return }
        resumeDefaults.removeObject(forKey: key)
    }

    /// Decides whether to offer the code page's paste chip without reading
    /// the clipboard — `hasStrings`/`hasURLs` never raise the system paste
    /// prompt. The contents are read only on the tap.
    func refreshOffers() {
        let board = UIPasteboard.general
        // Text might be a code, and a link might be the invite link.
        clipboardHasText = page == .together && together == .code && (board.hasStrings || board.hasURLs)
    }

    /// Removes a page without moving the reader: if it sat before the
    /// current one, the index shifts with it so the same page stays up.
    func drop(_ page: Page) {
        guard let i = pages.firstIndex(of: page) else { return }
        withAnimation(ease) {
            pages.remove(at: i)
            if i < index { index -= 1 }
        }
    }

    func advance() {
        note = nil
        focus = nil
        // Leaving the question, joined or not, settles the invite link.
        if page == .together { JoinGate.pendingCode = nil }
        guard index + 1 < pages.count else { finish(); return }
        withAnimation(ease) { index += 1 }
        if page == .name, trimmedName.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focus = .name }
        }
    }

    /// Once signed in, the welcome page is behind them for good.
    var canGoBack: Bool {
        guard index > 0 else { return false }
        return preview || !auth.signedIn || pages[index - 1] != .welcome
    }

    func back() {
        guard canGoBack else { return }
        note = nil
        focus = nil
        withAnimation(ease) { index -= 1 }
    }

    func finish() {
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

    var displayName: String {
        if !trimmedName.isEmpty { return trimmedName }
        if let uid = SupabaseAuth.shared.userId, let n = members.name(forUser: uid) { return n }
        return "you"
    }

    static let worldRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 30, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 110, longitudeDelta: 110)
    )
}
