import SwiftUI

/// The home city's few under the add page's question (and the first-save
/// page's): things on soon and places, from the same pool as the empty
/// library tabs, as glass chips that wrap from the left. On the add page a tap looks it up straight away; on the
/// first-save page (`ticked` set) a tap ticks it (the chip turns solid)
/// to save with the rest. Nothing at all without a city, or with an
/// empty pool that isn't loading.
struct Recommendations: View {
    let city: String?
    let picks: [ParseClient.Suggestion]
    var loading = false
    /// The ticked picks' ids, when chips tick instead of opening.
    var ticked: Set<String>? = nil
    let onPick: (ParseClient.Suggestion) -> Void

    var body: some View {
        if let city, !picks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Worth going to in \(city)")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
                CentredFlow(spacing: 8, leading: true) {
                    ForEach(picks) { chip($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        } else if loading, let city {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up a few things in \(city)…")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
            }
            .transition(.opacity)
        }
    }

    /// Glass until ticked, then solid ink with the page colour for text.
    /// Events keep their dates on the chip; the venue only goes to
    /// VoiceOver, to keep chips one line.
    private func chip(_ pick: ParseClient.Suggestion) -> some View {
        let on = ticked?.contains(pick.id) == true
        let icon = on ? "checkmark" : pick.kind == Item.Kind.event ? "ticket" : "mappin.and.ellipse"
        return Button {
            Haptics.tap()
            onPick(pick)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(pick.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let when = Suggestions.when(pick) {
                    Text(when)
                        .font(.caption2)
                        .opacity(0.72)
                        .fixedSize()
                }
            }
            .foregroundStyle(on ? AppBackground.base : AppBackground.ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(on ? AppBackground.ink : .clear, in: .capsule)
            .glassEffect(on ? .identity : .regular.interactive(), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: on)
        .accessibilityLabel(Self.spoken(pick))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(ticked == nil ? "Looks it up and makes the card" : "Saves it with your first saves")
    }

    /// "BFI Southbank, until 18 Oct".
    private static func spoken(_ pick: ParseClient.Suggestion) -> String {
        let venue = pick.venue.flatMap { $0 == pick.title || $0.isEmpty ? nil : $0 }
        return [pick.title, venue, Suggestions.when(pick)].compactMap(\.self).joined(separator: ", ")
    }
}

extension Item {
    /// What a recommendation already knows, for the capture drawer to
    /// show while the parser reads its page, or a first save to start from.
    convenience init(suggestion: ParseClient.Suggestion) {
        self.init()
        kind = suggestion.kind
        title = suggestion.title
        venue = suggestion.venue
        startsOn = suggestion.startsOn
        endsOn = suggestion.endsOn
        url = suggestion.url
    }

    /// Everything a lookup found, over whatever was there.
    func take(_ card: ParseClient.Card) {
        kind = card.kind
        title = card.title
        summary = card.summary
        venue = card.venue
        area = card.area
        address = card.address
        category = card.category
        price = card.price
        startsOn = card.starts_on
        endsOn = card.ends_on
        url = card.url ?? url
        lat = card.lat
        lng = card.lng
        colorHex = card.color
        imageUrl = card.image_url
        source = card.source
        placeId = card.place_id
        showings = card.showings ?? []
    }
}
