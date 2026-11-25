import SwiftUI

// MARK: - Themes

/// Fourteen moods, one app. The deep set: the signature midnight blue, a
/// pure black and its softer graphite, a petrol teal, a dark olive, a deep
/// wine red, a plum. The mid-tones from the print sheet: cobalt, moss,
/// terracotta. And four papers for daylight — oat, stone, blush and a
/// near-white chalk. Each theme derives its whole palette — tab shades,
/// sheet depth, card lift — from one base color, so everything stays
/// tuned. Declared in picker order.
enum AppTheme: String, CaseIterable, Identifiable {
    case midnight
    case ink
    case graphite
    case petrol
    /// Named Olive: the colour is an olive, and moss is the green. The raw
    /// value stays, since it is what people's phones have saved.
    case forest
    case wine
    case plum
    case cobalt
    case moss
    case terracotta
    case oat
    case stone
    case blush
    case chalk

    var id: String { rawValue }

    var name: String {
        switch self {
        case .midnight: "Midnight Blue"
        case .cobalt: "Cobalt"
        case .ink: "Pure Black"
        case .graphite: "Graphite"
        case .petrol: "Petrol"
        case .forest: "Olive"
        case .plum: "Plum"
        case .chalk: "Chalk"
        case .moss: "Moss"
        case .terracotta: "Terracotta"
        case .wine: "Wine Red"
        case .oat: "Oat"
        case .stone: "Stone"
        case .blush: "Blush"
        }
    }

    /// The papers — oat, stone, blush and chalk — are light pages with
    /// dark type; everything else is a dark base.
    var isLight: Bool {
        switch self {
        case .oat, .stone, .blush, .chalk: true
        default: false
        }
    }

    /// Cobalt, moss and terracotta sit between the deep bases and the
    /// papers: dark enough for light type, light enough that a few mixes
    /// need a gentler hand.
    var isMidTone: Bool {
        switch self {
        case .cobalt, .moss, .terracotta: true
        default: false
        }
    }

    var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// Logo, titles, and anything that used to be hardcoded white.
    /// Midnight, petrol and forest print in the warm cream of the olive
    /// reference; terracotta in a warmer shell; cobalt and moss in a soft
    /// white; graphite in a warm one; stone and chalk flip to near-black,
    /// oat to a dark brown, blush to a deep maroon; ink, wine and plum
    /// stay white.
    var ink: Color {
        switch self {
        case .stone: Color(hex: "#0D0F0A") ?? .black
        case .chalk: Color(hex: "#16171A") ?? .black
        case .graphite: Color(hex: "#F4F1EA") ?? .white
        case .oat: Color(hex: "#3E2C14") ?? Color(red: 0.243, green: 0.173, blue: 0.078)
        case .blush: Color(hex: "#43201D") ?? Color(red: 0.263, green: 0.125, blue: 0.114)
        case .midnight, .petrol, .forest: Self.forestCream
        case .terracotta: Color(hex: "#FBEFE3") ?? .white
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
        case .graphite:
            Color(hex: "#1F2023") ?? Color(red: 0.122, green: 0.125, blue: 0.137)
        case .plum:
            Color(hex: "#2E1437") ?? Color(red: 0.180, green: 0.078, blue: 0.216)
        case .chalk:
            Color(hex: "#F4F3EF") ?? Color(red: 0.957, green: 0.953, blue: 0.937)
        case .petrol:
            Color(hex: "#0F4C4F") ?? Color(red: 0.059, green: 0.298, blue: 0.310)
        case .forest:
            Color(hex: "#323316") ?? Color(red: 0.196, green: 0.200, blue: 0.086)
        case .moss:
            Color(hex: "#465A37") ?? Color(red: 0.275, green: 0.353, blue: 0.216)
        case .terracotta:
            Color(hex: "#7C3520") ?? Color(red: 0.486, green: 0.208, blue: 0.125)
        case .wine:
            Color(hex: "#440015") ?? Color(red: 0.267, green: 0, blue: 0.082)
        case .oat:
            Color(hex: "#E3DDCF") ?? Color(red: 0.890, green: 0.867, blue: 0.812)
        case .stone:
            Color(hex: "#D9DCD6") ?? Color(red: 0.851, green: 0.863, blue: 0.839)
        case .blush:
            Color(hex: "#EBDAD3") ?? Color(red: 0.922, green: 0.855, blue: 0.827)
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
        case .graphite: "AppIconGraphite"
        case .plum: "AppIconPlum"
        case .chalk: "AppIconChalk"
        case .petrol: "AppIconPetrol"
        case .forest: "AppIconForest"
        case .moss: "AppIconMoss"
        case .terracotta: "AppIconTerracotta"
        case .wine: "AppIconWine"
        case .oat: "AppIconOat"
        case .stone: "AppIconStone"
        case .blush: "AppIconBlush"
        }
    }

