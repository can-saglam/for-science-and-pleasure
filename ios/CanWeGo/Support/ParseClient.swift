import Foundation

/// Calls the stateless `parse` edge function — paste a link or attach a
/// screenshot, get back a structured card. Nothing is stored server-side.
///
/// Credentials come from Secrets.plist (gitignored; see Secrets.example.plist).
enum ParseClient {
    struct Card: Decodable {
        let kind: String
        let title: String
        let summary: String?
        let venue: String?
        let area: String?
        let address: String?
        let category: String?
        let price: String?
        let starts_on: String?
        let ends_on: String?
        let url: String?
        let lat: Double?
        let lng: Double?
        var color: String?
        var image_url: String?
        let source: String?
        let place_id: String?
        let showings: [Showing]?
        /// The page the model found for a typed name or a screenshot, on
        /// the early fields only.
        var link: String?
        /// The server was walled off from the save's own page.
        var page_unread: Bool?
    }

    enum ParseError: LocalizedError {
        case notConfigured
        case server(String, status: Int)
        /// A search rather than a save ("modern art museums in London"),
        /// which capture answers with its own note instead of a warning.
        /// `firm` once they've searched more than a few times today.
        case tooVague(String, firm: Bool)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Missing Secrets.plist. See ios/README.md."
            case .server(let message, _), .tooVague(let message, _):
                return message
            }
        }

        /// The day's lookups are used up. Never named as such: capture
        /// says "tomorrow" and points at filling the card in by hand.
        var isRestingForToday: Bool {
            if case .server(_, 429) = self { return true }
            return false
        }
    }

    private struct Secrets {
        let supabaseURL: URL

        static let shared: Secrets? = {
            if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
               let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let dict = plist as? [String: String],
               let base = dict["SUPABASE_URL"].flatMap(URL.init(string:)) {
                return Secrets(supabaseURL: base)
            }
            return Secrets(supabaseURL: SupabaseAuth.baseURL)
        }()
    }

    static var isConfigured: Bool { Secrets.shared != nil }

    /// The model's fields, a few seconds before the card: no address, pin,
    /// photo or colour yet. Decoded as a `Card` with those left empty.
    typealias Early = @MainActor (Card) -> Void

    /// One silent retry on a transient failure — a dropped connection, a
    /// gateway error — before the user is asked to try again, but only
    /// while nothing has come back: once the model's fields are in, the
    /// lookup has been done and asking again would do it twice. Anything
    /// that reads like a real answer ("couldn't find a venue", 4xx)
    /// surfaces straight away.
    static func parse(text: String?, imageJPEG: Data?, early: Early? = nil) async throws -> Card {
        // Social links pick up their caption and cover on-device first —
        // the phone can read what the server's IP is often walled from.
        let input = await SocialPrefetch.enrich(text: text, imageJPEG: imageJPEG)
        // The page the model finds for a typed name may wall off the
        // server too; the phone starts on its picture while the server's
        // lookups run, and uses it if the card says the server was kept out.
        let photo = PagePhoto()
        let heard = Flag()
        let watch: Early = { card in
            heard.set()
            if let link = card.link.flatMap(URL.init(string:)) { photo.start(link) }
            early?(card)
        }
        var card: Card
        do {
            card = try await parseReadingPage(text: input.text, imageJPEG: input.imageJPEG, early: watch)
        } catch let error where isTransient(error) && !heard.isSet {
            try? await Task.sleep(for: .seconds(1.5))
            card = try await parseReadingPage(text: input.text, imageJPEG: input.imageJPEG, early: watch)
        }
        if card.page_unread == true, let page = card.url.flatMap(URL.init(string:)),
           let lead = await photo.lead(orStart: page, within: .seconds(3)) {
            card.image_url = lead.url.absoluteString
            card.color = lead.colour ?? card.color
        }
        return card
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// One page's picture, read on the phone, started at most once.
    private final class PagePhoto: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<PagePhotos.Lead?, Never>?

        func start(_ page: URL) {
            lock.withLock {
                if task == nil { task = Task { await PagePhotos.lead(at: page) } }
            }
        }

        /// The picture, or nil if it isn't in by `limit`.
        func lead(orStart page: URL, within limit: Duration) async -> PagePhotos.Lead? {
            start(page)
            guard let task = lock.withLock({ task }) else { return nil }
            return await withTaskGroup(of: PagePhotos.Lead?.self) { group in
                group.addTask { await task.value }
                group.addTask {
                    try? await Task.sleep(for: limit)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
    }

    /// Some sites (Cloudflare's checks) wall off the server but not this
    /// phone. The server says so before reading anything else; the phone
    /// reads the page and sends it back, so the save comes from the page
    /// (its photo, its dates, its showings) rather than a web search.
    private static func parseReadingPage(text: String?, imageJPEG: Data?, early: Early?) async throws -> Card {
        do {
            return try await parseOnce(text: text, imageJPEG: imageJPEG, extra: ["page_fallback": "true"], early: early)
        } catch let blocked as PageBlocked {
            let html = await pageHTML(blocked.url)
            return try await parseOnce(text: text, imageJPEG: imageJPEG, extra: html.map { ["page_html": $0] } ?? [:], early: early)
        }
    }

    private struct PageBlocked: Error { let url: URL }

    private static func pageHTML(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
        else { return nil }
        return String(decoding: data.prefix(600_000), as: UTF8.self)
    }

    private static func isTransient(_ error: Error) -> Bool {
        if case ParseError.server(_, let status) = error {
            return status >= 500
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// The edge function's error bodies are written for logs ("internal
    /// error", "not a member"); the gateway's aren't written at all. Only a
    /// 422 carries a sentence meant for the person holding the phone.
    private static func friendly(status: Int, serverMessage: String?) -> String {
        switch status {
        case 422:
            return serverMessage ?? "Couldn't make sense of that one."
        case 400:
            return "Paste a link, some text, or add a screenshot first."
        case 401, 403:
            return "You're signed out. Sign in again from Settings."
        case 413:
            return "That photo is too big. Try a smaller screenshot."
        case 429:
            return "Let\u{2019}s pick this up tomorrow. You can still fill the card in yourself today."
        case 500...:
            return "The server tripped over that one. Try again in a moment."
        default:
            return "Couldn't read that one. Try again in a moment."
        }
    }

    private static func parseOnce(text: String?, imageJPEG: Data?, extra: [String: String], early: Early?) async throws -> Card {
        guard let secrets = Secrets.shared else { throw ParseError.notConfigured }

        var body = extra
        if let text, !text.isEmpty { body["text"] = text }
        if let imageJPEG {
            body["image_base64"] = imageJPEG.base64EncodedString()
            body["image_media_type"] = "image/jpeg"
        }
        if early != nil { body["stream"] = "true" }

        var request = URLRequest(url: secrets.supabaseURL.appending(path: "functions/v1/parse"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120 // web-search fallback can take a while
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let jwt = try await SupabaseAuth.shared.validToken()
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let streamed = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true
        guard status == 200, streamed, let early else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            guard status == 200 else { throw failure(status: status, data: data) }
            struct Envelope: Decodable { let card: Card }
            return try JSONDecoder().decode(Envelope.self, from: data).card
        }

        // One JSON object per `data:` line, named by the `event:` before it.
        var event = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let data = Data(line.dropFirst(5).utf8)
            switch event {
            case "early":
                if let card = try? JSONDecoder().decode(Card.self, from: data) {
                    await early(card)
                }
            case "card":
                return try JSONDecoder().decode(Card.self, from: data)
            case "error":
                struct Failure: Decodable { let status: Int }
                let status = (try? JSONDecoder().decode(Failure.self, from: data))?.status ?? 500
                throw failure(status: status, data: data)
            default:
                continue
            }
        }
        throw URLError(.networkConnectionLost)
    }

    private static func failure(status: Int, data: Data) -> Error {
        struct Body: Decodable { let error: String?; let code: String?; let firm: String?; let url: String? }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        if status == 409, body?.code == "page_blocked",
           let url = body?.url.flatMap(URL.init(string:)) {
            return PageBlocked(url: url)
        }
        let message = friendly(status: status, serverMessage: body?.error)
        if status == 422, body?.code == "too_vague" {
            return ParseError.tooVague(message, firm: body?.firm == "true")
        }
        return ParseError.server(message, status: status)
    }

    // MARK: - Suggestions (chips for the home city)

    struct Suggestion: Codable, Hashable, Identifiable {
        let title: String
        let url: String
        let kind: String
        var venue: String?
        var startsOn: String?
        var endsOn: String?
        var id: String { url }

        enum CodingKeys: String, CodingKey {
            case title, url, kind, venue
            case startsOn = "starts_on"
            case endsOn = "ends_on"
        }
    }

    struct SuggestionPool: Codable {
        let events: [Suggestion]
        let places: [Suggestion]
        /// No events yet for this city; a search for them is running.
        var eventsComing: Bool?

        enum CodingKeys: String, CodingKey {
            case events, places
            case eventsComing = "events_coming"
        }
    }

    /// Things on in `locality` and places worth going to, refreshed on the
    /// server weekly (events) and fortnightly (places). A stored pool is
    /// instant; only a brand-new city's places wait on a short model call.
    /// One retry on a drop.
    static func suggestions(locality: String, country: String) async throws -> SuggestionPool {
        do {
            return try await suggestionsOnce(locality: locality, country: country)
        } catch let error where isTransient(error) {
            try? await Task.sleep(for: .seconds(1))
            return try await suggestionsOnce(locality: locality, country: country)
        }
    }

    private static func suggestionsOnce(locality: String, country: String) async throws -> SuggestionPool {
        guard let secrets = Secrets.shared else { throw ParseError.notConfigured }

        var request = URLRequest(url: secrets.supabaseURL.appending(path: "functions/v1/suggestions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let jwt = try await SupabaseAuth.shared.validToken()
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["locality": locality, "country": country])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw ParseError.server(message ?? "Suggestions failed (\(status)).", status: status)
        }
        return try JSONDecoder().decode(SuggestionPool.self, from: data)
    }

    // MARK: - Locate (find missing locations)

    struct LocateItemPayload: Encodable {
        let id: String
        let kind: String
        let title: String
        let summary: String?
        let venue: String?
        let area: String?
        let address: String?
        let url: String?
        let notes: String?

        init(_ item: Item) {
            id = item.id.uuidString.lowercased()
            kind = item.kind
            title = item.title
            summary = item.summary
            venue = item.venue
            area = item.area
            address = item.address
            url = item.url
            notes = item.notes
        }
    }

    struct LocationProposal: Decodable, Identifiable {
        let id: String
        let venue: String?
        let area: String?
        let address: String?
        let confidence: String
        let lat: Double?
        let lng: Double?
    }

    static func locate(items: [Item]) async throws -> [LocationProposal] {
        guard let secrets = Secrets.shared else { throw ParseError.notConfigured }

        var request = URLRequest(url: secrets.supabaseURL.appending(path: "functions/v1/locate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120 // model + geocoding take a while
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let jwt = try await SupabaseAuth.shared.validToken()
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["items": items.map(LocateItemPayload.init)])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw ParseError.server(message ?? "Locate failed (\(status)).", status: status)
        }
        struct Envelope: Decodable { let proposals: [LocationProposal] }
        return try JSONDecoder().decode(Envelope.self, from: data).proposals
    }
}
