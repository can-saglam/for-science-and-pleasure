import SwiftUI
import TipKit

/// The one thing worth teaching after the first run: saves can come from
/// the share sheet. Shown on the list from the first launch, where the
/// first run used to end on a page about it, and never to someone who
/// has already shared something in.
struct ShareTip: Tip {
    /// One donation per launch, from `ContentView`.
    static let appOpened = Event(id: "appOpened")
    /// Flipped the first time a share-extension save lands in the app.
    @Parameter static var hasShared: Bool = false

    var title: Text { Text("Save from anywhere") }
    var message: Text? {
        Text("In Safari or any app, tap Share, then Can We Go? The first time, it's under More in the share sheet.")
    }
    var image: Image? { Image(systemName: "square.and.arrow.up") }

    var rules: [Rule] {
        #Rule(Self.appOpened) { $0.donations.count >= 1 }
        #Rule(Self.$hasShared) { $0 == false }
    }

    /// Set by first runs that ended on a page showing the share sheet and
    /// the widget, so neither tip is needed after one of those.
    static var taughtInOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "tips.taughtInOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "tips.taughtInOnboarding") }
    }

    /// Call once per process, at the point the library is on screen.
    static func configure() {
        try? Tips.configure([.datastoreLocation(.applicationDefault)])
        // CWG_TIPS (screenshot runs): show every tip regardless of rules.
        if ProcessInfo.processInfo.environment["CWG_TIPS"] != nil {
            Tips.showAllTipsForTesting()
        } else if taughtInOnboarding {
            ShareTip().invalidate(reason: .actionPerformed)
            WidgetTip().invalidate(reason: .actionPerformed)
        }
    }
}
