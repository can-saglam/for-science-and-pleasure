import AuthenticationServices
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UserNotifications

/// A save as the notifications page shows it: one of theirs from the step
/// before, an event on in their city, or Salman Toor at the Courtauld
/// (photo bundled, hours known).
struct ShowcaseSave {
    var title: String
    var place: String?
    var photoURL: URL?
    var bundledPhoto: String?
    var colorHex: String?
    var hours: String?
    /// The reminder's body, worded as `reminderBody` words it.
    var reminder = "Closes in a week"

    static let toor = ShowcaseSave(
        title: "Salman Toor: Someone Like You",
        place: "Courtauld Gallery \u{00B7} Strand",
        bundledPhoto: "SampleToor",
        colorHex: "#055032",
        hours: "Open until 18:00"
    )

    init(title: String, place: String?, photoURL: URL? = nil, bundledPhoto: String? = nil,
         colorHex: String?, hours: String? = nil) {
        self.title = title
        self.place = place
        self.photoURL = photoURL
        self.bundledPhoto = bundledPhoto
        self.colorHex = colorHex
        self.hours = hours
    }

    init(_ item: Item) {
        let place = [item.venue, item.area]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != item.title }
        self.init(
            title: item.title,
            place: place.isEmpty ? nil : place.joined(separator: " \u{00B7} "),
            photoURL: item.imageUrl.flatMap(URL.init(string:)),
            colorHex: item.colorHex
        )
        reminder = Self.reminder(startsOn: item.startsOn, endsOn: item.endsOn)
    }

    /// One of the city's events they were offered; only the notification
    /// shows it, which needs no photo.
    init(_ pick: ParseClient.Suggestion) {
        self.init(title: pick.title, place: pick.venue, colorHex: nil)
        reminder = Self.reminder(startsOn: pick.startsOn, endsOn: pick.endsOn)
    }

    /// A week ahead, or sooner when it's sooner. A run that hasn't started
    /// is reminded of its opening, one that has of its closing; a one-day
    /// event of the day.
    private static func reminder(startsOn: String?, endsOn: String?) -> String {
        let today = DayString.dayNumber(DayString.today()) ?? 0
        let days = { (day: String?) in day.flatMap(DayString.dayNumber).map { $0 - today } }
        let runs = endsOn != nil && endsOn != startsOn
        let opens = days(startsOn).map { $0 > 0 } ?? false
        guard let left = runs && !opens ? days(endsOn) : days(startsOn ?? endsOn) else {
            return "Closes in a week"
        }
        let when = left >= 7 ? "in a week" : left >= 3 ? "in 3 days" : left >= 1 ? "tomorrow" : "today"
        if runs { return opens ? "Opens \(when)" : (when == "today" ? "Last day" : "Closes \(when)") }
        return when == "today" ? "Today" : "\(when.prefix(1).uppercased())\(when.dropFirst())"
    }
}

/// The bottom of an iPhone 18 Pro on its Lock Screen, rising out of the
/// page: the day-of Live Activity and the reminder take turns over the
/// torch and camera buttons and the home bar. Laid out at the phone's own
/// size and scaled to the page's width; the top fades into the page, and
/// the page's title sits over the fade. With reduced motion the two sit
/// one above the other. The Live Activity is drawn the way
/// `DayActivityView` draws it.
struct PlanRemindStack: View {
    let plan: ShowcaseSave
    let remind: ShowcaseSave
    let icon: String
    let isLight: Bool
    let still: Bool
    @State private var photo: UIImage?
    @State private var shown = false
    @State private var showsPlan = true

