import StoreKit
import SwiftData
import SwiftUI

/// Why the paywall is up. Money is only ever mentioned at three moments —
/// a fifth save of a kind, an eleventh save in a day, a third person — or
/// when someone asks.
enum PlusReason: Hashable, Identifiable {
    case browsing
    case seats
    /// The category (as stored) that's full.
    case category(String)
    /// Today's ten new saves are in.
    case daily

    var id: String {
        switch self {
        case .browsing: "browsing"
        case .seats: "seats"
        case .category(let c): "category-\(c)"
        case .daily: "daily"
        }
    }
}

/// One plan as the paywall shows it. Every figure comes from StoreKit
/// (`displayPrice`, `priceFormatStyle`); screenshot runs use samples.
private struct Plan: Identifiable {
    let id: String
    let name: String
    let price: String
    let unit: String
    let perMonth: String?
    let amount: Decimal
    let product: Product?

    var isYearly: Bool { unit == "year" }

    init(_ product: Product) {
        let yearly = product.subscription?.subscriptionPeriod.unit == .year
        id = product.id
        name = yearly ? "Yearly" : "Monthly"
        price = product.displayPrice
        unit = yearly ? "year" : "month"
        perMonth = yearly ? "\((product.price / 12).formatted(product.priceFormatStyle)) a month" : nil
        amount = product.price
        self.product = product
    }

    private init(id: String, name: String, price: String, unit: String, perMonth: String?, amount: Decimal) {
        self.id = id
        self.name = name
        self.price = price
        self.unit = unit
        self.perMonth = perMonth
        self.amount = amount
        product = nil
    }

    static let samples = [
        Plan(id: PlusStore.productIDs[0], name: "Yearly", price: "£21.99", unit: "year", perMonth: "£1.83 a month", amount: 21.99),
        Plan(id: PlusStore.productIDs[1], name: "Monthly", price: "£2.99", unit: "month", perMonth: nil, amount: 2.99),
    ]
}

/// The one paywall: Settings, the My group card, a full category, a full
/// day and a full group all open it. It leads with the library itself —
/// the save they were adding on top of the ones that filled the list or
/// the day, the seats still empty — then the plans. In a group that's
/// already Plus it shows who's covering it instead.
struct PlusPaywall: View {
    var reason: PlusReason = .browsing
    /// The save that met the limit, on top of the stack. Not in the store.
    var incoming: Item?
    /// Runs once the server says the group is Plus — the capture sheet
    /// uses it to save the card it was holding.
    var onUnlocked: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @State private var group = GroupStore.shared
    @State private var plus = PlusStore.shared
    /// Plus was already on when the sheet opened: nothing to celebrate.
    @State private var wasPlus = GroupStore.shared.card?.isPlus == true
    @State private var selected = PlusStore.productIDs[0]
    /// Free-trial length per product, when this Apple ID is eligible.
    @State private var trialDays: [String: Int] = [:]
    @State private var buying = false
    @State private var restoring = false
    @State private var message: String?
    @State private var legal: LegalPage?
    @State private var manage = false
    @State private var dealt = false

    /// CWG_PAYWALL (screenshot runs): sample plans when the App Store has
    /// none, and `covered` photographs the already-Plus page.
    private static let screenshot = ProcessInfo.processInfo.environment["CWG_PAYWALL"]
    private var me: UUID? { SupabaseAuth.shared.userId }

    private var isCovered: Bool {
        if let shot = Self.screenshot { return shot == "covered" }
        return group.card?.isPlus == true
    }

    private var plans: [Plan] {
        if !plus.products.isEmpty { return plus.products.map(Plan.init) }
        return Self.screenshot != nil ? Plan.samples : []
    }

