import CoreLocation
import SwiftUI

/// The signature look carried over from the web app: every save wears a
/// gentle wash of its dominant color. Content stays plain; the tint does
/// the talking.
struct ItemCard: View {
    let item: Item
    /// Journal-density variant for We Did Go.
    var compact = false

    private var subtitle: String {
        ([cleanVenue, cleanArea, distance].compactMap(\.self))
            .joined(separator: " · ")
    }

    /// Lowercased alphanumerics only — for fuzzy redundancy checks like
    /// "Satos Kitchen Brixton" vs "Sato's Kitchen" + "Brixton".
    private func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Parsed data occasionally lands a URL in venue/area — never show it.
    private func looksLikeURL(_ s: String) -> Bool {
        s.contains("://") || s.hasPrefix("www.")
            || (s.contains("/") && s.contains(".") && !s.contains(" "))
    }

    private var cleanVenue: String? {
        guard let venue = item.venue?.trimmingCharacters(in: .whitespaces),
              !venue.isEmpty, !looksLikeURL(venue)
        else { return nil }
        let v = normalized(venue)
        // Venue that just restates the title (with or without the area
        // tacked on) adds nothing.
        if v == normalized(item.title) { return nil }
        if let area = item.area, v == normalized(item.title) + normalized(area) { return nil }
        return venue
    }

    private var cleanArea: String? {
        guard let area = item.area?.trimmingCharacters(in: .whitespaces),
              !area.isEmpty, !looksLikeURL(area),
              normalized(area) != normalized(item.title)
        else { return nil }
        // "Bara Café · Peckham" is good; "Satos Kitchen Brixton · Brixton"
        // is not — skip the area when the venue already names it.
        if let venue = cleanVenue, normalized(venue).contains(normalized(area)) { return nil }
        return area
    }

    /// "1.2 km" for places, when we know where the user is. Quietly absent
    /// otherwise (no permission, no fix, or absurd distances while abroad).
    private var distance: String? {
        guard item.isPlace, !item.isDone, let coord = item.coordinate,
              let here = LocationStore.shared.location
        else { return nil }
        let meters = here.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        guard meters < 100_000 else { return nil }
        if meters < 950 { return "\(Int((meters / 50).rounded() * 50)) m" }
        return String(format: "%.1f km", meters / 1000)
    }

    /// Quiet nudges for incomplete saves — only on active items.
    private var hints: [String] {
        guard !item.isDone, !compact else { return [] }
        var h: [String] = []
        if item.isEvent && item.startsOn == nil && item.endsOn == nil {
            h.append("needs a date")
        }
        if item.lat == nil || item.lng == nil {
            h.append("no location")
        }
        return h
    }

    private var radius: CGFloat { compact ? 14 : 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.title)
                    .font(compact ? .subheadline.weight(.medium) : .body.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 6)
                if let label = item.timeLabel {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.timeLabelIsUrgent ? .red : Color.secondary)
                        .lineLimit(1)
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !hints.isEmpty {
                Text(hints.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, compact ? 14 : 16)
        .padding(.vertical, compact ? 10 : 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: .rect(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
        .contentShape(.rect(cornerRadius: radius, style: .continuous))
    }

    // Cards live on the theme base: fold the accent into it and lift it
    // slightly, so every card reads as a tinted panel of the same material
    // rather than a foreign swatch. Mix amounts are tuned per theme.
    private var cardBackground: Color {
        AppBackground.base
            .mix(with: item.accentColor, by: AppBackground.theme.cardAccentMix)
            .mix(with: .white, by: AppBackground.theme.cardWhiteLift)
    }

    private var cardBorder: Color {
        item.accentColor.mix(with: .white, by: 0.4).opacity(0.30)
    }
}

/// Things-style tactility: cards settle slightly under the finger,
/// with a soft haptic tick on touch-down.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.28), value: configuration.isPressed)
    }
}

/// When the surrounding list was born — rows only cascade during its first
/// moments, so cells recycled while scrolling back up don't replay the fade.
private struct CascadeStartKey: EnvironmentKey {
    static let defaultValue = Date.distantPast
}

extension EnvironmentValues {
    var cascadeStart: Date {
        get { self[CascadeStartKey.self] }
        set { self[CascadeStartKey.self] = newValue }
    }
}

private struct CascadeRoot: ViewModifier {
    @State private var born = Date()

    func body(content: Content) -> some View {
        content.environment(\.cascadeStart, born)
    }
}

/// Staggered fade-up as cards arrive — capped so deep scrolling stays snappy.
private struct CascadeIn: ViewModifier {
    let index: Int
    @Environment(\.cascadeStart) private var start
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                // Past the list's opening beat, just appear in place.
                guard Date().timeIntervalSince(start) < 1.2 else {
                    shown = true
                    return
                }
                withAnimation(.spring(duration: 0.45).delay(Double(min(index, 10)) * 0.05)) {
                    shown = true
                }
            }
    }
}

extension View {
    func cascadeIn(_ index: Int) -> some View {
        modifier(CascadeIn(index: index))
    }

    /// Mark the list whose first render drives the cascade timing.
    func cascadeRoot() -> some View {
        modifier(CascadeRoot())
    }

    /// Card rows inside a plain List: invisible chrome, our own spacing.
    func cardListRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(.init(top: 5, leading: 20, bottom: 5, trailing: 20))
    }
}

/// A card in a list: tap to open, swipe right to mark done, swipe left to
/// delete, long-press for quick actions.
struct ItemCardRow: View {
    let item: Item
    let index: Int
    var compact = false
    let onOpen: () -> Void

    @Environment(\.modelContext) private var context
    @State private var celebrate = 0

    var body: some View {
        // Haptic fires with the action, not the press state — quick taps in
        // a scrolling list often never register as "pressed".
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            ItemCard(item: item, compact: compact)
        }
        .buttonStyle(PressableCardStyle())
        .cascadeIn(index)
        .cardListRow()
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if item.isDone {
                Button {
                    Haptics.tap()
                    item.putBack()
                } label: {
                    Label("Put back", systemImage: "arrow.uturn.backward")
                }
                .tint(.indigo)
            } else {
                Button {
                    celebrate += 1
                    item.markDone()
                } label: {
                    Label("We did go!", systemImage: "checkmark")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            if item.isDone {
                Button {
                    Haptics.tap()
                    item.putBack()
                } label: {
                    Label("Put back in the library", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button {
                    celebrate += 1
                    item.markDone()
                } label: {
                    Label("We did go!", systemImage: "checkmark")
                }
            }
            if let maps = item.googleMapsURL {
                Link(destination: maps) {
                    Label("Open in Google Maps", systemImage: "map")
                }
            }
            if let url = item.url.flatMap(URL.init(string:)) {
                Link(destination: url) {
                    Label("Open source", systemImage: "arrow.up.right")
                }
            }
            Divider()
            Button(role: .destructive) {
                delete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .sensoryFeedback(.success, trigger: celebrate)
    }

    /// Deletion always leaves a five-second Undo behind (toast in ContentView).
    private func delete() {
        Haptics.tap()
        UndoBin.shared.stash(item.snapshot)
        SupabaseSync.setDeleted(item.id, true)
        context.delete(item)
        try? context.save()
    }
}

/// Muted section headers shared by the card lists.
struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let count {
                Text("\(count)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