    /// 18 Pro: a 402-point-wide screen in a thin black border and a
    /// metal band.
    private static let screenWidth: CGFloat = 402
    private static let border: CGFloat = 8
    private static let band: CGFloat = 4
    private static var width: CGFloat { screenWidth + (border + band) * 2 }
    /// How much of the phone shows, from the bottom edge up.
    private static let shownHeight: CGFloat = 420

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / Self.width
            phone
                .frame(width: Self.width, height: Self.shownHeight, alignment: .bottom)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .aspectRatio(Self.width / Self.shownHeight, contentMode: .fit)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.18),
                    .init(color: .black.opacity(0.03), location: 0.23),
                    .init(color: .black.opacity(0.12), location: 0.28),
                    .init(color: .black.opacity(0.32), location: 0.33),
                    .init(color: .black.opacity(0.62), location: 0.38),
                    .init(color: .black.opacity(0.88), location: 0.43),
                    .init(color: .black, location: 0.48),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A Lock Screen. A Live Activity: \(plan.title), going at 14:00. A notification: \(remind.title), \(remind.reminder).")
        .task(id: plan.photoURL) {
            guard let url = plan.photoURL else { return }
            photo = await ImageStore.fetch(url)
        }
        .task {
            guard !still else { return }
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.smooth(duration: 0.6)) { shown = true }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.2))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.6)) { showsPlan.toggle() }
            }
        }
    }

    /// Only the bottom corners are rounded: the rest runs off the top.
    private var phone: some View {
        let outer = UnevenRoundedRectangle(bottomLeadingRadius: 66, bottomTrailingRadius: 66, style: .continuous)
        let inner = UnevenRoundedRectangle(bottomLeadingRadius: 62, bottomTrailingRadius: 62, style: .continuous)
        let screen = UnevenRoundedRectangle(bottomLeadingRadius: 54, bottomTrailingRadius: 54, style: .continuous)
        return ZStack(alignment: .trailing) {
            outer.fill(LinearGradient(
                colors: [Color(white: 0.78), Color(white: 0.52), Color(white: 0.7)],
                startPoint: .leading, endPoint: .trailing
            ))
            inner.fill(.black).padding([.horizontal, .bottom], Self.band)
            lockScreen
                .clipShape(screen)
                .padding([.horizontal, .bottom], Self.band + Self.border)
            // The Camera Control, low on the right side.
            Capsule()
                .fill(Color(white: 0.6))
                .frame(width: 3, height: 64)
                .offset(x: 2)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 70)
        }
    }

    private var lockScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // One at a time, in turn, sitting on the same bottom line.
            ZStack(alignment: .bottom) {
                if still {
                    VStack(spacing: 8) {
                        liveActivity
                        notification
                    }
                } else if shown {
                    if showsPlan {
                        liveActivity
                            .transition(.blurReplace.combined(with: .scale(0.97, anchor: .bottom)))
                    } else {
                        notification
                            .transition(.blurReplace.combined(with: .scale(0.97, anchor: .bottom)))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: still ? nil : 124, alignment: .bottom)
            .padding(.horizontal, 12)
            .padding(.bottom, 26)

            HStack {
                lockButton("flashlight.off.fill", size: 19)
                Spacer()
                lockButton("camera.fill", size: 18)
            }
            .padding(.horizontal, 46)
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: 140, height: 5)
                .padding(.top, 22)
                .padding(.bottom, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(
            stops: [
                .init(color: wallpaper(0), location: 0.2),
                .init(color: wallpaper(0.5), location: 0.5),
                .init(color: wallpaper(1), location: 0.9),
            ],
            startPoint: .top, endPoint: .bottom
        ))
        .environment(\.colorScheme, .dark)
    }

    /// The wallpaper, a deeper shade of the theme from top (0) to bottom
    /// (1). The papers deepen into their own ink so they don't go grey;
    /// Pure Black lifts to charcoal so the screen still reads as a screen.
    private func wallpaper(_ depth: Double) -> Color {
        let base = AppBackground.base
        if AppBackground.theme == .ink {
            return Color(white: 0.16 - 0.08 * depth)
        }
        if isLight {
            return base.mix(with: AppBackground.ink, by: 0.5 + 0.28 * depth)
        }
        return base.mix(with: .black, by: 0.12 + 0.36 * depth)
    }

    private func lockButton(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 50, height: 50)
            .glassEffect(.regular, in: .circle)
    }

    // MARK: Notification

    private var notification: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon sets can't be loaded as images, so a small copy of each
            // ships as a regular asset (IconPreview*).
            Image(icon)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(.rect(cornerRadius: 8.5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(remind.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("now").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Text(remind.reminder)
                    .font(.subheadline)
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    // MARK: Live Activity

    private var accent: Color {
        plan.colorHex.flatMap { Color(hex: $0) } ?? Color(red: 0.55, green: 0.5, blue: 0.4)
    }

    /// `DayLook.card`: the theme's paper folded toward the save's colour.
    private var card: Color {
        AppBackground.base
            .mix(with: accent, by: isLight ? 0.16 : 0.32)
            .mix(with: isLight ? .black : AppBackground.ink, by: isLight ? 0.05 : 0.06)
    }

    private var ink: Color { AppBackground.ink }

    private var image: Image? {
        if let photo { return Image(uiImage: photo) }
        return plan.bundledPhoto.map { Image($0) }
    }

    private var liveActivity: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(plan.title)
                .font(.displaySmall(24, relativeTo: .title3))
                .foregroundStyle(ink)
                .lineLimit(2)
            if let place = plan.place {
                Text(place)
                    .font(.subheadline)
                    .foregroundStyle(ink.opacity(0.65))
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text("Going at 14:00")
                if let hours = plan.hours { Text(hours) }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(ink.opacity(0.65))
            .lineLimit(1)
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .padding(.trailing, image == nil ? 0 : 84)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .trailing) {
            if let image {
                ActivityMelt(photo: image, card: card, ink: ink, isLight: isLight)
            }
        }
        .background(card)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(isLight ? 0.08 : 0.25), radius: 12, y: 6)
    }
}

