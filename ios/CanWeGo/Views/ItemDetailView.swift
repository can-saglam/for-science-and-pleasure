#if !APP_EXTENSION
import AppIntents
#endif
import MapKit
import SwiftData
import SwiftUI
import UIKit

/// Detail sheet — a soft wash of the item's color at the top, quiet
/// metadata, the map, and its actions floating in glass, bottom right.
/// Edit, in the toolbar's More menu, flips the whole sheet into an edit form.
struct ItemDetailView: View {
    @Bindable var item: Item
    /// Set when the save sits in the library's side pane rather than a
    /// sheet: closing hands the pane back instead of dismissing anything.
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var done = false
    @State private var editing = false
    /// Edits land on this detached scratch copy, applied on Done. Typing
    /// straight into the live model re-rendered the entire list under the
    /// sheet on every keystroke — that was the intermittent typing lag.
    @State private var scratch: Item?
    // CWG_DETENT is only set by automated screenshot runs.
    @State private var detent: PresentationDetent =
        ProcessInfo.processInfo.environment["CWG_DETENT"] == "large" ? .large : .medium
    @State private var fetching = false
    @State private var fetchNote: String?
    /// This save's link, on its way to the share sheet.
    @State private var sharing: ShareItems?
    @State private var paywall: PlusReason?
    @State private var hours: OpeningHours?
    @State private var hoursLoading = false
    /// A showing tapped in the details, opening the plan on it.
    @State private var planShowing: Showing?

    /// "Added by Can" and "edited by Joyce yesterday" (just "edited
    /// yesterday" when it's the saver's own edit). The edit only shows once
    /// the row has actually been changed after it was saved (the server
    /// stamps updated_by on human edits alone, so a thumbnail backfill never
    /// counts). Either is nil when unknown.
    private var who: (added: String?, edited: String?) {
        let saver = MembersStore.shared.saverName(for: item)
        let editor = item.updatedBy.flatMap { by in
            item.updatedAt.timeIntervalSince(item.createdAt) > 60 ? MembersStore.shared.name(forUser: by) : nil
        }
        let when = item.updatedAt.formatted(.relative(presentation: .named))
        let own = saver != nil && (item.updatedBy == item.createdBy || editor == saver)
        return (
            saver.map { "Added by \($0)" },
            editor.map { own ? "edited \(when)" : "edited by \($0) \(when)" }
        )
    }

