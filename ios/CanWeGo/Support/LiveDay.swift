import ActivityKit
import UIKit

/// Mirror of the widget's `DayActivityAttributes`, and of the payload
/// `send-reminders` builds: the type name and every field are the contract.
struct DayActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var label: String
    }

    var itemID: String
    var title: String
    var place: String?
    var colorHex: String?
    var kind: String
    var day: String
    var endsAt: Double
}

/// The app's half of the reminder-day Live Activity: the server starts and
/// ends it, and needs two tokens from here to do so. The phone's
/// push-to-start token goes up whenever it's issued or the account
/// changes; each running activity's update token goes up as it arrives
/// (the system wakes the app in the background for this when a push
/// starts one).
@MainActor
enum LiveDay {
    private static var listening = false
    private static var followed: Set<String> = []
    private static let sentKey = "liveDayStartToken"

    /// From launch, including background launches.
    static func listen() {
        guard !listening else { return }
        listening = true
        Task {
            for await data in Activity<DayActivityAttributes>.pushToStartTokenUpdates {
                await sendStartToken(hex(data))
            }
        }
        Task {
            for await activity in Activity<DayActivityAttributes>.activityUpdates {
                follow(activity)
            }
        }
        for activity in Activity<DayActivityAttributes>.activities {
            follow(activity)
        }
    }

    /// On becoming active: sends the start token if this account hasn't got
    /// it yet (a token issued while signed out went nowhere), and ends any
    /// activity whose day is over or whose save has moved on, in case the
    /// end push never came.
    static func refresh(items: [Item]) async {
        if let data = Activity<DayActivityAttributes>.pushToStartToken {
            await sendStartToken(hex(data))
        }
        let today = DayString.today()
        let now = Date().timeIntervalSince1970
        for activity in Activity<DayActivityAttributes>.activities {
            let attributes = activity.attributes
            let over = attributes.day < today || now >= attributes.endsAt
            let item = UUID(uuidString: attributes.itemID).flatMap { id in items.first { $0.id == id } }
            let movedOn = item.map { $0.isDone || $0.remindAt != attributes.day } ?? false
            if over || movedOn {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func follow(_ activity: Activity<DayActivityAttributes>) {
        guard followed.insert(activity.id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates {
                await call("register_live_activity", [
                    "p_item_id": activity.attributes.itemID,
                    "p_token": hex(data),
                ])
            }
        }
    }

    private static func sendStartToken(_ token: String) async {
        guard let user = SupabaseAuth.shared.userId?.uuidString else { return }
        let sent = "\(user):\(token)"
        guard UserDefaults.standard.string(forKey: sentKey) != sent else { return }
        if await call("register_activity_token", ["p_token": token, "p_build": SupabaseSync.buildNumber]) {
            UserDefaults.standard.set(sent, forKey: sentKey)
        }
    }

    @discardableResult
    private static func call(_ function: String, _ arguments: [String: Any]) async -> Bool {
        guard SupabaseAuth.shared.signedIn,
              let jwt = try? await SupabaseAuth.shared.validToken(),
              let device = UIDevice.current.identifierForVendor?.uuidString
        else { return false }
        var request = URLRequest(url: SupabaseAuth.baseURL.appending(path: "rest/v1/rpc/\(function)"))
        request.httpMethod = "POST"
        request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = arguments
        body["p_device_id"] = device
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        for attempt in 0..<2 {
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
                return true
            }
            if attempt == 0 { try? await Task.sleep(for: .seconds(2)) }
        }
        return false
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
