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
    /// time the app woke. A week gives sites a fair second chance.
    private static let attemptsKey = "thumbnailBackfillAttempts"
    private static let retryAfter: TimeInterval = 7 * 24 * 3600

    @MainActor
    static func run(context: ModelContext) async {
        guard let all = try? context.fetch(FetchDescriptor<Item>()) else { return }
        let missing = all.filter { item in
            item.url != nil && (item.imageUrl.map(ImageStore.isDead) ?? true)
        }
        guard !missing.isEmpty else { return }

        let defaults = UserDefaults.standard
        var attempts = defaults.dictionary(forKey: attemptsKey) as? [String: Date] ?? [:]
        // Entries for items that got an image (or got deleted) fall away.
        let liveURLs = Set(missing.compactMap(\.url))
        attempts = attempts.filter { liveURLs.contains($0.key) }

        var found: [(id: UUID, image: String)] = []
        for item in missing {
            guard let raw = item.url, let url = URL(string: raw),
                  url.scheme?.hasPrefix("http") == true,
                  !isMapsLink(url)
            else { continue }
            if let tried = attempts[raw], Date.now.timeIntervalSince(tried) < retryAfter {
                continue
            }
            // The page still pointing at the dead picture counts as nothing
            // found — try again next week, not next foreground.
            if let image = await ogImage(at: url), image != item.imageUrl {
                item.imageUrl = image
                found.append((item.id, image))
                attempts.removeValue(forKey: raw)
            } else {
                attempts[raw] = .now
            }
        }
        defaults.set(attempts, forKey: attemptsKey)
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
            if let absolute = URL(string: raw, relativeTo: url)?.absoluteString,
               !isMapsBrandedImage(absolute) {
                return absolute
            }
        }
        return nil
    }
}