    /// Who saved and who last edited, on one line when it fits; with long
    /// names, the edit takes a line of its own rather than breaking mid-name.
    @ViewBuilder
    private var whoRow: some View {
        let (added, edited) = who
        if let added, let edited {
            metaRow("person") {
                ViewThatFits(in: .horizontal) {
                    Text("\(added) · \(edited)")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(added)
                        Text(edited.prefix(1).uppercased() + edited.dropFirst())
                    }
                }
            }
        } else if let line = added ?? edited.map({ $0.prefix(1).uppercased() + $0.dropFirst() }) {
            metaRow("person", line)
        }
    }

    private var dateLine: String? { item.dateLine }

    private var heroURL: URL? {
        item.imageUrl.flatMap(URL.init(string:))
    }

    private var showsHero: Bool { heroURL != nil && !editing }

    /// The side safe areas when the bars run down the side (iPhone Duo),
    /// in the side pane or the drawer, on whichever side they are: the
    /// photo runs on under them to the edge, everything else stops short.
    @State private var sideInsets = EdgeInsets()
    @State private var rowFloor: CGFloat?
    @State private var barsEdge: HorizontalEdge?
    private var photoUnderBar: Bool { showsHero && (onClose != nil || barsEdge != nil) }
    private var barClearance: EdgeInsets { photoUnderBar ? sideInsets : EdgeInsets() }
    /// As a drawer with the bar down the right (iPhone Duo's outer
    /// display), the actions stop where the bar's column starts: the front
    /// camera is at the foot of that column, inside the safe area, and the
    /// system doesn't say where.
    private var rowBesideBarColumn: Bool { onClose == nil && barsEdge == .trailing && sideInsets.trailing > 48 }

    var body: some View {
        withOwnBars {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let hero = heroURL, !editing {
                        heroHeader(hero)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        if !showsHero {
                            header
                        }
                        if editing, let scratch {
                            VStack(alignment: .leading, spacing: 22) {
                                ItemForm(item: scratch)
                                refetchRow
                            }
                            .transition(.opacity)
                        } else {
                            readingContent
                        }
                    }
                    .padding(20)
                    .padding(.leading, barClearance.leading)
                    .padding(.trailing, barClearance.trailing)
                    .task(id: item.showsHours ? item.placeId : nil) { await loadHours() }
                }
            }
            .keepsNavigationBar(onClose != nil)
            // With a hero, the photo runs edge-to-edge under the controls.
            .ignoresSafeArea(edges: photoUnderBar ? [.top, .horizontal] : showsHero ? .top : [])
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !editing {
                    DetailActionCluster(
                        item: item,
                        done: done,
                        share: share,
                        went: confirmWent,
                        putBack: putBack
                    )
                    .environment(\.floatingRowTrailing, rowBesideBarColumn ? 0 : nil)
                }
            }
            // Without a photo, the item's color breathes at the top instead.
            .background(alignment: .top) {
                if !showsHero {
                    LinearGradient(
                        colors: [item.accentColor.opacity(0.22), item.accentColor.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 260)
                    .ignoresSafeArea()
                }
            }
            .background { ThemeFill(color: AppBackground.sheet) }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
                sideInsets = EdgeInsets(top: 0, leading: $0.leading, bottom: 0, trailing: $0.trailing)
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { rowFloor = $0 }
            .environment(\.floatingRowFloor, rowFloor)
            .onBarsEdgeChange { barsEdge = $0 }
            #if !APP_EXTENSION
            .appEntityIdentifier(EntityIdentifier(for: SaveEntity.self, identifier: item.id))
            #endif
            .toolbarBackground(onClose == nil ? .hidden : .automatic, for: .navigationBar)
            // In the side pane the buttons live in the app's side bar, so
            // nothing up top needs the photo frosted behind it.
            .scrollEdgeEffectHidden(onClose != nil, for: .top)
            .toolbar {
                if editing {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Haptics.tap()
                            applyEdits()
                            withAnimation(.snappy) { editing = false }
                        } label: {
                            // The side bar takes icons; words would be moved
                            // up over the list.
                            if onClose != nil {
                                Image(systemName: "checkmark").fontWeight(.semibold)
                            } else {
                                Text("Done").font(.subheadline.weight(.semibold))
                            }
                        }
                        .accessibilityLabel("Finish editing")
                    }
                    .keptVisible(.high)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if editing {
                        // The way out that doesn't save: drop the scratch
                        // copy and return to reading untouched.
                        Button {
                            Haptics.tap()
                            scratch = nil
                            withAnimation(.snappy) { editing = false }
                        } label: {
                            if onClose != nil {
                                Image(systemName: "xmark")
                            } else {
                                Text("Cancel").font(.subheadline)
                            }
                        }
                        .accessibilityLabel("Cancel editing")
                    } else {
                        // Edit, then the same actions the long-press menu offers.
                        Menu {
                            Button {
                                Haptics.tap()
                                scratch = editableCopy()
                                withAnimation(.snappy) { editing = true }
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Divider()
                            ShareMenuItems(item: item)
                            if let address = copyableAddress {
                                Button {
                                    Haptics.success()
                                    UIPasteboard.general.string = address
                                } label: {
                                    Label("Copy address", systemImage: "mappin.and.ellipse")
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                Haptics.tap()
                                UndoBin.shared.stash(item.snapshot)
                                item.softDelete()
                                close()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        // Edit nearest the button, Delete furthest, wherever
                        // the menu opens.
                        .menuOrder(.fixed)
                        .accessibilityLabel("More")
                    }
                }
                .keptVisible(.high)
                // Beside the list there's nothing to close: picking another
                // save replaces this one, as in Mail.
                if onClose == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Haptics.tap()
                            close()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                    }
                }
            }
        }
        // Cards open as a half-height drawer first; drag up for the rest.
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(AppBackground.sheet)
        .sheet(item: $sharing) { outgoing in
            ActivitySheet(items: outgoing.items)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $planShowing) { PlanSheet(item: item, showing: $0) }
        .sheet(item: $paywall) { PlusPaywall(reason: $0, incoming: item, onUnlocked: { item.putBack() }) }
        // The edit form needs the room, so entering edit expands the sheet.
        .onChange(of: editing) { _, isEditing in
            if isEditing { detent = .large }
            else { fetchNote = nil }
        }
        // Swiping the sheet away mid-edit discards, same as Cancel —
        // edits only ever land through an explicit Done.
        // A mid-hold swipe still commits We Did Go — they already tapped.
        .onDisappear { commitDoneIfNeeded() }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// The drawer has bars of its own. Beside the list, its buttons join
    /// the library's, in the app's side bar.
    @ViewBuilder
    private func withOwnBars(@ViewBuilder _ page: () -> some View) -> some View {
        if onClose == nil {
            NavigationStack { page() }
        } else {
            page()
        }
    }

    /// Same button, new label, then the drawer leaves. `markDone` waits
    /// so Remind and the library don't reshuffle under the success state.
    private func confirmWent() {
        guard !done else { return }
        Haptics.success()
        withAnimation(.easeInOut(duration: 0.2)) { done = true }
        Task {
            try? await Task.sleep(for: .seconds(1))
            commitDoneIfNeeded()
            close()
        }
    }

    private func commitDoneIfNeeded() {
        guard done, !item.isDone else { return }
        item.markDone()
        UndoBin.shared.stashDone(item)
    }

    /// A detached twin holding just the fields the form edits.
    private func editableCopy() -> Item {
        let copy = Item()
        copy.title = item.title
        copy.kind = item.kind
        copy.category = item.category
        copy.venue = item.venue
        copy.area = item.area
        copy.price = item.price
        copy.startsOn = item.startsOn
        copy.endsOn = item.endsOn
        copy.reminderOffsetDays = item.reminderOffsetDays
        copy.reminderAnchor = item.reminderAnchor
        copy.remindAt = item.remindAt
        copy.remindTime = item.remindTime
        copy.notes = item.notes
        copy.summary = item.summary
        copy.address = item.address
        copy.url = item.url
        copy.imageUrl = item.imageUrl
        copy.colorHex = item.colorHex
        copy.lat = item.lat
        copy.lng = item.lng
        copy.placeId = item.placeId
        copy.source = item.source
        return copy
    }

    /// One write to the live model — the list under the sheet re-renders
    /// once here instead of on every keystroke.
    private func applyEdits() {
        guard let scratch else { return }
        // Moved somewhere else without a fresh lookup: the old place's hours
        // aren't this one's. The server drops it on the same terms (0041).
        let moved = scratch.venue != item.venue || scratch.address != item.address
            || (scratch.isPlace && scratch.title != item.title)
        if moved && scratch.placeId == item.placeId { scratch.placeId = nil }
        item.placeId = scratch.placeId
        item.title = scratch.title
        item.kind = scratch.kind
        item.category = scratch.category
        item.venue = scratch.venue
        item.area = scratch.area
        item.price = scratch.price
        item.startsOn = scratch.startsOn
        item.endsOn = scratch.endsOn
        if scratch.hasReminder, scratch.reminderOffsetDays != item.reminderOffsetDays
            || scratch.reminderAnchor != item.reminderAnchor {
            item.clearPlan()
        }
        item.reminderOffsetDays = scratch.reminderOffsetDays
        item.reminderAnchor = scratch.reminderAnchor
        item.remindAt = scratch.remindAt
        item.remindTime = scratch.remindTime
        item.notes = scratch.notes
        item.summary = scratch.summary
        item.address = scratch.address
        item.url = scratch.url
        item.imageUrl = scratch.imageUrl
        item.colorHex = scratch.colorHex
        item.lat = scratch.lat
        item.lng = scratch.lng
        item.source = scratch.source
        item.reconcileReminder()
        item.reconcilePlan()
        item.updatedAt = .now
        item.stampAuthor()
        context.saveOrReport()
        self.scratch = nil
    }

    /// Looks the save up again and writes whatever came back onto the
    /// scratch form — notes stay put, and nothing is saved until Done.
    private var refetchRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.tap()
                Task { await fetchAgain() }
            } label: {
                HStack {
                    Label("Fetch data again", systemImage: "arrow.clockwise")
                        .foregroundStyle(AppBackground.ink)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    if fetching {
                        // The button is `.large`; a default ProgressView
                        // inherits that and stretches the capsule.
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(fetching)
            .accessibilityHint("Looks the link up again and fills the fields above")

            if let fetchNote {
                Text(fetchNote)
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Looks the original link up again and fills the fields above. Your notes stay put, and nothing saves until Done.")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fetchAgain() async {
        guard let scratch else { return }
        fetching = true
        fetchNote = nil
        defer { fetching = false }
        var parts: [String] = []
        if !scratch.title.isEmpty { parts.append(scratch.title) }
        if let url = item.url, !url.isEmpty {
            parts.append(url)
        } else if let area = scratch.area ?? item.area, !area.isEmpty {
            parts.append(area)
        }
        let text = parts.joined(separator: "\n")
        guard !text.isEmpty else {
            fetchNote = "Need a title or a link to look this up."
            return
        }
        do {
            let card = try await ParseClient.parse(text: text, imageJPEG: nil)
            apply(card, to: scratch)
            Haptics.success()
            fetchNote = "Updated from the latest page. Check the fields, then tap Done."
        } catch {
            fetchNote = SyncProblem(error).message
        }
    }

    /// Non-empty parse results overwrite the matching field; empty ones
    /// leave what's already there. Notes are never touched.
    private func apply(_ card: ParseClient.Card, to scratch: Item) {
        if !card.title.isEmpty { scratch.title = card.title }
        if card.kind == Item.Kind.event || card.kind == Item.Kind.place {
            scratch.kind = card.kind
        }
        func fill(_ path: ReferenceWritableKeyPath<Item, String?>, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            scratch[keyPath: path] = value
        }
        fill(\.category, card.category)
        fill(\.venue, card.venue)
        fill(\.area, card.area)
        fill(\.address, card.address)
        fill(\.price, card.price)
        fill(\.summary, card.summary)
        fill(\.url, card.url)
        fill(\.imageUrl, card.image_url)
        fill(\.colorHex, card.color)
        fill(\.source, card.source)
        fill(\.startsOn, card.starts_on)
        fill(\.endsOn, card.ends_on)
        fill(\.placeId, card.place_id)
        scratch.reconcileReminder()
        if let lat = card.lat, let lng = card.lng {
            scratch.lat = lat
            scratch.lng = lng
        }
    }

    // MARK: - Header

    /// Full-bleed photo melting into the sheet through a theme-colored
    /// scrim, with the title and meta sitting on top of it.
    /// At accessibility sizes the title can outgrow the melt and climb
    /// under the buttons on the photo, so it moves below the picture.
    @ViewBuilder
    private func heroHeader(_ url: URL) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HeroPhoto(url: url, placeholder: item.accentColor, fadesLeading: onClose != nil)
                header
                    .padding(.horizontal, 20)
                    .padding(.leading, barClearance.leading)
                    .padding(.trailing, barClearance.trailing)
                    .padding(.bottom, 6)
            }
        } else {
            HeroPhoto(url: url, placeholder: item.accentColor, fadesLeading: onClose != nil)
                .overlay(alignment: .bottomLeading) {
                    header
                        .padding(.horizontal, 20)
                        .padding(.leading, barClearance.leading)
                        .padding(.trailing, barClearance.trailing)
                        .padding(.bottom, 6)
                }
        }
    }

    private var areaLine: String? { item.areaLine }

    private var header: some View {
        // At accessibility sizes the pair can't share a line without the
        // dot stranded between wrapped halves, so they stack.
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.displaySmallBold(28, relativeTo: .title2))
                .fixedSize(horizontal: false, vertical: true)
            layout {
                if let label = item.headerTimeLabel {
                    Text(label)
                        .foregroundStyle(item.headerTimeLabelIsUrgent ? AppBackground.destructive : AppBackground.secondaryInk)
                }
                if !stacked && item.headerTimeLabel != nil && item.category != nil {
                    Text("·").foregroundStyle(AppBackground.secondaryInk.opacity(0.6))
                }
                if let category = item.category {
                    // Title case, matching the filter chips.
                    Text(Item.categoryLabel(category)).foregroundStyle(AppBackground.secondaryInk)
                }
            }
            .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Reading mode

    @ViewBuilder
    private var readingContent: some View {
        if let summary = item.summary {
            Text(summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 10) {
            let showings = PlanSheet.showings(of: item)
            if showings.isEmpty {
                metaRow("calendar", dateLine)
            } else {
                Label {
                    ShowingsLine(
                        showings: showings,
                        dateLine: dateLine,
                        choose: item.canPlan || item.upcomingPlan != nil ? { planShowing = $0 } : nil
                    )
                } icon: {
                    Image(systemName: "calendar")
                        .foregroundStyle(AppBackground.ink.opacity(0.45))
                        .frame(width: 20)
                }
                .font(.subheadline)
            }
            HoursRow(hours: hours, loading: hoursLoading)
            metaRow("building.2", item.venue != item.title ? item.venue : nil)
            metaRow("map", areaLine)
            metaRow("banknote", item.price)
            whoRow
        }

        PlanOrRemind(item: item)

        PlaceMap(item: item)

        if let notes = item.notes, !notes.isEmpty {
            Text(notes)
                .font(.subheadline)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 14, style: .continuous))
        }
    }

    /// "South London Gallery, 65 Peckham Road, London SE5 8UH": the name
    /// first, so it pastes as somewhere, not just a street.
    private var copyableAddress: String? {
        guard let address = item.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty
        else { return nil }
        let name = (item.isPlace ? item.title : item.venue)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, !address.localizedCaseInsensitiveContains(name) else { return address }
        return "\(name), \(address)"
    }

    private func share() {
        Task { sharing = await ShareItems.sending(item) }
    }

    private func putBack() {
        Haptics.tap()
        if let full = CategoryCap.overflow(item, context: context) {
            paywall = .category(full)
        } else {
            item.putBack()
        }
    }

    private func loadHours() async {
        guard item.showsHours else {
            hours = nil
            return
        }
        if let known = HoursClient.cached(item) {
            hours = known
            return
        }
        hoursLoading = true
        let loaded = await HoursClient.load(item)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            hours = loaded
            hoursLoading = false
        }
    }

    @ViewBuilder
    private func metaRow(_ symbol: String, _ text: String?) -> some View {
        if let text {
            metaRow(symbol) { Text(text) }
        }
    }

    private func metaRow(_ symbol: String, @ViewBuilder _ content: () -> some View) -> some View {
        Label {
            content().foregroundStyle(AppBackground.secondaryInk)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(AppBackground.ink.opacity(0.45))
                .frame(width: 20)
        }
        .font(.subheadline)
    }

}

