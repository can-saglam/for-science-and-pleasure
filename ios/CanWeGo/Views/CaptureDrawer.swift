import SwiftUI

/// What the parser was sent, for the drawer's first status line.
enum CaptureInput {
    case link, text, image

    init(text: String?, hasImage: Bool) {
        if hasImage {
            self = .image
        } else if let text, LinkPeek.firstURL(in: text) != nil {
            self = .link
        } else {
            self = .text
        }
    }
}

/// The wait for the parser, spent building the card in front of you: the
/// drawer's header (photo edge to edge, title, the quiet lines under it)
/// fills in piece by piece — the phone's link preview and on-device guess
/// first, then the parser's fields confirming or correcting them, then its
/// finished card with the photo and the map — and once the card is in, the
/// same drawer is the "Looks right?" preview, with the actions unfolding
/// below. Shared with the share extension.
struct CaptureDrawer<Actions: View>: View {
    /// The parser's card; nil while it's still reading.
    let draft: Item?
    /// The parser's fields while its lookups finish: no photo, map or
    /// colour yet.
    var early: Item? = nil
    /// The on-device model's quick guess.
    var look: Item? = nil
    var peek: LinkPeek? = nil
    let input: CaptureInput
    /// Off in the share extension, where a live map is too much memory.
    var showsMap = true
    /// Opens the form, for a gap the parser left ("No date on the page").
    var editFirst: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    @State private var choosingPhoto = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// What the parser has said so far.
    private var fields: Item? { draft ?? early }

    private var title: String? {
        let raw = fields?.title ?? peek?.title ?? look?.title
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? raw : nil
    }

    private var photoURL: URL? { draft?.imageUrl.flatMap(URL.init(string:)) }

    /// While it's reading there's always room for a photo — a placeholder
    /// until one turns up. A card that came back without one folds it away.
    private var showsPhoto: Bool { draft == nil || photoURL != nil }

