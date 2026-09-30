import SwiftUI
import TipKit
import WidgetKit

/// The second thing worth teaching: the list can live on the Home Screen.
/// Waits for enough photos that the widget looks dressed, and for the share
/// tip to be done with, and never reaches someone who already has one.
struct WidgetTip: Tip {
    /// Set once a Can We Go? widget is seen on the Home Screen. Never unset:
    /// someone who removed theirs doesn't need telling again.
    @Parameter static var hasWidget: Bool = false
    /// Upcoming events with a photo — what the widget rotates through.
    @Parameter static var photoSaves: Int = 0

    var title: Text { Text("Your list on your Home Screen") }
    var message: Text? {
        Text("Touch and hold your Home Screen, tap Edit, then Add Widget and search for Can\u{00A0}We\u{00A0}Go?")
    }
    var image: Image? { Image(systemName: "apps.iphone") }

    var rules: [Rule] {
        #Rule(ShareTip.appOpened) { $0.donations.count >= 4 }
        #Rule(Self.$photoSaves) { $0 >= 5 }
        #Rule(Self.$hasWidget) { $0 == false }
    }

    /// On each foreground, with the live library.
    @MainActor
    static func refresh(items: [Item]) async {
        let count = items.filter { $0.isEvent && !$0.isDone && !$0.isMissed && $0.imageUrl != nil }.count
        if photoSaves != count { photoSaves = count }
        guard !hasWidget,
              let widgets = try? await WidgetCenter.shared.currentConfigurations(),
              widgets.contains(where: { $0.kind == "RandomSave" })
        else { return }
        hasWidget = true
        WidgetTip().invalidate(reason: .actionPerformed)
    }
}