/// The details' header photo: full-bleed, melting into the sheet through a
/// theme-colored scrim. Whatever sits on it goes in an overlay.
struct HeroPhoto: View {
    let url: URL?
    /// A picture already on the phone (the capture drawer's link preview):
    /// shown on its own, or under `url` until that one has loaded.
    var image: UIImage? = nil
    let placeholder: Color
    var height: CGFloat = 230
    /// Beside the library list (iPhone Duo open): the leading edge melts
    /// into the pane, as the bottom does, instead of a hard line by the list.
    var fadesLeading = false
    /// The capture drawer's, where the picture turns up while you watch:
    /// it comes in soft and rich and sharpens as it settles, rather than
    /// popping in.
    var develops = false
    /// How large the picture is held, 1 being its own size. The capture
    /// drawer keeps it a touch close while the card is read and lets it
    /// ease back as the card lands.
    var zoom: CGFloat = 1

    var body: some View {
        Color.clear
            .frame(height: height)
            .overlay {
                if let image, develops {
                    Image(uiImage: image).resizable().scaledToFill()
                        .modifier(Develops(soft: true))
                        .scaleEffect(zoom)
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder.opacity(0.25)
                }
            }
            .overlay {
                if let url {
                    // Hero tier: the one place full-size pixels are worth it.
                    CachedImage(url: url, variant: .hero) { phase in
                        if case .success(let photo) = phase {
                            if develops {
                                photo.resizable().scaledToFill()
                                    // Over the link preview it's the same
                                    // picture, finer: no second arrival.
                                    .modifier(Develops(soft: image == nil))
                            } else {
                                photo.resizable().scaledToFill()
                            }
                        }
                    }
                    .scaleEffect(zoom)
                }
            }
            .animation(.easeOut(duration: 0.9), value: zoom)
            .overlay {
                LinearGradient(
                    stops: [
                        // A veil at the top keeps the floating controls
                        // legible — dark under light glyphs, light under
                        // cream's black ones.
                        .init(
                            color: AppBackground.theme.isLight
                                ? .white.opacity(0.35) : .black.opacity(0.35),
                            location: 0
                        ),
                        .init(color: .clear, location: 0.3),
                        // An eased (smoothstep) ramp, solid a little before
                        // the edge: a straight ramp that stops dead reads as
                        // a line across pale photos, however faint the photo.
                        .init(color: AppBackground.sheet.opacity(0.06), location: 0.4),
                        .init(color: AppBackground.sheet.opacity(0.22), location: 0.5),
                        .init(color: AppBackground.sheet.opacity(0.43), location: 0.6),
                        .init(color: AppBackground.sheet.opacity(0.66), location: 0.7),
                        .init(color: AppBackground.sheet.opacity(0.82), location: 0.78),
                        .init(color: AppBackground.sheet.opacity(0.94), location: 0.86),
                        .init(color: AppBackground.sheet.opacity(0.99), location: 0.92),
                        .init(color: AppBackground.sheet, location: 0.96),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            // The filled image overflows the frame, and at fractional pixel
            // positions the clip edge and the gradient's edge round
            // differently, leaking a one-pixel line of raw photo just past
            // the bottom. A sheet-colored strip straddling the boundary
            // (1pt of overhang into the plain sheet below) buries it.
            .overlay(alignment: .bottom) {
                AppBackground.sheet.frame(height: 3).offset(y: 1)
            }
            .modifier(LeadingFade(on: fadesLeading))
    }
}

/// A photo arriving the way a print develops: soft, rich and a little
/// close, sharpening as it settles. Over a picture that's already there
/// it's a short fade, sharp from the start.
private struct Develops: ViewModifier {
    /// Decided once, as the picture arrives: what's under it may change
    /// while it's still coming in.
    @State private var soft: Bool
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(soft: Bool) {
        _soft = State(initialValue: soft)
    }

    func body(content: Content) -> some View {
        let unsettled = soft && !arrived && !reduceMotion
        content
            .blur(radius: unsettled ? 18 : 0)
            .saturation(unsettled ? 1.35 : 1)
            .scaleEffect(unsettled ? 1.1 : 1)
            .animation(.easeOut(duration: 0.9), value: arrived)
            // Seen at once, then sharpened: the fade is the short part.
            .opacity(arrived ? 1 : 0)
            .animation(.easeOut(duration: 0.35), value: arrived)
            .onAppear { arrived = true }
    }
}

/// The hero's leading edge melting into the pane. Off, nothing is
/// applied: a mask would also clip the strip that hides the photo's
/// bottom pixel row.
private struct LeadingFade: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.mask {
                HStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.06), location: 0.15),
                            .init(color: .black.opacity(0.3), location: 0.35),
                            .init(color: .black.opacity(0.7), location: 0.65),
                            .init(color: .black.opacity(0.94), location: 0.85),
                            .init(color: .black, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 110)
                    Color.black
                }
            }
        } else {
            content
        }
    }
}

