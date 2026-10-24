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

    private var directions: URL? { item.isPlace ? item.directionsURL : nil }

    /// A place's side slot is Directions; Calendar joins it only for a
    /// plan. An event that's over has nothing left to put in a calendar.
    private var showsCalendar: Bool {
        guard !item.isDone || done else { return false }
        if item.upcomingPlan != nil { return true }
        if directions != nil { return false }
        return item.startsOn != nil && item.timeBucket != .past
    }

    /// Anything to show at all.
    static func hasActions(_ item: Item, done: Bool) -> Bool {
        item.url.flatMap(URL.init(string:)) != nil || item.canPutBack || (!item.isDone && item.canMarkDone) || done
            || item.startsOn != nil || item.upcomingPlan != nil
            || (item.isPlace && item.directionsURL != nil)
    }

    var body: some View {
        // Directions, Calendar, the link and the main button can outgrow a
        // small phone at large text; Directions gives way first.
        ViewThatFits(in: .horizontal) {
            actions(showingDirections: true)
            actions(showingDirections: false)
        }
        .animation(reduceMotion ? nil : .snappy, value: calendarAdded)
    }

    private func actions(showingDirections: Bool) -> some View {
        FloatingActions {
            if item.isDone && !done {
                if let link { FloatingCircleButton("Open link", systemImage: "safari") { openURL(link) } }
                if item.canPutBack {
                    FloatingMainButton("Put back", systemImage: "arrow.uturn.backward", action: putBack)
                }
            } else {
                if showingDirections || !showsCalendar || link == nil, let directions {
                    FloatingCircleButton("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") { openURL(directions) }
                }
                if showsCalendar {
                    FloatingCircleButton(
                        calendarAdded ? "In calendar" : "Add to calendar",
                        systemImage: calendarAdded ? "checkmark" : "calendar.badge.plus",
                        action: addToCalendar
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
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
