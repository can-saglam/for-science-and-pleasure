import CoreSpotlight
import SwiftData
import SwiftUI
import UIKit

/// Where the bottom bar's add button actually sits, in global coordinates —
/// the map's locate-me control docks itself directly above it.
@Observable
final class PlusButtonFrame {
    static let shared = PlusButtonFrame()
    /// Read off the tab bar's own Add button.
    var measured: CGRect = .zero
    /// A ghost laid out with the bar's known metrics, in case the read
    /// ever comes back empty.
    var fallback: CGRect = .zero
    var best: CGRect { measured != .zero ? measured : fallback }

    /// The bar's Add circle by its known metrics: 62 pt, 21 pt in from the
    /// trailing edge and the bottom of the screen.
    static func ghost(in screen: CGRect) -> CGRect {
        let side: CGFloat = 62, inset: CGFloat = 21
        return CGRect(x: screen.maxX - inset - side, y: screen.maxY - inset - side, width: side, height: side)
    }
}

/// Reports the on-screen frame of the tab bar's Add circle. UIKit draws
/// that button and never publishes where, so this reads it back through
/// public API: the bar's subview tree and the button's accessibility label
/// (which is the tab's title).
private struct TabBarAddButtonReader: UIViewRepresentable {
    let title: String

    func makeUIView(context: Context) -> ReaderView { ReaderView(title: title) }
    func updateUIView(_ view: ReaderView, context: Context) { view.scheduleRead() }

    final class ReaderView: UIView {
        private let title: String

        init(title: String) {
            self.title = title
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleRead()
            // The bar settles a beat after the content on first launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.read() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleRead()
        }

        func scheduleRead() {
            // The bar lays out after us; read once this pass has settled.
            DispatchQueue.main.async { [weak self] in self?.read() }
        }

        private func read() {
            guard let window,
                  let bar = window.firstDescendant(where: { $0 is UITabBar }),
                  let add = bar.firstDescendant(where: {
                      $0.accessibilityLabel == title && $0.bounds.width >= 40
                  })
            else { return }
            let rect = add.convert(add.bounds, to: nil)
            guard rect.width > 0, rect != PlusButtonFrame.shared.measured else { return }
            PlusButtonFrame.shared.measured = rect
        }
    }
}

private extension UIView {
    func firstDescendant(where test: (UIView) -> Bool) -> UIView? {
        for sub in subviews {
            if test(sub) { return sub }
            if let hit = sub.firstDescendant(where: test) { return hit }
        }
        return nil
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var items: [Item]
    // CWG_CAPTURE is only set by automated screenshot runs.
    @State private var captureOpen = ProcessInfo.processInfo.environment["CWG_CAPTURE"] != nil
    // CWG_TAB is only set by automated screenshot runs; users always start at 0.
    @State private var tab = ProcessInfo.processInfo.environment["CWG_TAB"].flatMap(Int.init) ?? 0
    @State private var undoBin = UndoBin.shared
    @State private var syncStatus = SyncStatus.shared
    @State private var group = GroupStore.shared
    /// An item summoned from outside the lists: a tapped reminder
    /// notification or a Spotlight result.
    @State private var deepLinked: Item?
    /// A notification/widget/Spotlight tap on a save that no longer exists.
    @State private var goneItem = false
    /// The Events tab wears today's date; refreshed when the app comes
    /// forward so an overnight leave doesn't leave yesterday on the bar.
    @State private var dayOfMonth = Calendar.current.component(.day, from: Date())

    /// Reads the Add circle off the tab bar, and keeps the by-the-metrics
    /// fallback in step with the screen: this view's frame plus its safe
    /// area insets is the full screen, so `maxY` is the screen bottom.
    private var plusButtonProbe: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { proxy in
                let frame = proxy.frame(in: .global)
                let safe = proxy.safeAreaInsets
                return CGRect(
                    x: frame.minX - safe.leading,
                    y: frame.minY - safe.top,
                    width: frame.width + safe.leading + safe.trailing,
                    height: frame.height + safe.top + safe.bottom
                )
            } action: { screen in
                PlusButtonFrame.shared.fallback = PlusButtonFrame.ghost(in: screen)
            }
            .background {
                TabBarAddButtonReader(title: Self.addTitle)
                    .frame(width: 0, height: 0)
            }
            .allowsHitTesting(false)
    }

