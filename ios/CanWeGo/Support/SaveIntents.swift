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
            card = try await SaveInbox.lookUp(link.absoluteString)
        } catch SaveIntentError.tooSlow {
            // The link is all it needs; the app reads it when next opened.
            OfflineDrafts.enqueue(id: UUID(), text: link.absoluteString, imageJPEG: nil, inLibrary: false)
            return .result(dialog: "That page is slow to read. It\u{2019}ll be in your saves next time you open Can We Go.")
        }
        try SaveInbox.park(card, url: card.url ?? link.absoluteString, userId: userId)
        return .result(dialog: "Saved \u{201c}\(card.title)\u{201d}.")
    }
}

/// "Add the new Anish Kapoor show at the Hayward to Can We Go." Looks the
/// description up the way the composer does typed text, reads back what it
/// found, and on a yes parks it in the inbox like a shared link.
struct AddToLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Can We Go"
    static let description = IntentDescription("Looks up an event or place from a description, like \u{201c}the new Anish Kapoor show at the Hayward\u{201d}, and adds it to your saves.")

    @Parameter(title: "What", requestValueDialog: "What should I add?")
    var what: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$what) to Can We Go")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = try await Self.add(what) { question in
            try await requestConfirmation(actionName: .add, dialog: "\(question)")
        }
        return .result(dialog: "\(outcome.sentence)")
    }

    enum Outcome {
        case alreadySaved(Item)
        case added(ParseClient.Card, id: UUID)

        @MainActor
        var sentence: String {
            switch self {
            case .alreadySaved(let twin):
                "\u{201c}\(twin.title)\u{201d} is already in your saves. \(DuplicateFinder.describe(twin))"
            case .added(let card, _):
                "Added \u{201c}\(card.title)\u{201d}."
            }
        }
    }

    /// Looks it up, answers an exact duplicate with who saved it, asks
    /// (naming any near-match), and on a yes parks it in the inbox.
    @MainActor
    static func add(_ what: String, confirm: (String) async throws -> Void) async throws -> Outcome {
        guard SupabaseAuth.shared.signedIn, let userId = SupabaseAuth.shared.userId else {
            throw SaveIntentError.signedOut
        }
        let asked = what.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { throw SaveIntentError.nothingAsked }
        let card = try await SaveInbox.lookUp(asked)
        let library = SaveLibrary.all()
        if let twin = DuplicateFinder.match(
            url: card.url, title: card.title, startsOn: card.starts_on, kind: card.kind, in: library
        ) {
            return .alreadySaved(twin)
        }
        if let similar = lookalike(of: card, in: library) {
            try await confirm("I found \(spoken(card)). You already have \u{201c}\(similar.title)\u{201d} saved. Add this one too?")
        } else {
            try await confirm("I found \(spoken(card)). Add it?")
        }
        let id = UUID()
        try SaveInbox.park(card, url: card.url, userId: userId, id: id)
        return .added(card, id: id)
    }

    /// A save that's probably the same thing under another title ("Jaga
    /// Jazzist" for "Jaga Jazzist at the Barbican"). Named in the question
    /// rather than blocking it: it may be a new date or a new show.
    static func lookalike(of card: ParseClient.Card, in items: [Item]) -> Item? {
        let found = " \(DuplicateFinder.normalizeTitle(card.title)) "
        return items.first { item in
            let saved = DuplicateFinder.normalizeTitle(item.title)
            guard item.kind == card.kind, saved.count >= 4 else { return false }
            return found.contains(" \(saved) ") || " \(saved) ".contains(found)
        }
    }

    /// "Anish Kapoor at Hayward Gallery, on until 18 October", so a wrong
    /// guess (last year's show, the other branch) is caught before it's saved.
    static func spoken(_ card: ParseClient.Card) -> String {
        var line = card.title
        let title = DuplicateFinder.normalizeTitle(card.title)
        if let venue = card.venue, !venue.isEmpty, DuplicateFinder.normalizeTitle(venue) != title {
            line += " at \(venue)"
        } else if let area = card.area, !area.isEmpty {
            line += " in \(area)"
        }
        let today = DayString.today()
        func day(_ s: String?) -> String? {
            guard let s else { return nil }
            let long = Date.FormatStyle.dateTime.day().month(.wide)
            return DayString.text(s, s.prefix(4) == today.prefix(4) ? long : long.year())
        }
        let startsOn = card.starts_on, endsOn = card.ends_on ?? card.starts_on
        if let endsOn, endsOn < today, let end = day(endsOn) {
            line += startsOn == endsOn ? ", which was on \(end)" : ", which ended on \(end)"
        } else if let startsOn, let endsOn, startsOn != endsOn, let start = day(startsOn), let end = day(endsOn) {
            line += startsOn <= today ? ", on until \(end)" : ", \(start) to \(end)"
        } else if let start = day(startsOn) {
            line += ", on \(start)"
        }
        return line
    }
}

/// The share sheet's route for anything Siri or Shortcuts looks up: the
/// parser, then the App Group inbox, claimed with the usual duplicate and
/// category checks next time the app is on screen, or straight away if it is.
@MainActor
enum SaveInbox {
    /// Siri won't wait for the parser's own timeouts (two minutes, and a
    /// retry). Past the deadline the look-up is cancelled, so nothing lands
    /// after Siri has already given up.
    static func lookUp(_ text: String, within seconds: Double = 45) async throws -> ParseClient.Card {
        do {
            return try await withThrowingTaskGroup(of: ParseClient.Card?.self) { group in
                group.addTask { try await ParseClient.parse(text: text, imageJPEG: nil) }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    return nil
                }
                defer { group.cancelAll() }
                guard let card = try await group.next() ?? nil else { throw SaveIntentError.tooSlow }
                return card
            }
        } catch let error as SaveIntentError {
            throw error
        } catch {
            throw SaveIntentError.lookup((error as? ParseClient.ParseError)?.errorDescription ?? SyncProblem(error).message)
        }
    }

    static func park(_ card: ParseClient.Card, url: String?, userId: UUID, id: UUID? = nil) throws {
        var pending = SharedInbox.PendingSave(card: card, url: url, userId: userId)
        pending.id = id
        try SharedInbox.write(pending)
        NotificationCenter.default.post(name: .cwgInboxChanged, object: nil)
    }
}

enum SaveIntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case notALink
    case nothingAsked
    case lookup(String)
    case tooSlow

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Can We Go first."
        case .notALink: "That isn't a web link."
        case .nothingAsked: "Tell me what to add, like \u{201c}the new Anish Kapoor show at the Hayward\u{201d}."
        case .lookup(let why): "\(why)"
        case .tooSlow: "That\u{2019}s taking too long to look up. Try again in a moment, or add it in the app."
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
        AppShortcut(
            intent: AddToLibraryIntent(),
            phrases: [
                "Add something to \(.applicationName)",
                "Save something to \(.applicationName)",
                "Add an event to \(.applicationName)",
                "Add an exhibition to \(.applicationName)",
                "Add a place to \(.applicationName)",
                "Add to \(.applicationName)",
            ],
            shortTitle: "Add Something",
            systemImageName: "plus.circle"
        )
    }
}
