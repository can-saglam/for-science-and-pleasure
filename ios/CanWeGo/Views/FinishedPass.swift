import SwiftData
import SwiftUI

/// Events that finished without anyone saying whether they went, asked
/// about in one pass. "Went" marks one done on the day it finished, which
/// syncs, so it joins Been for the whole group; "Didn't make it" changes
/// nothing and is remembered on this phone, so it isn't asked again. The
/// pass ends by saying what it did. Offered at most once a week, and never
/// over the plan follow-up.
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
    /// The ones answered "went", in order, for the closing summary.
    @State private var added: [Item] = []
    /// The summary's photos have popped in.
    @State private var landed = false
    /// The sheet fits its cards.
    @State private var height: CGFloat = 480

    /// How far a card has to travel to count as an answer.
    private static let threshold: CGFloat = 110

    /// Every card answered: the summary takes over.
    private var finished: Bool { index >= items.count }

    /// How far the top card is toward an answer: -1 "didn't", 1 "went".
    /// Follows the finger, and a tapped button's card on its way off.
    private var pull: CGFloat {
        max(-1, min(1, drag.width / Self.threshold + leaving))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if finished {
                summary
            } else {
                header
                stack
                    .padding(.top, 20)
                actions
                    .controlSize(.large)
                    .padding(.top, 20)
                // Only until the first answer; its room stays, so the
                // sheet doesn't change height mid-pass.
                Text("Swipe the card, or tap")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .opacity(index == 0 ? 1 : 0)
                    .accessibilityHidden(true)
            }
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
                card(items[i], top: depth == 0)
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

    /// The photo with the day it finished on it, melting down into the
    /// title and where, the way a list card's photo melts in from its edge.
    /// The words sit at the foot of the card and the photo has the rest, so
    /// a short title means more photo, not a gap under it.
    private func card(_ item: Item, top: Bool) -> some View {
        cardRoom
            .overlay {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(maxHeight: .infinity)
                        .overlay {
                            if let url = item.imageUrl.flatMap(URL.init(string:)) {
                                MeltDown(url: url, cardBackground: ItemCard.background(item.accentColor))
                            }
                        }
                        // No photo, or a dead one: the save's colour,
                        // fading the same way.
                        .background(
                            LinearGradient(
                                colors: [item.accentColor.opacity(0.35), item.accentColor.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipped()
                        .accessibilityHidden(true)
                        .overlay(alignment: .topLeading) {
                            if let when = finishedWhen(item) {
                                Text(when)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.black.opacity(0.6), in: .capsule)
                                    .padding(12)
                                    // Makes way for the verdict as the card is pulled.
                                    .opacity(top ? 1 - abs(pull) : 1)
                            }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.displaySmall(24, relativeTo: .title3))
                            .lineLimit(2)
                        if let venue = venue(item) {
                            Text(venue)
                                .font(.subheadline)
                                .foregroundStyle(AppBackground.secondaryInk)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    // Up into the foot of the photo, which is all card by
                    // there.
                    .padding(.top, -24)
                }
            }
        .background(ItemCard.background(item.accentColor))
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(ItemCard.border(item.accentColor), lineWidth: 1)
        )
        .overlay {
            // Pulled toward "went", the card takes the accent's outline.
            if top {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(AppBackground.accent, lineWidth: 3)
                    .opacity(max(0, pull))
            }
        }
        .overlay(alignment: .top) { if top { verdict } }
        .accessibilityElement(children: .combine)
    }

    /// The size of every card: the fullest one, two lines of title and a
    /// venue under its photo. One height keeps the stack even (a taller
    /// card underneath would show over the top of a shorter one) and the
    /// sheet still from card to card.
    private var cardRoom: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 200)
            VStack(alignment: .leading, spacing: 4) {
                Text(" ")
                    .font(.displaySmall(24, relativeTo: .title3))
                    .lineLimit(2, reservesSpace: true)
                Text(" ")
                    .font(.subheadline)
            }
            .padding(16)
            .padding(.top, -24)
        }
        .frame(maxWidth: .infinity)
        .hidden()
        .accessibilityHidden(true)
    }

    /// "Went" or "Didn't" fading in as the card is pulled toward it, or
    /// sent there by its button.
    @ViewBuilder
    private var verdict: some View {
        if abs(pull) > 0.05 {
            Text(pull > 0 ? Voice.went : "Didn\u{2019}t make it")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(pull > 0 ? AppBackground.onProminent : AppBackground.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(pull > 0 ? Color.white : AppBackground.sheet, in: .capsule)
                .padding(.top, 14)
                .opacity(abs(pull))
        }
    }

    private func venue(_ item: Item) -> String? {
        guard let venue = item.venue?.trimmingCharacters(in: .whitespaces), !venue.isEmpty else { return nil }
        return venue
    }

    /// "Finished Sunday", "Finished 21 Sep", "Was on 14 Nov".
    private func finishedWhen(_ item: Item) -> String? {
        guard let end = item.endsOn else { return nil }
        let oneDay = item.startsOn == nil || item.startsOn == end
        let days = -(DayString.daysFromToday(end) ?? -30)
        let when = days < 7
            ? DayString.text(end, .dateTime.weekday(.wide)) ?? end
            : DayString.text(end) ?? end
        return oneDay ? "Was on \(when)" : "Finished \(when)"
    }

    // MARK: - Answers

    /// In the order of the swipe: "didn't" on the left, "went" on the right.
    /// Each swells a little as the card is pulled its way.
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
            .scaleEffect(1 + 0.06 * max(0, -pull))

            Button {
                answer(went: true)
            } label: {
                Label(Voice.went, systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppBackground.onProminent)
                    .frame(maxWidth: .infinity)
            }
            .prominentGlass()
            .scaleEffect(1 + 0.06 * max(0, pull))
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
            added.append(item)
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
    }

    // MARK: - Summary

    /// What the pass did, before the sheet goes: the ones now marked as
    /// gone to, and what becomes of the rest.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !added.isEmpty {
                HStack(spacing: -16) {
                    ForEach(Array(added.prefix(5).enumerated()), id: \.element.id) { place, item in
                        thumb(item)
                            .rotationEffect(.degrees(place.isMultiple(of: 2) ? -6 : 5))
                            .scaleEffect(landed ? 1 : 0.4)
                            .opacity(landed ? 1 : 0)
                            .animation(
                                reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.35).delay(0.12 + Double(place) * 0.09),
                                value: landed
                            )
                            .zIndex(Double(place))
                    }
                }
                .padding(.leading, 4)
                .padding(.bottom, 16)
                .accessibilityHidden(true)
            }
            Text(outcome)
                .font(.displaySmallBold(28, relativeTo: .title2))
                .accessibilityAddTraits(.isHeader)
            whereTheyAre
                .font(.subheadline)
                .foregroundStyle(AppBackground.secondaryInk)
                .padding(.top, 6)
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppBackground.onProminent)
                    .frame(maxWidth: .infinity)
            }
            .prominentGlass()
            .controlSize(.large)
            .padding(.top, 22)
        }
        .onAppear { landed = true }
    }

    /// What the pass came to, said the way you'd say it afterwards:
    /// "Three to remember", not a count of rows moved.
    private var outcome: String {
        guard !added.isEmpty else { return "Can\u{2019}t make them all" }
        return "\(Self.spelled(added.count)) to remember"
    }

    /// "One", "Three", "Twenty-three". English, as the rest of the copy is,
    /// whatever the phone's language.
    private static func spelled(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_GB")
        let word = formatter.string(from: count as NSNumber) ?? "\(count)"
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// Where to find each lot, by the names the lists use. The names are
    /// set apart in the ink's weight: "under We did go" in one voice reads
    /// as a sentence that lost its way.
    private var whereTheyAre: Text {
        let missed = items.count - added.count
        let missedList = listName("Missed")
        if added.isEmpty {
            return missed == 1
                ? Text("It stays under \(missedList). No more questions.")
                : Text("They stay under \(missedList). No more questions.")
        }
        let wentList = listName(Voice.didGoSection)
        let find = added.count == 1
            ? Text("Find it under \(wentList).")
            : Text("Find them under \(wentList).")
        switch missed {
        case 0: return items.count == 1 ? find : Text("Not one missed. \(find)")
        case 1: return Text("\(find) The other one stays under \(missedList).")
        default: return Text("\(find) The rest stay under \(missedList).")
        }
    }

    private func listName(_ name: String) -> Text {
        Text(name)
            .fontWeight(.semibold)
            .foregroundStyle(AppBackground.ink)
    }

    private func thumb(_ item: Item) -> some View {
        Color.clear
            .frame(width: 70, height: 70)
            .overlay {
                if let url = item.imageUrl.flatMap(URL.init(string:)) {
                    CachedImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        }
                    }
                }
            }
            // Under the photo, so one that has none, or won't load, is a
            // ticked tile and not a blank one.
            .background {
                Image(systemName: "checkmark")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppBackground.ink.opacity(0.4))
            }
            .background(item.accentColor.mix(with: AppBackground.sheet, by: 0.5))
            .clipShape(.rect(cornerRadius: 17, style: .continuous))
            // A rim of the sheet, so overlapping photos read as separate.
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(AppBackground.sheet, lineWidth: 3)
            )
    }
}

