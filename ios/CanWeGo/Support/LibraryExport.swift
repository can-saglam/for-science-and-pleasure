import Foundation
import LinkPresentation
import UIKit

/// The library as files a person can take anywhere: a spreadsheet with
/// every field (Numbers, Excel, Google Sheets; Google My Maps, Notion and
/// Airtable import it), the dated events as a calendar, and the same
/// readable list the web exports.
@MainActor
enum LibraryExport {
    /// Writes the files into a fresh folder and returns them for the share
    /// sheet. The calendar is left out when nothing has a date.
    static func write(_ items: [Item]) -> [URL] {
        let live = items.filter { !$0.isDeleted && $0.deletedAt == nil }
            .sorted { ($0.isEvent ? 0 : 1, $0.title.lowercased()) < ($1.isEvent ? 0 : 1, $1.title.lowercased()) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Can We Go export")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var files: [(String, String)] = [("Can We Go.csv", csv(live))]
        if let calendar = ics(live) { files.append(("Can We Go events.ics", calendar)) }
        files.append(("Can We Go.md", markdown(live)))

        return files.compactMap { name, body in
            let url = folder.appending(path: name)
            return (try? body.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
        }
    }

    /// Share-sheet items: the first one carries a title, so the sheet's
    /// header reads as the library rather than "Plain Text and 1 Document".
    static func shareItems(_ files: [URL]) -> [Any] {
        let icon = UIImage(named: ThemeStore.shared.current.iconPreviewName)
        return files.enumerated().map { i, url in
            i == 0 ? TitledFile(url: url, count: files.count, icon: icon) as Any : url
        }
    }

    /// Reminders would make a to-do of the files.
    static let excludedTargets = [UIActivity.ActivityType("com.apple.reminders.sharingextension")]

    // MARK: - Spreadsheet

    static func csv(_ items: [Item]) -> String {
        let header = [
            "Title", "Type", "Category", "Status", "Starts", "Ends",
            "Venue", "Area", "Address", "Latitude", "Longitude",
            "Price", "Link", "Summary", "Notes", "Photo", "Added by", "Added on",
        ]
        let rows = items.map { i in
            [
                i.title,
                i.isEvent ? "Event" : "Place",
                i.category.map(Item.categoryLabel),
                status(i),
                i.startsOn,
                i.endsOn,
                i.venue,
                i.area,
                i.address,
                i.lat.map { String(format: "%.6f", $0) },
                i.lng.map { String(format: "%.6f", $0) },
                i.price,
                i.url,
                i.summary,
                i.notes,
                i.imageUrl,
                MembersStore.shared.saverName(for: i),
                addedOn(i),
            ]
        }
        // The byte-order mark is what makes Excel read accents as UTF-8.
        return "\u{FEFF}" + ([header] + rows.map { $0.map { $0 ?? "" } })
            .map { $0.map(cell).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }

    private static func status(_ i: Item) -> String {
        if i.isDone { return "Been" }
        if i.isMissed { return "Missed" }
        return "Saved"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func addedOn(_ i: Item) -> String {
        dayFormatter.string(from: i.createdAt)
    }

    /// Quoted when it has to be. Titles come from web pages, so anything a
    /// spreadsheet would run as a formula is defused with a leading quote.
    private static func cell(_ raw: String) -> String {
        var s = raw
        if let first = s.first, "=+-@\t\r".contains(first) { s = "'" + s }
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Calendar

    /// All-day entries. A run of up to a week is one entry; anything longer
    /// (most exhibitions) becomes its opening day and its last day, so it
    /// doesn't lie across every day for months.
    static func ics(_ items: [Item]) -> String? {
        let stamp = utcStamp(.now)
        var events: [String] = []
        for i in items where i.isEvent {
            guard let first = i.startsOn ?? i.endsOn, let last = i.endsOn ?? i.startsOn else { continue }
            if i.startsOn == nil {
                events.append(entry(i, "\(i.id.uuidString)-last", "Last day: \(i.title)", on: last, stamp: stamp))
            } else if (DayString.daysBetween(first, last) ?? 0) <= 6 {
                events.append(entry(i, i.id.uuidString, i.title, on: first, through: last, stamp: stamp))
            } else {
                events.append(entry(i, "\(i.id.uuidString)-opens", "Opens: \(i.title)", on: first, stamp: stamp))
                events.append(entry(i, "\(i.id.uuidString)-last", "Last day: \(i.title)", on: last, stamp: stamp))
            }
        }
        guard !events.isEmpty else { return nil }
        let lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Can We Go?//Library export//EN",
            "CALSCALE:GREGORIAN",
            "X-WR-CALNAME:Can We Go?",
        ] + events + ["END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func entry(
        _ i: Item, _ uid: String, _ summary: String,
        on day: String, through last: String? = nil, stamp: String
    ) -> String {
        // DTEND is exclusive: the morning after the last day.
        let end = DayString.addingDays(1, to: last ?? day) ?? day
        var lines = [
            "BEGIN:VEVENT",
            "UID:\(uid)@canwego.app",
            "DTSTAMP:\(stamp)",
            "DTSTART;VALUE=DATE:\(compact(day))",
            "DTEND;VALUE=DATE:\(compact(end))",
            "SUMMARY:\(escape(summary))",
            "TRANSP:TRANSPARENT",
        ]
        let place = [i.venue, i.address ?? i.area].compactMap { $0?.isEmpty == false ? $0 : nil }
        if !place.isEmpty { lines.append("LOCATION:\(escape(place.joined(separator: ", ")))") }
        var about: [String] = []
        if let s = i.startsOn, let e = i.endsOn, s != e,
           let from = DayString.text(s, date: .abbreviated), let to = DayString.text(e, date: .abbreviated) {
            about.append("On \(from) – \(to)")
        }
        if let summary = i.summary, !summary.isEmpty { about.append(summary) }
        if let notes = i.notes, !notes.isEmpty { about.append("Notes: \(notes)") }
        if let url = i.url { about.append(url) }
        if !about.isEmpty { lines.append("DESCRIPTION:\(escape(about.joined(separator: "\n\n")))") }
        if let url = i.url, URL(string: url) != nil { lines.append("URL:\(url)") }
        if let lat = i.lat, let lng = i.lng { lines.append(String(format: "GEO:%.6f;%.6f", lat, lng)) }
        lines.append("END:VEVENT")
        return lines.map(fold).joined(separator: "\r\n")
    }

    private static func compact(_ day: String) -> String {
        day.replacingOccurrences(of: "-", with: "")
    }

    private static func utcStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Calendar lines stop at 75 bytes; longer ones continue on a line
    /// that starts with a space. Never splits a character.
    private static func fold(_ line: String) -> String {
        var out = ""
        var bytes = 0
        for ch in line {
            let n = String(ch).utf8.count
            if bytes + n > 75 {
                out += "\r\n "
                bytes = 1
            }
            out.append(ch)
            bytes += n
        }
        return out
    }

    // MARK: - Readable list

    /// Same shape as the web export: grouped, human-readable Markdown.
    static func markdown(_ items: [Item]) -> String {
        var lines = ["# Can We Go?", ""]

        func section(_ title: String, _ list: [Item]) {
            guard !list.isEmpty else { return }
            lines.append("## \(title)")
            lines.append("")
            for i in list {
                var meta = [i.venue, i.area, i.price].compactMap(\.self)
                if let s = i.startsOn, let e = i.endsOn {
                    meta.append(s == e ? s : "\(s) – \(e)")
                } else if let e = i.endsOn {
                    meta.append("until \(e)")
                }
                lines.append("- **\(i.title)**\(meta.isEmpty ? "" : " · \(meta.joined(separator: " · "))")")
                if let summary = i.summary { lines.append("  \(summary)") }
                if let url = i.url { lines.append("  <\(url)>") }
                if let notes = i.notes, !notes.isEmpty { lines.append("  > \(notes)") }
            }
            lines.append("")
        }

        section("Events", items.filter { $0.isEvent && !$0.isDone && !$0.isMissed })
        section("Places", items.filter { $0.isPlace && !$0.isDone && !$0.isMissed })
        section("Been", items.filter { $0.isDone })
        section("Missed", items.filter { $0.isMissed })
        return lines.joined(separator: "\n")
    }
}

private final class TitledFile: NSObject, UIActivityItemSource {
    private static let title = "Your Can We Go? library"
    let url: URL
    let count: Int
    let icon: UIImage?

    init(url: URL, count: Int, icon: UIImage?) {
        self.url = url
        self.count = count
        self.icon = icon
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }

    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String { Self.title }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let meta = LPLinkMetadata()
        meta.title = Self.title
        // Shown as the header's second line.
        meta.originalURL = URL(fileURLWithPath: "\(count) files")
        if let icon { meta.iconProvider = NSItemProvider(object: icon) }
        return meta
    }
}
