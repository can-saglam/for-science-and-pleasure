import CoreData
import SQLite3
import SwiftData
import SwiftUI
import UserNotifications

@main
struct CanWeGoApp: App {
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar
    let container: ModelContainer

    init() {
        // Sets the home clock from the cache before any time label renders.
        _ = HomeStore.shared
        ShareTip.configure()
        container = LibraryStore.container
    }

    var body: some Scene {
        WindowGroup {
            RootGate()
        }
        .modelContainer(container)
    }
}

/// The one library store, shared by the scene and by Siri and Shortcuts,
/// which can run with no screen up.
@MainActor
enum LibraryStore {
    static let container: ModelContainer = {
        // The store is local only. Supabase is the sync — one source of
        // truth, scoped to the signed-in account's group by RLS. This store
        // used to be mirrored to the user's private iCloud database as well,
        // and that mirror resurrected an old library into the app after a
        // reinstall or an account change (another person signing in on the
        // same phone saw the previous member's saves; deleted rows came
        // back as duplicates). Same store name, so existing data opens as-is.
        let local = ModelConfiguration("CanWeGo", cloudKitDatabase: .none)
        if let container = open(local) { return container }
        switch health(of: local.url) {
        case .corrupt, .otherModel:
            // A store this build can never open (a damaged file, a
            // downgrade): its files go aside, unsynced edits and all, for
            // recovery by hand, and a fresh store fills from a full pull.
            // The sync cursor belongs to the old file, so it goes too.
            print("[store] the library can't be opened by this build, setting it aside")
            setAside(local.url)
            SupabaseSync.resetCursor()
            if let container = open(local) { return container }
        case .unreadable:
            // Readable later (the phone not yet unlocked since a restart,
            // a full disk): the store stays put, and this launch runs on
            // an empty stand-in that nothing is synced or mirrored from.
            print("[store] the library can't be read right now")
        }
        StandInStore.active = true
        SyncStatus.shared.problem = SyncProblem(
            message: "Couldn\u{2019}t open your saves on this phone. Close Can We Go and open it again."
        )
        do {
            return try ModelContainer(for: Item.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("Could not create any model container: \(error)")
        }
    }()

    /// The versioned schema first; a store from before it (or one SwiftData
    /// can migrate by itself) opens the plain way.
    private static func open(_ local: ModelConfiguration) -> ModelContainer? {
        do {
            return try ModelContainer(
                for: Schema(versionedSchema: LibrarySchemaV1.self),
                migrationPlan: LibraryMigrations.self,
                configurations: local
            )
        } catch {
            print("[store] versioned open failed: \(error)")
        }
        do {
            return try ModelContainer(for: Item.self, configurations: local)
        } catch {
            print("[store] open failed: \(error)")
            return nil
        }
    }

    private enum Health {
        case corrupt, otherModel, unreadable
    }

    /// Why a store didn't open. Only a file SQLite itself calls damaged, or
    /// one written for a model this build doesn't know, is beyond a retry.
    private static func health(of store: URL) -> Health {
        guard FileManager.default.fileExists(atPath: store.path(percentEncoded: false)) else { return .unreadable }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        func failure() -> Health {
            let code = sqlite3_extended_errcode(db) & 0xff
            return code == SQLITE_CORRUPT || code == SQLITE_NOTADB ? .corrupt : .unreadable
        }
        guard sqlite3_open_v2(store.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return failure() }
        var check: OpaquePointer?
        defer { sqlite3_finalize(check) }
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK,
              sqlite3_step(check) == SQLITE_ROW
        else { return failure() }
        guard let text = sqlite3_column_text(check, 0), String(cString: text) == "ok" else { return .corrupt }
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: store),
              let model = NSManagedObjectModel.makeManagedObjectModel(for: [Item.self])
        else { return .unreadable }
        return model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) ? .unreadable : .otherModel
    }

    /// Moves a store's files (with its -wal and -shm) into
    /// Application Support/Set aside.
    private static func setAside(_ store: URL) {
        let files = FileManager.default
        let folder = URL.applicationSupportDirectory.appending(path: "Set aside", directoryHint: .isDirectory)
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date.now.timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(filePath: store.path(percentEncoded: false) + suffix)
            guard files.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
            try? files.moveItem(at: file, to: folder.appending(path: "\(stamp)-\(file.lastPathComponent)"))
        }
    }
}

