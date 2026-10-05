import SwiftUI

/// Today's hours in the details' meta rows ("Open until 18:00"), opening
/// to the week on a tap. A quiet placeholder holds the line while they
/// load, so the rows below don't jump when they land.
struct HoursRow: View {
    let hours: OpeningHours?
    let loading: Bool
    @State private var expanded = false

    var body: some View {
        if let hours, let summary = hours.summary() {
            VStack(alignment: .leading, spacing: 8) {
                // A tap gesture rather than a Button: a button draws its
                // label a shade brighter than the plain meta rows around it.
                Label {
                    HStack(spacing: 5) {
                        Text(summary).foregroundStyle(.secondary)
                        if !hours.isClosed {
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                    }
                } icon: {
                    icon
                }
                .font(.subheadline)
                .contentShape(.rect)
                .onTapGesture {
                    guard !hours.isClosed else { return }
                    Haptics.tap()
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Opening hours: \(summary)")
                .accessibilityAddTraits(hours.isClosed ? [] : .isButton)
                .accessibilityHint(hours.isClosed ? "" : expanded ? "Hides the week" : "Shows the week")

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        week(hours)
                        Text("From Google Maps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28)
                    }
                    .transition(.opacity)
                }
            }
        } else if loading {
            Label {
                Text("Open until 18:00")
                    .foregroundStyle(.secondary)
                    .redacted(reason: .placeholder)
            } icon: {
                icon
            }
            .font(.subheadline)
            .accessibilityHidden(true)
        }
    }

    private var icon: some View {
        Image(systemName: "clock")
            .foregroundStyle(AppBackground.ink.opacity(0.45))
            .frame(width: 20)
    }

    private func week(_ hours: OpeningHours) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(Array(hours.upcoming().enumerated()), id: \.element.date) { index, day in
                GridRow {
                    Text(OpeningHours.dayName(day, index: index))
                        .fontWeight(index == 0 ? .semibold : .regular)
                    Text(OpeningHours.rangesText(day.ranges))
                        .foregroundStyle(day.ranges.isEmpty ? .tertiary : .secondary)
                }
            }
        }
        .font(.footnote)
        .monospacedDigit()
        // In line with the row's text, past the icon column.
        .padding(.leading, 28)
    }
}
