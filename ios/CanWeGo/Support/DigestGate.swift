import Foundation

/// A tapped reminder (or Spotlight result) names one item to open. Parked
/// here when the tap lands before the UI exists (cold start). Lives in
/// Support/ so views shared with the extension can reference it.
enum ItemGate {
    static var pending: UUID?
}

extension Notification.Name {
    /// A specific item should open — object carries its UUID.
    static let cwgOpenItem = Notification.Name("cwgOpenItem")
    /// The active tab was tapped again — scroll its list back to the top.
    static let cwgScrollToTop = Notification.Name("cwgScrollToTop")
    /// The local library is about to be wiped and replaced (membership
    /// change) — any sheet showing an item should close first.
    static let cwgLibraryWillSwap = Notification.Name("cwgLibraryWillSwap")
}
