import ImageIO
import SwiftUI

/// A save as Siri's card shows it: the library's card. Siri draws it once,
/// like a widget, so nothing can load while it's up: the photo and its
/// melt are read before the view is made.
struct SiriCardRow: Identifiable {
    let id: UUID
    let title: String
    let place: String?
    let when: String?
    let plan: String?
    let tint: Color
    let imageURL: URL?
    /// Only a save already in the library: one still in the inbox would
    /// open to "this save is gone".
    let opens: Bool
    var photo: UIImage?
    var melt: UIImage?

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
        tint = item.accentColor
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
    /// past that the card goes out plain.
    static func dressed(_ row: SiriCardRow, wait: Bool = false) async -> SiriCardRow {
        var row = row
        if row.opens, let data = WidgetStore.photo(for: row.id), let image = thumbnail(data) {
            row.photo = image
        } else if let url = row.imageURL {
            if ImageStore.cached(url) == nil, wait {
                await ImageStore.warm(url, variant: .card, limit: .seconds(2))
            }
            row.photo = ImageStore.cached(url).map(shrunk)
            row.melt = ImageStore.cachedMelt(url)
        }
        if let photo = row.photo, row.melt == nil {
            row.melt = await ImageStore.meltUnderlay(photo)
        }
        return row
    }

    /// Never waits on the network: a list answers straight away.
    static func dressed(_ items: [Item]) async -> [SiriCardRow] {
        var rows: [SiriCardRow] = []
        for item in items { rows.append(await dressed(SiriCardRow(item))) }
        return rows
    }

    /// The melt is 150 pt wide; 3× of that, and no more, goes into the card.
    private static let side: CGFloat = 450

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
        VStack(alignment: .leading, spacing: 8) {
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
/// Empty with no screen to show it on.
struct SiriSaveCard: View {
    let row: SiriCardRow?

    var body: some View {
        if let row {
            SiriRow(row: row, large: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
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

    private var radius: CGFloat { large ? 18 : 14 }
    private var background: Color { ItemCard.background(row.tint) }

    /// The list card's grey, fixed: the system one turns vibrant on Siri's
    /// glass and comes out the card's colour, brightened.
    private var label: Color {
        let traits = UITraitCollection(userInterfaceStyle: AppBackground.theme.isLight ? .light : .dark)
        return Color(uiColor: .secondaryLabel.resolvedColor(with: traits))
    }

    /// The library's card, in the app's theme whatever the system's
    /// appearance: the panel is the theme's, so its ink must be too.
    private var content: some View {
        VStack(alignment: .leading, spacing: large ? 5 : 3) {
            Text(row.title)
                .font(large ? .displaySmall(22, relativeTo: .body) : .displaySmall(18, relativeTo: .subheadline))
                .lineLimit(2)
            if let place = row.place {
                Text(place)
                    .font(large ? .subheadline : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if row.when != nil || row.plan != nil {
                HStack(spacing: 6) {
                    if let when = row.when {
                        Text(when)
                            .foregroundStyle(label)
                    }
                    if let plan = row.plan {
                        planPill(plan)
                    }
                }
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.top, 1)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, large ? 16 : 14)
        .padding(.vertical, large ? 13 : 10)
        .padding(.trailing, row.photo == nil ? 0 : 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .trailing) {
            if let photo = row.photo {
                MeltLayers(sharp: photo, blurred: row.melt ?? photo, cardBackground: background, width: 150)
                    .compositingGroup()
                    .frame(width: 150)
                    .clipped()
            }
        }
        .background(background, in: .rect(cornerRadius: radius, style: .continuous))
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(ItemCard.border(row.tint), lineWidth: 1)
        )
        .foregroundStyle(AppBackground.ink)
        .environment(\.colorScheme, AppBackground.theme.colorScheme)
        .contentShape(.rect)
    }

    private func planPill(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .imageScale(.small)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppBackground.ink.opacity(0.75))
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .padding(.vertical, 4)
        .background(AppBackground.ink.opacity(0.08), in: .capsule)
    }
}
