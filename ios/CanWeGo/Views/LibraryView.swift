import CoreLocation
import SwiftData
import SwiftUI
import TipKit

/// Map-or-list, shared by the Events and Places tabs: switch to the map on
/// one and the other stays on the map, so geographic browsing carries
/// across without flipping back to the list.
@Observable
final class ViewMode {
    static let shared = ViewMode()
    var showMap = false
    /// The Events map's footer toggle: pins for things not open yet too.
    var mapShowsUpcoming = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The stale-sync pill's sideways drag, on its way to being dismissed.
    @State private var staleDrag: CGFloat = 0
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @State private var query = ""
    @State private var category: String?
    @State private var area: String?
    /// Places only: nearest first, and only what's open right now.
    @State private var nearMe = false
    @State private var openNow = false
    @State private var checkingHours = false
    @State private var selected: Item?
    /// Shared across the Events and Places tabs: flipping to the map on one
    /// keeps the other on the map too, so browsing both by geography flows.
    private var mode: ViewMode { .shared }
    @State private var searchOpen = false
    @State private var searchOpenedAt = Date.distantPast
    @FocusState private var searchFocused: Bool
    /// Apple Intelligence is ready, checked as search opens: questions
    /// typed into search can be put to the library.
    @State private var askable = false
    /// The question last put to the library; the answer stands while the
    /// search still reads the same.
    @State private var asked: String?
    @State private var archiveOpen = false
    @State private var archiveSide: ArchiveSide = .all
    /// Brief drop-in after a pull-to-refresh: "Updated just now", or why not.
    @State private var refreshNotice: (text: String, icon: String)?
    @State private var syncStatus = SyncStatus.shared
    @State private var undoBin = UndoBin.shared
    /// A pull-to-refresh in flight: the wordmark's "?" rocks meanwhile.
    @State private var refreshing = false
    /// The pull itself, which the "?" follows. Written as the list
    /// scrolls and read only by the wordmark.
    @State private var pull = PullDistance()
    @State private var pullFeedback = PullFeedback()
    /// One tip at a time: the share tip first, then the widget tip once it's
    /// dismissed or no longer needed.
    @State private var tips = TipGroup(.firstAvailable) {
        ShareTip()
        WidgetTip()
    }
    /// Drives the tap-active-tab scroll back to the top of the list.
    @State private var scrollPosition = ScrollPosition()
    /// The list's visible height, for centring an empty tab in it.
    @State private var listHeight: CGFloat = 0

    private enum ArchiveSide: CaseIterable {
        case all, been

        @MainActor var label: String {
            switch self {
            case .all: "All"
            case .been: Voice.didGoSection
            }
        }
    }

    // MARK: - Filtering

    /// `CWG_EMPTY` (test runs only) shows every tab empty, for screenshots
    /// of the first-run state on an account that has saves.
    private var library: [Item] {
        ProcessInfo.processInfo.environment["CWG_EMPTY"] != nil ? [] : items
    }

    private var base: [Item] {
        library.filter { $0.kind == kind && !$0.isDeleted && !$0.isDone && !$0.isMissed }
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
        if openNow, item.isPlace, !item.isOpenNow {
            return false
        }
        if !query.isEmpty {
            return [item.title, item.venue, item.area, item.notes, item.summary]
                .compactMap(\.self)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return true
    }

    /// The search, when it reads like a question for the library.
    private var askQuestion: String? {
        #if APP_EXTENSION
        return nil
        #else
        guard searchOpen, askable, #available(iOS 27.0, *) else { return nil }
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return AskLibraryRow.isQuestion(question) ? question : nil
        #endif
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
        let list = Self.ordered(base.filter(matches), kind: kind)
        guard nearMe, kind == Item.Kind.place else { return list }
        return Self.nearestFirst(list)
    }

    /// Closest to the phone first; anything without a pin (or no fix yet)
    /// keeps its place in the list's own order, after the rest.
    private static func nearestFirst(_ list: [Item]) -> [Item] {
        guard let here = LocationStore.shared.location else { return list }
        func away(_ item: Item) -> Double {
            item.coordinate.map { here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) } ?? .infinity
        }
        return list.enumerated()
            .sorted { away($0.element) != away($1.element) ? away($0.element) < away($1.element) : $0.offset < $1.offset }
            .map(\.element)
    }

    /// How many places "Open now" asks about: each is a billed lookup,
    /// so only the nearest, and only ones this launch hasn't seen.
    private static let openNowLookups = 10

