import AppIntents
import Foundation
import GeoToolbox

// iOS 27's Siri knows list apps through the Reminders schema, and fills a
// new item's title from whatever was said. Events and Places are the
// lists, a save is an item on one. Only adding is adopted: "Add the latest
// Anish Kapoor exhibition at Hayward Gallery to Can We Go" is looked up,
// read back and parked like the two-step Add Something. The schema's other
// fields are accepted and ignored.

@available(iOS 27.0, *)
@AppEnum(schema: .reminders.listType)
enum SaveListType: String {
    case standard

    static let caseDisplayRepresentations: [SaveListType: DisplayRepresentation] = [
        .standard: "List",
    ]
}

@available(iOS 27.0, *)
@AppEntity(schema: .reminders.list)
struct SaveListEntity {
    static let defaultQuery = SaveListQuery()

    let id: String
    var name: String
    var type: SaveListType

    static let events = SaveListEntity(id: "event", name: "Events")
    static let places = SaveListEntity(id: "place", name: "Places")

    init(id: String, name: String) {
        self.id = id
        self.name = name
        self.type = .standard
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: id == "place" ? "building.columns" : "calendar"))
    }
}

@available(iOS 27.0, *)
struct SaveListQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SaveListEntity] {
        suggested().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SaveListEntity] {
        let asked = string.lowercased()
        return suggested().filter { asked.contains($0.name.lowercased().dropLast()) }
    }

    func suggestedEntities() async throws -> [SaveListEntity] {
        suggested()
    }

    private func suggested() -> [SaveListEntity] {
        [.events, .places]
    }
}

/// The lists have no sections; the schema asks for the type all the same.
@available(iOS 27.0, *)
@AppEntity(schema: .reminders.section)
struct SaveSectionEntity {
    static let defaultQuery = SaveSectionQuery()

    let id: String
    var name: String
    var list: SaveListEntity

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(iOS 27.0, *)
struct SaveSectionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SaveSectionEntity] { [] }
    func entities(matching string: String) async throws -> [SaveSectionEntity] { [] }
}

@available(iOS 27.0, *)
@AppEnum(schema: .reminders.locationTriggerEvent)
enum SaveLocationTriggerEvent: String {
    case arrive
    case depart

    static let caseDisplayRepresentations: [SaveLocationTriggerEvent: DisplayRepresentation] = [
        .arrive: "Arriving",
        .depart: "Leaving",
    ]
}

/// Never set: saves don't remind by place.
@available(iOS 27.0, *)
@AppEntity(schema: .reminders.locationTrigger)
struct SaveLocationTriggerEntity {
    static let defaultQuery = SaveLocationTriggerQuery()

    let id: String
    var event: SaveLocationTriggerEvent
    var place: PlaceDescriptor

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

@available(iOS 27.0, *)
struct SaveLocationTriggerQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SaveLocationTriggerEntity] { [] }
    func entities(matching string: String) async throws -> [SaveLocationTriggerEntity] { [] }
}

/// A save as a list item: its dates, "been" as completed, the summary as
/// the note, the category as a tag.
@available(iOS 27.0, *)
@AppEntity(schema: .reminders.reminder)
struct SaveItemEntity {
    static let defaultQuery = SaveItemQuery()

    let id: UUID
    var title: String
    var dueDate: DateComponents?
    var isCompleted: Bool
    var completionDate: Date?
    var creationDate: Date?
    var isFlagged: Bool?
    var list: SaveListEntity
    var locationTrigger: SaveLocationTriggerEntity?
    var note: String?
    var recurrence: Calendar.RecurrenceRule?
    var tags: Set<String>
    var urls: [URL]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: note.map { "\($0)" })
    }

    @MainActor
    init(_ item: Item) {
        self.init(
            id: item.id, title: item.title, kind: item.kind, day: item.endsOn ?? item.startsOn,
            summary: item.summary, category: item.category, url: item.url
        )
        isCompleted = item.isDone
        creationDate = item.createdAt
    }

    /// What Siri gets back for a save still on its way from the inbox.
    init(id: UUID, card: ParseClient.Card) {
        self.init(
            id: id, title: card.title, kind: card.kind, day: card.ends_on ?? card.starts_on,
            summary: card.summary, category: card.category, url: card.url
        )
    }

    private init(id: UUID, title: String, kind: String, day: String?, summary: String?, category: String?, url: String?) {
        self.id = id
        self.title = title
        dueDate = day.flatMap(DayString.date).map { DayString.calendar.dateComponents([.year, .month, .day], from: $0) }
        isCompleted = false
        creationDate = .now
        list = kind == "place" ? .places : .events
        note = summary
        tags = category.map { [Item.categoryLabel($0)] } ?? []
        urls = url.flatMap(URL.init(string:)).map { [$0] } ?? []
    }
}

@available(iOS 27.0, *)
struct SaveItemQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SaveItemEntity] {
        let wanted = Set(identifiers)
        return SaveLibrary.all().filter { wanted.contains($0.id) }.map(SaveItemEntity.init)
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .reminders.createReminder)
struct AddSaveByVoiceIntent {
    var title: String
    var dueDate: DateComponents?
    var images: [IntentFile]
    var isFlagged: Bool?
    var list: SaveListEntity?
    var locationTrigger: SaveLocationTriggerEntity?
    var note: String?
    var recurrence: Calendar.RecurrenceRule?
    var section: SaveSectionEntity?
    var tags: Set<String>
    var urls: [URL]

    @MainActor
    func perform() async throws -> some ReturnsValue<SaveItemEntity> & ProvidesDialog {
        let outcome = try await AddToLibraryIntent.add(title) { question in
            try await requestConfirmation(actionName: .add, dialog: "\(question)")
        }
        let entity = switch outcome {
        case .alreadySaved(let twin): SaveItemEntity(twin)
        case .added(let card, let id): SaveItemEntity(id: id, card: card)
        }
        return .result(value: entity, dialog: "\(outcome.sentence)")
    }
}
