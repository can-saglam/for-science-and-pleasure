import AppIntents
import Foundation
import GeoToolbox

// iOS 27's Siri adds events through the Calendar schema: "Add the Amar
// Kanwar exhibition at Serpentine to Can We Go" is an event to Siri, not a
// list item, so the Reminders route (SiriLists) never gets the sentence.
// Can We Go is one calendar here. The event Siri describes is looked up,
// read back and parked like any Siri add; the schema's other fields are
// accepted and ignored.

@available(iOS 27.0, *)
@AppEntity(schema: .calendar.calendar)
struct SaveCalendarEntity {
    static let defaultQuery = SaveCalendarQuery()

    let id: String
    var title: String

    static let canWeGo = SaveCalendarEntity(id: "canwego", title: "Can We Go")

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "calendar"))
    }
}

@available(iOS 27.0, *)
struct SaveCalendarQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SaveCalendarEntity] {
        identifiers.contains(SaveCalendarEntity.canWeGo.id) ? [.canWeGo] : []
    }

    func entities(matching string: String) async throws -> [SaveCalendarEntity] {
        [.canWeGo]
    }

    func suggestedEntities() async throws -> [SaveCalendarEntity] {
        [.canWeGo]
    }
}

@available(iOS 27.0, *)
@AppEnum(schema: .calendar.attendeeType)
enum SaveAttendeeType: String {
    case person

    static let caseDisplayRepresentations: [SaveAttendeeType: DisplayRepresentation] = [
        .person: "Person",
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .calendar.attendeeStatus)
enum SaveAttendeeStatus: String {
    case accepted
    case tentative
    case declined

    static let caseDisplayRepresentations: [SaveAttendeeStatus: DisplayRepresentation] = [
        .accepted: "Accepted",
        .tentative: "Tentative",
        .declined: "Declined",
    ]
}

/// Saves have no guests; the schema asks for the type all the same.
@available(iOS 27.0, *)
@AppEntity(schema: .calendar.attendee)
struct SaveAttendeeEntity {
    static let defaultQuery = SaveAttendeeQuery()

    let id: String
    var person: IntentPerson
    var isAttendanceOptional: Bool
    var status: SaveAttendeeStatus?
    var type: SaveAttendeeType?

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

@available(iOS 27.0, *)
@UnionValue
enum SaveEventLocation {
    case place(PlaceDescriptor)
    case text(String)
}

@available(iOS 27.0, *)
@UnionValue
enum SaveEventAlarm {
    case before(Duration)
    case at(Date)
}

@available(iOS 27.0, *)
struct SaveAttendeeQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SaveAttendeeEntity] { [] }
    func entities(matching string: String) async throws -> [SaveAttendeeEntity] { [] }
}

@available(iOS 27.0, *)
@AppEnum(schema: .calendar.eventStatus)
enum SaveEventStatus: String {
    case confirmed
    case tentative
    case cancelled

    static let caseDisplayRepresentations: [SaveEventStatus: DisplayRepresentation] = [
        .confirmed: "Confirmed",
        .tentative: "Tentative",
        .cancelled: "Cancelled",
    ]
}

/// A save as a calendar event: its dates all-day, the venue as the
/// location, the summary as the note.
@available(iOS 27.0, *)
@AppEntity(schema: .calendar.event)
struct SaveEventEntity {
    static let defaultQuery = SaveEventQuery()

    let id: UUID
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var location: SaveEventLocation?
    var note: String?
    var calendar: SaveCalendarEntity
    var attendees: [SaveAttendeeEntity]
    var organizers: [IntentPerson]
    var alarms: [SaveEventAlarm]
    var recurrence: Calendar.RecurrenceRule?
    var status: SaveEventStatus?
    var travelTime: Duration?
    var virtualLocation: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: note.map { "\($0)" })
    }

    @MainActor
    init(_ item: Item) {
        self.init(
            id: item.id, title: item.title, startsOn: item.startsOn, endsOn: item.endsOn,
            venue: item.venue, summary: item.summary
        )
    }

    /// What Siri gets back for a save still on its way from the inbox.
    init(id: UUID, card: ParseClient.Card) {
        self.init(
            id: id, title: card.title, startsOn: card.starts_on, endsOn: card.ends_on,
            venue: card.venue, summary: card.summary
        )
    }

    private init(id: UUID, title: String, startsOn: String?, endsOn: String?, venue: String?, summary: String?) {
        self.id = id
        self.title = title
        // A save found without a date still answers as today's event.
        let start = startsOn.flatMap(DayString.date) ?? DayString.calendar.startOfDay(for: .now)
        startDate = start
        endDate = endsOn.flatMap(DayString.date) ?? start
        isAllDay = true
        location = venue.map { .text($0) }
        note = summary
        calendar = .canWeGo
        attendees = []
        organizers = []
        alarms = []
        status = .confirmed
    }
}

@available(iOS 27.0, *)
struct SaveEventQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SaveEventEntity] {
        let wanted = Set(identifiers)
        return SaveLibrary.all().filter { wanted.contains($0.id) }.map(SaveEventEntity.init)
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .calendar.createEvent)
struct AddEventByVoiceIntent: LongRunningIntent {
    var title: String
    var startDate: Date
    var endDate: Date?
    var isAllDay: Bool
    var location: SaveEventLocation?
    var note: String?
    var calendar: SaveCalendarEntity
    var attendees: [SaveAttendeeEntity]
    var recurrence: Calendar.RecurrenceRule?

    @MainActor
    func perform() async throws -> some ReturnsValue<SaveEventEntity> & ProvidesDialog & ShowsSnippetView {
        let place: String? = switch location {
        case .text(let text): text
        case .place(let descriptor): descriptor.commonName
        case nil: nil
        }
        let outcome = try await AddToLibraryIntent.add(Self.description(title: title, location: place), asking: self)
        let entity = switch outcome {
        case .alreadySaved(let twin): SaveEventEntity(twin)
        case .added(let card, let id, _): SaveEventEntity(id: id, card: card)
        }
        return .result(value: entity, dialog: outcome.dialog, view: await outcome.card(voiceOnly: Siri.voiceOnly(self)))
    }

    /// "Amar Kanwar, Serpentine North": the venue Siri heard goes with the
    /// title, unless the title already names it. Siri's own dates are left
    /// out — the parser finds the run from the event's page.
    static func description(title: String, location: String?) -> String {
        let asked = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let place = location?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty,
              !asked.localizedCaseInsensitiveContains(place)
        else { return asked }
        return "\(asked), \(place)"
    }
}
