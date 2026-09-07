import Foundation
import UIKit

/// Layer two for Instagram / TikTok / Facebook links. The server tries the
/// platform's public endpoints first, but a datacenter IP is sometimes shown
/// the login wall; this phone — a residential IP, a mobile Safari UA —
/// usually isn't. So before a social link goes to the parser, fetch the
/// post's own `og:` tags here and send the caption and cover along with it.
/// A screenshot already arrives in exactly that shape, so the parser needs
/// nothing new. Best effort, a few seconds at most; silence on failure.
enum SocialPrefetch {
    private static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func isSocial(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host.hasSuffix("instagram.com") || host.hasSuffix("tiktok.com")
            || host.hasSuffix("facebook.com") || host == "fb.watch"
    }

    /// Returns the input with the caption appended and the cover attached
    /// (unless the user attached their own picture). Unchanged when the
    /// link isn't social or nothing could be read.
    static func enrich(text: String?, imageJPEG: Data?) async -> (text: String?, imageJPEG: Data?) {
        guard let text, let url = firstURL(in: text), isSocial(url) else {
            return (text, imageJPEG)
        }
        guard let html = await fetchHTML(url) else { return (text, imageJPEG) }
        let caption = meta("og:description", in: html).flatMap(stripInstagramPrefix)
        let cover = meta("og:image", in: html).flatMap(URL.init(string:))

        var outText = text
        if let caption, !caption.isEmpty, !text.contains(caption) {
            outText += "\n\nCaption: \(caption)"
        }
        var outImage = imageJPEG
        if outImage == nil, let cover, isRealCover(cover) {
            outImage = await fetchJPEG(cover)
        }
        return (outText, outImage)
    }

    private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url
    }

    private static func fetchHTML(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
        else { return nil }
        return String(data: data.prefix(400_000), encoding: .utf8)
    }

    /// One `<meta property=… content=…>` value, attribute order agnostic,
    /// entities decoded.
    private static func meta(_ property: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            #"<meta[^>]+(?:property|name)=["']"# + escaped + #"["'][^>]+content=["']([^"']*)["']"#,
            #"<meta[^>]+content=["']([^"']*)["'][^>]+(?:property|name)=["']"# + escaped + #"["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            return decodeEntities(String(html[range]))
        }
        return nil
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        if let regex = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);|&#(\d+);"#) {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed()
            for m in matches {
                guard let whole = Range(m.range, in: out) else { continue }
                let scalar: UInt32?
                if let hex = Range(m.range(at: 1), in: out) {
                    scalar = UInt32(out[hex], radix: 16)
                } else if let dec = Range(m.range(at: 2), in: out) {
                    scalar = UInt32(out[dec])
                } else {
                    scalar = nil
                }
                if let scalar, let u = Unicode.Scalar(scalar) {
                    out.replaceSubrange(whole, with: String(Character(u)))
                }
            }
        }
        return out
    }

    /// `3,886 likes, 22 comments - dezeen on July 3, 2026: "caption"` → the
    /// caption. A profile page's "N Followers, …" line is no caption at all.
    private static func stripInstagramPrefix(_ description: String) -> String? {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^\d[\d,.]*[KM]?\s+Followers,"#, options: .regularExpression) != nil {
            return nil
        }
        let pattern = #"^.*?\s-\s\S+\s+on\s+[A-Z][a-z]+\s+\d{1,2},\s+\d{4}:\s*["“]([\s\S]*)["”]\s*$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// The login wall's og:image is the platform's own logo — skip anything
    /// not served from a content CDN.
    private static func isRealCover(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return host.contains("cdninstagram") || host.contains("fbcdn") || host.contains("tiktokcdn")
    }

    private static func fetchJPEG(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              data.count < 6_000_000,
              let image = UIImage(data: data)
        else { return nil }
        return image.compressedForUpload()
    }
}
