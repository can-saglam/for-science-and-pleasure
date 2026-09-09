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
        // The store is local only. Supabase is the sync — one source of
        // truth, scoped to the signed-in account's group by RLS. This store
        // used to be mirrored to the user's private iCloud database as well,
        // and that mirror resurrected an old library into the app after a
        // reinstall or an account change (another person signing in on the
        // same phone saw the previous member's saves; deleted rows came
        // back as duplicates). Same store name, so existing data opens as-is.
        do {
            let local = ModelConfiguration("CanWeGo", cloudKitDatabase: .none)
            container = try ModelContainer(for: Item.self, configurations: local)
        } catch {
            // A store this build can't open (corrupt file, downgrade): keep
            // the app usable on a fresh one; the next sync refills it.
            do {
                let fallback = ModelConfiguration("CanWeGo-local", cloudKitDatabase: .none)
                container = try ModelContainer(for: Item.self, configurations: fallback)
            } catch {
                fatalError("Could not create any model container: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootGate()
        }
        .modelContainer(container)
    }
}

/// Sign-in gate: the shared library needs a member session before anything
/// else. CWG_SKIP_AUTH keeps automated screenshot runs on local demo data.
private struct RootGate: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var auth = SupabaseAuth.shared

    var body: some View {
        Group {
            if auth.signedIn || ProcessInfo.processInfo.environment["CWG_SKIP_AUTH"] != nil {
                gated
            } else {
                AuthView()
            }
        }
        // Every way out — Settings, an expired session, Apple revoking the
        // app — leaves the sync cursor and the group card as a fresh sign-in
        // expects. The library itself stays; the engine decides its fate
        // when the next account's first sync sees who owns it.
        .onChange(of: auth.signedIn) { _, signedIn in
            if !signedIn {
                SupabaseSync.resetCursor()
                GroupStore.shared.signedOut()
            }
        }
    }

    private var gated: some View {
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
                if phase == .active { PushRegistrar.register() }
            }
    }
}

/// Registers this phone for APNs and parks the token in Supabase, so the
/// other member's saves can ping it. Lives here (not in Support/) because
/// UIApplication is off-limits inside the share extension.
final class PushRegistrar: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Asks for the alert permission once (without it iOS delivers pushes
    /// silently to nowhere), then registers for a device token. Safe to call
    /// on every foreground — both steps are idempotent.
    static func register() {
        guard SupabaseAuth.shared.signedIn else { return }
        guard ProcessInfo.processInfo.environment["CWG_NO_PROMPTS"] == nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if userInfo["digest"] != nil {
            await MainActor.run {
                DigestGate.pending = true
                NotificationCenter.default.post(name: .cwgOpenDigest, object: nil)
            }
        } else if let id = (userInfo["itemID"] as? String).flatMap(UUID.init) {
            // A last-chance nudge: open the event it's about.
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
              let device = await UIDevice.current.identifierForVendor?.uuidString
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
