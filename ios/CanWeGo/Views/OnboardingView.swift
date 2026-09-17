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
}

/// First run. One question a page, centred on a soft wash of the theme:
/// a welcome, Sign in with Apple, then only what the account still lacks
/// (a name if Apple didn't hand one over, a look, a shared library, a
/// home city), the person's own first save, and only after that the ask
/// for notifications, once there's a real card to be notified about.
///
/// Someone who already has an account never sees a page past sign-in:
/// the moment the session lands and the card says name and home are on
/// record, the view hands straight over to the library.
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

    enum Page: Hashable { case welcome, home, name, theme, code, save, notify }
    @State private var pages: [Page] = [.welcome, .name, .theme, .code, .home, .save, .notify]
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

    // Code
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
    @State private var clipboardHasLink = false

    // Notify
    @State private var notifyStatus: UNAuthorizationStatus = .notDetermined

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
        }
        // An invite link tapped while the first run is up.
        .onReceive(NotificationCenter.default.publisher(for: .cwgJoinCode)) { note in
            if let code = note.object as? String { takeInviteCode(code) }
        }
        .onChange(of: codeDraft) { _, new in codeTyped(new) }
        .onChange(of: page) { old, _ in
            refreshOffers()
            // The carousel is rebuilt on every visit; forget where it was
            // parked so the next visit parks on the current theme again
            // instead of reading its fresh zero offset as a choice.
            if old == .theme {
                themes.commit()
                themeScroll = nil
                carouselReady = false
            }
        }
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
                    Annotation("", coordinate: c) {
                        Circle()
                            .fill(AppBackground.ink)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(AppBackground.base, lineWidth: 2))
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
        case .theme:
            return Forward(run: advance)
        case .name:
            return Forward(disabled: trimmedName.isEmpty, run: commitName)
        case .code:
            if joined { return Forward(run: advance) }
            if let p = codePreview, p.canJoin {
                // The card above already names the group; keep the pill short.
                return Forward(title: "Join") { Task { await join() } }
            }
            return Forward(run: advance)
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
                return Forward(title: "Notify me") {
                    if !preview { PushRegistrar.register() }
                    finish()
                }
            }
            return Forward(title: "Done", run: finish)
        }
    }

    // MARK: Pages

    @ViewBuilder
    private var pageBody: some View {
        switch page {
        case .welcome: welcomePage
        case .name: namePage
        case .theme: themePage
        case .code: codePage
        case .home: homePage
        case .save: savePage
        case .notify: notifyPage
        }
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.display(34, relativeTo: .largeTitle))
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

    @ViewBuilder
    private var noteLine: some View {
        if let note {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Welcome

    /// The front door: the wordmark, one line, and Sign in with Apple.
    /// The same button whether this is a brand new account or a returning
    /// one, because Apple knows which and we don't until the session
    /// lands. New accounts arrive with a name, so the name page is never
    /// asked of them; returning ones skip the whole run.
    private var welcomePage: some View {
        VStack(spacing: 22) {
            Image("Figure")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 168)
                .foregroundStyle(AppBackground.ink)
                .accessibilityHidden(true)
            LogoTitle(height: 52)
            Text(auth.sessionExpired && !preview
                 ? "Your session expired.\nSign in again to keep syncing.\nEverything you saved is still here."
                 : "The things you want to go to.\nYours, or shared.")
                .font(.display(20, relativeTo: .title3))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if needsSignIn || unreachable || signingIn || preview {
                signInBlock
                    .padding(.top, 18)
            }

            // Temporary: the welcome page has no bottom bar, so there's
            // no other way past Apple while trying the rest of the run.
            quiet("Skip (debug)") { advance() }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 40)
        .animation(ease, value: signingIn)
        .animation(ease, value: unreachable)
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
            // They came by invite link: joining is the point, so the code
            // page leads (and the group's home then answers that page).
            if let code = JoinGate.pendingCode, let i = pages.firstIndex(of: .code) {
                pages.remove(at: i)
                pages.insert(.code, at: min(1, pages.count))
                codeDraft = JoinSheet.formatTyping(code)
                Task { await lookup(code) }
            }
            index = min(1, pages.count - 1)
        }
    }

    // MARK: Name

    private var namePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("What should we\ncall you?")
            lede("First name is plenty. It's how you show up on the things you save: “Added by \(trimmedName.isEmpty ? "you" : trimmedName)”.")

            slab {
                TextField("Your first name", text: $name)
                    .font(.title3)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .name)
                    .onSubmit(commitName)
                    .onChange(of: name) { _, new in
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
        guard !trimmedName.isEmpty else { return }
        if preview { advance(); return }
        busy = true
        Task {
            if let error = await members.setDisplayName(trimmedName) {
                note = error
                busy = false
                return
            }
            busy = false
            advance()
        }
    }

    // MARK: Theme

    private var themePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("How should\nit look?")
            lede("\(Self.spelled(AppTheme.allCases.count)) moods. The whole app repaints as you tap; change it any time in Settings.")

            themeCarousel
                // Bleed past the page margin so neighbours peek in.
                .padding(.horizontal, -28)
                .padding(.top, 6)
        }
    }

    /// "Five", not "5": the copy reads as prose, and stays right if a
    /// theme is added.
    private static func spelled(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        return (f.string(from: NSNumber(value: n)) ?? String(n)).capitalized
    }

    @State private var themeScroll: AppTheme?
    @State private var carouselWidth: CGFloat = 0

    /// Swipe through mini screens of each theme; the one that settles in
    /// the centre becomes the theme.
    private var themeCarousel: some View {
        let thumb = max(carouselWidth * 0.58, 1)
        let margin = max((carouselWidth - thumb) / 2, 0)
        return ScrollView(.horizontal) {
            HStack(spacing: 18) {
                ForEach(AppTheme.allCases) { option in
                    themeThumb(option)
                        .frame(width: thumb)
                        .contentShape(.rect)
                        // A peeking neighbour is an invitation: tapping it
                        // slides it to the centre (and so applies it).
                        .onTapGesture {
                            guard option != themeScroll else { return }
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.35)) { themeScroll = option }
                        }
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.92)
                                .opacity(phase.isIdentity ? 1 : 0.55)
                        }
                        .id(option)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $themeScroll, anchor: .center)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            carouselWidth = width
            // Park on the current theme only once the thumbnails have a
            // real size; before that the offsets mean nothing and the
            // first frame would "choose" whichever theme sits at zero.
            guard width > 0, themeScroll == nil else { return }
            themeScroll = themes.current
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                carouselReady = true
            }
        }
        // Repaint as a thumbnail crosses the centre, mid-swipe, rather
        // than waiting for the scroll to settle.
        .onScrollGeometryChange(for: Int.self) { geo in
            let step = thumb + 18
            return Int(((geo.contentOffset.x + geo.contentInsets.leading) / step).rounded())
        } action: { _, i in
            guard carouselReady else { return }
            let all = AppTheme.allCases
            guard all.indices.contains(i), all[i] != themes.current else { return }
            apply(all[i])
        }
        .onChange(of: themeScroll) { _, new in
            if carouselReady, let new, new != themes.current { apply(new) }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .idle { themes.commit() }
        }
        // The page-wide theme ease must not also tween the thumbs: that
        // fights the scroll transition and drops frames on device.
        .animation(nil, value: themes.current)
    }

    @State private var carouselReady = false

    /// Not `select`: that cross-dissolves the whole window via a UIKit
    /// snapshot, which stalls a live scroll for a frame. `preview` paints
    /// SwiftUI colours only; `commit` (on idle, or leaving the page)
    /// writes disk, widgets and the window trait. No `withAnimation`
    /// here — it would capture the scroll offset in the same transaction.
    private func apply(_ theme: AppTheme) {
        guard theme != themes.current else { return }
        Haptics.selection()
        themes.preview(theme)
    }

    private static let thumbAccents = ["#B44A2C", "#2C7A6B", "#7A4FB4"]

    /// A little screen in the theme: wordmark up top, three sample cards.
    private func themeThumb(_ option: AppTheme) -> some View {
        let on = themes.current == option
        return VStack(spacing: 12) {
            VStack(spacing: 10) {
                Image("Logo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 16)
                    .foregroundStyle(option.ink)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                ForEach(Self.thumbAccents, id: \.self) { hex in
                    let accent = Color(hex: hex) ?? option.ink
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(option.ink.opacity(0.8))
                            .frame(width: 70, height: 7)
                        Capsule().fill(option.ink.opacity(0.4))
                            .frame(width: 44, height: 5)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        option.base
                            .mix(with: option.cardLiftColor, by: option.cardLiftAmount)
                            .mix(with: accent, by: option.cardAccentMix),
                        in: .rect(cornerRadius: 12)
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .aspectRatio(0.66, contentMode: .fit)
            .background(option.base, in: .rect(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(AppBackground.ink.opacity(on ? 0.9 : 0.15), lineWidth: on ? 2 : 1)
            )

            Text(option.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(on ? AppBackground.ink : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Code

    private var codePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("Did someone\nsend you a code?")
            lede("Join them and you share one library. Everyone sees and edits everything. No code? Carry on and invite people later.")

            slab {
                // Formatting happens in the binding's setter, in the same
                // pass as the keystroke, so fast typing never lands on a
                // draft that's about to be rewritten (and lose a letter).
                TextField("KV7-P2M", text: Binding(
                    get: { codeDraft },
                    set: { codeDraft = JoinSheet.formatTyping($0) }
                ))
                    .accessibilityLabel("Invite code")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
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

            noteLine
        }
        .animation(ease, value: codePreview?.status)
    }

    private func codePreviewCard(_ p: GroupStore.JoinPreview) -> some View {
        slab {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(p.name ?? "Their library")
                        .font(.title3.weight(.bold))
                    Spacer()
                    if let home = p.homeLocality {
                        Label(home, systemImage: "house")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let members = p.members, !members.isEmpty {
                    HStack(spacing: 8) {
                        HStack(spacing: -8) {
                            ForEach(members.prefix(4)) { m in
                                Text(m.initial)
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(AvatarColour.initial(m.avatarColour))
                                    .frame(width: 30, height: 30)
                                    .background(AvatarColour.color(m.avatarColour), in: .circle)
                                    .overlay(Circle().stroke(AppBackground.base, lineWidth: 2))
                            }
                        }
                        .accessibilityHidden(true)
                        Text(members.map(\.name).joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
        members: [.init(displayName: "Joyce", avatarColour: "#C24B5A")]
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
            return
        }
        busy = true
        defer { busy = false }
        focus = nil
        do {
            _ = await SupabaseSync.flush(context: context)
            try await group.join(code: code, keepCopy: false)
            _ = await SupabaseSync.replaceLibrary(context: context)
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
        } catch {
            note = "Couldn't join. \(SyncProblem(error).message)"
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
            lede("The city your saves are about. A whole city, not a borough. It sets the clock on every card and where the map opens.")

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
                        TextField("City", text: $cityDraft)
                            .font(.title3)
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
        picked = first
        wider = HomeStore.widerCity(for: first)
        guessed = true
        manualHome = false
        frame(first)
    }

    @State private var guessSlow = false

    /// The chip: may raise the system permission prompt first. People
    /// read prompts at their own pace, so wait on the *answer*, then on
    /// the fix; only a denial or a genuinely missing fix gives up.
    private func useLocation() async {
        locating = true
        defer { locating = false }
        note = nil
        LocationStore.shared.refresh()
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

    // MARK: First save

    private static let londonStarters: [(title: String, url: String)] = [
        ("Photographers' Gallery", "https://thephotographersgallery.org.uk"),
        ("Sessions Arts Club", "https://sessionsartsclub.com"),
        ("Roundhouse", "https://www.roundhouse.org.uk"),
    ]

    /// Only a home that was actually chosen counts; `HomeStore.home` falls
    /// back to London when nothing is set, and that must not show London
    /// starters to someone in Lisbon who hasn't picked yet.
    private var homeIsLondon: Bool {
        let home = picked ?? (HomeStore.shared.isSet ? HomeStore.shared.home : nil)
        return home?.locality.compare("London", options: .caseInsensitive) == .orderedSame
    }

    private var savePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let parsed {
                headline("There it is.")
                lede("A real save. Everything you add lands in the library looking like this.")
                ItemCard(item: parsed, meta: "Added by \(displayName)")
                quiet("Try another") {
                    self.parsed = nil
                    linkDraft = ""
                    linkImage = nil
                    note = nil
                    refreshOffers()
                }
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

                    if clipboardHasLink, linkDraft.isEmpty, linkImage == nil {
                        chip("Paste the link you copied", icon: "doc.on.clipboard") {
                            let board = UIPasteboard.general
                            let text = board.url?.absoluteString ?? board.string ?? ""
                            linkDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if linkURL != nil {
                                startParse()
                            } else {
                                clipboardHasLink = false
                                linkDraft = ""
                                note = "That didn't look like a link."
                            }
                        }
                    }

                    if homeIsLondon, linkDraft.isEmpty, linkImage == nil {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(Self.londonStarters, id: \.url) { s in
                                    Button(s.title) {
                                        Haptics.tap()
                                        linkDraft = s.url
                                        startParse()
                                    }
                                    .buttonStyle(.glass)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollClipDisabled()
                    }
                    // The share-sheet lesson isn't here: it arrives as a
                    // tip in the library on the second launch (ShareTip).
                }
            }

            noteLine
        }
        .animation(ease, value: parsing)
        .animation(ease, value: parsed?.id)
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
                ParsingPhrases()
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
        item.addedByEmail = SupabaseAuth.shared.email
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
        if !needsSignIn, let i = pages.firstIndex(of: .code) {
            withAnimation(ease) { index = i }
            note = nil
            Task { await lookup(code) }
        }
    }

    private func setUp() {
        if preview { originalTheme = themes.current }
        if !preview, let code = JoinGate.pendingCode {
            codeDraft = JoinSheet.formatTyping(code)
        }
        if !preview, let uid = SupabaseAuth.shared.userId, let existing = members.name(forUser: uid) {
            name = existing
        }
        // Before sign-in the account is unknown, so the run is the full
        // one; `signedInFromFrontDoor` trims it once the card is in.
        pages = pageOrder()
        // Preview only: `CWG_ONBOARDING_PAGE=home` (any Page name) opens
        // straight on that page, for checking one screen at a time.
        if preview, let raw = ProcessInfo.processInfo.environment["CWG_ONBOARDING_PAGE"],
           let i = pages.firstIndex(where: { "\($0)" == raw }) {
            index = i
        }
        if locationAllowed, pages.contains(.home) {
            Task { await guessHome() }
        }
        refreshOffers()
    }

    private var locationAllowed: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(LocationStore.shared.authorization)
    }

    /// Home leads the questions when it can be guessed; pages the account
    /// already answers are dropped (never in preview, which shows them all).
    private func pageOrder() -> [Page] {
        var order: [Page] = locationAllowed
            ? [.welcome, .home, .name, .theme, .code, .save, .notify]
            : [.welcome, .name, .theme, .code, .home, .save, .notify]
        if !preview {
            if OnboardingGate.hasName { order.removeAll { $0 == .name } }
            if OnboardingGate.hasHome { order.removeAll { $0 == .home } }
        }
        return order
    }

    /// Decides whether to offer a paste chip without reading the clipboard
    /// — `hasStrings`/`hasURLs` and pattern detection never raise the
    /// system paste prompt. The contents are read only on the tap.
    private func refreshOffers() {
        let board = UIPasteboard.general
        clipboardHasText = false
        clipboardHasLink = false
        switch page {
        case .code:
            // A link is never a code; anything else that's text might be.
            clipboardHasText = board.hasStrings && !board.hasURLs
        case .save:
            if board.hasURLs {
                clipboardHasLink = true
            } else if board.hasStrings {
                Task {
                    let found = try? await board.detectedPatterns(for: [\.probableWebURL])
                    if page == .save { clipboardHasLink = found?.contains(\.probableWebURL) == true }
                }
            }
        default:
            break
        }
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
            // The look they chose should be the icon on the home screen too.
            themes.syncAppIcon()
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