    var body: some View {
        // The system tab bar is the only place the bubbly light-bend
        // lives — a custom glass pill can slide, it cannot refract.
        // Add is a search-role tab so it renders as the trailing glass
        // circle; selecting it opens capture and lands back on the tab
        // you were on (see `addAwareTab`).
        TabView(selection: addAwareTab) {
            Tab("Events", systemImage: eventsGlyph, value: 0) {
                LibraryView(kind: Item.Kind.event)
            }
            Tab("Places", systemImage: "building.columns", value: 1) {
                LibraryView(kind: Item.Kind.place)
            }
            Tab(Self.addTitle, systemImage: "plus", value: 2, role: .search) {
                // Never reaches the screen: the selection is handed back
                // in the same update, before UIKit installs this page.
                Color.clear
            }
        }
        // Step 2 of the Add tap: the state really did change to 2, so
        // SwiftUI now pushes the old tab back to the tab bar controller.
        .onChange(of: tab) { old, new in
            if new == addTab { tab = old }
        }
        .sensoryFeedback(.selection, trigger: tab) { (old: Int, new: Int) -> Bool in
            old != addTab && new != addTab
        }
        // Locate-me docks above Add. The system circle's frame is read
        // straight off the tab bar; the fallback is the same circle placed
        // by the bar's metrics — 62 pt, 21 pt in from the trailing edge and
        // the screen bottom — off this full-screen view's own frame, so it
        // lands exactly where the read would.
        .background { plusButtonProbe }
        .sheet(isPresented: $captureOpen) {
            CaptureView()
        }
        // The kill switch. Server-driven; CWG_FORCE_UPDATE only exists so
        // automated runs can photograph the screen without touching the
        // real min_build.
        .fullScreenCover(isPresented: Binding(
            get: { syncStatus.updateRequired || ProcessInfo.processInfo.environment["CWG_FORCE_UPDATE"] != nil },
            set: { _ in }
        )) {
            UpdateRequiredView()
        }
        .sheet(item: $deepLinked) { ItemDetailView(item: $0) }
        .alert("This save was removed", isPresented: $goneItem) {
            Button("OK") {}
        } message: {
            Text("One of you deleted it since, so there's nothing left to open. Everything else is where you left it.")
        }
        // The card says this account is in a different group from the one
        // the local library was pulled for (someone joined or left from
        // another device). The sync engine owns the swap; just run it.
        .onChange(of: group.libraryIsForeign) { _, foreign in
            if foreign { Task { await SupabaseSync.sync(context: context) } }
        }
        // …and it says so, once, after the new library has landed.
        .alert(
            "Now showing \u{201c}\(syncStatus.librarySwappedTo ?? "your group")\u{201d}",
            isPresented: Binding(
                get: { syncStatus.librarySwappedTo != nil },
                set: { if !$0 { syncStatus.librarySwappedTo = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text("Your saves now come from this group. See who\u{2019}s in it under Settings.")
        }
        // The library is about to be replaced — close anything showing an item.
        .onReceive(NotificationCenter.default.publisher(for: .cwgLibraryWillSwap)) { _ in
            deepLinked = nil
        }
        // A last-chance notification tapped while the app is alive.
        .onReceive(NotificationCenter.default.publisher(for: .cwgOpenItem)) { note in
            if let id = note.object as? UUID { openItem(id) }
        }
        // A save tapped in iOS system search.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let id = UUID(uuidString: raw) {
                openItem(id)
            }
        }
        // The home-screen widget deep-links canwego://item/<uuid>.
        .onOpenURL { url in
            guard url.scheme == "canwego", url.host() == "item",
                  let id = UUID(uuidString: url.lastPathComponent)
            else { return }
            openItem(id)
        }
        // Five-second Undo after a save, a swipe-delete or "We did go!".
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let saved = undoBin.saved {
                    undoToast("Saved \u{201c}\(saved.title)\u{201d}") {
                        undoBin.undoSave(in: context)
                    }
                }
                if let deleted = undoBin.deleted {
                    undoToast("Deleted \u{201c}\(deleted.title)\u{201d}") {
                        undoBin.restore(into: context)
                    }
                }
                if let done = undoBin.done {
                    undoToast("We did go to \u{201c}\(done.title)\u{201d}!") {
                        undoBin.undoDone(in: context)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 72)
            .accessibilityElement(children: .contain)
        }
        .animation(reduceMotion ? nil : .snappy, value: undoBin.saved?.id)
        .animation(reduceMotion ? nil : .snappy, value: undoBin.deleted?.id)
        .animation(reduceMotion ? nil : .snappy, value: undoBin.done?.id)
        .onChange(of: undoBin.saved?.id) { _, id in
            if id != nil { announceUndo("Saved. Undo available.") }
        }
        .onChange(of: undoBin.deleted?.id) { _, id in
            if id != nil { announceUndo("Deleted. Undo available.") }
        }
        .onChange(of: undoBin.done?.id) { _, id in
            if id != nil { announceUndo("We did go. Undo available.") }
        }
        // First sign-in on a fresh install: don't present empty tabs while
        // the shared library is still on its way down — and if that first
        // pull fails, say so instead of leaving a silent blank app. The same
        // curtain covers a store that belongs to another account until the
        // sync engine has replaced it.
        .overlay {
            if SupabaseAuth.shared.signedIn, !syncStatus.hasSyncedOnce,
               items.isEmpty || group.libraryIsForeign {
                if syncStatus.syncing {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(AppBackground.ink)
                        Text("Pulling your shared library…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { ThemeFill(color: AppBackground.base) }
                    .transition(.opacity)
                } else if let problem = syncStatus.problem {
                    VStack(spacing: 14) {
                        Image(systemName: problem.status == 0 ? "wifi.slash" : "exclamationmark.icloud")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Couldn't load your library")
                            .font(.headline)
                        Text(problem.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            Haptics.tap()
                            Task { await SupabaseSync.sync(context: context) }
                        } label: {
                            Text("Retry")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { ThemeFill(color: AppBackground.base) }
                    .transition(.opacity)
                }
            }
        }
        .animation(.snappy, value: syncStatus.syncing)
        // Controls pick up the theme's accent; the selected tab, toolbar
        // buttons, and links all shift with it.
        .tint(AppBackground.accent)
        .appColorScheme()
        .task {
            // Bundle seeds are only for the offline demo path (CWG_SKIP_AUTH);
            // signed-in libraries come from the first Supabase pull instead.
            if !SupabaseAuth.shared.signedIn {
                SeedImporter.runIfNeeded(context: context)
            }
        }
        // Sweep anything the share extension parked in the App Group inbox,
        // then refresh the shared URL index.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            dayOfMonth = Calendar.current.component(.day, from: Date())
            // A reminder tap that landed before the UI existed (cold start).
            if let pending = ItemGate.pending {
                openItem(pending)
            }
            let existing = Set(items.compactMap { $0.url.map(SavedURLIndex.normalize) })
            let pending = SharedInbox.drain()
            var drained: [Item] = []
            for save in pending {
                // The extension warns about duplicates, but its index can
                // lag — this is the authoritative check.
                if save.allowDuplicate != true,
                   let url = save.url, existing.contains(SavedURLIndex.normalize(url)) {
                    continue
                }
                let item = Item(pending: save)
                item.addedByEmail = SupabaseAuth.shared.email
                context.insert(item)
                drained.append(item)
            }
            if !pending.isEmpty { try? context.save() }
            if !drained.isEmpty {
                // Share-sheet saves ping the other member once they land.
                Task {
                    for item in drained { await SupabaseSync.announceSave(item) }
                }
            }
            SavedURLIndex.rebuild(from: items, extraURLs: pending.compactMap(\.url))
            SpotlightIndex.sync(items: items)
            // Fill the in-memory image cache from disk before the cards
            // need it — off the main thread, so the launch animation never
            // competes with a dozen JPEG decodes. Only the first screenful:
            // warming the whole library once held every decoded image in
            // RAM at once, and the rest loads lazily as it scrolls in.
            ImageStore.prewarm(prewarmURLs)
            // Backfill runs after the pull, not before — on a fresh install
            // the library is empty until the first sync lands.
            Task {
                await SupabaseSync.sync(context: context)
                // Anything new the pull brought in warms up too.
                ImageStore.prewarm(prewarmURLs)
                await ThumbnailBackfill.run(context: context)
                // The widget's snapshot rebuilds after the pull, so it
                // rotates through the freshest library.
                WidgetStore.sync(items: items)
            }
            Task { await MembersStore.shared.refresh() }
            Task { await GroupStore.shared.refresh() }
            // Home first: it's the clock every time label below is read on.
            Task { await HomeStore.shared.refresh() }
        }
        // Any local save (add, edit, done, delete-undo…) syncs to the shared
        // table after a short debounce.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            SupabaseSync.schedule(context: context)
        }
    }

    private func announceUndo(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    /// Deep link from a notification, the widget or Spotlight: present the
    /// item if it exists. It may have been deleted since — then say so,
    /// rather than a tap that appears to do nothing.
    private func openItem(_ id: UUID) {
        ItemGate.pending = nil
        guard let match = items.first(where: { $0.id == id }) else {
            goneItem = true
            return
        }
        deepLinked = match
    }

    /// One glass capsule per undoable act, stacked when both are live.
    private func undoToast(_ message: String, undo: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Text(message)
                .font(.subheadline)
                .lineLimit(1)
            Button("Undo") {
                Haptics.tap()
                undo()
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel("Undo")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    /// The first screenful of images, roughly in the order the lists show
    /// them: urgent events first (the events tab is the landing page), then
    /// places. Everything past this loads lazily on scroll.
    private var prewarmURLs: [URL] {
        let active = items.filter { !$0.isDone }
        let events = active.filter(\.isEvent)
            .sorted { ($0.daysUntilClose ?? .max) < ($1.daysUntilClose ?? .max) }
        let places = active.filter(\.isPlace)
        return Array(
            (events + places)
                .compactMap { $0.imageUrl.flatMap(URL.init(string:)) }
                .prefix(16)
        )
    }

    /// `9.calendar`, `24.calendar`, … — SF Symbols ships one per day.
    private var eventsGlyph: String {
        (1...31).contains(dayOfMonth) ? "\(dayOfMonth).calendar" : "calendar"
    }

    private let addTab = 2
    private static let addTitle = "Add something"

    /// Add is a tab so it can sit in the system glass; choosing it must
    /// not actually land on that tab.
    ///
    /// The tab bar controller has already moved to Add by the time this
    /// setter runs, and SwiftUI only pushes a selection back to UIKit when
    /// its own state changes — refusing the value here (`return` without
    /// writing `tab`) left UIKit sitting on the empty Add page, which was
    /// the black screen behind the capture sheet. So the value is
    /// accepted and immediately handed back in `onChange(of: tab)`; both
    /// happen in one update, before the Add page is ever installed.
    private var addAwareTab: Binding<Int> {
        Binding(
            get: { tab },
            set: { new in
                if new == addTab {
                    Haptics.tap()
                    captureOpen = true
                    tab = addTab
                    return
                }
                if new == tab {
                    NotificationCenter.default.post(name: .cwgScrollToTop, object: nil)
                    return
                }
                tab = new
            }
        )
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
