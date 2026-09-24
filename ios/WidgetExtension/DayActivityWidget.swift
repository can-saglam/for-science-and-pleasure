import ActivityKit
import SwiftUI
import WidgetKit

/// A save on its reminder day, on the Lock Screen and in the Dynamic Island
/// from 09:00 until 18:00. Started and ended by `send-reminders`.
///
/// Mirror of the app's `DayActivityAttributes`, and of the payload
/// `send-reminders` builds (`_shared/live_activity.ts`): the type name and
/// every field are the contract. Plain types only, since APNs payloads are
/// decoded with the default strategies.
struct DayActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Last day", "Opens tomorrow", "Reminder".
        var label: String
    }

    var itemID: String
    var title: String
    var place: String?
    var colorHex: String?
    var kind: String
    /// The reminder day, yyyy-MM-dd on the home clock.
    var day: String
    /// When it leaves the Lock Screen, in seconds since 1970.
    var endsAt: Double
}

struct DayActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DayActivityAttributes.self) { context in
            DayActivityView(context: context)
                .activityBackgroundTint(DayActivityView.backdrop(context.attributes))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(DayActivityView.link(context.attributes))
        } dynamicIsland: { context in
            let accent = DayActivityView.accent(context.attributes)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DayActivityView.glyph(context.attributes)
                        .font(.title3)
                        .foregroundStyle(accent)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.title)
                                .font(.headline)
                                .lineLimit(2)
                            if let place = context.attributes.place {
                                Text(place)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        DayActivityView.openButton(context.attributes, tint: accent)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                DayActivityView.glyph(context.attributes)
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(context.state.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .frame(maxWidth: 76)
                    .minimumScaleFactor(0.7)
            } minimal: {
                DayActivityView.glyph(context.attributes)
                    .foregroundStyle(accent)
            }
            .widgetURL(DayActivityView.link(context.attributes))
            .keylineTint(accent)
        }
        .supplementalActivityFamilies([.small])
    }
}

struct DayActivityView: View {
    let context: ActivityViewContext<DayActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small: small
        default: medium
        }
    }

    /// Lock Screen and banner.
    private var medium: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Self.glyph(context.attributes)
                    Text(context.state.label.uppercased())
                        .tracking(0.6)
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)

                Text(context.attributes.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let place = context.attributes.place {
                    Text(place)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Self.openButton(context.attributes, tint: .white)
        }
        .padding(16)
    }

    /// Apple Watch Smart Stack and CarPlay.
    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Self.glyph(context.attributes)
                Text(context.state.label)
                    .lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Self.accent(context.attributes))
            Text(context.attributes.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    static func glyph(_ attributes: DayActivityAttributes) -> Image {
        Image(systemName: attributes.kind == "place" ? "mappin.and.ellipse" : "ticket.fill")
    }

    static func openButton(_ attributes: DayActivityAttributes, tint: Color) -> some View {
        Link(destination: link(attributes)) {
            Text("Open")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint == .white ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(tint, in: .capsule)
        }
    }

    static func link(_ attributes: DayActivityAttributes) -> URL {
        URL(string: "canwego://item/\(attributes.itemID)") ?? URL(string: "canwego://")!
    }

    /// The save's own colour, lifted so it reads on the black island.
    static func accent(_ attributes: DayActivityAttributes) -> Color {
        let base = attributes.colorHex.flatMap(Color.fromHex) ?? Color(red: 0.96, green: 0.89, blue: 0.71)
        return base.mix(with: .white, by: 0.35)
    }

    /// A deep wash of the save's colour behind white type.
    static func backdrop(_ attributes: DayActivityAttributes) -> Color {
        let base = attributes.colorHex.flatMap(Color.fromHex) ?? Color(red: 0.2, green: 0.2, blue: 0.09)
        return base.mix(with: .black, by: 0.45)
    }
}
