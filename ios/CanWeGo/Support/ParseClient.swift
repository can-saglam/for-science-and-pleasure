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
        let color: String?
        let image_url: String?
        let source: String?
    }

    enum ParseError: LocalizedError {
        case notConfigured
        case server(String, status: Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Missing Secrets.plist. See ios/README.md."
            case .server(let message, _):
                return message
            }
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

    /// One silent retry on a transient failure — a dropped connection, a
    /// gateway timeout while the web-search fallback runs long — before the
    /// user is asked to try again. Anything that reads like a real answer
    /// ("couldn't find a venue", 4xx) surfaces straight away.
    static func parse(text: String?, imageJPEG: Data?) async throws -> Card {
        // Social links pick up their caption and cover on-device first —
        // the phone can read what the server's IP is often walled from.
        let input = await SocialPrefetch.enrich(text: text, imageJPEG: imageJPEG)
        do {
            return try await parseOnce(text: input.text, imageJPEG: input.imageJPEG)
        } catch let error where isTransient(error) {
            try? await Task.sleep(for: .seconds(1.5))
            return try await parseOnce(text: input.text, imageJPEG: input.imageJPEG)
        }
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
            return "That\u{2019}s today\u{2019}s reading done. Come back tomorrow, or fill the card in yourself."
        case 500...:
            return "The server tripped over that one. Try again in a moment."
        default:
            return "Couldn't read that one. Try again in a moment."
        }
    }

    private static func parseOnce(text: String?, imageJPEG: Data?) async throws -> Card {
        guard let secrets = Secrets.shared else { throw ParseError.notConfigured }

        var body: [String: String] = [:]
        if let text, !text.isEmpty { body["text"] = text }
        if let imageJPEG {
            body["image_base64"] = imageJPEG.base64EncodedString()
            body["image_media_type"] = "image/jpeg"
        }

        var request = URLRequest(url: secrets.supabaseURL.appending(path: "functions/v1/parse"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120 // web-search fallback can take a while
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let jwt = try await SupabaseAuth.shared.validToken()
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let serverMessage = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw ParseError.server(friendly(status: status, serverMessage: serverMessage), status: status)
        }
        struct Envelope: Decodable { let card: Card }
        return try JSONDecoder().decode(Envelope.self, from: data).card
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
