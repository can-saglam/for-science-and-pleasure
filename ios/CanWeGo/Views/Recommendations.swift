import SwiftUI

/// The home city's few under the add page's question (and the first-save
/// page's): things on soon and places, from the same pool as the empty
/// library tabs, as glass chips that wrap from the left. On the add page
/// a tap looks it up straight away; on the first-save page (`ticked` set)
/// a tap ticks it (the chip turns solid) to save with the rest. Nothing at all without a city, or with an
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
                Text("Or try one of these")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(AppBackground.secondaryInk.opacity(0.6))
                CentredFlow(spacing: 8, leading: true) {
                    ForEach(picks) { pick in
                        PickChip(
                            pick: pick,
                            on: ticked?.contains(pick.id) == true,
                            hint: ticked == nil ? "Looks it up and makes the card" : "Saves it with your first saves"
                        ) { onPick(pick) }
                    }
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