    /// A small copy of the home-screen icon as a plain image asset, for
    /// showing the icon inside the app (icon sets can't be loaded).
    var iconPreviewName: String {
        switch self {
        case .midnight: "IconPreviewMidnight"
        case .cobalt: "IconPreviewCobalt"
        case .ink: "IconPreviewInk"
        case .graphite: "IconPreviewGraphite"
        case .plum: "IconPreviewPlum"
        case .chalk: "IconPreviewChalk"
        case .petrol: "IconPreviewPetrol"
        case .forest: "IconPreviewForest"
        case .moss: "IconPreviewMoss"
        case .terracotta: "IconPreviewTerracotta"
        case .wine: "IconPreviewWine"
        case .oat: "IconPreviewOat"
        case .stone: "IconPreviewStone"
        case .blush: "IconPreviewBlush"
        }
    }

    /// Tint for controls: toolbar buttons, the selected tab, links. The
    /// mid-tones and petrol lift a pale wash of their own hue, like
    /// midnight's periwinkle. Each paper has a deep colour of its own — a
    /// rust, a pine, a rose, and the signature blue on chalk — dark enough
    /// to hold 4.5:1 on its page.
    var accent: Color {
        switch self {
        case .midnight: Color(hex: "#97A4FF") ?? .white
        case .cobalt: Color(hex: "#D3DEFF") ?? .white
        case .ink: .white
        case .graphite: ink
        case .plum: Color(hex: "#E0B8FF") ?? .white
        case .oat: Color(hex: "#9A3F16") ?? ink
        case .stone: Color(hex: "#2B5A45") ?? ink
        case .blush: Color(hex: "#96334A") ?? ink
        case .chalk: Color(hex: "#0C169D") ?? ink
        case .petrol: Color(hex: "#9EE3DA") ?? .white
        case .forest: Self.forestCream
        case .moss: Color(hex: "#DCE8C8") ?? .white
        case .terracotta: Color(hex: "#FFD3BF") ?? .white
        case .wine: Color(hex: "#FFA2B8") ?? .white
        }
    }

    /// Accents that are just the theme's ink or a near-white — nothing
    /// to deepen into a swipe fill.
    var accentIsNeutral: Bool {
        switch self {
        case .ink, .graphite, .forest: true
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
        case .oat, .stone, .blush, .chalk: 0.16
        case .cobalt, .moss, .terracotta: 0.28
        default: 0.34
        }
    }

    /// How much of the ink quiet type keeps: dates, venues, counts. Each
    /// is the least that holds 4.5:1 on every page shade of its theme; a
    /// card whose save colour would fall short darkens instead
    /// (`AppBackground.readable`).
    var secondaryStrength: Double {
        switch self {
        case .cobalt: 0.90
        case .moss: 0.85
        case .petrol: 0.80
        case .oat, .stone, .blush, .chalk: 0.78
        case .terracotta: 0.75
        default: 0.70
        }
    }

    /// The lift that separates a card from the page behind it. Dark
    /// themes mix in their ink (white, or forest's cream). The papers go
    /// toward white, well past the page: a lighter sheet laid on it, the
    /// way their chips and buttons already sit. (A shade darker read as
    /// muddy, most of all on stone.)
    var cardLiftColor: Color { isLight ? .white : ink }

