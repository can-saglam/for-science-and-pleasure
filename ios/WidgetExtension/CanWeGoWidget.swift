import SwiftUI
import WidgetKit

/// The home-screen widget: one saved event at a time, photo-first, rotating
/// through the library hour by hour. Tapping it opens that event in the app.
@main
struct CanWeGoWidgets: WidgetBundle {
    var body: some Widget {
        RandomSaveWidget()
    }
}

struct RandomSaveWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RandomSave", provider: Provider()) { entry in
            RandomSaveView(entry: entry)
        }
        .configurationDisplayName("Can We Go?")
        .description("A save from your list, rotating through the day.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Snapshot (written by the app, read here)

/// Mirror of the app's `WidgetStore.Entry` — the JSON contract between the
/// two targets. Kept deliberately tiny and stable.
struct SnapshotItem: Codable, Identifiable {
    var id: UUID
    var title: String
    var subtitle: String?
    var timeLabel: String?
    var colorHex: String?
    var hasImage: Bool
}

enum Snapshot {
    static let groupID = "group.com.cansaglam.CanWeGo"

    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appending(path: "Widget", directoryHint: .isDirectory)
    }

    static func load() -> [SnapshotItem] {
        guard let url = directory?.appending(path: "items.json"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? JSONDecoder().decode([SnapshotItem].self, from: data)) ?? []
    }

    /// The pre-shrunk photo the app parked for this item, decoded small —
    /// widget extensions live under a tight memory ceiling.
    static func image(for id: UUID, maxSide: CGFloat = 700) -> UIImage? {
        guard let url = directory?.appending(path: "\(id.uuidString).jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Timeline

struct ThemeSnapshot {
    var name: String
    var isLight: Bool
    var paper: Color
    var ink: Color

    static func load() -> ThemeSnapshot {
        let url = Snapshot.directory?.appending(path: "theme.json")
        let data = url.flatMap { try? Data(contentsOf: $0) }
        let decoded = data.flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
        return named(decoded?.theme ?? "midnight")
    }

    private struct Payload: Codable {
        var theme: String
        var isLight: Bool?
    }

    private static func named(_ name: String) -> ThemeSnapshot {
        switch name {
        case "cream":
            ThemeSnapshot(name: name, isLight: true, paper: Color.fromHex("#F8F0CA") ?? .white, ink: .black)
        case "forest":
            ThemeSnapshot(name: name, isLight: false, paper: Color.fromHex("#323316") ?? .black, ink: Color.fromHex("#F6E2B6") ?? .white)
        case "wine":
            ThemeSnapshot(name: name, isLight: false, paper: Color.fromHex("#440015") ?? .black, ink: .white)
        case "ink":
            ThemeSnapshot(name: name, isLight: false, paper: .black, ink: .white)
        default:
            ThemeSnapshot(name: "midnight", isLight: false, paper: Color.fromHex("#0A107A") ?? .black, ink: Color.fromHex("#F6E2B6") ?? .white)
        }
    }
}

struct SaveEntry: TimelineEntry {
    let date: Date
    let item: SnapshotItem?
    let image: UIImage?
    let theme: ThemeSnapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SaveEntry {
        SaveEntry(
            date: .now,
            item: SnapshotItem(
                id: UUID(),
                title: "Anish Kapoor",
                subtitle: "Hayward Gallery · South Bank",
                timeLabel: "7 weeks left",
                colorHex: "#8f4a3d",
                hasImage: false
            ),
            image: nil,
            theme: ThemeSnapshot.load()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SaveEntry) -> Void) {
        completion(entry(at: .now, in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SaveEntry>) -> Void) {
        // A fresh random save every hour, four hours ahead; then WidgetKit
        // asks again. The app also reloads the timeline whenever it writes
        // a fresh snapshot.
        let calendar = Calendar.current
        let top = calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour], from: .now)
        ) ?? .now
        var entries = [entry(at: .now, in: context)]
        for hour in 1...4 {
            if let date = calendar.date(byAdding: .hour, value: hour, to: top) {
                entries.append(entry(at: date, in: context))
            }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(at date: Date, in context: Context) -> SaveEntry {
        let all = Snapshot.load()
        let theme = ThemeSnapshot.load()
        guard !all.isEmpty else { return SaveEntry(date: date, item: nil, image: nil, theme: theme) }
        // Seeded by the hour so every size of the widget shows the same
        // pick, scrambled so consecutive hours jump around the list.
        let hour = Int(date.timeIntervalSince1970 / 3600)
        let index = abs(hour &* 2654435761 % all.count)
        let item = all[index]
        // Decode at the widget's real pixel size: displaySize is in points,
        // and current iPhones are 3x displays.
        let side = max(context.displaySize.width, context.displaySize.height) * 3
        let image = item.hasImage ? Snapshot.image(for: item.id, maxSide: side) : nil
        return SaveEntry(date: date, item: item, image: image, theme: theme)
    }
}

// MARK: - View

struct RandomSaveView: View {
    let entry: SaveEntry
    @Environment(\.widgetFamily) private var family

    private var accent: Color {
        entry.item?.colorHex.flatMap(Color.fromHex) ?? Color(red: 0.35, green: 0.42, blue: 0.62)
    }

    var body: some View {
        Group {
            if let item = entry.item {
                content(item)
                    .widgetURL(URL(string: "canwego://item/\(item.id.uuidString)"))
            } else {
                empty
            }
        }
        .containerBackground(for: .widget) {
            background
        }
    }

    /// The photo runs edge to edge; without one, a deep wash of the item's
    /// color stands in, so the widget always looks dressed.
    @ViewBuilder
    private var background: some View {
        if let image = entry.image {
            Color.clear.overlay(
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            )
            .overlay(scrim)
        } else if entry.item != nil {
            LinearGradient(
                colors: [
                    accent.mix(with: entry.theme.paper, by: entry.theme.isLight ? 0.72 : 0.45),
                    accent.mix(with: entry.theme.paper, by: entry.theme.isLight ? 0.88 : 0.7),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            entry.theme.paper
        }
    }

    /// Photo-to-text handoff: clear up top, quietly dark where the words sit.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.08), location: 0),
                .init(color: .clear, location: 0.35),
                .init(color: .black.opacity(0.55), location: 0.72),
                .init(color: .black.opacity(0.82), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The small widget is tight on width, so "Happening next Thursday"
    /// sheds its first word and reads as just "next Thursday".
    private func eyebrow(_ item: SnapshotItem) -> String? {
        guard let label = item.timeLabel else { return nil }
        if family == .systemSmall, label.lowercased().hasPrefix("happening ") {
            return String(label.dropFirst("happening ".count))
        }
        return label
    }

    private func content(_ item: SnapshotItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            if let label = eyebrow(item) {
                Text(label.uppercased())
                    .font(.system(size: family == .systemSmall ? 9 : 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(typeColor.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.bottom, 4)
            }
            Text(item.title)
                .font(family == .systemSmall ? .subheadline.bold() : .title3.bold())
                .foregroundStyle(typeColor)
                .lineLimit(family == .systemLarge ? 3 : 2)
                .minimumScaleFactor(0.9)
            if family != .systemSmall, let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(typeColor.opacity(0.75))
                    .lineLimit(1)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(entry.image == nil ? 0 : 0.35), radius: 3, y: 1)
    }

    /// Photo sits on a dark scrim, so type stays white. Empty and no-photo
    /// follow the app theme — cream paper gets black ink.
    private var typeColor: Color {
        entry.image != nil ? .white : entry.theme.ink
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(entry.theme.ink.opacity(0.8))
            Text("Save something to see it here")
                .font(.caption.weight(.medium))
                .foregroundStyle(entry.theme.ink.opacity(0.75))
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Hex color

extension Color {
    /// Same parsing as the app's `Color(hex:)` — duplicated so the widget
    /// stays self-contained.
    static func fromHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