/// Where it is, with a tap through to directions. Shared by the detail
/// drawer and the capture drawer; nothing for a save without a location.
struct PlaceMap: View {
    let item: Item
    /// Found a moment ago (the capture drawer): the map opens on the
    /// neighbourhood, eases down to the street, and the pin lands once
    /// it's there. Reduce Motion gets it as it will stay.
    var arrives = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Degrees across: the few streets the map shows.
    fileprivate static let span = 0.012

    var body: some View {
        if let lat = item.lat, let lng = item.lng {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            Group {
                if arrives, !reduceMotion {
                    ArrivingMap(
                        coordinate: coord,
                        title: item.venue ?? item.title,
                        tint: UIColor(item.accentColor)
                    )
                } else {
                    Map(initialPosition: .region(.init(
                        center: coord,
                        span: .init(latitudeDelta: Self.span, longitudeDelta: Self.span)
                    ))) {
                        Marker(item.venue ?? item.title, coordinate: coord)
                            .tint(item.accentColor)
                    }
                }
            }
            .frame(height: 190)
            .allowsHitTesting(false)
            .overlay(alignment: .bottomTrailing) {
                Label("Open in \(TransportApp.current.name)", systemImage: "arrow.up.right")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(8)
            }
            .clipShape(.rect(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppBackground.ink.opacity(0.10), lineWidth: 1)
            )
            .contentShape(.rect(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                if let maps = item.directionsURL {
                    Haptics.tap()
                    openURL(maps)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.directionsURL == nil
                ? (item.venue ?? item.title)
                : "Open in \(TransportApp.current.name)")
            .accessibilityAddTraits(item.directionsURL == nil ? [] : .isButton)
        }
    }
}

/// `PlaceMap` arriving. SwiftUI's `Map` moves its camera at its own pace
/// and adds a marker without ceremony; the map view underneath can take
/// as long over the move as it's told, and its marker can be dropped in.
/// Once it has settled it's the same picture `Map` draws.
private struct ArrivingMap: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let title: String
    let tint: UIColor

    /// How much more of the neighbourhood it opens on. Small enough that
    /// the streets it ends on are already drawn when it gets there.
    private static let wider = 2.4

    func makeCoordinator() -> Coordinator { Coordinator(tint: tint) }

    func makeUIView(context: Context) -> ArrivingMapView {
        let map = ArrivingMapView()
        map.delegate = context.coordinator
        map.isUserInteractionEnabled = false
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.pin)
        let place = MKPointAnnotation()
        place.coordinate = coordinate
        place.title = title
        map.arrive(
            from: region(across: PlaceMap.span * Self.wider),
            to: region(across: PlaceMap.span),
            at: place
        )
        return map
    }

