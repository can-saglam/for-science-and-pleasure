import Foundation

/// A save's opening hours, as `place-hours` returns them: a week from today
/// on the venue's clock. Google's terms let us keep a place ID but not its
/// hours, so these are fetched when the details open and only remembered
/// while the app runs.
struct OpeningHours: Decodable, Equatable {
    struct Range: Decodable, Equatable {
        /// "HH:mm" on the venue's clock; a close of "24:00" or "00:00" is midnight.
        let open: String
        let close: String
    }

    struct Day: Decodable, Equatable {
        let date: String
        let ranges: [Range]
    }

    let status: String
    let days: [Day]
    /// Minutes the venue's clock is ahead of UTC.
    let offset: Int

    var isClosed: Bool { status != "open" }
}

extension Item {
    /// Runs of at least this many days (end minus start) get hours; the
    /// server's `MIN_RUN_DAYS`.
    static let hoursMinRunDays = 3

    /// Whether the venue's hours are this save's own: a place (not a concert
    /// hall, whose hours are the box office's), or an exhibition or market
    /// that runs for days. Mirrors the server's `hoursApply`.
    var hoursApply: Bool {
        guard placeId != nil else { return false }
        if isPlace { return category != "venue" }
        guard isEvent, category == "exhibition" || category == "market" else { return false }
        guard let startsOn, let endsOn,
              let from = DayString.date(startsOn), let to = DayString.date(endsOn)
        else { return true }
        let days = DayString.calendar.dateComponents([.day], from: from, to: to).day ?? 0
        return days >= Self.hoursMinRunDays
    }

    /// Open right now, by hours already loaded this launch.
    @MainActor var isOpenNow: Bool {
        guard let hours = HoursClient.cached(self) ?? nil else { return false }
        return hours.isOpen()
    }

    /// Whether the details should ask for hours today: their own, and for
    /// an event, only while it's on. Mirrors the server's `hoursShown`.
    var showsHours: Bool {
        guard hoursApply else { return false }
        guard isEvent else { return true }
        let today = DayString.today()
        if let startsOn, startsOn > today { return false }
        if let endsOn, endsOn < today { return false }
        return true
    }
}

@MainActor
enum HoursClient {
    /// Per save and place, for this launch only. A failed request isn't
    /// remembered, so the next open tries again.
    private static var cache: [String: OpeningHours?] = [:]

    private static func key(_ item: Item) -> String {
        "\(item.id.uuidString)|\(item.placeId ?? "")"
    }

    static func cached(_ item: Item) -> OpeningHours?? {
        cache[key(item)]
    }

    /// `planning` asks for hours the details wouldn't show yet (an event
    /// before it opens), to mark closed days in the plan picker. A miss
    /// isn't remembered under the details' key.
    static func load(_ item: Item, planning: Bool = false) async -> OpeningHours? {
        let key = planning ? key(item) + "|plan" : key(item)
        if let hit = cache[key] ?? (planning ? cache[self.key(item)] : nil) { return hit }
        do {
            var request = URLRequest(url: SupabaseAuth.baseURL.appending(path: "functions/v1/place-hours"))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(try await SupabaseAuth.shared.validToken())", forHTTPHeaderField: "Authorization")
            var body: [String: Any] = ["item_id": item.id.uuidString.lowercased()]
            if planning { body["planning"] = true }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            struct Envelope: Decodable { let hours: OpeningHours? }
            let hours = try JSONDecoder().decode(Envelope.self, from: data).hours
            cache[key] = hours
            return hours
        } catch {
            return nil
        }
    }
}

// MARK: - Reading them

extension OpeningHours {
    private static let parse: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let show: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    private static let weekdayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "10:00" in the phone's own style ("10:00 AM" in the US).
    static func time(_ hm: String) -> String {
        if hm == "24:00" || hm == "00:00" { return "midnight" }
        return parse.date(from: hm).map(show.string(from:)) ?? hm
    }

    static func minutes(_ hm: String) -> Int {
        (Int(hm.prefix(2)) ?? 0) * 60 + (Int(hm.suffix(2)) ?? 0)
    }

    /// A close at or before its opening runs past midnight.
    static func closeMinutes(_ range: Range) -> Int {
        let close = minutes(range.close)
        return close <= minutes(range.open) ? close + 1440 : close
    }

