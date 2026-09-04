import Foundation
import SwiftData
import SwiftUI

/// One saved thing — an event with a date window, or a place with none.
/// Mirrors the web app's `items` table so the two stay conceptually in sync.
///
/// CloudKit rules shape this model: every property has a default, nothing is
/// `@Attribute(.unique)`, and date-only values are stored as "yyyy-MM-dd"
/// strings (like the web) so timezones can never shift a date.
@Model
final class Item {
    var id: UUID = UUID()
    var kind: String = Item.Kind.event
    var title: String = ""
    var summary: String?
    var venue: String?
    var area: String?
    var address: String?
    var url: String?
    var imageUrl: String?
    var startsOn: String?
    var endsOn: String?
    var price: String?
    var category: String?
    var notes: String?
    var status: String = Item.Status.saved
    /// Dominant color pulled from the source page's image, as "#rrggbb".
    var colorHex: String?
    var lat: Double?
    var lng: Double?
    var addedByEmail: String?
    /// Manual position in the Places list (long-press drag). Local-only —
    /// never synced, so each of you can keep your own order.
    var sortOrder: Double?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    enum Kind {
        static let event = "event"
        static let place = "place"
    }

    enum Status {
        static let saved = "saved"
        static let done = "done"
    }

    init() {}
}

// MARK: - Date-only helpers

enum DayString {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    static func today() -> String {
        formatter.string(from: .now)
    }

    static func date(_ s: String) -> Date? {
        formatter.date(from: s)
    }

    /// Whole days from `from` to `to` (negative when `to` is in the past).
    static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let a = date(from), let b = date(to) else { return nil }
        return Calendar.current.dateComponents([.day], from: a, to: b).day
    }
}

// MARK: - Domain logic (ported from the web app's lib/api.ts)

enum TimeBucket {
    case past
    case lastChance   // closes within 7 days
    case now          // running, no imminent end
    case upcoming     // starts in the future
    case undated
}

extension Item {
    var isEvent: Bool { kind == Kind.event }
    var isPlace: Bool { kind == Kind.place }
    var isDone: Bool { status == Status.done }

    /// One-day events "happen"; ranges "open" and "close".
    var isOneDay: Bool {
        guard let s = startsOn, let e = endsOn else { return false }
        return s == e
    }

    var daysUntilStart: Int? {
        guard let s = startsOn else { return nil }
        return DayString.daysBetween(DayString.today(), s)
    }

    var daysUntilClose: Int? {
        guard let e = endsOn else { return nil }
        return DayString.daysBetween(DayString.today(), e)
    }

    var timeBucket: TimeBucket {
        if let close = daysUntilClose, close < 0 { return .past }
        if let open = daysUntilStart, open > 0 { return .upcoming }
        if let close = daysUntilClose {
            return close <= 7 ? .lastChance : .now
        }
        // Started (or undated start) with no end date: it's just on.
        return startsOn != nil ? .now : .undated
    }

    /// Ended without ever being marked done.
    var isMissed: Bool {
        !isDone && timeBucket == .past
    }

    /// Days become weeks become months once the number stops being useful —
    /// "52 days left" reads worse than "7 weeks left".
    private static func friendlySpan(_ d: Int) -> String {
        if d < 15 { return "\(d) day\(d == 1 ? "" : "s")" }
        if d < 57 {
            let w = max(2, Int((Double(d) / 7).rounded()))
            return "\(w) weeks"
        }
        let m = max(2, Int((Double(d) / 30.44).rounded()))
        return "\(m) months"
    }

    /// "today", "tomorrow", "this Saturday", "next Thursday" for anything
    /// within the current or the following calendar week; nil beyond that.
    private static func friendlyDay(_ daysAway: Int, _ day: String) -> String? {
        switch daysAway {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...13:
            guard let date = DayString.date(day) else { return nil }
            let calendar = Calendar.current
            let dow = calendar.component(.weekday, from: calendar.startOfDay(for: .now))
            let daysToSunday = (8 - dow) % 7 // 1 = Sunday
            let name = date.formatted(.dateTime.weekday(.wide))
            if daysAway <= daysToSunday { return "this \(name)" }
            if daysAway <= daysToSunday + 7 { return "next \(name)" }
            return nil
        default: return nil
        }
    }

    /// Short label for list rows, e.g. "3 days left" / "Opens next Friday".
    var timeLabel: String? {
        switch timeBucket {
        case .past:
            return "Ended"
        case .lastChance:
            guard let d = daysUntilClose else { return nil }
            // A gig has no "last day" — it just happens today.
            if d == 0 { return isOneDay ? "Today" : "Last Day" }
            return "\(d) day\(d == 1 ? "" : "s") left"
        case .now:
            if let d = daysUntilClose { return "\(Item.friendlySpan(d)) left" }
            return "On now"
        case .upcoming:
            guard let d = daysUntilStart else { return nil }
            // Near starts get the human phrasing: "Opens this Saturday"
            // beats "Opens in 2 days".
            if let s = startsOn, let day = Item.friendlyDay(d, s) {
                return isOneDay ? "Happening \(day)" : "Opens \(day)"
            }
            return isOneDay
                ? "Happening in \(Item.friendlySpan(d))"
                : "Opens in \(Item.friendlySpan(d))"
        case .undated:
            return nil
        }
    }

    /// Red when the window is about to shut — same urgency cue as the web.
    var timeLabelIsUrgent: Bool {
        if case .lastChance = timeBucket, let d = daysUntilClose, d <= 2 { return true }
        return false
    }
}

// MARK: - Accent color

extension Item {
    /// Curated fallbacks so undyed items still get stable, distinct colors.
    private static let palette: [String] = [
        "#c2703d", "#8f9e4f", "#b5525c", "#5e8ca7", "#a06d9c",
        "#c99a3c", "#659381", "#96676a", "#7a7fb0", "#ae8459",
    ]

    var accentColor: Color {
        if let hex = colorHex, let color = Color(hex: hex) { return color }
        // Stable hash of the id so the fallback never flickers between runs.
        let hash = id.uuidString.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }
        let hex = Item.palette[abs(hash) % Item.palette.count]
        return Color(hex: hex) ?? .secondary
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
