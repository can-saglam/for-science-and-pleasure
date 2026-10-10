import SwiftUI

/// A few things to go to in the home city, as glass chips wrapping to
/// centred rows. A tap opens the add sheet on the link and reads it, the
/// same as sharing it in.
struct SuggestionChips: View {
    let picks: [ParseClient.Suggestion]

    var body: some View {
        CentredFlow(spacing: 8) {
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

/// One city pick as a glass chip: a ticket or pin, the title, and an
/// event's dates. Ticked, it turns solid ink with the page colour for
/// text. The venue only goes to VoiceOver, to keep chips one line.
struct PickChip: View {
    let pick: ParseClient.Suggestion
    var on = false
    let hint: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark" : pick.kind == Item.Kind.event ? "ticket" : "mappin.and.ellipse")
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
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(hint)
    }

    /// "BFI Southbank, until 18 Oct".
    private var spoken: String {
        let venue = pick.venue.flatMap { $0 == pick.title || $0.isEmpty ? nil : $0 }
        return [pick.title, venue, Suggestions.when(pick)].compactMap(\.self).joined(separator: ", ")
    }
}

/// Rows that wrap and centre (or start at the left), each child no wider
/// than the row.
struct CentredFlow: Layout {
    var spacing: CGFloat = 8
    var leading = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(width: width, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (leading ? 0 : (bounds.width - row.width) / 2)
            for (index, size) in row.items {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            size.width = min(size.width, width)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
