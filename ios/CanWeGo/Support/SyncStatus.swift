import Foundation
import Observation

/// Observable mirror of the sync engine's state, for the UI: the first-pull
/// loading screen, pull-to-refresh, and "Last synced" in Settings.
@Observable
final class SyncStatus {
    static let shared = SyncStatus()

    var syncing = false
    var lastSyncedAt: Date?
    /// Why the last sync round failed, if it did — shown in Settings so a
    /// broken sync is never invisible.
    var problem: String?

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
    }
}
