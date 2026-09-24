import FoundationModels
import UIKit
import Vision

/// A first look at a save, made on the phone in a second or two while the
/// parser works: kind, title, venue and dates from Apple's on-device model.
/// Only a preview (the parser's card replaces it) unless the phone is
/// offline, when it can be saved and finished later. Phones without Apple
/// Intelligence never see it.
enum InstantDraft {
    @Generable
    struct Card {
        @Guide(description: "event for something on at a particular time (exhibition, gig, talk, festival, market, screening); place for somewhere you can go any time (restaurant, bar, café, shop, museum, park)")
        var kind: Kind
        @Guide(description: "The name as written, without the dates or the venue")
        var title: String
        @Guide(description: "The venue or building, only if written")
        var venue: String?
        @Guide(description: "The neighbourhood, town or city, only if written")
        var area: String?
        @Guide(description: "The first day as yyyy-MM-dd, only if a date is written")
        var startsOn: String?
        @Guide(description: "The last day as yyyy-MM-dd, only if written")
        var endsOn: String?
    }

    @Generable
    enum Kind {
        case event
        case place
    }

    /// What survived the check against the input, ready to become a card.
    struct Draft: Sendable {
        var kind: String
        var title: String
        var venue: String?
        var area: String?
        var startsOn: String?
        var endsOn: String?

        /// An unsaved card, like the parser's draft before Save.
        @MainActor
        var item: Item {
            let item = Item()
            item.kind = kind
            item.title = title
            item.venue = venue
            item.area = area
            item.startsOn = startsOn
            item.endsOn = endsOn
            return item
        }
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Nil when the model is missing, the input is only a link (the page is
    /// the parser's to read), or the answer doesn't stand up against what
    /// was actually written.
    static func make(text: String?, imageJPEG: Data?) async -> Draft? {
        guard isAvailable else { return nil }
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let picture = imageJPEG.flatMap { UIImage(data: $0)?.cgImage }
        var seen: [String] = []
        if let picture {
            seen = (try? await RecognizeTextRequest().perform(on: picture))?
                .compactMap { $0.topCandidates(1).first?.string } ?? []
        }
        let words = typed.isEmpty || isJustALink(typed) ? seen : [typed] + seen
        let source = words.joined(separator: "\n")
        guard source.count >= 3, !Task.isCancelled else { return nil }

        let session = LanguageModelSession(instructions: """
            Someone is saving something to a shared list of things to do together. \
            From the screenshot's text, caption or description, fill in the card using only what is written. \
            Leave a field empty rather than guess. Today is \(DayString.today()).
            """)
        guard let card = try? await session.respond(to: prompt(source, picture: picture), generating: Card.self).content,
              !Task.isCancelled
        else { return nil }
        return checked(card, against: source)
    }

    private static func prompt(_ source: String, picture: CGImage?) -> Prompt {
        if #available(iOS 27.0, *), let picture, SystemLanguageModel.default.capabilities.contains(.vision) {
            return Prompt {
                "What is being saved?\n\(source)"
                Attachment(picture)
            }
        }
        return Prompt("What is being saved?\n\(source)")
    }

    private static func isJustALink(_ text: String) -> Bool {
        !text.contains(where: \.isWhitespace) && (text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("www."))
    }

    /// Only what can be found in the input survives: a title with none of
    /// its words written anywhere is the model's invention, not the poster's.
    private static func checked(_ card: Card, against source: String) -> Draft? {
        let written = " \(DuplicateFinder.normalizeTitle(source)) "
        func isWritten(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            let words: [String] = DuplicateFinder.normalizeTitle(value)
                .split(separator: " ").map(String.init).filter { $0.count >= 3 }
            guard !words.isEmpty else { return written.contains(" \(DuplicateFinder.normalizeTitle(value)) ") ? value : nil }
            let found = words.filter { written.contains(" \($0) ") }.count
            return found * 2 >= words.count ? value : nil
        }
        guard let title = isWritten(card.title) else { return nil }
        let shouted = title.contains(where: \.isLetter) && title == title.uppercased()
        var draft = Draft(
            kind: card.kind == .place ? Item.Kind.place : Item.Kind.event,
            title: shouted ? title.localizedCapitalized : title,
            venue: isWritten(card.venue),
            area: isWritten(card.area)
        )
        if card.kind == .event, let start = card.startsOn, DayString.dayNumber(start) != nil {
            draft.startsOn = start
            if let end = card.endsOn, DayString.dayNumber(end) != nil, end >= start {
                draft.endsOn = end
            }
        }
        return draft
    }
}
