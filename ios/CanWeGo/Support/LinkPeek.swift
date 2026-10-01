import LinkPresentation
import UIKit

/// The phone's own look at a link — the page's title and picture, the
/// preview Messages draws — so the capture drawer has something real to
/// show in the second or so before the parser's card lands. Never saved:
/// the card replaces it, and anything that looks like a login wall, a
/// bare site name or a logo is dropped rather than shown.
struct LinkPeek {
    var title: String?
    var image: UIImage?

    /// Hosts whose previews are a sign-in page or a logo for anyone not
    /// logged in in Safari — never worth showing.
    private static let walled = [
        "instagram.com", "tiktok.com", "facebook.com", "fb.me", "threads.net",
        "x.com", "twitter.com", "t.co",
    ]

    /// Google Maps links keep their title (the place's name) but never
    /// their picture: Maps photos are the parser's last resort, not ours.
    private static let maps = ["maps.app.goo.gl", "goo.gl", "maps.google.com"]

    private static let junkTitles = [
        "log in", "login", "sign in", "sign up", "just a moment", "access denied",
        "attention required", "page not found", "not found", "error", "forbidden",
        "what's on", "whats on", "home", "homepage", "welcome", "events", "tickets",
    ]

    /// The first web link in what was typed or shared.
    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url.flatMap {
            $0.scheme?.hasPrefix("http") == true ? $0 : nil
        }
    }

    /// Nil for a link that isn't worth a look, or when nothing usable came
    /// back within the timeout. Cancelling the task stops the fetch.
    @MainActor
    static func fetch(_ url: URL, timeout: TimeInterval = 5) async -> LinkPeek? {
        guard let host = url.host()?.lowercased(), url.scheme?.hasPrefix("http") == true else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if walled.contains(where: { bare == $0 || bare.hasSuffix("." + $0) }) { return nil }
        let isMaps = maps.contains(bare) || (bare.hasPrefix("google.") && url.path().hasPrefix("/maps"))

        let provider = LPMetadataProvider()
        provider.timeout = timeout
        let metadata: LPLinkMetadata
        do {
            metadata = try await withTaskCancellationHandler {
                try await provider.startFetchingMetadata(for: url)
            } onCancel: {
                provider.cancel()
            }
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let title = metadata.title.flatMap { tidy($0, host: bare) }
        var image: UIImage?
        if !isMaps, let provider = metadata.imageProvider {
            image = await load(provider)
        }
        guard !Task.isCancelled, title != nil || image != nil else { return nil }
        return LinkPeek(title: title, image: image)
    }

    /// "Dishoom | Indian Restaurant In King's Cross | North London" →
    /// "Dishoom", "Anish Kapoor – Lisson Gallery" → "Anish Kapoor": pages
    /// lead with the thing itself. Nil for a title that's only the site's
    /// own name, a section ("What's on") or an error/login page.
    static func tidy(_ raw: String, host: String) -> String? {
        let squash = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        // The registrable name: "eventbrite" for www.eventbrite.co.uk.
        let labels = host.split(separator: ".").map(String.init)
        let site = labels.reversed().first { $0.count > 3 && !["co", "com", "org", "net"].contains($0) }
            ?? labels.first ?? host
        let isSite = { (s: String) in squash(s) == site }

        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSite(title) { return nil }
        for separator in [" | ", " · ", " :: "] {
            if let range = title.range(of: separator) {
                title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        // A dash is often part of the name itself; only a site name after
        // one is dropped.
        for separator in [" — ", " – ", " - "] {
            if let range = title.range(of: separator, options: .backwards),
               isSite(String(title[range.upperBound...])) {
                title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard squash(title).count >= 3 else { return nil }
        let lower = title.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…!").union(.whitespaces))
        if junkTitles.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) { return nil }
        return title
    }

    /// The page's picture, if it's big enough to be a photo rather than a
    /// logo, scaled down to what a full-width header needs.
    private static func load(_ provider: NSItemProvider) async -> UIImage? {
        let object: UIImage? = await withCheckedContinuation { cont in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                cont.resume(returning: object as? UIImage)
            }
        }
        guard let object else { return nil }
        let pixels = CGSize(width: object.size.width * object.scale, height: object.size.height * object.scale)
        let short = min(pixels.width, pixels.height), long = max(pixels.width, pixels.height)
        guard short >= 300, long / short <= 3 else { return nil }
        let ratio = min(1, 1200 / long)
        guard ratio < 1 else { return object }
        return await object.byPreparingThumbnail(ofSize: CGSize(width: pixels.width * ratio, height: pixels.height * ratio))
    }
}
