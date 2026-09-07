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
    /// Why the last sync round failed, if it did — shown in Settings so a
    /// broken sync is never invisible.
    var problem: String?

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
