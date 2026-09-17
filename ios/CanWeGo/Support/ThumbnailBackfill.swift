import Foundation
import SwiftData

/// Items saved before thumbnails existed have a URL but no image. On launch
/// this quietly fetches each page's og:image and stores it — best effort,
/// no LLM involved, sites that block bots are simply skipped. A thumbnail
/// whose URL has since died (`ImageStore.isDead`) counts as missing too, so
/// a venue that reshuffles its CDN gets a fresh picture rather than a
/// permanent colour block.
enum ThumbnailBackfill {
    /// Pages that yielded nothing (bot walls, no og:image) aren't retried
    /// on every foreground — that was a fresh round of doomed requests each
    /// time the app woke. Retries back off: an hour after the first miss
    /// (many pages set their picture minutes after going live, or were
    /// simply slow), a day after the second, a week from then on.
    private static let attemptsKey = "thumbnailBackfillAttempts"
    private static let attemptCountsKey = "thumbnailBackfillAttemptCounts"

    private static func retryAfter(misses: Int) -> TimeInterval {
        switch misses {
        case ..<2: return 3600
        case 2: return 24 * 3600
        default: return 7 * 24 * 3600
        }
    }

    @MainActor
    static func run(context: ModelContext) async {
        guard let all = try? context.fetch(FetchDescriptor<Item>()) else { return }
        let missing = all.filter { item in
            item.url != nil && (item.imageUrl.map(ImageStore.isDead) ?? true)
        }
        guard !missing.isEmpty else { return }

        let defaults = UserDefaults.standard
        var attempts = defaults.dictionary(forKey: attemptsKey) as? [String: Date] ?? [:]
        var counts = defaults.dictionary(forKey: attemptCountsKey) as? [String: Int] ?? [:]
        // Entries for items that got an image (or got deleted) fall away.
        let liveURLs = Set(missing.compactMap(\.url))
        attempts = attempts.filter { liveURLs.contains($0.key) }
        counts = counts.filter { liveURLs.contains($0.key) }

        var found: [(id: UUID, image: String)] = []
        for item in missing {
            // Social posts' og:image is a signed CDN URL that expires within
            // days — never a thumbnail. Those saves get their picture from
            // the venue's own site at parse time, or stay on the colour block.
            guard let raw = item.url, let url = URL(string: raw),
                  url.scheme?.hasPrefix("http") == true,
                  !isMapsLink(url), !SocialPrefetch.isSocial(url)
            else { continue }
            let misses = counts[raw] ?? 0
            if let tried = attempts[raw], Date.now.timeIntervalSince(tried) < retryAfter(misses: misses) {
                continue
            }
            // The page still pointing at the dead picture counts as nothing
            // found — back off, rather than try again next foreground.
            if let image = await pageImage(at: url), image != item.imageUrl {
                item.imageUrl = image
                found.append((item.id, image))
                attempts.removeValue(forKey: raw)
                counts.removeValue(forKey: raw)
            } else {
                attempts[raw] = .now
                counts[raw] = misses + 1
            }
        }
        defaults.set(attempts, forKey: attemptsKey)
        defaults.set(counts, forKey: attemptCountsKey)
        guard !found.isEmpty else { return }
        try? context.save()
        // Reach the shared table as a column patch, not a full-row push:
        // this is machine work, not an edit. It must never carry the rest of
        // the row (which could overwrite a partner's fresher change) and
        // never look like a person touched the item. The server keeps
        // updated_at unchanged for image-only writes; other phones derive
        // their own thumbnail the same way, so nothing needs propagating.
        for (id, image) in found {
            await SupabaseSync.patch(id, ["image_url": image])
        }
    }

    /// Maps pages only ever offer the Google Maps app icon as their
    /// og:image — a garbage thumbnail. Skip them entirely.
    private static func isMapsLink(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if host.contains("maps.google") || host == "maps.app.goo.gl" { return true }
        if host.hasSuffix("google.com"), url.path().hasPrefix("/maps") { return true }
        if host == "goo.gl", url.path().hasPrefix("/maps") { return true }
        return false
    }

    /// The generic Google Maps app icon once poisoned saves with
    /// rainbow-streak thumbnails — never store any maps-branded asset.
    private static func isMapsBrandedImage(_ url: String) -> Bool {
        url.range(of: #"(?:gstatic|googleusercontent)\.com.*maps|maps_\d+dp\.(?:png|webp)"#,
                  options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The page's picture, by the places sites put one: Open Graph and
    /// Twitter cards first, then schema.org JSON-LD (most ticketing and
    /// venue pages carry an Event/Place with an `image`), then the old
    /// `<link rel="image_src">`.
    private static func pageImage(at url: URL) async -> String? {
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

        // og:image / twitter:image, tolerant of attribute order; then
        // JSON-LD `"image": "…"` or `"image": ["…"]` / `{"url": "…"}`;
        // then the legacy link tag.
        let patterns = [
            #"<meta[^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["']"#,
            #""image"\s*:\s*\[?\s*(?:\{[^}]*?"url"\s*:\s*)?"(https?:[^"]+)""#,
            #"<link[^>]+rel=["']image_src["'][^>]+href=["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let raw = String(html[range])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\/", with: "/")
            // Relative paths resolve against the page they came from.
            if let absolute = URL(string: raw, relativeTo: url)?.absoluteString,
               !isMapsBrandedImage(absolute) {
                return absolute
            }
        }
        return nil
    }
}
