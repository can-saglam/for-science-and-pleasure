import SwiftData
import SwiftUI

/// Map-or-list, shared by the Events and Places tabs: switch to the map on
/// one and the other stays on the map, so geographic browsing carries
/// across without flipping back to the list.
@Observable
final class ViewMode {
    static let shared = ViewMode()
    var showMap = false
}

/// One tab per kind, carrying the whole story of that kind.
///
/// Events lead with urgency — what's about to close, what's happening,
/// what's opening — then everything simply on, then what's still to come.
/// Places keep their hand-arranged list. Both end with the journal:
/// Been, then Missed.
struct LibraryView: View {
    let kind: String

    @Environment(\.modelContext) private var context
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @State private var query = ""
    @State private var category: String?
    @State private var area: String?
    @State private var selected: Item?
    /// Shared across the Events and Places tabs: flipping to the map on one
    /// keeps the other on the map too, so browsing both by geography flows.
    private var mode: ViewMode { .shared }
    @State private var searchOpen = false
    @State private var searchOpenedAt = Date.distantPast
    @FocusState private var searchFocused: Bool
    @State private var archiveOpen = false
    @State private var archiveSide: ArchiveSide = .all
    /// Brief drop-in after a pull-to-refresh: "Updated just now", or why not.
    @State private var refreshNotice: (text: String, icon: String)?
    @State private var syncStatus = SyncStatus.shared
    /// Drives the tap-active-tab scroll back to the top of the list.
    @State private var scrollPosition = ScrollPosition()

    private enum ArchiveSide: String, CaseIterable {
        case all = "All"
        case been = "We Did Go"
    }

    // MARK: - Filtering

    private var base: [Item] {
        items.filter { $0.kind == kind && !$0.isDone && !$0.isMissed }
    }

    /// One chip/search filter shared by the active list and the journal.
    private func matches(_ item: Item) -> Bool {
        if let category,
           item.category?.trimmingCharacters(in: .whitespaces) != category {
            return false
        }
        if let area,
           item.area?.trimmingCharacters(in: .whitespaces).lowercased() != area.lowercased() {
            return false
        }
        if !query.isEmpty {
            return [item.title, item.venue, item.area, item.notes, item.summary]
                .compactMap(\.self)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return true
    }

    // Chip order must be fully deterministic: dictionary iteration order is
    // re-randomised every launch, so a count-only sort left tied chips (most
    // of them) shuffling on every app open. Alphabetical tie-break pins them.
    private var categories: [String] {
        var counts: [String: Int] = [:]
        for item in base {
            if let c = item.category?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
                counts[c, default: 0] += 1
            }
        }
        return counts
            .sorted {
                $0.value != $1.value
                    ? $0.value > $1.value
                    : $0.key.localizedCompare($1.key) == .orderedAscending
            }
            .map(\.key)
    }

    /// Top neighbourhoods for Places — keyed case-insensitively, capped so
    /// the row doesn't sprawl. Same deterministic order as categories.
    private var areas: [String] {
        guard kind == Item.Kind.place else { return [] }
        var counts: [String: (label: String, n: Int)] = [:]
        for item in base {
            guard let label = item.area?.trimmingCharacters(in: .whitespaces),
                  !label.isEmpty else { continue }
            let key = label.lowercased()
            counts[key] = (counts[key]?.label ?? label, (counts[key]?.n ?? 0) + 1)
        }
        return counts.values
            .sorted {
                $0.n != $1.n
                    ? $0.n > $1.n
                    : $0.label.localizedCompare($1.label) == .orderedAscending
            }
            .prefix(8)
            .map(\.label)
    }

