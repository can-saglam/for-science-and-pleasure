import SwiftData
import SwiftUI

/// Full list of active saves for one kind, closing-soonest first —
/// undated items (most places) fall to the bottom, newest first.
struct LibraryView: View {
    let kind: String

    @Environment(\.modelContext) private var context
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @State private var query = ""
    @State private var category: String?
    @State private var selected: Item?
    @State private var showMap = false

    private var base: [Item] {
        items.filter { $0.kind == kind && !$0.isDone && !$0.isMissed }
    }

    private var categories: [String] {
        var counts: [String: Int] = [:]
        for item in base {
            if let c = item.category?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
                counts[c, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    private var visible: [Item] {
        var list = base
        if let category {
            list = list.filter {
                $0.category?.trimmingCharacters(in: .whitespaces) == category
            }
        }
        if !query.isEmpty {
            list = list.filter {
                [$0.title, $0.venue, $0.area, $0.notes, $0.summary]
                    .compactMap(\.self)
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        // Swift's sort is not stable, so ties need an explicit tie-break or
        // equal items shuffle every time the list recomputes (e.g. on filter).
        return list.sorted { a, b in
            switch (a.daysUntilClose, b.daysUntilClose) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.createdAt > b.createdAt
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if showMap {
                    MapPinsView(items: visible) { selected = $0 }
                } else {
                    list
                }
            }
            .navigationTitle(kind == Item.Kind.place ? "Places" : "Events")
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
            // CWG_OPEN / CWG_CHIP are only set by automated screenshot runs;
            // they deep-open an item / preselect a chip and do nothing otherwise.
            .task {
                // One coarse location fix so place cards can show distance.
                if kind == Item.Kind.place {
                    LocationStore.shared.refresh()
                }
                let env = ProcessInfo.processInfo.environment
                if let probe = env["CWG_OPEN"],
                   let match = visible.first(where: { $0.title.localizedCaseInsensitiveContains(probe) }) {
                    selected = match
                }
                if let chip = env["CWG_CHIP"] {
                    category = categories.first { $0.localizedCaseInsensitiveContains(chip) }
                }
                if env["CWG_MAP"] != nil { showMap = true }
            }
        }
    }

    private var list: some View {
        List {
            if categories.count > 1 {
                chipRow
                    .cardListRow()
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, item in
                ItemCardRow(item: item, index: i) { selected = item }
            }
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(
                        base.isEmpty ? "Nothing saved yet" : "Nothing matches",
                        systemImage: kind == Item.Kind.place ? "mappin.and.ellipse" : "books.vertical"
                    )
                } description: {
                    Text(
                        base.isEmpty
                            ? "Anything you two save lands here."
                            : "Try a different word, or clear the filters."
                    )
                } actions: {
                    if category != nil || !query.isEmpty {
                        Button("Clear filters") {
                            Haptics.tap()
                            withAnimation(.snappy) {
                                category = nil
                                query = ""
                            }
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.top, 40)
                .cardListRow()
            }
        }
        .listStyle(.plain)
        // Attached to the list, not the tab — the map doesn't need it.
        .searchable(text: $query)
        .refreshable { await SupabaseSync.sync(context: context) }
        // The search bar leaves a big default gap above the first row.
        .contentMargins(.top, 4, for: .scrollContent)
        // Room at the end so the last card clears the floating add button.
        .contentMargins(.bottom, 90, for: .scrollContent)
        .cascadeRoot()
        .appBackground(kind == Item.Kind.place ? AppBackground.places : AppBackground.library)
    }

    /// Liquid Glass filter chips — the one custom control layer here.
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { c in
                        Button {
                            Haptics.selection()
                            withAnimation(.snappy) {
                                category = category == c ? nil : c
                            }
                        } label: {
                            Text(c.capitalized)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        // Explicit colors: the system styles both resolve
                        // near-white here, leaving white text on white glass.
                        .foregroundStyle(category == c ? AppBackground.base : .white)
                        .glassEffect(
                            category == c
                                ? .regular.tint(.white.opacity(0.92)).interactive()
                                : .regular.interactive(),
                            in: .capsule
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollClipDisabled()
    }
}
