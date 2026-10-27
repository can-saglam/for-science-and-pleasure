import SwiftUI

/// The detail drawer's actions, floating bottom right: plain glass circles
/// for the side actions, and the main one in solid white — "We did go!"
/// (or "Put back") spelled out. Calendar lives in the plan, not here.
struct DetailActionCluster: View {
    let item: Item
    /// "We did go!" was tapped and the drawer is on its way out.
    let done: Bool
    let share: () -> Void
    let went: () -> Void
    let putBack: () -> Void

    @Environment(\.openURL) private var openURL

    private var link: URL? { item.url.flatMap(URL.init(string:)) }

    private var directions: URL? { item.isPlace ? item.directionsURL : nil }

    var body: some View {
        // Directions, Share, the link and the main button can outgrow a
        // small phone at large text; Directions gives way first.
        ViewThatFits(in: .horizontal) {
            actions(showingDirections: true)
            actions(showingDirections: false)
        }
    }

    private var shareButton: some View {
        FloatingCircleButton("Share with a friend", systemImage: "paperplane", action: share)
    }

    private func actions(showingDirections: Bool) -> some View {
        FloatingActions {
            if item.isDone && !done {
                shareButton
                if let link { FloatingCircleButton("Open link", systemImage: "safari") { openURL(link) } }
                if item.canPutBack {
                    FloatingMainButton("Put back", systemImage: "arrow.uturn.backward", action: putBack)
                }
            } else {
                if showingDirections || link == nil, let directions {
                    FloatingCircleButton("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") { openURL(directions) }
                }
                shareButton
                if let link {
                    FloatingCircleButton("Open link", systemImage: "safari") { openURL(link) }
                }
                if item.canMarkDone || done {
                    FloatingMainButton(
                        done ? "Done" : (item.isMissed ? Voice.didGoAfterAll : Voice.didGoBang),
                        systemImage: done ? "checkmark.circle.fill" : "checkmark",
                        action: went
                    )
                    .allowsHitTesting(!done)
                }
            }
        }
    }
}
