import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI

/// Disk-backed image cache in the App Group container, shared by the app
/// and the share extension. Every image downloads once; afterwards it loads
/// straight from disk on fresh launches — and keeps working offline.
///
/// In memory, images live in two tiers: `.card` (small, what the lists
/// draw) and `.hero` (full-size, decoded only when a detail sheet opens).
/// Decoding everything at hero size once put the whole library's pixels in
/// RAM at once — hundreds of MB the system answered with background kills,
/// which meant more cold launches.
enum ImageStore {
    /// How big the decoded pixels need to be for where they're drawn.
    enum Variant: String {
        /// List cards and small thumbs (~150 pt at 3×, with headroom).
        case card
        /// The detail sheet's full-width header.
        case hero

        var maxSide: CGFloat {
            switch self {
            case .card: 600
            case .hero: 1200
            }
        }
    }

    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Decoded pixels are accounted at 4 bytes each (see `store`), so
        // this is a real ~120 MB ceiling instead of an unbounded cache.
        cache.totalCostLimit = 120_000_000
        return cache
    }()

    private static let dir: URL = {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedInbox.groupID)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "ImageCache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Stable file name per URL — content-addressed by the URL string.
    /// Disk keeps one original per URL; the variants only differ in memory.
    private static func file(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return dir.appending(path: hash)
    }

    private static func key(_ url: URL, _ variant: Variant) -> NSString {
        "\(url.absoluteString)|\(variant.rawValue)" as NSString
    }

    private static func store(_ image: UIImage, key: NSString) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(image, forKey: key, cost: cost)
    }

    /// Memory hit only, synchronously. Deliberately never touches the disk:
    /// this runs in view inits on the main thread, and a disk read plus a
    /// JPEG decode there is exactly the cold-launch stutter we had. `prewarm`
    /// is what makes these hits land on cold launches.
    static func cached(_ url: URL, variant: Variant = .card) -> UIImage? {
        memory.object(forKey: key(url, variant))
    }

    /// The pre-blurred companion for the card melt, memory-only.
    static func cachedMelt(_ url: URL) -> UIImage? {
        memory.object(forKey: "\(url.absoluteString)|melt" as NSString)
    }

    /// Bulk-loads disk images into memory off the main thread, sequentially,
    /// so cards born moments later get synchronous memory hits — the calm of
    /// the old blocking reads without ever touching the main thread. Called
    /// at launch (and after syncs) with the first screenful the lists show;
    /// everything further down loads lazily as it scrolls in.
    static func prewarm(_ urls: [URL]) {
        Task.detached(priority: .userInitiated) {
            for url in urls {
                guard cached(url) == nil else { continue }
                guard let data = try? Data(contentsOf: file(for: url)),
                      let image = await decoded(data, maxSide: Variant.card.maxSide)
                else { continue }
                store(image, key: key(url, .card))
                // The melt underlay bakes here too, so the first cards
                // arrive whole instead of sharpening-then-blurring.
                if let blurred = melted(image) {
                    store(blurred, key: "\(url.absoluteString)|melt" as NSString)
                }
            }
        }
    }

    /// Cache-first fetch; disk and network misses resolve off the main
    /// thread, and every image lands in memory already decoded and scaled
    /// to its tier.
    static func fetch(_ url: URL, variant: Variant = .card) async -> UIImage? {
        if let hit = cached(url, variant: variant) { return hit }
        _ = pruneOnce
        // Detached on purpose: `.task` on a view inherits the MainActor, so
        // without the hop even "async" disk reads and decodes run on main.
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let data = try? Data(contentsOf: file(for: url)) {
                return await decoded(data, maxSide: variant.maxSide)
            }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? true,
                  let image = await decoded(data, maxSide: variant.maxSide)
            else { return nil }
            try? data.write(to: file(for: url), options: .atomic)
            return image
        }.value
        if let image {
            store(image, key: key(url, variant))
        }
        return image
    }

    /// The card image and its pre-blurred melt underlay, together. Baking
    /// the blur once here (instead of a live `.blur` on every card) takes
    /// the heaviest per-frame GPU pass out of scrolling entirely.
    static func meltPair(_ url: URL) async -> (sharp: UIImage, blurred: UIImage)? {
        guard let sharp = await fetch(url, variant: .card) else { return nil }
        if let blurred = cachedMelt(url) { return (sharp, blurred) }
        let blurred = await Task.detached(priority: .userInitiated) {
            melted(sharp)
        }.value
        guard let blurred else { return (sharp, sharp) }
        store(blurred, key: "\(url.absoluteString)|melt" as NSString)
        return (sharp, blurred)
    }

    /// Gaussian-blurred copy for the melt underlay, computed once per image.
    /// Matches the old live `.blur(radius: 10, opaque: true)` look: radius
    /// scales with the image so the softness is the same at any size.
    private static func melted(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        // Cards draw ~150 pt wide from this image: 10 pt of display blur is
        // radius ≈ 10 × (imageWidth / 150) in image pixels.
        let radius = 10 * input.extent.width / 150
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let rendered = meltContext.createCGImage(output, from: input.extent)
        else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }

    private static let meltContext = CIContext(options: [.cacheIntermediates: false])

    /// Decode fully (no lazy decompression at render time) and cap the
    /// pixel size to the tier: og:images are routinely 2000 px wide but a
    /// card draws ~450 px of them.
    private static func decoded(_ data: Data, maxSide: CGFloat) async -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let largest = max(image.size.width, image.size.height) * image.scale
        guard largest > maxSide else {
            return await image.byPreparingForDisplay() ?? image
        }
        let factor = maxSide / largest
        let target = CGSize(
            width: image.size.width * image.scale * factor,
            height: image.size.height * image.scale * factor
        )
        return await image.byPreparingThumbnail(ofSize: target) ?? image
    }

    /// One light prune per launch: once the cache passes ~200 MB, the
    /// least-recently-touched files go until it's back under half that.
    private static let pruneOnce: Void = {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
            var entries = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
            var total = entries.reduce(0) { $0 + $1.size }
            guard total > 200_000_000 else { return }
            entries.sort { $0.date < $1.date }
            for entry in entries where total > 100_000_000 {
                try? fm.removeItem(at: entry.url)
                total -= entry.size
            }
        }
    }()
}

