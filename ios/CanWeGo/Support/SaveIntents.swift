import AppIntents
import Foundation
import SwiftUI

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
    func perform() async throws -> some ReturnsValue<[SaveEntity]> & ProvidesDialog & ShowsSnippetView {
        await Self.answer(SaveLibrary.whatsOn(period), period: period, voiceOnly: Siri.voiceOnly(self))
    }

    /// The names out loud; on screen, the saves as cards under a short
    /// line, since the card already names them. With no screen at all
    /// (CarPlay, AirPods) it's three names at most, said the way you'd say them.
    @MainActor
    static func answer(_ items: [Item], period: SavePeriod, voiceOnly: Bool) async -> some ReturnsValue<[SaveEntity]> & ProvidesDialog & ShowsSnippetView {
        if voiceOnly {
            let said = sentence(items.map { Siri.said($0.title) }, period: period, names: 3)
            return .result(value: items.map(SaveEntity.init), dialog: "\(said)", view: EmptyView())
        }
        let spoken = sentence(items.map(\.title), period: period)
        guard !items.isEmpty else {
            return .result(value: [], dialog: "\(spoken)", view: EmptyView())
        }
        let shown = switch period {
        case .today: "Here\u{2019}s what\u{2019}s on today."
        case .weekend: "Here\u{2019}s what\u{2019}s on this weekend."
        case .week: "Here\u{2019}s what\u{2019}s on this week."
        case .closing: "Here\u{2019}s what\u{2019}s closing soon."
        }
        let rows = await SiriCards.dressed(Array(items.prefix(SiriSavesCard.shown)))
        return .result(
            value: items.map(SaveEntity.init),
            dialog: IntentDialog(full: "\(spoken)", supporting: "\(shown)"),
            view: SiriSavesCard(rows: rows, total: items.count)
        )
    }

    /// "This weekend: A, B and C." `names` at most, the last of them a
    /// count when there are more.
    static func sentence(_ titles: [String], period: SavePeriod, names limit: Int = 5) -> String {
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
        let shown = titles.count > limit ? Array(titles.prefix(limit - 1)) : titles
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
    func perform() async throws -> some ReturnsValue<[SaveEntity]> & ProvidesDialog & ShowsSnippetView {
        await WhatsOnIntent.answer(SaveLibrary.whatsOn(.closing), period: .closing, voiceOnly: Siri.voiceOnly(self))
    }
}

/// "Ask Can We Go something": a question about the saves, answered on the
/// phone by Apple's model (`LibraryAsk`). The answer is said; the saves
/// it's about come as cards under it.
struct AskLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Your Saves"
    static let description = IntentDescription("Answers a question about your saves, like \u{201c}anything free this weekend?\u{201d}, on this iPhone with Apple Intelligence.")
    @Parameter(title: "Question", requestValueDialog: "What would you like to know?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some ReturnsValue<[SaveEntity]> & ProvidesDialog & ShowsSnippetView {
        guard #available(iOS 27.0, *), LibraryAsk.isAvailable else { throw SaveIntentError.noModel }
        let answer: LibraryAsk.Answer
        do {
            answer = try await LibraryAsk.ask(question)
        } catch {
            throw SaveIntentError.unanswered
        }
        let value = answer.items.map(SaveEntity.init)
        if Siri.voiceOnly(self) || answer.items.isEmpty {
            return .result(value: value, dialog: "\(answer.text)", view: EmptyView())
        }
        let rows = await SiriCards.dressed(Array(answer.items.prefix(SiriSavesCard.shown)))
        return .result(value: value, dialog: "\(answer.text)", view: SiriSavesCard(rows: rows, total: rows.count))
    }
}

/// A slow look-up carries on in the background (`SaveInbox.lookUp(_:for:)`).
@available(iOS 27.0, *)
extension SaveLinkIntent: LongRunningIntent {}

@available(iOS 27.0, *)
extension AddToLibraryIntent: LongRunningIntent {}

/// How Siri is being heard.
enum Siri {
    /// No screen at all: CarPlay, AirPods with the phone away. Knowable
    /// from iOS 27; before that every answer assumes a screen.
    static func voiceOnly(_ intent: some AppIntent) -> Bool {
        if #available(iOS 27.0, *) { return intent.systemContext.isVoiceOnly }
        return false
    }

