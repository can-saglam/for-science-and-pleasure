import StoreKit
import SwiftData
import SwiftUI

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
                .foregroundStyle(AppBackground.secondaryInk)
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

/// Plus in Settings, for someone who came looking: the free plan and Plus
/// side by side, then whose subscription it's on, or the plans. The
/// paywall is for the moments a limit is met. Restore Purchases and
/// Manage Subscription, which App Review looks for, are both here.
