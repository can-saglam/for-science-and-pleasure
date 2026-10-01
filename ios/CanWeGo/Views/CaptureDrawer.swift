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
/// first, then the parser's card confirming or correcting them — and once
/// the card is in, the same drawer is the "Looks right?" preview, with
/// the actions unfolding below. Shared with the share extension.
struct CaptureDrawer<Actions: View>: View {
    /// The parser's card; nil while it's still reading.
    let draft: Item?
    /// The on-device model's quick guess.
    var look: Item? = nil
    var peek: LinkPeek? = nil
    let input: CaptureInput
    /// Off in the share extension, where a live map is too much memory.
    var showsMap = true
    @ViewBuilder var actions: () -> Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var title: String? {
        let raw = draft?.title ?? peek?.title ?? look?.title
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? raw : nil
    }

    private var photoURL: URL? { draft?.imageUrl.flatMap(URL.init(string:)) }

    /// While it's reading there's always room for a photo — a placeholder
    /// until one turns up. A card that came back without one folds it away.
    private var showsPhoto: Bool { draft == nil || photoURL != nil }

    private var settle: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
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
                        .transition(settle)
                }
                if draft != nil {
                    actions()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                } else {
                    CaptureStatus(input: input)
                        .transition(.opacity)
                }
            }
            .padding(20)
        }
        .onChange(of: draft != nil) { _, ready in
            if ready { AccessibilityNotification.Announcement("Ready").post() }
        }
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

            if let draft {
                subtitle(draft)
                    .transition(settle)
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
                        .foregroundStyle(draft.timeLabelIsUrgent ? AppBackground.destructive : Color.secondary)
                }
                if !stacked && draft.timeLabel != nil && draft.category != nil {
                    Text("·").foregroundStyle(.tertiary)
                }
                if let category = draft.category {
                    Text(category.capitalized).foregroundStyle(.secondary)
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
        if let draft {
            if let text = draft.summary, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
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
    /// until the quick guess has them; the card's answer replaces both,
    /// and a line it has nothing for goes away.
    private var lines: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let draft {
                line("calendar", draft.dateLine)
                line("building.2", draft.venue != draft.title ? draft.venue : nil)
                line("map", draft.areaLine)
                line("sterlingsign.circle", draft.price)
                line("camera", draft.photoCredit)
            } else {
                line("calendar", lookDate, placeholder: 150)
                line("building.2", look?.venue, placeholder: 190)
                line("map", look?.areaLine, placeholder: 110)
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
    private func line(_ symbol: String, _ text: String?, placeholder width: CGFloat? = nil) -> some View {
        if let text {
            Label {
                Text(text)
                    .foregroundStyle(.secondary)
                    .id(text)
                    .transition(.opacity)
            } icon: {
                icon(symbol)
            }
            .font(.subheadline)
            .transition(settle)
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
/// the last for a slow read. VoiceOver hears the first line once.
struct CaptureStatus: View {
    let input: CaptureInput
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
            Text(phrases[step])
                .id(step)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .clipped()
        .animation(.snappy, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phrases[0])
        .task {
            AccessibilityNotification.Announcement(phrases[0]).post()
            for hold in Self.holds {
                try? await Task.sleep(for: .seconds(hold))
                guard !Task.isCancelled else { return }
                step += 1
            }
        }
    }
}
