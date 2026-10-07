import SwiftUI

/// The detail drawer's actions, floating bottom right: plain glass circles
/// for the side actions, and the main one in solid white — "We did go!"
/// (or "Put back") spelled out. A soft fade in the corner keeps text from running under it.
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
        HStack {
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 12) {
                    if item.isDone && !done {
                        if let link { circle("safari", "Open link") { openURL(link) } }
                        main("arrow.uturn.backward", "Put back", action: putBack)
                    } else {
                        if item.isPlace, let maps = item.directionsURL {
                            circle("arrow.triangle.turn.up.right.diamond", "Directions") { openURL(maps) }
                        } else if showsCalendar {
                            circle(
                                calendarAdded ? "checkmark" : "calendar.badge.plus",
                                calendarAdded ? "In calendar" : "Add to calendar",
                                action: addToCalendar
                            )
                            .contentTransition(.symbolEffect(.replace))
                        }
                        if let link { circle("safari", "Open link") { openURL(link) } }
                        if item.canMarkDone || done {
                            main(
                                done ? "checkmark.circle.fill" : "checkmark",
                                done ? "Done" : (item.isMissed ? Voice.didGoAfterAll : Voice.didGoBang),
                                action: went
                            )
                            .allowsHitTesting(!done)
                        }
                    }
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: calendarAdded)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        // Into the home-indicator margin, the way the system's own
        // floating controls sit, while keeping clear of the corner.
        .padding(.bottom, -8)
        .background(alignment: .bottomTrailing) {
            RadialGradient(
                colors: [AppBackground.sheet.opacity(0.92), AppBackground.sheet.opacity(0)],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 220
            )
            // Taller than the row, so it fades out fully above the
            // buttons rather than stopping at a hard edge.
            .frame(width: 220, height: 220)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// Solid white: the reason the drawer is open.
    private func main(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 20)
            .frame(minWidth: 54, minHeight: 54)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppBackground.onProminent)
        .glassEffect(.regular.tint(.white).interactive(), in: .capsule)
        .accessibilityLabel(label)
    }

    private func circle(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 54, height: 54)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppBackground.ink)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}
