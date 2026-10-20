import Foundation

/// A save sent to someone outside the library: `wegocan.com/s/<token>`
/// opens a copy of its card, on the web or here ready to save. The copy is
/// the card's public part only; notes, plans and reminders stay home.
enum SaveLink {
    /// The card as the parser would answer it, so the other end opens it
    /// the way it opens a parsed one.
    private struct Outgoing: Encodable {
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
        let image_url: String?
        let color: String?
        let lat: Double?
        let lng: Double?
        let place_id: String?
        let showings: [Showing]?

        init(_ item: Item) {
            kind = item.kind
            title = item.title
            summary = item.summary
            venue = item.venue
            area = item.area
            address = item.address
            category = item.category
            price = item.price
            starts_on = item.startsOn
            ends_on = item.endsOn
            url = item.url
            image_url = item.imageUrl
            color = item.colorHex
            lat = item.lat
            lng = item.lng
            place_id = item.placeId
            showings = item.showings.isEmpty ? nil : item.showings
        }
    }

    private struct Request: Encodable {
        let item_id: String
        let card: Outgoing
    }

    /// The save's link, made on first share and the same one after.
    static func url(for item: Item) async throws -> URL {
        guard let secrets = ParseClient.Secrets.shared else { throw ParseClient.ParseError.notConfigured }
        var request = URLRequest(url: secrets.supabaseURL.appending(path: "functions/v1/share"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let jwt = try await SupabaseAuth.shared.validToken()
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            Request(item_id: item.id.uuidString.lowercased(), card: Outgoing(item))
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct Made: Decodable { let url: URL }
        guard status == 200, let made = try? JSONDecoder().decode(Made.self, from: data) else {
            throw ParseClient.ParseError.server("Couldn\u{2019}t make a link (\(status)).", status: status)
        }
        return made.url
    }

    /// The card behind a link, or nil once it's gone.
    static func card(token: String) async throws -> ParseClient.Card? {
        guard let secrets = ParseClient.Secrets.shared else { throw ParseClient.ParseError.notConfigured }
        var parts = URLComponents(
            url: secrets.supabaseURL.appending(path: "functions/v1/share"),
            resolvingAgainstBaseURL: false
        )!
        parts.queryItems = [URLQueryItem(name: "t", value: token)]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else {
            throw ParseClient.ParseError.server("Couldn\u{2019}t open that save (\(status)).", status: status)
        }
        struct Envelope: Decodable { let card: ParseClient.Card }
        return try JSONDecoder().decode(Envelope.self, from: data).card
    }

    /// The token in a save link, or nil if the URL is something else.
    static func token(from url: URL) -> String? {
        guard let raw = OwnLink.value(in: url, section: "s") else { return nil }
        let token = raw.filter { $0.isLetter || $0.isNumber }
        return token.count == 10 && token == raw ? token : nil
    }
}

/// A save link that arrived before the screen that opens it (a cold
/// start, or someone still signing in).
enum ShareGate {
    static var pendingToken: String?
}

extension Notification.Name {
    /// A save link arrived — object carries its token.
    static let cwgSharedSave = Notification.Name("cwgSharedSave")
}
