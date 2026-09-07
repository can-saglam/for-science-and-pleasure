import PhotosUI
import SwiftData
import SwiftUI

/// Add something: paste a link / describe it / attach a screenshot, let the
/// parser read it, preview the card, then save — or start from a blank card.
/// Mirrors the web app's three-stage capture flow.
struct CaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var imageJPEG: Data?
    @State private var cameraOpen = false
    @State private var busy = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    /// Unsaved model object; only inserted into the store on "Save".
    @State private var draft: Item?
    @State private var editing = false
    /// True when the card was started blank — no parser involved.
    @State private var manual = false
    @State private var confetti = false
    @State private var saved = false
    /// A save already in the library that the input points at — shown as a
    /// notice with a way to open it, never as a wall. "Save anyway" sets the
    /// override and the same input parses through.
    @State private var existing: Item?
    @State private var saveAnyway = false
    /// Half height for the one-field input stage; the card preview gets the
    /// full sheet.
    @State private var detent: PresentationDetent = .medium

    private var canParse: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageJPEG != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let draft {
                        previewStage(draft)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
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
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.success, trigger: saved) { _, new in new }
        .onChange(of: draft != nil) { _, hasDraft in
            withAnimation(.snappy) { detent = hasDraft ? .large : .medium }
        }
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
            // CWG_DUPE (screenshot runs): type in a link already in the
            // library and send it, to photograph the duplicate notice.
            if ProcessInfo.processInfo.environment["CWG_DUPE"] != nil,
               let url = library.compactMap(\.url).first {
                text = url
                Task { await parse() }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        // A changed input is a new question; the old duplicate verdict goes.
        .onChange(of: text) { _, _ in
            existing = nil
            saveAnyway = false
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
        // One composer, AI-app style: the field on top, attachments in the
        // middle, and a tool row along the bottom — gallery and camera on
        // the left, the round send button on the right.
        VStack(alignment: .leading, spacing: 0) {
            TextField(
                "An exhibition, a restaurant, a link…",
                text: $text,
                axis: .vertical
            )
            .lineLimit(3...8)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let image = imageJPEG.flatMap(UIImage.init(data:)) {
                attachedThumbnail(image)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            HStack(spacing: 8) {
                if busy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        ParsingPhrases()
                    }
                    .padding(.leading, 6)
                } else {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        composerIcon("photo")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attach a photo")

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            Haptics.tap()
                            cameraOpen = true
                        } label: {
                            composerIcon("camera")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Take a photo")
                    }
                }

                Spacer(minLength: 8)

                Button {
                    Haptics.tap()
                    Task { await parse() }
                } label: {
                    Group {
                        if busy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .foregroundStyle(
                        canParse && !busy
                            ? AnyShapeStyle(AppBackground.base)
                            : AnyShapeStyle(.white.opacity(0.55))
                    )
                    .background(
                        Circle().fill(.white.opacity(canParse && !busy ? 0.92 : 0.16))
                    )
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(busy || !canParse)
                .accessibilityLabel("Add")
            }
            .padding(10)
            .animation(.snappy, value: busy)
        }
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    .white.opacity(inputFocused ? 0.22 : 0.10),
                    lineWidth: 1
                )
        )
        // Anywhere on the composer counts as the field. No auto-focus on
        // appear: the keyboard would shove the sheet to full height, and the
        // half-open drawer is the point.
        .contentShape(.rect(cornerRadius: 24, style: .continuous))
        .onTapGesture { inputFocused = true }
        .animation(.snappy, value: inputFocused)

        if let errorMessage {
            // The input is still in the field above — nothing is lost — so
            // the way forward is one tap, not a re-paste.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canParse {
                    Button("Try again") {
                        Haptics.tap()
                        Task { await parse() }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
        }

        if let existing {
            duplicateNotice(existing) {
                saveAnyway = true
                self.existing = nil
                Task { await parse() }
            }
            .transition(.opacity)
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
            Label("Add it manually", systemImage: "square.and.pencil")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .padding(.top, 2)
    }

    /// Small round tool button in the composer's bottom row.
    private func composerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 34, height: 34)
            .background(.white.opacity(0.10), in: .circle)
            .contentShape(.circle)
    }

    /// Just the picture with a small × on its corner — the way AI composers
    /// show attachments. It speaks for itself; no caption needed.
    private func attachedThumbnail(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.snappy) {
                        imageJPEG = nil
                        photoItem = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.black.opacity(0.55), in: .circle)
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
            // Keep the × tappable where it pokes past the picture's corner.
            .padding(.top, 6)
            .padding(.trailing, 6)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
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

            // The card already wears its thumbnail — a hero image above it
            // just showed the same picture twice.
            ItemCard(item: draft)
        }

        if editing {
            ItemForm(item: draft)
                .transition(.opacity)
        }

        // The parser may land on something we already have — the same URL
        // after redirects, or the same gig from a different ticket site.
        // Flag it with a way to the original; the Save button below is the
        // "save anyway".
        if !saved, !saveAnyway, let twin = duplicate(ofCard: draft) {
            duplicateNotice(twin, saveAnyway: nil)
        }

        // An event that's already happened would land straight in "Ended".
        // Chances are they're logging a night out — offer the journal.
        if !saved, draft.isEvent, draft.timeBucket == .past,
           let day = (draft.endsOn ?? draft.startsOn).flatMap(DayString.date) {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "This happened on \(day.formatted(.dateTime.day().month(.abbreviated))). Add it to We Did Go instead?",
                    systemImage: "checkmark.seal"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

                Button {
                    draft.status = Item.Status.done
                    save(draft)
                } label: {
                    Label("We did go!", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
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
            // Neutral white, not the item's extracted accent: murky source
            // colors (olive posters…) made the main CTA read as disabled.
            .tint(.white.opacity(0.92))
            .foregroundStyle(AppBackground.base)
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
                // Match the save button's height so the stack reads as one set.
                .controlSize(.large)
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

    private var library: [Item] {
        (try? context.fetch(FetchDescriptor<Item>())) ?? []
    }

    private func duplicate(of url: String?) -> Item? {
        DuplicateFinder.match(url: url, title: nil, startsOn: nil, kind: nil, in: library)
    }

    private func duplicate(ofCard card: Item) -> Item? {
        DuplicateFinder.match(
            url: card.url, title: card.title, startsOn: card.startsOn, kind: card.kind,
            in: library.filter { $0 !== card }
        )
    }

    /// "Joyce saved this 2 weeks ago" with a way to the original. Warn, don't
    /// block: the pair may genuinely want two entries.
    private func duplicateNotice(_ twin: Item, saveAnyway: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DuplicateFinder.describe(twin))
                        .font(.footnote.weight(.semibold))
                    Text("\u{201c}\(twin.title)\u{201d}")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "books.vertical")
            }
            .foregroundStyle(.orange)

            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    openExisting(twin)
                } label: {
                    Label("Open it", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.white.opacity(0.92))
                .foregroundStyle(AppBackground.base)

                if let saveAnyway {
                    Button {
                        Haptics.tap()
                        saveAnyway()
                    } label: {
                        Label("Save anyway", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
    }

    /// Close the composer and bring up the original — the same route a
    /// tapped notification takes.
    private func openExisting(_ twin: Item) {
        let id = twin.id
        dismiss()
        Task {
            try? await Task.sleep(for: .seconds(0.4))
            NotificationCenter.default.post(name: .cwgOpenItem, object: id)
        }
    }

    private func parse() async {
        busy = true
        errorMessage = nil
        inputFocused = false
        defer { busy = false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Known URL? Say so before spending a parse — unless they've already
        // chosen to save it anyway.
        if !saveAnyway, let twin = duplicate(of: firstURL(in: trimmed)) {
            withAnimation(.snappy) { existing = twin }
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
            // ParseError already speaks to a person; everything else
            // (URLError, decoding) gets the same translation sync uses.
            errorMessage = (error as? ParseClient.ParseError)?.errorDescription ?? SyncProblem(error).message
        }
    }

    private func save(_ item: Item) {
        item.createdAt = .now
        item.updatedAt = .now
        item.addedByEmail = SupabaseAuth.shared.email
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
    /// keeps camera shots and screenshots under the parse endpoint's 4 MB.
    ///
    /// Everything is computed in pixels with an explicit 1× renderer scale:
    /// the default renderer format uses the screen scale (3× on iPhone),
    /// which silently *tripled* the output and made camera photos too big.
    func compressedForUpload(maxEdge: CGFloat = 2000) -> Data? {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let ratio = min(1, maxEdge / max(pixelSize.width, pixelSize.height))
        let target = CGSize(width: pixelSize.width * ratio, height: pixelSize.height * ratio)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }

        // Belt and braces: dense photos can still overshoot at 0.85 —
        // step the quality down before giving the data back.
        var quality: CGFloat = 0.85
        var data = resized.jpegData(compressionQuality: quality)
        while let bytes = data?.count, bytes > 3_500_000, quality > 0.4 {
            quality -= 0.15
            data = resized.jpegData(compressionQuality: quality)
        }
        return data
    }
}
