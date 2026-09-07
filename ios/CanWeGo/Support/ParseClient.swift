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
        let ingestSecret: String

        static let shared: Secrets? = {
            guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: String],
                  let base = dict["SUPABASE_URL"].flatMap(URL.init(string:)),
                  let secret = dict["INGEST_SECRET"]
            else { return nil }
            return Secrets(supabaseURL: base, ingestSecret: secret)
        }()
    }

    static var isConfigured: Bool { Secrets.shared != nil }

    /// One silent retry on a transient failure — a dropped connection, a
    /// gateway timeout while the web-search fallback runs long — before the
    /// user is asked to try again. Anything that reads like a real answer
    /// ("couldn't find a venue", 4xx) surfaces straight away.
    static func parse(text: String?, imageJPEG: Data?) async throws -> Card {
        do {
            return try await parseOnce(text: text, imageJPEG: imageJPEG)
        } catch let error where isTransient(error) {
            try? await Task.sleep(for: .seconds(1.5))
            return try await parseOnce(text: text, imageJPEG: imageJPEG)
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
        request.setValue(secrets.ingestSecret, forHTTPHeaderField: "x-ingest-secret")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw ParseError.server(message ?? "Couldn't read that one (\(status)).", status: status)
        }
        struct Envelope: Decodable { let card: Card }
        return try JSONDecoder().decode(Envelope.self, from: data).card
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
        request.setValue(secrets.ingestSecret, forHTTPHeaderField: "x-ingest-secret")
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