    func updateUIView(_ map: ArrivingMapView, context: Context) {}

    private func region(across span: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, span: .init(latitudeDelta: span, longitudeDelta: span))
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let pin = "pin"
        private let tint: UIColor

        init(tint: UIColor) {
            self.tint = tint
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.pin, for: annotation)
            if let marker = view as? MKMarkerAnnotationView {
                marker.markerTintColor = tint
                marker.titleVisibility = .visible
            }
            return view
        }

        /// The pin comes down from just above and lands with a small
        /// bounce. (`animatesWhenAdded` only fades it in.)
        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for view in views {
                view.alpha = 0
                view.transform = CGAffineTransform(translationX: 0, y: -34)
                UIView.animate(withDuration: 0.15) { view.alpha = 1 }
                UIView.animate(
                    withDuration: 0.6, delay: 0,
                    usingSpringWithDamping: 0.5, initialSpringVelocity: 0
                ) {
                    view.transform = .identity
                }
            }
        }
    }
}

/// A map view that makes its entrance once it has a size: a region set
/// on a view with no bounds yet has nothing to fit itself to, and nothing
/// animates before the view is on screen.
final class ArrivingMapView: MKMapView {
    private var entrance: (() -> Void)?

    func arrive(from wide: MKCoordinateRegion, to close: MKCoordinateRegion, at place: MKPointAnnotation) {
        entrance = { [weak self] in
            guard let self else { return }
            setRegion(wide, animated: false)
            // A beat for the tile to fade in before anything moves.
            UIView.animate(withDuration: 0.9, delay: 0.3, options: [.curveEaseInOut]) {
                self.setRegion(close, animated: true)
            } completion: { _ in
                self.addAnnotation(place)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, bounds.width > 0, let entrance else { return }
        self.entrance = nil
        entrance()
    }
}

/// The quiet lines under a drawer's header, shared by the detail drawer
/// and the capture drawer.
extension Item {
    var dateLine: String? {
        switch (startsOn, endsOn) {
        case let (s?, e?) where s == e:
            return DayString.text(s, date: .abbreviated)
        case let (s?, e?):
            if let range = DayString.text(from: s, to: e) { return range }
            let from = DayString.text(s, date: .abbreviated) ?? s
            let to = DayString.text(e, date: .abbreviated) ?? e
            return "\(from) – \(to)"
        case let (s?, nil):
            return "From \(DayString.text(s, date: .abbreviated) ?? s)"
        case let (nil, e?):
            return "Until \(DayString.text(e, date: .abbreviated) ?? e)"
        default:
            return nil
        }
    }

    /// Once they've been, the day they went: "Ended" or a countdown is
    /// about the event, not about them. Nothing when the day isn't known.
    var headerTimeLabel: String? { isDone ? wentLabel : timeLabel }

    var headerTimeLabelIsUrgent: Bool { !isDone && timeLabelIsUrgent }

    /// "Nunhead" under a "Nunhead" venue, or "Barbican" under "Barbican
    /// Centre", says nothing new.
    var areaLine: String? {
        guard let area else { return nil }
        let squash = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        if let venue, venue != title, squash(venue).contains(squash(area)) { return nil }
        return area
    }
}