/// Which state a `CachedImage` is in — mirrors `AsyncImage`'s phases so
/// call sites read the same.
enum CachedImagePhase {
    case empty
    case success(Image)
    case failure
}

/// Drop-in replacement for `AsyncImage`, backed by `ImageStore`. Anything
/// in memory renders immediately; disk hits arrive a beat later without
/// ever blocking the main thread — and keep working offline.
struct CachedImage<Content: View>: View {
    let url: URL
    var variant: ImageStore.Variant = .card
    @ViewBuilder let content: (CachedImagePhase) -> Content

    @State private var phase: CachedImagePhase
    /// Which URL `phase` belongs to — rows get recycled with new URLs.
    @State private var loaded: URL?

    init(
        url: URL,
        variant: ImageStore.Variant = .card,
        @ViewBuilder content: @escaping (CachedImagePhase) -> Content
    ) {
        self.url = url
        self.variant = variant
        self.content = content
        // Memory only — a disk read in a view init stalls the main thread.
        if let hit = ImageStore.cached(url, variant: variant) {
            _phase = State(initialValue: .success(Image(uiImage: hit)))
            _loaded = State(initialValue: url)
        } else {
            _phase = State(initialValue: .empty)
            _loaded = State(initialValue: nil)
        }
    }

    var body: some View {
        // The ZStack matters: callers may render EmptyView for the empty
        // phase, and SwiftUI never runs .task on an EmptyView — the fetch
        // would silently never start.
        ZStack {
            content(phase)
        }
        .task(id: url) {
            // Never re-assign a phase that's already right: every write here
            // re-renders the card (and its whole gradient melt), and rows
            // re-run this task each time scrolling brings them back.
            guard loaded != url else { return }
            if let image = await ImageStore.fetch(url, variant: variant) {
                phase = .success(Image(uiImage: image))
                loaded = url
            } else if loaded == nil {
                phase = .failure
            }
        }
    }
}
