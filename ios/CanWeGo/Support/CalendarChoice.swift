import EventKit

/// Which calendar "Add to calendar" writes into. Unset — the default — is
/// the iPhone's own default calendar, reached with add-only access.
/// Picking one needs full access, so iOS's see-all-your-events prompt only
/// ever appears to someone who asks for it in Settings.
enum CalendarChoice {
    static let key = "calendarID"

    static var hasFullAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// The chosen calendar, while it still exists, takes new events and
    /// access hasn't been taken back — otherwise nil, and the event goes
    /// to the default calendar as before.
    static func calendar(in store: EKEventStore) -> EKCalendar? {
        guard hasFullAccess,
              let id = UserDefaults.standard.string(forKey: key), !id.isEmpty,
              let calendar = store.calendar(withIdentifier: id),
              calendar.allowsContentModifications
        else { return nil }
        return calendar
    }

    struct Option: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// Calendars that take new events, grouped by account; empty without
    /// full access. A title two accounts share reads "Home · iCloud".
    static func options() -> [Option] {
        guard hasFullAccess else { return [] }
        let calendars = EKEventStore().calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted {
                ($0.source.title, $0.title.localizedLowercase)
                    < ($1.source.title, $1.title.localizedLowercase)
            }
        let titles = Dictionary(grouping: calendars, by: \.title)
        return calendars.map { calendar in
            let shared = (titles[calendar.title]?.count ?? 0) > 1
            return Option(
                id: calendar.calendarIdentifier,
                name: shared ? "\(calendar.title) · \(calendar.source.title)" : calendar.title
            )
        }
    }

    /// Asks for full access, and returns whether it was given. Someone who
    /// has never added an event is asked for add-only access first, so
    /// turning down the bigger ask leaves Add to calendar working.
    static func requestFullAccess() async -> Bool {
        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await store.requestWriteOnlyAccessToEvents()
        }
        if EKEventStore.authorizationStatus(for: .event) == .writeOnly {
            _ = try? await store.requestFullAccessToEvents()
        }
        return hasFullAccess
    }
}
