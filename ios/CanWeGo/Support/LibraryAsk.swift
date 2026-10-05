import Foundation
import FoundationModels

/// "Anything free near Peckham on Saturday?": a question put to the
/// library, answered on the phone by Apple's model. Nothing leaves the
/// device. The model only reads the question and writes the answer; the
/// searching in between is the app's own, so "this weekend" means the
/// days the saves are actually on.
@available(iOS 27.0, *)
@MainActor
enum LibraryAsk {
    struct Answer {
        let text: String
        let items: [Item]
    }

    enum Problem: Error {
        case unavailable
        case tooSlow
    }

    /// Apple Intelligence is on and the model is ready on this phone.
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    @Generable
    enum Kind {
        case events, places, both
    }

    @Generable
    struct Search {
        @Guide(description: "Words to look for in the saves' titles, venues, areas, categories and descriptions, with close synonyms, like [\"ceramics\", \"pottery\"] or [\"Peckham\"]. Empty when the question names no topic, place or thing.")
        var keywords: [String]
        @Guide(description: "Whether the question is about events (exhibitions, gigs, talks), places (restaurants, cafés, bars, shops) or both.")
        var kind: Kind
        @Guide(description: "The first day the question is about, as yyyy-MM-dd. Empty when it names no time.")
        var from: String
        @Guide(description: "The last day the question is about, as yyyy-MM-dd. Empty when it names no time.")
        var to: String
        @Guide(description: "True only when the question asks for free things.")
        var free: Bool
        @Guide(description: "True only when the question is about places or events already been to.")
        var been: Bool
    }

    @Generable
    struct Reply {
        @Guide(description: "One or two short, warm sentences, under 30 words, answering the question from the saves listed. Name them by title; the cards under the answer show the details.")
        var answer: String
        @Guide(description: "The exact titles, from the list, of the saves the answer is about, best first. Empty when none fit.", .maximumCount(4))
        var titles: [String]
    }

    static func ask(_ question: String) async throws -> Answer {
        guard isAvailable else { throw Problem.unavailable }
        let (text, ids) = try await within(.seconds(40)) {
            var search = try await LanguageModelSession(instructions: searchInstructions())
                .respond(to: question, generating: Search.self).content
            // The model fills in what the question never said.
            let said = words(question)
            if !namesTime(said) { search.from = ""; search.to = "" }
            if !said.contains("free") { search.free = false }
            if said.isDisjoint(with: pastWords) { search.been = false }
            let closing = !said.isDisjoint(with: closingWords)
            if closing { search.kind = .events }
            let found = matches(search, topic: terms(said), closing: closing)
            guard !found.isEmpty else { return ("Nothing in your saves fits that.", [UUID]()) }
            let list = found.prefix(12).enumerated()
                .map { "\($0.offset + 1). \(line($0.element))" }
                .joined(separator: "\n")
            let reply = try await LanguageModelSession(instructions: answerInstructions())
                .respond(to: "Question: \(question)\n\nSaves that fit:\n\(list)", generating: Reply.self).content
            return (reply.answer, picked(reply.titles, from: found).map(\.id))
        }
        let library = SaveLibrary.all()
        return Answer(text: text, items: ids.compactMap { id in library.first { $0.id == id } })
    }

    // MARK: - Searching

