import SwiftUI

/// The home city's few under the add page's question (and the first-save
/// page's): two things on soon and a place, from the same pool as the
/// empty library tabs, in the display type. A tap looks it up straight
/// away. Nothing at all without a city, or with an empty pool that
/// isn't loading.
struct Recommendations: View {
    let city: String?
    let picks: [ParseClient.Suggestion]
    var loading = false
    let onPick: (ParseClient.Suggestion) -> Void

    var body: some View {
        if let city, !picks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Or try one of these in \(city)")
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
        Button {
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
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Looks it up and makes the card")
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
    /// show while the parser reads its page.
    convenience init(suggestion: ParseClient.Suggestion) {
        self.init()
        kind = suggestion.kind
        title = suggestion.title
        venue = suggestion.venue
        startsOn = suggestion.startsOn
        endsOn = suggestion.endsOn
        url = suggestion.url
    }
}