    private var settle: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
    }

    /// Fields that land together settle one after another, top to bottom.
    private func arrival(_ order: Int) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: settle.animation(.spring(duration: 0.45).delay(Double(order) * 0.07)),
            removal: .opacity
        )
    }

    /// The card's own additions — photo credit, gaps, map — follow the
    /// fields when they all land at once, and come straight in after them.
    private func finishing(_ order: Int) -> AnyTransition {
        arrival(early == nil ? order : order - 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsPhoto {
                HeroPhoto(
                    url: photoURL,
                    image: peek?.image,
                    placeholder: draft?.accentColor ?? AppBackground.ink.opacity(0.4)
                )
                .overlay {
                    if draft == nil, peek?.image == nil {
                        Shimmer(highlight: AppBackground.ink.opacity(0.07)).clipped()
                    }
                }
                .accessibilityHidden(true)
                .overlay(alignment: .bottomLeading) {
                    heading
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                }
                .transition(.opacity)
            } else {
                // Clears the floating close button, like the detail
                // drawer's header under its toolbar.
                heading
                    .padding(.horizontal, 20)
                    .padding(.top, 92)
            }

            VStack(alignment: .leading, spacing: 20) {
                summary
                lines
                if showsMap, let draft {
                    PlaceMap(item: draft)
                        .transition(finishing(7))
                }
                if draft != nil {
                    actions()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                } else {
                    CaptureStatus(input: input, finishing: early != nil)
                        .transition(.opacity)
                }
            }
            .padding(20)
        }
        .onChange(of: draft != nil) { _, ready in
            if ready { AccessibilityNotification.Announcement("Ready").post() }
        }
        .sheet(isPresented: $choosingPhoto) {
            if let draft, let page = pageURL(draft) {
                PagePhotoPicker(page: page, current: draft.imageUrl) { url, colour in
                    draft.imageUrl = url.absoluteString
                    if let colour { draft.colorHex = colour }
                }
            }
        }
    }

    private func pageURL(_ draft: Item) -> URL? {
        guard let url = draft.url.flatMap(URL.init(string:)),
              url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }

    // MARK: - Header

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.displaySmallBold(28, relativeTo: .title2))
                    .foregroundStyle(AppBackground.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    // A corrected title cross-fades rather than snapping.
                    .id(title)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    skeleton(width: 230, height: 20)
                    skeleton(width: 150, height: 20)
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }

            if let fields {
                subtitle(fields)
                    .transition(arrival(0))
            } else {
                skeleton(width: 120, height: 10)
                    .padding(.vertical, 4)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The detail drawer's line under the title: when it's on, then what
    /// kind of thing it is.
    @ViewBuilder
    private func subtitle(_ draft: Item) -> some View {
        // At accessibility sizes the pair can't share a line without the
        // dot stranded between wrapped halves, so they stack.
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        if draft.timeLabel != nil || draft.category != nil {
            layout {
                if let label = draft.timeLabel {
                    Text(label)
                        .foregroundStyle(draft.timeLabelIsUrgent ? AppBackground.destructive : AppBackground.secondaryInk)
                }
                if !stacked && draft.timeLabel != nil && draft.category != nil {
                    Text("·").foregroundStyle(AppBackground.secondaryInk.opacity(0.6))
                }
                if let category = draft.category {
                    Text(category.capitalized).foregroundStyle(AppBackground.secondaryInk)
                }
            }
            .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Body

    /// The card's description, as the detail drawer shows it; placeholder
    /// lines hold its place while reading.
    @ViewBuilder
    private var summary: some View {
        if let fields {
            if let text = fields.summary, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(arrival(1))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                skeleton(width: 320, height: 10)
                skeleton(width: 290, height: 10)
                skeleton(width: 180, height: 10)
            }
            .padding(.vertical, 4)
            .transition(.opacity)
        }
    }

    /// Dates, venue, area, price and the photo's credit, in the detail
    /// drawer's order. While reading, the first three are placeholders
    /// until the quick guess has them; the parser's fields replace both,
    /// and a line it has nothing for goes away. What's missing is only
    /// said once the card is in: the page's listing can still date it.
    private var lines: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let fields {
                let showings = PlanSheet.showings(of: fields)
                if fields.isEvent, fields.startsOn == nil, fields.endsOn == nil, showings.isEmpty {
                    if draft != nil {
                        gap("calendar", "No date on the page", fix: "Add one", action: editFirst)
                            .transition(finishing(6))
                    } else {
                        line("calendar", nil, placeholder: 150, order: 2)
                    }
                } else if showings.isEmpty {
                    line("calendar", fields.dateLine, order: 2)
                } else {
                    Label {
                        ShowingsLine(showings: showings, dateLine: fields.dateLine)
                    } icon: {
                        icon("calendar")
                    }
                    .font(.subheadline)
                    .transition(arrival(2))
                }
                line("building.2", fields.venue != fields.title ? fields.venue : nil, order: 3)
                line("map", fields.areaLine, order: 4)
                line("banknote", fields.price, order: 5)
                if let draft {
                    line("camera", draft.photoCredit, order: early == nil ? 6 : 0)
                    if photoURL == nil, pageURL(draft) != nil {
                        gap("photo", "No photo found", fix: "Pick one") { choosingPhoto = true }
                            .transition(finishing(6))
                    }
                }
            } else {
                line("calendar", lookDate, placeholder: 150, order: 0)
                line("building.2", look?.venue, placeholder: 190, order: 1)
                line("map", look?.areaLine, placeholder: 110, order: 2)
            }
        }
    }

    /// A guessed single date reads as that day; "From …" is the card's to say.
    private var lookDate: String? {
        guard let look else { return nil }
        if look.endsOn == nil, let start = look.startsOn {
            return DayString.text(start, date: .abbreviated) ?? start
        }
        return look.dateLine
    }

    @ViewBuilder
    private func line(_ symbol: String, _ text: String?, placeholder width: CGFloat? = nil, order: Int) -> some View {
        if let text {
            Label {
                Text(text)
                    .foregroundStyle(AppBackground.secondaryInk)
                    .id(text)
                    .transition(.opacity)
            } icon: {
                icon(symbol)
            }
            .font(.subheadline)
            .transition(arrival(order))
        } else if let width {
            Label {
                skeleton(width: width, height: 10)
            } icon: {
                icon(symbol)
            }
            .font(.subheadline)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    /// Something the parser couldn't find, said plainly, with the way to
    /// fill it in beside it.
    private func gap(_ symbol: String, _ text: String, fix: String, action: (() -> Void)?) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(text).foregroundStyle(AppBackground.secondaryInk)
                if let action {
                    Text("·").foregroundStyle(AppBackground.secondaryInk.opacity(0.6))
                    Button(fix) {
                        Haptics.tap()
                        action()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(AppBackground.ink)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                    .padding(.vertical, -12)
                }
            }
        } icon: {
            icon(symbol)
        }
        .font(.subheadline)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(AppBackground.ink.opacity(0.45))
            .frame(width: 20)
    }

    private func skeleton(width: CGFloat, height: CGFloat) -> some View {
        SkeletonLine(width: width, height: height)
            .overlay { Shimmer(highlight: AppBackground.ink.opacity(0.12)) }
            .clipShape(.capsule)
            .accessibilityHidden(true)
    }
}

/// One line saying what the parser is doing, moved on by the clock: what
/// it was sent first, then the same few steps for everything, holding on
/// the last for a slow read — or going straight to it once the parser's
/// fields are in. VoiceOver hears the first line once.
struct CaptureStatus: View {
    let input: CaptureInput
    /// The fields are in; only the photo and the map are left.
    var finishing = false
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds each line stays before the next — a normal read is five or six.
    private static let holds: [Double] = [1.6, 1.5, 1.5]

    private var phrases: [String] {
        let opener = switch input {
        case .link: "Reading the page…"
        case .text: "Reading what you wrote…"
        case .image: "Reading the screenshot…"
        }
        return [opener, "Finding the venue…", "Checking the dates…", "Almost there…"]
    }

    var body: some View {
        HStack(spacing: 8) {
            SmallRing()
            // Only the words are clipped, for the push between lines: the
            // ring's stroke reaches just past its own frame.
            ZStack(alignment: .leading) {
                Text(phrases[step])
                    .id(step)
                    .transition(reduceMotion ? .opacity : .push(from: .bottom))
            }
            .clipped()
        }
        .font(.subheadline)
        .foregroundStyle(AppBackground.secondaryInk)
        .animation(.snappy, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phrases[0])
        .task {
            AccessibilityNotification.Announcement(phrases[0]).post()
            for hold in Self.holds {
                try? await Task.sleep(for: .seconds(hold))
                guard !Task.isCancelled else { return }
                step = min(step + 1, phrases.count - 1)
            }
        }
        .onChange(of: finishing, initial: true) { _, done in
            if done { step = phrases.count - 1 }
        }
    }
}
