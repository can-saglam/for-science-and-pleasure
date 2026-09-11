import SwiftData
import SwiftUI

struct SettingsView: View {
    @State private var groupUI = GroupUI()
    /// Translucent panel rows on the theme wash.
    static var rowBackground: Color { AppBackground.wash(0.08) }

    @Environment(\.dismiss) private var dismiss
    @Query private var items: [Item]
    @State private var auth = SupabaseAuth.shared
    @State private var themes = ThemeStore.shared
    @State private var showAuth = false
    @State private var confirmSignOut = false
    /// Which maps app gets the directions taps — same key `TransportApp` reads.
    @AppStorage(TransportApp.key, store: UserDefaults(suiteName: SharedInbox.groupID))
    private var transportApp = TransportApp.google.rawValue

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

                GroupSection(ui: groupUI)

                Section("Appearance") {
                    Menu {
                        Picker(selection: theme) {
                            ForEach(AppTheme.allCases) { option in
                                Text(option.name).tag(option)
                            }
                        } label: { EmptyView() }
                    } label: {
                        menuValue("Theme", icon: "paintpalette.fill", value: themes.current.name)
                    }
                    .tint(themes.current.ink)
                    .sensoryFeedback(.selection, trigger: themes.current)
                }
                .listRowBackground(Self.rowBackground)

                Section {
                    Menu {
                        Picker(selection: $transportApp) {
                            ForEach(TransportApp.allCases) { app in
                                Text(app.name).tag(app.rawValue)
                            }
                        } label: { EmptyView() }
                    } label: {
                        menuValue(
                            "Directions in",
                            icon: "map.fill",
                            value: TransportApp(rawValue: transportApp)?.name ?? ""
                        )
                    }
                    .tint(themes.current.ink)
                    .sensoryFeedback(.selection, trigger: transportApp)
                } header: {
                    Text("Directions")
                } footer: {
                    Text("Opens when you tap a place or ask the way.")
                }
                .listRowBackground(Self.rowBackground)

                Section {
                    ShareLink(item: exportFile()) {
                        row("Export as Markdown", icon: "square.and.arrow.up")
                    }
                } header: {
                    Text("Your library")
                }
                .listRowBackground(Self.rowBackground)

                Section {
                    if let email = auth.email {
                        LabeledContent {
                            Text(email)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } label: {
                            row(auth.usesApple ? "Signed in with Apple" : "Signed in",
                                icon: auth.usesApple ? "apple.logo" : "person.fill")
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
                                    .foregroundStyle(AppBackground.warning)
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
                            confirmSignOut = true
                        } label: {
                            row("Sign out", icon: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(AppBackground.destructive)
                        }
                        .confirmationDialog(
                            "Sign out?",
                            isPresented: $confirmSignOut,
                            titleVisibility: .visible
                        ) {
                            Button("Sign out", role: .destructive) {
                                // RootGate resets the cursor and group card on
                                // any sign-out, this one included. Dismiss so
                                // the sign-in screen isn't trapped under this
                                // sheet.
                                SupabaseAuth.shared.signOut()
                                dismiss()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("You can sign back in from this screen. Nothing saved on this phone is deleted.")
                        }
                    } else {
                        Button {
                            Haptics.tap()
                            showAuth = true
                        } label: {
                            SettingsRow(title: "Sign in", icon: "person.fill")
                                .fontWeight(.semibold)
                        }
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text(auth.signedIn
                        ? "Your shared library syncs with the web app and each other\u{2019}s phones whenever the app is open."
                        : "Sign in to sync your shared library across phones.")
                }
                .listRowBackground(Self.rowBackground)
            }
            .appBackground(AppBackground.sheet)
            .appColorScheme()
            .tint(themes.current.ink)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .task {
                if ProcessInfo.processInfo.environment["CWG_JOIN"] != nil {
                    groupUI.showJoin = true
                }
            }
            .fullScreenCover(isPresented: $showAuth) {
                AuthView()
            }
            .onChange(of: auth.signedIn) { _, on in
                if on { showAuth = false }
            }
            // The group rows' alerts, invite sheet and leave dialog.
            .modifier(GroupPresentations(ui: groupUI))
        }
        .presentationDetents([.large])
        .onDisappear(perform: syncAppIcon)
    }

    /// One row, modern-settings style: a small icon squircle, then the
    /// title. Monochrome — every badge wears the current theme's accent,
    /// with the icon glyph in the theme base for contrast.
    private func row(_ title: String, icon: String) -> some View {
        SettingsRow(title: title, icon: icon)
    }

    /// Trailing value in the theme ink — system `Picker` rows take the
    /// window tint (often a leftover pink) and ignore `.tint`.
    private func menuValue(_ title: String, icon: String, value: String) -> some View {
        LabeledContent {
            HStack(spacing: 5) {
                Text(value)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(themes.current.ink.opacity(0.55))
        } label: {
            row(title, icon: icon)
        }
    }

    /// Writes the store; the window cross-fades in one step. The matching
    /// home-screen icon waits until this sheet closes — iOS confirms every
    /// icon change with an alert, and one landing on top of the menu and
    /// the fade was most of what made switching feel rough.
    private var theme: Binding<AppTheme> {
        Binding(
            get: { themes.current },
            set: { new in
                Haptics.selection()
                themes.select(new)
            }
        )
    }

    /// Flip the home-screen icon to the chosen theme, once, on the way out.
    private func syncAppIcon() {
        #if !APP_EXTENSION
        let wanted = themes.current.iconName
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != wanted
        else { return }
        UIApplication.shared.setAlternateIconName(wanted)
        #endif
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
        section("Missed", items.filter(\.isMissed))

        let url = FileManager.default.temporaryDirectory
            .appending(path: "can-we-go.md")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
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
                .foregroundStyle(AppBackground.ink.opacity(0.72))
        }
        .accessibilityLabel("Settings")
        // Explicit accent: this sheet is presented from inside the nav bar's
        // dimmed-white tint scope, which would otherwise wash its controls.
        .sheet(isPresented: $open) { SettingsView().tint(AppBackground.ink) }
        // CWG_SETTINGS is only set by automated test runs.
        .task {
            if ProcessInfo.processInfo.environment["CWG_SETTINGS"] != nil {
                open = true
            }
        }
    }
}