    private func checkOpenNow() async {
        let unknown = Self.nearestFirst(Self.ordered(base, kind: kind))
            .filter(\.showsHours)
            .prefix(Self.openNowLookups)
            .filter { HoursClient.cached($0) == nil }
        guard !unknown.isEmpty else { return }
        checkingHours = true
        await withDiscardingTaskGroup { group in
            for item in unknown {
                group.addTask { @MainActor in _ = await HoursClient.load(item) }
            }
        }
        checkingHours = false
    }

    /// The active list's order. Static so launch can warm photos in the
    /// same order the list will ask for them.
    static func ordered(_ list: [Item], kind: String) -> [Item] {
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
    private static func closesSooner(_ a: Item, _ b: Item) -> Bool {
        switch (a.daysUntilClose, b.daysUntilClose) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return newerFirst(a, b)
        }
    }

    /// The universal tie-break: newest save first, with the id as a final
    /// arbiter so two items can never compare equal and trade places.
    private static func newerFirst(_ a: Item, _ b: Item) -> Bool {
        a.createdAt != b.createdAt
            ? a.createdAt > b.createdAt
            : a.id.uuidString < b.id.uuidString
    }

    private func newerFirst(_ a: Item, _ b: Item) -> Bool { Self.newerFirst(a, b) }

    // MARK: - Event urgency sections (the old This Week, folded in)

    private var eventSections: [(String, [Item])] { Self.eventSections(visible) }

    /// `visible` (already in `ordered` order) split into the Events page's
    /// sections, in page order.
    static func eventSections(_ visible: [Item]) -> [(String, [Item])] {
        // "This week" means through Sunday, not a rolling seven days: on a
        // Thursday, a gig next Thursday is 7 days away but it is next week.
        let weekEnd = DayString.endOfThisWeek()
        let byStart: (Item, Item) -> Bool = {
            ($0.startsOn ?? "") != ($1.startsOn ?? "")
                ? ($0.startsOn ?? "") < ($1.startsOn ?? "")
                : newerFirst($0, $1)
        }
        // Only the truly urgent lead the page: three days or fewer to act.
        let lastChance = visible.filter {
            !$0.isOneDay && ($0.daysUntilClose ?? 99) <= 3 && $0.timeBucket == .lastChance
        }
        // One-offs and openings woven together, chronological: an
        // exhibition opening Thursday is as much "this week" as a gig on
        // Friday.
        let happeningThisWeek = visible
            .filter {
                guard let start = $0.startsOn, let away = $0.daysUntilStart,
                      away >= 0, start <= weekEnd
                else { return false }
                return $0.isOneDay || $0.timeBucket == .upcoming
            }
            .sorted(by: byStart)
        // Running with the end in sight (within three weeks), but not
        // urgent, so it reads after this week's happenings, not before.
        let closingSoon = visible.filter {
            guard !$0.isOneDay, $0.timeBucket == .now || $0.timeBucket == .lastChance
            else { return false }
            return (4...21).contains($0.daysUntilClose ?? 99)
        }
        // Running with no imminent end, or undated: simply on.
        let onNow = visible.filter {
            ($0.timeBucket == .now && ($0.daysUntilClose ?? 99) > 21)
                || $0.timeBucket == .undated
        }
        // Starts after this week ends: the far horizon.
        let comingUp = visible
            .filter { $0.timeBucket == .upcoming && ($0.startsOn ?? "") > weekEnd }
            .sorted(by: byStart)
        return [
            ("Last chance", lastChance),
            ("Happening this week", happeningThisWeek),
            ("Closing soon", closingSoon),
            ("On now", onNow),
            ("Coming up", comingUp),
        ]
        .filter { !$0.1.isEmpty }
        .map { ($0.0, plannedFirst($0.1)) }
    }

    /// A plan still ahead leads its section, soonest day and time first
    /// (a timed plan before an untimed one that day); the rest keep the
    /// section's own order. It drops back once the day has gone by.
    private static func plannedFirst(_ list: [Item]) -> [Item] {
        let planned = list.filter { $0.upcomingPlan != nil }
        guard !planned.isEmpty else { return list }
        let when = { (item: Item) in (item.upcomingPlan ?? "", item.planTime ?? "~") }
        return planned.sorted { when($0) != when($1) ? when($0) < when($1) : newerFirst($0, $1) }
            + list.filter { $0.upcomingPlan == nil }
    }

