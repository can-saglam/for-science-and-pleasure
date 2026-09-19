import SwiftUI

// MARK: - Themes

/// Nine moods, one app. The deep set: the signature midnight blue, a pure
/// black, a dark forest green, a deep wine red. The mid-tones from the
/// print sheet: cobalt, moss, umber. And two papers for daylight — oat
/// and stone. Each theme derives its whole palette — tab shades,
/// sheet depth, control accent — from one base color, so everything
/// stays tuned.
enum AppTheme: String, CaseIterable, Identifiable {
    case midnight
    case cobalt
    case ink
    case forest
    case moss
    case umber
    case wine
    case oat
    case stone

    var id: String { rawValue }

    var name: String {
        switch self {
        case .midnight: "Midnight Blue"
        case .cobalt: "Cobalt"
        case .ink: "Pure Black"
        case .forest: "Forest Green"
        case .moss: "Moss"
        case .umber: "Umber"
        case .wine: "Wine Red"
        case .oat: "Oat"
        case .stone: "Stone"
        }
    }

    /// The papers — oat and stone — are light pages with dark type;
    /// everything else is a dark base.
    var isLight: Bool {
        switch self {
        case .oat, .stone: true
        default: false
        }
    }

    /// Cobalt, moss and umber sit between the deep bases and the papers:
    /// dark enough for light type, light enough that a few mixes need a
    /// gentler hand.
    var isMidTone: Bool {
        switch self {
        case .cobalt, .moss, .umber: true
        default: false
        }
    }

    var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// Logo, titles, and anything that used to be hardcoded white.
    /// Midnight and forest print in the warm cream of the olive
    /// reference; umber in a paler parchment; cobalt and moss in a soft
    /// white; stone flips to near-black, oat to a dark brown; ink and wine
    /// stay white.
    var ink: Color {
        switch self {
        case .stone: Color(hex: "#0D0F0A") ?? .black
        case .oat: Color(hex: "#3E2C14") ?? Color(red: 0.243, green: 0.173, blue: 0.078)
        case .midnight, .forest: Self.forestCream
        case .umber: Color(hex: "#EFEED2") ?? Self.forestCream
        case .cobalt, .moss: Color(hex: "#FAF8F0") ?? .white
        default: .white
        }
    }

    /// The color everything else is mixed from.
    var base: Color {
        switch self {
        case .midnight:
            (Color(hex: "#0C169D") ?? Color(red: 0.047, green: 0.086, blue: 0.616))
                .shifted(brightness: -0.12)
        case .cobalt:
            Color(hex: "#365AA8") ?? Color(red: 0.212, green: 0.353, blue: 0.659)
        case .ink:
            .black
        case .forest:
            Color(hex: "#323316") ?? Color(red: 0.196, green: 0.200, blue: 0.086)
        case .moss:
            Color(hex: "#465A37") ?? Color(red: 0.275, green: 0.353, blue: 0.216)
        case .umber:
            Color(hex: "#564A30") ?? Color(red: 0.337, green: 0.290, blue: 0.188)
        case .wine:
            Color(hex: "#440015") ?? Color(red: 0.267, green: 0, blue: 0.082)
        case .oat:
            Color(hex: "#E3DDCF") ?? Color(red: 0.890, green: 0.867, blue: 0.812)
        case .stone:
            Color(hex: "#C8CBC4") ?? Color(red: 0.784, green: 0.796, blue: 0.769)
        }
    }

    /// Sampled from the olive print — the running figure and the “GO”.
    static let forestCream = Color(hex: "#F6E2B6") ?? Color(red: 0.965, green: 0.886, blue: 0.714)

    /// The matching alternate home-screen icon; nil means the primary
    /// (midnight blue) icon.
    var iconName: String? {
        switch self {
        case .midnight: nil
        case .cobalt: "AppIconCobalt"
        case .ink: "AppIconInk"
        case .forest: "AppIconForest"
        case .moss: "AppIconMoss"
        case .umber: "AppIconUmber"
        case .wine: "AppIconWine"
        case .oat: "AppIconOat"
        case .stone: "AppIconStone"
        }
    }

    /// A small copy of the home-screen icon as a plain image asset, for
    /// showing the icon inside the app (icon sets can't be loaded).
    var iconPreviewName: String {
        switch self {
        case .midnight: "IconPreviewMidnight"
        case .cobalt: "IconPreviewCobalt"
        case .ink: "IconPreviewInk"
        case .forest: "IconPreviewForest"
        case .moss: "IconPreviewMoss"
        case .umber: "IconPreviewUmber"
        case .wine: "IconPreviewWine"
        case .oat: "IconPreviewOat"
        case .stone: "IconPreviewStone"
        }
    }

