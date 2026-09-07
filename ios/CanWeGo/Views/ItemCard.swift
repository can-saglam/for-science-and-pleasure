import CoreLocation
import SwiftUI

/// The signature look carried over from the web app: every save wears a
/// gentle wash of its dominant color. Content stays plain; the tint does
/// the talking.
struct ItemCard: View {
    let item: Item
    /// Journal-density variant for We Did Go.
    var compact = false
    /// Context-specific meta line (the digest's "Closes Fri 29 Aug · venue")
    /// — replaces both the subtitle and the countdown label.
    var meta: String? = nil

    private var subtitle: String {
        if let meta { return meta }
        return ([cleanVenue, cleanArea, distance].compactMap(\.self))
            .joined(separator: " · ")
    }

    /// Lowercased alphanumerics only — for fuzzy redundancy checks like
    /// "Satos Kitchen Brixton" vs "Sato's Kitchen" + "Brixton".
    private func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Parsed data occasionally lands a URL in venue/area — never show it.
    private func looksLikeURL(_ s: String) -> Bool {
        s.contains("://") || s.hasPrefix("www.")
            || (s.contains("/") && s.contains(".") && !s.contains(" "))
    }

    private var cleanVenue: String? {
        guard let venue = item.venue?.trimmingCharacters(in: .whitespaces),
              !venue.isEmpty, !looksLikeURL(venue)
        else { return nil }
        let v = normalized(venue)
        // Venue that just restates the title (with or without the area
        // tacked on) adds nothing.
        if v == normalized(item.title) { return nil }
        if let area = item.area, v == normalized(item.title) + normalized(area) { return nil }
        return venue
    }

    private var cleanArea: String? {
        guard let area = item.area?.trimmingCharacters(in: .whitespaces),
              !area.isEmpty, !looksLikeURL(area),
              normalized(area) != normalized(item.title)
        else { return nil }
        // "Bara Café · Peckham" is good; "Satos Kitchen Brixton · Brixton"
        // is not — skip the area when the venue already names it.
        if let venue = cleanVenue, normalized(venue).contains(normalized(area)) { return nil }
        return area
    }

    /// "1.2 km" for places, when we know where the user is. Quietly absent
    /// otherwise (no permission, no fix, or absurd distances while abroad).
    private var distance: String? {
        guard item.isPlace, !item.isDone, let coord = item.coordinate,
              let here = LocationStore.shared.location
        else { return nil }
        let meters = here.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        guard meters < 100_000 else { return nil }
        if meters < 950 { return "\(Int((meters / 50).rounded() * 50)) m" }
        return String(format: "%.1f km", meters / 1000)
    }

    /// Quiet nudge for undated events — the one gap that actually hides an
    /// item from the calendar and digest. A missing pin is often deliberate
    /// (festivals across town), so it gets no badge.
    private var hints: [String] {
        guard !item.isDone, !compact, meta == nil else { return [] }
        if item.isEvent && item.startsOn == nil && item.endsOn == nil {
            return ["needs a date"]
        }
        return []
    }

    private var radius: CGFloat { compact ? 14 : 18 }

    /// Settings can switch thumbnails off, restoring the pre-thumbnail card.
    @AppStorage("cardThumbnails", store: UserDefaults(suiteName: SharedInbox.groupID))
    private var thumbnailsOn = true