    static func isAllDay(_ ranges: [Range]) -> Bool {
        ranges.count == 1 && ranges[0].open == "00:00" && closeMinutes(ranges[0]) >= 1440
    }

    /// The venue's date and minutes past midnight, right now.
    private func venueNow(_ now: Date) -> (date: String, minutes: Int) {
        let local = now.addingTimeInterval(TimeInterval(offset * 60))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.hour, .minute], from: local)
        return (Self.weekdayFormat.string(from: local), (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// The week from the venue's today; the days before it drop off if the
    /// app has been open since an earlier day.
    func upcoming(_ now: Date = .now) -> [Day] {
        let today = venueNow(now).date
        return Array(days.drop { $0.date < today })
    }

    /// "Tue", or "Today" and "Tomorrow" for the first two.
    static func dayName(_ day: Day, index: Int) -> String {
        if index == 0 { return "Today" }
        if index == 1 { return "Tomorrow" }
        guard let date = weekdayFormat.date(from: day.date) else { return day.date }
        return date.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).weekday(.abbreviated))
    }

    static func rangesText(_ ranges: [Range]) -> String {
        if ranges.isEmpty { return "Closed" }
        if isAllDay(ranges) { return "Open 24 hours" }
        return ranges.map { "\(time($0.open))–\(time($0.close))" }.joined(separator: ", ")
    }

    /// Where things stand right now: "Open until 18:00", "Opens 10:00",
    /// "Closed today · opens Wed 10:00".
    func summary(_ now: Date = .now) -> String? {
        switch status {
        case "closed_temporarily": return "Temporarily closed"
        case "closed_permanently": return "Closed for good"
        default: break
        }
        let week = upcoming(now)
        guard let today = week.first else { return nil }
        let minutes = venueNow(now).minutes
        let ranges = today.ranges
        if Self.isAllDay(ranges) { return "Open 24 hours" }
        if let first = ranges.first, minutes < Self.minutes(first.open) {
            return "Opens \(Self.time(first.open))"
        }
        for (i, range) in ranges.enumerated() {
            if minutes >= Self.minutes(range.open) && minutes < Self.closeMinutes(range) {
                return "Open until \(Self.time(range.close))"
            }
            if i + 1 < ranges.count, minutes < Self.minutes(ranges[i + 1].open) {
                return "Reopens \(Self.time(ranges[i + 1].open))"
            }
        }
        let closed = ranges.isEmpty ? "Closed today" : "Closed now"
        guard let (index, next) = week.enumerated().dropFirst().first(where: { !$0.element.ranges.isEmpty }),
              let open = next.ranges.first?.open
        else { return closed }
        let when = index == 1 ? "tomorrow" : Self.dayName(next, index: index)
        return "\(closed) · opens \(when) \(Self.time(open))"
    }

    /// The hours on `date` (yyyy-MM-dd): that day's own within the week
    /// Google gave, or the same weekday's beyond it. Empty is closed; nil
    /// is unknown.
    func ranges(on date: String) -> [Range]? {
        guard status == "open" else { return [] }
        if let day = days.first(where: { $0.date == date }) { return day.ranges }
        guard let weekday = Self.weekday(date) else { return nil }
        return days.first { Self.weekday($0.date) == weekday }?.ranges
    }

    /// Whether `date` comes from the week Google gave rather than the
    /// weekday pattern after it.
    func knowsExactly(_ date: String) -> Bool {
        days.contains { $0.date == date }
    }

    private static func weekday(_ date: String) -> Int? {
        guard let day = weekdayFormat.date(from: date) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.component(.weekday, from: day)
    }

    /// The opening `hm` falls in, if any.
    static func range(_ ranges: [Range], containing hm: String) -> Range? {
        let t = minutes(hm)
        return ranges.first { t >= minutes($0.open) && t < closeMinutes($0) }
    }

    /// Open right now, for the summary's colour.
    func isOpen(_ now: Date = .now) -> Bool {
        guard status == "open", let today = upcoming(now).first else { return false }
        let minutes = venueNow(now).minutes
        return today.ranges.contains { minutes >= Self.minutes($0.open) && minutes < Self.closeMinutes($0) }
    }
}
