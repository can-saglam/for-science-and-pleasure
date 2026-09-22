import Foundation
import os
import SwiftData
import SwiftUI

/// One saved thing — an event with a date window, or a place with none.
/// Mirrors the web app's `items` table so the two stay conceptually in sync.
///
/// Shaped by the CloudKit rules it once had to meet (and there's no reason
/// to loosen them): every property has a default, nothing is
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
    /// How it came in: `link`, `text` or `image` from the parser, `manual`
    /// for the hand-typed form, `shortcut` from the Shortcut. Nil on rows
    /// that predate the field, which the server treats as `manual`.
    var source: String?
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
    /// Days before the anchor to fire a shared reminder: 7, 3, 1, or 0
    /// (morning of). Nil means no reminder. Always travels with
    /// `reminderAnchor` and `remindAt`. A hand-picked reminder stores 0.
    var reminderOffsetDays: Int?
    /// `starts_on` or `ends_on` — which date the offset is measured from —
    /// or `custom` when the day and time were picked by hand.
    var reminderAnchor: String?
    /// Computed fire day (`yyyy-MM-dd`) on the home calendar. The server
    /// cron sends at 10:00 that morning unless `remindTime` says otherwise.
    var remindAt: String?
    /// Hand-picked fire time (`HH:mm`, home clock). Only with the `custom`
    /// anchor; nil for the presets, which always go out at 10:00.
    var remindTime: String?
    /// Manual position in the Places list (long-press drag). Local-only —
    /// never synced, so each of you can keep your own order.
    var sortOrder: Double?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    /// Soft delete — hidden in the UI, pushed as `deleted_at`, kept so a
    /// newer local edit can still win over an older remote tombstone.
    var deletedAt: Date?

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
        cache.withLock { $0 = Cache() }
    }

    /// The lists sort and bucket every card by these on each redraw, so
    /// they must stay cheap: a `DateFormatter` round trip is ~80 µs, and
    /// thousands of them per redraw stalled scrolling. Day differences are
    /// arithmetic on the civil date, "today" is worked out once per home
    /// day, and parsed midnights are remembered per string.
    private struct Cache {
        var today: (string: String, day: Int, weekEnd: String, until: Date)?
        var midnights: [String: Date] = [:]
    }

    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// Days since 1970-01-01 for a strict `yyyy-MM-dd`, without a
    /// formatter. Nil for anything else.
    static func dayNumber(_ s: String) -> Int? {
        let u = Array(s.utf8)
        guard u.count == 10, u[4] == 45, u[7] == 45 else { return nil }
        func digits(_ r: Range<Int>) -> Int? {
            var n = 0
            for i in r {
                let d = Int(u[i]) - 48
                guard (0...9).contains(d) else { return nil }
                n = n * 10 + d
            }
            return n
        }
        guard let y = digits(0..<4), let m = digits(5..<7), let d = digits(8..<10),
              (1...12).contains(m), d >= 1, d <= daysIn(month: m, year: y)
        else { return nil }
        // Howard Hinnant's days_from_civil.
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func daysIn(month m: Int, year y: Int) -> Int {
        switch m {
        case 2: (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    private static func currentDay() -> (string: String, day: Int, weekEnd: String) {
        let now = Date.now
        if let hit = cache.withLock({ $0.today }), now < hit.until {
            return (hit.string, hit.day, hit.weekEnd)
        }
        let string = formatter.string(from: now)
        let midnight = calendar.startOfDay(for: now)
        let until = calendar.date(byAdding: .day, value: 1, to: midnight) ?? now.addingTimeInterval(60)
        let dow = calendar.component(.weekday, from: midnight) // 1 = Sunday
        let sunday = calendar.date(byAdding: .day, value: (8 - dow) % 7, to: midnight) ?? midnight
        let weekEnd = formatter.string(from: sunday)
        let day = dayNumber(string) ?? 0
        cache.withLock { $0.today = (string, day, weekEnd, until) }
        return (string, day, weekEnd)
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
        currentDay().string
    }

    /// Midnight of `s` on the home clock.
    static func date(_ s: String) -> Date? {
        if let hit = cache.withLock({ $0.midnights[s] }) { return hit }
        guard let parsed = formatter.date(from: s) else { return nil }
        cache.withLock { $0.midnights[s] = parsed }
        return parsed
    }

    /// Whole days from `from` to `to` (negative when `to` is in the past).
    static func daysBetween(_ from: String, _ to: String) -> Int? {
        if let a = dayNumber(from), let b = dayNumber(to) { return b - a }
        guard let a = date(from), let b = date(to) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    /// Whole days from today to `day`: the hot path behind every card's
    /// bucket and label.
    static func daysFromToday(_ day: String) -> Int? {
        if let b = dayNumber(day) { return b - currentDay().day }
        return daysBetween(today(), day)
    }

    /// `day` shifted by `days` on the home calendar.
    static func addingDays(_ days: Int, to day: String) -> String? {
        guard let date = date(day),
              let shifted = calendar.date(byAdding: .day, value: days, to: date)
        else { return nil }
        return formatter.string(from: shifted)
    }

    /// A fire day is still bookable: later than today, or today before 11:00
    /// home time (the 10:00 send window hasn't closed).
    static func isMorningOpen(for day: String) -> Bool {
        let today = Self.today()
        if day > today { return true }
        if day < today { return false }
        return calendar.component(.hour, from: .now) < 11
    }

    /// `HH:mm` on the home clock for an instant.
    static func time(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Splits an instant into a home-clock day string and `HH:mm`.
    static func dayAndTime(_ date: Date) -> (day: String, time: String) {
        (formatter.string(from: date), time(date))
    }

    /// The instant a `day` + `HH:mm` pair names on the home clock.
    static func instant(day: String, time: String) -> Date? {
        guard let midnight = self.date(day) else { return nil }
        let bits = time.split(separator: ":").compactMap { Int($0) }
        guard bits.count >= 2 else { return nil }
        return calendar.date(bySettingHour: bits[0], minute: bits[1], second: 0, of: midnight)
    }

    /// A day + time as text in the home zone and the device locale
    /// ("Sat 20 Sep, 18:30").
    static func text(day: String, time: String) -> String? {
        guard let d = instant(day: day, time: time) else { return nil }
        var style: Date.FormatStyle = .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        style.timeZone = timeZone
        return d.formatted(style)
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
        currentDay().weekEnd
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
        return DayString.daysFromToday(s)
    }

    var daysUntilClose: Int? {
        guard let e = endsOn else { return nil }
        return DayString.daysFromToday(e)
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

// MARK: - Shared reminder

struct ReminderChoice: Hashable, Identifiable {
    var offsetDays: Int
    var anchor: String

    var id: String { "\(anchor)-\(offsetDays)" }

    var offsetLabel: String {
        switch offsetDays {
        case 7: return "1 week before"
        case 3: return "3 days before"
        case 1: return "1 day before"
        case 0: return "Morning of"
        default: return "\(offsetDays) days before"
        }
    }

    var valueLabel: String {
        let side = anchor == "ends_on" ? "it closes" : "it starts"
        switch offsetDays {
        case 7: return "1 week before \(side)"
        case 3: return "3 days before \(side)"
        case 1: return "1 day before \(side)"
        case 0: return "Morning of"
        default: return offsetLabel
        }
    }
}

extension Item {
    static let reminderOffsets = [7, 3, 1, 0]
    /// Anchor for a hand-picked day and time.
    static let customReminderAnchor = "custom"

    var hasReminder: Bool { reminderOffsetDays != nil && remindAt != nil }

    /// A hand-picked day and time rather than one of the date presets.
    var hasCustomReminder: Bool {
        hasReminder && reminderAnchor == Self.customReminderAnchor && remindTime != nil
    }

    /// The instant a hand-picked reminder fires, on the home clock.
    var customReminderDate: Date? {
        guard hasCustomReminder, let day = remindAt, let time = remindTime else { return nil }
        return DayString.instant(day: day, time: time)
    }

    /// Where the picker opens: the reminder already set, or the next
    /// round hour at least an hour from now.
    var suggestedCustomReminderDate: Date {
        if let customReminderDate, customReminderDate > .now { return customReminderDate }
        let cal = DayString.calendar
        let inAnHour = Date.now.addingTimeInterval(3600)
        return cal.date(bySetting: .minute, value: 0, of: inAnHour) ?? inAnHour
    }

    /// Both dates exist and they differ — the menu offers start and close.
    var asksReminderAnchor: Bool {
        guard let s = startsOn, let e = endsOn else { return false }
        return s != e
    }

    private var soleReminderAnchor: String? {
        if let s = startsOn, let e = endsOn, s == e { return "starts_on" }
        if startsOn != nil, endsOn == nil { return "starts_on" }
        if endsOn != nil, startsOn == nil { return "ends_on" }
        return nil
    }

    func remindAt(offset: Int, anchor: String) -> String? {
        let day: String? = switch anchor {
        case "starts_on": startsOn
        case "ends_on": endsOn
        default: nil
        }
        guard let day else { return nil }
        return DayString.addingDays(-offset, to: day)
    }

    var availableReminderChoices: [ReminderChoice] {
        let anchors: [String]
        if asksReminderAnchor {
            anchors = ["starts_on", "ends_on"]
        } else if let sole = soleReminderAnchor {
            anchors = [sole]
        } else {
            return []
        }
        return anchors.flatMap { anchor in
            Self.reminderOffsets.compactMap { offset -> ReminderChoice? in
                guard let fire = remindAt(offset: offset, anchor: anchor),
                      DayString.isMorningOpen(for: fire)
                else { return nil }
                return ReminderChoice(offsetDays: offset, anchor: anchor)
            }
        }
    }

    /// Anything still ahead can take a hand-picked day and time; dated
    /// saves also get the presets. An event that has already ended has
    /// nothing left to be reminded of.
    var canRemind: Bool { !isDone && timeBucket != .past }

    var reminderValueLabel: String {
        guard let offset = reminderOffsetDays, let anchor = reminderAnchor else {
            return "Off"
        }
        if anchor == Self.customReminderAnchor {
            guard let day = remindAt, let time = remindTime,
                  let text = DayString.text(day: day, time: time)
            else { return "Off" }
            return text
        }
        let choice = ReminderChoice(offsetDays: offset, anchor: anchor)
        return asksReminderAnchor ? choice.valueLabel : choice.offsetLabel
    }

    func applyReminder(offset: Int, anchor: String) {
        guard let fire = remindAt(offset: offset, anchor: anchor),
              DayString.isMorningOpen(for: fire)
        else {
            clearReminder()
            return
        }
        reminderOffsetDays = offset
        reminderAnchor = anchor
        remindAt = fire
        remindTime = nil
    }

    /// A hand-picked instant. Minutes are kept; seconds dropped. Anything
    /// already past is refused and the reminder cleared.
    func applyCustomReminder(at date: Date) {
        guard date > .now else {
            clearReminder()
            return
        }
        let (day, time) = DayString.dayAndTime(date)
        reminderOffsetDays = 0
        reminderAnchor = Self.customReminderAnchor
        remindAt = day
        remindTime = time
    }

    func clearReminder() {
        reminderOffsetDays = nil
        reminderAnchor = nil
        remindAt = nil
        remindTime = nil
    }

    /// Drop or recompute the reminder after dates change or the item is done.
    /// A hand-picked reminder ignores the dates; it only goes once it has fired.
    func reconcileReminder() {
        guard hasReminder else { return }
        if isDone || timeBucket == .past {
            clearReminder()
            return
        }
        if reminderAnchor == Self.customReminderAnchor {
            guard let fire = customReminderDate, fire > .now else {
                clearReminder()
                return
            }
            return
        }
        if availableReminderChoices.isEmpty {
            clearReminder()
            return
        }
        guard let offset = reminderOffsetDays, let anchor = reminderAnchor else {
            clearReminder()
            return
        }
        if availableReminderChoices.contains(where: { $0.offsetDays == offset && $0.anchor == anchor }) {
            applyReminder(offset: offset, anchor: anchor)
        } else {
            clearReminder()
        }
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
