import AppIntents
import CoreSpotlight
import SwiftData

/// A save as Siri, Shortcuts and Spotlight see it. The id is the row's
/// server UUID, so it names the same save on every member's phone.
struct SaveEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Save",
        numericFormat: "\(placeholder: .int) saves"
    )
    static let defaultQuery = SaveQuery()

    let id: UUID
    let glyph: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Type")
    var type: String

    @Property(title: "Category")
    var category: String?

    @Property(title: "Venue")
    var venue: String?

    @Property(title: "Area")
    var area: String?

    @Property(title: "When")
    var when: String?

    @Property(title: "Starts")
    var starts: Date?

    @Property(title: "Ends")
    var ends: Date?

    @Property(title: "Saved by")
    var savedBy: String?

    @Property(title: "Link")
    var link: URL?

    @MainActor
    init(_ item: Item) {
        id = item.id
        glyph = item.glyph
        title = item.title
        type = item.isPlace ? "Place" : "Event"
        category = item.category.map(Item.categoryLabel)
        venue = item.venue
        area = item.area
        when = item.timeLabel
        starts = item.startsOn.flatMap(DayString.date)
        ends = item.endsOn.flatMap(DayString.date)
        savedBy = MembersStore.shared.saverName(for: item)
        link = item.url.flatMap(URL.init(string:))
    }

    var displayRepresentation: DisplayRepresentation {
        let detail = [venue ?? area, when].compactMap(\.self).joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: detail.isEmpty ? nil : "\(detail)",
            image: .init(systemName: glyph)
        )
    }
}

struct SaveQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SaveEntity] {
        let wanted = Set(identifiers)
        return SaveLibrary.all().filter { wanted.contains($0.id) }.map(SaveEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [SaveEntity] {
        SaveLibrary.search(string).map(SaveEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SaveEntity] {
        SaveLibrary.upcoming().map(SaveEntity.init)
    }
}

/// When "What's on" looks. The same home-clock days as the Events page.
enum SavePeriod: String, AppEnum {
    case today
    case weekend
    case week
    case closing

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "When"
    static let caseDisplayRepresentations: [SavePeriod: DisplayRepresentation] = [
        .today: "today",
        .weekend: "this weekend",
        .week: "this week",
        .closing: "closing soon",
    ]
}

/// The library as intents read it: the signed-in account's saves, never
/// deleted ones, in the app's own order.
@MainActor
enum SaveLibrary {
    static func all() -> [Item] {
        guard SupabaseAuth.shared.signedIn, !GroupStore.shared.libraryIsForeign else { return [] }
        let items = (try? LibraryStore.container.mainContext.fetch(FetchDescriptor<Item>())) ?? []
        return items.filter { !$0.isDeleted }
    }

    /// Still to do: not been, not missed.
    static func active() -> [Item] {
        all().filter { !$0.isDone && !$0.isMissed }
    }

    /// What Shortcuts offers when picking a save: this week's events and
    /// what's closing, then everything else, then places.
    static func upcoming() -> [Item] {
        let active = active()
        let events = LibraryView.eventSections(
            LibraryView.ordered(active.filter(\.isEvent), kind: Item.Kind.event)
        ).flatMap(\.1)
        let places = LibraryView.ordered(active.filter(\.isPlace), kind: Item.Kind.place)
        return Array((events + places).prefix(40))
    }

    /// Every word has to appear somewhere on the save: title, venue, area,
    /// category or who saved it. Titles that start with the words lead.
    static func search(_ text: String) -> [Item] {
        let words = fold(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return upcoming() }
        let phrase = words.joined(separator: " ")
        let hits = all().filter { item in
            let haystack = fold([
                item.title, item.venue, item.area, item.address,
                item.category.map(Item.categoryLabel), item.category,
                MembersStore.shared.saverName(for: item),
            ].compactMap(\.self).joined(separator: " "))
            return words.allSatisfy(haystack.contains)
        }
        return hits
            .sorted { a, b in
                let (x, y) = (fold(a.title).hasPrefix(phrase), fold(b.title).hasPrefix(phrase))
                if x != y { return x }
                if a.isDone != b.isDone { return !a.isDone }
                return a.createdAt > b.createdAt
            }
            .prefix(20)
            .map(\.self)
    }

    static func whatsOn(_ period: SavePeriod) -> [Item] {
        let events = active().filter(\.isEvent)
        let today = DayString.today()
        switch period {
        case .closing:
            // The Events page's Last chance and Closing soon together.
            return events
                .filter {
                    !$0.isOneDay
                        && ($0.timeBucket == .now || $0.timeBucket == .lastChance)
                        && ($0.daysUntilClose ?? 99) <= 21
                }
                .sorted { ($0.endsOn ?? "", $0.title) < ($1.endsOn ?? "", $1.title) }
        case .today:
            return on(events, from: today, to: today)
        case .week:
            return on(events, from: today, to: DayString.endOfThisWeek())
        case .weekend:
            let sunday = DayString.endOfThisWeek()
            let saturday = DayString.addingDays(-1, to: sunday) ?? sunday
            return on(events, from: max(saturday, today), to: sunday)
        }
    }

    /// Anything open at some point between `from` and `to`. Things that
    /// happen or open in the window lead, by day; then what's already
    /// running, closing soonest first.
    private static func on(_ events: [Item], from: String, to: String) -> [Item] {
        let open = events.filter { item in
            guard item.startsOn != nil || item.endsOn != nil else { return false }
            let start = item.startsOn ?? "0000-01-01"
            let end = item.endsOn ?? (item.isOneDay ? start : "9999-12-31")
            return start <= to && end >= from
        }
        let starting = open.filter { ($0.startsOn ?? "") >= from }
            .sorted { ($0.startsOn ?? "", $0.title) < ($1.startsOn ?? "", $1.title) }
        let running = open.filter { ($0.startsOn ?? "") < from }
            .sorted { ($0.endsOn ?? "9999-12-31", $0.title) < ($1.endsOn ?? "9999-12-31", $1.title) }
        return starting + running
    }

    private static func fold(_ s: String) -> String {
        DuplicateFinder.normalizeTitle(s)
    }
}
