import CoreSpotlight
import Foundation

/// Mirrors the library into iOS system search: swipe down on the home
/// screen, type "Kapoor", land on the save. Past saves are in too, so Siri
/// can answer "where was that place we went?". Rebuilt in full once per
/// launch, which self-heals anything missed; after that each foreground
/// reindexes only the saves whose words changed and drops the ones gone.
enum SpotlightIndex {
    private static let domain = "saves"

    /// What this launch last indexed for each save, by id.
    @MainActor private static var indexed: [String: Int]?
    /// The ids indexed, across launches, so the next launch knows what to drop.
    private static let idsKey = "spotlightIndexedIDs"

    @MainActor
    static func sync(items: [Item]) {
        var fresh: [String: Int] = [:]
        var changed: [CSSearchableItem] = []
        let previous = indexed
        for item in items where !item.isTrashed {
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
            let id = item.id.uuidString
            var hasher = Hasher()
            hasher.combine(attributes.title)
            hasher.combine(attributes.contentDescription)
            hasher.combine(attributes.keywords)
            hasher.combine(attributes.textContent)
            hasher.combine(attributes.startDate)
            hasher.combine(attributes.endDate)
            let fingerprint = hasher.finalize()
            fresh[id] = fingerprint
            guard previous?[id] != fingerprint else { continue }
            #if !APP_EXTENSION
            // Same result, now also the save Siri and Apple
            // Intelligence can reason about.
            attributes.associateAppEntity(SaveEntity(item))
            #endif
            changed.append(CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domain, attributeSet: attributes))
        }
        // A launch's first pass replaces in place rather than clearing the
        // domain first, so a search meanwhile still finds everything: what
        // the last launch indexed and is no longer here goes after.
        let recorded = UserDefaults.standard.stringArray(forKey: idsKey)
        let before = previous.map { Set($0.keys) } ?? Set(recorded ?? [])
        let gone = Array(before.subtracting(fresh.keys))
        // A build that kept no record cleared the domain every time:
        // once more, so nothing it indexed is left behind.
        let clearFirst = previous == nil && recorded == nil
        indexed = fresh
        UserDefaults.standard.set(Array(fresh.keys), forKey: idsKey)
        guard previous == nil || !changed.isEmpty || !gone.isEmpty else { return }
        let index = CSSearchableIndex.default()
        Task {
            if clearFirst { try? await index.deleteSearchableItems(withDomainIdentifiers: [domain]) }
            if !changed.isEmpty { try? await index.indexSearchableItems(changed) }
            if !gone.isEmpty { try? await index.deleteSearchableItems(withIdentifiers: gone) }
        }
        #if !APP_EXTENSION
        // "Open <save> in Can We Go" matches against the current titles.
        CanWeGoShortcuts.updateAppShortcutParameters()
        if #available(iOS 27.0, *), previous == nil {
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