/// The Live Activity's photo melt (the widget's `Melt`): a multiply pass
/// pulling the photo toward the card colour and an eased wash of the card
/// on top, the strip fading in from the left.
struct ActivityMelt: View {
    let photo: Image
    let card: Color
    let ink: Color
    let isLight: Bool

    var body: some View {
        ZStack {
            photo
                .resizable()
                .scaledToFill()
                .frame(width: 150)
                .clipped()
            LinearGradient(
                stops: [
                    .init(color: card, location: 0),
                    .init(color: card.mix(with: ink, by: isLight ? 0.06 : 0.5), location: 0.45),
                    .init(color: isLight ? card : .white, location: 0.95),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .blendMode(.multiply)
            LinearGradient(
                stops: [
                    .init(color: card, location: 0),
                    .init(color: card.opacity(0.95), location: 0.15),
                    .init(color: card.opacity(0.75), location: 0.3),
                    .init(color: card.opacity(0.45), location: 0.45),
                    .init(color: card.opacity(0.18), location: 0.6),
                    .init(color: card.opacity(0.05), location: 0.75),
                    .init(color: card.opacity(0), location: 0.9),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .compositingGroup()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.15),
                    .init(color: .black.opacity(0.12), location: 0.3),
                    .init(color: .black.opacity(0.4), location: 0.45),
                    .init(color: .black.opacity(0.75), location: 0.62),
                    .init(color: .black, location: 0.8),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .clipped()
    }
}

/// Each page's slot for the welcome cards, by page: while two pages
/// cross-fade, the cards follow the one being turned to.
struct DeckSlotKey: PreferenceKey {
    static let defaultValue: [OnboardingView.Page: Anchor<CGRect>] = [:]
    static func reduce(value: inout [OnboardingView.Page: Anchor<CGRect>], nextValue: () -> [OnboardingView.Page: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A sideways strip runs to the display's edges on a phone. In the open
/// Duo's centred column it ends at the column's, top and bottom left
/// loose for the chips' outlines and shadows.
struct ColumnClip: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.mask { Rectangle().padding(.vertical, -20) }
        } else {
            content
        }
    }
}
