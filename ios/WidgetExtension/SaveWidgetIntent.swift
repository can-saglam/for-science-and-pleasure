import AppIntents
import WidgetKit

/// Which saves the home-screen widget rotates through.
enum WidgetShow: String, AppEnum {
    case everything, events, places, planned

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Show"
    static let caseDisplayRepresentations: [WidgetShow: DisplayRepresentation] = [
        .everything: "Everything",
        .events: "Events",
        .places: "Places",
        .planned: "Planned",
    ]
}

/// The parser's categories (`Item.eventCategories`, `Item.placeCategories`)
/// less "other", which names nothing worth picking.
enum WidgetCategory: String, AppEnum {
    case any
    case exhibition, gig, theatre, film, market, festival, talk, workshop, outdoors
    case restaurant, cafe, drink, gallery, museum, park, shop, venue

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    static let caseDisplayRepresentations: [WidgetCategory: DisplayRepresentation] = [
        .any: "Any",
        .exhibition: "Exhibitions",
        .gig: "Gigs",
        .theatre: "Theatre",
        .film: "Films",
        .market: "Markets",
        .festival: "Festivals",
        .talk: "Talks",
        .workshop: "Workshops",
        .outdoors: "Outdoors",
        .restaurant: "Restaurants",
        .cafe: "Cafés",
        .drink: "Drinks",
        .gallery: "Galleries",
        .museum: "Museums",
        .park: "Parks",
        .shop: "Shops",
        .venue: "Venues",
    ]

    var label: String {
        String(localized: Self.caseDisplayRepresentations[self]?.title ?? "")
    }
}

/// The widget's Edit Widget sheet. A widget placed before these settings
/// existed gets the defaults, which are what it always showed.
struct SaveWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose saves"
    static let description = IntentDescription("Pick which saves the widget rotates through.")

    @Parameter(title: "Show", default: .everything)
    var show: WidgetShow

    @Parameter(title: "Category", default: .any)
    var category: WidgetCategory

    func includes(_ item: SnapshotItem) -> Bool {
        let shown = switch show {
        case .everything: true
        case .events: item.kind != "place"
        case .places: item.kind == "place"
        case .planned: item.planned == true
        }
        return shown && (category == .any || item.category == category.rawValue)
    }

    /// What the empty widget says when these settings leave nothing.
    var emptyMessage: String {
        if category != .any { return "Save something in \(category.label) to see it here" }
        return switch show {
        case .everything: "Save something to see it here"
        case .events: "Save an event to see it here"
        case .places: "Save a place to see it here"
        case .planned: "Plan a save to see it here"
        }
    }
}
