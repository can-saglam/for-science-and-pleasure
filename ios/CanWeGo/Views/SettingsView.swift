import SwiftData
import SwiftUI

struct SettingsView: View {
    /// Translucent panel rows on the app blue.
    static let rowBackground = Color.white.opacity(0.08)

    @Environment(\.dismiss) private var dismiss
    @Query private var items: [Item]
    @State private var locating = false
    @State private var locateError: String?
    @State private var proposals: [ParseClient.LocationProposal]?

    private var unlocated: [Item] {
        items.filter { $0.lat == nil && !$0.isDone }
    }

    private func findLocations() async {
        locating = true
        locateError = nil
        defer { locating = false }
        do {
            let found = try await ParseClient.locate(items: unlocated)
            proposals = found
        } catch {
            locateError = error.localizedDescription
        }
    }

    private var activeEvents: Int {
        items.count { $0.isEvent && !$0.isDone && !$0.isMissed }
    }
    private var activePlaces: Int {
        items.count { $0.isPlace && !$0.isDone && !$0.isMissed }
    }
    private var been: Int {
        items.count(where: \.isDone)
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Theme") {
                    ForEach(AppTheme.allCases) { theme in
                        Button {
                            Haptics.selection()
                            withAnimation(.snappy) {
                                ThemeStore.shared.current = theme
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(theme.base)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                                    .frame(width: 26, height: 26)
                                Text(theme.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if ThemeStore.shared.current == theme {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppBackground.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Self.rowBackground)

                Section("Your library") {
                    LabeledContent("Events", value: "\(activeEvents)")
                    LabeledContent("Places", value: "\(activePlaces)")
                    LabeledContent("Been", value: "\(been)")
                }
                .listRowBackground(Self.rowBackground)

                Section {
                    ShareLink(item: exportFile()) {
                        Label("Export as Markdown", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Export")
                } footer: {
                    Text("One document with everything — share it to Notes, Files, or anywhere else.")
                }
                .listRowBackground(Self.rowBackground)

                Section {
                    Button {
                        Task { await findLocations() }
                    } label: {
                        HStack {
                            Label("Find missing locations", systemImage: "mappin.and.ellipse")
                            Spacer()
                            if locating {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(locating || unlocated.isEmpty)
                } header: {
                    Text("Housekeeping")
                } footer: {
                    Text(
                        unlocated.isEmpty
                            ? "Everything has a pin."
                            : "\(unlocated.count) save\(unlocated.count == 1 ? "" : "s") without a pin. The model proposes locations; nothing is applied until you confirm."
                    )
                }
                .listRowBackground(Self.rowBackground)
                if let locateError {
                    Section {
                        Text(locateError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(Self.rowBackground)
                }

                Section {
                    if let email = SupabaseAuth.shared.email {
                        LabeledContent("Signed in as", value: email)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let synced = SyncStatus.shared.lastSyncedAt {
                            LabeledContent(
                                "Last synced",
                                value: synced.formatted(.relative(presentation: .named))
                            )
                        }
                        Button(role: .destructive) {
                            Haptics.tap()
                            SupabaseSync.resetCursor()
                            SupabaseAuth.shared.signOut()
                        } label: {
                            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.red)
                        }
                    } else {
                        Label {
                            Text("Not signed in — saves stay on this device.")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.xmark")
                        }
                        .font(.subheadline)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Your shared library syncs with the web app and each other's phones whenever the app is open.")
                }
                .listRowBackground(Self.rowBackground)

                Section {
                    LabeledContent("Version", value: version)
                } footer: {
                    Text("Can We Go? — for science and pleasure.")
                }
                .listRowBackground(Self.rowBackground)
            }
            .appBackground(AppBackground.sheet)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { proposals != nil },
                    set: { if !$0 { proposals = nil } }
                )
            ) {
                if let proposals {
                    LocateProposalsSheet(proposals: proposals, items: items) {
                        self.proposals = nil
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// Same shape as the web export: grouped, human-readable Markdown.
    private func exportFile() -> URL {
        var lines = ["# Can We Go?", ""]

        func section(_ title: String, _ list: [Item]) {
            guard !list.isEmpty else { return }
            lines.append("## \(title)")
            lines.append("")
            for i in list {
                var meta = [i.venue, i.area, i.price].compactMap(\.self)
                if let s = i.startsOn, let e = i.endsOn {
                    meta.append(s == e ? s : "\(s) – \(e)")
                } else if let e = i.endsOn {
                    meta.append("until \(e)")
                }
                lines.append("- **\(i.title)**\(meta.isEmpty ? "" : " — \(meta.joined(separator: " · "))")")
                if let summary = i.summary { lines.append("  \(summary)") }
                if let url = i.url { lines.append("  <\(url)>") }
                if let notes = i.notes, !notes.isEmpty { lines.append("  > \(notes)") }
            }
            lines.append("")
        }

        section("Events", items.filter { $0.isEvent && !$0.isDone && !$0.isMissed })
        section("Places", items.filter { $0.isPlace && !$0.isDone && !$0.isMissed })
        section("Been", items.filter(\.isDone))

        let url = FileManager.default.temporaryDirectory
            .appending(path: "can-we-go.md")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Location proposals

/// Confirm-before-apply, same as the web: pinned proposals are on by
/// default, unpinnable ones are shown greyed out.
private struct LocateProposalsSheet: View {
    let proposals: [ParseClient.LocationProposal]
    let items: [Item]
    let onDone: () -> Void

    @Environment(\.modelContext) private var context
    @State private var accepted: Set<String> = []

    private func item(for proposal: ParseClient.LocationProposal) -> Item? {
        items.first { $0.id.uuidString.lowercased() == proposal.id }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(proposals) { p in
                    if let item = item(for: p) {
                        row(p, item: item)
                            .listRowBackground(SettingsView.rowBackground)
                    }
                }
            }
            .appBackground(AppBackground.sheet)
            .navigationTitle("Confirm locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onDone() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply \(accepted.count)") { apply() }
                        .fontWeight(.semibold)
                        .disabled(accepted.isEmpty)
                }
            }
            .onAppear {
                accepted = Set(proposals.filter { $0.lat != nil }.map(\.id))
            }
        }
    }

    @ViewBuilder
    private func row(_ p: ParseClient.LocationProposal, item: Item) -> some View {
        let pinned = p.lat != nil
        Button {
            guard pinned else { return }
            if accepted.contains(p.id) {
                accepted.remove(p.id)
            } else {
                accepted.insert(p.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: accepted.contains(p.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(pinned ? item.accentColor : Color.secondary)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                    if pinned {
                        Text(
                            [p.venue, p.area, p.address]
                                .compactMap(\.self)
                                .joined(separator: " · ")
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        Text(p.confidence == "high" ? "confident" : "best guess — check it")
                            .font(.caption)
                            .foregroundStyle(p.confidence == "high" ? .green : .orange)
                    } else {
                        Text("Couldn't pin this one down.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(pinned ? 1 : 0.55)
    }

    private func apply() {
        for p in proposals where accepted.contains(p.id) {
            guard let item = item(for: p) else { continue }
            item.lat = p.lat
            item.lng = p.lng
            if item.venue == nil { item.venue = p.venue }
            if item.area == nil { item.area = p.area }
            if item.address == nil { item.address = p.address }
            item.updatedAt = .now
        }
        try? context.save()
        onDone()
    }
}

// MARK: - Toolbar hook

/// Gear button + sheet, applied inside each tab's NavigationStack.
private struct SettingsToolbar: ViewModifier {
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        open = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $open) { SettingsView() }
    }
}

extension View {
    func settingsToolbar() -> some View {
        modifier(SettingsToolbar())
    }
}
