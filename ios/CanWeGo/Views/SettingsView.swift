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
    @State private var enriching = false
    @State private var enrichProgress = ""
    @State private var enrichNote: String?
    @State private var enrichProposals: [EnrichProposal]?
    @State private var digest = DigestScheduleStore.shared
    @State private var digestPreview = false
    /// Photos bleeding into list cards — same key ItemCard reads.
    @AppStorage("cardThumbnails", store: UserDefaults(suiteName: SharedInbox.groupID))
    private var cardThumbnails = true
    /// Which maps app gets the directions taps — same key `TransportApp` reads.
    @AppStorage(TransportApp.key, store: UserDefaults(suiteName: SharedInbox.groupID))
    private var transportApp = TransportApp.google.rawValue

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

    /// Active saves with at least one gap the parser might fill. No URL is
    /// fine — the backend can identify a bare name by web search.
    private var enrichable: [Item] {
        items
            .filter { item in
                guard !item.isDone, !item.isMissed else { return false }
                return item.summary == nil || item.venue == nil || item.area == nil
                    || item.category == nil || item.imageUrl == nil || item.lat == nil
                    || (item.isEvent && item.startsOn == nil && item.endsOn == nil)
            }
            // Oldest first — they were saved when the parser knew the least.
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func enrich() async {
        enriching = true
        enrichNote = nil
        defer {
            enriching = false
            enrichProgress = ""
        }
        // A slice per run: each item is a full parse (page fetch + model),
        // so the whole batch stays under a couple of minutes.
        let batch = Array(enrichable.prefix(8))
        var found: [EnrichProposal] = []
        for (i, item) in batch.enumerated() {
            enrichProgress = "\(i + 1) of \(batch.count)"
            // Send the name along with the link: opaque or blocked URLs
            // (Reddit share links…) are useless on their own, but the title
            // gives the backend's web search something to chase.
            let text = [item.title, item.url ?? item.area ?? "London"]
                .joined(separator: "\n")
            guard let card = try? await ParseClient.parse(text: text, imageJPEG: nil),
                  let proposal = EnrichProposal(item: item, card: card)
            else { continue }
            found.append(proposal)
        }
        if found.isEmpty {
            enrichNote = "Nothing new found this round."
        } else {
            enrichProposals = found
        }
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                // The wordmark as the hero — settings opens on the brand,
                // with the version tucked quietly beneath it.
                Section {
                    VStack(spacing: 10) {
                        LogoTitle(height: 44)
                        Text("Your city, planned by you or together. The exhibitions, gigs and good food you keep meaning to get to, saved before the moment passes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                        Text("for science and pleasure · v\(version)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    // Pulls the hero up against the grouped list's default
                    // top margin, so the brand sits closer to the close button.
                    .padding(.top, -16)
                    .padding(.bottom, 6)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section("Appearance") {
                    themeRow
                    Toggle(isOn: $cardThumbnails) {
                        row("Photos on cards", icon: "photo.fill")
                    }
                    .tint(AppBackground.accent)
                    .sensoryFeedback(.selection, trigger: cardThumbnails)
                    Picker(selection: $transportApp) {
                        ForEach(TransportApp.allCases) { app in
                            Text(app.name).tag(app.rawValue)
                        }
                    } label: {
                        row("Directions in", icon: "map.fill")
                    }
                    .sensoryFeedback(.selection, trigger: transportApp)
                }
                .listRowBackground(Self.rowBackground)

                Section {
                    // Until the shared schedule arrives from the server the
                    // pickers would show the hard-coded default and then
                    // flip — a quiet dash is more honest than a wrong day.
                    if SupabaseAuth.shared.signedIn && !digest.loaded {
                        LabeledContent { Text("—") } label: {
                            row("Day", icon: "bell.badge.fill")
                        }
                        LabeledContent { Text("—") } label: {
                            row("Time", icon: "clock.fill")
                        }
                    } else {
                        Picker(selection: digestDay) {
                            ForEach(1...7, id: \.self) { day in
                                Text(DigestScheduleStore.dayNames[day - 1]).tag(day)
                            }
                        } label: {
                            row("Day", icon: "bell.badge.fill")
                        }
                        .disabled(!SupabaseAuth.shared.signedIn)
                        DatePicker(selection: digestTime, displayedComponents: .hourAndMinute) {
                            row("Time", icon: "clock.fill")
                        }
                        .disabled(!SupabaseAuth.shared.signedIn)
                    }
                    Button {
                        Haptics.tap()
                        digestPreview = true
                    } label: {
                        row("Preview the weekend", icon: "text.rectangle.page")
                    }
                } header: {
                    Text("Weekend digest")
                } footer: {
                    // Follows the picked day — a hardcoded "Thursday" here
                    // once contradicted the picker sitting right above it.
                    // Until the shared schedule loads, no day is promised.
                    Text(
                        SupabaseAuth.shared.signedIn && !digest.loaded
                            ? "Once a week: what's closing, happening, and opening over the weekend. One notification for you both."
                            : "Every \(DigestScheduleStore.dayNames[digest.dayOfWeek - 1]): what's closing, happening, and opening over the weekend. One notification for you both."
                    )
                }
                .listRowBackground(Self.rowBackground)

                Section {
                    ShareLink(item: exportFile()) {
                        row("Export as Markdown", icon: "square.and.arrow.up")
                    }
                    Button {
                        Task { await findLocations() }
                    } label: {
                        HStack {
                            row("Find missing locations", icon: "mappin.and.ellipse")
                            Spacer()
                            if locating {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(locating || unlocated.isEmpty)
                    Button {
                        Task { await enrich() }
                    } label: {
                        HStack {
                            row("Enrich older saves", icon: "wand.and.stars")
                            Spacer()
                            if enriching {
                                Text(enrichProgress)
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                ProgressView()
                            }
                        }
                    }
                    .disabled(enriching || enrichable.isEmpty)
                } header: {
                    Text("Your library")
                } footer: {
                    Text(footerText)
                }
                .listRowBackground(Self.rowBackground)

                if let note = locateError ?? enrichNote {
                    Section {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(locateError != nil ? .red : .secondary)
                    }
                    .listRowBackground(Self.rowBackground)
                }

                Section {
                    if let email = SupabaseAuth.shared.email {
                        LabeledContent {
                            Text(email)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } label: {
                            row("Signed in", icon: "person.fill")
                        }
                        if let synced = SyncStatus.shared.lastSyncedAt {
                            LabeledContent {
                                Text(synced.formatted(.relative(presentation: .named)))
                            } label: {
                                row("Last synced", icon: "arrow.triangle.2.circlepath")
                            }
                        }
                        if let problem = SyncStatus.shared.problem {
                            VStack(alignment: .leading, spacing: 6) {
                                row("Sync issue", icon: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(problem.message)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if let detail = problem.detail {
                                    Text(detail)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                        .lineLimit(4)
                                }
                            }
                        }
                        Button(role: .destructive) {
                            Haptics.tap()
                            SupabaseSync.resetCursor()
                            SupabaseAuth.shared.signOut()
                        } label: {
                            row("Sign out", icon: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.red)
                        }
                    } else {
                        Label {
                            Text("Not signed in. Saves stay on this device.")
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
            }
            .appBackground(AppBackground.sheet)
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
            .task { await digest.pull() }
            .sheet(isPresented: $digestPreview) { WeeklyDigestSheet() }
            // CWG_ENRICH is only set by automated test runs.
            .task {
                if ProcessInfo.processInfo.environment["CWG_ENRICH"] != nil {
                    await enrich()
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
            .sheet(
                isPresented: Binding(
                    get: { enrichProposals != nil },
                    set: { if !$0 { enrichProposals = nil } }
                )
            ) {
                if let enrichProposals {
                    EnrichProposalsSheet(proposals: enrichProposals, items: items) {
                        self.enrichProposals = nil
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// One row, modern-settings style: a small icon squircle, then the
    /// title. Monochrome — every badge wears the current theme's accent,
    /// with the icon glyph in the theme base for contrast.
    private func row(_ title: String, icon: String) -> some View {
        Label {
            // No explicit color: lets callers tint the title (e.g. Sign out).
            Text(title)
        } icon: {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppBackground.base)
                .frame(width: 28, height: 28)
                .background(AppBackground.accent.gradient, in: .rect(cornerRadius: 7, style: .continuous))
        }
    }

    /// The three moods side by side — swatch, name, a ring on the current one.
    private var themeRow: some View {
        HStack(spacing: 8) {
            ForEach(AppTheme.allCases) { theme in
                let selected = ThemeStore.shared.current == theme
                Button {
                    Haptics.selection()
                    withAnimation(.snappy) {
                        ThemeStore.shared.current = theme
                    }
                    // The home screen icon follows the theme. Compiled out of
                    // the share extension, where UIApplication is off-limits
                    // (and Settings is never presented anyway).
                    #if !APP_EXTENSION
                        if UIApplication.shared.alternateIconName != theme.iconName {
                            UIApplication.shared.setAlternateIconName(theme.iconName)
                        }
                    #endif
                } label: {
                    VStack(spacing: 7) {
                        ZStack {
                            Circle().fill(theme.base)
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle().strokeBorder(
                                selected ? .white : .white.opacity(0.25),
                                lineWidth: selected ? 2 : 1
                            )
                        )
                        Text(theme.name)
                            .font(.caption2.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        selected ? Color.white.opacity(0.08) : .clear,
                        in: .rect(cornerRadius: 12, style: .continuous)
                    )
                    .contentShape(.rect(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    /// Picker bindings that write straight through to the shared row —
    /// the partner's app picks the change up on its next Settings visit.
    private var digestDay: Binding<Int> {
        Binding(
            get: { digest.dayOfWeek },
            set: { day in
                Haptics.selection()
                digest.dayOfWeek = day
                Task { await digest.push() }
            }
        )
    }

    private var digestTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    from: DateComponents(hour: digest.hour, minute: digest.minute)
                ) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                digest.hour = parts.hour ?? 10
                digest.minute = parts.minute ?? 0
                Task { await digest.push() }
            }
        )
    }

    private var footerText: String {
        var lines: [String] = []
        lines.append(
            unlocated.isEmpty
                ? "Everything has a pin."
                : "\(unlocated.count) save\(unlocated.count == 1 ? "" : "s") without a pin."
        )
        if !enrichable.isEmpty {
            lines.append(
                "\(enrichable.count) save\(enrichable.count == 1 ? "" : "s") could use richer details. Looks each one up again, 8 at a time."
            )
        }
        lines.append("Nothing is applied until you confirm.")
        return lines.joined(separator: " ")
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
                lines.append("- **\(i.title)**\(meta.isEmpty ? "" : " · \(meta.joined(separator: " · "))")")
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
                        Text(p.confidence == "high" ? "confident" : "best guess, check it")
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
        // Fill-only, and sent as column patches so a partner's concurrent
        // edit elsewhere on the row is never overwritten.
        var patches: [(Item, [String: Any])] = []
        for p in proposals where accepted.contains(p.id) {
            guard let item = item(for: p) else { continue }
            var fields: [String: Any] = ["lat": p.lat, "lng": p.lng]
            item.lat = p.lat
            item.lng = p.lng
            if item.venue == nil, let venue = p.venue { item.venue = venue; fields["venue"] = venue }
            if item.area == nil, let area = p.area { item.area = area; fields["area"] = area }
            if item.address == nil, let address = p.address { item.address = address; fields["address"] = address }
            patches.append((item, fields))
        }
        try? context.save()
        onDone()
        Task {
            for (item, fields) in patches {
                await SupabaseSync.patchOrSync(item, fields, context: context)
            }
        }
    }
}

// MARK: - Enrichment proposals

/// A fresh parse of one item's URL, reduced to just the fields the item is
/// missing. Fill-only: nothing an item already has is ever touched.
struct EnrichProposal: Identifiable {
    let id: UUID
    let card: ParseClient.Card
    /// Human-readable list of what would be added, for the review sheet.
    let additions: [String]

    init?(item: Item, card: ParseClient.Card) {
        var adds: [String] = []
        func gap(_ current: String?, _ new: String?, _ label: String) {
            guard current?.isEmpty != false, let new, !new.isEmpty else { return }
            adds.append("\(label): \(new)")
        }
        gap(item.venue, card.venue, "venue")
        gap(item.area, card.area, "area")
        gap(item.address, card.address, "address")
        gap(item.category, card.category, "category")
        gap(item.price, card.price, "price")
        if item.summary?.isEmpty != false, card.summary?.isEmpty == false {
            adds.append("summary")
        }
        if item.imageUrl == nil, card.image_url != nil {
            adds.append("photo")
        }
        if item.lat == nil, card.lat != nil, card.lng != nil {
            adds.append("map pin")
        }
        if item.isEvent {
            gap(item.startsOn, card.starts_on, "starts")
            gap(item.endsOn, card.ends_on, "ends")
        }
        guard !adds.isEmpty else { return nil }
        id = item.id
        self.card = card
        additions = adds
    }

    /// Writes only into empty fields and returns exactly the columns it
    /// filled — the patch the caller sends, so nothing else on the row is
    /// touched.
    func apply(to item: Item) -> [String: Any] {
        var fields: [String: Any] = [:]
        func fill(_ path: ReferenceWritableKeyPath<Item, String?>, _ column: String, _ value: String?) {
            guard item[keyPath: path]?.isEmpty != false,
                  let value, !value.isEmpty else { return }
            item[keyPath: path] = value
            fields[column] = value
        }
        fill(\.summary, "summary", card.summary)
        fill(\.venue, "venue", card.venue)
        fill(\.area, "area", card.area)
        fill(\.address, "address", card.address)
        fill(\.category, "category", card.category)
        fill(\.price, "price", card.price)
        fill(\.imageUrl, "image_url", card.image_url)
        fill(\.colorHex, "color", card.color)
        if item.lat == nil, let lat = card.lat, let lng = card.lng {
            item.lat = lat
            item.lng = lng
            fields["lat"] = lat
            fields["lng"] = lng
        }
        if item.isEvent {
            fill(\.startsOn, "starts_on", card.starts_on)
            fill(\.endsOn, "ends_on", card.ends_on)
        }
        return fields
    }
}

/// Same confirm-before-apply shape as the locations sheet.
private struct EnrichProposalsSheet: View {
    let proposals: [EnrichProposal]
    let items: [Item]
    let onDone: () -> Void

    @Environment(\.modelContext) private var context
    @State private var accepted: Set<UUID> = []

    private func item(for proposal: EnrichProposal) -> Item? {
        items.first { $0.id == proposal.id }
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
            .navigationTitle("Confirm details")
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
                accepted = Set(proposals.map(\.id))
            }
        }
    }

    private func row(_ p: EnrichProposal, item: Item) -> some View {
        Button {
            Haptics.selection()
            if accepted.contains(p.id) {
                accepted.remove(p.id)
            } else {
                accepted.insert(p.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: accepted.contains(p.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.accentColor)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                    ForEach(p.additions, id: \.self) { addition in
                        Text(addition)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func apply() {
        Haptics.success()
        var patches: [(Item, [String: Any])] = []
        for p in proposals where accepted.contains(p.id) {
            guard let item = item(for: p) else { continue }
            let fields = p.apply(to: item)
            if !fields.isEmpty { patches.append((item, fields)) }
        }
        try? context.save()
        onDone()
        Task {
            for (item, fields) in patches {
                await SupabaseSync.patchOrSync(item, fields, context: context)
            }
        }
    }
}

// MARK: - Toolbar hook

/// Gear button + sheet, self-contained so callers can slot it anywhere in
/// a toolbar and control the ordering explicitly.
struct SettingsButton: View {
    @State private var open = false

    var body: some View {
        Button {
            Haptics.tap()
            open = true
        } label: {
            // Softened white at semibold — bright icons shouted over the
            // content; all three header icons match.
            Image(systemName: "gearshape")
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.72))
        }
        .accessibilityLabel("Settings")
        // Explicit accent: this sheet is presented from inside the nav bar's
        // dimmed-white tint scope, which would otherwise wash its controls.
        .sheet(isPresented: $open) { SettingsView().tint(AppBackground.accent) }
        // CWG_SETTINGS is only set by automated test runs.
        .task {
            if ProcessInfo.processInfo.environment["CWG_SETTINGS"] != nil {
                open = true
            }
        }
    }
}
