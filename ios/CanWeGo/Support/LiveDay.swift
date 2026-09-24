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
    var imageURL: String?
    var kind: String
    var day: String
    var endsAt: Double
}

/// The app's half of the day-of Live Activity: the server starts and ends
/// it, and needs two tokens from here to do so. The phone's push-to-start
/// token goes up whenever it's issued or the account changes; each running
/// activity's update token goes up as it arrives (the system wakes the app
/// in the background for this when a push starts one), and so does its
/// photo, parked in the App Group for the widget to draw.
///
/// Settings → "Live Activity on the day" switches it off per phone: the
/// start token comes off the server, so nothing arrives at all.
@MainActor
enum LiveDay {
    static let key = "liveActivities"
    private static var listening = false
    private static var followed: Set<String> = []
    private static let sentKey = "liveDayStartToken"

    /// On unless switched off in Settings, and allowed by iOS.
    static var isOn: Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool ?? true)
            && ActivityAuthorizationInfo().areActivitiesEnabled
    }

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
                await arrived(activity)
            }
        }
        // iOS's own switch for this app, flipped in the Settings app.
        Task {
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                await sync()
            }
        }
        for activity in Activity<DayActivityAttributes>.activities {
            Task { await arrived(activity) }
        }
    }

    /// The Settings switch.
    static func set(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: key)
        await sync()
    }

    /// On becoming active: sends the start token if this account hasn't got
    /// it yet (a token issued while signed out went nowhere), and ends any
    /// activity whose time is up or whose save has moved on, in case the
    /// end push never came.
    static func refresh(items: [Item]) async {
        await sync()
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
        sweepPhotos()
    }

    /// Signing out took the phone's tokens off the server; the screen and
    /// the marker follow, so the next account sends its own.
    static func signedOut() async {
        UserDefaults.standard.removeObject(forKey: sentKey)
        for activity in Activity<DayActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        sweepPhotos()
    }

    /// Token on the server matches the switch; off also clears the screen.
    private static func sync() async {
        if isOn {
            if let data = Activity<DayActivityAttributes>.pushToStartToken {
                await sendStartToken(hex(data))
            }
        } else {
            if UserDefaults.standard.string(forKey: sentKey) != nil,
               await call("unregister_activity_token", [:]) {
                UserDefaults.standard.removeObject(forKey: sentKey)
            }
            for activity in Activity<DayActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func arrived(_ activity: Activity<DayActivityAttributes>) async {
        // Started by a push that raced the switch being turned off.
        guard isOn else {
            await activity.end(nil, dismissalPolicy: .immediate)
            return
        }
        guard followed.insert(activity.id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates {
                await call("register_live_activity", [
                    "p_item_id": activity.attributes.itemID,
                    "p_token": hex(data),
                ])
            }
        }
        await park(activity)
    }

    // MARK: - Photo

    private static var photos: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedInbox.groupID)?
            .appending(path: "Live", directoryHint: .isDirectory)
    }

    private static func photoFile(_ itemID: String) -> URL? {
        photos?.appending(path: "\(itemID.lowercased()).jpg")
    }

    /// Fetches the save's photo (disk cache first), shrinks it to what the
    /// Lock Screen shows, and re-renders the activity so it appears.
    private static func park(_ activity: Activity<DayActivityAttributes>) async {
        guard let file = photoFile(activity.attributes.itemID),
              !FileManager.default.fileExists(atPath: file.path()),
              let url = activity.attributes.imageURL.flatMap(URL.init(string:)),
              let image = await ImageStore.fetch(url),
              let jpeg = shrunk(image, maxSide: 450).jpegData(compressionQuality: 0.8)
        else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? jpeg.write(to: file, options: .atomic)) != nil else { return }
        await activity.update(activity.content)
    }

    private static func sweepPhotos() {
        guard let photos else { return }
        let keep = Set(Activity<DayActivityAttributes>.activities.map { "\($0.attributes.itemID.lowercased()).jpg" })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: photos.path())) ?? []
        for file in files where !keep.contains(file) {
            try? FileManager.default.removeItem(at: photos.appending(path: file))
        }
    }

    private static func shrunk(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxSide else { return image }
        let scale = maxSide / largest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Server

    private static func sendStartToken(_ token: String) async {
        guard isOn, let user = SupabaseAuth.shared.userId?.uuidString else { return }
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
