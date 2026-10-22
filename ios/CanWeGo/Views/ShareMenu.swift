import SwiftUI
import UIKit

/// The share actions, the same in the details' menu and a card's
/// long-press: the save sent as a link that opens it ready to save, and the
/// page's own link copied (or a map without one).
struct ShareMenuItems: View {
    let item: Item
    let send: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            send()
        } label: {
            Label("Send to a friend", systemImage: "paperplane")
        }
        if let url = item.shareURL {
            let page = item.sharesPage
            Button {
                Haptics.success()
                UIPasteboard.general.url = url
            } label: {
                Label(page ? "Copy link" : "Copy map link", systemImage: "doc.on.doc")
            }
        }
    }
}

/// What goes to the share sheet, wrapped so a sheet can be driven by it.
struct ShareItems: Identifiable {
    let id = UUID()
    let items: [Any]

    /// The save as a link that opens it, here or on the web. Without a
    /// connection to make one, the page's own link (or a map) goes instead.
    @MainActor
    static func sending(_ item: Item) async -> ShareItems {
        guard let link = (try? await SaveLink.url(for: item)) ?? item.shareURL else {
            return ShareItems(items: [item.shareMessage])
        }
        return ShareItems(items: [AlongsideLink(text: item.shareMessage), link])
    }
}

/// The text that goes with a link to a chat or a mail. Copy leaves it out:
/// with it on the clipboard, a paste into Safari's address bar is the text,
/// and Safari searches for it instead of opening the link.
private final class AlongsideLink: NSObject, UIActivityItemSource {
    let text: String

    init(text: String) { self.text = text }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { text }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        type == .copyToPasteboard ? nil : text
    }
}

/// `UIActivityViewController` in a sheet — `ShareLink` wants its payload at
/// build time, and a save link is made on demand.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    var excluded: [UIActivity.ActivityType] = []
    /// Called with true once something was actually sent or saved.
    var completed: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.excludedActivityTypes = excluded
        if let completed {
            controller.completionWithItemsHandler = { _, done, _, _ in completed(done) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
