import Foundation
import UserNotifications

/// Local notifications for closing windows: when a saved event enters its
/// final week, a single quiet nudge fires at 10am. Rescheduled from scratch
/// on every foreground so the set always matches the library.
enum LastChanceNotifier {
    private static let prefix = "lastchance-"

    static func sync(items: [Item]) async {
        let center = UNUserNotificationCenter.current()

        let events = items.filter {
            $0.isEvent && !$0.isDone && !$0.isMissed && $0.endsOn != nil
        }
        // Don't ask for permission until there's actually something to say.
        // (CWG_NO_PROMPTS keeps automated screenshot runs alert-free.)
        guard !events.isEmpty,
              ProcessInfo.processInfo.environment["CWG_NO_PROMPTS"] == nil
        else { return }

        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized else { return }

        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        let calendar = Calendar.current
        for event in events {
            guard let end = event.endsOn.flatMap(DayString.date),
                  let weekBefore = calendar.date(byAdding: .day, value: -6, to: end)
            else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: weekBefore)
            comps.hour = 10
            guard let fire = calendar.date(from: comps), fire > .now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Last chance"
            let closes = end.formatted(date: .abbreviated, time: .omitted)
            content.body = "\u{201c}\(event.title)\u{201d} closes \(closes) — one week left."
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour], from: fire),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: prefix + event.id.uuidString,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }
}