/// Sign-in gate: the shared library needs a member session before anything
/// else. The front door is onboarding's welcome page with Sign in with
/// Apple on it; `AuthView` only returns for an expired session.
/// CWG_SKIP_AUTH keeps automated screenshot runs on local demo data.
private struct RootGate: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @State private var auth = SupabaseAuth.shared
    @State private var phase: Phase = .checking

    private enum Phase { case checking, onboard, ready }

    var body: some View {
        gated
        // Every way out — Settings, an expired session, Apple revoking the
        // app — leaves the sync cursor and the group card as a fresh sign-in
        // expects. The library itself stays; the engine decides its fate
        // when the next account's first sync sees who owns it.
        .onChange(of: auth.signedIn) { _, signedIn in
            if !signedIn {
                SupabaseSync.resetCursor()
                GroupStore.shared.signedOut()
                HomeStore.shared.signedOut()
                Task { await LiveDay.signedOut() }
                phase = .checking
            } else {
                cameFromFrontDoor = true
                Task { await decideOnboarding() }
                Task { await PlusStore.shared.reconcile() }
            }
        }
        .task {
            // Before anything else can buy: StoreKit delivers renewals and
            // purchases from other devices to whoever is listening.
            PlusStore.shared.start()
            if auth.signedIn { await decideOnboarding() }
        }
        // A theme for Light mode and one for Dark: the phone may have
        // changed while the app was away (or Control Centre was over it),
        // and can change on its schedule while the app is open.
        .task(id: scenePhase == .active && ThemeStore.shared.followsSystem) {
            guard scenePhase == .active, ThemeStore.shared.followsSystem else { return }
            while !Task.isCancelled {
                ThemeStore.shared.catchUpWithSystem()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        // The first run's theme choice reaches the home-screen icon here,
        // in the background, where iOS swaps it without the alert.
        .onChange(of: scenePhase) { old, phase in
            if phase == .background { ThemeStore.shared.syncAppIconIfPending() }
            if phase == .active, old == .background { Task { await PlusStore.shared.reconcile() } }
        }
        // An invite link. Parked for whichever screen can use it: the
        // first-run's code page (a new install), or the Join sheet.
        // A save link likewise, for the library to open once it's up.
        .onOpenURL { url in
            if let token = SaveLink.token(from: url) {
                ShareGate.pendingToken = token
                NotificationCenter.default.post(name: .cwgSharedSave, object: token)
                return
            }
            guard let code = JoinGate.code(from: url) else { return }
            JoinGate.pendingCode = code
            NotificationCenter.default.post(name: .cwgJoinCode, object: code)
        }
    }

    private var skipAuth: Bool {
        ProcessInfo.processInfo.environment["CWG_SKIP_AUTH"] != nil
    }

    /// Screenshot runs of first-run: the same preview Settings offers.
    /// Closing it drops through to the normal app.
    @State private var onboardingPreview =
        ProcessInfo.processInfo.environment["CWG_ONBOARDING_PREVIEW"] != nil

    @ViewBuilder
    private var gated: some View {
        if onboardingPreview {
            OnboardingView(onFinished: { onboardingPreview = false }, preview: true)
        } else if skipAuth {
            ready
        } else if !auth.signedIn || phase == .onboard {
            // One branch for "not signed in yet" (including a lapsed
            // session, which the welcome page explains) and "signed in,
            // still onboarding", so the view keeps its identity (and its
            // page) across the sign-in itself.
            OnboardingView {
                phase = .ready
            }
        } else if phase == .ready {
            ready
        } else {
            ZStack {
                ThemeFill(color: AppBackground.base)
                // Usually gone within a few frames (photos warming, the
                // card check); the spinner is only for a real wait.
                DelayedSpinner()
            }
            .appColorScheme()
        }
    }

    /// Founders and a second device already have a name and a home on the
    /// card — land in the library. A new Apple account has neither yet.
    /// Straight after a front-door sign-in the onboarding view is already
    /// on screen, so this never drops to the spinner in between.
    private func decideOnboarding() async {
        if OnboardingGate.isComplete {
            await warmFirstScreen()
            phase = .ready
            await refreshMembership()
            if !OnboardingGate.isComplete { phase = .onboard }
            return
        }
        phase = phase == .checking && !cameFromFrontDoor ? .checking : .onboard
        await refreshMembership()
        if OnboardingGate.isComplete {
            phase = .ready
        } else if GroupStore.shared.card == nil, !cameFromFrontDoor {
            // Launched offline with a session but no cached card (a fresh
            // install of an existing account): the server wasn't reached,
            // so nothing is known. The library, empty until sync, is the
            // honest place; first-run questions here would be wrong ones.
            // (From the front door the onboarding view handles this
            // itself, with a retry.)
            phase = .ready
        } else {
            phase = .onboard
        }
    }

    /// True when the sign-in just happened on the welcome page, rather
    /// than the session being restored at launch.
    @State private var cameFromFrontDoor = false

    /// The first screenful of photos, from disk into memory, before the
    /// library is shown, so its cards come up with them instead of a few
    /// frames later. Capped: a slow disk never holds the app back for long.
    private func warmFirstScreen() async {
        let items = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        await ImageStore.warm(Array(ContentView.prewarmURLs(items).prefix(8)), within: .milliseconds(400))
    }

    private func refreshMembership() async {
        await GroupStore.shared.refresh()
        await MembersStore.shared.refresh()
        await HomeStore.shared.refresh()
    }

    private var ready: some View {
        ContentView()
            .task {
                PushRegistrar.register()
                // Apple lets people revoke an app in Settings; a revoked
                // account must not carry on syncing. Local data stays put.
                await AppleSignIn.checkCredentialState()
            }
            // Re-register on every foreground: uploading the token is
            // idempotent, and it self-heals a device whose first upload
            // failed (offline, expired session…).
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    PushRegistrar.register()
                    ThemeStore.shared.applyInterfaceStyle()
                }
            }
    }
}

