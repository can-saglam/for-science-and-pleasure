import AppIntents
import AppIntentsTesting
import XCTest

/// Runs Siri's and Shortcuts' view of the library against the installed
/// app, signed in, on whatever saves the simulator holds. Checks shape and
/// the date rules rather than exact titles, and prints what Siri would say
/// so it can be compared with the Events page by eye.
final class SaveIntentTests: XCTestCase {
    private let definitions = IntentDefinitions(bundleIdentifier: "com.cansaglam.CanWeGo")
    private var saves: AppEntityDefinition { definitions.entities["SaveEntity"] }

    private func titles(_ entities: [AnyAppEntity]) throws -> [String] {
        try entities.map { try $0.title }
    }

    private func values(_ result: ResolvedIntentResult) -> [AnyAppEntity] {
        let value: DynamicPropertyPath = result.value
        var out: [AnyAppEntity] = []
        while let entity: AnyAppEntity = try? value[out.count] { out.append(entity) }
        return out
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func testSuggestedSavesAreTheLibrary() async throws {
        let suggested = try await saves.suggestedEntities()
        print("suggested \(suggested.count):", try titles(suggested).prefix(10))
        XCTAssertFalse(suggested.isEmpty)
        XCTAssertLessThanOrEqual(suggested.count, 40)
        XCTAssertEqual(Set(suggested.map(\.identifier.instanceIdentifier)).count, suggested.count, "no save twice")
    }

    func testSearchNeedsEveryWord() async throws {
        let suggested = try await saves.suggestedEntities()
        let first: String = try XCTUnwrap(suggested.first).title
        let word = try XCTUnwrap(first.split(separator: " ").first.map(String.init))
        let hits = try await saves.entities(matching: word)
        print("matching \"\(word)\":", try titles(hits))
        XCTAssertTrue(try titles(hits).contains(first))

        let none = try await saves.entities(matching: "\(word) zzqxv")
        XCTAssertTrue(none.isEmpty, "a word nothing has rules everything out")
    }

    func testLookupByIdRoundTrips() async throws {
        let suggested = try await saves.suggestedEntities()
        let one = try XCTUnwrap(suggested.first)
        let back = try await saves.entities(identifiers: [one.identifier.instanceIdentifier])
        XCTAssertEqual(try titles(back), [try one.title])
    }

    func testWhatsOnFollowsTheHomeCalendar() async throws {
        let today = Self.day.string(from: .now)
        for period in ["today", "weekend", "week", "closing"] {
            let intent = definitions.intents["WhatsOnIntent"].makeIntent(
                period: AnyAppEnum(typeIdentifier: "SavePeriod", rawValue: period)
            )
            let found = values(try await intent.run())
            print("what's on \(period) \(found.count):", try titles(found))
            for entity in found {
                let type: String = try entity.type
                XCTAssertEqual(type, "Event", "places have no dates")
                if let ends: Date = try? entity.ends {
                    let title: String = try entity.title
                    XCTAssertGreaterThanOrEqual(Self.day.string(from: ends), today, "\(title) has ended")
                }
            }
        }
    }

    func testClosingSoonIsWithinThreeWeeks() async throws {
        let found = values(try await definitions.intents["ClosingSoonIntent"].makeIntent().run())
        print("closing soon \(found.count):", try titles(found))
        let limit = Self.day.string(from: .now.addingTimeInterval(22 * 86_400))
        var last = ""
        for entity in found {
            let ends: Date = try entity.ends
            let day = Self.day.string(from: ends)
            XCTAssertLessThan(day, limit)
            XCTAssertGreaterThanOrEqual(day, last, "soonest first")
            last = day
        }
    }

    /// Brings the app up on the save; the screenshot shows the sheet.
    @MainActor
    func testOpenShowsTheSave() async throws {
        let suggested = try await saves.suggestedEntities()
        let one = try XCTUnwrap(suggested.first)
        try await definitions.intents["OpenSaveIntent"].makeIntent(target: one).run()
        let app = XCUIApplication(bundleIdentifier: "com.cansaglam.CanWeGo")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let title: String = try one.title
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 10), "\(title) on screen")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Only the paths that add nothing: a link already saved, and not a link.
    func testSaveLinkNeverDuplicates() async throws {
        let withLink = try await saves.suggestedEntities().first { (try? $0.link as URL) != nil }
        let link: URL = try XCTUnwrap(withLink).link
        try await definitions.intents["SaveLinkIntent"].makeIntent(link: link).run()

        do {
            try await definitions.intents["SaveLinkIntent"].makeIntent(link: URL(string: "mailto:someone@example.com")!).run()
            XCTFail("a mail link isn't a save")
        } catch {}
    }

    /// Only the path that looks nothing up: an empty request. The rest ends
    /// in a spoken confirmation, which this harness can't answer.
    func testAddNeedsSomethingToAdd() async throws {
        do {
            try await definitions.intents["AddToLibraryIntent"].makeIntent(what: "  ").run()
            XCTFail("an empty request adds nothing")
        } catch {}
    }

    /// iOS 27's "add … to Can We Go": Events and Places are the lists, and
    /// an empty title is refused before anything is looked up.
    func testSiriListsAreEventsAndPlaces() async throws {
        let lists = try await definitions.entities["SaveListEntity"].suggestedEntities()
        XCTAssertEqual(try lists.map { try $0.name as String }, ["Events", "Places"])
        do {
            try await definitions.intents["AddSaveByVoiceIntent"].makeIntent(title: " ").run()
            XCTFail("an empty title adds nothing")
        } catch {}
    }

    func testSpotlightKnowsTheSaves() async throws {
        let suggested = try await saves.suggestedEntities()
        let first: String = try XCTUnwrap(suggested.first).title
        let hits = try await saves.spotlightQuery(first)
        print("spotlight \"\(first)\":", try titles(hits))
        XCTAssertTrue(try titles(hits).contains(first))
    }
}
