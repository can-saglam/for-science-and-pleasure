import SwiftData
import SwiftUI

/// Events that finished without anyone saying whether they went, asked
/// about in one pass. "Went" marks one done on the day it finished, which
/// syncs, so it joins Been for the whole group; "Didn't make it" changes
/// nothing and is remembered on this phone, so it isn't asked again. Offered
/// at most once a week, and never over the plan follow-up.
struct FinishedPass: Identifiable {
    let id = UUID()
    var items: [Item]

    private static var defaults: UserDefaults { UserDefaults(suiteName: SharedInbox.groupID) ?? .standard }
    private static let skippedKey = "finishedPass.skipped"
    private static let offeredKey = "finishedPass.offeredAt"

    /// Newest finish first: the ones still fresh in mind lead.
    static func candidates(_ items: [Item]) -> [Item] {
        let skipped = Set(defaults.stringArray(forKey: skippedKey) ?? [])
        return items
            .filter { $0.isEvent && $0.isMissed && !$0.isTrashed && $0.endsOn != nil && !skipped.contains($0.id.uuidString) }
            .sorted { ($0.endsOn ?? "") > ($1.endsOn ?? "") }
    }

    static var due: Bool {
        guard let last = defaults.object(forKey: offeredKey) as? Date else { return true }
        return Date.now.timeIntervalSince(last) >= 7 * 24 * 3600
    }

    static func offered() {
        defaults.set(Date.now, forKey: offeredKey)
    }

    static func skip(_ item: Item) {
        var skipped = defaults.stringArray(forKey: skippedKey) ?? []
        skipped.append(item.id.uuidString)
        defaults.set(skipped, forKey: skippedKey)
    }
}

struct FinishedPassSheet: View {
    let items: [Item]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var drag: CGSize = .zero
    /// The answered card on its way off: -1 left, 1 right.
    @State private var leaving: CGFloat = 0
    /// The sheet fits its cards.
    @State private var height: CGFloat = 480

    /// How far a card has to travel to count as an answer.
    private static let threshold: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            stack
                .padding(.top, 20)
            actions
                .controlSize(.large)
                .padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .padding(.bottom, 16)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ThemeFill(color: AppBackground.sheet) }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppBackground.sheet)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Did you go?")
                .font(.displaySmallBold(30, relativeTo: .title2))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if items.count > 1 {
                Text("\(min(index + 1, items.count)) of \(items.count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppBackground.secondaryInk)
            }
        }
    }

    // MARK: - Cards

    private var stack: some View {
        ZStack {
            // The next two peek out underneath, drawn back to front.
            ForEach(Array(items.indices.dropFirst(index).prefix(3).reversed()), id: \.self) { i in
                let depth = CGFloat(i - index)
                card(items[i])
                    .scaleEffect(1 - depth * 0.05, anchor: .bottom)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(AppBackground.sheet.opacity(depth * 0.3))
                    }
                    .offset(y: depth * 10)
                    .modifier(TopCard(active: depth == 0, drag: drag, leaving: leaving))
                    .gesture(swipe, isEnabled: depth == 0)
                    .zIndex(-depth)
                    .accessibilityHidden(depth > 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, min(CGFloat(items.count - index - 1), 2) * 10)
    }

    private var swipe: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let x = value.predictedEndTranslation.width
                if x > Self.threshold {
                    answer(went: true)
                } else if x < -Self.threshold {
                    answer(went: false)
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { drag = .zero }
                }
            }
    }

    private func card(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 150)
                .overlay {
                    if let url = item.imageUrl.flatMap(URL.init(string:)) {
                        CachedImage(url: url, variant: .hero) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            }
                        }
                    }
                }
                .background(item.accentColor.opacity(0.35))
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.displaySmall(24, relativeTo: .title3))
                    .lineLimit(2)
                if let line = finishedLine(item) {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(AppBackground.secondaryInk)
                        .lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ItemCard.background(item.accentColor))
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(ItemCard.border(item.accentColor), lineWidth: 1)
        )
        .overlay(alignment: .top) { verdict }
        .accessibilityElement(children: .combine)
    }

    /// "Went" or "Didn't" fading in as the card is pulled toward it.
    @ViewBuilder
    private var verdict: some View {
        let pull = min(abs(drag.width) / Self.threshold, 1)
        if pull > 0.05 {
            Text(drag.width > 0 ? Voice.went : "Didn\u{2019}t make it")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(drag.width > 0 ? AppBackground.onProminent : AppBackground.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(drag.width > 0 ? Color.white : AppBackground.sheet, in: .capsule)
                .padding(.top, 14)
                .opacity(pull)
        }
    }

    /// "Finished Sunday", "Finished 21 Sep", "Was on 14 Nov".
    private func finishedLine(_ item: Item) -> String? {
        guard let end = item.endsOn else { return nil }
        let oneDay = item.startsOn == nil || item.startsOn == end
        let days = -(DayString.daysFromToday(end) ?? -30)
        let when = days < 7
            ? DayString.text(end, .dateTime.weekday(.wide)) ?? end
            : DayString.text(end) ?? end
        let lead = oneDay ? "Was on \(when)" : "Finished \(when)"
        return [lead, item.venue].compactMap(\.self).joined(separator: " \u{00B7} ")
    }

    // MARK: - Answers

    /// In the order of the swipe: "didn't" on the left, "went" on the right.
    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                answer(went: false)
            } label: {
                Text("Didn\u{2019}t make it")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppBackground.ink)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)

            Button {
                answer(went: true)
            } label: {
                Label(Voice.went, systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppBackground.onProminent)
                    .frame(maxWidth: .infinity)
            }
            .prominentGlass()
        }
        .disabled(leaving != 0 || index >= items.count)
    }

    private func answer(went: Bool) {
        guard index < items.count, leaving == 0 else { return }
        let item = items[index]
        if went {
            Haptics.success()
            item.markDone()
            UndoBin.shared.stashDone(item)
        } else {
            Haptics.tap()
            FinishedPass.skip(item)
        }
        guard !reduceMotion else { return advance() }
        withAnimation(.easeIn(duration: 0.22)) { leaving = went ? 1 : -1 }
        Task {
            try? await Task.sleep(for: .seconds(0.22))
            advance()
        }
    }

    private func advance() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            leaving = 0
            drag = .zero
            index += 1
        }
        if index >= items.count { dismiss() }
    }
}

/// The top card follows the finger, tilting the way it's pulled, and flies
/// off once answered.
private struct TopCard: ViewModifier {
    let active: Bool
    let drag: CGSize
    let leaving: CGFloat

    func body(content: Content) -> some View {
        if active {
            content
                .offset(x: drag.width + leaving * 520, y: drag.height * 0.15)
                .rotationEffect(.degrees(Double(drag.width) / 22 + Double(leaving) * 10), anchor: .bottom)
        } else {
            content
        }
    }
}
