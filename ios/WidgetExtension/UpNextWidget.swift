import SwiftUI
import WidgetKit

/// The Lock Screen widget: the one save worth a glance today. A plan
/// first, then what's on its last day, then what closes or opens soonest.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpNext", provider: UpNextProvider()) { entry in
            UpNextView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("Today's plan, or what's closing or opening soon.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

/// Mirror of the app's `WidgetStore.LockEntry` — change one, change both.
struct LockItem: Codable {
    var id: UUID
    var title: String
    var place: String?
    var startsOn: String?
    var endsOn: String?
    var oneDay: Bool
    var planOn: String?
    var planTime: String?
}

struct UpNextEntry: TimelineEntry {
    let date: Date
    let pick: (item: LockItem, label: String)?
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: .now, pick: (
            LockItem(id: UUID(), title: "Anish Kapoor", place: "Hayward Gallery", oneDay: false),
            "Closes in 3 days"
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(entry(at: .now, from: Self.load()))
    }

    /// Now, then each of the next three midnights, when every label moves
    /// on a day. The app reloads the timeline whenever it writes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let items = Self.load()
        let calendar = Calendar.current
        var entries = [entry(at: .now, from: items)]
        var day = calendar.startOfDay(for: .now)
        for _ in 0..<3 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            entries.append(entry(at: next, from: items))
            day = next
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(at date: Date, from items: [LockItem]) -> UpNextEntry {
        UpNextEntry(date: date, pick: UpNext.pick(items, on: UpNext.day(date)))
    }

    static func load() -> [LockItem] {
        guard let url = Snapshot.directory?.appending(path: "lock.json"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? JSONDecoder().decode([LockItem].self, from: data)) ?? []
    }
}

enum UpNext {
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func day(_ date: Date) -> String { format.string(from: date) }

    private static func days(from: String, to: String) -> Int? {
        guard let a = format.date(from: from), let b = format.date(from: to) else { return nil }
        return Calendar.current.dateComponents([.day], from: a, to: b).day
    }

    private static func weekday(_ day: String) -> String {
        guard let date = format.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// Within a week, soonest first; nothing further out earns the spot.
    static func pick(_ items: [LockItem], on today: String) -> (item: LockItem, label: String)? {
        func plan(_ item: LockItem, _ word: String) -> String {
            item.planTime.map { "\(word) · \($0.prefix(5))" } ?? word
        }
        let planned = items.filter { $0.planOn != nil }
            .sorted { ($0.planOn ?? "", $0.planTime ?? "~") < ($1.planOn ?? "", $1.planTime ?? "~") }
        if let item = planned.first(where: { $0.planOn == today }) { return (item, plan(item, "Today")) }
        let events = items.filter { item in
            let end = item.endsOn ?? item.startsOn
            return end.map { $0 >= today } ?? false
        }
        if let item = events.first(where: { $0.oneDay && $0.startsOn == today }) { return (item, "Today") }
        if let item = events.first(where: { !$0.oneDay && $0.endsOn == today }) { return (item, "Last day") }
        if let tomorrow = nextDay(today), let item = planned.first(where: { $0.planOn == tomorrow }) {
            return (item, plan(item, "Tomorrow"))
        }

        var options: [(item: LockItem, inDays: Int, label: String)] = []
        for item in events {
            if let start = item.startsOn, start > today, let n = days(from: today, to: start), n <= 7 {
                let when = n == 1 ? "Tomorrow" : weekday(start)
                options.append((item, n, item.oneDay ? when : "Opens \(n == 1 ? "tomorrow" : when)"))
            } else if !item.oneDay, let end = item.endsOn, end > today,
                      let n = days(from: today, to: end), n <= 7 {
                options.append((item, n, n == 1 ? "Closes tomorrow" : "Closes in \(n) days"))
            }
        }
        return options.min { $0.inDays < $1.inDays }.map { ($0.item, $0.label) }
    }

    private static func nextDay(_ day: String) -> String? {
        guard let date = format.date(from: day),
              let next = Calendar.current.date(byAdding: .day, value: 1, to: date)
        else { return nil }
        return format.string(from: next)
    }

    /// "Nancy Holt" for "Nancy Holt: MoonSunStarEarthSkyWater": the
    /// one-line widget has room for the name you'd say.
    static func short(_ title: String) -> String {
        guard let colon = title.range(of: ": ") else { return title }
        let lead = title[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
        return lead.count >= 3 ? lead : title
    }
}

struct UpNextView: View {
    let entry: UpNextEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(entry.pick.map { URL(string: "canwego://item/\($0.item.id.uuidString)") } ?? URL(string: "canwego://"))
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            if let pick = entry.pick {
                Label("\(pick.label): \(UpNext.short(pick.item.title))", systemImage: "calendar")
            } else {
                Label("Nothing this week", systemImage: "calendar")
            }
        default:
            rectangular
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let pick = entry.pick {
                Label(pick.label.uppercased(), systemImage: "calendar")
                    .font(.caption2.weight(.bold))
                    .widgetAccentable()
                    .lineLimit(1)
                Text(pick.item.title)
                    .font(.headline)
                    .lineLimit(pick.item.place == nil ? 2 : 1)
                if let place = pick.item.place {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Label("CAN WE GO?", systemImage: "calendar")
                    .font(.caption2.weight(.bold))
                    .widgetAccentable()
                Text("Nothing this week")
                    .font(.headline)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
