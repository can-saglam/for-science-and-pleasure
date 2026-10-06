import SwiftUI
import WidgetKit

/// The Lock Screen's other glance: what's already on. Runs that have
/// opened and not yet closed, one an hour, the soonest to close first.
/// Same card as Up Next, so the two sit together.
struct OnNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OnNow", provider: OnNowProvider()) { entry in
            UpNextView(entry: entry, empty: "Nothing on right now")
        }
        .configurationDisplayName("On Now")
        .description("Exhibitions and runs that are on right now, a different one each hour.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

struct OnNowProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: .now, pick: (
            LockItem(id: UUID(), title: "Nancy Holt", place: "Goodwood Art Foundation", oneDay: false),
            "On now"
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(entry(at: .now, from: UpNextProvider.load()))
    }

    /// Now, then the top of each of the next six hours. Each entry works
    /// out its own day, so one past midnight moves the labels on too.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let items = UpNextProvider.load()
        let calendar = Calendar.current
        let top = calendar.dateInterval(of: .hour, for: .now)?.start ?? .now
        var entries = [entry(at: .now, from: items)]
        for hour in 1...6 {
            if let date = calendar.date(byAdding: .hour, value: hour, to: top) {
                entries.append(entry(at: date, from: items))
            }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(at date: Date, from items: [LockItem]) -> UpNextEntry {
        UpNextEntry(date: date, pick: OnNow.pick(items, at: date))
    }
}

enum OnNow {
    static func pick(_ items: [LockItem], at date: Date) -> (item: LockItem, label: String)? {
        let today = UpNext.day(date)
        // A one-day event today is Up Next's; a run with only a closing
        // date is taken to be on already.
        let on = items
            .filter { item in
                guard !item.oneDay, item.startsOn != nil || item.endsOn != nil else { return false }
                return (item.startsOn ?? today) <= today && (item.endsOn ?? today) >= today
            }
            .sorted { ($0.endsOn ?? "~", $0.title) < ($1.endsOn ?? "~", $1.title) }
        guard !on.isEmpty else { return nil }
        // Keyed to the hour itself, so a reload mid-hour shows the same one.
        let hour = Int(date.timeIntervalSince1970 / 3600)
        let item = on[hour % on.count]
        return (item, label(item, today: today))
    }

    /// Kept short: the card's top line has no room for a closing date.
    private static func label(_ item: LockItem, today: String) -> String {
        item.endsOn == today ? "Last day" : "On now"
    }
}