    /// The library narrowed the way the model read the question: kind,
    /// days on (a plan on one of them counts too) or, with `closing`,
    /// the last day among them; free, been. Then the words: a topic in
    /// the question itself must match (the model's synonyms widen it);
    /// with none, the model's words only rank. Most matches first.
    private static func matches(_ search: Search, topic: Set<String>, closing: Bool) -> [Item] {
        var from = day(search.from), to = day(search.to) ?? day(search.from)
        if closing, from == nil {
            from = DayString.today()
            to = DayString.addingDays(21, to: DayString.today())
        }
        let extra = terms(Set(search.keywords.flatMap { words($0) })).subtracting(topic)
        let scored = SaveLibrary.all().compactMap { item -> (Item, Int)? in
            switch search.kind {
            case .events where item.isPlace, .places where !item.isPlace: return nil
            default: break
            }
            if search.been != (item.isDone || item.isMissed) { return nil }
            if search.free, !(item.price?.localizedCaseInsensitiveContains("free") ?? false) { return nil }
            if let from, let to, !item.isPlace {
                if closing {
                    guard let end = item.endsOn, end >= from, end <= to else { return nil }
                } else if !on(item, from: from, to: to) {
                    return nil
                }
            }
            guard !topic.isEmpty || !extra.isEmpty else { return (item, 0) }
            let hay = haystack(item)
            let hits = topic.filter { hay.contains($0) }.count * 2 + extra.filter { hay.contains($0) }.count
            return hits > 0 || topic.isEmpty ? (item, hits) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : soonest($0.0) < soonest($1.0) }.map(\.0)
    }

    private static func on(_ item: Item, from: String, to: String) -> Bool {
        if let plan = item.upcomingPlan, plan >= from, plan <= to { return true }
        guard let start = item.startsOn ?? item.endsOn else { return false }
        let end = item.endsOn ?? start
        return start <= to && end >= from
    }

    /// Planned first, by the plan; then whatever ends soonest.
    private static func soonest(_ item: Item) -> String {
        if let plan = item.upcomingPlan { return "0\(plan)" }
        return "1\(item.endsOn ?? item.startsOn ?? "9999")"
    }

    private static func haystack(_ item: Item) -> String {
        [
            item.title, item.venue, item.area, item.address, item.category.map(Item.categoryLabel),
            item.summary, item.notes, item.price, MembersStore.shared.saverName(for: item),
        ]
        .compactMap(\.self)
        .joined(separator: " ")
        .lowercased()
    }