    /// Tint for controls: toolbar buttons, the selected tab, links.
    /// Papers use their ink; the mid-tones lift a pale wash of their own
    /// hue, like midnight's periwinkle; umber uses its parchment ink.
    var accent: Color {
        switch self {
        case .midnight: Color(hex: "#97A4FF") ?? .white
        case .cobalt: Color(hex: "#D3DEFF") ?? .white
        case .ink: .white
        case .forest: Self.forestCream
        case .moss: Color(hex: "#DCE8C8") ?? .white
        case .umber, .oat, .stone: ink
        case .wine: Color(hex: "#FFA2B8") ?? .white
        }
    }

    /// Accents that are just the theme's ink or a near-white — nothing
    /// to deepen into a swipe fill.
    var accentIsNeutral: Bool {
        switch self {
        case .ink, .forest, .umber, .oat, .stone: true
        default: false
        }
    }

    /// How much of an item's color soaks into its card. Pure black needs a
    /// slightly stronger pour to keep cards from going murky; the papers
    /// want a whisper so they still read as paper; the mid-tones already
    /// carry colour, so a little less.
    var cardAccentMix: Double {
        switch self {
        case .ink: 0.30
        case .oat, .stone: 0.16
        case .cobalt, .moss, .umber: 0.28
        default: 0.34
        }
    }

    /// The lift that separates a card from the page behind it. Dark
    /// themes mix in their ink (white, or forest's cream); the papers mix
    /// in black so cards sit *on* the page instead of bleaching out.
    var cardLiftColor: Color { isLight ? .black : ink }

    var cardLiftAmount: Double {
        switch self {
        case .ink: 0.07
        case .oat, .stone: 0.05
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
            guard persistChanges else { return }
            persist(current)
        }
    }

    /// `preferredColorScheme` / window traits. Updated only when a
    /// choice is committed, so scrubbing the onboarding carousel can
    /// repaint SwiftUI colours without a UIKit trait rebuild mid-gesture.
    private(set) var scheme: AppTheme

    /// When false, `current` is a live preview only — no disk, widgets,
    /// or window-style flip. The onboarding slider uses this so a swipe
    /// does not stall on `WidgetCenter.reloadAllTimelines`.
    private var persistChanges = true

    private func persist(_ theme: AppTheme) {
        defaults?.set(theme.rawValue, forKey: "appTheme")
        scheme = theme
        applyInterfaceStyle()
        #if !APP_EXTENSION
        WidgetStore.writeTheme(theme)
        #endif
    }

    /// Paint `theme` without the persist side-effects. Call `commit()`
    /// when the gesture settles.
    func preview(_ theme: AppTheme) {
        guard theme != current else { return }
        persistChanges = false
        current = theme
        persistChanges = true
    }

    /// Write whatever `preview` left unsaved. No-op if traits already
    /// match the live theme.
    func commit() {
        guard scheme != current else { return }
        persist(current)
    }

    private let defaults = UserDefaults(suiteName: SharedInbox.groupID)

