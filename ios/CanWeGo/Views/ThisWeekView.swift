import SwiftData
import SwiftUI

/// Urgency-first view of active events: what's about to close, what's on,
/// what's about to open.
struct ThisWeekView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @State private var selected: Item?
    @State private var showMap = false

    private var active: [Item] {
        items.filter { $0.isEvent && !$0.isDone && !$0.isMissed }
    }

    private var lastChance: [Item] {
        active
            .filter { $0.timeBucket == .lastChance && !$0.isOneDay }
            .sorted { ($0.daysUntilClose ?? 99) < ($1.daysUntilClose ?? 99) }
    }

    /// Running, with the end in sight (within three weeks) — same tier as
    /// the web app's "Closing soon".
    private var closingSoon: [Item] {
        active
            .filter {
                $0.timeBucket == .now && !$0.isOneDay && ($0.daysUntilClose ?? 99) <= 21
            }
            .sorted { ($0.daysUntilClose ?? 99) < ($1.daysUntilClose ?? 99) }
    }

    private var oneOffs: [Item] {
        active
            .filter { $0.isOneDay && ($0.daysUntilStart ?? -1) >= 0 && ($0.daysUntilStart ?? 99) <= 7 }
            .sorted { ($0.startsOn ?? "") < ($1.startsOn ?? "") }
    }

    private var opening: [Item] {
        active
            .filter { $0.timeBucket == .upcoming && !$0.isOneDay && ($0.daysUntilStart ?? 99) <= 7 }
            .sorted { ($0.daysUntilStart ?? 99) < ($1.daysUntilStart ?? 99) }
    }

    /// Everything else that's simply on — running with no imminent end, or
    /// undated. The full list, closing-soonest first, endless ones oldest-
    /// saved first so early finds resurface.
    private var onNow: [Item] {
        active
            .filter {
                ($0.timeBucket == .now && ($0.daysUntilClose ?? 99) > 21)
                    || $0.timeBucket == .undated
            }
            .sorted { a, b in
                switch (a.daysUntilClose, b.daysUntilClose) {
                case let (x?, y?): x < y
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): a.createdAt < b.createdAt
                }
            }
    }

    private var everything: [Item] {
        lastChance + closingSoon + oneOffs + opening + onNow
    }

    var body: some View {
        NavigationStack {
            Group {
                if showMap {
                    MapPinsView(items: everything) { selected = $0 }
                } else {
                    list
                }
            }
            .navigationTitle("This Week")
            // Inline title row carries the wordmark instead of text.
            .navigationBarTitleDisplayMode(.inline)
            .logoTitle()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy) { showMap.toggle() }
                    } label: {
                        Image(systemName: showMap ? "list.bullet" : "map")
                    }
                    .accessibilityLabel(showMap ? "Show list" : "Show map")
                }
            }
            .settingsToolbar()
            .sheet(item: $selected) { ItemDetailView(item: $0) }
        }
    }

    private var list: some View {
        List {
            // Urgency highlights up top; the full ongoing list below.
            cardSection("Last chance", items: lastChance, offset: 0)
            cardSection(
                "Closing soon", items: closingSoon,
                offset: lastChance.count
            )
            cardSection(
                "Happening this week", items: oneOffs,
                offset: lastChance.count + closingSoon.count
            )
            cardSection(
                "Just opening", items: opening,
                offset: lastChance.count + closingSoon.count + oneOffs.count
            )
            cardSection(
                "On now", items: onNow,
                offset: lastChance.count + closingSoon.count + oneOffs.count + opening.count
            )

            if everything.isEmpty {
                ContentUnavailableView(
                    "Nothing pressing",
                    systemImage: "paintpalette",
                    description: Text("Save something and it'll surface here when its window opens.")
                )
                .padding(.top, 60)
                .cardListRow()
            }
        }
        .listStyle(.plain)
        .refreshable { await SupabaseSync.sync(context: context) }
        // Room at the end so the last card clears the floating add button.
        .contentMargins(.bottom, 90, for: .scrollContent)
        .cascadeRoot()
        .appBackground(AppBackground.thisWeek)
    }

    @ViewBuilder
    private func cardSection(_ title: String, items: [Item], offset: Int) -> some View {
        if !items.isEmpty {
            SectionHeader(title: title, count: items.count)
                .cardListRow()
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                ItemCardRow(item: item, index: offset + i) { selected = item }
            }
        }
    }
}
