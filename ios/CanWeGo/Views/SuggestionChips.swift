import SwiftUI

/// A few things to go to in the home city, as glass chips wrapping to
/// centred rows. A tap opens the add sheet on the link and reads it, the
/// same as sharing it in.
struct SuggestionChips: View {
    let picks: [ParseClient.Suggestion]

    var body: some View {
        CentredFlow(spacing: 8) {
            ForEach(picks) { s in
                Button {
                    Self.open(s)
                } label: {
                    HStack(spacing: 5) {
                        Text(s.title)
                            .lineLimit(1)
                        if let when = Suggestions.when(s) {
                            Text(when)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    .font(.footnote.weight(.medium))
                }
                .buttonStyle(.glass)
                .accessibilityHint("Adds it to your library")
            }
        }
    }

    static func open(_ s: ParseClient.Suggestion) {
        Haptics.tap()
        CaptureGate.pendingLink = s.url
        NotificationCenter.default.post(name: .cwgCaptureImage, object: nil)
    }
}

/// Rows that wrap and centre, each child no wider than the row.
struct CentredFlow: Layout {
    var spacing: CGFloat = 8

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
            var x = bounds.minX + (bounds.width - row.width) / 2
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