    /// A title as you'd say it: the artist before a colon ("Nancy Holt"
    /// for "Nancy Holt: MoonSunStarEarthSkyWater"), the whole thing
    /// otherwise.
    static func said(_ title: String) -> String {
        guard let colon = title.range(of: ": ") else { return title }
        let lead = title[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
        return lead.count >= 3 ? lead : title
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
            card = try await SaveInbox.lookUp(link.absoluteString, for: self)
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
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let outcome = try await Self.add(what, asking: self)
        return .result(dialog: outcome.dialog, view: await outcome.card(voiceOnly: Siri.voiceOnly(self)))
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

        @MainActor
        var dialog: IntentDialog {
            switch self {
            case .alreadySaved:
                IntentDialog("\(sentence)")
            case .added(let card, _):
                IntentDialog(full: "\(sentence)", supporting: "Added to \(AddToLibraryIntent.list(card.kind)).")
            }
        }

        /// The save as it now stands; nothing with no screen to show it
        /// on. A new one's photo came in for the question, so it's
        /// already to hand.
        @MainActor
        func card(voiceOnly: Bool = false) async -> SiriSaveCard {
            if voiceOnly { return SiriSaveCard(row: nil) }
            return switch self {
            case .alreadySaved(let twin):
                SiriSaveCard(row: await SiriCards.dressed(SiriCardRow(twin), wait: true))
            case .added(let card, let id):
                SiriSaveCard(row: await SiriCards.dressed(SiriCardRow(card, id: id)))
            }
        }
    }

    /// The question before saving: all of it out loud; on screen a short
    /// line over the card, which says the rest.
    struct Ask {
        let spoken: String
        let shown: String
        let card: ParseClient.Card
    }

    static func list(_ kind: String) -> String {
        kind == Item.Kind.place ? "Places" : "Events"
    }

    /// Asks with the found save's card under the question, so a wrong
    /// guess (last year's show, the other branch) shows as well as sounds.
    @MainActor
    static func add(_ what: String, asking intent: some AppIntent) async throws -> Outcome {
        try await add(what, lookUp: { try await SaveInbox.lookUp($0, for: intent) }) { ask in
            if Siri.voiceOnly(intent) {
                try await intent.requestConfirmation(actionName: .add, dialog: "\(ask.spoken)")
                return
            }
            let row = await SiriCards.dressed(SiriCardRow(ask.card), wait: true)
            try await intent.requestConfirmation(
                actionName: .add,
                dialog: IntentDialog(full: "\(ask.spoken)", supporting: "\(ask.shown)")
            ) {
                SiriSaveCard(row: row)
            }
        }
    }

    /// Looks it up, answers an exact duplicate with who saved it, asks
    /// (naming any near-match), and on a yes parks it in the inbox.
    @MainActor
    static func add(
        _ what: String,
        lookUp: (String) async throws -> ParseClient.Card,
        confirm: (Ask) async throws -> Void
    ) async throws -> Outcome {
        guard SupabaseAuth.shared.signedIn, let userId = SupabaseAuth.shared.userId else {
            throw SaveIntentError.signedOut
        }
        let asked = what.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { throw SaveIntentError.nothingAsked }
        let card = try await lookUp(asked)
        let library = SaveLibrary.all()
        // A page the parser found for a description is a lead, not proof:
        // it goes through the lookalike question below instead.
        if let twin = DuplicateFinder.match(
            url: card.source == "link" ? card.url : nil,
            title: card.title, startsOn: card.starts_on, kind: card.kind, in: library
        ) {
            return .alreadySaved(twin)
        }
        let samePage = card.source == "link" ? nil
            : DuplicateFinder.match(url: card.url, title: nil, startsOn: nil, kind: nil, in: library)
        if let similar = samePage ?? lookalike(of: card, in: library) {
            try await confirm(Ask(
                spoken: "I found \(spoken(card)). You already have \u{201c}\(similar.title)\u{201d} saved. Add this one too?",
                shown: "You already have \u{201c}\(similar.title)\u{201d}. Add this one too?",
                card: card
            ))
        } else {
            try await confirm(Ask(
                spoken: "I found \(spoken(card)). Add it?",
                shown: "Add this to \(list(card.kind))?",
                card: card
            ))
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

    /// A Siri or Shortcuts look-up. On iOS 27 one still going after a few
    /// seconds carries on as a background task with its progress showing,
    /// and gets the parser's full time rather than the 45 seconds Siri
    /// would otherwise wait. A quick one never leaves the conversation.
    static func lookUp(_ text: String, for intent: some AppIntent) async throws -> ParseClient.Card {
        if #available(iOS 27.0, *), let long = intent as? any LongRunningIntent {
            return try await lookUpLong(text, in: long)
        }
        return try await lookUp(text)
    }

    static let longLookUp: Double = 100
    static let quickLookUp: Duration = .seconds(8)

    @available(iOS 27.0, *)
    private static func lookUpLong(_ text: String, in intent: some LongRunningIntent) async throws -> ParseClient.Card {
        let lookup = Task { try await lookUp(text, within: longLookUp) }
        let quick = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ParseClient.Card?.self) { group in
                group.addTask { try await lookup.value }
                group.addTask {
                    try await Task.sleep(for: quickLookUp)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        } onCancel: {
            lookup.cancel()
        }
        if let quick { return quick }
        intent.progress.totalUnitCount = 1
        intent.progress.localizedDescription = "Looking it up"
        let card = try await intent.performBackgroundTask {
            try await withTaskCancellationHandler {
                try await lookup.value
            } onCancel: {
                lookup.cancel()
            }
        }
        intent.progress.completedUnitCount = 1
        return card
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
    case noModel
    case unanswered

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Can We Go first."
        case .notALink: "That isn't a web link."
        case .nothingAsked: "Tell me what to add, like \u{201c}the new Anish Kapoor show at the Hayward\u{201d}."
        case .lookup(let why): "\(why)"
        case .tooSlow: "That\u{2019}s taking too long to look up. Try again in a moment, or add it in the app."
        case .noModel: "Asking your saves needs Apple Intelligence turned on."
        case .unanswered: "I couldn\u{2019}t answer that one. Try asking another way."
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
            intent: AskLibraryIntent(),
            phrases: [
                "Ask \(.applicationName) something",
                "Ask \(.applicationName) a question",
                "Ask my saves in \(.applicationName)",
            ],
            shortTitle: "Ask Your Saves",
            systemImageName: "sparkles"
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
