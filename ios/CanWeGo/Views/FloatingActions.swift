import SwiftUI

/// Actions floating bottom right over a drawer: plain glass circles for
/// the side actions, and the main one in solid white, spelled out. A soft
/// fade in the corner keeps text from running under them. The detail
/// drawer's and the capture preview's.
struct FloatingActions<Content: View>: View {
    private let content: Content
    @State private var keyboardUp = false
    @Environment(\.floatingRowMatch) private var match
    @Environment(\.floatingRowFloor) private var floor
    @Environment(\.floatingRowTrailing) private var trailing

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 12) {
                    content
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, trailing ?? 20)
        .padding(.top, 28)
        // Into the home-indicator margin, the way the system's own
        // floating controls sit, while keeping clear of the corner. Over
        // the keyboard there's no margin to borrow, so they stand off it.
        .padding(.bottom, bottomPadding)
        // Turning iPhone Duo posts a show with no keyboard on screen.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard Self.keyboardOnScreen(note) else { return }
            withAnimation(.snappy) { keyboardUp = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.snappy) { keyboardUp = false }
        }
        .background(alignment: .bottomTrailing) {
            RadialGradient(
                colors: [AppBackground.sheet.opacity(0.92), AppBackground.sheet.opacity(0)],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 220
            )
            // Taller than the row, so it fades out fully above the
            // buttons rather than stopping at a hard edge.
            .frame(width: 220, height: 220)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

extension FloatingActions {
    /// Level with the side bar's Add button when there's one to match,
    /// bottom edges together.
    private var bottomPadding: CGFloat {
        if keyboardUp { return 12 }
        if let match, let floor { return floor - match.maxY }
        return -8
    }

    private static func keyboardOnScreen(_ note: Notification) -> Bool {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let screen = note.object as? UIScreen
        else { return true }
        return frame.height > 0 && frame.intersects(screen.bounds)
    }
}

/// Solid white: the reason the drawer is open.
struct FloatingMainButton: View {
    @Environment(\.floatingRowMatch) private var match
    private var side: CGFloat { match?.height ?? 54 }
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ label: String, systemImage symbol: String, action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 20)
            .frame(minWidth: side, minHeight: side)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppBackground.onProminent)
        .glassEffect(.regular.tint(.white).interactive(), in: .capsule)
        .accessibilityLabel(label)
    }
}

/// Plain glass, a symbol alone; the label is for VoiceOver.
struct FloatingCircleButton: View {
    @Environment(\.floatingRowMatch) private var match
    private var side: CGFloat { match?.height ?? 54 }
    let symbol: String
    let label: String
    var tint: Color = AppBackground.ink
    let action: () -> Void

    init(_ label: String, systemImage symbol: String, tint: Color = AppBackground.ink, action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: side, height: side)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}
