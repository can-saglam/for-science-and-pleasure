import SwiftData
import SwiftUI

@main
struct CanWeGoApp: App {
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar
    let container: ModelContainer

    init() {
        do {
            let cloud = ModelConfiguration(
                "CanWeGo",
                cloudKitDatabase: .private("iCloud.com.cansaglam.CanWeGo")
            )
            container = try ModelContainer(for: Item.self, configurations: cloud)
        } catch {
            // No iCloud account / entitlement (e.g. plain simulator): keep the
            // app usable with a local store instead of dying at launch.
            do {
                let local = ModelConfiguration("CanWeGo-local", cloudKitDatabase: .none)
                container = try ModelContainer(for: Item.self, configurations: local)
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
    @State private var auth = SupabaseAuth.shared

    var body: some View {
        if auth.signedIn || ProcessInfo.processInfo.environment["CWG_SKIP_AUTH"] != nil {
            ContentView()
                .task { PushRegistrar.register() }
        } else {
            AuthView()
        }
    }
}

/// Registers this phone for APNs and parks the token in Supabase, so the
/// other member's saves can ping it. Lives here (not in Support/) because
/// UIApplication is off-limits inside the share extension.
final class PushRegistrar: NSObject, UIApplicationDelegate {
    /// No prompt involved — the alert permission is requested separately
    /// (LastChanceNotifier); registration itself is silent and idempotent.
    static func register() {
        guard SupabaseAuth.shared.signedIn else { return }
        guard ProcessInfo.processInfo.environment["CWG_NO_PROMPTS"] == nil else { return }
        UIApplication.shared.registerForRemoteNotifications()
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

    private static func upload(token: String) async {
        guard let email = SupabaseAuth.shared.email,
              let jwt = try? await SupabaseAuth.shared.validToken()
        else { return }
        var request = URLRequest(
            url: SupabaseAuth.baseURL.appending(path: "rest/v1/apns_tokens")
        )
        request.httpMethod = "POST"
        request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            "email": email,
        ])
        _ = try? await URLSession.shared.data(for: request)
    }
}