    private var chosen: Plan? { plans.first { $0.id == selected } ?? plans.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                    .padding(.top, 60)
                headline
                    .padding(.top, 22)
                if isCovered {
                    benefits(unlocked: true)
                        .padding(.top, 28)
                } else {
                    selling
                }
                bottomBar
                    .padding(.top, 28)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .overlay(alignment: .topTrailing) { closeButton }
        .foregroundStyle(AppBackground.ink)
        .background { ThemeFill(color: AppBackground.sheet) }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .appColorScheme()
        .sheet(item: $legal) { LegalSheet(page: $0) }
        .manageSubscriptionsSheet(isPresented: $manage)
        .task {
            dealt = true
            await group.refresh()
            await plus.loadProducts()
            await loadTrials()
        }
        .onChange(of: group.card?.isPlus) { _, now in
            guard now == true, !wasPlus else { return }
            Haptics.success()
            if let onUnlocked {
                onUnlocked()
                dismiss()
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        ZStack {
            if isCovered, let card = group.card {
                seats(card.members, empty: 0)
            } else if case .seats = reason, let card = group.card {
                seats(card.members, empty: max(0, 4 - card.members.count))
            } else if !heroCards.isEmpty {
                fan(heroCards)
            } else {
                mark
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        // A soft pool of the theme's accent for the hero to sit in. In the
        // background so its size never widens the page.
        .background {
            RadialGradient(
                colors: [AppBackground.accent.opacity(0.18), AppBackground.accent.opacity(0)],
                center: .center, startRadius: 8, endRadius: 170
            )
            .frame(width: 420, height: 320)
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    /// The saves the sheet is about, back to front: the ones filling a
    /// full category or today's adds, with the one they were adding on
    /// top; otherwise a few of the library's liveliest — photos first.
    private var heroCards: [Item] {
        let live = items.filter(CategoryCap.counts)
        let pool: [Item]
        switch reason {
        case .category(let c):
            let key = CategoryCap.key(c)
            pool = live.filter { CategoryCap.key($0.category) == key }
        case .daily:
            pool = DailyCap.today(items, me: me)
        default:
            pool = live
        }
        let others = pool.filter { $0.id != incoming?.id }
        let photographed = others.filter { $0.imageUrl != nil } + others.filter { $0.imageUrl == nil }
        let room = switch reason {
        case .category: CategoryCap.limit
        case .daily: 4
        default: 3
        }
        let behind = Array(photographed.prefix(room - (incoming == nil ? 0 : 1))).reversed()
        return behind + [incoming].compactMap(\.self)
    }

    private func fan(_ cards: [Item]) -> some View {
        CardFan(cards: cards, dealt: dealt)
    }

    /// The group as a row of seats: who's in (a star on whoever holds
    /// Plus), and the empty chairs Plus would add.
    private func seats(_ members: [GroupCard.Member], empty: Int) -> some View {
        // Fewer seats, bigger faces; four still fit across the narrowest phone.
        let size: CGFloat = switch members.count + empty {
        case ...2: 96
        case 3: 84
        default: 68
        }
        return HStack(alignment: .top, spacing: 18) {
            ForEach(members) { member in
                VStack(spacing: 8) {
                    Text(member.initial)
                        .font(.displaySmallBold(size * 0.44, relativeTo: .title))
                        .foregroundStyle(AvatarColour.initial(member.avatarColour))
                        .frame(width: size, height: size)
                        .background(AvatarColour.color(member.avatarColour), in: .circle)
                        .overlay(alignment: .bottomTrailing) {
                            if member.isPlus && isCovered {
                                Image(systemName: "star.fill")
                                    .font(.system(size: size * 0.16, weight: .bold))
                                    .foregroundStyle(AppBackground.base)
                                    .frame(width: size * 0.34, height: size * 0.34)
                                    .background(AppBackground.ink, in: .circle)
                                    .overlay(Circle().strokeBorder(AppBackground.sheet, lineWidth: 2.5))
                                    .offset(x: 3, y: 3)
                            }
                        }
                        .shadow(color: .black.opacity(AppBackground.theme.isLight ? 0.10 : 0.3), radius: 10, y: 5)
                    Text(member.userId == me ? "You" : member.name)
                        .font((size > 68 ? Font.footnote : Font.caption).weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: size + 8)
                }
                .scaleEffect(dealt ? 1 : 0.6)
                .opacity(dealt ? 1 : 0)
            }
            let waiting = Self.waitingColours(after: members)
            ForEach(0..<empty, id: \.self) { i in
                VStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(AppBackground.ink.opacity(0.5))
                        .frame(width: size, height: size)
                        .background(AvatarColour.color(waiting[i % waiting.count]).opacity(0.32), in: .circle)
                    Text(i == 0 ? "A friend" : "And another")
                        .font((size > 68 ? Font.footnote : Font.caption).weight(.semibold))
                        .foregroundStyle(AppBackground.ink.opacity(0.62))
                        .lineLimit(1)
                        .fixedSize()
                }
                .scaleEffect(dealt ? 1 : 0.6)
                .opacity(dealt ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.3).delay(0.2 + Double(i) * 0.1), value: dealt)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.3), value: dealt)
    }

    /// An empty seat is a pale wash of a colour nobody in the group has yet.
    private static func waitingColours(after members: [GroupCard.Member]) -> [String] {
        let taken = Set(members.compactMap(\.avatarColour))
        let free = ["sky", "amber", "lilac", "rose", "teal", "mint", "coral", "plum"].filter { !taken.contains($0) }
        return free.isEmpty ? ["sky", "amber"] : free
    }

    /// An empty library has nothing to fan: the wordmark instead.
    private var mark: some View {
        VStack(spacing: 14) {
            LogoTitle(height: 56)
            Text("PLUS")
                .font(.caption.weight(.heavy))
                .tracking(3)
                .foregroundStyle(AppBackground.base)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(AppBackground.ink, in: .capsule)
        }
    }

    // MARK: - Words

    private var title: String {
        if isCovered { return "You\u{2019}ve got Plus" }
        switch reason {
        case .browsing: return "Plan without limits"
        case .seats: return "Bring two more along"
        case .category: return "Room for one more?"
        case .daily: return "That\u{2019}s \(Self.spelled(DailyCap.free)) for today"
        }
    }

    private var lede: String {
        if isCovered { return coveredLine }
        switch reason {
        case .browsing:
            return "Can We Go? is free to use. Plus takes the caps off, for everyone in your group."
        case .seats:
            return "Free groups are just for two. With Plus, four of you can share one library."
        case .category(let c):
            return "You\u{2019}ve already got \(Self.spelled(CategoryCap.limit)) \(CategoryCap.plural(c).lowercased()) lined up, the most a free group can keep of any one kind. Plus lifts the cap for all of you."
        case .daily:
            return "You\u{2019}ve added \(Self.spelled(DailyCap.free)) things today, the most the free plan takes in a day. With Plus, you can add up to \(Self.spelled(DailyCap.plus))."
        }
    }

    /// For the subscriber: when it renews or ends, and that Apple holds the
    /// subscription, so nothing in the app can change or cancel it.
    static func appleNote(_ renewal: PlusStore.Renewal?) -> String {
        var note = ""
        if let renewal {
            let plan = renewal.yearly ? "yearly" : "monthly"
            note = renewal.renews
                ? "Your \(plan) plan renews on \(renewal.day). "
                : "Your \(plan) plan ends on \(renewal.day) and won\u{2019}t renew. "
        }
        return note + "Plus is billed through your Apple Account, so that\u{2019}s the only place to change or cancel it: open the App Store, tap your photo, then Subscriptions."
    }

    /// "four", "ten", "fifty": limits read as words in a sentence.
    static func spelled(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_GB")
        return formatter.string(from: n as NSNumber) ?? "\(n)"
    }

    private var coveredLine: String {
        let holders = (group.card?.members ?? []).filter(\.isPlus)
        let mine = holders.contains { $0.userId == me }
        let others = holders.filter { $0.userId != me }.map(\.name)
        if mine && others.isEmpty { return "Your Plus covers everyone in your group." }
        if mine { return "You and \(ListFormatter.localizedString(byJoining: others)) both have Plus. You only need one for the whole group." }
        if let first = others.first, others.count == 1 {
            return "\(first) has Plus, so you have it too. Nothing to pay."
        }
        if !others.isEmpty {
            return "\(ListFormatter.localizedString(byJoining: others)) have Plus, so you have it too. Nothing to pay."
        }
        return "Your group has Plus, so you have it too. Nothing to pay."
    }

    private var headline: some View {
        VStack(spacing: 12) {
            if isCovered {
                Text("Can We Go? Plus")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(AppBackground.ink.opacity(0.6))
            }
            Text(title)
                .font(.displaySmallBold(42, relativeTo: .largeTitle))
                .lineSpacing(-4)
                .accessibilityAddTraits(.isHeader)
            Text(lede)
                .font(.subheadline)
                .foregroundStyle(AppBackground.ink.opacity(0.72))
                .lineSpacing(2)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Benefits

    private func benefits(unlocked: Bool) -> some View {
        let room = benefit(
            "sparkles", "Line up as much as you like",
            "Lists keep growing with no cap, and you can add up to \(Self.spelled(DailyCap.plus)) new things a day.", unlocked
        )
        let seats = benefit("person.3.fill", "Room for four", "Bring two more friends into your library.", unlocked)
        return VStack(spacing: 0) {
            // The one that answers this moment goes first.
            if case .seats = reason {
                seats
                Divider().overlay(AppBackground.ink.opacity(0.08)).padding(.leading, 64)
                room
            } else {
                room
                Divider().overlay(AppBackground.ink.opacity(0.08)).padding(.leading, 64)
                seats
            }
        }
        .padding(.vertical, 6)
        .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 22, style: .continuous))
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String, _ unlocked: Bool) -> some View {
        HStack(spacing: 16) {
            // Wide enough for person.3.fill, the widest of the glyphs.
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AppBackground.ink.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if unlocked {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppBackground.ink.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Selling

    @ViewBuilder
    private var selling: some View {
        benefits(unlocked: false)
            .padding(.top, 24)

        VStack(spacing: 10) {
            if plans.isEmpty {
                unavailable
            } else {
                ForEach(plans) { planTile($0) }
            }
            Text("One subscription covers your whole group.")
                .font(.footnote)
                .foregroundStyle(AppBackground.ink.opacity(0.62))
                .padding(.top, 4)
        }
        .padding(.top, 24)

        if let problem = message ?? plus.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(AppBackground.warning)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 20)
        }
    }

    /// Yearly against twelve months of monthly, rounded down.
    private var yearlySaving: Int? {
        guard let yearly = plans.first(where: \.isYearly),
              let monthly = plans.first(where: { !$0.isYearly }), monthly.amount > 0 else { return nil }
        let ratio = NSDecimalNumber(decimal: yearly.amount / (monthly.amount * 12)).doubleValue
        let saving = Int(((1 - ratio) * 100).rounded(.down))
        return saving > 0 ? saving : nil
    }

    private func planTile(_ plan: Plan) -> some View {
        let isOn = chosen?.id == plan.id
        return Button {
            Haptics.selection()
            withAnimation(.snappy) { selected = plan.id }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title2.weight(isOn ? .semibold : .regular))
                    .foregroundStyle(AppBackground.ink.opacity(isOn ? 1 : 0.35))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(plan.name).font(.headline)
                        if plan.isYearly, let saving = yearlySaving {
                            Text("Save \(saving)%")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(AppBackground.base)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(AppBackground.ink, in: .capsule)
                        }
                    }
                    Text(plan.perMonth ?? "Billed every month")
                        .font(.footnote)
                        .foregroundStyle(AppBackground.ink.opacity(0.62))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(plan.price)
                        .font(.headline)
                        .monospacedDigit()
                    Text("a \(plan.unit)")
                        .font(.caption)
                        .foregroundStyle(AppBackground.ink.opacity(0.62))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(
            isOn ? .regular.tint(AppBackground.ink.opacity(0.06)).interactive() : .regular.interactive(),
            in: .rect(cornerRadius: 20)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(AppBackground.ink.opacity(isOn ? 0.85 : 0), lineWidth: 1.5)
        )
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel("\(plan.name), \(plan.price) a \(plan.unit)")
    }

    /// No plans yet: still loading, or the App Store is out of reach.
    @ViewBuilder
    private var unavailable: some View {
        if plus.productsLoaded {
            VStack(spacing: 12) {
                Label("Couldn\u{2019}t reach the App Store just now.", systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.ink.opacity(0.62))
                Button {
                    Haptics.tap()
                    Task {
                        await plus.loadProducts()
                        await loadTrials()
                    }
                } label: {
                    Text("Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(.vertical, 8)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 140)
        }
    }

    // MARK: - Bottom bar

    private var trial: Int? {
        if Self.screenshot != nil, plus.products.isEmpty { return 7 }
        return chosen.flatMap { trialDays[$0.id] }
    }

    private var ctaTitle: String {
        if let trial { return "Try it free for \(trial) days" }
        if let chosen { return "Subscribe for \(chosen.price) a \(chosen.unit)" }
        return "Subscribe"
    }

    private var renewalTerms: String {
        guard let chosen else { return " " }
        let price = "\(chosen.price) a \(chosen.unit)"
        let lead = trial.map { "Free for \($0) days, then \(price)." } ?? "\(price)."
        return "\(lead) Renews automatically until you cancel, any time, in Settings."
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if isCovered {
                if plus.subscribed || Self.screenshot == "covered" {
                    Button {
                        Haptics.tap()
                        manage = true
                    } label: {
                        Text("Manage subscription").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)

                    Text(Self.appleNote(plus.renewal ?? (Self.screenshot == "covered" ? .sample : nil)))
                        .font(.footnote)
                        .foregroundStyle(AppBackground.ink.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .prominentGlass()
                .controlSize(.large)
            } else {
                Button {
                    Task { await buy() }
                } label: {
                    ZStack {
                        Text(ctaTitle).opacity(buying ? 0 : 1)
                        if buying { ProgressView() }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .prominentGlass()
                .controlSize(.large)
                .disabled(chosen == nil || buying)

                // What's charged after the trial, legible next to the button
                // that offers the trial (App Review guideline 3.1.2).
                Text(renewalTerms)
                    .font(.footnote)
                    .foregroundStyle(AppBackground.ink.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 18) {
                    Button(restoring ? "Restoring\u{2026}" : "Restore") {
                        Haptics.tap()
                        Task {
                            restoring = true
                            message = await plus.restore()
                            restoring = false
                        }
                    }
                    .disabled(restoring)
                    Button("Terms") { legal = .terms }
                    Button("Privacy") { legal = .privacy }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AppBackground.ink.opacity(0.75))
            }
        }
    }

    private var closeButton: some View {
        Button {
            Haptics.tap()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(AppBackground.ink)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Close")
        .padding(.top, 24)
        .padding(.trailing, 20)
    }

    // MARK: - Buying

    private func buy() async {
        guard let product = chosen?.product else { return }
        buying = true
        defer { buying = false }
        message = nil
        // The buyer's account id rides on the purchase, so the server can
        // tell whose subscription it is without trusting the phone.
        var options: Set<Product.PurchaseOption> = []
        if let me { options.insert(.appAccountToken(me)) }
        do {
            switch try await purchase(product, options: options) {
            case .success(let verification):
                await plus.handle(verification)
            case .pending:
                message = "Waiting for approval. Plus switches on as soon as it\u{2019}s through."
            default:
                break
            }
        } catch {
            message = "The purchase didn\u{2019}t go through. Please try again."
        }
    }

    private func loadTrials() async {
        for product in plus.products {
            guard let subscription = product.subscription,
                  let offer = subscription.introductoryOffer, offer.paymentMode == .freeTrial,
                  await subscription.isEligibleForIntroOffer else { continue }
            let period = offer.period
            let days = switch period.unit {
            case .day: period.value
            case .week: period.value * 7
            case .month: period.value * 30
            case .year: period.value * 365
            @unknown default: period.value
            }
            trialDays[product.id] = days
        }
    }
}

// MARK: - Card fan

/// Saves dealt into a loose stack, back to front: each card behind shows
/// its title above the next, and the last one sits on top.
private struct CardFan: View {
    let cards: [Item]
    let dealt: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let seats: [(tilt: Double, x: Double, y: Double)] = [
        (-3, -20, -84), (3, 20, -38), (-1.5, -10, 8), (1, 6, 56),
    ]

    var body: some View {
        let seats = Array(Self.seats.suffix(cards.count))
        // By their tops: centred, a taller card would ride up over the
        // title of the one behind it.
        ZStack(alignment: .top) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, item in
                let seat = seats[i]
                ItemCard(item: item, oneLineTitle: true)
                    .frame(width: 272)
                    .allowsHitTesting(false)
                    .rotationEffect(.degrees(dealt ? seat.tilt : 0))
                    .offset(x: dealt ? seat.x : 0, y: dealt ? seat.y : 90)
                    .scaleEffect(dealt ? 1 : 0.88)
                    .opacity(dealt ? 1 : 0)
                    .shadow(color: .black.opacity(AppBackground.theme.isLight ? 0.10 : 0.35), radius: 16, y: 8)
                    .animation(
                        reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.26).delay(Double(i) * 0.1),
                        value: dealt
                    )
            }
        }
    }
}

// MARK: - Busy day

/// Plus, and today's fifty are in: no selling, just what happens to this
/// one. Closing it leaves the card as it was.
struct BusyDaySheet: View {
    /// The save that met the limit, on top. Not in the store.
    var incoming: Item?
    /// Parks the save for the morning. Nil when it's already parked.
    var onLater: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @State private var dealt = false

    private var cards: [Item] {
        let behind = DailyCap.today(items, me: SupabaseAuth.shared.userId)
            .filter { $0.id != incoming?.id }
        let photographed = behind.filter { $0.imageUrl != nil } + behind.filter { $0.imageUrl == nil }
        return Array(photographed.prefix(incoming == nil ? 3 : 2)).reversed() + [incoming].compactMap(\.self)
    }

    var body: some View {
        VStack(spacing: 0) {
            CardFan(cards: cards, dealt: dealt)
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .padding(.top, 70)
                .accessibilityHidden(true)
            Text("Busy day!")
                .font(.displaySmallBold(42, relativeTo: .largeTitle))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 18)
            Text("That\u{2019}s \(PlusPaywall.spelled(DailyCap.plus)) new things today, the most anyone can add in a day. We\u{2019}ll keep this one and add it first thing tomorrow.")
                .font(.subheadline)
                .foregroundStyle(AppBackground.ink.opacity(0.72))
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Button {
                Haptics.success()
                onLater?()
                dismiss()
            } label: {
                Text("Save for tomorrow")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .prominentGlass()
            .controlSize(.large)
            .padding(.top, 26)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topTrailing) {
            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppBackground.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close")
            .padding(.top, 24)
            .padding(.trailing, 20)
        }
        .foregroundStyle(AppBackground.ink)
        .background { ThemeFill(color: AppBackground.sheet) }
        .presentationDetents([typeSize.isAccessibilitySize ? .large : .height(560)])
        .presentationDragIndicator(.visible)
        .appColorScheme()
        .onAppear { dealt = true }
    }
}

// MARK: - Settings

/// Settings' way in, unprompted: the paywall, and the two rows App Review
/// looks for — Restore Purchases and Manage Subscription.
/// The Settings rows for Plus. Its sheets hang off the Settings list: one
/// attached to a list section tears Settings down along with it.
/// The purchase plumbing, on the Account page; Plus itself is a row on
/// the first page of Settings.
struct PlusSection: View {
    @Binding var manage: Bool
    @State private var plus = PlusStore.shared
    @State private var restoring = false
    @State private var note: String?

    /// One line for the Plus row: whose subscription it's on, or what it adds.
    static func status(for card: GroupCard?) -> String {
        guard let card else { return "No cap on lists, and room for four" }
        guard card.isPlus else { return "Free plan. Plus lifts the caps and makes room for four" }
        let holders = card.members.filter(\.isPlus)
        if holders.contains(where: { $0.userId == SupabaseAuth.shared.userId }) {
            if let renewal = PlusStore.shared.renewal {
                return "Active until \(renewal.day)"
            }
            return "Active for the whole group"
        }
        if let first = holders.first { return "Active for the whole group, through \(first.name)\u{2019}s subscription" }
        return "Active for the whole group"
    }

    var body: some View {
        if SupabaseAuth.shared.signedIn {
            Section {
                if plus.subscribed {
                    Button {
                        Haptics.tap()
                        manage = true
                    } label: {
                        HStack {
                            SettingsRow(title: "Manage subscription")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppBackground.ink.opacity(0.45))
                        }
                    }
                }
                Button {
                    Haptics.tap()
                    Task {
                        restoring = true
                        note = await plus.restore()
                        restoring = false
                    }
                } label: {
                    HStack {
                        SettingsRow(title: "Restore purchases")
                        Spacer()
                        if restoring { ProgressView() }
                    }
                }
                .disabled(restoring)
            } header: {
                Text("Plus")
            } footer: {
                if let note = note ?? plus.problem {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(AppBackground.warning)
                } else if plus.subscribed {
                    Text(PlusPaywall.appleNote(plus.renewal))
                        .font(.footnote)
                }
            }
            .listRowBackground(SettingsView.rowBackground)
        }
    }
}
