import StoreKit
import SwiftData
import SwiftUI

struct PlusPage: View {
    @Binding var manage: Bool

    @Environment(\.purchase) private var purchase
    @State private var group = GroupStore.shared
    @State private var plus = PlusStore.shared
    @State private var buyer = PlusCheckout(samples: PlusPage.screenshot != nil)
    @State private var legal: LegalPage?

    /// CWG_PLUS (screenshot runs): `free` photographs the page with the
    /// plans, `mine` a subscription of your own.
    private static let screenshot = ProcessInfo.processInfo.environment["CWG_PLUS"]
    private var me: UUID? { SupabaseAuth.shared.userId }
    private var card: GroupCard? { group.card?.forScreenshots }
    private var isPlus: Bool { Self.screenshot == "free" ? false : card?.isPlus == true }
    private var solo: Bool { (card?.members.count ?? 1) == 1 }

    private var renewal: PlusStore.Renewal? {
        plus.renewal ?? (Self.screenshot == "mine" ? .sample : nil)
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))

            Section {
                comparison
            } header: {
                SettingsSectionHeader("Free and Plus")
            } footer: {
                note("One subscription covers everyone in your library.")
            }
            .listRowBackground(SettingsView.rowBackground)

            if isPlus {
                subscription
            } else {
                checkout
            }
        }
        .sheet(item: $legal) { LegalSheet(page: $0) }
        .task {
            await buyer.load()
        }
        .onChange(of: card?.isPlus) { _, now in
            if now == true { Haptics.success() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isPlus ? "Plus is on" : "You\u{2019}re on Free")
                .font(.displaySmallBold(28, relativeTo: .title2))
                .foregroundStyle(AppBackground.ink)
                .accessibilityAddTraits(.isHeader)
            Text(isPlus ? payer : "Plus gives your library more room, and space for two more people.")
                .font(.footnote)
                .foregroundStyle(AppBackground.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// Whose subscription it's on, so nobody pays twice without knowing.
    private var payer: String {
        let holders = (card?.members ?? []).filter(\.isPlus)
        let mine = plus.subscribed || Self.screenshot == "mine" || holders.contains { $0.userId == me }
        let others = holders.filter { $0.userId != me }.map(\.name)
        if mine && others.isEmpty {
            return solo ? "On your subscription." : "On your subscription, for everyone in \(card?.name ?? "your library")."
        }
        if mine {
            return "You and \(ListFormatter.localizedString(byJoining: others)) both pay. One subscription is enough for everyone."
        }
        if let first = others.first, others.count == 1 {
            return "On \(first)\u{2019}s subscription. Nothing for you to pay."
        }
        return "On your group\u{2019}s subscription. Nothing for you to pay."
    }

    // MARK: Free and Plus

    private var comparison: some View {
        let rows: [(String, String, String)] = [
            ("People in a library", "2", "4"),
            ("Saves per category", "\(CategoryCap.limit)", "No limit"),
            ("New saves a day", "\(DailyCap.free)", "\(DailyCap.plus)"),
            ("Picks, the map and reminders", "\u{2713}", "\u{2713}"),
        ]
        return VStack(spacing: 12) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                planHeading("Free", current: !isPlus)
                planHeading("Plus", current: isPlus)
            }
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 0) {
                    Text(row.0)
                        .font(.subheadline)
                        .foregroundStyle(AppBackground.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.1)
                        .font(.subheadline)
                        .foregroundStyle(AppBackground.secondaryInk)
                        .frame(width: 76)
                    Text(row.2)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppBackground.ink)
                        .frame(width: 76)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.0): free, \(row.1 == "\u{2713}" ? "included" : row.1); Plus, \(row.2 == "\u{2713}" ? "included" : row.2)")
            }
        }
        .monospacedDigit()
        .padding(.vertical, 8)
    }

    /// The plan you're on is filled in.
    private func planHeading(_ name: String, current: Bool) -> some View {
        Text(name)
            .font(.footnote.weight(.bold))
            .foregroundStyle(current ? AppBackground.base : AppBackground.secondaryInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(current ? AppBackground.ink : .clear, in: .capsule)
            .frame(width: 76)
            .accessibilityLabel(current ? "\(name), your plan" : name)
    }

    // MARK: Subscribed

    @ViewBuilder private var subscription: some View {
        let yours = plus.subscribed || Self.screenshot == "mine"
        Section {
            if yours {
                if let renewal {
                    LabeledContent {
                        Text(renewal.renews ? "Renews \(renewal.day)" : "Ends \(renewal.day)")
                            .foregroundStyle(AppBackground.secondaryInk)
                    } label: {
                        SettingsRow(title: renewal.yearly ? "Yearly plan" : "Monthly plan")
                    }
                }
                Button {
                    Haptics.tap()
                    manage = true
                } label: {
                    HStack {
                        SettingsRow(title: "Manage subscription")
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppBackground.ink.opacity(0.45))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            restoreRow
        } header: {
            SettingsSectionHeader(yours ? "Your subscription" : "Purchases")
        } footer: {
            if let problem = buyer.problem {
                warning(problem)
            } else {
                note(yours
                    ? "Billed through your Apple Account. You can also change or cancel it in the App Store: tap your photo, then Subscriptions."
                    : "Paid for Plus before on this Apple ID? Restore it here.")
            }
        }
        .listRowBackground(SettingsView.rowBackground)
    }

    // MARK: Free

    @ViewBuilder private var checkout: some View {
        Section {
            if buyer.plans.isEmpty {
                unavailable
            } else {
                ForEach(buyer.plans) { planRow($0) }
            }
        } header: {
            SettingsSectionHeader("Choose a plan")
        }
        .listRowBackground(SettingsView.rowBackground)

        Section {
            VStack(spacing: 10) {
                Button {
                    Task { await buyer.buy(with: purchase) }
                } label: {
                    ZStack {
                        Text(buyer.cta).opacity(buyer.buying ? 0 : 1)
                        if buyer.buying { ProgressView() }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .prominentGlass()
                .controlSize(.large)
                .disabled(buyer.chosen == nil || buyer.buying)

                Text(buyer.terms)
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))

        Section {
            restoreRow
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let problem = buyer.problem {
                    warning(problem)
                }
                HStack(spacing: 0) {
                    Button("Terms") {
                        Haptics.tap()
                        legal = .terms
                    }
                    Text("\u{00B7}").accessibilityHidden(true)
                    Button("Privacy") {
                        Haptics.tap()
                        legal = .privacy
                    }
                }
                .buttonStyle(FooterLinkStyle())
                .padding(.leading, -FooterLinkStyle.inset)
                .font(.footnote)
                .foregroundStyle(AppBackground.secondaryInk)
            }
        }
        .listRowBackground(SettingsView.rowBackground)
    }

    private func planRow(_ plan: PlusPlan) -> some View {
        let isOn = buyer.chosen?.id == plan.id
        return Button {
            Haptics.selection()
            withAnimation(.snappy) { buyer.choose(plan) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(plan.name)
                            .foregroundStyle(AppBackground.ink)
                        if plan.isYearly, let saving = buyer.yearlySaving {
                            Text("Save \(saving)%")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(AppBackground.base)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(AppBackground.ink, in: .capsule)
                        }
                    }
                    Text(plan.perMonth ?? "Billed every month")
                        .font(.footnote)
                        .foregroundStyle(AppBackground.secondaryInk)
                }
                Spacer(minLength: 8)
                Text("\(plan.price) a \(plan.unit)")
                    .monospacedDigit()
                    .foregroundStyle(AppBackground.ink)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppBackground.ink)
                    .opacity(isOn ? 1 : 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// No plans yet: still loading, or the App Store is out of reach.
    @ViewBuilder private var unavailable: some View {
        if plus.productsLoaded {
            Button {
                Haptics.tap()
                Task { await buyer.load() }
            } label: {
                HStack {
                    SettingsRow(title: "Couldn\u{2019}t reach the App Store", subtitle: "Tap to try again")
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppBackground.secondaryInk)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 52)
        }
    }

    private var restoreRow: some View {
        Button {
            Haptics.tap()
            Task { await buyer.restore() }
        } label: {
            HStack {
                SettingsRow(title: "Restore purchases")
                Spacer()
                if buyer.restoring { ProgressView() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(buyer.restoring)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AppBackground.secondaryInk)
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AppBackground.warning)
    }
}

/// Restore, Terms and Privacy: small type, a full 44pt to hit.
struct FooterLinkStyle: ButtonStyle {
    static let inset: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Self.inset)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
