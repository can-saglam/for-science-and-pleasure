import PhotosUI
import SwiftUI
import UIKit

/// Field-by-field editor for an item — used for parsed drafts in Capture
/// and for editing saved items from the detail sheet. Fields carry quiet
/// leading icons and gather under small section headers, so eight rows
/// read as four little thoughts instead of a wall.
struct ItemForm: View {
    @Bindable var item: Item
    /// What the event had before it became a place, so flipping back
    /// within the same edit brings it all back.
    @State private var eventOnly: EventFields?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // First, because it decides which fields follow: a place has
            // no dates, and its title already is the venue.
            Picker("Kind", selection: $item.kind) {
                Text("Event").tag(Item.Kind.event)
                Text("Place").tag(Item.Kind.place)
            }
            .pickerStyle(.segmented)

            section("The basics") {
                field(item.isPlace ? "Name of the place" : "What\u{2019}s on", icon: "pencil.line", text: $item.title)
                field("Category", icon: "tag", text: optional($item.category))
            }

            section("Picture") {
                ThumbnailField(item: item)
            }

            section("Where") {
                if item.isEvent {
                    field("Venue", icon: "building.2", text: optional($item.venue))
                }
                field("Area", icon: "mappin.and.ellipse", text: optional($item.area))
            }

            // A hand-picked reminder needs no dates, so a place can keep one.
            if item.isEvent || item.hasCustomReminder {
                section("When") {
                    if item.isEvent {
                        OptionalDateRow(label: "Opens", icon: "calendar", value: $item.startsOn)
                        OptionalDateRow(label: "Closes", icon: "calendar.badge.checkmark", value: $item.endsOn)
                    }
                    RemindRow(item: item)
                }
            }

            section("Extras") {
                field("Price", icon: "banknote", text: optional($item.price))

                HStack(alignment: .top, spacing: 10) {
                    fieldIcon("note.text")
                        .padding(.top, 3)
                    TextField(
                        "",
                        text: optional($item.notes),
                        prompt: AppBackground.fieldPrompt("Notes"),
                        axis: .vertical
                    )
                    .foregroundStyle(AppBackground.ink)
                    .lineLimit(2...5)
                }
                .padding(12)
                .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
        // Hidden dates would still count: a place with a closing date
        // drops into Missed the day after. So a place saves without them.
        .onChange(of: [item.id.uuidString, item.kind]) { old, new in
            // A different item handed in isn't a flip.
            guard old[0] == new[0] else {
                eventOnly = nil
                return
            }
            if new[1] == Item.Kind.place {
                eventOnly = EventFields(item)
                item.startsOn = nil
                item.endsOn = nil
                item.venue = nil
                item.reconcileReminder()
            } else if let stashed = eventOnly {
                stashed.restore(into: item)
                eventOnly = nil
            }
        }
    }

    private struct EventFields {
        let startsOn: String?
        let endsOn: String?
        let venue: String?
        let reminderOffsetDays: Int?
        let reminderAnchor: String?
        let remindAt: String?
        let remindTime: String?

        init(_ item: Item) {
            startsOn = item.startsOn
            endsOn = item.endsOn
            venue = item.venue
            reminderOffsetDays = item.reminderOffsetDays
            reminderAnchor = item.reminderAnchor
            remindAt = item.remindAt
            remindTime = item.remindTime
        }

