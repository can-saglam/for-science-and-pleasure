import SwiftUI

// MARK: - Themes

/// Five moods, one app: the signature deep blue, a pure black, a dark
/// forest green, a deep wine red, and a cream paper for daylight. Each
/// theme derives its whole palette — tab shades, sheet depth, control
/// accent — from one base color, so everything stays tuned.
enum AppTheme: String, CaseIterable, Identifiable {
    case midnight
    case ink
    case forest
    case wine
    case cream

    var id: String { rawValue }

    var name: String {
        switch self {
        case .midnight: "Midnight Blue"
        case .ink: "Pure Black"
        case .forest: "Forest Green"
        case .wine: "Wine Red"
        case .cream: "Cream"
        }
    }

    /// Cream is the only light page; everything else is a dark base.
    var isLight: Bool { self == .cream }

    var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// Logo, titles, and anything that used to be hardcoded white.
    /// Midnight and forest print in the warm cream of the olive
    /// reference; cream flips to black; ink and wine stay white.
    var ink: Color {
        switch self {
        case .cream: .black
        case .midnight, .forest: Self.forestCream
        default: .white
        }
    }

    /// The color everything else is mixed from.
    var base: Color {
        switch self {
        case .midnight:
            (Color(hex: "#0C169D") ?? Color(red: 0.047, green: 0.086, blue: 0.616))
                .shifted(brightness: -0.12)
        case .ink:
            .black
        case .forest:
            Color(hex: "#323316") ?? Color(red: 0.196, green: 0.200, blue: 0.086)
        case .wine:
            Color(hex: "#440015") ?? Color(red: 0.267, green: 0, blue: 0.082)
        case .cream:
            Color(hex: "#F8F0CA") ?? Color(red: 0.973, green: 0.941, blue: 0.792)
        }
    }

    /// Sampled from the olive print — the running figure and the “GO”.
    static let forestCream = Color(hex: "#F6E2B6") ?? Color(red: 0.965, green: 0.886, blue: 0.714)

    /// The matching alternate home-screen icon; nil means the primary
    /// (midnight blue) icon.
    var iconName: String? {
        switch self {
        case .midnight: nil
        case .ink: "AppIconInk"
        case .forest: "AppIconForest"
        case .wine: "AppIconWine"
        case .cream: "AppIconCream"
        }
    }

    /// Tint for controls: toolbar buttons, the selected tab, links.
    var accent: Color {
        switch self {
        case .midnight: Color(hex: "#97A4FF") ?? .white
        case .ink: .white
        case .forest: Self.forestCream
        case .wine: Color(hex: "#FFA2B8") ?? .white
        case .cream: .black
        }
    }

    /// How much of an item's color soaks into its card. Pure black needs a
    /// slightly stronger pour to keep cards from going murky; cream wants
    /// a whisper so the paper still reads as paper.
    var cardAccentMix: Double {
        switch self {
        case .ink: 0.30
        case .cream: 0.16
        default: 0.34
        }
    }

    /// The lift that separates a card from the page behind it. Dark
    /// themes mix in their ink (white, or forest's cream); cream mixes
    /// in black so cards sit *on* the paper instead of bleaching out.
    var cardLiftColor: Color { isLight ? .black : ink }

    var cardLiftAmount: Double {
        switch self {
        case .ink: 0.07
        case .cream: 0.05
        default: 0.06
        }
    }
}

