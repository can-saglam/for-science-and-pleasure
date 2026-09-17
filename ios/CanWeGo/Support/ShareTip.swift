import SwiftUI
import TipKit

/// The one thing worth teaching after the first run: saves can come from
/// the share sheet. Held back until the second launch, so the first is
/// about the library itself, and never shown to someone who has already
/// shared something in.
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
        #Rule(Self.appOpened) { $0.donations.count >= 2 }
        #Rule(Self.$hasShared) { $0 == false }
    }

    /// Call once per process, at the point the library is on screen.
    static func configure() {
        try? Tips.configure([.datastoreLocation(.applicationDefault)])
        // CWG_TIPS (screenshot runs): show every tip regardless of rules.
        if ProcessInfo.processInfo.environment["CWG_TIPS"] != nil {
            Tips.showAllTipsForTesting()
        }
    }
}