    // MARK: - The journal (the old We Did Go, folded in)

    private var been: [Item] {
        library
            .filter { $0.kind == kind && !$0.isDeleted && $0.isDone && matches($0) }
            .sorted { $0.wentDate != $1.wentDate ? $0.wentDate > $1.wentDate : newerFirst($0, $1) }
    }

    private var missed: [Item] {
        library
            .filter { $0.kind == kind && !$0.isDeleted && $0.isMissed && $0.endsOn != nil && matches($0) }
            .sorted {
                ($0.endsOn ?? "") != ($1.endsOn ?? "")
                    ? ($0.endsOn ?? "") > ($1.endsOn ?? "")
                    : newerFirst($0, $1)
            }
    }

    /// Been and Missed woven together, most recent first — done things by
    /// when you went, missed things by when they ended.
    private var archiveAll: [Item] {
        (been + missed).sorted {
            archiveDate($0) != archiveDate($1)
                ? archiveDate($0) > archiveDate($1)
                : newerFirst($0, $1)
        }
    }

    private func archiveDate(_ item: Item) -> Date {
        item.isDone ? item.wentDate : (DayString.date(item.endsOn ?? "") ?? item.updatedAt)
    }

    // MARK: - Map

    /// The Events map only pins what you could walk into today: running or
    /// undated things — nothing not-yet-open, nothing gone. The footer
    /// pill on the map lets the not-yet-open ones in.
    private var mapItems: [Item] {
        guard kind == Item.Kind.event else { return visible }
        return visible.filter {
            switch $0.timeBucket {
            case .now, .lastChance, .undated: true
            case .upcoming: mode.mapShowsUpcoming
            case .past: false
            }
        }
    }

    // MARK: - Reordering (Places)

    /// Reordering only makes sense on the full, unfiltered Places list —
    /// with a chip or search active the row indices wouldn't map cleanly.
    /// "Open now" is the only filter on.
    private var openNowOnly: Bool { openNow && category == nil && area == nil && query.isEmpty }

    private var canReorder: Bool {
        kind == Item.Kind.place && category == nil && area == nil && query.isEmpty && !nearMe && !openNow
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
                    // Floats just above the tab bar; the list scrolls clear
                    // of it. A refresh notice takes the same spot while it
                    // shows, so a good retry hands straight over to
                    // "Updated just now".
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        let shown = showsStale && refreshNotice == nil && !searchOpen
                        VStack {
                            if shown {
                                staleBanner
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 12)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .animation(.snappy, value: shown)
                    }
                    .opacity(mode.showMap ? 0 : 1)
                    .allowsHitTesting(!mode.showMap)
                    .accessibilityHidden(mode.showMap)
                if mode.showMap {
                    MapPinsView(
                        items: mapItems,
                        upcoming: kind == Item.Kind.event
                            ? visible.filter { $0.timeBucket == .upcoming }.count
                            : 0,
                        showsUpcoming: Binding(
                            get: { mode.mapShowsUpcoming },
                            set: { mode.mapShowsUpcoming = $0 }
                        )
                    ) { selected = $0 }
                        .transition(.opacity)
                }
            }
            // A quiet word after pull-to-refresh, either way, just above
            // the tab bar.
            .overlay(alignment: .bottom) {
                if let refreshNotice {
                    Label(refreshNotice.text, systemImage: refreshNotice.icon)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // No navigation title: the wordmark owns the leading edge, and
            // the bottom bar already says which tab you're on.
            .navigationBarTitleDisplayMode(.inline)
            .logoTitle(refreshing: refreshing, pull: pull)
            // Our own search control, not `.searchable`: the system pins
            // its search item to the far trailing end and won't hide it on
            // the map — this one sits left of the group and steps aside, so
            // the gear and toggle hold the very right end on both views.
            .toolbar {
                if !mode.showMap {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Haptics.tap()
                            if searchOpen {
                                // Opening the field relayouts the bar, and
                                // the same tap is delivered again. Ignore
                                // that echo so the field isn't closed by
                                // the gesture that opened it.
                                guard Date.now.timeIntervalSince(searchOpenedAt) > 0.45 else { return }
                                closeSearch()
                            } else {
                                searchOpenedAt = .now
                                withAnimation(.snappy) { searchOpen = true }
                            }
                        } label: {
                            headerIcon("magnifyingglass")
                        }
                        .accessibilityLabel("Search")
                    }
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
                // Settings holds the far end: the gear is the one control
                // that isn't about the list in front of you.
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsButton()
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
                takeSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cwgSearchSaves)) { _ in
                takeSearch()
            }
            .sheet(item: $selected) { ItemDetailView(item: $0) }
            // The library is about to be replaced: the open item won't exist.
            .onReceive(NotificationCenter.default.publisher(for: .cwgLibraryWillSwap)) { _ in
                selected = nil
            }
            // CWG_OPEN / CWG_CHIP are only set by automated screenshot runs;
            // they deep-open an item / preselect a chip and do nothing otherwise.
            .task {
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
            .foregroundStyle(AppBackground.ink.opacity(0.72))
    }

