import Foundation
import UIKit
import WidgetKit

/// Feeds the home-screen widget: a JSON snapshot of the active events plus
/// pre-shrunk photos, parked in the App Group container. Rewritten on every
/// foreground — the widget never touches the live store, it just reads
/// whatever the app last left for it.
enum WidgetStore {
    /// The JSON contract with the widget target (mirrored there as
    /// `SnapshotItem`) — change one, change both.
    private struct Entry: Codable {
        var id: UUID
        var title: String
        var subtitle: String?
        var timeLabel: String?
        var colorHex: String?
        var hasImage: Bool
    }

    private static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedInbox.groupID)?
            .appending(path: "Widget", directoryHint: .isDirectory)
    }

    /// Call on the main actor with live models; the heavy lifting (image
    /// fetch, JPEG encode, disk writes) hops off it.
    static func sync(items: [Item]) {
        // The widget shows things you could still go to.
        let active = items.filter { $0.isEvent && !$0.isDone && !$0.isMissed }
        let entries = active.map { item in
            (
                entry: Entry(
                    id: item.id,
                    title: item.title,
                    subtitle: [item.venue, item.area]
                        .compactMap(\.self)
                        .filter { $0 != item.title }
                        .joined(separator: " · ")
                        .nilIfEmpty,
                    timeLabel: item.timeLabel,
                    colorHex: item.colorHex,
                    hasImage: item.imageUrl != nil
                ),
                imageURL: item.imageUrl.flatMap(URL.init(string:))
            )
        }

        Task.detached(priority: .utility) {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // When the image pipeline changes (size, quality), bump the
            // version so every photo gets re-rendered once.
            let versionFile = directory.appending(path: "version.txt")
            let version = "2"
            if (try? String(contentsOf: versionFile, encoding: .utf8)) != version {
                let stale = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
                for file in stale where file.hasSuffix(".jpg") {
                    try? FileManager.default.removeItem(at: directory.appending(path: file))
                }
                try? version.write(to: versionFile, atomically: true, encoding: .utf8)
            }

            var written: [Entry] = []
            for (entry, imageURL) in entries {
                var entry = entry
                if let imageURL {
                    let file = directory.appending(path: "\(entry.id.uuidString).jpg")
                    if !FileManager.default.fileExists(atPath: file.path()) {
                        // Big enough for a 3x medium widget; the widget still
                        // decodes these down to its own pixel size, so disk is
                        // the only cost.
                        if let image = await ImageStore.fetch(imageURL, variant: .hero),
                           let jpeg = shrunk(image, maxSide: 1400).jpegData(compressionQuality: 0.85) {
                            try? jpeg.write(to: file, options: .atomic)
                        }
                    }
                    entry.hasImage = FileManager.default.fileExists(atPath: file.path())
                }
                written.append(entry)
            }

            if let data = try? JSONEncoder().encode(written) {
                try? data.write(to: directory.appending(path: "items.json"), options: .atomic)
            }

            // Sweep photos of items that left the rotation (done, deleted).
            let keep = Set(written.map { "\($0.id.uuidString).jpg" } + ["items.json", "version.txt"])
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
            for file in files where !keep.contains(file) {
                try? FileManager.default.removeItem(at: directory.appending(path: file))
            }

            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func shrunk(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxSide else { return image }
        let scale = maxSide / largest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