    private var imageURL: URL? {
        guard thumbnailsOn, !compact else { return nil }
        return item.imageUrl.flatMap(URL.init(string:))
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    /// At accessibility text sizes the countdown can't share a line with
    /// the title — it moves below, the way it already does beside a photo.
    private var stackedTimeLabel: Bool {
        imageURL != nil || typeSize.isAccessibilitySize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.title)
                    .font(compact ? .subheadline.weight(.medium) : .body.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    // Big type wraps rather than clips: a truncated title is
                    // a missing title to someone reading at that size.
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                // With a thumbnail bleeding in from the right, the countdown
                // moves down beside the subtitle so titles keep their room.
                if !stackedTimeLabel && meta == nil {
                    Spacer(minLength: 6)
                    if let label = item.timeLabel {
                        timeText(label)
                    }
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            }
            if stackedTimeLabel, meta == nil, let label = item.timeLabel {
                timeText(label)
                    .padding(.top, 1)
            }
            if !hints.isEmpty {
                Text(hints.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, compact ? 14 : 16)
        .padding(.vertical, compact ? 10 : 13)
        // Keep text clear of the visible part of the photo.
        .padding(.trailing, imageURL == nil ? 0 : 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .trailing) {
            if let imageURL {
                bleedImage(imageURL)
                    // Decorative: the text already says everything it shows.
                    .accessibilityHidden(true)
            }
        }
        .background(cardBackground, in: .rect(cornerRadius: radius, style: .continuous))
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
        .contentShape(.rect(cornerRadius: radius, style: .continuous))
        // One sentence per card for VoiceOver, in reading order, instead of
        // three separate stops with the countdown detached from its title.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [item.title]
        if !subtitle.isEmpty { parts.append(subtitle) }
        if meta == nil, let label = item.timeLabel { parts.append(label) }
        if item.isDone { parts.append("We did go") }
        parts.append(contentsOf: hints)
        return parts.joined(separator: ". ")
    }

    /// Urgent labels wear a quiet rose badge — folded toward the card color
    /// so it belongs to the theme, instead of a raw system red.
    @ViewBuilder
    private func timeText(_ label: String) -> some View {
        if item.timeLabelIsUrgent {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.red.mix(with: .white, by: 0.65))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Color.red.mix(with: cardBackground, by: 0.55),
                    in: .capsule
                )
        } else {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        }
    }

    /// The source photo bleeding in from the card's right edge, dissolving
    /// into the card color so text never fights it. Dead URLs show nothing.
    ///
    /// Three layers make the melt: a blurred copy of the photo underneath
    /// (so sharp poster edges soften before they fade instead of ghosting
    /// through), the sharp photo fading in over it, and an eased wash of
    /// the card color on top. The blur is baked once per image off the main
    /// thread — a live `.blur` on every card was the priciest GPU pass in
    /// every scrolled frame.
    private func bleedImage(_ url: URL) -> some View {
        MeltImage(url: url, cardBackground: cardBackground)
    }

    // Cards live on the theme base: fold the accent into it and lift it
    // slightly, so every card reads as a tinted panel of the same material
    // rather than a foreign swatch. Mix amounts are tuned per theme.
    private var cardBackground: Color {
        AppBackground.base
            .mix(with: item.accentColor, by: AppBackground.theme.cardAccentMix)
            .mix(with: .white, by: AppBackground.theme.cardWhiteLift)
    }

    private var cardBorder: Color {
        item.accentColor.mix(with: .white, by: 0.4).opacity(0.30)
    }
}

/// The card's photo melt, from pre-baked pixels: the blurred underlay comes
/// out of `ImageStore` already rendered, so a scrolled frame composites four
/// cheap layers instead of running a Gaussian blur per card.
private struct MeltImage: View {
    let url: URL
    let cardBackground: Color

    @State private var sharp: UIImage?
    @State private var blurred: UIImage?
    /// Which URL the pair belongs to — rows get recycled with new URLs.
    @State private var loaded: URL?

    init(url: URL, cardBackground: Color) {
        self.url = url
        self.cardBackground = cardBackground
        // Memory-only lookups: cold-launch prewarm makes these land without
        // a main-thread disk read.
        if let hit = ImageStore.cached(url) {
            _sharp = State(initialValue: hit)
            _blurred = State(initialValue: ImageStore.cachedMelt(url) ?? hit)
            _loaded = State(initialValue: url)
        }
    }

