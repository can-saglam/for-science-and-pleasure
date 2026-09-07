import Foundation

/// Which app opens when someone taps a map or "get there". Google Maps
/// stays the default (the richer place cards); Settings offers Apple Maps
/// and Citymapper. One choice, applied everywhere directions are offered.
enum TransportApp: String, CaseIterable, Identifiable {
    case google
    case apple
    case citymapper

    var id: String { rawValue }

    static let key = "transportApp"

    static var current: TransportApp {
        let defaults = UserDefaults(suiteName: SharedInbox.groupID) ?? .standard
        return defaults.string(forKey: key).flatMap(TransportApp.init(rawValue:)) ?? .google
    }

    var name: String {
        switch self {
        case .google: "Google Maps"
        case .apple: "Apple Maps"
        case .citymapper: "Citymapper"
        }
    }

    /// The destination for one save, in this app's URL dialect. Every
    /// variant opens the native app when installed and the web otherwise.
    func url(for item: Item) -> URL? {
        switch self {
        case .google:
            return item.googleMapsURL
        case .apple:
            var components = URLComponents(string: "https://maps.apple.com/")!
            var query: [URLQueryItem] = []
            if let name = item.placeQuery { query.append(.init(name: "q", value: name)) }
            if let c = item.coordinate {
                query.append(.init(name: "ll", value: "\(c.latitude),\(c.longitude)"))
            }
            guard !query.isEmpty else { return nil }
            components.queryItems = query
            return components.url
        case .citymapper:
            // Citymapper routes to a coordinate; a save with no pin yet
            // falls back to a Google search rather than a dead tap.
            guard let c = item.coordinate else { return item.googleMapsURL }
            var components = URLComponents(string: "https://citymapper.com/directions")!
            components.queryItems = [
                .init(name: "endcoord", value: "\(c.latitude),\(c.longitude)"),
                .init(name: "endname", value: item.venue ?? item.title),
            ]
            return components.url
        }
    }
}
