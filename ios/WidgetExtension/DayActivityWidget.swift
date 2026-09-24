import ActivityKit
import SwiftUI
import WidgetKit

/// A save on the day its reminder goes off, on the Lock Screen and in the
/// Dynamic Island for up to eight hours. Started and ended by
/// `send-reminders`; a tap anywhere opens the save.
///
/// Mirror of the app's `DayActivityAttributes`, and of the payload
/// `send-reminders` builds (`_shared/live_activity.ts`): the type name and
/// every field are the contract. Plain types only, since APNs payloads are
/// decoded with the default strategies.
struct DayActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Last day", "Opens tomorrow", "Today".
        var label: String
    }

    var itemID: String
    var title: String
    var place: String?
    var colorHex: String?
    var imageURL: String?
    var kind: String
    /// The reminder day, yyyy-MM-dd on the home clock.
    var day: String
    /// When it leaves the Lock Screen, in seconds since 1970.
    var endsAt: Double
}

/// The photo the app parks for a running activity (`LiveDay.park`),
/// decoded small: Live Activities render under a tight memory ceiling.
enum LivePhoto {
    static func load(_ itemID: String, maxSide: CGFloat = 450) -> UIImage? {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Snapshot.groupID)?
            .appending(path: "Live/\(itemID.lowercased()).jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct DayActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DayActivityAttributes.self) { context in
            let look = DayLook(context.attributes)
            DayActivityView(context: context, look: look)
                .activityBackgroundTint(look.card)
                .activitySystemActionForegroundColor(look.ink)
                .widgetURL(look.link)
        } dynamicIsland: { context in
            let look = DayLook(context.attributes)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Thumb(look: look, side: 52, corner: 12)
                        .padding(.leading, 2)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(look.islandAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.trailing, 4)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.custom("PPNeueGstaad-CondensedRegular", size: 22, relativeTo: .headline))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        if let place = context.attributes.place {
                            Text(place)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Thumb(look: look, side: 24, corner: 6)
            } compactTrailing: {
                Text(context.state.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(look.islandAccent)
                    .lineLimit(1)
                    .frame(maxWidth: 76)
                    .minimumScaleFactor(0.7)
            } minimal: {
                Thumb(look: look, side: 24, corner: 12)
            }
            .widgetURL(look.link)
            .keylineTint(look.islandAccent)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// Colours and the photo for one activity, worked out once per render.
/// The card follows the app theme the way `ItemCard` does: the theme's
/// paper folded toward the save's colour, then lifted.
struct DayLook {
    let attributes: DayActivityAttributes
    let theme: ThemeSnapshot
    let accent: Color
    let photo: UIImage?

    init(_ attributes: DayActivityAttributes) {
        self.attributes = attributes
        theme = ThemeSnapshot.load()
        accent = attributes.colorHex.flatMap(Color.fromHex) ?? Color(red: 0.55, green: 0.5, blue: 0.4)
        photo = LivePhoto.load(attributes.itemID)
    }

    var card: Color {
        theme.paper
            .mix(with: accent, by: theme.isLight ? 0.16 : 0.32)
            .mix(with: theme.isLight ? .black : theme.ink, by: theme.isLight ? 0.05 : 0.06)
    }

    var ink: Color { theme.ink }

    /// The Dynamic Island is always black: the save's colour, lifted.
    var islandAccent: Color { accent.mix(with: .white, by: 0.4) }

    var glyph: String { attributes.kind == "place" ? "mappin.and.ellipse" : "ticket.fill" }

    var link: URL {
        URL(string: "canwego://item/\(attributes.itemID)") ?? URL(string: "canwego://")!
    }
}

struct DayActivityView: View {
    let context: ActivityViewContext<DayActivityAttributes>
    let look: DayLook
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small: small
        default: card
        }
    }

    /// Lock Screen and banner: the list card, photo melting in from the
    /// right.
    private var card: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(context.attributes.title)
                .font(.custom("PPNeueGstaad-CondensedRegular", size: 24, relativeTo: .title3))
                .foregroundStyle(look.ink)
                .lineLimit(2)
            if let place = context.attributes.place {
                Text(place)
                    .font(.subheadline)
                    .foregroundStyle(look.ink.opacity(0.65))
                    .lineLimit(1)
            }
            label
                .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .padding(.trailing, look.photo == nil ? 0 : 84)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .trailing) {
            if let photo = look.photo {
                Melt(photo: photo, card: look.card, ink: look.ink, isLight: look.theme.isLight)
            }
        }
    }

    /// Today-only days wear the cards' rose badge; the rest read as a
    /// quiet caption.
    @ViewBuilder
    private var label: some View {
        let urgent = ["Last day", "On today", "Opens today"].contains(context.state.label)
        if urgent {
            Text(context.state.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.red.mix(with: look.ink, by: 0.65))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.mix(with: look.card, by: 0.55), in: .capsule)
        } else {
            Text(context.state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(look.ink.opacity(0.65))
        }
    }

    /// Apple Watch Smart Stack and CarPlay.
    private var small: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(look.islandAccent)
                    .lineLimit(1)
                Text(context.attributes.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Thumb(look: look, side: 34, corner: 8)
        }
        .padding(8)
    }
}

/// The card's photo melt: the sharp photo fading in from the left, a
/// multiply pass pulling bright posters toward the card colour, and an
/// eased wash of the card on top. Same stops as `ItemCard`'s `MeltImage`,
/// minus the blurred underlay.
private struct Melt: View {
    let photo: UIImage
    let card: Color
    let ink: Color
    let isLight: Bool

    var body: some View {
        ZStack {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: 150)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.2), .init(color: .black, location: 0.8)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            LinearGradient(
                stops: [
                    .init(color: card, location: 0),
                    .init(color: card.mix(with: ink, by: isLight ? 0.06 : 0.5), location: 0.45),
                    .init(color: isLight ? card : .white, location: 0.95),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .blendMode(.multiply)
            LinearGradient(
                stops: [
                    .init(color: card, location: 0),
                    .init(color: card.opacity(0.95), location: 0.15),
                    .init(color: card.opacity(0.75), location: 0.3),
                    .init(color: card.opacity(0.45), location: 0.45),
                    .init(color: card.opacity(0.18), location: 0.6),
                    .init(color: card.opacity(0.05), location: 0.75),
                    .init(color: card.opacity(0), location: 0.9),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .compositingGroup()
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .clipped()
    }
}

/// The photo as a small rounded square, or the save's glyph without one.
private struct Thumb: View {
    let look: DayLook
    let side: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let photo = look.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: look.glyph)
                    .font(.system(size: side * 0.5, weight: .semibold))
                    .foregroundStyle(look.islandAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(look.accent.opacity(0.25))
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
    }
}
