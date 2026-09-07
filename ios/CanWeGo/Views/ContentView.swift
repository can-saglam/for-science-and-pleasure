import CoreSpotlight
import SwiftData
import SwiftUI

/// Where the bottom bar's add button actually sits, in global coordinates —
/// the map's locate-me control docks itself directly above it.
@Observable
final class PlusButtonFrame {
    static let shared = PlusButtonFrame()
    var rect: CGRect = .zero
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var items: [Item]
    // CWG_CAPTURE is only set by automated screenshot runs.
    @State private var captureOpen = ProcessInfo.processInfo.environment["CWG_CAPTURE"] != nil
    // CWG_TAB is only set by automated screenshot runs; users always start at 0.
    @State private var tab = ProcessInfo.processInfo.environment["CWG_TAB"].flatMap(Int.init) ?? 0
    @State private var undoBin = UndoBin.shared
    @State private var syncStatus = SyncStatus.shared
    // CWG_DIGEST is only set by automated screenshot runs.
    @State private var digestOpen = ProcessInfo.processInfo.environment["CWG_DIGEST"] != nil
    /// An item summoned from outside the lists: a tapped last-chance
    /// notification or a Spotlight result.
    @State private var deepLinked: Item?
    /// A notification/widget/Spotlight tap on a save that no longer exists.
    @State private var goneItem = false

    /// Drives the stretchy selection pill in the bottom bar.
    @Namespace private var barNamespace

    var body: some View {
        // Two tabs live in a TabView for state-keeping, but the system bar
        // is hidden — our own compact bar draws at the bottom instead.
        TabView(selection: $tab) {
            Tab("The Plan", systemImage: "building.columns", value: 0) {
                LibraryView(kind: Item.Kind.event)
                    .toolbarVisibility(.hidden, for: .tabBar)
            }
            Tab("The Fuel", systemImage: "fork.knife", value: 1) {
                LibraryView(kind: Item.Kind.place)
                    .toolbarVisibility(.hidden, for: .tabBar)
            }
        }
        // A soft tick as you move between tabs.
        .sensoryFeedback(.selection, trigger: tab)
        // Events | Places grouped in one pill, the add button beside it.
        .overlay(alignment: .bottom) {
            bottomBar
        }
        .sheet(isPresented: $captureOpen) {
            CaptureView()
        }
        .sheet(isPresented: $digestOpen) {
            WeeklyDigestSheet()
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
        .onReceive(NotificationCenter.default.publisher(for: .cwgOpenDigest)) { _ in
            DigestGate.pending = false
            digestOpen = true
        }
        .sheet(item: $deepLinked) { ItemDetailView(item: $0) }
        .alert("This save was removed", isPresented: $goneItem) {
            Button("OK") {}
        } message: {
            Text("One of you deleted it since, so there's nothing left to open. Everything else is where you left it.")
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
        // Five-second Undo after any swipe-delete or "We did go!".
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
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
            .padding(.bottom, 96)
        }
        .animation(.snappy, value: undoBin.deleted?.id)
        .animation(.snappy, value: undoBin.done?.id)
        // First sign-in on a fresh install: don't present empty tabs while
        // the shared library is still on its way down — and if that first
        // pull fails, say so instead of leaving a silent blank app.
        .overlay {
            if SupabaseAuth.shared.signedIn, !syncStatus.hasSyncedOnce, items.isEmpty {
                if syncStatus.syncing {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("Pulling your shared library…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppBackground.base.ignoresSafeArea())
                    .transition(.opacity)
                } else if syncStatus.problem != nil {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Couldn't load your library")
                            .font(.headline)
                        Text("Check your connection and try again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
                    .background(AppBackground.base.ignoresSafeArea())
                    .transition(.opacity)
                }
            }
        }
        .animation(.snappy, value: syncStatus.syncing)
        // Controls pick up the theme's accent; the selected tab, toolbar
        // buttons, and links all shift with it.
        .tint(AppBackground.accent)
        // All three themes are dark bases — light text always.
        .preferredColorScheme(.dark)
        .task {
            // Bundle seeds are only for the offline demo path (CWG_SKIP_AUTH);
            // signed-in libraries come from the first Supabase pull instead.
            if !SupabaseAuth.shared.signedIn {
                SeedImporter.runIfNeeded(context: context)
            }
        }
        // Sweep anything the share extension parked in the App Group inbox,
        // then refresh the shared URL index and last-chance notifications.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            // A digest push tapped before the UI existed (cold start).
            if DigestGate.pending {
                DigestGate.pending = false
                digestOpen = true
            }
            // Same for a last-chance notification naming one item.
            if let pending = ItemGate.pending {
                openItem(pending)
            }
            let existing = Set(items.compactMap { $0.url.map(SavedURLIndex.normalize) })
            let pending = SharedInbox.drain()
            var drained: [Item] = []
            for save in pending {
                // The extension warns about duplicates, but its index can
                // lag — this is the authoritative check.
                if let url = save.url, existing.contains(SavedURLIndex.normalize(url)) {
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
            SavedURLIndex.rebuild(from: items.compactMap(\.url) + pending.compactMap(\.url))
            Task { await LastChanceNotifier.sync(items: items) }
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
        }
        // Any local save (add, edit, done, delete-undo…) syncs to the shared
        // table after a short debounce.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            SupabaseSync.schedule(context: context)
        }
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
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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

    // MARK: - Bottom bar

    /// The whole navigation in one line: a glass pill holding the two tabs,
    /// and the add button as its own circle beside it.
    private var bottomBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    navButton("The Plan", icon: "building.columns", value: 0)
                    navButton("The Fuel", icon: "fork.knife", value: 1)
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)

                Button {
                    Haptics.tap()
                    captureOpen = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular.tint(.white.opacity(0.42)).interactive(),
                    in: .circle
                )
                .accessibilityLabel("Add something")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    PlusButtonFrame.shared.rect = $0
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func navButton(_ title: String, icon: String, value: Int) -> some View {
        Button {
            // Tapping the tab you're already on scrolls its list back to
            // the top — the platform convention.
            guard tab != value else {
                NotificationCenter.default.post(name: .cwgScrollToTop, object: nil)
                return
            }
            withAnimation(.snappy) { tab = value }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // Explicit colors, same trick as the filter chips: the selected
        // side inverts onto a near-white pill.
        .foregroundStyle(tab == value ? AppBackground.base : .white)
        .background {
            if tab == value {
                // One shared pill that stretches from side to side on
                // switch — the native tab bar's liquid slide.
                Capsule()
                    .fill(.white.opacity(0.92))
                    .matchedGeometryEffect(id: "barSelection", in: barNamespace)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