        /// Only into fields still empty: anything typed as a place stays.
        func restore(into item: Item) {
            item.startsOn = item.startsOn ?? startsOn
            item.endsOn = item.endsOn ?? endsOn
            item.venue = item.venue ?? venue
            guard !item.hasReminder else { return }
            item.reminderOffsetDays = reminderOffsetDays
            item.reminderAnchor = reminderAnchor
            item.remindAt = remindAt
            item.remindTime = remindTime
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Same voice as the library's section headers ("Last chance",
            // "Nearby"): footnote, semibold, a fixed share of the ink —
            // the only all-caps in the app was here.
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppBackground.ink.opacity(SectionHeader.titleOpacity))
            content()
        }
    }

    private func field(_ label: String, icon: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            fieldIcon(icon)
            TextField("", text: text, prompt: AppBackground.fieldPrompt(label))
                .foregroundStyle(AppBackground.ink)
        }
        .padding(12)
        .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func optional(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

/// Dimmed leading symbol, fixed-width so every field's text starts on the
/// same vertical line.
private func fieldIcon(_ name: String) -> some View {
    FieldIcon(name: name)
}

private struct FieldIcon: View {
    let name: String
    /// Grows with the symbol, or big type pushes it into the label.
    @ScaledMetric(relativeTo: .subheadline) private var width = 22.0

    var body: some View {
        Image(systemName: name)
            .font(.subheadline)
            .foregroundStyle(AppBackground.ink.opacity(0.35))
            .frame(width: width)
    }
}

/// "Add date" → date picker + clear, for the optional yyyy-MM-dd fields.
private struct OptionalDateRow: View {
    let label: String
    let icon: String
    @Binding var value: String?

    var body: some View {
        HStack(spacing: 10) {
            fieldIcon(icon)
            // Same type and ink as the text fields' prompts, so an empty
            // date doesn't read as a disabled one.
            AppBackground.fieldPrompt(label)
            Spacer()
            if let value, let date = DayString.date(value) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { date },
                        set: { self.value = DayString.formatter.string(from: $0) }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                Button {
                    Haptics.tap()
                    self.value = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppBackground.secondaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear date")
            } else {
                Button {
                    Haptics.tap()
                    value = DayString.today()
                } label: {
                    Label("Add date", systemImage: "calendar.badge.plus")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppBackground.secondaryInk)
            }
        }
        // Same filled row as the text fields, so nothing floats loose.
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Add, replace or clear the cover. The picker is the system photo library;
/// the file lands in Storage and `image_url` so both phones (and the site)
/// see the same picture, then `ImageStore` keeps a local copy.
private struct ThumbnailField: View {
    @Bindable var item: Item
    @State private var pick: PhotosPickerItem?
    @State private var cameraOpen = false
    @State private var choosingFromPage = false
    @State private var uploading = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $pick, matching: .images) {
                    HStack(spacing: 12) {
                        thumb
                        if item.imageUrl == nil {
                            AppBackground.fieldPrompt("Add a photo")
                        } else {
                            Text("Change photo")
                        }
                        Spacer(minLength: 0)
                        if uploading {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(uploading)
                .accessibilityLabel(item.imageUrl == nil ? "Add a photo" : "Change photo")

                if let page = pageURL, !uploading {
                    Button {
                        Haptics.tap()
                        choosingFromPage = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                            .font(.body)
                            .foregroundStyle(AppBackground.ink.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pick a photo from the page")
                    .sheet(isPresented: $choosingFromPage) {
                        PagePhotoPicker(page: page, current: item.imageUrl) { url, colour in
                            note = nil
                            item.imageUrl = url.absoluteString
                            if let colour { item.colorHex = colour }
                        }
                    }
                }

                if UIImagePickerController.isSourceTypeAvailable(.camera), item.imageUrl == nil, !uploading {
                    Button {
                        Haptics.tap()
                        cameraOpen = true
                    } label: {
                        Image(systemName: "camera")
                            .font(.body)
                            .foregroundStyle(AppBackground.ink.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Take a photo")
                }

                if item.imageUrl != nil, !uploading {
                    Button {
                        Haptics.tap()
                        Task { await clear() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(AppBackground.secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove photo")
                }
            }
            .padding(12)
            .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))

            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(AppBackground.warning)
            }
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            pick = nil
            Task { await use(item) }
        }
        .sheet(isPresented: $cameraOpen) {
            CameraPicker { image in
                Task { await use(image) }
            }
            .ignoresSafeArea()
        }
    }

    /// The save's own web page, whose pictures can be picked from.
    private var pageURL: URL? {
        guard let url = item.url.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }

    @ViewBuilder
    private var thumb: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let raw = item.imageUrl, let url = URL(string: raw) {
            CachedImage(url: url, variant: .card) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    AppBackground.wash(0.12)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(shape)
        } else {
            shape.fill(AppBackground.wash(0.12))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppBackground.secondaryInk.opacity(0.6))
                }
        }
    }

    private func use(_ pick: PhotosPickerItem) async {
        guard let data = try? await pick.loadTransferable(type: Data.self) else {
            note = "Couldn't read that photo."
            return
        }
        await use(data.compressedImageForUpload())
    }

    private func use(_ image: UIImage) async {
        await use(image.compressedForUpload())
    }

    private func use(_ jpeg: Data?) async {
        guard let jpeg else {
            note = "Couldn't read that photo."
            return
        }
        uploading = true
        note = nil
        defer { uploading = false }
        do {
            let previous = item.imageUrl
            item.imageUrl = try await ItemImageUpload.publish(jpeg, replacing: previous)
            if let old = previous, old != item.imageUrl, let url = URL(string: old) {
                ImageStore.evict(url)
            }
        } catch {
            note = (error as? ItemImageError)?.errorDescription ?? SyncProblem(error).message
        }
    }

    private func clear() async {
        let previous = item.imageUrl
        item.imageUrl = nil
        note = nil
        if let previous {
            await ItemImageUpload.remove(previous)
        }
    }
}
