#if !APP_EXTENSION
import Foundation
import UserNotifications

/// One nudge toward a second save: the evening after the first, a
/// notification with one of the home city's picks, pointing at the share
/// sheet. Scheduled on the phone, so the server plays no part; withdrawn for
/// good once there's a second save. Never asks for permission: with
/// notifications off it simply doesn't happen.
@MainActor
enum SecondSaveNudge {
    private static let id = "second-save-nudge"
    /// Two saves reached: never again on this phone.
    private static let doneKey = "secondSaveNudge.done"
    /// Booked once; a second booking would only repeat it.
    private static let bookedKey = "secondSaveNudge.booked"
    private static var defaults: UserDefaults { UserDefaults(suiteName: SharedInbox.groupID) ?? .standard }

    static func refresh(items: [Item]) async {
        guard SupabaseAuth.shared.signedIn, !GroupStore.shared.libraryIsForeign,
              !defaults.bool(forKey: doneKey)
        else { return }
        let saves = items.filter { !$0.isTrashed && ($0.isEvent || $0.isPlace) }
        let center = UNUserNotificationCenter.current()
        if saves.count >= 2 {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            defaults.set(true, forKey: doneKey)
            return
        }
        guard saves.count == 1, let first = saves.first, !defaults.bool(forKey: bookedKey) else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let when = fireDate(after: first.createdAt)
        let content = UNMutableNotificationContent()
        let home = HomeStore.shared.isSet ? HomeStore.shared.home : nil
        if let home, let pick = Suggestions.shared.mixed(for: home, excluding: items, count: 1).first,
           let data = try? JSONEncoder().encode(pick) {
            content.title = pick.shortTitle ?? pick.title
            content.body = body(pick, city: home.locality)
            content.userInfo = ["pick": data]
        } else {
            content.title = "Seen somewhere you\u{2019}d go?"
            content.body = "Share it to Can We Go? from Safari, Instagram or Maps and it\u{2019}s on your list."
        }
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        )
        guard (try? await center.add(request)) != nil else { return }
        defaults.set(true, forKey: bookedKey)
    }

    /// 18:00 the day after the first save, or the next 18:00 at least an
    /// hour off when that has gone by.
    static func fireDate(after saved: Date, now: Date = .now) -> Date {
        let calendar = Calendar.current
        let nextDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: saved) ?? saved)
        let earliest = max(nextDay, now.addingTimeInterval(3600))
        let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: earliest) ?? earliest
        return evening >= earliest ? evening : calendar.date(byAdding: .day, value: 1, to: evening) ?? evening
    }

    /// "At Tate Britain, until 15 Feb. One of this week's picks in London:
    /// tap to save it, or share the next thing you see from Safari or
    /// Instagram."
    private static func body(_ pick: Suggestions.Pick, city: String) -> String {
        var about: [String] = []
        if let venue = Suggestions.shared.whereText(pick) {
            about.append(pick.kind == Item.Kind.event ? "At \(venue)" : venue)
        }
        if let when = Suggestions.when(pick) { about.append(when) }
        let lead = about.isEmpty ? "" : about.joined(separator: ", ") + ". "
        return lead + "One of this week\u{2019}s picks in \(city): tap to save it, or share the next thing you see from Safari or Instagram."
    }
}
#endif