    private var visible: [Item] {
        let list = base.filter(matches)
        // Places respect a hand-arranged order first (long-press drag);
        // anything never moved falls back to the closing-soon sort below.
        if kind == Item.Kind.place {
            return list.sorted { a, b in
                switch (a.sortOrder, b.sortOrder) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return closesSooner(a, b)
                }
            }
        }
        return list.sorted(by: closesSooner)
    }

    // Swift's sort is not stable, so ties need an explicit tie-break or
    // equal items shuffle every time the list recomputes (e.g. on filter).
    private func closesSooner(_ a: Item, _ b: Item) -> Bool {
        switch (a.daysUntilClose, b.daysUntilClose) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return newerFirst(a, b)
        }
    }

    /// The universal tie-break: newest save first, with the id as a final
    /// arbiter so two items can never compare equal and trade places.
    private func newerFirst(_ a: Item, _ b: Item) -> Bool {
        a.createdAt != b.createdAt
            ? a.createdAt > b.createdAt
            : a.id.uuidString < b.id.uuidString
    }

    // MARK: - Event urgency sections (the old This Week, folded in)

    /// Only the truly urgent lead the page: three days or fewer to act.
    private var lastChance: [Item] {
        visible.filter {
            !$0.isOneDay && ($0.daysUntilClose ?? 99) <= 3 && $0.timeBucket == .lastChance
        }
    }

    /// Running with the end in sight (within three weeks) — but not urgent,
    /// so it reads after this week's happenings, not before.
    private var closingSoon: [Item] {
        visible.filter {
            guard !$0.isOneDay, $0.timeBucket == .now || $0.timeBucket == .lastChance
            else { return false }
            return (4...21).contains($0.daysUntilClose ?? 99)
        }
    }

    /// The last day of the current calendar week (Sunday), as a day string.
    /// "This week" means through Sunday, not a rolling seven days: on a
    /// Thursday, a gig next Thursday is 7 days away but it is next week.
    private var weekEnd: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let dow = calendar.component(.weekday, from: today) // 1 = Sunday
        let sunday = calendar.date(byAdding: .day, value: (8 - dow) % 7, to: today)!
        return DayString.formatter.string(from: sunday)
    }

    /// One-offs and openings woven together, chronological: an exhibition
    /// opening Thursday is as much "this week" as a gig on Friday.
    private var happeningThisWeek: [Item] {
        visible
            .filter {
                guard let start = $0.startsOn, let away = $0.daysUntilStart,
                      away >= 0, start <= weekEnd
                else { return false }
                return $0.isOneDay || $0.timeBucket == .upcoming
            }
            .sorted {
                ($0.startsOn ?? "") != ($1.startsOn ?? "")
                    ? ($0.startsOn ?? "") < ($1.startsOn ?? "")
                    : newerFirst($0, $1)
            }
    }

    /// Running with no imminent end, or undated — simply on.
    private var onNow: [Item] {
        visible.filter {
            ($0.timeBucket == .now && ($0.daysUntilClose ?? 99) > 21)
                || $0.timeBucket == .undated
        }
    }

    /// Starts after this week ends — the far horizon.
    private var comingUp: [Item] {
        visible
            .filter { $0.timeBucket == .upcoming && ($0.startsOn ?? "") > weekEnd }
            .sorted {
                ($0.startsOn ?? "") != ($1.startsOn ?? "")
                    ? ($0.startsOn ?? "") < ($1.startsOn ?? "")
                    : newerFirst($0, $1)
            }
    }

    private var eventSections: [(String, [Item])] {
        [
            ("Last chance", lastChance),
            ("Happening this week", happeningThisWeek),
            ("Closing soon", closingSoon),
            ("On now", onNow),
            ("Coming up", comingUp),
        ].filter { !$0.1.isEmpty }
    }

    // MARK: - The journal (the old We Did Go, folded in)

    private var been: [Item] {
        items
            .filter { $0.kind == kind && $0.isDone && matches($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var missed: [Item] {
        items
            .filter { $0.kind == kind && $0.isMissed && $0.endsOn != nil && matches($0) }
            .sorted {
                ($0.endsOn ?? "") != ($1.endsOn ?? "")
                    ? ($0.endsOn ?? "") > ($1.endsOn ?? "")
                    : newerFirst($0, $1)
            }
    }

    /// Been and Missed woven together, most recent first — done things by
    /// when you marked them, missed things by when they ended.
    private var archiveAll: [Item] {
        (been + missed).sorted {
            archiveDate($0) != archiveDate($1)
                ? archiveDate($0) > archiveDate($1)
                : newerFirst($0, $1)
        }
    }

    private func archiveDate(_ item: Item) -> Date {
        item.isDone ? item.updatedAt : (DayString.date(item.endsOn ?? "") ?? item.updatedAt)
    }

    // MARK: - Map

    /// The Events map only pins what you could walk into today: running or
    /// undated things — nothing not-yet-open, nothing gone.
    private var mapItems: [Item] {
        guard kind == Item.Kind.event else { return visible }
        return visible.filter {
            switch $0.timeBucket {
            case .now, .lastChance, .undated: true
            case .upcoming, .past: false
            }
        }
    }

    // MARK: - Reordering (Places)

    /// Reordering only makes sense on the full, unfiltered Places list —
    /// with a chip or search active the row indices wouldn't map cleanly.
    private var canReorder: Bool {
        kind == Item.Kind.place && category == nil && area == nil && query.isEmpty
    }

    private func move(from source: IndexSet, to destination: Int) {
        Haptics.tap()
        var order = visible
        order.move(fromOffsets: source, toOffset: destination)
        // Freeze the whole list into explicit positions; updatedAt stays
        // untouched so a personal rearrangement never syncs.
        for (i, item) in order.enumerated() {
            item.sortOrder = Double(i)
        }
        try? context.save()
    }

    var body: some View {
        NavigationStack {
            // The list stays mounted underneath the map instead of being
            // swapped out: rebuilding it on every return re-attached the
            // search drawer (a brief flash of the bar) and re-ran the whole
            // list layout mid-animation. Hidden, it keeps its scroll
            // position and its tucked-away search bar; the map just fades.
            ZStack {
                list
                    .opacity(mode.showMap ? 0 : 1)
                    .allowsHitTesting(!mode.showMap)
                    .accessibilityHidden(mode.showMap)
                if mode.showMap {
                    MapPinsView(items: mapItems) { selected = $0 }
                        .transition(.opacity)
                }
            }
            // A quiet drop-in after pull-to-refresh, either way.
            .overlay(alignment: .top) {
                if let refreshNotice {
                    Label(refreshNotice.text, systemImage: refreshNotice.icon)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // No navigation title: the wordmark owns the leading edge, and
            // the bottom bar already says which tab you're on.
            .navigationBarTitleDisplayMode(.inline)
            .logoTitle()
            // Our own search control, not `.searchable`: the system pins
            // its search item to the far trailing end and won't hide it on
            // the map — this one sits left of the group and steps aside, so
            // the gear and toggle hold the very right end on both views.
            .toolbar {
                if !mode.showMap {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Haptics.tap()
                            withAnimation(.snappy) {
                                searchOpen.toggle()
                                if !searchOpen { query = "" }
                            }
                        } label: {
                            headerIcon("magnifyingglass")
                        }
                        .accessibilityLabel("Search")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy) {
                            mode.showMap.toggle()
                            searchOpen = false
                        }
                    } label: {
                        headerIcon(mode.showMap ? "list.bullet" : "map")
                    }
                    .accessibilityLabel(mode.showMap ? "Show list" : "Show map")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if searchOpen && !mode.showMap {
                    searchField
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // CWG_SEARCH is only set by automated test runs.
            .task {
                if ProcessInfo.processInfo.environment["CWG_SEARCH"] != nil {
                    searchOpen = true
                }
            }
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
                if env["CWG_MAP"] != nil { mode.showMap = true }
            }
        }
    }

    /// Softened white at semibold — bright icons shouted over the content;
    /// all three header icons speak at the same volume.
    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.72))
    }

    /// The glass search row that drops in under the header when the
    /// magnifier is tapped. The X inside the field is the way out — it
    /// dismisses search altogether; scrolling the list works too (see `list`).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Search your saves", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            Button {
                closeSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .task {
            searchFocused = true
            searchOpenedAt = .now
        }
        .onDisappear { searchFocused = false }
    }

    private func closeSearch() {
        Haptics.tap()
        withAnimation(.snappy) {
            searchOpen = false
            query = ""
        }
    }

    private func showRefreshNotice(_ text: String, icon: String) {
        withAnimation(.snappy) { refreshNotice = (text, icon) }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.snappy) { refreshNotice = nil }
        }
    }

    /// A day without a successful sync while online: say so, say why if we
    /// know, and offer a retry. Dismissible, but it returns after another
    /// day of the same — a library quietly drifting apart is the one thing
    /// a shared list must never do silently.
    private var staleBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last synced \(syncStatus.lastSyncedAt?.formatted(.relative(presentation: .named)) ?? "a while ago")")
                            .font(.footnote.weight(.semibold))
                        Text(syncStatus.problem ?? "Couldn't reach the server, though you're online.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath.circle")
                }
                .foregroundStyle(.orange)
                Spacer(minLength: 0)
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { syncStatus.staleBannerDismissedAt = .now }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            Button {
                Haptics.tap()
                Task {
                    await SupabaseSync.sync(context: context)
                    if SyncStatus.shared.problem == nil {
                        Haptics.success()
                        showRefreshNotice("Updated just now", icon: "checkmark")
                    }
                }
            } label: {
                Label(syncStatus.syncing ? "Syncing…" : "Try again", systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(syncStatus.syncing)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var list: some View {
        List {
            // CWG_STALE only exists so screenshot runs can photograph the banner.
            if (syncStatus.isStale && SupabaseAuth.shared.signedIn)
                || ProcessInfo.processInfo.environment["CWG_STALE"] != nil {
                staleBanner
                    .padding(.top, 6)
                    .cardListRow()
                    .transition(.opacity)
            }

            if categories.count > 1 || areas.count > 1 {
                // Not cardListRow(): its insets would win over these, and
                // the row above and below the chips wants to be tighter.
                // Places get a touch more below — their cards follow the
                // chips directly, with no section header to give them air.
                chipRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(
                        top: 5,
                        leading: 20,
                        bottom: kind == Item.Kind.place ? 16 : 0,
                        trailing: 20
                    ))
            }

            if kind == Item.Kind.event {
                eventList
            } else {
                placeList
            }

            if visible.isEmpty && been.isEmpty && missed.isEmpty {
                ContentUnavailableView {
                    Label(
                        base.isEmpty ? emptyTitle : "Nothing matches",
                        systemImage: kind == Item.Kind.place ? "fork.knife" : "building.columns"
                    )
                } description: {
                    Text(
                        base.isEmpty
                            ? emptyPrompt
                            : "Try a different word, or clear the filters."
                    )
                } actions: {
                    if category != nil || area != nil || !query.isEmpty {
                        Button("Clear filters") {
                            Haptics.tap()
                            withAnimation(.snappy) {
                                category = nil
                                area = nil
                                query = ""
                            }
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.top, 40)
                .cardListRow()
            }

            journal
        }
        .listStyle(.plain)
        // Opting out of the 44pt minimum row height is only for the chip
        // row, which it padded with dead air below the chips; every other
        // short row pins the old height back explicitly (frame(minHeight:))
        // so the rest of the page keeps its original rhythm.
        .environment(\.defaultMinListRowHeight, 1)
        // Pull-to-refresh answers either way: a thump and "Updated just
        // now", or a brief notice when the sync couldn't get through.
        .refreshable {
            await SupabaseSync.sync(context: context)
            if SyncStatus.shared.problem == nil {
                Haptics.success()
                showRefreshNotice("Updated just now", icon: "checkmark")
            } else {
                showRefreshNotice("Couldn't refresh. Check your connection", icon: "wifi.slash")
            }
        }
        // Tapping the tab you're already on brings the list home.
        .scrollPosition($scrollPosition)
        .onReceive(NotificationCenter.default.publisher(for: .cwgScrollToTop)) { _ in
            guard !mode.showMap else { return }
            if searchOpen { closeSearch() }
            withAnimation(.snappy) { scrollPosition.scrollTo(edge: .top) }
        }
        // Scrolling is a way out of search: the keyboard drops right away,
        // and an untouched (empty) field slides off entirely. The grace
        // period skips the offset jump caused by the field's own inset
        // appearing, which would otherwise close it the moment it opened.
        .scrollDismissesKeyboard(.immediately)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
            guard searchOpen, query.isEmpty,
                  Date.now.timeIntervalSince(searchOpenedAt) > 0.6,
                  abs(new - old) > 12
            else { return }
            withAnimation(.snappy) { searchOpen = false }
        }
        // Snug under the header — the chip row's own insets are enough air.
        .contentMargins(.top, 0, for: .scrollContent)
        // Room at the end so the last card clears the floating bottom bar.
        .contentMargins(.bottom, 90, for: .scrollContent)
        .appBackground(kind == Item.Kind.place ? AppBackground.places : AppBackground.library)
    }

    /// Urgency first, then the simply-on, then the far horizon.
    @ViewBuilder
    private var eventList: some View {
        ForEach(eventSections, id: \.0) { section in
            SectionHeader(title: section.0, count: section.1.count)
                .frame(minHeight: 44)
                .cardListRow()
            ForEach(section.1) { item in
                ItemCardRow(item: item) { selected = item }
            }
        }
    }

    @ViewBuilder
    private var placeList: some View {
        ForEach(visible) { item in
            ItemCardRow(item: item) { selected = item }
        }
        .onMove(perform: canReorder ? move : nil)
    }

    // MARK: - Empty states

    private var emptyTitle: String {
        kind == Item.Kind.place ? "No places yet" : "No events yet"
    }

    /// One concrete way to get the first save in, tuned to the tab.
    private var emptyPrompt: String {
        kind == Item.Kind.place
            ? "Share a restaurant, bar or shop from Safari, Google Maps or Instagram — it lands here for both of you."
            : "Share a gig from DICE, an exhibition from a gallery's page, or paste any link — it lands here for both of you."
    }

    /// The journal at the end of the list. Events keep theirs folded into a
    /// collapsed Archive; Places just show where you've been. A search
    /// unfolds it: "did we go to that?" is half of what search is for.
    @ViewBuilder
    private var journal: some View {
        if kind == Item.Kind.event {
            if !query.isEmpty {
                if !archiveAll.isEmpty {
                    SectionHeader(title: "We Did Go", count: archiveAll.count)
                        .frame(minHeight: 44)
                        .cardListRow()
                    ForEach(archiveAll) { item in
                        ItemCardRow(item: item, compact: true) {
                            selected = item
                        }
                    }
                }
            } else {
                eventArchive
            }
        } else if !been.isEmpty {
            SectionHeader(title: "Been", count: been.count)
                .frame(minHeight: 44)
                .cardListRow()
            ForEach(been) { item in
                ItemCardRow(item: item, compact: true) {
                    selected = item
                }
            }
        }
    }

    /// One quiet drawer for everything that's over — collapsed by default,
    /// with an All / We Did Go split inside (missed things only show in All).
    @ViewBuilder
    private var eventArchive: some View {
        if !archiveAll.isEmpty {
            Button {
                Haptics.tap()
                withAnimation(.snappy) { archiveOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Archive")
                    Text("\(archiveAll.count)")
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(archiveOpen ? 90 : 0))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .cardListRow()

            if archiveOpen {
                Picker("Archive filter", selection: $archiveSide.animation(.snappy)) {
                    ForEach(ArchiveSide.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: archiveSide)
                .padding(.top, 4)
                .frame(minHeight: 44)
                .cardListRow()

                let rows = archiveSide == .all ? archiveAll : been
                ForEach(rows) { item in
                    ItemCardRow(item: item, compact: true) {
                        selected = item
                    }
                }
            }
        }
    }

    private var chipRow: some View {
        ChipRow(
            categories: categories,
            areas: areas,
            category: $category,
            area: $area,
            fadeColor: kind == Item.Kind.place ? AppBackground.places : AppBackground.library
        )
    }
}

/// Liquid Glass filter chips — the one custom control layer here.
/// Categories first, then (for Places) neighbourhoods after a divider.
///
/// Deliberately its own view: the end-of-row fade tracks scroll position,
/// and while this state lived on LibraryView every swipe past the edge
/// recomputed the entire page (sections, sorts and all) mid-gesture —
/// the source of the chip row's jumpiness. Here a flip re-renders only
/// this row.
private struct ChipRow: View {
    let categories: [String]
    let areas: [String]
    @Binding var category: String?
    @Binding var area: String?
    let fadeColor: Color

    /// Whether the row is scrolled to its end — drives the fade hint.
    @State private var atEnd = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // No GlassEffectContainer here on purpose: it exists to morph
            // nearby glass shapes into each other, so while the row scrolls
            // adjacent chips kept trying to coalesce — warping mid-swipe and
            // costing a full re-composite every frame. Independent chips
            // never need to merge; each carries its own glass.
            HStack(spacing: 8) {
                if categories.count > 1 {
                    ForEach(categories, id: \.self) { c in
                        chip(c.capitalized, isOn: category == c) {
                            category = category == c ? nil : c
                        }
                    }
                }
                if categories.count > 1 && areas.count > 1 {
                    Rectangle()
                        .fill(.white.opacity(0.25))
                        .frame(width: 1, height: 16)
                }
                if areas.count > 1 {
                    ForEach(areas, id: \.self) { a in
                        chip(a, isOn: area?.lowercased() == a.lowercased()) {
                            area = area?.lowercased() == a.lowercased() ? nil : a
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.x + geo.containerSize.width >= geo.contentSize.width - 8
        } action: { _, nowAtEnd in
            if atEnd != nowAtEnd { atEnd = nowAtEnd }
        }
        // A soft dissolve into the page at the screen edge, hinting there
        // are more chips to scroll. A mask can't do this: it would also clip
        // the intentional overflow into the margins (scrollClipDisabled).
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [.clear, fadeColor],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 36)
            // The row is inset 20 pt from the screen; reach the true edge.
            .offset(x: 20)
            .allowsHitTesting(false)
            .opacity(atEnd ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: atEnd)
        }
    }

    private func chip(_ label: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.snappy) { toggle() }
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityHint(isOn ? "Clears this filter" : "Filters the list")
        // Explicit colors: the system styles both resolve near-white here,
        // leaving white text on white glass.
        .foregroundStyle(isOn ? AppBackground.base : .white)
        // Not .interactive(): touch-tracking glass deforms under the finger,
        // which reads as wobble when a swipe drags across the row.
        .glassEffect(
            isOn ? .regular.tint(.white.opacity(0.92)) : .regular,
            in: .capsule
        )
    }
}

