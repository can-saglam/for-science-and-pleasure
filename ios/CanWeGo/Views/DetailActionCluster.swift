import SwiftUI

/// The detail drawer's actions, floating bottom right: plain glass circles
/// for the side actions, and the main one in solid white — "We did go!"
/// (or "Put back") spelled out.
struct DetailActionCluster: View {
    let item: Item
    /// "We did go!" was tapped and the drawer is on its way out.
    let done: Bool
    let calendarAdded: Bool
    let addToCalendar: () -> Void
    let went: () -> Void
    let putBack: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var link: URL? { item.url.flatMap(URL.init(string:)) }

    private var showsCalendar: Bool {
        (item.startsOn != nil || item.upcomingPlan != nil) && (!item.isDone || done)
    }

    /// Anything to show at all.
    static func hasActions(_ item: Item, done: Bool) -> Bool {
        item.url.flatMap(URL.init(string:)) != nil || item.isDone || item.canMarkDone || done
            || item.startsOn != nil || item.upcomingPlan != nil
            || (item.isPlace && item.directionsURL != nil)
    }

    var body: some View {
        FloatingActions {
            if item.isDone && !done {
                if let link { FloatingCircleButton("Open link", systemImage: "safari") { openURL(link) } }
                FloatingMainButton("Put back", systemImage: "arrow.uturn.backward", action: putBack)
            } else {
                if item.isPlace, let maps = item.directionsURL {
                    FloatingCircleButton("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") { openURL(maps) }
                } else if showsCalendar {
                    FloatingCircleButton(
                        calendarAdded ? "In calendar" : "Add to calendar",
                        systemImage: calendarAdded ? "checkmark" : "calendar.badge.plus",
                        action: addToCalendar
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                if let link { FloatingCircleButton("Open link", systemImage: "safari") { openURL(link) } }
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
        .animation(reduceMotion ? nil : .snappy, value: calendarAdded)
    }
}
