import StoreKit
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
struct PlusPlan: Identifiable {
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
        PlusPlan(id: PlusStore.productIDs[0], name: "Yearly", price: "£21.99", unit: "year", perMonth: "£1.83 a month", amount: 21.99),
        PlusPlan(id: PlusStore.productIDs[1], name: "Monthly", price: "£2.99", unit: "month", perMonth: nil, amount: 2.99),
    ]
}

/// Choosing and buying a plan, for the paywall and the Plus page in
/// Settings alike: the plans on offer, the one chosen, any free trial, and
/// the purchase or restore in flight.
@MainActor
@Observable
final class PlusCheckout {
    /// Screenshot runs: sample plans and a seven-day trial when the App
    /// Store has none.
    let samples: Bool
    var selected = PlusStore.productIDs[0]
    /// Free-trial length per product, when this Apple ID is eligible.
    private(set) var trialDays: [String: Int] = [:]
    private(set) var buying = false
    private(set) var restoring = false
    private(set) var message: String?

    private let plus = PlusStore.shared

    init(samples: Bool) {
        self.samples = samples
    }

    var plans: [PlusPlan] {
        if !plus.products.isEmpty { return plus.products.map(PlusPlan.init) }
        return samples ? PlusPlan.samples : []
    }

    var chosen: PlusPlan? { plans.first { $0.id == selected } ?? plans.first }

    var trial: Int? {
        if samples, plus.products.isEmpty { return 7 }
        return chosen.flatMap { trialDays[$0.id] }
    }

    /// Yearly against twelve months of monthly, rounded down.
    var yearlySaving: Int? {
        guard let yearly = plans.first(where: \.isYearly),
              let monthly = plans.first(where: { !$0.isYearly }), monthly.amount > 0 else { return nil }
        let ratio = NSDecimalNumber(decimal: yearly.amount / (monthly.amount * 12)).doubleValue
        let saving = Int(((1 - ratio) * 100).rounded(.down))
        return saving > 0 ? saving : nil
    }

    var cta: String {
        if let trial { return "Try it free for \(trial) days" }
        if let chosen { return "Subscribe for \(chosen.price) a \(chosen.unit)" }
        return "Subscribe"
    }

    /// What's charged after the trial, legible next to the button that
    /// offers the trial (App Review guideline 3.1.2).
    var terms: String {
        guard let chosen else { return " " }
        let price = "\(chosen.price) a \(chosen.unit)"
        let lead = trial.map { "Free for \($0) days, then \(price)." } ?? "\(price)."
        return "\(lead) Renews automatically. Cancel any time in your Apple Account subscriptions."
    }

    /// What went wrong last, here or in the store.
    var problem: String? { message ?? plus.problem }

    func choose(_ plan: PlusPlan) {
        selected = plan.id
    }

    /// The products, then which of them this Apple ID gets a trial on.
    func load() async {
        await plus.loadProducts()
        trialDays = await Self.trials(plus.products)
    }

    func buy(with purchase: PurchaseAction) async {
        guard let product = chosen?.product else { return }
        buying = true
        defer { buying = false }
        message = nil
        message = await Self.buy(product, with: purchase)
    }

    func restore() async {
        restoring = true
        message = await plus.restore()
        restoring = false
    }

    private static func trials(_ products: [Product]) async -> [String: Int] {
        var days: [String: Int] = [:]
        for product in products {
            guard let subscription = product.subscription,
                  let offer = subscription.introductoryOffer, offer.paymentMode == .freeTrial,
                  await subscription.isEligibleForIntroOffer else { continue }
            let period = offer.period
            days[product.id] = switch period.unit {
            case .day: period.value
            case .week: period.value * 7
            case .month: period.value * 30
            case .year: period.value * 365
            @unknown default: period.value
            }
        }
        return days
    }

    /// Nil once it's through or cancelled; otherwise what to say.
    private static func buy(_ product: Product, with purchase: PurchaseAction) async -> String? {
        // The buyer's account id rides on the purchase, so the server can
        // tell whose subscription it is without trusting the phone.
        var options: Set<Product.PurchaseOption> = []
        if let me = SupabaseAuth.shared.userId { options.insert(.appAccountToken(me)) }
        do {
            switch try await purchase(product, options: options) {
            case .success(let verification):
                await PlusStore.shared.handle(verification)
            case .pending:
                return "Waiting for approval. Plus switches on as soon as it\u{2019}s through."
            default:
                break
            }
        } catch {
            return "The purchase didn\u{2019}t go through. Please try again."
        }
        return nil
    }
}
