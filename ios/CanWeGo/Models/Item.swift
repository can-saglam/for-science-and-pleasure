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
    /// Which shared library this belongs to (launch plan, Phase 1a). Set by
    /// the server on first insert; the client only carries it back.
    var groupId: UUID?
    /// Who last made a *human* edit — stamped server-side from the JWT, so
    /// a backfill or thumbnail write never changes it.
    var updatedBy: UUID?
    /// Who saved it — stamped server-side from the JWT (Phase 1b). Replaces
    /// addedByEmail as the source for "Added by"; the email stays for old rows.
    var createdBy: UUID?
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

/// Date-only arithmetic on the *home* clock. Saved dates are plain
/// YYYY-MM-DD strings; "today", and so every "3 days left" / "Last Day" /
/// This Week judgement, is measured in the group's home timezone rather than
/// the phone's, so the shared library reads identically for every member
/// wherever they are. HomeStore sets the zone on launch and after each pull.
enum DayString {
    /// The home timezone; London until HomeStore says otherwise.
    /// Written on the main actor only (HomeStore), read anywhere.
    nonisolated(unsafe) private(set) static var timeZone: TimeZone = TimeZone(identifier: "Europe/London")!

    nonisolated(unsafe) private(set) static var calendar: Calendar = homeCalendar(timeZone)

    nonisolated(unsafe) private(set) static var formatter: DateFormatter = homeFormatter(timeZone)

    static func use(timeZone zone: TimeZone) {
        guard zone != timeZone else { return }
        timeZone = zone
        calendar = homeCalendar(zone)
        formatter = homeFormatter(zone)
    }

    private static func homeCalendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    private static func homeFormatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    static func today() -> String {
        formatter.string(from: .now)
    }

    /// Midnight of `s` on the home clock.
    static func date(_ s: String) -> Date? {
        formatter.date(from: s)
    }

    /// Whole days from `from` to `to` (negative when `to` is in the past).
    static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let a = date(from), let b = date(to) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    /// A saved day as text: rendered in the home zone (so a home midnight
    /// never shows as the evening before when you're west of home) and in
    /// the device locale ("Sun 30 Aug" here, "Sun, Aug 30" there).
    static func text(_ day: String, _ style: Date.FormatStyle = .dateTime.day().month(.abbreviated)) -> String? {
        guard let d = date(day) else { return nil }
        var style = style
        style.timeZone = timeZone
        return d.formatted(style)
    }

    /// Same, for the system date styles ("30 Aug 2026").
    static func text(_ day: String, date dateStyle: Date.FormatStyle.DateStyle) -> String? {
        text(day, Date.FormatStyle(date: dateStyle, time: .omitted))
    }

    /// Sunday of the current home week, as a day string. "This week" means
    /// through Sunday, not a rolling seven days.
    static func endOfThisWeek() -> String {
        let today = calendar.startOfDay(for: .now)
        let dow = calendar.component(.weekday, from: today) // 1 = Sunday
        let sunday = calendar.date(byAdding: .day, value: (8 - dow) % 7, to: today)!
        return formatter.string(from: sunday)
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

    /// The SF Symbol that stands for this save on the map and in list
    /// headers. Chosen by what the thing *is*, not which tab it lives on —
    /// a sculpture park saved as a place gets a palette, not a fork, so the
    /// Places tab reads as "everywhere we want to go", not "where we eat".
    var glyph: String {
        Self.glyph(kind: kind, category: category)
    }

    /// Chip text for a category: the stored word, capitalised, with the one
    /// accent the parser's ASCII vocabulary can't carry.
    static func categoryLabel(_ category: String) -> String {
        switch category.trimmingCharacters(in: .whitespaces).lowercased() {
        case "cafe": return "Café"
        default: return category.capitalized
        }
    }

    static func glyph(kind: String, category: String?) -> String {
        switch category?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "restaurant": return "fork.knife"
        case "cafe": return "cup.and.saucer"
        case "drink": return "wineglass"
        case "gallery", "exhibition": return "paintpalette"
        case "museum": return "building.columns"
        case "park", "outdoors": return "leaf"
        case "shop", "market": return "bag"
        case "gig": return "music.note"
        case "theatre": return "theatermasks"
        case "film": return "film"
        case "talk": return "bubble.left.and.bubble.right"
        case "workshop": return "hammer"
        case "festival": return "sparkles"
        default: return kind == Kind.place ? "mappin" : "ticket"
        }
    }

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
            // Which weekday "today" is depends on the home clock too.
            let calendar = DayString.calendar
            let dow = calendar.component(.weekday, from: calendar.startOfDay(for: .now))
            let daysToSunday = (8 - dow) % 7 // 1 = Sunday
            let name = DayString.text(day, .dateTime.weekday(.wide)) ?? date.formatted(.dateTime.weekday(.wide))
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
