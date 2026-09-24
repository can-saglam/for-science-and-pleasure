import AppIntents
import Foundation

/// Opens a save in the app: the same route a reminder tap takes, so a cold
/// start and a running app both land on it.
struct OpenSaveIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Save"
    static let description = IntentDescription("Opens one of your saves in Can We Go.")

    @Parameter(title: "Save")
    var target: SaveEntity

    init() {}

    init(target: SaveEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ItemGate.pending = target.id
        NotificationCenter.default.post(name: .cwgOpenItem, object: target.id)
        return .result()
    }
}

/// "What's on this weekend?" Answers from the library, out loud, and hands
/// the saves on to whatever comes next in a shortcut.
struct WhatsOnIntent: AppIntent {
    static let title: LocalizedStringResource = "What's On"
    static let description = IntentDescription("Lists the saved events that are on today, this weekend, this week, or closing soon.")

    @Parameter(title: "When", default: .weekend)
    var period: SavePeriod

    static var parameterSummary: some ParameterSummary {
        Summary("What's on \(\.$period)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some ReturnsValue<[SaveEntity]> & ProvidesDialog {
        let items = SaveLibrary.whatsOn(period)
        return .result(value: items.map(SaveEntity.init), dialog: "\(Self.sentence(items.map(\.title), period: period))")
    }

    /// "This weekend: A, B and C." Five names at most, then a count.
    static func sentence(_ titles: [String], period: SavePeriod) -> String {
        guard !titles.isEmpty else {
            return switch period {
            case .today: "Nothing saved is on today."
            case .weekend: "Nothing saved is on this weekend."
            case .week: "Nothing saved is on this week."
            case .closing: "Nothing saved is closing soon."
            }
        }
        let lead = switch period {
        case .today: "On today"
        case .weekend: "This weekend"
        case .week: "This week"
        case .closing: "Closing soon"
        }
        let shown = titles.count > 5 ? Array(titles.prefix(4)) : titles
        let rest = titles.count - shown.count
        var names = shown
        if rest > 0 { names.append("\(rest) more") }
        let list = names.count == 1
            ? names[0]
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "\(lead): \(list)."
    }
}

/// "What's closing soon?" on its own, so the phrase needs no follow-up.
struct ClosingSoonIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Closing Soon"
    static let description = IntentDescription("Lists the saved exhibitions and runs that close in the next three weeks.")

    init() {}

    @MainActor
    func perform() async throws -> some ReturnsValue<[SaveEntity]> & ProvidesDialog {
        let items = SaveLibrary.whatsOn(.closing)
        return .result(value: items.map(SaveEntity.init), dialog: "\(WhatsOnIntent.sentence(items.map(\.title), period: .closing))")
    }
}

/// Saves a link the way the share sheet does: looked up, then parked in the
/// App Group inbox for the app to claim (duplicate and category checks
/// included) the next time it's on screen, or straight away if it is.
struct SaveLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Save a Link"
    static let description = IntentDescription("Looks up a link and adds it to your saves, like sharing it to Can We Go.")

    @Parameter(title: "Link")
    var link: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$link) to Can We Go")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SupabaseAuth.shared.signedIn, let userId = SupabaseAuth.shared.userId else {
            throw SaveIntentError.signedOut
        }
        guard let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw SaveIntentError.notALink
        }
        if SavedURLIndex.contains(link.absoluteString) {
            return .result(dialog: "That one's already in your saves.")
        }
        let card: ParseClient.Card
        do {
            card = try await ParseClient.parse(text: link.absoluteString, imageJPEG: nil)
        } catch {
            throw SaveIntentError.lookup((error as? ParseClient.ParseError)?.errorDescription ?? SyncProblem(error).message)
        }
        var pending = SharedInbox.PendingSave(kind: card.kind, title: card.title)
        pending.summary = card.summary
        pending.venue = card.venue
        pending.area = card.area
        pending.address = card.address
        pending.category = card.category
        pending.price = card.price
        pending.startsOn = card.starts_on
        pending.endsOn = card.ends_on
        pending.url = card.url ?? link.absoluteString
        pending.lat = card.lat
        pending.lng = card.lng
        pending.colorHex = card.color
        pending.imageUrl = card.image_url
        pending.source = card.source
        pending.userId = userId.uuidString
        pending.groupId = GroupStore.shared.card?.groupId.uuidString
        try SharedInbox.write(pending)
        NotificationCenter.default.post(name: .cwgInboxChanged, object: nil)
        return .result(dialog: "Saved \u{201c}\(card.title)\u{201d}.")
    }
}

enum SaveIntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case notALink
    case lookup(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Can We Go first."
        case .notALink: "That isn't a web link."
        case .lookup(let why): "\(why)"
        }
    }
}

struct CanWeGoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsOnIntent(),
            phrases: [
                "What's on \(\.$period) in \(.applicationName)",
                "What's on \(\.$period) from \(.applicationName)",
                "What's on \(\.$period) for \(.applicationName)",
                "What's on \(\.$period) on \(.applicationName)",
                "Ask \(.applicationName) what's on \(\.$period)",
                "What have we saved for \(\.$period) in \(.applicationName)",
                "What's on in \(.applicationName)",
            ],
            shortTitle: "What's On",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: ClosingSoonIntent(),
            phrases: [
                "What's closing soon in \(.applicationName)",
                "What's closing soon from \(.applicationName)",
                "What's closing soon on \(.applicationName)",
                "What's ending soon in \(.applicationName)",
                "Ask \(.applicationName) what's closing soon",
            ],
            shortTitle: "Closing Soon",
            systemImageName: "hourglass"
        )
        AppShortcut(
            intent: OpenSaveIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Show \(\.$target) in \(.applicationName)",
            ],
            shortTitle: "Open a Save",
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: SaveLinkIntent(),
            phrases: [
                "Save a link to \(.applicationName)",
                "Add a link to \(.applicationName)",
            ],
            shortTitle: "Save a Link",
            systemImageName: "link"
        )
    }
}
