import CoreLocation
import EventKit
import SwiftData

// Actions shared by the detail sheet, swipe actions, and context menus.
extension Item {
    func markDone() {
        status = Item.Status.done
        clearReminder()
        updatedAt = .now
        try? modelContext?.save()
    }

    /// Back from We Did Go to the active library.
    func putBack() {
        status = Item.Status.saved
        updatedAt = .now
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
        let city = HomeStore.cached()?.locality ?? "London"
        return ([place, area].compactMap(\.self) + [city]).joined(separator: ", ")
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

    /// All-day calendar event spanning the item's window.
    func addToCalendar() async throws {
        guard let start = startsOn.flatMap(DayString.date) else { return }
        let store = EKEventStore()
        guard try await store.requestWriteOnlyAccessToEvents() else {
            throw NSError(
                domain: "CanWeGo", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Calendar access was declined."]
            )
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.isAllDay = true
        event.startDate = start
        event.endDate = endsOn.flatMap(DayString.date) ?? start
        event.location = [venue, area].compactMap(\.self).joined(separator: ", ")
        event.notes = [summary, url].compactMap(\.self).joined(separator: "\n\n")
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }
}