/// The chosen theme, persisted in the App Group so the share extension
/// paints the same color the moment it opens.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var current: AppTheme {
        didSet {
            defaults?.set(current.rawValue, forKey: "appTheme")
            applyInterfaceStyle()
            #if !APP_EXTENSION
            WidgetStore.writeTheme(current)
            #endif
        }
    }

    private let defaults = UserDefaults(suiteName: SharedInbox.groupID)

    private init() {
        // CWG_THEME env var lets simulator runs pin a theme for screenshots.
        let stored = ProcessInfo.processInfo.environment["CWG_THEME"]
            ?? defaults?.string(forKey: "appTheme")
        current = stored.flatMap(AppTheme.init(rawValue:)) ?? .midnight
        // After the singleton is live — doing this inline re-enters
        // `shared` mid-init and traps. `writeTheme` used to read
        // `ThemeStore.shared` from here and crashed launch on device.
        applyInterfaceStyle()
        #if !APP_EXTENSION
        let theme = current
        DispatchQueue.main.async {
            WidgetStore.writeTheme(theme)
        }
        #endif
    }

    /// A user-chosen switch. Every window cross-dissolves as one picture:
    /// SwiftUI's colours, the UIKit trait flip and the tint all land under
    /// a single fade, instead of rows re-tinting one after another while
    /// the layout animates underneath. Reduce Motion just cuts.
    func select(_ theme: AppTheme) {
        guard theme != current else { return }
        #if !APP_EXTENSION
        // The trait flip goes inside the fade, synchronously: this is a
        // user action (never inside `body`), and left to the async path
        // it would land a frame after the SwiftUI colours, so UIKit-owned
        // surfaces — menus, glass, field placeholders — would hard-cut.
        let style: UIUserInterfaceStyle = theme.isLight ? .light : .dark
        let ink = UIColor(theme.ink)
        let flip = {
            for window in Self.windows {
                window.overrideUserInterfaceStyle = style
                window.tintColor = ink
            }
        }
        if UIAccessibility.isReduceMotionEnabled {
            flip()
        } else {
            for window in Self.windows {
                UIView.transition(
                    with: window,
                    duration: 0.35,
                    options: [.transitionCrossDissolve, .allowUserInteraction],
                    animations: flip
                )
            }
        }
        #endif
        current = theme
    }

    /// UIKit pickers, menus and glass follow the *window* style, not
    /// SwiftUI's `preferredColorScheme`. Cream is light; everything else
    /// stays dark — otherwise a Light system setting paints black
    /// "Google Maps" on a dark row. Always hops to the next turn so a
    /// trait change never lands inside `body` or `dispatch_once`.
    func applyInterfaceStyle() {
        #if !APP_EXTENSION
        let style: UIUserInterfaceStyle = current.isLight ? .light : .dark
        let ink = UIColor(current.ink)
        DispatchQueue.main.async {
            for window in Self.windows {
                if window.overrideUserInterfaceStyle != style {
                    window.overrideUserInterfaceStyle = style
                }
                window.tintColor = ink
            }
        }
        #endif
    }

    #if !APP_EXTENSION
    private static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }
    #endif
}

// MARK: - Derived palette

/// Every screen sits on a slightly different shade of the theme base, so
/// tabs feel distinct without shouting. Dark themes keep light text;
/// cream flips the ink to black.
enum AppBackground {
    static var theme: AppTheme { ThemeStore.shared.current }

    /// The whole palette derives from this — cards and tab shades follow.
    static var base: Color { theme.base }

    /// Control accent for the current theme.
    static var accent: Color { theme.accent }

    /// Logo and primary marks — cream on midnight and forest, black on cream, white elsewhere.
    static var ink: Color { theme.ink }

    /// Label on a white (or near-white) prominent glass pill.
    /// Cream prints black; dark themes print the page colour.
    static var onProminent: Color { theme.isLight ? ink : base }

    /// The small icon squircle on settings rows. Always a light badge with
    /// a dark glyph — accent on the dark themes, white on cream — so a
    /// theme switch never inverts it: a cross-fade through an inversion
    /// passes a frame where badge and glyph are the same grey.
    static var badge: Color { theme.isLight ? .white : accent }
    static var badgeGlyph: Color { theme.isLight ? ink : base }

    /// Warnings, error notes, duplicate notices. System orange reads on the
    /// dark pages but sits at ~1.5:1 on cream paper, so cream deepens it
    /// to a burnt orange.
    static var warning: Color {
        theme.isLight ? Color(red: 0.62, green: 0.32, blue: 0) : .orange
    }

