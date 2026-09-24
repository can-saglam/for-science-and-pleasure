import PhotosUI
import SwiftUI
import UIKit

/// Field-by-field editor for an item — used for parsed drafts in Capture
/// and for editing saved items from the detail sheet. Fields carry quiet
/// leading icons and gather under small section headers, so eight rows
/// read as four little thoughts instead of a wall.
struct ItemForm: View {
    @Bindable var item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("The basics") {
                field("Title", icon: "pencil.line", text: $item.title)

                Picker("Kind", selection: $item.kind) {
                    Text("Event").tag(Item.Kind.event)
                    Text("Place").tag(Item.Kind.place)
                }
                .pickerStyle(.segmented)

                field("Category", icon: "tag", text: optional($item.category))
            }

            section("Picture") {
                ThumbnailField(item: item)
            }

            section("Where") {
                field("Venue", icon: "building.2", text: optional($item.venue))
                field("Area", icon: "mappin.and.ellipse", text: optional($item.area))
            }

            section("When") {
                OptionalDateRow(label: "Opens", icon: "calendar", value: $item.startsOn)
                OptionalDateRow(label: "Closes", icon: "calendar.badge.checkmark", value: $item.endsOn)
                RemindRow(item: item)
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
    Image(systemName: name)
        .font(.subheadline)
        .foregroundStyle(AppBackground.ink.opacity(0.35))
        .frame(width: 22)
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
                        .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
    @State private var uploading = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                fieldIcon("photo")
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

                if UIImagePickerController.isSourceTypeAvailable(.camera), !uploading {
                    Button {
                        Haptics.tap()
                        cameraOpen = true
                    } label: {
                        Image(systemName: "camera")
                            .font(.subheadline)
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
                            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func use(_ pick: PhotosPickerItem) async {
        guard let data = try? await pick.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else {
            note = "Couldn't read that photo."
            return
        }
        await use(image)
    }

    private func use(_ image: UIImage) async {
        guard let jpeg = image.compressedForUpload() else {
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