private struct DelayedSpinner: View {
    @State private var shown = false

    var body: some View {
        ProgressView()
            .opacity(shown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(600))
                shown = true
            }
    }
}

/// Registers this phone for APNs and parks the token in Supabase, so the
/// other member's saves can ping it. Lives here (not in Support/) because
/// UIApplication is off-limits inside the share extension.
final class PushRegistrar: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Info.plist lists landscape for iPhone Duo; everywhere else the app
    /// stays portrait, as it always has.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Foldable.rotates(window) ? .allButUpsideDown : .portrait
    }

    /// Signs this phone up for pushes. Never raises the system prompt: a
    /// returning account would meet it cold, over the library. That comes
    /// only from a moment that says what it's for (`requestNow`).
    static func register() {
        guard SupabaseAuth.shared.signedIn else { return }
        Task {
            await clearRetiredLocalNotifications()
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Raise the system prompt now, over whatever explained it: the first
    /// run's "Notify me", the Notifications row in Settings, or choosing a
    /// reminder. Returns once it's answered so the flow can finish *after*
    /// rather than under it.
    static func requestNow() async {
        guard SupabaseAuth.shared.signedIn else { return }
        guard ProcessInfo.processInfo.environment["CWG_NO_PROMPTS"] == nil else { return }
        await clearRetiredLocalNotifications()
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Last-chance used to schedule one local notification per dated event.
    /// Those requests survive until we cancel them; do it once after the kill.
    private static func clearRetiredLocalNotifications() async {
        let defaults = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
        let key = "clearedRetiredLocals"
        guard !defaults.bool(forKey: key) else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix("lastchance-") }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        defaults.set(true, forKey: key)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        LiveDay.listen()
        MetricReporter.shared.start()
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let data = userInfo["pick"] as? Data,
           let pick = try? JSONDecoder().decode(ParseClient.Suggestion.self, from: data) {
            // The second-save nudge: open Add on its pick.
            await MainActor.run { SuggestionChips.open(pick) }
        }
        if let id = (userInfo["itemID"] as? String).flatMap(UUID.init) {
            // A reminder (or Spotlight) tap: open the save it's about.
            await MainActor.run {
                ItemGate.pending = id
                NotificationCenter.default.post(name: .cwgOpenItem, object: id)
            }
        }
    }

    /// Pushes still show as banners while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await Self.upload(token: token) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Simulator or missing entitlement — fine, just no pushes here.
    }

    /// One row per device: `register_apns_token` replaces whatever this
    /// device registered before (and sweeps the account's legacy rows), and
    /// records the build so `min_build` can be raised on evidence.
    private static func upload(token: String) async {
        guard let jwt = try? await SupabaseAuth.shared.validToken(),
              let device = UIDevice.current.identifierForVendor?.uuidString
        else { return }
        #if targetEnvironment(simulator)
        let platform = "simulator"
        #else
        let platform = "ios"
        #endif
        var request = URLRequest(
            url: SupabaseAuth.baseURL.appending(path: "rest/v1/rpc/register_apns_token")
        )
        request.httpMethod = "POST"
        request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "p_token": token,
            "p_device_id": device,
            "p_build": SupabaseSync.buildNumber,
            "p_platform": platform,
        ] as [String: Any])
        // One quick retry — a dropped upload here used to mean this phone
        // silently never received partner pushes.
        for attempt in 0..<2 {
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
                return
            }
            if attempt == 0 { try? await Task.sleep(for: .seconds(2)) }
        }
    }
}
