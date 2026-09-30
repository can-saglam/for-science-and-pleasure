import CoreLocation
import EventKit
import SwiftData

// Actions shared by the detail sheet, swipe actions, and context menus.
extension Item {
    var isDeleted: Bool { deletedAt != nil }

    /// Who saved or last edited this, for sync salvage and "Added by".
    func stampAuthor() {
        let me = SupabaseAuth.shared.userId
        if createdBy == nil { createdBy = me }
        updatedBy = me
        if addedByEmail == nil { addedByEmail = SupabaseAuth.shared.email }
    }

    func softDelete() {
        deletedAt = .now
        updatedAt = .now
        stampAuthor()
        try? modelContext?.save()
        let id = self.id
        Task { @MainActor in SupabaseSync.setDeleted(id, true) }
    }

    func markDone() {
        status = Item.Status.done
        clearReminder()
        updatedAt = .now
        stampAuthor()
        try? modelContext?.save()
    }

    /// Back from We Did Go to the active library. A plan it went with is
    /// history now, not a question for tomorrow morning.
    func putBack() {
        status = Item.Status.saved
        if let planOn, planOn < DayString.today() { clearPlan() }
        updatedAt = .now
        stampAuthor()
        try? modelContext?.save()
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// "Venue, Area, London" — what a maps app should search for. Nil when
    /// the save names no place (an event with only a title).
    var placeQuery: String? {
        guard let place = venue ?? (kind == Item.Kind.place ? title : nil) else { return nil }
        let city = HomeStore.cached()?.locality
        return ([place, area, city].compactMap(\.self)).joined(separator: ", ")
    }

    /// Wherever the user chose to get directions (Settings → Directions).
    var directionsURL: URL? { TransportApp.current.url(for: self) }

    /// Google Maps link, built on the fly — the app opens it directly if
    /// installed, the web version otherwise. A named search gets the full
    /// place card (hours, photos); coordinates are the fallback pin.
    var googleMapsURL: URL? {
        let query: String
        if let placeQuery {
            query = placeQuery
        } else if let coordinate {
            query = "\(coordinate.latitude),\(coordinate.longitude)"
        } else {
            return nil
        }
        var components = URLComponents(string: "https://www.google.com/maps/search/")!
        components.queryItems = [
            .init(name: "api", value: "1"),
            .init(name: "query", value: query),
        ]
        return components.url
    }

    /// The plan, when there is one: its time for a couple of hours, or its
    /// day. Otherwise an all-day event spanning the item's window.
    func addToCalendar() async throws {
        let plan = upcomingPlan
        guard let start = (plan ?? startsOn).flatMap(DayString.date) else { return }
        let store = EKEventStore()
        guard try await store.requestWriteOnlyAccessToEvents() else {
            throw NSError(
                domain: "CanWeGo", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Calendar access was declined."]
            )
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        if plan != nil, let at = planInstant {
            event.timeZone = DayString.timeZone
            event.startDate = at
            event.endDate = at.addingTimeInterval(Item.planCalendarHours * 3600)
        } else {
            event.isAllDay = true
            event.startDate = start
            event.endDate = plan == nil ? endsOn.flatMap(DayString.date) ?? start : start
        }
        event.location = [venue, area].compactMap(\.self).joined(separator: ", ")
        event.notes = [summary, url].compactMap(\.self).joined(separator: "\n\n")
        event.calendar = CalendarChoice.calendar(in: store) ?? store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }
}
