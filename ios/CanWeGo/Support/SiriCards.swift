import ImageIO
import SwiftUI

/// A save as Siri's card shows it. Siri draws the card once, like a widget,
/// so nothing can load while it's up: the photo is read before the view is
/// made, and a save without one wears its category glyph on its colour.
struct SiriCardRow: Identifiable {
    let id: UUID
    let title: String
    let place: String?
    let when: String?
    let plan: String?
    let glyph: String
    let tint: Color
    let imageURL: URL?
    /// Only a save already in the library: one still in the inbox would
    /// open to "this save is gone".
    let opens: Bool
    var photo: UIImage?

    var link: URL? {
        opens ? URL(string: "canwego://item/\(id.uuidString)") : nil
    }

    @MainActor
    init(_ item: Item) {
        id = item.id
        title = item.title
        place = Self.place(venue: item.venue, area: item.area, title: item.title)
        when = item.timeLabel
        plan = item.planPillText
        glyph = item.glyph
        tint = item.colorHex.flatMap(Color.init(hex:)) ?? Self.fallbackTint
        imageURL = item.imageUrl.flatMap(URL.init(string:))
        opens = true
    }

    /// What the parser found, before or just after it's saved.
    init(_ card: ParseClient.Card, id: UUID = UUID()) {
        self.id = id
        title = card.title
        place = Self.place(venue: card.venue, area: card.area, title: card.title)
        when = Self.days(card.starts_on, card.ends_on)
        plan = nil
        glyph = Item.glyph(kind: card.kind, category: card.category)
        tint = card.color.flatMap(Color.init(hex:)) ?? Self.fallbackTint
        imageURL = card.image_url.flatMap(URL.init(string:))
        opens = false
    }

    private static let fallbackTint = Color(red: 0.35, green: 0.42, blue: 0.62)

    private static func place(venue: String?, area: String?, title: String) -> String? {
        let parts = [venue, area].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != title }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2–11 Oct 2026", or the one day.
    private static func days(_ start: String?, _ end: String?) -> String? {
        if let start, let end, start != end, let range = DayString.text(from: start, to: end) { return range }
        return (start ?? end).flatMap { DayString.text($0, .dateTime.day().month(.abbreviated).year()) }
    }
}

@MainActor
enum SiriCards {
    /// The widget's copy of the photo when there is one: every upcoming
    /// event has it on disk. Otherwise whatever the app already holds,
    /// and only with `wait` the network too, for two seconds at most —
    /// past that the card goes out with its glyph.
    static func dressed(_ row: SiriCardRow, wait: Bool = false) async -> SiriCardRow {
        var row = row
        if row.opens, let data = WidgetStore.photo(for: row.id), let image = thumbnail(data) {
            row.photo = image
            return row
        }
        guard let url = row.imageURL else { return row }
        if ImageStore.cached(url) == nil, wait {
            await ImageStore.warm(url, variant: .card, limit: .seconds(2))
        }
        row.photo = ImageStore.cached(url).map(shrunk)
        return row
    }

    /// Never waits on the network: a list answers straight away.
    static func dressed(_ items: [Item]) async -> [SiriCardRow] {
        var rows: [SiriCardRow] = []
        for item in items { rows.append(await dressed(SiriCardRow(item))) }
        return rows
    }

    /// Drawn at most 72 pt; 3× of that, and no more, goes into the card.
    private static let side: CGFloat = 216

    private static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }

    private static func shrunk(_ image: UIImage) -> UIImage {
        let pixels = max(image.size.width, image.size.height) * image.scale
        guard pixels > side else { return image }
        let ratio = side / pixels
        let size = CGSize(width: image.size.width * image.scale * ratio, height: image.size.height * image.scale * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// "What's on": the first four, each opening its save, then how many more.
struct SiriSavesCard: View {
    let rows: [SiriCardRow]
    let more: Int

    static let shown = 4

    /// `total` counts every save the answer has, beyond the rows dressed.
    init(rows: [SiriCardRow], total: Int) {
        self.rows = Array(rows.prefix(Self.shown))
        more = max(0, total - self.rows.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                SiriRow(row: row, large: false)
            }
            if more > 0 {
                Text("\(more) more in Can We Go")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// The one save an add is about: what was found, or what's already there.
struct SiriSaveCard: View {
    let row: SiriCardRow

    var body: some View {
        SiriRow(row: row, large: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }
}

private struct SiriRow: View {
    let row: SiriCardRow
    let large: Bool

    var body: some View {
        if let link = row.link {
            Link(destination: link) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var side: CGFloat { large ? 72 : 52 }

    private var content: some View {
        HStack(spacing: 12) {
            thumb
                .frame(width: side, height: side)
                .clipShape(.rect(cornerRadius: side * 0.22, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(large ? .title3.weight(.semibold) : .headline)
                    .foregroundStyle(.primary)
                    .lineLimit(large ? 3 : 2)
                if let place = row.place {
                    Text(place)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if row.when != nil || row.plan != nil {
                    HStack(spacing: 6) {
                        if let when = row.when {
                            Text(when)
                                .foregroundStyle(.secondary)
                        }
                        if let plan = row.plan {
                            Label(plan, systemImage: "calendar")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: .capsule)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var thumb: some View {
        if let photo = row.photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                // Deepened so the white glyph holds on a pale colour.
                Rectangle().fill(row.tint.mix(with: .black, by: 0.3).gradient)
                Image(systemName: row.glyph)
                    .font(.system(size: side * 0.38, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}
