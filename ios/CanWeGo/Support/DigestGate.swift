import Foundation

/// Hand-off between the push-notification delegate and the UI: a digest
/// push tapped before the UI exists parks a flag here; once the scene is
/// active, ContentView drains it and presents the digest sheet. Lives in
/// Support/ so views shared with the extension can reference it.
enum DigestGate {
    static var pending = false
}

/// A tapped last-chance notification (or Spotlight result) names one item to
/// open. Parked here when the tap lands before the UI exists (cold start).
enum ItemGate {
    static var pending: UUID?
}

extension Notification.Name {
    /// A weekly digest push was tapped — present the digest sheet.
    static let cwgOpenDigest = Notification.Name("cwgOpenDigest")
    /// A specific item should open — object carries its UUID.
    static let cwgOpenItem = Notification.Name("cwgOpenItem")
    /// The active tab was tapped again — scroll its list back to the top.
    static let cwgScrollToTop = Notification.Name("cwgScrollToTop")
}
