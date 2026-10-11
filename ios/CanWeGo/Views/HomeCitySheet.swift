import MapKit
import SwiftUI

/// The city field's lookup button, lit like the composer's send once
/// there's a name to look up: a bare glyph didn't read as the next step.
struct CitySearchButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text("Search")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .foregroundStyle(enabled ? AppBackground.onProminent : AppBackground.ink.opacity(0.45))
                .background(Capsule().fill(enabled ? Color.white.opacity(0.92) : AppBackground.wash(0.16)))
                .overlay(
                    Capsule().strokeBorder(
                        AppBackground.ink.opacity(enabled && AppBackground.theme.isLight ? 0.22 : 0),
                        lineWidth: 1)
                )
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // Taller than the text beside it; the field keeps its height.
        .padding(.vertical, -5)
        .animation(.snappy, value: enabled)
    }
}

/// Set or change the group's home city from Settings. Same lookup as
/// onboarding, so skipping the city there isn't a dead end.
struct HomeCitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var home = HomeStore.shared
    @State private var query = ""
    @State private var matches: [HomeStore.Home] = []
    @State private var looking = false
    @State private var saving = false
    @State private var note: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("The city you go out in. It sets the clock on your cards and where the map opens.")
                        .font(.subheadline)
                        .foregroundStyle(AppBackground.ink.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)

                    if home.isSet {
                        Label {
                            Text("Now: \(Text("\(home.home.locality), \(home.home.country)").fontWeight(.semibold))")
                        } icon: {
                            Image(systemName: "house.fill")
                        }
                        .font(.subheadline)
                        .accessibilityLabel("Home is \(home.home.locality), \(home.home.country)")
                    }

                    HStack(spacing: 10) {
                        TextField("", text: $query, prompt: AppBackground.fieldPrompt("City"))
                            .font(.title3)
                            .foregroundStyle(AppBackground.ink)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .focused($focused)
                            .onSubmit { Task { await lookup() } }
                        if looking || saving {
                            ProgressView().controlSize(.small)
                        } else {
                            CitySearchButton(enabled: !query.trimmingCharacters(in: .whitespaces).isEmpty) {
                                Task { await lookup() }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))

                    Text(note ?? " ")
                        .font(.footnote)
                        .foregroundStyle(note == nil ? Color.clear : AppBackground.warning)
                        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                        .accessibilityHidden(note == nil)

                    if !matches.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(matches, id: \.self) { home in
                                Button {
                                    Haptics.tap()
                                    Task { await save(home) }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(home.locality).font(.body.weight(.medium))
                                            Text(home.country)
                                                .font(.caption)
                                                .foregroundStyle(AppBackground.ink.opacity(0.62))
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                                .disabled(saving)
                                if home != matches.last {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .appBackground(AppBackground.sheet)
            .sheetTitle("Home city") {
                dismiss()
            }
        }
        .foregroundStyle(AppBackground.ink)
        .appColorScheme()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
    }

    private func lookup() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !looking else { return }
        looking = true
        defer { looking = false }
        note = nil
        matches = []
        do {
            guard let request = MKGeocodingRequest(addressString: trimmed) else {
                note = "Couldn't look that up."
                return
            }
            request.preferredLocale = HomeStore.namesLocale
            present(try await request.mapItems)
            if matches.isEmpty {
                note = "No city matched “\(trimmed)”. Try the city name on its own."
            }
        } catch {
            note = "Couldn't look that up. Check the connection and try again."
        }
    }

    private func present(_ items: [MKMapItem]) {
        var seen = Set<String>()
        var homes: [HomeStore.Home] = []
        for item in items {
            guard let found = HomeStore.from(item.placemark) else { continue }
            // A ward (Nakano) is listed as its city (Tokyo).
            let home = HomeStore.widerCity(for: found) ?? found
            let key = "\(home.locality)|\(home.country)"
            if seen.insert(key).inserted { homes.append(home) }
        }
        matches = Array(homes.prefix(5))
    }

    private func save(_ home: HomeStore.Home) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        if let error = await HomeStore.shared.save(home) {
            note = error
            return
        }
        Haptics.success()
        dismiss()
    }
}
