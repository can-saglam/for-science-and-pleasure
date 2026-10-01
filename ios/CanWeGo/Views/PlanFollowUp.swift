import SwiftData
import SwiftUI

/// The plans whose day has gone by, asked about one after another.
struct PlanFollowUp: Identifiable {
    let id = UUID()
    var items: [Item]
}

/// The morning after a plan: did you make it? Any answer clears the plan,
/// and that syncs, so the group is asked once. "We went" ("I went" alone) marks an event
/// done (a place stays on the list, it just loses the plan); "Not this
/// time" offers another day while one is left. Swiping it away counts as
/// not this time.
struct PlanFollowUpSheet: View {
    let items: [Item]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var index = 0
    @State private var askingAgain = false
    @State private var replanning: Item?
    /// The picker saved a new day; move on once it has closed.
    @State private var replanned = false
    /// Answered, so leaving doesn't answer them again.
    @State private var answered: Set<UUID> = []
    /// The sheet fits its question.
    @State private var height: CGFloat = 320

    private var current: Item? {
        index < items.count ? items[index] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item = current {
                if askingAgain {
                    anotherDay(item)
                } else {
                    question(item)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ThemeFill(color: AppBackground.sheet) }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppBackground.sheet)
        .sheet(item: $replanning, onDismiss: {
            if replanned {
                replanned = false
                next()
            }
        }) { item in
            PlanSheet(item: item) { replanned = true }
        }
        .onDisappear {
            // Closed because the library is being replaced: not an answer.
            guard !GroupStore.shared.libraryIsForeign else { return }
            if let item = current, !answered.contains(item.id) { clear(item) }
        }
    }

    // MARK: - Steps

    private func question(_ item: Item) -> some View {
        step(item, title: "Did you make it to \(item.title)?", detail: whenLine(item)) {
            HStack(spacing: 10) {
                Button {
                    wentThere(item)
                } label: {
                    Label(Voice.went, systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppBackground.onProminent)
                        .frame(maxWidth: .infinity)
                }
                .prominentGlass()

                Button {
                    notThisTime(item)
                } label: {
                    Text("Not this time")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppBackground.ink)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func anotherDay(_ item: Item) -> some View {
        step(item, title: "Another day?", detail: stillOn(item)) {
            VStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    replanning = item
                } label: {
                    Label("Pick another day", systemImage: "calendar.badge.clock")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppBackground.onProminent)
                        .frame(maxWidth: .infinity)
                }
                .prominentGlass()

                Button {
                    Haptics.tap()
                    next()
                } label: {
                    Text("Keep it in the list")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppBackground.ink)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
    }

    /// Laid out like the details: the photo with the heading on its foot
    /// (or the item's color washing in when there's none), then the answers.
    private func step(
        _ item: Item, title: String, detail: String?,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        let heading = VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.displaySmallBold(28, relativeTo: .title2))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)

        return VStack(alignment: .leading, spacing: 0) {
            if let url = item.imageUrl.flatMap(URL.init(string:)) {
                HeroPhoto(url: url, placeholder: item.accentColor)
                    .accessibilityHidden(true)
                    .overlay(alignment: .bottomLeading) {
                        heading
                            .padding(.horizontal, 20)
                            .padding(.bottom, 6)
                    }
            } else {
                heading
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 40)
                    .background(alignment: .top) {
                        LinearGradient(
                            colors: [item.accentColor.opacity(0.22), item.accentColor.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 260)
                    }
            }
            actions()
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
        }
        .transition(.opacity)
    }

    /// "Yesterday at 17:00 · Hayward Gallery", "Saturday · Hayward Gallery".
    private func whenLine(_ item: Item) -> String? {
        guard let day = item.planOn else { return nil }
        var when = (DayString.daysFromToday(day) ?? 0) == -1
            ? "Yesterday"
            : DayString.text(day, .dateTime.weekday(.wide)) ?? day
        if let time = item.planTime { when += " at \(OpeningHours.time(time))" }
        let place = item.isPlace ? nil : item.venue
        return [when, place].compactMap(\.self).joined(separator: " · ")
    }

    /// "It's on until 30 Oct." for an event that's still running.
    private func stillOn(_ item: Item) -> String? {
        guard item.isEvent, let ends = item.endsOn, let text = DayString.text(ends) else { return nil }
        return "It\u{2019}s on until \(text)."
    }

    // MARK: - Answers

    private func wentThere(_ item: Item) {
        Haptics.success()
        answered.insert(item.id)
        item.clearPlan()
        if item.isEvent {
            item.markDone()
            UndoBin.shared.stashDone(item)
        } else {
            item.updatedAt = .now
            try? context.save()
        }
        next()
    }

    private func notThisTime(_ item: Item) {
        Haptics.tap()
        answered.insert(item.id)
        clear(item)
        if item.canPlan {
            withAnimation(.snappy) { askingAgain = true }
        } else {
            next()
        }
    }

    private func clear(_ item: Item) {
        guard item.modelContext != nil, item.planIsOver else { return }
        item.clearPlan()
        item.updatedAt = .now
        try? context.save()
    }

    private func next() {
        let following = items.indices.dropFirst(index + 1).first { items[$0].planIsOver }
        guard let following else {
            index = items.count
            dismiss()
            return
        }
        withAnimation(.snappy) {
            askingAgain = false
            index = following
        }
    }
}
