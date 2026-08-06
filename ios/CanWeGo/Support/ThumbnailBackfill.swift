import Foundation
import SwiftData

/// Items saved before thumbnails existed have a URL but no image. On launch
/// this quietly fetches each page's og:image and stores it — best effort,
/// no LLM involved, sites that block bots are simply skipped.
enum ThumbnailBackfill {
    @MainActor
    static func run(context: ModelContext) async {
        guard let all = try? context.fetch(FetchDescriptor<Item>()) else { return }
        let missing = all.filter { $0.imageUrl == nil && $0.url != nil }
        guard !missing.isEmpty else { return }

        var found = false
        for item in missing {
            guard let url = item.url.flatMap(URL.init(string:)),
                  url.scheme?.hasPrefix("http") == true
            else { continue }
            if let image = await ogImage(at: url) {
                item.imageUrl = image
                found = true
            }
        }
        if found { try? context.save() }
    }

    private static func ogImage(at url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        // Plenty of venue sites serve bots a stripped page; look like Safari.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
        else { return nil }

        let head = data.prefix(400_000)
        guard let html = String(data: head, encoding: .utf8)
            ?? String(data: head, encoding: .isoLatin1)
        else { return nil }

        // og:image / twitter:image, tolerant of attribute order.
        let patterns = [
            #"<meta[^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let raw = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
            // Relative paths resolve against the page they came from.
            if let absolute = URL(string: raw, relativeTo: url)?.absoluteString {
                return absolute
            }
        }
        return nil
    }
}
