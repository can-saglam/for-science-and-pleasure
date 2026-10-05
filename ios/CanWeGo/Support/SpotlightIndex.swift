import CoreSpotlight
import Foundation

/// Mirrors the library into iOS system search: swipe down on the home
/// screen, type "Kapoor", land on the save. Past saves are in too, so Siri
/// can answer "where was that place we went?". Rebuilt in full on every
/// foreground — the library is small, and a rebuild self-heals renames,
/// deletions and done-markings without any bookkeeping.
enum SpotlightIndex {
    private static let domain = "saves"

    @MainActor
    static func sync(items: [Item]) {
        let entries = items
            .filter { !$0.isDeleted }
            .map { item -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .content)
                attributes.title = item.title
                attributes.contentDescription = [
                    item.venue, item.area, item.isDone ? "Been" : item.timeLabel,
                ]
                .compactMap(\.self)
                .joined(separator: " · ")
                attributes.keywords = [item.category, item.area, item.venue].compactMap(\.self)
                attributes.textContent = about(item)
                attributes.startDate = item.startsOn.flatMap(DayString.date)
                attributes.endDate = (item.endsOn ?? item.startsOn).flatMap(DayString.date)
                #if !APP_EXTENSION
                // Same result, now also the save Siri and Apple
                // Intelligence can reason about.
                attributes.associateAppEntity(SaveEntity(item))
                #endif
                return CSSearchableItem(
                    uniqueIdentifier: item.id.uuidString,
                    domainIdentifier: domain,
                    attributeSet: attributes
                )
            }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(entries, completionHandler: nil)
        }
        #if !APP_EXTENSION
        // "Open <save> in Can We Go" matches against the current titles.
        CanWeGoShortcuts.updateAppShortcutParameters()
        if #available(iOS 27.0, *) {
            Task.detached(priority: .utility) {
                let index = CSSearchableIndex.default()
                try? await index.indexAppEntities([SaveCalendarEntity.canWeGo])
                try? await index.indexAppEntities([SaveListEntity.canWeGo, .events, .places])
            }
        }
        #endif
    }

    /// The save in plain sentences, for questions put to the library
    /// ("something free near Peckham on Saturday") as much as for search.
    @MainActor
    private static func about(_ item: Item) -> String {
        var lines = [item.isPlace ? "A place." : "An event."]
        if let category = item.category { lines.append("\(Item.categoryLabel(category)).") }
        let at = [item.venue, item.area].compactMap(\.self).filter { $0 != item.title }
        if !at.isEmpty { lines.append("At \(at.joined(separator: ", ")).") }
        if let address = item.address { lines.append("Address: \(address).") }
        let long = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year()
        if let start = item.startsOn, let end = item.endsOn, start != end,
           let from = DayString.text(start, long), let to = DayString.text(end, long) {
            lines.append("On from \(from) until \(to).")
        } else if let day = (item.startsOn ?? item.endsOn).flatMap({ DayString.text($0, long) }) {
            lines.append("On \(day).")
        }
        if let plan = item.upcomingPlan, let day = DayString.text(plan, long) {
            lines.append("Planned for \(day)\(item.planTime.map { " at \($0)" } ?? "").")
        }
        if item.isDone { lines.append("Been already.") } else if item.isMissed { lines.append("Missed.") }
        if let price = item.price { lines.append("Price: \(price).") }
        if let saver = MembersStore.shared.saverName(for: item) { lines.append("Saved by \(saver).") }
        if let summary = item.summary { lines.append(summary) }
        return lines.joined(separator: " ")
    }
}