    var body: some View {
        ZStack {
            if let sharp, let blurred {
                filled(Image(uiImage: blurred))
                filled(Image(uiImage: sharp))
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.25),
                                .init(color: .black, location: 0.8),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                // Multiply pulls bright content toward the card color in
                // the melt zone — white posters tint instead of glaring —
                // and leaves the photo untouched at the right edge.
                LinearGradient(
                    stops: [
                        .init(color: cardBackground, location: 0),
                        .init(color: cardBackground.mix(with: .white, by: 0.5), location: 0.45),
                        .init(color: .white, location: 0.95),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .blendMode(.multiply)
                LinearGradient(
                    stops: [
                        .init(color: cardBackground, location: 0),
                        .init(color: cardBackground.opacity(0.95), location: 0.15),
                        .init(color: cardBackground.opacity(0.75), location: 0.3),
                        .init(color: cardBackground.opacity(0.45), location: 0.45),
                        .init(color: cardBackground.opacity(0.18), location: 0.6),
                        .init(color: cardBackground.opacity(0.05), location: 0.75),
                        .init(color: cardBackground.opacity(0), location: 0.9),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .compositingGroup()
        .frame(width: 150)
        .clipped()
        .task(id: url) {
            guard loaded != url else { return }
            guard let pair = await ImageStore.meltPair(url) else { return }
            sharp = pair.sharp
            blurred = pair.blurred
            loaded = url
        }
    }

    private func filled(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: 150)
            .clipped()
    }
}

/// Things-style tactility: cards settle slightly under the finger,
/// with a soft haptic tick on touch-down.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.28), value: configuration.isPressed)
    }
}

extension View {
    /// Card rows inside a plain List: invisible chrome, our own spacing.
    func cardListRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(.init(top: 5, leading: 20, bottom: 5, trailing: 20))
    }
}

/// A card in a list: tap to open, swipe right to mark done, swipe left to
/// delete, long-press for quick actions.
struct ItemCardRow: View {
    let item: Item
    var compact = false
    let onOpen: () -> Void

    @Environment(\.modelContext) private var context
    @State private var celebrate = 0
    /// A rendered postcard of this save, on its way to the share sheet.
    @State private var shareCard: ShareCard.Rendered?

    var body: some View {
        // Haptic fires with the action, not the press state — quick taps in
        // a scrolling list often never register as "pressed".
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            ItemCard(item: item, compact: compact)
        }
        .buttonStyle(PressableCardStyle())
        .cardListRow()
        // The swipe gestures, spoken: VoiceOver's rotor gets the same three
        // actions a sighted thumb has.
        .accessibilityHint("Opens the details")
        .accessibilityAction(named: item.isDone ? "Put back in the library" : "We did go") {
            if item.isDone {
                item.putBack()
            } else {
                celebrate += 1
                item.markDone()
                UndoBin.shared.stashDone(item)
            }
        }
        .accessibilityAction(named: "Delete") { delete() }
        // No full swipe: a firm scroll-adjacent drag was enough to silently
        // mark an event done (see: Carnival, 7:13am, nobody remembers doing
        // it). The swipe now only reveals the button; done takes a real tap.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if item.isDone {
                Button {
                    Haptics.tap()
                    item.putBack()
                } label: {
                    Label("Put back", systemImage: "arrow.uturn.backward")
                }
                .tint(AppBackground.swipePutBack)
            } else {
                Button {
                    celebrate += 1
                    item.markDone()
                    UndoBin.shared.stashDone(item)
                } label: {
                    Label("We did go!", systemImage: "checkmark")
                }
                .tint(AppBackground.swipeDone)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(AppBackground.swipeDelete)
        }
        .contextMenu {
            if item.isDone {
                Button {
                    Haptics.tap()
                    item.putBack()
                } label: {
                    Label("Put back in the library", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button {
                    celebrate += 1
                    item.markDone()
                    UndoBin.shared.stashDone(item)
                } label: {
                    Label("We did go!", systemImage: "checkmark")
                }
            }
            if let maps = item.directionsURL {
                Link(destination: maps) {
                    Label("Open in \(TransportApp.current.name)", systemImage: "map")
                }
            }
            if let url = item.url.flatMap(URL.init(string:)) {
                Link(destination: url) {
                    Label("Open source", systemImage: "arrow.up.right")
                }
            }
            Button {
                Haptics.tap()
                Task { shareCard = await ShareCard.render(item) }
            } label: {
                Label("Share as image", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                delete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .sensoryFeedback(.success, trigger: celebrate)
        .sheet(item: $shareCard) { card in
            ActivitySheet(items: [card.image])
                .presentationDetents([.medium, .large])
        }
    }

    /// Deletion always leaves a five-second Undo behind (toast in ContentView).
    private func delete() {
        Haptics.tap()
        UndoBin.shared.stash(item.snapshot)
        SupabaseSync.setDeleted(item.id, true)
        context.delete(item)
        try? context.save()
    }
}

/// Muted section headers shared by the card lists.
struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let count {
                Text("\(count)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
