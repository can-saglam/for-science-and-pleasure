import SwiftUI

/// The home city's few under the add page's question (and the first-save
/// page's): things on soon and places, from the same pool as the empty
/// library tabs, in the display type. On the add page a tap looks it up
/// straight away; on the first-save page (`ticked` set) a tap ticks it to
/// save with the rest. Nothing at all without a city, or with an empty
/// pool that isn't loading.
struct Recommendations: View {
    let city: String?
    let picks: [ParseClient.Suggestion]
    var loading = false
    /// The ticked picks' ids, when rows tick instead of opening.
    var ticked: Set<String>? = nil
    let onPick: (ParseClient.Suggestion) -> Void

    var body: some View {
        if let city, !picks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(ticked == nil ? "Or try one of these in \(city)" : "Or pick a few in \(city)")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
                    .padding(.bottom, 4)
                ForEach(Array(picks.enumerated()), id: \.element.id) { index, pick in
                    if index > 0 {
                        Divider().overlay(AppBackground.ink.opacity(0.12))
                    }
                    row(pick)
                }
            }
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

    private func row(_ pick: ParseClient.Suggestion) -> some View {
        let on = ticked?.contains(pick.id) == true
        return Button {
            Haptics.tap()
            onPick(pick)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: pick.kind == Item.Kind.event ? "ticket" : "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(AppBackground.ink.opacity(0.55))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.title)
                        .font(.displaySmallBold(20, relativeTo: .headline))
                        .foregroundStyle(AppBackground.ink)
                        .lineLimit(1)
                    if let detail = Self.detail(pick) {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(AppBackground.secondaryInk)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if ticked != nil {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.title3.weight(on ? .semibold : .regular))
                        .foregroundStyle(AppBackground.ink.opacity(on ? 1 : 0.4))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(ticked == nil ? "Looks it up and makes the card" : "Saves it with your first saves")
    }

    /// "BFI Southbank · until 18 Oct".
    private static func detail(_ pick: ParseClient.Suggestion) -> String? {
        let venue = pick.venue.flatMap { $0 == pick.title || $0.isEmpty ? nil : $0 }
        let parts = [venue, Suggestions.when(pick)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
