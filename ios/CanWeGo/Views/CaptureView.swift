import PhotosUI
import SwiftData
import SwiftUI

/// Add something: paste a link / describe it / attach a screenshot, let the
/// parser read it, preview the card, then save — or start from a blank card.
/// Mirrors the web app's three-stage capture flow.
struct CaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var imageJPEG: Data?
    @State private var cameraOpen = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var clipboardHasLink = false
    @FocusState private var inputFocused: Bool

    /// Unsaved model object; only inserted into the store on "Save".
    @State private var draft: Item?
    @State private var editing = false
    /// True when the card was started blank — no parser involved.
    @State private var manual = false
    @State private var confetti = false
    @State private var saved = false

    private var canParse: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageJPEG != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let draft {
                        previewStage(draft)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    } else {
                        inputStage
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(
                draft == nil ? "Where are we going?" : (manual ? "Add your own" : "Looks right?")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .background(alignment: .top) {
                if let draft {
                    LinearGradient(
                        colors: [draft.accentColor.opacity(0.25), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 220)
                    .ignoresSafeArea()
                }
            }
            .background(AppBackground.sheet.ignoresSafeArea())
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.success, trigger: saved) { _, new in new }
        // Pattern detection spots a copied link (even as plain text) without
        // triggering the paste banner — reading happens only on tap.
        .onAppear {
            // CWG_BLANK is only set by automated screenshot runs; it jumps
            // straight to the blank-card edit stage.
            if ProcessInfo.processInfo.environment["CWG_BLANK"] != nil, draft == nil {
                let blank = Item()
                blank.kind = Item.Kind.place
                draft = blank
                editing = true
                manual = true
            }
            UIPasteboard.general.detectPatterns(for: [\.probableWebURL]) { result in
                if case .success(let patterns) = result, patterns.contains(\.probableWebURL) {
                    Task { @MainActor in
                        withAnimation(.snappy) { clipboardHasLink = true }
                    }
                }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraPicker { image in
                withAnimation(.snappy) {
                    imageJPEG = image.compressedForUpload()
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Stage 1: input

    @ViewBuilder
    private var inputStage: some View {
        TextField(
            "An exhibition, a restaurant, a link…",
            text: $text,
            axis: .vertical
        )
        .lineLimit(4...8)
        .textFieldStyle(.plain)
        .focused($inputFocused)
        .padding(16)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    .white.opacity(inputFocused ? 0.22 : 0.10),
                    lineWidth: 1
                )
        )
        .animation(.snappy, value: inputFocused)
        .task {
            // Focus requested mid-presentation is silently dropped — wait
            // for the sheet to settle, claim it, and retry once if lost.
            try? await Task.sleep(for: .seconds(0.45))
            guard draft == nil else { return }
            inputFocused = true
            try? await Task.sleep(for: .seconds(0.5))
            if draft == nil && !inputFocused { inputFocused = true }
        }

        // Copied a link before opening the app? One tap does the rest.
        if clipboardHasLink && text.isEmpty && imageJPEG == nil {
            Button {
                Haptics.tap()
                let pasted = UIPasteboard.general.url?.absoluteString
                    ?? UIPasteboard.general.string.flatMap(firstURL(in:))
                guard let pasted else {
                    clipboardHasLink = false
                    return
                }
                text = pasted
                clipboardHasLink = false
                Task { await parse() }
            } label: {
                Label("Add the link you copied", systemImage: "link")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .transition(.opacity)
        }

        if let image = imageJPEG.flatMap(UIImage.init(data:)) {
            attachedThumbnail(image)
        }

        // One row, one height: attach, shoot, add.
        HStack(spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.glass)

            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    Haptics.tap()
                    cameraOpen = true
                } label: {
                    Image(systemName: "camera")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Take a photo")
            }

            Button {
                Haptics.tap()
                Task { await parse() }
            } label: {
                Group {
                    if busy {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            ParsingPhrases()
                        }
                    } else {
                        Text("Add")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(busy || !canParse)
            .animation(.snappy, value: busy)
        }
        .controlSize(.large)

        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
        }

        Button {
            Haptics.tap()
            let blank = Item()
            blank.kind = Item.Kind.place
            withAnimation(.snappy) {
                draft = blank
                editing = true
                manual = true
            }
        } label: {
            Text("or start with a blank card")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private func attachedThumbnail(_ image: UIImage) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Screenshot attached")
                    .font(.subheadline.weight(.medium))
                Text("The parser will read it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.snappy) {
                    imageJPEG = nil
                    photoItem = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16, style: .continuous))
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }

    // MARK: - Stage 2: preview / edit

    @ViewBuilder
    private func previewStage(_ draft: Item) -> some View {
        // While editing, the form IS the preview — showing the card too
        // just duplicates (or, for a blank card, embarrasses) it.
        if !editing {
            Label(
                draft.isPlace ? "Looks like a place" : "Looks like an event",
                systemImage: draft.isPlace ? "mappin.and.ellipse" : "ticket"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)

            if let image = draft.imageUrl.flatMap(URL.init(string:)) {
                ItemImage(url: image, height: 150)
            }

            ItemCard(item: draft)
        }

        if editing {
            ItemForm(item: draft)
                .transition(.opacity)
        }

        // The parser may land on a URL we already have (e.g. after
        // redirects) — flag it, but leave the decision to the user.
        if !saved && duplicate(of: draft.url) != nil {
            Label("Looks like this one's already in your library.", systemImage: "books.vertical")
                .font(.footnote)
                .foregroundStyle(.orange)
        }

        VStack(spacing: 10) {
            Button {
                save(draft)
            } label: {
                Label(saved ? "Saved" : "Save to library", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(draft.accentColor)
            .controlSize(.large)
            .disabled(saved || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            .overlay {
                ConfettiBurst(color: draft.accentColor, fire: $confetti)
            }

            if !saved {
                HStack(spacing: 10) {
                    // A blank card is always in edit mode — no toggle.
                    if !manual {
                        Button {
                            Haptics.tap()
                            withAnimation(.snappy) { editing.toggle() }
                        } label: {
                            Label(editing ? "Show card" : "Edit first", systemImage: editing ? "rectangle.on.rectangle" : "pencil")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }

                    Button(role: .destructive) {
                        Haptics.tap()
                        withAnimation(.snappy) {
                            self.draft = nil
                            editing = false
                            manual = false
                        }
                    } label: {
                        Label("Discard", systemImage: "trash")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    /// First linked URL in the input, for the pre-parse duplicate check.
    private func firstURL(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url?.absoluteString
    }

    private func duplicate(of url: String?) -> Item? {
        guard let url, !url.isEmpty else { return nil }
        let target = SavedURLIndex.normalize(url)
        let all = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        return all.first { $0.url.map(SavedURLIndex.normalize) == target }
    }

    private func parse() async {
        busy = true
        errorMessage = nil
        inputFocused = false
        defer { busy = false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Known URL? Skip the whole parse — nothing new to learn.
        if let existing = duplicate(of: firstURL(in: trimmed)) {
            errorMessage = "Already in your library as \u{201c}\(existing.title)\u{201d}."
            return
        }
        do {
            let card = try await ParseClient.parse(
                text: trimmed.isEmpty ? nil : trimmed,
                imageJPEG: imageJPEG
            )
            let item = Item()
            item.kind = card.kind
            item.title = card.title
            item.summary = card.summary
            item.venue = card.venue
            item.area = card.area
            item.address = card.address
            item.category = card.category
            item.price = card.price
            item.startsOn = card.starts_on
            item.endsOn = card.ends_on
            item.url = card.url
            item.lat = card.lat
            item.lng = card.lng
            item.colorHex = card.color
            item.imageUrl = card.image_url
            withAnimation(.spring(duration: 0.4)) { draft = item }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ item: Item) {
        item.createdAt = .now
        item.updatedAt = .now
        context.insert(item)
        try? context.save()
        Task { await SupabaseSync.announceSave(item) }
        saved = true
        confetti = true
        Task {
            try? await Task.sleep(for: .seconds(0.75))
            dismiss()
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else { return }
        withAnimation(.snappy) {
            imageJPEG = image.compressedForUpload()
        }
    }
}

// MARK: - Camera

/// System camera, feeding the same attachment slot as the photo picker.
private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Image compression

extension UIImage {
    /// Same recipe as the web app: cap the long edge at 2000px, JPEG 0.85 —
    /// keeps phone screenshots under the parse endpoint's limits.
    func compressedForUpload(maxEdge: CGFloat = 2000) -> Data? {
        let longest = max(size.width, size.height)
        guard longest > maxEdge else { return jpegData(compressionQuality: 0.85) }
        let scale = maxEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
