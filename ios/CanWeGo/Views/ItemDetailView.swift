import MapKit
import SwiftData
import SwiftUI
import UIKit

/// Detail sheet — a soft wash of the item's color at the top, quiet
/// metadata, the map, and a pair of equal actions. A pencil in the toolbar
/// flips the whole sheet into an edit form.
struct ItemDetailView: View {
    @Bindable var item: Item
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var done = false
    @State private var editing = false
    /// Edits land on this detached scratch copy, applied on Done. Typing
    /// straight into the live model re-rendered the entire list under the
    /// sheet on every keystroke — that was the intermittent typing lag.
    @State private var scratch: Item?
    @State private var calendarState: CalendarState = .idle
    @State private var detent: PresentationDetent = .medium
    @State private var fetching = false
    @State private var fetchNote: String?

    private enum CalendarState {
        case idle, added, failed
    }

    /// "Added by Can" — same as the web; quietly absent when unknown.
    private var addedBy: String? {
        MembersStore.shared.saverName(for: item).map { "Added by \($0)" }
    }

    /// "Edited by Joyce · yesterday" — only once the row has actually been
    /// edited after it was saved (the server stamps updated_by on human
    /// edits alone, so a thumbnail backfill never produces this line).
    private var editedBy: String? {
        guard let by = item.updatedBy,
              item.updatedAt.timeIntervalSince(item.createdAt) > 60,
              let name = MembersStore.shared.name(forUser: by)
        else { return nil }
        let when = item.updatedAt.formatted(.relative(presentation: .named))
        return "Edited by \(name) · \(when)"
    }

    private var dateLine: String? {
        switch (item.startsOn, item.endsOn) {
        case let (s?, e?) where s == e:
            return DayString.text(s, date: .abbreviated)
        case let (s?, e?):
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

    private var heroURL: URL? {
        item.imageUrl.flatMap(URL.init(string:))
    }

    /// Text accompanying a shared link — enough to make sense in a chat.
    private var shareMessage: String {
        var lines = [item.title]
        let place = [item.venue, item.area].compactMap(\.self).joined(separator: ", ")
        if !place.isEmpty { lines.append(place) }
        if let dateLine { lines.append(dateLine) }
        return lines.joined(separator: "\n")
    }

    private var showsHero: Bool { heroURL != nil && !editing }

    var body: some View {
        NavigationStack {
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
                }
            }
            // With a hero, the photo runs edge-to-edge under the controls.
            .ignoresSafeArea(edges: showsHero ? .top : [])
            .scrollDismissesKeyboard(.interactively)
            // Without a photo, the item's color breathes at the top instead.
            .background(alignment: .top) {
                if !showsHero {
                    LinearGradient(
                        colors: [item.accentColor.opacity(0.22), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 260)
                    .ignoresSafeArea()
                }
            }
            .background { ThemeFill(color: AppBackground.sheet) }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        if editing {
                            applyEdits()
                        } else {
                            scratch = editableCopy()
                        }
                        withAnimation(.snappy) { editing.toggle() }
                    } label: {
                        if editing {
                            Text("Done").font(.subheadline.weight(.semibold))
                        } else {
                            Image(systemName: "pencil")
                        }
                    }
                    .accessibilityLabel(editing ? "Finish editing" : "Edit")
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
                            Text("Cancel").font(.subheadline)
                        }
                        .accessibilityLabel("Cancel editing")
                    } else if let url = item.url.flatMap(URL.init(string:)) {
                        ShareLink(item: url, message: Text(shareMessage)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    } else {
                        ShareLink(item: shareMessage) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        // Cards open as a half-height drawer first; drag up for the rest.
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(AppBackground.sheet)
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

    /// Same button, new label, then the drawer leaves. `markDone` waits
    /// so Remind and the library don't reshuffle under the success state.
    private func confirmWent() {
        guard !done else { return }
        Haptics.success()
        withAnimation(.easeInOut(duration: 0.2)) { done = true }
        Task {
            try? await Task.sleep(for: .seconds(1))
            commitDoneIfNeeded()
            dismiss()
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
        copy.notes = item.notes
        copy.summary = item.summary
        copy.address = item.address
        copy.url = item.url
        copy.imageUrl = item.imageUrl
        copy.colorHex = item.colorHex
        copy.lat = item.lat
        copy.lng = item.lng
        return copy
    }

    /// One write to the live model — the list under the sheet re-renders
    /// once here instead of on every keystroke.
    private func applyEdits() {
        guard let scratch else { return }
        item.title = scratch.title
        item.kind = scratch.kind
        item.category = scratch.category
        item.venue = scratch.venue
        item.area = scratch.area
        item.price = scratch.price
        item.startsOn = scratch.startsOn
        item.endsOn = scratch.endsOn
        item.reminderOffsetDays = scratch.reminderOffsetDays
        item.reminderAnchor = scratch.reminderAnchor
        item.remindAt = scratch.remindAt
        item.notes = scratch.notes
        item.summary = scratch.summary
        item.address = scratch.address
        item.url = scratch.url
        item.imageUrl = scratch.imageUrl
        item.colorHex = scratch.colorHex
        item.lat = scratch.lat
        item.lng = scratch.lng
        item.reconcileReminder()
        item.updatedAt = .now
        try? context.save()
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
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Looks the original link up again and fills the fields above. Your notes stay put — nothing saves until Done.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
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
            fetchNote = "Updated from the latest page — check the fields, then tap Done."
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
        fill(\.startsOn, card.starts_on)
        fill(\.endsOn, card.ends_on)
        scratch.reconcileReminder()
        if let lat = card.lat, let lng = card.lng {
            scratch.lat = lat
            scratch.lng = lng
        }
    }

    // MARK: - Header

    /// Full-bleed photo melting into the sheet through a theme-colored
    /// scrim, with the title and meta sitting on top of it.
    private func heroHeader(_ url: URL) -> some View {
        Color.clear
            .frame(height: 230)
            .overlay {
                // Hero tier: the one place full-size pixels are worth it.
                CachedImage(url: url, variant: .hero) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        item.accentColor.opacity(0.25)
                    }
                }
            }
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
                        .init(color: .clear, location: 0.32),
                        .init(color: AppBackground.sheet.opacity(0.7), location: 0.78),
                        .init(color: AppBackground.sheet, location: 1),
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
            .overlay(alignment: .bottomLeading) {
                header
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let label = item.timeLabel {
                    Text(label)
                        .foregroundStyle(item.timeLabelIsUrgent ? AppBackground.destructive : Color.secondary)
                }
                if item.timeLabel != nil && item.category != nil {
                    Text("·").foregroundStyle(.tertiary)
                }
                if let category = item.category {
                    // Title case, matching the filter chips.
                    Text(category.capitalized).foregroundStyle(.secondary)
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
                .font(.post(17))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 10) {
            metaRow("calendar", dateLine)
            metaRow("building.2", item.venue != item.title ? item.venue : nil)
            metaRow("map", item.area)
            metaRow("sterlingsign.circle", item.price)
            metaRow("person", addedBy)
            metaRow("pencil", editedBy)
        }

        RemindRow(item: item, persist: true)

        if let lat = item.lat, let lng = item.lng {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            Map(initialPosition: .region(.init(
                center: coord,
                span: .init(latitudeDelta: 0.012, longitudeDelta: 0.012)
            ))) {
                Marker(item.venue ?? item.title, coordinate: coord)
                    .tint(item.accentColor)
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

        if let notes = item.notes, !notes.isEmpty {
            Text(notes)
                .font(.post(15, relativeTo: .subheadline))
                .lineSpacing(2)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 14, style: .continuous))
        }

        // Actions: an equal pair up top, the calendar as a quiet
        // third. No accent — the content above carries the color.
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let url = item.url.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Label("Open link", systemImage: "safari")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppBackground.onProminent)
                            .frame(maxWidth: .infinity)
                    }
                    .prominentGlass()
                }