    /// The glass search row that drops in under the header when the
    /// magnifier is tapped. The X inside the field is the way out — it
    /// dismisses search altogether; scrolling the list works too (see `list`).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(AppBackground.secondaryInk)
            TextField("", text: $query, prompt: AppBackground.fieldPrompt("Search your saves"))
                .foregroundStyle(AppBackground.ink)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit {
                    guard let question = askQuestion else { return }
                    withAnimation(.snappy) { asked = question }
                }
            Button {
                closeSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(AppBackground.secondaryInk)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
            .padding(.trailing, -11)
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
            #if !APP_EXTENSION
            if #available(iOS 27.0, *) { askable = LibraryAsk.isAvailable }
            #endif
        }
        .onDisappear { searchFocused = false }
    }

    /// A search asked for from outside, if it's for this tab.
    private func takeSearch() {
        guard let search = SearchGate.pending, search.kind == kind else { return }
        SearchGate.pending = nil
        selected = nil
        mode.showMap = false
        category = nil
        area = nil
        query = search.text
        searchOpenedAt = .now
        withAnimation(.snappy) { searchOpen = true }
    }

    private func closeSearch() {
        Haptics.tap()
        withAnimation(.snappy) {
            searchOpen = false
            query = ""
        }
        asked = nil
    }

    private func showRefreshNotice(_ text: String, icon: String) {
        withAnimation(.snappy) { refreshNotice = (text, icon) }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.snappy) { refreshNotice = nil }
        }
    }

    /// A day without a successful sync while online: one glass pill above
    /// the tab bar saying when it last worked, with Retry inside it. Swiped
    /// away it returns after another day of the same — a library quietly
    /// drifting apart is the one thing a shared list must never do
    /// silently. Why it failed lives in Settings, with the raw answer.
    private var staleBanner: some View {
        HStack(spacing: 10) {
            Group {
                if syncStatus.syncing {
                    SmallRing()
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppBackground.warning)
                }
            }
            .frame(width: 18)

            // Two lines of different lengths cross-fading smear into each
            // other; one pushes the other out instead.
            ZStack(alignment: .leading) {
                Group {
                    if syncStatus.syncing {
                        Text("\(Text("Syncing…").fontWeight(.semibold))\(Text(" · \(lastSyncedPhrase(lower: true))").foregroundStyle(AppBackground.secondaryInk))")
                    } else {
                        Text(lastSyncedPhrase(lower: false)).fontWeight(.semibold)
                    }
                }
                .id(syncStatus.syncing)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
            }
            .font(.footnote)
            .foregroundStyle(AppBackground.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

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
                Text("Retry")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .prominentGlass()
            .controlSize(.small)
            .disabled(syncStatus.syncing)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy, value: syncStatus.syncing)
        // Swiped sideways, it goes; a mostly vertical drag is the list
        // scrolling and leaves it be.
        .offset(x: staleDrag)
        .opacity(1 - min(0.8, abs(staleDrag) / 240))
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { drag in
                    guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                    staleDrag = drag.translation.width
                }
                .onEnded { drag in
                    if abs(drag.translation.width) > 90 || abs(drag.predictedEndTranslation.width) > 220 {
                        dismissStaleBanner()
                    } else {
                        withAnimation(.snappy) { staleDrag = 0 }
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint(syncStatus.problem?.message ?? "You're online, but the server hasn't answered since.")
        .accessibilityAction(named: "Dismiss") { dismissStaleBanner() }
    }

    private func dismissStaleBanner() {
        Haptics.tap()
        withAnimation(.snappy) { syncStatus.staleBannerDismissedAt = .now }
        staleDrag = 0
    }

    /// "Last synced 2 days ago", "Last synced yesterday": when it last
    /// worked, rather than an alarm.
    private func lastSyncedPhrase(lower: Bool) -> String {
        let lead = lower ? "last synced" : "Last synced"
        guard let last = syncStatus.lastSyncedAt else { return lower ? "not synced yet" : "Not synced yet" }
        return "\(lead) \(last.formatted(.relative(presentation: .named)))"
    }

    private var list: some View {
        ScrollViewReader { proxy in
            listBody
                // A card just landed in this tab: bring it into view, then
                // its own lift (ItemCardRow) says "here". A beat's delay lets
                // the row exist before the scroll asks for it.
                .onChange(of: undoBin.landed) { _, id in
                    guard let id, !mode.showMap,
                          (visible + been).contains(where: { $0.id == id })
                    else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.3))
                        guard undoBin.landed == id else { return }
                        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
        }
    }

    /// CWG_STALE only exists so screenshot runs can photograph the pill.
    private var showsStale: Bool {
        (syncStatus.isStale && SupabaseAuth.shared.signedIn)
            || ProcessInfo.processInfo.environment["CWG_STALE"] != nil
    }

    private var listBody: some View {
        List {
            // Second launch onwards, until dismissed or a share lands:
            // saves can come from the share sheet. Then the widget.
            TipView(tips.currentTip)
                .tipBackground(AppBackground.wash(0.06))
                .tipCornerRadius(12)
                .tipImageSize(CGSize(width: 22, height: 22))
                .padding(.top, 6)
                .cardListRow()

            #if !APP_EXTENSION
            if #available(iOS 27.0, *), let question = askQuestion {
                AskLibraryRow(question: question, asked: $asked) { id in
                    selected = items.first { $0.id == id && !$0.isDeleted }
                }
                .cardListRow()
            }
            #endif

            if categories.count > 1 || areas.count > 1 {
                // Not cardListRow(): its insets would win over these, and
                // the row above and below the chips wants to be tighter.
                // Places get a touch more below — their cards follow the
                // chips directly, with no section header to give them air.
                chipRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    // Full-bleed row, 20pt padding inside the scroller, so
                    // the first chip still lines up with the cards and the
                    // scroll view can clip instead of spilling.
                    .listRowInsets(.init(
                        top: 5,
                        leading: 0,
                        bottom: kind == Item.Kind.place ? 16 : 0,
                        trailing: 0
                    ))
            }

            if kind == Item.Kind.event {
                eventList
            } else {
                placeList
            }

            if visible.isEmpty && !been.isEmpty && query.isEmpty && category == nil && area == nil {
                EmptyState(
                    title: "Nothing coming up",
                    message: kind == Item.Kind.place
                        ? "You\u{2019}ve been everywhere you saved. Where next?"
                        : "Everything you saved has been and gone. What\u{2019}s next?"
                ) {
                    suggestionChips
                }
                .padding(.vertical, 8)
                .cardListRow()
            }

            if visible.isEmpty && been.isEmpty && missed.isEmpty && base.isEmpty && awaitingFirstPull {
                ContentUnavailableView {
                    Label(
                        partnerFirstName.map { "\($0)'s saves are on the way" } ?? "Your library is on the way",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                } description: {
                    Text("Give it a moment. Everything already saved lands here.")
                } actions: {
                    ProgressView()
                }
                .padding(.top, 40)
                .cardListRow()
            } else if visible.isEmpty && been.isEmpty && missed.isEmpty {
                let filtered = category != nil || area != nil || openNow || !query.isEmpty
                if base.isEmpty && !filtered {
                    // Nothing in this tab: the first-time version when the
                    // whole library is new, with things to start from.
                    let firstTime = !library.contains { !$0.isDeleted }
                    EmptyState(
                        title: firstTime ? firstTitle : emptyTitle,
                        message: firstTime ? firstPrompt : emptyPrompt
                    ) {
                        suggestionChips
                    }
                    // Centred between the header and the tab bar, less the
                    // bottom content margin.
                    .frame(minHeight: max(listHeight - 24, 0))
                    .cardListRow()
                } else if askQuestion == nil {
                    EmptyState(
                        title: base.isEmpty ? emptyTitle : (openNowOnly ? (checkingHours ? "Checking hours…" : "Nothing open right now") : "Nothing matches"),
                        message: base.isEmpty ? emptyPrompt : (openNowOnly ? "Out of the \(Self.openNowLookups) places nearest you." : "Try a different word, or clear the filters."),
                        glyph: category != nil ? emptyGlyph : nil
                    ) {
                        if filtered {
                            Button("Clear filters") {
                                Haptics.tap()
                                withAnimation(.snappy) {
                                    category = nil
                                    area = nil
                                    openNow = false
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
            pullFeedback.caught()
            refreshing = true
            await SupabaseSync.sync(context: context)
            refreshing = false
            if let problem = SyncStatus.shared.problem {
                let offline = problem.status == 0
                showRefreshNotice(
                    offline ? "Couldn't refresh. Check your connection" : "Refreshed, but not everything synced",
                    icon: offline ? "wifi.slash" : "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                )
            } else {
                Haptics.success()
                showRefreshNotice("Updated just now", icon: "checkmark")
            }
        }
        // Only past the top, and to the half point: an ordinary scroll
        // changes nothing here and costs nothing.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let past = -(geometry.contentOffset.y + geometry.contentInsets.top)
            return past > 0 ? (past * 2).rounded() / 2 : 0
        } action: { _, points in
            pull.points = points
            pullFeedback.pulled(to: points)
        }
        // Tapping the tab you're already on brings the list home.
        .scrollPosition($scrollPosition)
        .task(id: openNow) { if openNow { await checkOpenNow() } }
        .onReceive(NotificationCenter.default.publisher(for: .cwgScrollToTop)) { _ in
            guard !mode.showMap else { return }
            if searchOpen { closeSearch() }
            withAnimation(.snappy) { scrollPosition.scrollTo(edge: .top) }
        }
        // A finger drag leaves search. The field's own inset and the
        // keyboard both move the content offset, and that used to count
        // as a scroll and close the field the moment it opened. Only a
        // real drag (the interacting phase) counts.
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, phase in
            pullFeedback.dragging = phase == .interacting
            guard searchOpen, query.isEmpty, phase == .interacting,
                  Date.now.timeIntervalSince(searchOpenedAt) > 0.45
            else { return }
            withAnimation(.snappy) {
                searchOpen = false
                query = ""
            }
        }
        // Snug under the header — the chip row's own insets are enough air.
        .contentMargins(.top, 0, for: .scrollContent)
        // A little extra so the last card clears the floating tab bar.
        .contentMargins(.bottom, 24, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
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

    /// A title and a line under it, in the brand's type instead of a system
    /// placeholder. A chosen filter chip's glyph sits above.
    private struct EmptyState<Actions: View>: View {
        let title: String
        let message: String
        var glyph: String? = nil
        @ViewBuilder var actions: () -> Actions

        init(title: String, message: String, glyph: String? = nil,
             @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
            self.title = title
            self.message = message
            self.glyph = glyph
            self.actions = actions
        }

        var body: some View {
            VStack(spacing: 14) {
                if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(AppBackground.ink.opacity(0.55))
                        .frame(height: 56)
                }
                VStack(spacing: 6) {
                    Text(title)
                        .font(.displaySmallBold(22, relativeTo: .title3))
                        .foregroundStyle(AppBackground.ink)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(AppBackground.secondaryInk)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions()
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// Nothing saved in either tab yet: most likely straight out of the
    /// first run without adding anything.
    private var firstTitle: String {
        kind == Item.Kind.place ? "Where do you keep meaning to go?" : "What's the first thing you'd go to?"
    }

    private var firstPrompt: String {
        let how = kind == Item.Kind.place
            ? "Share it from Maps or Instagram, or tap + and type the name."
            : "Share a link from anywhere, or tap + and type it."
        return how + seenBy
    }

    /// A few things from the home city's pool under an empty tab. None
    /// without a home, and none left once they're all saved.
    @ViewBuilder
    private var suggestionChips: some View {
        let home = HomeStore.shared.isSet ? HomeStore.shared.home : nil
        let picks = home.map { Suggestions.shared.picks(kind: kind, for: $0, excluding: library) } ?? []
        VStack(spacing: 0) {
            if !picks.isEmpty {
                VStack(spacing: 10) {
                    Text("Or start with one of these")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(AppBackground.secondaryInk.opacity(0.6))
                    SuggestionChips(picks: picks)
                }
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: picks)
        .onAppear {
            if let home { Suggestions.shared.load(for: home) }
        }
    }

    private var emptyTitle: String {
        if let category {
            return "No \(Item.categoryLabel(category).lowercased()) yet"
        }
        return kind == Item.Kind.place ? "No places yet" : "No events yet"
    }

    private var emptyGlyph: String {
        if let category {
            return Item.glyph(kind: kind, category: category)
        }
        if kind == Item.Kind.place { return "building.columns" }
        let day = Calendar.current.component(.day, from: Date())
        return (1...31).contains(day) ? "\(day).calendar" : "calendar"
    }

    /// One concrete way to get the first save in, tuned to the tab or chip.
    private var emptyPrompt: String {
        if let category {
            switch category.lowercased() {
            case "gig": return "Got tickets on DICE or Ticketmaster? Share the link."
            case "restaurant": return "Share one from Maps or Instagram."
            case "exhibition", "gallery": return "Share the show\u{2019}s page from the gallery\u{2019}s site."
            case "film": return "Share the cinema\u{2019}s listing."
            case "theatre": return "Share the play\u{2019}s page."
            case "cafe": return "Share one from Maps or Instagram."
            case "park", "outdoors": return "Share it from Maps."
            case "museum": return "Share it from Maps or the museum\u{2019}s site."
            case "festival": return "Share the lineup or the ticket page."
            default: return "Share a link, or tap + and type it."
            }
        }
        // Alone, the invite is the next step; together, it's that the
        // others see it too.
        let how = kind == Item.Kind.place
            ? "Share it from Maps or Instagram, or tap + and type the name."
            : "Share a link from anywhere, or tap + and type it."
        return how + (sharedLibrary ? seenBy : " Invite someone from Settings to plan together.")
    }

    /// More than one member on the card: saves are for everyone in it.
    private var sharedLibrary: Bool { (GroupStore.shared.card?.members.count ?? 1) > 1 }

    private var seenBy: String {
        guard sharedLibrary else { return "" }
        return (GroupStore.shared.card?.members.count ?? 0) > 2 ? " Everyone sees it." : " You\u{2019}ll both see it."
    }

    /// Just joined, first pull still running: the library isn't empty, it
    /// hasn't arrived yet. Named after the person whose saves are coming.
    private var awaitingFirstPull: Bool {
        sharedLibrary && !syncStatus.hasSyncedOnce && syncStatus.syncing
    }

    private var partnerFirstName: String? {
        guard let card = GroupStore.shared.card else { return nil }
        let me = SupabaseAuth.shared.userId
        return card.members.first { $0.userId != me }.flatMap {
            $0.displayName?.isEmpty == false ? $0.displayName : MembersStore.shared.name(forUser: $0.userId)
        }
    }

    /// The journal at the end of the list. Events keep theirs folded into a
    /// collapsed Archive; Places just show where you've been. A search
    /// unfolds it: "did we go to that?" is half of what search is for.
    @ViewBuilder
    private var journal: some View {
        if kind == Item.Kind.event {
            if !query.isEmpty {
                if !been.isEmpty {
                    SectionHeader(title: Voice.didGoSection, count: been.count)
                        .frame(minHeight: 44)
                        .cardListRow()
                    ForEach(been) { item in
                        ItemCardRow(item: item, compact: true) {
                            selected = item
                        }
                    }
                }
                if !missed.isEmpty {
                    SectionHeader(title: "Missed", count: missed.count)
                        .frame(minHeight: 44)
                        .cardListRow()
                    ForEach(missed) { item in
                        ItemCardRow(item: item, compact: true) {
                            selected = item
                        }
                    }
                }
            } else {
                eventArchive
            }
        } else if !been.isEmpty {
            SectionHeader(title: Voice.didGoSection, count: been.count)
                .frame(minHeight: 44)
                .cardListRow()
            if query.isEmpty {
                JournalTally(items: been)
                    .cardListRow()
            }
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
                if reduceMotion {
                    archiveOpen.toggle()
                } else {
                    withAnimation(.snappy) { archiveOpen.toggle() }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Archive")
                    Text("\(archiveAll.count)")
                        .foregroundStyle(AppBackground.ink.opacity(SectionHeader.countOpacity))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(archiveOpen ? 90 : 0))
                        .animation(reduceMotion ? nil : .snappy, value: archiveOpen)
                }
                .font(.footnote.weight(.semibold))
                // Same ink shares as SectionHeader, so the count is always
                // the dimmer of the two on every theme.
                .foregroundStyle(AppBackground.ink.opacity(SectionHeader.titleOpacity))
                .padding(.leading, 4)
                .padding(.top, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archive, \(archiveAll.count)")
            .accessibilityHint(archiveOpen ? "Collapse" : "Expand")
            .accessibilityAddTraits(.isButton)
            .frame(minHeight: 44)
            .cardListRow()

            if archiveOpen {
                Picker("Archive filter", selection: $archiveSide.animation(.snappy)) {
                    ForEach(ArchiveSide.allCases, id: \.self) { Text($0.label) }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: archiveSide)
                .padding(.top, 4)
                .frame(minHeight: 44)
                .cardListRow()

                if archiveSide == .been {
                    JournalTally(items: been)
                        .cardListRow()
                }
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
            capCounts: CategoryCap.applies ? CategoryCap.tally(items) : [:],
            areas: areas,
            category: $category,
            area: $area,
            showsNearMe: kind == Item.Kind.place && LocationStore.shared.location != nil,
            showsOpenNow: kind == Item.Kind.place,
            nearMe: $nearMe,
            openNow: $openNow,
            checkingHours: checkingHours
        )
    }
}

/// Liquid Glass filter chips — the one custom control layer here.
/// Categories first, then (for Places) neighbourhoods after a divider.
///
/// Deliberately its own view so a chip toggle re-renders only this row,
/// not the whole page (sections, sorts and all) behind it.
private struct ChipRow: View {
    let categories: [String]
    /// Free groups only: active saves per category key, for the "3/4"
    /// shown once a category is one away from the cap.
    let capCounts: [String: Int]
    let areas: [String]
    @Binding var category: String?
    @Binding var area: String?
    var showsNearMe = false
    var showsOpenNow = false
    @Binding var nearMe: Bool
    @Binding var openNow: Bool
    var checkingHours = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // No GlassEffectContainer here on purpose: it exists to morph
            // nearby glass shapes into each other, so while the row scrolls
            // adjacent chips kept trying to coalesce — warping mid-swipe and
            // costing a full re-composite every frame. Independent chips
            // never need to merge; each carries its own glass.
            HStack(spacing: 8) {
                if showsNearMe {
                    chip("Near me", symbol: "location.fill", isOn: nearMe) { nearMe.toggle() }
                }
                if showsOpenNow {
                    chip("Open now", symbol: "clock", isOn: openNow, busy: checkingHours) { openNow.toggle() }
                }
                if (showsNearMe || showsOpenNow) && (categories.count > 1 || areas.count > 1) {
                    Rectangle()
                        .fill(AppBackground.ink.opacity(0.25))
                        .frame(width: 1, height: 16)
                }
                if categories.count > 1 {
                    ForEach(categories, id: \.self) { c in
                        chip(Item.categoryLabel(c), isOn: category == c, cap: capCounts[CategoryCap.key(c)]) {
                            category = category == c ? nil : c
                        }
                    }
                }
                if categories.count > 1 && areas.count > 1 {
                    Rectangle()
                        .fill(AppBackground.ink.opacity(0.25))
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
            .padding(.horizontal, 20)
        }
        // Clipped, but not at its own bounds: those crop the glass's soft
        // shadow into a hard-edged band behind the row (strongest on iOS
        // 26). A fixed margin holds the shadow and keeps the draw rect
        // bounded. Fully unclipped, the row spills into the cards above
        // and below and the list remeasures that on every drag.
        .scrollClipDisabled()
        .clipShape(.rect.inset(by: -64))
    }

    private func chip(_ label: String, symbol: String? = nil, isOn: Bool, busy: Bool = false, cap: Int? = nil, toggle: @escaping () -> Void) -> some View {
        let shown = cap.flatMap { $0 >= CategoryCap.limit - 1 ? min($0, CategoryCap.limit) : nil }
        return Button {
            Haptics.selection()
            withAnimation(.snappy) { toggle() }
        } label: {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini).tint(isOn ? AppBackground.base : AppBackground.ink)
                } else if let symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
                Text(label)
                if let shown {
                    Text("\(shown)/\(CategoryCap.limit)")
                        .monospacedDigit()
                        .opacity(0.6)
                        .accessibilityLabel("\(shown) of \(CategoryCap.limit)")
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityHint(isOn ? "Clears this filter" : "Filters the list")
        // Explicit colors: the system styles both resolve near-white here,
        // leaving white text on white glass.
        .foregroundStyle(isOn ? AppBackground.base : AppBackground.ink)
        // Not .interactive(): touch-tracking glass deforms under the finger,
        // which reads as wobble when a swipe drags across the row.
        .glassEffect(
            isOn ? .regular.tint(AppBackground.ink.opacity(0.92)) : .regular,
            in: .capsule
        )
    }
}

