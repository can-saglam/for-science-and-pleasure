import Foundation

/// A tapped reminder (or Spotlight result) names one item to open. Parked
/// here when the tap lands before the UI exists (cold start). Lives in
/// Support/ so views shared with the extension can reference it.
enum ItemGate {
    static var pending: UUID?
}

/// An invite link (`canwego://join/KV7P2M`, or `https://canwego.app/join/…`
/// once the domain exists) names a code to join with. Parked here until
/// whichever screen can act on it is up: the first-run's code page for a
/// new install, the Join sheet for someone already in.
enum JoinGate {
    static var pendingCode: String?

    /// The code in an invite URL, or nil if the URL is something else.
    static func code(from url: URL) -> String? {
        let isOurs = url.scheme == "canwego" && url.host() == "join"
        let isWeb = ["https", "http"].contains(url.scheme ?? "")
            && url.host()?.hasSuffix("canwego.app") == true
            && url.pathComponents.dropFirst().first == "join"
        guard isOurs || isWeb else { return nil }
        let raw = url.lastPathComponent
        let code = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        return code.count == 6 ? code : nil
    }
}

extension Notification.Name {
    /// A specific item should open — object carries its UUID.
    static let cwgOpenItem = Notification.Name("cwgOpenItem")
    /// An invite link arrived — object carries the code; `JoinGate` holds
    /// it too for anything not yet on screen.
    static let cwgJoinCode = Notification.Name("cwgJoinCode")
    /// The active tab was tapped again — scroll its list back to the top.
    static let cwgScrollToTop = Notification.Name("cwgScrollToTop")
    /// The local library is about to be wiped and replaced (membership
    /// change) — any sheet showing an item should close first.
    static let cwgLibraryWillSwap = Notification.Name("cwgLibraryWillSwap")
    /// Siri or Shortcuts parked a save in the shared inbox.
    static let cwgInboxChanged = Notification.Name("cwgInboxChanged")
}
