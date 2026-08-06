import SwiftData
import SwiftUI

/// The journal: things marked done ("Been") and dated things that slipped
/// past ("Missed"), grouped by month.
struct WeDidGoView: View {
    private enum Side: String, CaseIterable {
        case been = "Been"
        case missed = "Missed"
    }

    @Environment(\.modelContext) private var context
    @Query private var items: [Item]
    @State private var side: Side = .been
    @State private var selected: Item?

    private var been: [(String, [Item])] {
        let done = items
            .filter(\.isDone)
            .sorted { $0.updatedAt > $1.updatedAt }
        return groupByMonth(done) { $0.updatedAt }
    }

    private var missed: [(String, [Item])] {
        let past = items
            .filter { $0.isMissed && $0.endsOn != nil }
            .sorted { ($0.endsOn ?? "") > ($1.endsOn ?? "") }
        return groupByMonth(past) { DayString.date($0.endsOn ?? "") ?? $0.updatedAt }
    }

    private func groupByMonth(
        _ list: [Item],
        dateOf: (Item) -> Date
    ) -> [(String, [Item])] {
        var order: [String] = []
        var groups: [String: [Item]] = [:]
        for item in list {
            let key = dateOf(item).formatted(.dateTime.month(.wide).year())
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                let months = side == .been ? been : missed
                ForEach(Array(months.enumerated()), id: \.element.0) { m, month in
                    SectionHeader(title: month.0, count: month.1.count)
                        .cardListRow()
                    ForEach(Array(month.1.enumerated()), id: \.element.id) { i, item in
                        ItemCardRow(item: item, index: m * 3 + i, compact: true) {
                            selected = item
                        }
                    }
                }
                if months.isEmpty {
                    ContentUnavailableView(
                        side == .been ? "Nothing here yet" : "Nothing missed",
                        systemImage: "shoeprints.fill",
                        description: Text(
                            side == .been
                                ? "Go somewhere, then mark it done."
                                : "You're keeping up."
                        )
                    )
                    .padding(.top, 60)
                    .cardListRow()
                }
            }
            .listStyle(.plain)
            .refreshable { await SupabaseSync.sync(context: context) }
            // Room at the end so the last row clears the floating add button.
            .contentMargins(.bottom, 90, for: .scrollContent)
            .cascadeRoot()
            .appBackground(AppBackground.weDidGo)
            .navigationTitle("We Did Go")
            .navigationBarTitleDisplayMode(.inline)
            .logoTitle()
            .settingsToolbar()
            // Been/Missed sits full-width just above the list — the
            // wordmark has the title slot.
            .safeAreaInset(edge: .top) {
                Picker("Side", selection: $side.animation(.snappy)) {
                    ForEach(Side.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .sensoryFeedback(.selection, trigger: side)
            }
            .sheet(item: $selected) { ItemDetailView(item: $0) }
        }
    }
}
