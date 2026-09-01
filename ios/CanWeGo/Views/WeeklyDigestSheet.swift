import SwiftData
import SwiftUI

/// The weekend digest, opened from the push notification (or previewed from
/// Settings): what closes over the weekend, what's happening (one-offs and
/// openings woven together), and everything still on — with thumbnails,
/// not a plain list. Tapping anything opens the full item.
struct WeeklyDigestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @State private var selected: Item?

    // Same date rules as the backend's digest builder: the coming Fri–Sun,
    // or the rest of the current weekend once it's under way.

    private var weekend: (start: String, end: String) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let dow = calendar.component(.weekday, from: today) // 1 = Sunday
        let sunday = calendar.date(byAdding: .day, value: (8 - dow) % 7, to: today)!
        let friday = calendar.date(byAdding: .day, value: -2, to: sunday)!
        let start = max(today, friday)
        return (DayString.formatter.string(from: start), DayString.formatter.string(from: sunday))
    }

    private func inWeekend(_ day: String?) -> Bool {
        guard let day else { return false }
        return day >= weekend.start && day <= weekend.end
    }

    private var events: [Item] {
        items.filter { $0.isEvent && !$0.isDone }
    }

    // Ties broken by id so equal dates never swap rows between redraws.
    private func byDay(_ key: KeyPath<Item, String?>) -> (Item, Item) -> Bool {
        { a, b in
            let x = a[keyPath: key] ?? ""
            let y = b[keyPath: key] ?? ""
            return x != y ? x < y : a.id.uuidString < b.id.uuidString
        }
    }

    /// Already-running events whose window shuts over the weekend — last
    /// chance. Pop-ups that only open during the weekend belong under
    /// "Happening", not here, even if they also close by Sunday.
    private var closing: [Item] {
        events
            .filter { item in
                guard !item.isOneDay, inWeekend(item.endsOn) else { return false }
                return item.startsOn.map { $0 < weekend.start } ?? true
            }
            .sorted(by: byDay(\.endsOn))
    }

    /// One-offs and openings woven together, chronological — same merged
    /// section as the events page, so both tell the same story.
    private var happening: [Item] {
        let closingIds = Set(closing.map(\.id))
        return events
            .filter {
                guard inWeekend($0.startsOn) else { return false }
                return $0.isOneDay || !closingIds.contains($0.id)
            }
            .sorted(by: byDay(\.startsOn))
    }

    /// Everything else that's simply available — every running or undated
    /// event not already in a weekend section, closing soonest first.
    private var stillOn: [Item] {
        let shown = Set((happening + closing).map(\.id))
        return events
            .filter {
                !shown.contains($0.id)
                    && ($0.timeBucket == .now || $0.timeBucket == .lastChance
                        || $0.timeBucket == .undated)
            }
            .sorted { a, b in
                switch (a.daysUntilClose, b.daysUntilClose) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return a.createdAt != b.createdAt
                        ? a.createdAt < b.createdAt
                        : a.id.uuidString < b.id.uuidString
                }
            }
    }

    private var quietWeekend: Bool {
        closing.isEmpty && happening.isEmpty
    }

    private var weekendSpan: String {
        guard let start = DayString.date(weekend.start),
              let end = DayString.date(weekend.end)
        else { return "" }
        let f = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        if start == end { return start.formatted(f) }
        return "\(start.formatted(f)) – \(end.formatted(f))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This weekend")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text(weekendSpan)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    if quietWeekend {
                        Text("A quiet weekend on paper, but these are on.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    section("Last chance", tint: .red, closing)
                    section("Happening", tint: AppBackground.accent, happening)
                    section("Still on", tint: .secondary, stillOn)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .appBackground(AppBackground.sheet)
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
        }
        .sheet(item: $selected) { ItemDetailView(item: $0) }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section(_ title: String, tint: Color, _ list: [Item]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(tint)
                ForEach(list) { item in
                    Button {
                        Haptics.tap()
                        selected = item
                    } label: {
                        ItemCard(item: item, meta: meta(for: item, in: title))
                    }
                    .buttonStyle(PressableCardStyle())
                }
            }
        }
    }

    private func meta(for item: Item, in section: String) -> String {
        var parts: [String] = []
        switch section {
        case "Last chance":
            if let day = friendly(item.endsOn) { parts.append("Closes \(day)") }
        case "Happening":
            if let day = friendly(item.startsOn) {
                parts.append(item.isOneDay ? day : "Opens \(day)")
            }
        default:
            parts.append(item.timeLabel ?? "On now")
        }
        if let venue = item.venue ?? item.area { parts.append(venue) }
        return parts.joined(separator: " · ")
    }

    private func friendly(_ day: String?) -> String? {
        guard let day, let date = DayString.date(day) else { return nil }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// Digest entries render as the standard ItemCard (photo melting in from
// the right), with the digest's own meta line in place of the countdown.
