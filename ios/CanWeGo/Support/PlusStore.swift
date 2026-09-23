import Foundation
import Observation
import StoreKit

/// Can We Go? Plus on this phone: what StoreKit says this Apple ID holds,
/// and the hand-off to the server. Subscriptions belong to people; a group
/// is Plus whenever any member's `entitlements` row is live, and that row
/// is only ever written by `record-entitlement` after asking Apple.
///
/// No webhook: the app posts every verified transaction StoreKit reports
/// (purchase, renewal, restore, a purchase made on another device), and
/// once a day on the first foreground, so renewals propagate without one.
@Observable
@MainActor
final class PlusStore {
    static let shared = PlusStore()

    nonisolated static let productIDs = [
        "com.cansaglam.CanWeGo.plus.yearly",
        "com.cansaglam.CanWeGo.plus.monthly",
    ]

    /// This Apple ID holds a live Plus subscription, per StoreKit.
    private(set) var subscribed = false
    /// Why the last purchase couldn't be credited to this account, if it
    /// couldn't. Shown on the paywall and in Settings.
    private(set) var problem: String?
    /// The two plans, once the App Store has described them. Empty while
    /// loading, offline, or before they exist in App Store Connect.
    private(set) var products: [Product] = []
    private(set) var productsLoaded = false

    private var listener: Task<Void, Never>?

    private static let postedKey = "plusLastPosted"
    private static var defaults: UserDefaults { UserDefaults(suiteName: SharedInbox.groupID) ?? .standard }

    private init() {}

    /// Once, at launch: listen for transactions StoreKit delivers outside a
    /// purchase call, and bring the server up to date with what's held.
    func start() {
        guard listener == nil else { return }
        listener = Task.detached(priority: .utility) {
            for await result in Transaction.updates {
                await PlusStore.shared.handle(result)
            }
        }
        Task { await reconcile() }
    }

    /// A purchase from the paywall, or a transaction StoreKit pushed.
    /// Finished only once the server has it, so an offline purchase is
    /// delivered again next launch and credited then.
    func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result,
              Self.productIDs.contains(transaction.productID) else { return }
        if await record(result.jwsRepresentation, stamp: Self.stamp(transaction)) {
            await transaction.finish()
        }
        await refreshSubscribed()
    }

    /// Posts the live subscription if the server hasn't seen this state of
    /// it today. `force` (Restore, Try again) posts regardless.
    func reconcile(force: Bool = false) async {
        guard SupabaseAuth.shared.signedIn else { return }
        guard let (result, transaction) = await current() else {
            subscribed = false
            return
        }
        subscribed = true
        let stamp = Self.stamp(transaction)
        let last = Self.defaults.dictionary(forKey: Self.postedKey)
        let seen = last?["stamp"] as? String == stamp
            && (last?["at"] as? Date).map { Date.now.timeIntervalSince($0) < 24 * 3600 } == true
        guard force || !seen else { return }
        _ = await record(result.jwsRepresentation, stamp: stamp)
    }

    /// Restore Purchases: ask the App Store for this Apple ID's history,
    /// then credit whatever is live. Nil on success, else what to say.
    func restore() async -> String? {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return nil
        } catch {
            return "Couldn\u{2019}t reach the App Store. Try again in a moment."
        }
        await reconcile(force: true)
        if !subscribed { return "No Plus subscription on this Apple ID." }
        return problem
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        let loaded = (try? await Product.products(for: Self.productIDs)) ?? []
        products = loaded.sorted { $0.price > $1.price }
        productsLoaded = true
    }

    // MARK: - Plumbing

    private func current() async -> (VerificationResult<Transaction>, Transaction)? {
        var best: (VerificationResult<Transaction>, Transaction)?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, Self.productIDs.contains(t.productID),
                  t.revocationDate == nil else { continue }
            if best == nil || (t.expirationDate ?? .distantPast) > (best!.1.expirationDate ?? .distantPast) {
                best = (result, t)
            }
        }
        return best
    }

    private func refreshSubscribed() async {
        subscribed = await current() != nil
    }

    /// One state of one subscription: renewals change the expiry.
    private static func stamp(_ t: Transaction) -> String {
        "\(t.originalID)|\(t.expirationDate?.timeIntervalSince1970 ?? 0)"
    }

    /// True when the server has given its final word on this transaction
    /// (recorded, or refused for good), false when it's worth retrying.
    private func record(_ jws: String, stamp: String) async -> Bool {
        let retryLater = "Your purchase went through, but Can We Go? couldn\u{2019}t confirm it yet. It\u{2019}ll try again next time you open the app."
        guard SupabaseAuth.shared.signedIn else { return false }
        do {
            let jwt = try await SupabaseAuth.shared.validToken()
            var request = URLRequest(url: SupabaseAuth.baseURL.appending(path: "functions/v1/record-entitlement"))
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["signed_transaction": jws])
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                problem = nil
                Self.defaults.set(["stamp": stamp, "at": Date.now], forKey: Self.postedKey)
                await GroupStore.shared.refresh()
                return true
            case 409:
                problem = "This Apple ID\u{2019}s Plus is already linked to another Can We Go? account."
                return true
            case 404:
                // Apple has never heard of it: a local StoreKit test
                // transaction. Nothing a retry can fix.
                problem = "The App Store couldn\u{2019}t find that purchase."
                return true
            default:
                problem = retryLater
                return false
            }
        } catch {
            problem = retryLater
            return false
        }
    }
}
