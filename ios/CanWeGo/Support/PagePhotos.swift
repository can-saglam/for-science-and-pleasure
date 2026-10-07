import Foundation
import UIKit

/// Every picture a page offers, for choosing a save's photo by hand: the
/// card images first (Open Graph, Twitter, JSON-LD), then the page's own
/// `<img>` tags in reading order. Logos, icons, sprites and maps-branded
/// assets are left out; anything that turns out tiny is the picker's to
/// drop once it has loaded.
enum PagePhotos {
    static func candidates(at url: URL, limit: Int = 18) async -> [URL] {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
        else { return [] }
        let head = data.prefix(600_000)
        guard let html = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1)
        else { return [] }

        let patterns = [
            #"<meta[^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["']"#,
            #""image"\s*:\s*\[?\s*(?:\{[^}]*?"url"\s*:\s*)?"(https?:[^"]+)""#,
            #"<img[^>]+(?:data-src|data-lazy-src|src)=["']([^"']+)["']"#,
        ]
        var seen = Set<String>()
        var found: [URL] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let raw = String(html[range])
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "\\/", with: "/")
                guard let resolved = URL(string: raw, relativeTo: url)?.absoluteURL,
                      usable(resolved),
                      seen.insert(resolved.absoluteString).inserted
                else { continue }
                found.append(resolved)
                if found.count == limit { return found }
            }
        }
        return found
    }

    private static func usable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else { return false }
        let s = url.absoluteString.lowercased()
        if url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty { return false }
        if [".svg", ".gif", ".ico"].contains(where: { url.path().lowercased().hasSuffix($0) }) { return false }
        if ["logo", "icon", "sprite", "avatar", "favicon", "badge", "pixel", "spinner", "placeholder"]
            .contains(where: s.contains) { return false }
        if s.range(of: #"(?:gstatic|googleusercontent)\.com.*maps|maps_\d+dp\.(?:png|webp)"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    /// A picked photo's colour, the way the parser chooses one
    /// (`dominantFromRgba` in color.ts): the most common saturated hue,
    /// greys and near-black or near-white left out, else the average.
    static func colour(of image: UIImage) -> String? {
        guard let cg = image.cgImage else { return nil }
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var buckets: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        var total = (n: 0, r: 0, g: 0, b: 0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            guard pixels[i + 3] >= 128 else { continue }
            total = (total.n + 1, total.r + r, total.g + g, total.b + b)
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high == 0 ? 0 : Double(high - low) / Double(high)
            let lightness = Double(high + low) / 510
            guard saturation >= 0.18, lightness >= 0.12, lightness <= 0.92 else { continue }
            let key = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5)
            let e = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (e.n + 1, e.r + r, e.g + g, e.b + b)
        }
        func hex(_ e: (n: Int, r: Int, g: Int, b: Int)) -> String {
            String(format: "#%02x%02x%02x", e.r / e.n, e.g / e.n, e.b / e.n)
        }
        if let best = buckets.values.max(by: { $0.n < $1.n }), best.n >= 8 { return hex(best) }
        return total.n > 0 ? hex(total) : nil
    }
}
