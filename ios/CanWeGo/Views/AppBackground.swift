import SwiftUI

// MARK: - Themes

/// Four moods, one app: the signature deep blue, a pure black, a dark
/// forest green, and a deep wine red. Each theme derives its whole palette —
/// tab shades, sheet depth, control accent — from one base color, so
/// everything stays tuned.
enum AppTheme: String, CaseIterable, Identifiable {
    case midnight
    case ink
    case forest
    case wine

    var id: String { rawValue }

    var name: String {
        switch self {
        case .midnight: "Midnight Blue"
        case .ink: "Pure Black"
        case .forest: "Forest Green"
        case .wine: "Wine Red"
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
            Color(hex: "#07231A") ?? Color(red: 0.027, green: 0.137, blue: 0.102)
        case .wine:
            Color(hex: "#440015") ?? Color(red: 0.267, green: 0, blue: 0.082)
        }
    }

    /// The matching alternate home-screen icon; nil means the primary
    /// (midnight blue) icon.
    var iconName: String? {
        switch self {
        case .midnight: nil
        case .ink: "AppIconInk"
        case .forest: "AppIconForest"
        case .wine: "AppIconWine"
        }
    }

    /// Tint for controls: toolbar buttons, the selected tab, links.
    var accent: Color {
        switch self {
        case .midnight: Color(hex: "#97A4FF") ?? .white
        case .ink: .white
        case .forest: Color(hex: "#8FD9B6") ?? .white
        case .wine: Color(hex: "#FFA2B8") ?? .white
        }
    }

    /// How much of an item's color soaks into its card. Pure black needs a
    /// slightly stronger pour to keep cards from going murky.
    var cardAccentMix: Double {
        switch self {
        case .ink: 0.30
        default: 0.34
        }
    }

    /// The lift that separates a card from the page behind it.
    var cardWhiteLift: Double {
        switch self {
        case .ink: 0.07
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
        didSet { defaults?.set(current.rawValue, forKey: "appTheme") }
    }

    private let defaults = UserDefaults(suiteName: SharedInbox.groupID)

    private init() {
        // CWG_THEME env var lets simulator runs pin a theme for screenshots.
        let stored = ProcessInfo.processInfo.environment["CWG_THEME"]
            ?? defaults?.string(forKey: "appTheme")
        current = stored.flatMap(AppTheme.init(rawValue:)) ?? .midnight
    }
}

// MARK: - Derived palette

/// Every screen sits on a slightly different shade of the theme base, so
/// tabs feel distinct without shouting. The app runs in dark scheme
/// permanently — light text belongs on all three bases.
enum AppBackground {
    static var theme: AppTheme { ThemeStore.shared.current }

    /// The whole palette derives from this — cards and tab shades follow.
    static var base: Color { theme.base }

    /// Control accent for the current theme.
    static var accent: Color { theme.accent }

    /// A touch toward teal, and brighter: out on the town.
    static var places: Color { base.shifted(hue: -0.020, brightness: 0.045) }
    /// A touch toward violet.
    static var library: Color { base.shifted(hue: 0.018, brightness: 0.02) }
    /// Sheets sit slightly deeper than the pages behind them.
    static var sheet: Color {
        theme == .ink ? base.shifted(brightness: 0.03) : base.shifted(brightness: -0.045)
    }

    // MARK: Swipe action fills

    /// Stock green/red swipe buttons clashed with every theme, so all three
    /// derive from the palette. Deepened accent — dark enough that the
    /// system's white label stays readable. Ink's accent is white, so it
    /// gets a charcoal instead.
    static var swipeDone: Color {
        theme == .ink ? Color(white: 0.24) : accent.mix(with: .black, by: 0.4)
    }
    /// Red pulled toward the base: still unmistakably destructive, but
    /// speaking the theme's tone rather than shouting over it.
    static var swipeDelete: Color {
        Color(red: 0.85, green: 0.16, blue: 0.22).mix(with: base, by: 0.4)
    }
    /// A quiet lift off the base for the non-committal "put back".
    static var swipePutBack: Color { base.shifted(brightness: 0.18) }
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

extension View {
    /// Full-bleed tinted backdrop behind a List/ScrollView.
    func appBackground(_ color: Color) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(color.ignoresSafeArea())
    }
}
