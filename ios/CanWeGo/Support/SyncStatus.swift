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

    /// False only before the very first successful pull on this install.
    var hasSyncedOnce: Bool { lastSyncedAt != nil }

    private init() {
        let defaults = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
        lastSyncedAt = defaults.object(forKey: "supabaseLastSyncAt") as? Date
    }
}
