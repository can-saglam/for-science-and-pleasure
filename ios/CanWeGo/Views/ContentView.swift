import SwiftData
import SwiftUI

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

    /// Windows about to shut — surfaced right on the tab icon.
    private var lastChanceCount: Int {
        items.count { $0.isEvent && !$0.isDone && $0.timeBucket == .lastChance }
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("This Week", systemImage: "paintpalette", value: 0) {
                ThisWeekView()
            }
            .badge(lastChanceCount)
            Tab("Events", systemImage: "books.vertical", value: 1) {
                LibraryView(kind: Item.Kind.event)
            }
            Tab("Places", systemImage: "mappin.and.ellipse", value: 2) {
                LibraryView(kind: Item.Kind.place)
            }
            Tab("We Did Go", systemImage: "shoeprints.fill", value: 3) {
                WeDidGoView()
            }
        }
        // A soft tick as you move between tabs.
        .sensoryFeedback(.selection, trigger: tab)
        // One floating glass circle in the bottom-right corner — no
        // accessory slot (its container always draws a full-width pill).
        .overlay(alignment: .bottomTrailing) {
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
            .padding(.trailing, 20)
            .padding(.bottom, 76)
            .accessibilityLabel("Add something")
        }
        .sheet(isPresented: $captureOpen) {
            CaptureView()
        }
        // Five-second Undo after any swipe-delete.
        .overlay(alignment: .bottom) {
            if let deleted = undoBin.deleted {
                HStack(spacing: 14) {
                    Text("Deleted \u{201c}\(deleted.title)\u{201d}")
                        .font(.subheadline)
                        .lineLimit(1)
                    Button("Undo") {
                        Haptics.tap()
                        undoBin.restore(into: context)
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 24)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: undoBin.deleted?.id)
        // First sign-in on a fresh install: don't present empty tabs while
        // the shared library is still on its way down.
        .overlay {
            if SupabaseAuth.shared.signedIn, !syncStatus.hasSyncedOnce,
               syncStatus.syncing, items.isEmpty {
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
        // Older saves get their page thumbnails fetched in the background.
        .task { await ThumbnailBackfill.run(context: context) }
        // Sweep anything the share extension parked in the App Group inbox,
        // then refresh the shared URL index and last-chance notifications.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
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
            Task { await SupabaseSync.sync(context: context) }
        }
        // Any local save (add, edit, done, delete-undo…) syncs to the shared
        // table after a short debounce.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            SupabaseSync.schedule(context: context)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
