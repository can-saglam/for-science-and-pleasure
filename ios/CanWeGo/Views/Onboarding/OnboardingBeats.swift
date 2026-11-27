import SwiftUI

/// The three pages before sign-in show the app at work, with made-up
/// saves: a shared link turning into a card, the list putting what's
/// closing first, then the same list shared, each card marked with who
/// added it. One view across the three, drawn above the pages, so the
/// cards carry over from one page to the next instead of fading out.
/// Real `ItemCard`s, so the look is exactly the library's.
struct BeatDemo: View {
    /// 0: from anywhere, 1: it knows when, 2: better together.
    let beat: Int
    let still: Bool

    @State private var source = 0
    @State private var linkIn = false
    @State private var cardIn = false
    @State private var sorted = false
    @State private var faces = 0
    @State private var arrived = false

    static let cardHeight: CGFloat = 92
    static let gap: CGFloat = 10
    static let logoHeight: CGFloat = 30
    static let logoGap: CGFloat = 26
    static var stageHeight: CGFloat { cardHeight * 3 + gap * 2 }
    /// The demo at full size; a short display scales it down whole.
    static var height: CGFloat { logoHeight + logoGap + stageHeight }

    var body: some View {
        GeometryReader { geo in
            let scale = min(1, geo.size.height / Self.height)
            VStack(alignment: .leading, spacing: Self.logoGap) {
                LogoTitle(height: Self.logoHeight, writes: .onboarding)
                stage
                    .frame(height: Self.stageHeight, alignment: .top)
            }
            .frame(width: geo.size.width / scale, height: Self.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
        }
        .accessibilityHidden(true)
        .task(id: beat) { await run() }
    }

    // MARK: Stage

    private var stage: some View {
        ZStack(alignment: .top) {
            link
                .offset(y: linkTop)
                .opacity(beat == 0 && linkIn ? 1 : 0)
                .offset(y: linkIn ? 0 : 8)
            ForEach(Self.cards) { card in
                let spot = place(card)
                ItemCard(item: card.item, awayHint: false, fillsHeight: true)
                    .frame(height: Self.cardHeight)
                    .overlay(alignment: .topTrailing) {
                        if let who = card.who {
                            face(who)
                                .offset(x: 6, y: -6)
                                .scaleEffect(spot.face ? 1 : 0.3)
                                .opacity(spot.face ? 1 : 0)
                        }
                    }
                    .shadow(color: .black.opacity(AppBackground.theme.isLight ? 0.08 : 0.3), radius: 12, y: 6)
                    .scaleEffect(spot.shown ? 1 : 0.96)
                    .opacity(spot.shown ? 1 : 0)
                    .offset(y: spot.y)
                    .zIndex(spot.z)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// "Shared from Instagram" over the link, the way it arrives.
    private var link: some View {
        let from = Self.sources[source]
        return VStack(alignment: .leading, spacing: 8) {
            Label("Shared from \(from.app)", systemImage: "square.and.arrow.up")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppBackground.secondaryInk)
                .padding(.leading, 4)
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.subheadline.weight(.semibold))
                Text(from.link)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private static let linkHeight: CGFloat = 74
    private static let linkToCard: CGFloat = 16
    private var linkTop: CGFloat {
        (Self.stageHeight - Self.linkHeight - Self.linkToCard - Self.cardHeight) / 2
    }

    private func face(_ who: Person) -> some View {
        Text(who.initial)
            .font(.caption.weight(.bold))
            .foregroundStyle(AvatarColour.initial(who.colour))
            .frame(width: 28, height: 28)
            .background(AvatarColour.color(who.colour), in: .circle)
            .overlay(Circle().strokeBorder(AppBackground.base, lineWidth: 2))
    }

    // MARK: Where each card sits

    private struct Spot {
        var y: CGFloat
        var shown: Bool
        var face = false
        var z: Double = 0
    }

    private func row(_ i: Int) -> CGFloat { CGFloat(i) * (Self.cardHeight + Self.gap) }

    /// The list on the second page, before and after it sorts.
    private var listOrder: [String] {
        if beat == 2 { return arrived ? ["openHouse", "anish", "polica"] : ["anish", "polica", "toor"] }
        return sorted ? ["anish", "polica", "toor"] : ["toor", "polica", "anish"]
    }

    private func place(_ card: Demo) -> Spot {
        if beat == 0 {
            let showing = Self.sources[source].card == card.id
            return Spot(y: linkTop + Self.linkHeight + Self.linkToCard, shown: showing && cardIn)
        }
        if let i = listOrder.firstIndex(of: card.id) {
            let face = beat == 2 && (Self.faceOrder.firstIndex(of: card.id).map { $0 < faces } ?? false)
            // The one rising passes over the others.
            return Spot(y: row(i), shown: true, face: face, z: card.id == "anish" ? 1 : 0)
        }
        // On its way in from above, or pushed out of the bottom.
        if card.id == "openHouse" { return Spot(y: -Self.cardHeight / 2, shown: false) }
        return Spot(y: row(3), shown: false)
    }

    // MARK: Timing

    private func run() async {
        if still {
            source = 0
            linkIn = beat == 0
            cardIn = beat == 0
            sorted = beat >= 1
            faces = beat == 2 ? Self.faceOrder.count : 0
            arrived = beat == 2
            return
        }
        switch beat {
        case 0:
            withAnimation(.smooth(duration: 0.5)) {
                sorted = false
                faces = 0
                arrived = false
                cardIn = false
                linkIn = false
            }
            try? await Task.sleep(for: .seconds(0.5))
            while !Task.isCancelled {
                withAnimation(.smooth(duration: 0.45)) { linkIn = true }
                guard await pause(1.0) else { return }
                withAnimation(.spring(duration: 0.6, bounce: 0.22)) { cardIn = true }
                guard await pause(2.4) else { return }
                withAnimation(.easeIn(duration: 0.3)) {
                    linkIn = false
                    cardIn = false
                }
                guard await pause(0.45) else { return }
                source = (source + 1) % Self.sources.count
            }
        case 1:
            withAnimation(.smooth(duration: 0.6)) {
                linkIn = false
                cardIn = false
                faces = 0
                arrived = false
                sorted = false
            }
            guard await pause(1.2) else { return }
            withAnimation(.spring(duration: 0.9, bounce: 0.12)) { sorted = true }
        default:
            withAnimation(.smooth(duration: 0.6)) {
                linkIn = false
                cardIn = false
                sorted = true
                arrived = false
                faces = 0
            }
            guard await pause(0.6) else { return }
            // The three already there, then the one Joyce adds.
            for n in 1..<Self.faceOrder.count {
                withAnimation(.spring(duration: 0.45, bounce: 0.4)) { faces = n }
                guard await pause(0.3) else { return }
            }
            guard await pause(0.8) else { return }
            withAnimation(.spring(duration: 0.8, bounce: 0.12)) { arrived = true }
            guard await pause(0.5) else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0.4)) { faces = Self.faceOrder.count }
        }
    }

    /// Sleeps, and says whether the page is still up.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    // MARK: Sample saves

    struct Person {
        var initial: String
        var colour: String
    }

    struct Demo: Identifiable {
        var id: String
        var item: Item
        var who: Person?
    }

    private static let joyce = Person(initial: "J", colour: "mint")
    private static let sam = Person(initial: "S", colour: "coral")
    /// Who marks their cards, in the order the faces appear.
    private static let faceOrder = ["anish", "polica", "toor", "openHouse"]

    private static let sources: [(app: String, link: String, card: String)] = [
        ("Instagram", "instagram.com/p/DA7mK2pNx4R", "polica"),
        ("Safari", "southbankcentre.co.uk/whats-on/anish-kapoor", "anish"),
        ("Maps", "maps.apple.com/place?name=Sessions+Arts+Club", "sessions"),
    ]

    /// Dated from today, so the badges read the same whenever it's opened.
    /// Photos come from the bundle, handed to the image cache under
    /// made-up URLs so the cards draw them through the ordinary melt.
    static let cards: [Demo] = {
        let day = { (n: Int) in DayString.addingDays(n, to: DayString.today()) }
        func photo(_ asset: String) -> String? {
            let url = URL(string: "cwg-sample://\(asset.lowercased())")!
            guard let image = UIImage(named: asset) else { return nil }
            ImageStore.seed(image, for: url)
            return url.absoluteString
        }
        func event(_ title: String, venue: String?, area: String, category: String,
                   from: Int, to: Int, colour: String, asset: String) -> Item {
            let item = Item()
            item.kind = Item.Kind.event
            item.title = title
            item.venue = venue
            item.area = area
            item.category = category
            item.startsOn = day(from)
            item.endsOn = day(to)
            item.colorHex = colour
            item.imageUrl = photo(asset)
            return item
        }
        let sessions = Item()
        sessions.kind = Item.Kind.place
        sessions.title = "Sessions Arts Club"
        sessions.area = "Clerkenwell"
        sessions.category = "restaurant"
        sessions.colorHex = "#2C7A6B"
        sessions.imageUrl = photo("SampleSessions")
        return [
            Demo(id: "toor", item: event("Salman Toor", venue: "Courtauld Gallery", area: "Strand", category: "exhibition",
                                         from: -20, to: 23, colour: "#3F6E4A", asset: "SampleToor"), who: joyce),
            Demo(id: "polica", item: event("Poli\u{00E7}a", venue: "EartH", area: "Dalston", category: "gig",
                                           from: 4, to: 4, colour: "#B8892E", asset: "SampleGig"), who: sam),
            Demo(id: "anish", item: event("Anish Kapoor", venue: "Hayward Gallery", area: "Southbank", category: "exhibition",
                                          from: -40, to: 2, colour: "#B44A2C", asset: "SampleAnish"), who: joyce),
            Demo(id: "sessions", item: sessions),
            Demo(id: "openHouse", item: event("Open House Festival", venue: nil, area: "London", category: "festival",
                                              from: 1, to: 1, colour: "#7A4FB4", asset: "SampleOpenHouse"), who: joyce),
        ]
    }()
}
