#if !APP_EXTENSION
import ActivityKit
#endif
import AuthenticationServices
import EventKit
import SwiftData
import SwiftUI
import UserNotifications

struct SettingsView: View {
    /// The pages one tap in from the first.
    enum Page: String, Hashable {
        case group, plus, account
    }

    @State private var path: [Page] = []
    @State private var group = GroupStore.shared
    @State private var groupUI = GroupUI()
    @State private var showPlus = false
    @State private var manageSubscription = false
    /// Translucent panel rows on the theme wash.
    static var rowBackground: Color { AppBackground.wash(0.08) }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.authorizationController) private var authorizationController
    @Query private var items: [Item]
    @State private var auth = SupabaseAuth.shared
    @State private var themes = ThemeStore.shared
    @State private var syncStatus = SyncStatus.shared
    /// Local edits not yet on the server, for the sync row.
    @State private var pending = 0

    /// "Synced 2 minutes ago · 3 waiting to send", or the honest gaps.
    private var syncSummary: String {
        var parts: [String] = []
        if let last = syncStatus.lastSyncedAt {
            parts.append("Synced \(last.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("Not synced yet")
        }
        if pending > 0 {
            parts.append("\(pending) waiting to send")
        } else if syncStatus.lastSyncedAt != nil {
            parts.append("Up to date")
        }
        return parts.joined(separator: " · ")
    }
    @State private var showAuth = false
    @State private var showOnboardingPreview = false
    @State private var confirmSignOut = false
    @State private var signingOut = false
    @State private var unsyncedOnSignOut = false
    @State private var legal: LegalPage?
    @State private var confirmDelete = false
    @State private var showDeleteConfirm = false
    @State private var deletePhrase = ""
    @State private var deleteBusy = false
    @State private var deleteError: String?
    @State private var showExport = false
    @State private var deleteAfterExport = false
    /// Which maps app gets the directions taps — same key `TransportApp` reads.
    @AppStorage(TransportApp.key, store: UserDefaults(suiteName: SharedInbox.groupID))
    private var transportApp = TransportApp.google.rawValue
    /// Same key `LiveDay` reads; on until switched off.
    @AppStorage("liveActivities") private var liveActivities = true
    #if !APP_EXTENSION
    /// Same key `CalendarChoice` reads; empty is the iPhone's default calendar.
    @AppStorage(CalendarChoice.key) private var calendarID = ""
    @State private var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    @State private var calendars: [CalendarChoice.Option] = []
    /// The iPhone's default calendar; only full access can see which.
    @State private var defaultCalendarID: String?
    @State private var calendarRefused = false
    /// iOS's own Live Activities switch for this app, in the Settings app.
    @State private var activitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled
    @State private var notificationStatus: UNAuthorizationStatus?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    #endif

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if auth.signedIn {
                    groupHeader
                    Section {
                        homeCityRow
                    } header: {
                        SettingsSectionHeader("Finding things")
                    }
                    .listRowBackground(Self.rowBackground)
                } else {
                    signInCard
                }

                Section {
                    #if !APP_EXTENSION
                    calendarRow
                    #endif
                    menuRow("Get directions with") {
                        Picker(selection: $transportApp) {
                            ForEach(TransportApp.allCases) { app in
                                Text(app.name).tag(app.rawValue)
                            }
                        } label: { EmptyView() }
                    }
                    .sensoryFeedback(.selection, trigger: transportApp)
                } header: {
                    SettingsSectionHeader("Making plans")
                }
                .listRowBackground(Self.rowBackground)

                #if !APP_EXTENSION
                onTheDay
                #endif

                Section {
                    // The same one-tap swatch row as the first run: the
                    // whole sheet repaints under the finger, no sub-screen.
                    ThemeSwatchRow(title: "Theme") { option in
                        theme.wrappedValue = option
                    }
                    .padding(.vertical, 6)
                } header: {
                    SettingsSectionHeader("Look")
                }
                .listRowBackground(Self.rowBackground)

                if auth.signedIn {
                    Section {
                        pageRow("Plus", value: group.card?.forScreenshots.isPlus == true ? "On" : "Free") {
                            path.append(.plus)
                        }
                        pageRow(
                            "Account",
                            subtitle: syncStatus.problem != nil ? "Sync issue" : auth.email,
                            warning: syncStatus.problem != nil
                        ) {
                            path.append(.account)
                        }
                    } header: {
                        SettingsSectionHeader("You")
                    }
                    .listRowBackground(Self.rowBackground)
                }

                #if !APP_EXTENSION
                // Temporary, for testing builds. Remove before release.
                Section {
                    pageRow("Replay onboarding", subtitle: "Every page, nothing saved") {
                        showOnboardingPreview = true
                    }
                }
                .listRowBackground(Self.rowBackground)
                #endif

                footer
            }
            .listSectionSpacing(.compact)
            // The grouped list's own top margin left a gap under the close
            // button; this keeps the footer on the first screen.
            .contentMargins(.top, 4, for: .scrollContent)
            .settingsPage(nil)
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .group: groupPage
                case .plus: PlusPage(manage: $manageSubscription).settingsPage("Plus")
                case .account: accountPage
                }
            }
            .task {
                if ProcessInfo.processInfo.environment["CWG_JOIN"] != nil {
                    groupUI.showJoin = true
                }
                // CWG_INVITE: a made-up code, so screenshot runs can show the
                // invite sheet without creating a real invite.
                if ProcessInfo.processInfo.environment["CWG_INVITE"] != nil {
                    groupUI.invite = .init(code: "LGU-2GT", expiresAt: .now.addingTimeInterval(7 * 86_400), message: nil)
                }
                // CWG_SETTINGS_PAGE=account: screenshot runs photograph a
                // page one level in.
                if let raw = ProcessInfo.processInfo.environment["CWG_SETTINGS_PAGE"],
                   let page = Page(rawValue: raw) {
                    path = [page]
                }
                pending = SupabaseSync.pendingCount(context: context)            }
            .onChange(of: syncStatus.syncing) { _, now in
                if !now { pending = SupabaseSync.pendingCount(context: context) }
            }
            #if !APP_EXTENSION
            .task { refreshCalendars() }
            // Back from the Settings app, where access may have changed.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                refreshCalendars()
                activitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled
                Task { await refreshNotificationStatus() }
            }
            .alert("Choose a calendar in Settings", isPresented: $calendarRefused) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text(calendarAccess == .writeOnly
                    ? "Allow Full Access to Calendars to choose one. Until then, events go to your default calendar."
                    : "Turn on Calendars for Can We Go and choose Full Access to pick where your events go.")
            }
            #endif
            .sheet(item: $legal) { page in
                LegalSheet(page: page)
            }
            // Deleting after an export picks up where it left off once the
            // export sheet closes.
            .sheet(isPresented: $showExport, onDismiss: {
                guard deleteAfterExport else { return }
                deleteAfterExport = false
                deletePhrase = ""
                showDeleteConfirm = true
            }) {
                ExportSheet()
            }
            .alert("Type DELETE to confirm", isPresented: $showDeleteConfirm) {
                TextField("", text: $deletePhrase, prompt: AppBackground.fieldPrompt("DELETE"))
                    .foregroundStyle(AppBackground.ink)
                    .textInputAutocapitalization(.characters)
                Button("Delete account", role: .destructive) {
                    Task { await deleteAccount() }
                }
                .disabled(deletePhrase.trimmingCharacters(in: .whitespaces) != "DELETE")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteAccountCopy)
            }
            .alert("Couldn't delete the account", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(deleteError ?? "")
            }
            .fullScreenCover(isPresented: $showAuth) {
                AuthView()
            }
            #if !APP_EXTENSION
            .fullScreenCover(isPresented: $showOnboardingPreview) {
                OnboardingView(onFinished: { showOnboardingPreview = false }, preview: true)
            }
            #endif
            .onChange(of: auth.signedIn) { _, on in
                if on { showAuth = false }
            }
            // The group rows' alerts, invite sheet and leave dialog.
            .modifier(GroupPresentations(ui: groupUI))
            .sheet(isPresented: $showPlus) { PlusPaywall() }
            .manageSubscriptionsSheet(isPresented: $manageSubscription)
            // CWG_SETTINGS=paywall / export are only set by automated test runs.
            .task {
                if ProcessInfo.processInfo.environment["CWG_SETTINGS"] == "paywall" {
                    try? await Task.sleep(for: .seconds(1.5))
                    showPlus = true
                }
                if ProcessInfo.processInfo.environment["CWG_SETTINGS"]?.hasPrefix("export") == true {
                    try? await Task.sleep(for: .seconds(1.5))
                    showExport = true
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear(perform: syncAppIcon)
    }

    // MARK: - First page

    /// Who shares the library, as a title line rather than a card: it's
    /// something you know, not something you change often.
    @ViewBuilder private var groupHeader: some View {
        if let card = group.card?.forScreenshots {
            Section {
                GroupHeader(card: card, ui: groupUI) { path.append(.group) }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
        } else if group.loaded {
            Section {
                GroupLoadFailed()
            }
            .listRowBackground(Self.rowBackground)
        } else {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .listRowBackground(Color.clear)
        }
    }

    /// The group's city: what picks are for and where the map opens.
    private var homeCityRow: some View {
        let home = group.card?.forScreenshots.homeLocality.flatMap { $0.isEmpty ? nil : $0 }
        return Button {
            Haptics.tap()
            groupUI.editingHome = true
        } label: {
            HStack {
                SettingsRow(title: "Home city", subtitle: "Where we look for picks, and where the map opens")
                Spacer(minLength: 8)
                Text(home ?? "Not set")
                    .foregroundStyle(AppBackground.secondaryInk)
                    .lineLimit(1)
                chevron
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Changes the city your picks and map use")
    }

    /// Signed out, the brand and the one thing to do.
    private var signInCard: some View {
        Section {
            VStack(spacing: 14) {
                LogoTitle(height: 40, writes: .settings)
                Text("The shows, gigs and places you keep meaning to go to, in one list you share.")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
                    .multilineTextAlignment(.center)
                Button {
                    Haptics.tap()
                    showAuth = true
                } label: {
                    Text("Sign in")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .prominentGlass()
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .listRowBackground(Self.rowBackground)
    }

    /// A way one level in: the name, what's behind it, and a chevron. An
    /// email address keeps both ends when it's too long.
    private func pageRow(
        _ title: String, subtitle: String? = nil, value: String? = nil, warning: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(AppBackground.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(warning ? AppBackground.warning : AppBackground.secondaryInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .foregroundStyle(AppBackground.secondaryInk)
                }
                chevron
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppBackground.ink.opacity(0.45))
            .accessibilityHidden(true)
    }

    /// The website's own words, kept in step with wegocan.com.
    private static let about = [
        "Can We Go is home to exhibitions, gigs, restaurants, bars or just anywhere you mean to get to. No more shared Notes or WhatsApp links that get lost in the ether. Share an event from Safari, Instagram, TikTok or Maps, take a photo of a poster IRL or use the app\u{2019}s native search function to find the latest from the Tate.",
        "Keep a list with your partner or a group of friends and get reminders of the things you can do: events ending soon rise to the top and the places you want to go live on a map. Forgot what you did last weekend? A record of your exploits lives in the archive.",
        "I\u{2019}m Can, and I built Can We Go for my partner and I to keep track of exhibitions and events in the city that we love. I hope it gets you to a few more of the places you said you\u{2019}d go to, too.",
    ]

    /// The brand signs off: what the app is for, in the website's words,
    /// then the legal pages and the version.
    private var footer: some View {
        Section {
            VStack(spacing: 12) {
                if auth.signedIn {
                    LogoTitle(height: 26, writes: .settings)
                }
                VStack(spacing: 8) {
                    ForEach(Self.about, id: \.self) { paragraph in
                        Text(paragraph)
                    }
                }
                .font(.caption)
                .foregroundStyle(AppBackground.secondaryInk.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                HStack(spacing: 8) {
                    Button("Privacy") {
                        Haptics.tap()
                        legal = .privacy
                    }
                    Text("·").accessibilityHidden(true)
                    Button("Terms") {
                        Haptics.tap()
                        legal = .terms
                    }
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(AppBackground.secondaryInk)
                Text("for science and pleasure · v\(version)")
                    .font(.caption)
                    .foregroundStyle(AppBackground.secondaryInk.opacity(0.75))
                    #if !APP_EXTENSION
                    // The first-run preview, for whoever made it.
                    .onLongPressGesture {
                        Haptics.tap()
                        showOnboardingPreview = true
                    }
                    #endif
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Pages

    private var groupPage: some View {
        List {
            GroupSection(ui: groupUI)
        }
        // Alone, there's no group yet: it's your library, waiting for someone.
        .settingsPage(groupTitle)
    }

    private var groupTitle: String {
        guard let card = group.card?.forScreenshots else { return "Group" }
        return card.members.count == 1 ? "Your library" : card.name
    }

    #if !APP_EXTENSION
    @ViewBuilder private var onTheDay: some View {
        Section {
            Toggle(isOn: Binding(
                get: { liveActivities && activitiesAllowed },
                set: { liveActivities = $0 }
            )) {
                SettingsRow(
                    title: "Use Live Activities",
                    subtitle: "Plans and reminders stay on your Lock Screen on the day, instead of a notification."
                )
            }
            .disabled(!activitiesAllowed)
            .tint(AppBackground.toggleTint)
            .sensoryFeedback(.selection, trigger: liveActivities)
            .onChange(of: liveActivities) { _, on in
                Task { await LiveDay.set(on) }
            }
            notificationsRow
        } header: {
            SettingsSectionHeader("On the day")
        } footer: {
            // Footers here (and in GroupSection) spell out `.footnote`:
            // when a menu picker opens or closes, the List re-measures
            // the visible footers without its own footer styling —
            // body-sized text, an extra line, and everything below
            // jumps ~33pt for one frame. With the font explicit both
            // passes agree and nothing moves.
            if !activitiesAllowed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live Activities are off for Can We Go in iPhone Settings.")
                        .font(.footnote)
                        .foregroundStyle(AppBackground.secondaryInk)
                    Button("Open Settings") {
                        Haptics.tap()
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(themes.current.ink)
                }
            }
        }
        .listRowBackground(Self.rowBackground)
    }
    #endif

    #if !APP_EXTENSION
    /// Never asked: the tap asks. Otherwise it opens this app's page in
    /// iPhone Settings, the only place the answer can change.
    private var notificationsRow: some View {
        Button {
            Haptics.tap()
            if notificationStatus == .notDetermined {
                Task {
                    await PushRegistrar.requestNow()
                    await refreshNotificationStatus()
                }
            } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                openURL(url)
            }
        } label: {
            HStack {
                SettingsRow(title: "Notifications", subtitle: notificationSummary)
                Spacer(minLength: 8)
                if notificationStatus != nil {
                    Text(notificationsOn ? "On" : "Off")
                        .foregroundStyle(AppBackground.secondaryInk)
                }
                Image(systemName: notificationStatus == .notDetermined ? "bell.badge" : "arrow.up.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppBackground.ink.opacity(0.45))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task { await refreshNotificationStatus() }
    }

    private var notificationsOn: Bool {
        [.authorized, .provisional, .ephemeral].contains(notificationStatus)
    }

    private var notificationSummary: String? {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: "Reminders, plans and what your group adds"
        case .denied: "Turn them on in iPhone Settings"
        case .notDetermined: "Tap to turn them on"
        default: nil
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    #endif

    @ViewBuilder private var accountPage: some View {
        List {
            if let email = auth.email {
                Section {
                    SettingsRow(title: email, subtitle: auth.usesApple ? "Signed in with Apple" : "Signed in")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Sync, honestly: when it last worked, what's still
                    // waiting on this phone, whether there's a route out,
                    // and a way to try now.
                    Button {
                        Haptics.tap()
                        Task {
                            await SupabaseSync.sync(context: context)
                            pending = SupabaseSync.pendingCount(context: context)
                            if SyncStatus.shared.problem == nil { Haptics.success() }
                        }
                    } label: {
                        LabeledContent {
                            if syncStatus.syncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Sync now")
                                    .font(.subheadline)
                                    .foregroundStyle(themes.current.ink)
                            }
                        } label: {
                            SettingsRow(title: syncStatus.online ? "Sync" : "Sync (offline)", subtitle: syncSummary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(syncStatus.syncing)
                    .accessibilityLabel("Sync now. \(syncSummary)")
                    if let problem = SyncStatus.shared.problem {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sync issue")
                                .fontWeight(.semibold)
                                .foregroundStyle(AppBackground.warning)
                            Text(problem.message)
                                .font(.subheadline)
                                .foregroundStyle(AppBackground.secondaryInk)
                            if let detail = problem.detail {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(AppBackground.secondaryInk.opacity(0.75))
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
                .listRowBackground(Self.rowBackground)

                Section {
                    Button {
                        Haptics.tap()
                        showExport = true
                    } label: {
                        HStack {
                            SettingsRow(title: "Export library")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppBackground.ink.opacity(0.45))
                        }
                    }
                } header: {
                    SettingsSectionHeader("Your saves")
                } footer: {
                    Text("A spreadsheet, a calendar file and a readable list, to keep or move elsewhere.")
                        .font(.footnote)
                        .foregroundStyle(AppBackground.secondaryInk)
                }
                .listRowBackground(Self.rowBackground)

                Section {
                    Button(role: .destructive) {
                        Haptics.tap()
                        confirmSignOut = true
                    } label: {
                        HStack {
                            SettingsRow(title: "Sign out", destructive: true)
                            Spacer()
                            if signingOut { ProgressView() }
                        }
                    }
                    .disabled(deleteBusy || signingOut)
                    .confirmationDialog(
                        "Sign out?",
                        isPresented: $confirmSignOut,
                        titleVisibility: .visible
                    ) {
                        Button("Sign out", role: .destructive) {
                            Task {
                                signingOut = true
                                let landed = await SupabaseSync.flushBeforeSignOut(context: context)
                                signingOut = false
                                if landed { signOut() } else { unsyncedOnSignOut = true }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Your saves stay on this phone. You can sign back in any time.")
                    }
                    .alert("Some changes haven\u{2019}t synced", isPresented: $unsyncedOnSignOut) {
                        Button("Stay signed in", role: .cancel) {}
                        Button("Sign out anyway", role: .destructive) { signOut() }
                    } message: {
                        Text("They\u{2019}ll sync when you sign back in. If a different account signs in on this phone first, they\u{2019}ll be lost.")
                    }
                    Button(role: .destructive) {
                        Haptics.tap()
                        deletePhrase = ""
                        deleteError = nil
                        confirmDelete = true
                    } label: {
                        HStack {
                            SettingsRow(title: "Delete account", destructive: true)
                            Spacer()
                            if deleteBusy { ProgressView() }
                        }
                    }
                    .disabled(deleteBusy)
                    .confirmationDialog(
                        "Delete your account?",
                        isPresented: $confirmDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Export my library first") {
                            deleteAfterExport = true
                            showExport = true
                        }
                        Button("Delete without a copy", role: .destructive) {
                            deletePhrase = ""
                            showDeleteConfirm = true
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(deleteAccountCopy)
                    }
                }
                .listRowBackground(Self.rowBackground)
            }
        }
        .settingsPage("Account")
    }

    /// A Settings-style value row: the title on the left, a menu picker as
    /// the small trailing value, matching the system Settings app.
    private func menuRow<P: View>(
        _ title: String, subtitle: String? = nil, @ViewBuilder picker: () -> P
    ) -> some View {
        // Not LabeledContent: with a subtitle it drops the menu onto a
        // line of its own.
        HStack(spacing: 8) {
            SettingsRow(title: title, subtitle: subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            picker()
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(AppBackground.secondaryInk)
                .fixedSize()
        }
        // The menu button is UIKit-backed and asks the cell for ~34pt via
        // Auto Layout, over SwiftUI's head; meet it, and trim the row insets
        // so the row still measures the same 52pt as its neighbours. Keep
        // `listRowInsets` the outermost modifier on the row — anything
        // wrapped around it hides the insets from the List.
        .frame(minHeight: 34)
        .listRowInsets(EdgeInsets(top: 9, leading: 20, bottom: 9, trailing: 20))
    }

    #if !APP_EXTENSION
    /// Everyone starts on the iPhone's default calendar with add-only
    /// access; the list, and the full-access prompt it needs, are only for
    /// someone who taps here asking for them.
    @ViewBuilder private var calendarRow: some View {
        if calendarAccess == .fullAccess {
            menuRow("Calendar", subtitle: Self.calendarNote) {
                // Unset follows the iPhone's default, shown by its name;
                // only a pick writes the setting.
                Picker(selection: Binding(
                    get: { calendarID.isEmpty ? (defaultCalendarID ?? "") : calendarID },
                    set: { calendarID = $0 }
                )) {
                    if defaultCalendarID == nil {
                        Text("Default").tag("")
                    }
                    ForEach(calendars) { calendar in
                        Text(calendar.name).tag(calendar.id)
                    }
                } label: { EmptyView() }
            }
            .sensoryFeedback(.selection, trigger: calendarID)
        } else {
            Button {
                Haptics.tap()
                Task {
                    _ = await CalendarChoice.requestFullAccess()
                    refreshCalendars()
                    calendarRefused = calendarAccess != .fullAccess
                }
            } label: {
                // Dressed as the picker it turns into once allowed.
                LabeledContent {
                    HStack(spacing: 5) {
                        Text("Default")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(AppBackground.secondaryInk)
                } label: {
                    SettingsRow(title: "Calendar", subtitle: Self.calendarNote)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose a calendar. iOS will ask to let Can We Go see your calendars.")
            .frame(minHeight: 34)
            .listRowInsets(EdgeInsets(top: 9, leading: 20, bottom: 9, trailing: 20))
        }
    }

    private static let calendarNote = "Where plans go when you add them to your calendar"

    /// A calendar that's gone falls back to the default, so the picker
    /// never shows a blank value.
    private func refreshCalendars() {
        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        calendars = CalendarChoice.options()
        let fallback = calendarAccess == .fullAccess
            ? EKEventStore().defaultCalendarForNewEvents?.calendarIdentifier : nil
        defaultCalendarID = calendars.contains { $0.id == fallback } ? fallback : nil
        if calendarAccess == .fullAccess, !calendarID.isEmpty,
           !calendars.contains(where: { $0.id == calendarID }) {
            calendarID = ""
        }
    }
    #endif

    /// Writes the store; the window cross-fades in one step, and the
    /// home-screen icon follows right away. iOS confirms every icon change
    /// with its own alert — there is no public way around that, so it
    /// simply lands here, on the pick, where the user expects it.
    private var theme: Binding<AppTheme> {
        Binding(
            get: { themes.current },
            set: { new in
                themes.select(new)
                themes.syncAppIconWhenSettled()
            }
        )
    }

    /// Flip the home-screen icon to the chosen theme. Also runs when the
    /// sheet closes, as a catch-up if the immediate call was skipped (the
    /// system refuses icon changes while the app isn't active).
    private func syncAppIcon() {
        themes.syncAppIcon()
    }

    private var deleteAccountCopy: String {
        let shared = (GroupStore.shared.card?.members.count ?? 0) > 1
        if shared {
            return "Your group keeps the library. Export first if you want your own copy."
        }
        return "This deletes your library too. Export first if you want a copy."
    }

    /// RootGate resets the cursor and group card on any sign-out, this one
    /// included. Dismiss so the sign-in screen isn't trapped under this
    /// sheet.
    private func signOut() {
        SupabaseAuth.shared.signOut()
        dismiss()
    }

    private func deleteAccount() async {
        guard deletePhrase.trimmingCharacters(in: .whitespaces) == "DELETE" else { return }
        deleteBusy = true
        defer { deleteBusy = false }
        do {
            var payload: [String: String] = [:]
            if SupabaseAuth.appleUserID != nil {
                do {
                    payload["apple_code"] = try await AppleSignIn.codeForDeletion(using: authorizationController)
                } catch {
                    return // cancelled the Apple sheet: nothing deleted
                }
            }
            let jwt = try await SupabaseAuth.shared.validToken()
            var request = URLRequest(url: SupabaseAuth.baseURL.appending(path: "functions/v1/delete-account"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                throw SupabaseAuth.AuthError(message: message ?? "Delete failed (\(status)).", status: status)
            }
            SupabaseSync.wipeLocalLibrary(context: context)
            SharedInbox.removeAll()
            #if !APP_EXTENSION
            OnboardingGate.clearSkip()
            #endif
            HomeStore.shared.signedOut()
            GroupStore.shared.signedOut()
            SupabaseAuth.shared.signOut()
            dismiss()
        } catch {
            deleteError = SyncProblem(error).message
        }
    }

}

// MARK: - Toolbar hook

/// Gear button + sheet, self-contained so callers can slot it anywhere in
/// a toolbar and control the ordering explicitly.
struct SettingsButton: View {
    @State private var open = false

    var body: some View {
        Button {
            Haptics.tap()
            open = true
        } label: {
            // Softened white at semibold — bright icons shouted over the
            // content; all three header icons match.
            Image(systemName: "gearshape")
                .fontWeight(.semibold)
                .foregroundStyle(AppBackground.ink.opacity(0.72))
                .redrawnPerTheme()
        }
        .accessibilityLabel("Settings")
        // Explicit accent: this sheet is presented from inside the nav bar's
        // dimmed-white tint scope, which would otherwise wash its controls.
        .sheet(isPresented: $open) { SettingsView().tint(AppBackground.ink) }
        // CWG_SETTINGS is only set by automated test runs. Once per launch:
        // every tab has its own gear, and the next tab's would open it again.
        .task {
            if ProcessInfo.processInfo.environment["CWG_SETTINGS"] != nil, !Self.openedForTest {
                Self.openedForTest = true
                open = true
            }
        }
    }

    @MainActor private static var openedForTest = false
}

private extension View {
    /// Every Settings page: the theme's sheet, its ink, rows of one
    /// height, the title in the display face and the close button.
    func settingsPage(_ title: String?) -> some View {
        modifier(SettingsPageChrome(title: title))
    }
}

private struct SettingsPageChrome: ViewModifier {
    let title: String?
    @Environment(\.dismiss) private var dismiss
    @State private var themes = ThemeStore.shared

    func body(content: Content) -> some View {
        content
            .environment(\.defaultMinListRowHeight, 52)
            .appBackground(AppBackground.sheet)
            .appColorScheme()
            .tint(themes.current.ink)
            .navigationTitle(title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let title {
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(.displaySmallBold(20, relativeTo: .headline))
                            .foregroundStyle(AppBackground.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
    }
}