                if item.isDone && !done {
                    Button {
                        Haptics.tap()
                        item.putBack()
                    } label: {
                        Label("Put back", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    Button(role: .destructive) {
                        Haptics.tap()
                        UndoBin.shared.stash(item.snapshot)
                        SupabaseSync.setDeleted(item.id, true)
                        context.delete(item)
                        try? context.save()
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                } else if !item.isDone || done {
                    Button(action: confirmWent) {
                        // For something that's already over, the plain label
                        // reads odd — soften it to an after-the-fact note.
                        Label(
                            done ? "Done" : (item.isMissed ? "We did go after all" : "We did go!"),
                            systemImage: "checkmark"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppBackground.onProminent)
                        .frame(maxWidth: .infinity)
                        .contentTransition(.opacity)
                    }
                    .prominentGlass()
                    .allowsHitTesting(!done)
                }
            }

            if item.startsOn != nil && (!item.isDone || done) {
                Button {
                    Haptics.tap()
                    Task {
                        do {
                            try await item.addToCalendar()
                            Haptics.success()
                            withAnimation(.snappy) { calendarState = .added }
                        } catch {
                            withAnimation(.snappy) { calendarState = .failed }
                        }
                    }
                } label: {
                    Label(
                        calendarState == .added ? "In calendar" : "Add to calendar",
                        systemImage: calendarState == .added ? "checkmark" : "calendar.badge.plus"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(calendarState == .added)
            }

            if calendarState == .failed {
                if let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("Couldn't add. Allow calendar access in Settings.", destination: settings)
                        .font(.footnote)
                        .foregroundStyle(AppBackground.destructive)
                } else {
                    Text("Couldn't add. Allow calendar access in Settings.")
                        .font(.footnote)
                        .foregroundStyle(AppBackground.destructive)
                }
            }
        }
        .controlSize(.large)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func metaRow(_ symbol: String, _ text: String?) -> some View {
        if let text {
            Label {
                Text(text).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(AppBackground.ink.opacity(0.45))
                    .frame(width: 20)
            }
            .font(.subheadline)
        }
    }

}
