import Foundation

/// A tapped reminder (or Spotlight result) names one item to open. Parked
/// here when the tap lands before the UI exists (cold start). Lives in
/// Support/ so views shared with the extension can reference it.
enum ItemGate {
    static var pending: UUID?
}

/// A picture sent from Visual Intelligence, or a tapped suggestion, to be
/// looked up and saved, or a card someone sent, parked until the composer
/// opens and takes it.
/// `pendingOpen` is the Control Center button: the composer, empty.
enum CaptureGate {
    static var pendingImage: Data?
    static var pendingPick: ParseClient.Suggestion?
    static var pendingOpen = false
    /// A save someone sent: its card, ready to save as it is.
    static var pendingCard: ParseClient.Card?

    static func takeCard() -> ParseClient.Card? {
        defer { pendingCard = nil }
        return pendingCard
    }

    static func take() -> Data? {
        defer { pendingImage = nil }
        return pendingImage
    }

    static func takePick() -> ParseClient.Suggestion? {
        defer { pendingPick = nil }
        return pendingPick
    }
}

/// A search asked for from outside ("More results" in Visual Intelligence):
/// which tab, and what to type.
enum SearchGate {
    static var pending: (kind: String, text: String)?
}

/// The app's own links: `canwego://<section>/…` or
/// `https://wegocan.com/<section>/…`.
enum OwnLink {
    static let domain = "wegocan.com"

    /// The part after `/<section>/`, or nil if the URL is something else.
    static func value(in url: URL, section: String) -> String? {
        let isOurs = url.scheme == "canwego" && url.host() == section
        let host = url.host()?.lowercased()
        let isWeb = ["https", "http"].contains(url.scheme ?? "")
            && (host == domain || host == "www.\(domain)")
            && url.pathComponents.dropFirst().first == section
        guard isOurs || isWeb else { return nil }
        let value = url.lastPathComponent
        return value == section || value == "/" ? nil : value
    }
}

/// An invite link (`canwego://join/KV7P2M` or `https://wegocan.com/join/…`)
/// names a code to join with. Parked here until whichever screen can act
/// on it is up: the first-run's code page for a new install, the Join sheet
/// for someone already in.
enum JoinGate {
    static var pendingCode: String?

    /// The code in an invite URL, or nil if the URL is something else.
    static func code(from url: URL) -> String? {
        guard OwnLink.value(in: url, section: "join") != nil else { return nil }
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
    /// `CaptureGate` holds a picture or a link for the composer, or asks
    /// for it to open.
    static let cwgCaptureImage = Notification.Name("cwgCaptureImage")
    /// `SearchGate` holds a search for one of the tabs.
    static let cwgSearchSaves = Notification.Name("cwgSearchSaves")
}