    private init() {
        // CWG_THEME env var lets simulator runs pin a theme for screenshots.
        let stored = ProcessInfo.processInfo.environment["CWG_THEME"]
            ?? defaults?.string(forKey: "appTheme")
        // "cream" was retired; the nearest paper stands in for anyone who had it.
        let initial = stored.flatMap(AppTheme.init(rawValue:))
            ?? (stored == "cream" ? .oat : .midnight)
        current = initial
        scheme = initial
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
    /// SwiftUI's `preferredColorScheme`. The papers are light; everything else
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

    /// Flips the home-screen icon to match the theme. Safe to call often:
    /// it does nothing when the icon already matches, and the system
    /// refuses the change while the app isn't active, so callers run it
    /// at moments the app is (a picker change, a sheet closing, onboarding
    /// finishing).
    func syncAppIcon() {
        #if !APP_EXTENSION
        let wanted = current.iconName
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != wanted
        else { return }
        UIApplication.shared.setAlternateIconName(wanted)
        #endif
    }

    /// Has a theme ever been chosen on this device? False on a fresh
    /// install, when the first run picks one from the system appearance.
    var hasStoredChoice: Bool { defaults?.string(forKey: "appTheme") != nil }

    /// The home-screen icon swap raises a system alert whenever the app is
    /// in the foreground. The first run ends on the library, not on that
    /// alert: it books the swap and `RootGate` performs it the next time
    /// the app goes to the background, where iOS changes the icon quietly.
    func deferIconSync() {
        defaults?.set(true, forKey: "iconSyncPending")
    }

    func syncAppIconIfPending() {
        guard defaults?.bool(forKey: "iconSyncPending") == true else { return }
        defaults?.removeObject(forKey: "iconSyncPending")
        syncAppIcon()
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
/// the papers flip the ink dark.
enum AppBackground {
    static var theme: AppTheme { ThemeStore.shared.current }

    /// The whole palette derives from this — cards and tab shades follow.
    static var base: Color { theme.base }

    /// Control accent for the current theme.
    static var accent: Color { theme.accent }

    /// Logo and primary marks — cream on midnight and forest, dark on the papers, white elsewhere.
    static var ink: Color { theme.ink }

    /// Label on a white (or near-white) prominent glass pill.
    /// The papers print their ink; dark themes print the page colour.
    static var onProminent: Color { theme.isLight ? ink : base }

    /// The small icon squircle on settings rows. Always a light badge with
    /// a dark glyph — accent on the dark themes, white on the papers — so a
    /// theme switch never inverts it: a cross-fade through an inversion
    /// passes a frame where badge and glyph are the same grey.
    static var badge: Color { theme.isLight ? .white : accent }
    static var badgeGlyph: Color { theme.isLight ? ink : base }

    /// Warnings, error notes, duplicate notices. System orange reads on the
    /// dark pages but sits at ~1.5:1 on the papers, so they deepen it to
    /// a burnt orange; on umber's brown it goes paler to stay distinct.
    static var warning: Color {
        if theme.isLight { return Color(red: 0.62, green: 0.32, blue: 0) }
        if theme == .umber { return Color(red: 1.0, green: 0.72, blue: 0.36) }
        return .orange
    }

    /// Destructive rows and urgent copy. Deeper on the papers (system red
    /// is under 3:1 there); on wine, system red melts into the page, so it
    /// lifts toward the theme's pink; the mid-tones lift it a touch too,
    /// so it stays legible against a coloured page.
    static var destructive: Color {
        if theme.isLight { return Color(red: 0.72, green: 0.10, blue: 0.14) }
        if theme == .wine { return Color(red: 1.0, green: 0.47, blue: 0.53) }
        if theme.isMidTone { return Color(red: 1.0, green: 0.55, blue: 0.55) }
        return .red
    }

    /// A hairline wash for inset rows and fields. White on dark pages,
    /// dark on the papers, so the same 8% still reads as a recess.
    static func wash(_ opacity: Double) -> Color {
        ink.opacity(opacity)
    }

    /// A touch toward teal, and brighter: out on the town. The papers keep
    /// their pages on the one shade the drawers use — the tab tints read
    /// as dirt on a light page.
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
    /// system's white label stays readable. Themes whose accent is just
    /// their ink (or black, on the papers) use charcoal instead.
    static var swipeDone: Color {
        theme.accentIsNeutral
            ? Color(white: 0.24)
            : accent.mix(with: .black, by: 0.4)
    }
    /// Red pulled toward the base: still unmistakably destructive, but
    /// speaking the theme's tone rather than shouting over it. The
    /// mid-tones take less base so the red doesn't go muddy.
    static var swipeDelete: Color {
        let pull = theme.isLight ? 0.15 : (theme.isMidTone ? 0.25 : 0.4)
        return Color(red: 0.85, green: 0.16, blue: 0.22).mix(with: base, by: pull)
    }
    /// A quiet lift off the base for the non-committal "put back". The
    /// system draws swipe labels white, so the papers use a mid grey
    /// rather than a darker paper that would leave white type at 1.4:1;
    /// the mid-tones lift less, since they start brighter.
    static var swipePutBack: Color {
        if theme.isLight { return Color(white: 0.45) }
        return base.shifted(brightness: theme.isMidTone ? 0.10 : 0.18)
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

    /// Light text on the dark bases, dark on the papers. Midnight and forest
    /// also paint primary type in the warm cream ink.
    func appColorScheme() -> some View {
        modifier(AppColorSchemeModifier())
    }

    /// White glass pill, dark-enough label — the papers get dark type.
    /// Disabled, the pill drops to a wash of the page and the label goes
    /// to dimmed ink: the system's own greying kept the page-coloured
    /// label, which vanished into the grey pill on every dark theme.
    func prominentGlass() -> some View {
        modifier(ProminentGlassModifier())
    }
}

private struct ProminentGlassModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(.glassProminent)
            .tint(isEnabled ? Color.white : AppBackground.wash(0.10))
            .foregroundStyle(isEnabled ? AppBackground.onProminent : AppBackground.ink.opacity(0.5))
    }
}

/// Observes the theme so flipping paper ↔ dark actually updates the
/// window. Does not also push `environment(\.colorScheme)` — that loops
/// with `preferredColorScheme` and crashes AttributeGraph.
private struct AppColorSchemeModifier: ViewModifier {
    @State private var themes = ThemeStore.shared

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(themes.scheme.colorScheme)
            .foregroundStyle(themes.current.ink)
    }
}
