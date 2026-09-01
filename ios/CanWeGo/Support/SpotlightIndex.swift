import CoreSpotlight
import Foundation

/// Mirrors the active library into iOS system search: swipe down on the home
/// screen, type "Kapoor", land on the save. Rebuilt in full on every
/// foreground — the library is small, and a rebuild self-heals renames,
/// deletions and done-markings without any bookkeeping.
enum SpotlightIndex {
    private static let domain = "saves"

    static func sync(items: [Item]) {
        let entries = items
            .filter { !$0.isDone }
            .map { item -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .content)
                attributes.title = item.title
                attributes.contentDescription = [
                    item.venue, item.area, item.timeLabel,
                ]
                .compactMap(\.self)
                .joined(separator: " · ")
                attributes.keywords = [item.category, item.area, item.venue].compactMap(\.self)
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
    }
}
