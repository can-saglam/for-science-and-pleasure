import Foundation
import Network
import Observation

/// Observable mirror of the sync engine's state, for the UI: the first-pull
/// loading screen, pull-to-refresh, "Last synced" in Settings, and the
/// stale-sync banner on the library.
@Observable
final class SyncStatus {
    static let shared = SyncStatus()

    var syncing = false
    var lastSyncedAt: Date?
    /// Why the last sync round failed, if it did — shown on the stale
    /// banner and in Settings so a broken sync is never invisible.
    var problem: SyncProblem?

    /// Whether the phone currently has a route to the internet. Offline is
    /// a normal state and never a warning; "online but not syncing" is.
    var online = true
    /// The banner is dismissible, but it comes back after a day of the same.
    var staleBannerDismissedAt: Date?

    /// A day without a successful sync while the phone has been online is
    /// the signal something is wrong on our side (a dead session, a broken
    /// build, the server) — not a tunnel or a flight. Never fires before the
    /// first pull, which has its own loading screen.
    var isStale: Bool {
        guard online, !updateRequired, let last = lastSyncedAt else { return false }
        guard Date.now.timeIntervalSince(last) > 24 * 3600 else { return false }
        if let dismissed = staleBannerDismissedAt,
           Date.now.timeIntervalSince(dismissed) < 24 * 3600 {
            return false
        }
        return true
    }

    @ObservationIgnored
    private let monitor = NWPathMonitor()

    /// The server says this build is too old to sync (`app_config.min_build`).
    /// While true, the app shows the update screen and every write path
    /// stays offline — a stale client must never push stale rows.
    var updateRequired = false
    /// Where the update button goes: TestFlight during beta, the App Store
    /// listing later. Server-provided so the switch needs no release.
    var storeURL: URL?

    /// False only before the very first successful pull on this install.
    var hasSyncedOnce: Bool { lastSyncedAt != nil }

    private init() {
        let defaults = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
        lastSyncedAt = defaults.object(forKey: "supabaseLastSyncAt") as? Date
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.online = up }
        }
        monitor.start(queue: DispatchQueue(label: "cwg.netpath", qos: .utility))
    }
}

/// A sync failure in two registers: `message` is a sentence for the banner
/// ("Changes on this phone haven't reached the server yet."), `detail` is
/// the raw evidence for Settings (`Push failed (400): {"code":"PGRST102"…`).
/// Nobody should ever read JSON off a banner.
struct SyncProblem: Error, Equatable {
    var message: String
    var detail: String?
    /// HTTP status when the server itself answered; 0 for network trouble.
    var status = 0

    /// A 400/409/422 means the *payload* was refused — the one class of
    /// failure that retrying can't fix and that may be one row's fault.
    var rowRejected: Bool { [400, 409, 422].contains(status) }

    /// Translates whatever the engine threw into something a person can act on.
    init(_ error: Error) {
        if let problem = error as? SyncProblem {
            self = problem
            return
        }
        if let auth = error as? SupabaseAuth.AuthError {
            self.init(
                message: auth.status == 0 && auth.message == "Signed out."
                    ? "You've been signed out. Sign in again from Settings."
                    : "Couldn't confirm who you are. Try signing in again.",
                detail: auth.message,
                status: auth.status
            )
            return
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                self.init(message: "No internet connection.", detail: url.localizedDescription)
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                self.init(message: "Couldn't reach the server. It may be down for a moment.", detail: url.localizedDescription)
            default:
                self.init(message: "Couldn't reach the server.", detail: url.localizedDescription)
            }
            return
        }
        if error is DecodingError || error is EncodingError {
            self.init(message: "The server sent something this version doesn't understand.", detail: String(describing: error))
            return
        }
        self.init(message: "Something went wrong while syncing.", detail: error.localizedDescription)
    }

    init(message: String, detail: String? = nil, status: Int = 0) {
        self.message = message
        self.detail = detail
        self.status = status
    }
}