    /// Destructive rows and urgent copy. Deeper on cream (system red is
    /// under 3:1 there); on wine, system red melts into the page, so it
    /// lifts toward the theme's pink instead.
    static var destructive: Color {
        if theme.isLight { return Color(red: 0.72, green: 0.10, blue: 0.14) }
        if theme == .wine { return Color(red: 1.0, green: 0.47, blue: 0.53) }
        return .red
    }

    /// A hairline wash for inset rows and fields. White on dark pages,
    /// black on cream, so the same 8% still reads as a recess.
    static func wash(_ opacity: Double) -> Color {
        ink.opacity(opacity)
    }

    /// A touch toward teal, and brighter: out on the town. Cream keeps its
    /// pages on the one paper the drawers use — the tab tints read as
    /// dirt on a light page.
    static var places: Color {
        theme.isLight ? sheet : base.shifted(hue: -0.020, brightness: 0.045)
    }
    /// A touch toward violet.
    static var library: Color {
        theme.isLight ? sheet : base.shifted(hue: 0.018, brightness: 0.02)
    }
    /// Sheets sit slightly deeper than the pages behind them.
    static var sheet: Color {
        if theme.isLight { return base.shifted(brightness: -0.035) }
        return theme == .ink ? base.shifted(brightness: 0.03) : base.shifted(brightness: -0.045)
    }

    // MARK: Swipe action fills

    /// Stock green/red swipe buttons clashed with every theme, so these
    /// derive from the palette. Deepened accent — dark enough that the
    /// system's white label stays readable. Ink, forest and cream use
    /// charcoal because their accents are already white, cream or black.
    static var swipeDone: Color {
        theme == .ink || theme == .forest || theme.isLight
            ? Color(white: 0.24)
            : accent.mix(with: .black, by: 0.4)
    }
    /// Red pulled toward the base: still unmistakably destructive, but
    /// speaking the theme's tone rather than shouting over it.
    static var swipeDelete: Color {
        Color(red: 0.85, green: 0.16, blue: 0.22).mix(with: base, by: theme.isLight ? 0.15 : 0.4)
    }
    /// A quiet lift off the base for the non-committal "put back". The
    /// system draws swipe labels white, so cream uses a mid grey rather
    /// than a darker paper that would leave white type at 1.4:1.
    static var swipePutBack: Color {
        theme.isLight ? Color(white: 0.45) : base.shifted(brightness: 0.18)
    }
}

extension Color {
    /// Small HSB nudges off a base color.
    func shifted(hue dh: Double = 0, saturation ds: Double = 0, brightness db: Double = 0) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var nh = (Double(h) + dh).truncatingRemainder(dividingBy: 1)
        if nh < 0 { nh += 1 }
        return Color(
            hue: nh,
            saturation: min(max(Double(s) + ds, 0), 1),
            brightness: min(max(Double(b) + db, 0), 1),
            opacity: Double(a)
        )
    }
}

/// Full-bleed page fill. Call sites share this so lists and sheets stay
/// on the same colour.
struct ThemeFill: View {
    var color: Color

    var body: some View {
        color.ignoresSafeArea()
    }
}

extension View {
    /// Full-bleed tinted backdrop behind a List/ScrollView.
    func appBackground(_ color: Color) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { ThemeFill(color: color) }
    }

    /// Light text on the dark bases, black on cream. Midnight and forest
    /// also paint primary type in the warm cream ink.
    func appColorScheme() -> some View {
        modifier(AppColorSchemeModifier())
    }

    /// White glass pill, dark-enough label — cream gets black type.
    func prominentGlass() -> some View {
        self
            .buttonStyle(.glassProminent)
            .tint(.white)
            .foregroundStyle(AppBackground.onProminent)
    }
}

/// Observes the theme so flipping cream ↔ dark actually updates the
/// window. Does not also push `environment(\.colorScheme)` — that loops
/// with `preferredColorScheme` and crashes AttributeGraph.
private struct AppColorSchemeModifier: ViewModifier {
    @State private var themes = ThemeStore.shared

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(themes.current.colorScheme)
            .foregroundStyle(themes.current.ink)
    }
}