    var cardLiftAmount: Double {
        switch self {
        case .ink: 0.07
        case .oat, .stone, .blush, .chalk: 0.45
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

    /// Increase Contrast: quiet type goes to full ink and cards aim higher.
    private(set) var highContrast = UIAccessibility.isDarkerSystemColorsEnabled

    /// On, the theme follows the phone: `day` in Light mode, `night` in
    /// Dark. `current` is still whichever is on screen.
    private(set) var followsSystem: Bool
    private(set) var day: AppTheme
    private(set) var night: AppTheme

    /// The phone's own appearance. Not the windows': they carry the
    /// theme's override, so a paper reads as light whatever the phone says.
    private(set) var systemIsDark: Bool

    /// Both themes, for the widget to choose between; nil with one theme.
    var pair: (day: AppTheme, night: AppTheme)? { followsSystem ? (day, night) : nil }

    /// When false, `current` is a live preview only — no disk, widgets,
    /// or window-style flip. The onboarding slider uses this so a swipe
    /// does not stall on `WidgetCenter.reloadAllTimelines`.
    private var persistChanges = true

    private func persist(_ theme: AppTheme) {
        defaults?.set(theme.rawValue, forKey: "appTheme")
        scheme = theme
        applyInterfaceStyle()
        #if !APP_EXTENSION
        WidgetStore.writeTheme(theme, pair: pair)
        #endif
    }

    // MARK: Light and dark

    /// Turning it on moves nothing: the theme in use takes the slot the
    /// phone is in now, and the other keeps its last pick. Off, the theme
    /// on screen simply stays.
    @MainActor
    func setFollowsSystem(_ on: Bool) {
        guard on != followsSystem else { return }
        catchUpWithSystem()
        if on {
            if systemIsDark { night = current } else { day = current }
        }
        followsSystem = on
        savePair()
        writeWidgets()
    }

    /// A pick for Light or Dark mode. Only the one the phone is in now
    /// repaints the app; the other waits for its turn.
    @MainActor
    func pick(_ theme: AppTheme, inDark: Bool) {
        catchUpWithSystem()
        if inDark { night = theme } else { day = theme }
        savePair()
        // `select` tells the widgets itself when it has something to change.
        if inDark == systemIsDark, theme != current { select(theme) } else { writeWidgets() }
    }

    private func savePair() {
        defaults?.set(followsSystem, forKey: "themeFollowsSystem")
        defaults?.set(day.rawValue, forKey: "themeDay")
        defaults?.set(night.rawValue, forKey: "themeNight")
    }

    private func writeWidgets() {
        #if !APP_EXTENSION
        WidgetStore.writeTheme(current, pair: pair)
        #endif
    }

    /// The phone went light or dark, or the app came back to find it had.
    func systemAppearance(isDark: Bool) {
        systemIsDark = isDark
        guard followsSystem else { return }
        select(isDark ? night : day)
    }

    /// Catches up with the phone's appearance. Nothing in the app hears
    /// it change: SwiftUI pins the theme's light or dark on the scene, so
    /// every window's traits are the theme's. The screen sits above that
    /// and still has the phone's own, so the app looks whenever it comes
    /// to the front, and now and then while it stays there.
    @MainActor
    func catchUpWithSystem() {
        #if !APP_EXTENSION
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }
        systemAppearance(isDark: scene.screen.traitCollection.userInterfaceStyle == .dark)
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
        // Retired themes hand over to their nearest: cream to oat, umber to
        // terracotta (saved, and its icon swapped on the next background).
        let single = stored.flatMap(AppTheme.init(rawValue:))
            ?? Self.successor(of: stored)
        // A pair picks by the phone's appearance, which may have changed
        // since the last run. Nothing is on screen yet, so the current
        // traits are still the phone's own.
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let pinned = ProcessInfo.processInfo.environment["CWG_THEME"] != nil
        let follows = !pinned && defaults?.bool(forKey: "themeFollowsSystem") == true
        let day = defaults?.string(forKey: "themeDay").flatMap(AppTheme.init(rawValue:))
            ?? (single.isLight ? single : .oat)
        let night = defaults?.string(forKey: "themeNight").flatMap(AppTheme.init(rawValue:))
            ?? (single.isLight ? .midnight : single)
        let initial = follows ? (dark ? night : day) : single
        current = initial
        scheme = initial
        followsSystem = follows
        self.day = day
        self.night = night
        systemIsDark = dark
        if follows, stored != initial.rawValue {
            defaults?.set(initial.rawValue, forKey: "appTheme")
        }
        if stored == "umber", ProcessInfo.processInfo.environment["CWG_THEME"] == nil {
            defaults?.set(initial.rawValue, forKey: "appTheme")
            defaults?.set(true, forKey: "iconSyncPending")
        }
        // After the singleton is live — doing this inline re-enters
        // `shared` mid-init and traps. `writeTheme` used to read
        // `ThemeStore.shared` from here and crashed launch on device.
        applyInterfaceStyle()
        #if !APP_EXTENSION
        let theme = current
        let pair = pair
        DispatchQueue.main.async {
            WidgetStore.writeTheme(theme, pair: pair)
        }
        #endif
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.highContrast = UIAccessibility.isDarkerSystemColorsEnabled
        }
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

    /// Flips the home-screen icon to match the theme: the Light mode one
    /// when the theme follows the phone, since iOS announces every icon
    /// change with an alert and a pair would raise one twice a day. Safe
    /// to call often:
    /// it does nothing when the icon already matches, and the system
    /// refuses the change while the app isn't active, so callers run it
    /// at moments the app is (a picker change, a sheet closing, onboarding
    /// finishing).
    func syncAppIcon() {
        #if !APP_EXTENSION
        let wanted = (followsSystem ? day : current).iconName
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != wanted
        else { return }
        UIApplication.shared.setAlternateIconName(wanted)
        #endif
    }

    /// The theme pick cross-fades the window. Changing the icon in the
    /// middle of that fade makes iOS lay out its "icon changed" alert
    /// against a window that's still mid-transition, and the icon in
    /// the alert lands with the wrong padding. Wait until the fade is done.
    func syncAppIconWhenSettled() {
        #if !APP_EXTENSION
        iconSyncItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.syncAppIcon()
        }
        iconSyncItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
        #endif
    }

