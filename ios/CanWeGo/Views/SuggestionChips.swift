import SwiftUI

/// A few things to go to in the home city, in one row that scrolls
/// sideways. A tap opens the add sheet on the link and reads it, the same
/// as sharing it in.
struct SuggestionChips: View {
    let picks: [ParseClient.Suggestion]
    /// Set while the city's events are still being searched for.
    var finding: String? = nil

    var body: some View {
        PickStrip {
            if let finding { FindingChip(city: finding) }
            ForEach(picks) { s in
                PickChip(pick: s, hint: "Adds it to your library") { Self.open(s) }
            }
        }
    }

    static func open(_ s: ParseClient.Suggestion) {
        CaptureGate.pendingLink = s.url
        NotificationCenter.default.post(name: .cwgCaptureImage, object: nil)
    }
}

/// Where a new city's events will be, while they're searched for: a chip
/// the size of the others, so the row doesn't look empty or broken, and
/// takes its place when they arrive.
struct FindingChip: View {
    let city: String

    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 56

    var body: some View {
        HStack(spacing: 11) {
            ProgressView()
                .controlSize(.small)
                .tint(AppBackground.secondaryInk)
                .frame(width: side * 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finding what's on in \(city)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppBackground.ink)
                Text("Takes a minute or two")
                    .font(.caption)
                    .foregroundStyle(AppBackground.secondaryInk)
            }
            .lineLimit(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(minHeight: side)
        .frame(maxWidth: 300, alignment: .leading)
        .background(AppBackground.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppBackground.ink.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finding what's on in \(city). Takes a minute or two.")
    }
}

/// One row of picks that scrolls sideways, chip by chip, and runs on past
/// its container to the screen's edges.
struct PickStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) { content() }
                .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }
}

/// One city pick as a small card: its picture melting in from the left
/// edge the way a saved card's does from the right, the title, then when
/// and where. Tinted from the picture's colour, like a card. Ticked, it
/// takes an ink outline and a check over the picture.
struct PickChip: View {
    let pick: ParseClient.Suggestion
    var on = false
    let hint: String
    let action: () -> Void

    /// The chip's height, and where the text starts: the photo stays
    /// sharp across about this much before it fades under the text.
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 56
    @State private var photo: (sharp: UIImage, blurred: UIImage)?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    private var accent: Color {
        pick.color.flatMap(Color.init(hex:)) ?? Item.fallbackAccent(pick.url)
    }

    private var url: URL? { pick.image.flatMap(URL.init(string:)) }

    private var detail: String? {
        let parts = [Suggestions.when(pick), Suggestions.shared.whereText(pick)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    init(pick: ParseClient.Suggestion, on: Bool = false, hint: String, action: @escaping () -> Void) {
        self.pick = pick
        self.on = on
        self.hint = hint
        self.action = action
        if let url = pick.image.flatMap(URL.init(string:)), let sharp = ImageStore.cached(url) {
            _photo = State(initialValue: (sharp, ImageStore.cachedMelt(url) ?? sharp))
        }
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 0) {
                picture
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.shortTitle ?? pick.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppBackground.ink)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(AppBackground.secondaryInk)
                    }
                }
                .lineLimit(1)
                .padding(.trailing, 14)
            }
            .frame(minHeight: side)
            .frame(maxWidth: 300, alignment: .leading)
            .background(alignment: .leading) {
                if let photo {
                    MeltLayers(sharp: photo.sharp, blurred: photo.blurred, cardBackground: tint, width: meltWidth, photoLeading: true)
                        .frame(width: meltWidth)
                        .accessibilityHidden(true)
                }
            }
            .background(tint, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(on ? AppBackground.ink : ItemCard.border(accent), lineWidth: on ? 2 : 1)
            }
            // The press dims the chip as one picture; dimmed layer by
            // layer, the melt's photo shows through its own wash.
            .compositingGroup()
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: on)
        .task(id: url) {
            guard let url, photo == nil, let pair = await ImageStore.meltPair(url) else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { photo = pair }
        }
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(hint)
    }

    private var tint: Color { ItemCard.background(accent) }

    /// The melt runs a little under the text, as a card's does, but is
    /// mostly washed out by the first letter so a poster's own lettering
    /// can't fight the title.
    private var meltWidth: CGFloat { side * 1.6 }

    /// The space the photo keeps clear at the leading edge: the ticket or
    /// pin when there's no photo, and the check once ticked.
    private var picture: some View {
        ZStack {
            if photo == nil {
                Image(systemName: pick.kind == Item.Kind.event ? "ticket" : "mappin.and.ellipse")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppBackground.secondaryInk)
            }
            if on {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(AppBackground.base, AppBackground.ink)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: photo == nil ? side * 0.8 : side + 8, height: side)
        .accessibilityHidden(true)
    }

    /// "Pitchfork Music Festival London 2026, All over London, 2–8 Nov".
    private var spoken: String {
        [pick.title, Suggestions.shared.whereText(pick), Suggestions.when(pick)].compactMap(\.self).joined(separator: ", ")
    }
}