    /// Words worth looking for: no filler, no time, plurals made single.
    private static func terms(_ words: Set<String>) -> Set<String> {
        Set(words
            .filter { $0.count >= 3 && !ignored.contains($0) && !timeWords.contains($0) && !pastWords.contains($0) }
            .map { $0.count > 4 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    private static let ignored: Set<String> = [
        "the", "and", "any", "anything", "something", "somewhere", "some", "event", "events", "place",
        "places", "saved", "saves", "save", "this", "that", "these", "those", "with", "for", "from",
        "near", "around", "free", "cheap", "show", "shows", "thing", "things", "stuff", "good", "best",
        "new", "fun", "nice", "cool", "interesting", "see", "visit", "eat", "drink", "going", "should",
        "could", "would", "will", "want", "what", "whats", "where", "which", "when", "who", "whom",
        "how", "are", "does", "have", "has", "can", "our", "ours", "you", "your", "they", "them",
        "their", "there", "get", "got", "like", "find", "tell", "give", "recommend", "suggest",
        "still", "lot", "much", "many", "most", "more", "all", "trip", "out", "into", "about",
        "worth", "time", "day", "days", "list", "app",
    ]

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private static func namesTime(_ words: Set<String>) -> Bool {
        !words.isDisjoint(with: timeWords) || words.contains { $0.first?.isNumber == true }
    }

    private static let closingWords: Set<String> = ["closing", "close", "closes", "ending", "ends"]

    private static let pastWords: Set<String> = [
        "been", "went", "visited", "past", "already", "before", "gone", "did", "were", "was",
    ]

    private static let timeWords: Set<String> = {
        var words: Set<String> = [
            "today", "tonight", "tomorrow", "weekend", "week", "month", "now", "soon",
            "closing", "close", "closes", "ending", "ends", "opening", "open", "upcoming", "next",
            "later", "yesterday", "last", "ago", "recently",
        ]
        let symbols = Calendar(identifier: .gregorian)
        for list in [symbols.weekdaySymbols, symbols.shortWeekdaySymbols, symbols.monthSymbols] {
            words.formUnion(list.map { $0.lowercased() })
        }
        return words
    }()

    private static func day(_ text: String) -> String? {
        text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil ? text : nil
    }

    /// The saves the answer names, in its order; failing that, the best
    /// few found that it mentions.
    private static func picked(_ titles: [String], from found: [Item]) -> [Item] {
        func key(_ s: String) -> String { DuplicateFinder.normalizeTitle(s) }
        var picked: [Item] = []
        for title in titles {
            let wanted = key(title)
            guard !wanted.isEmpty else { continue }
            let match = found.first { key($0.title) == wanted }
                ?? found.first { key($0.title).contains(wanted) || wanted.contains(key($0.title)) }
            if let match, !picked.contains(where: { $0.id == match.id }) { picked.append(match) }
        }
        return picked
    }

    // MARK: - What the model reads

    private static let long = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year()

    private static func spoken(_ day: String) -> String { DayString.text(day, long) ?? day }

    /// One save in a few plain sentences: what and where, when, the plan,
    /// the rest. Days left are counted here; the model doesn't count.
    private static func line(_ item: Item) -> String {
        let what = item.category.map(Item.categoryLabel) ?? (item.isPlace ? "Place" : "Event")
        let at = [item.venue, item.area].compactMap(\.self).filter { $0 != item.title }
        var parts = [at.isEmpty ? "\(what)." : "\(what) at \(at.joined(separator: ", "))."]
        let today = DayString.today()
        if let start = item.startsOn, start > today {
            parts.append("Opens \(spoken(start)).")
        }
        if let end = item.endsOn, end >= today, end != item.startsOn,
           let left = DayString.daysBetween(today, end) {
            parts.append(left == 0 ? "Ends today." : "Ends in \(left) day\(left == 1 ? "" : "s").")
        } else if item.endsOn == nil || item.endsOn == item.startsOn, let day = item.startsOn {
            parts.append("On \(spoken(day)).")
        }
        if let plan = item.upcomingPlan {
            parts.append("Planned for \(spoken(plan))\(item.planTime.map { " at \($0)" } ?? "").")
        }
        if item.isDone { parts.append("Been already.") }
        if let price = item.price { parts.append("\(price).") }
        if let saver = MembersStore.shared.saverName(for: item) { parts.append("Saved by \(saver).") }
        if let summary = item.summary?.prefix(100) { parts.append("\(summary)…") }
        return "\(item.title): \(parts.joined(separator: " "))"
    }

    private static func searchInstructions() -> String {
        let today = DayString.today()
        let sunday = DayString.endOfThisWeek()
        func plus(_ days: Int, _ from: String) -> String { DayString.addingDays(days, to: from) ?? from }
        let dayOfMonth = Calendar.current.component(.day, from: .now)
        let daysInMonth = Calendar.current.range(of: .day, in: .month, for: .now)?.count ?? dayOfMonth
        let monthEnd = plus(daysInMonth - dayOfMonth, today)
        let lastMonthEnd = plus(-dayOfMonth, today)
        let lastMonthStart = String(lastMonthEnd.prefix(8)) + "01"
        return """
        You turn a question about a saved list of events and places into a search. \
        Today is \(spoken(today)), \(today). Tonight is \(today). Tomorrow is \(plus(1, today)). \
        This week is \(today) to \(sunday). This weekend is \(plus(-1, sunday)) to \(sunday). \
        Next week is \(plus(1, sunday)) to \(plus(7, sunday)). Next weekend is \(plus(6, sunday)) to \(plus(7, sunday)). \
        This month is \(today) to \(monthEnd). Soon means \(today) to \(plus(21, today)). \
        Last week is \(plus(-13, sunday)) to \(plus(-7, sunday)). \
        Last month is \(lastMonthStart) to \(plus(-dayOfMonth, today)). \
        Use yyyy-MM-dd for days.
        """
    }

    private static func answerInstructions() -> String {
        """
        You answer questions about a saved list in the app Can We Go: events and \
        places the user and their friends want to go to. Today is \(spoken(DayString.today())). \
        Use only the saves listed; never invent one. The list comes best first. Answer \
        like a friend, in one or two short sentences under 30 words, naming the best \
        few by title. No greeting, and don't repeat the list's details.
        """
    }

    private static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() ?? nil else { throw Problem.tooSlow }
            return value
        }
    }
}