/// A card's photo across its top, sharp until its last stretch, where it
/// dissolves into the card below: the list card's melt, turned downward.
private struct MeltDown: View {
    let url: URL
    let cardBackground: Color

    @State private var sharp: UIImage?
    @State private var blurred: UIImage?

    init(url: URL, cardBackground: Color) {
        self.url = url
        self.cardBackground = cardBackground
        // Memory only, as the list's cards do: what's there draws in the
        // sheet's first frame.
        if let hit = ImageStore.cached(url, variant: .hero) ?? ImageStore.cached(url) {
            _sharp = State(initialValue: hit)
            _blurred = State(initialValue: ImageStore.cachedMelt(url) ?? hit)
        }
    }

    var body: some View {
        ZStack {
            if let sharp, let blurred {
                // The melt is a fixed stretch at the foot, however tall the
                // photo has been left to be.
                GeometryReader { box in
                    MeltLayers(
                        sharp: sharp, blurred: blurred, cardBackground: cardBackground,
                        width: nil, downOver: min(1, 100 / max(box.size.height, 1))
                    )
                }
            }
        }
        // Flat, so the multiply inside tints the photo and nothing under it.
        .compositingGroup()
        .task(id: url) {
            // The card-size photo and its blur are usually in hand from the
            // list; the full-size one takes their place when it lands.
            async let full = ImageStore.fetch(url, variant: .hero)
            guard let pair = await ImageStore.meltPair(url) else { return }
            show(sharp ?? pair.sharp, over: pair.blurred)
            if let full = await full { show(full, over: pair.blurred) }
        }
    }

    /// Never animated: a late photo appears, it doesn't fade or grow in.
    private func show(_ photo: UIImage, over blur: UIImage) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            sharp = photo
            blurred = blur
        }
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