    #if !APP_EXTENSION
    private var iconSyncItem: DispatchWorkItem?
    #endif

    static func successor(of retired: String?) -> AppTheme {
        switch retired {
        case "cream": .oat
        case "umber": .terracotta
        default: .midnight
        }
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

    /// A switch's track when on. The knob is always white, so the dark
    /// themes' pale accents (white itself on ink) would swallow it: they
    /// sink the accent halfway into the page, keeping its hue. The papers'
    /// accents are deep already.
    static var toggleTint: Color { theme.isLight ? accent : accent.mix(with: base, by: 0.45) }

    /// Logo and primary marks — cream on midnight and forest, dark on the papers, white elsewhere.
    static var ink: Color { theme.ink }

    /// Quiet type: dates, notes, legends. The theme's own ink, faded only
    /// as far as small type still reads (4.5:1); the system grey was a cool
    /// blue-grey on warm pages and fell under 3:1 on the mid-tones. Full
    /// ink with Increase Contrast.
    static var secondaryInk: Color {
        ink.opacity(ThemeStore.shared.highContrast ? 1 : theme.secondaryStrength)
    }

    /// A card fill quiet type still reads on. A save colour light enough to
    /// drop `secondaryInk` under 4.5:1 (7:1 with Increase Contrast) moves
    /// toward black, or toward white on the papers, only as far as it takes,
    /// so it keeps its hue.
    static func readable(_ fill: Color) -> Color {
        let high = ThemeStore.shared.highContrast
        let key = ReadableKey(fill: fill, theme: theme, high: high)
        readableLock.lock()
        defer { readableLock.unlock() }
        if let hit = readableCache[key] { return hit }

        let target = high ? 7.1 : 4.6
        let strength = high ? 1 : theme.secondaryStrength
        let toward: Color = theme.isLight ? .white : .black
        let reads = { (card: Color) in Contrast.ratio(ink, opacity: strength, over: card) >= target }
        var result = fill
        if !reads(fill) {
            var short = 0.0, enough = 1.0
            for _ in 0..<10 {
                let mid = (short + enough) / 2
                if reads(fill.mix(with: toward, by: mid)) { enough = mid } else { short = mid }
            }
            result = fill.mix(with: toward, by: enough)
        }
        readableCache[key] = result
        return result
    }

    private struct ReadableKey: Hashable {
        let fill: Color
        let theme: AppTheme
        let high: Bool
    }
    private static var readableCache: [ReadableKey: Color] = [:]
    private static let readableLock = NSLock()

    /// Placeholder ink. The system grey disappears into the paper themes.
    static func fieldPrompt(_ title: String) -> Text {
        Text(title).foregroundStyle(ink.opacity(0.72))
    }

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
    /// a burnt orange; on terracotta's orange-red it goes paler to stay
    /// distinct.
    static var warning: Color {
        if theme.isLight { return Color(red: 0.62, green: 0.32, blue: 0) }
        if theme == .terracotta { return Color(red: 1.0, green: 0.82, blue: 0.50) }
        return .orange
    }

    /// Destructive rows and urgent copy. Deeper on the papers (system red
    /// is under 3:1 there); on wine, system red melts into the page, so it
    /// lifts toward the theme's pink; terracotta is itself a red, so it
    /// goes paler still; the other mid-tones lift it a touch, so it stays
    /// legible against a coloured page.
    static var destructive: Color {
        if theme.isLight { return Color(red: 0.72, green: 0.10, blue: 0.14) }
        if theme == .wine { return Color(red: 1.0, green: 0.47, blue: 0.53) }
        if theme == .terracotta { return Color(red: 1.0, green: 0.74, blue: 0.72) }
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
    /// as dirt on a light page. The mid-tones skip the brightening: their
    /// ink only just holds 4.5:1 on the base as it is.
    static var places: Color {
        if theme.isLight { return sheet }
        return base.shifted(hue: -0.020, brightness: theme.isMidTone ? 0 : 0.045)
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
    /// their ink use charcoal instead.
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

/// WCAG 2 contrast, for colours the palette mixes at run time.
enum Contrast {
    /// `ink` at `opacity` laid over an opaque `background`.
    static func ratio(_ ink: Color, opacity: Double, over background: Color) -> Double {
        let env = EnvironmentValues()
        let fg = ink.resolve(in: env), bg = background.resolve(in: env)
        let a = Float(opacity) * fg.opacity
        func blend(_ f: Float, _ b: Float) -> Float { f * a + b * (1 - a) }
        let top = luminance(blend(fg.red, bg.red), blend(fg.green, bg.green), blend(fg.blue, bg.blue))
        let bottom = luminance(bg.red, bg.green, bg.blue)
        return (max(top, bottom) + 0.05) / (min(top, bottom) + 0.05)
    }

    private static func luminance(_ r: Float, _ g: Float, _ b: Float) -> Double {
        func linear(_ c: Float) -> Double {
            let c = Double(min(max(c, 0), 1))
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
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

    /// Solid destructive pill. Plain `.glass` on a delete action renders
    /// the label in the placeholder grey, which reads as a dead control.
    func destructiveGlass() -> some View {
        modifier(DestructiveGlassModifier())
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

private struct DestructiveGlassModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(.glassProminent)
            .tint(isEnabled ? AppBackground.destructive : AppBackground.wash(0.10))
            .foregroundStyle(isEnabled ? Color.white : AppBackground.ink.opacity(0.5))
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
