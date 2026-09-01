import SwiftUI
import UniformTypeIdentifiers

/// The share sheet flow: read whatever was shared (link, text, image),
/// run it through the parser, show the card, save on confirmation.
/// Saves land in the App Group inbox; the app imports them on next open.
struct ShareView: View {
    let extensionContext: NSExtensionContext?
    let complete: () -> Void
    let cancel: () -> Void

    private enum Stage {
        case reading
        case parsing
        case preview(Item)
        case duplicate
        case failed(String, retryText: String?)
        case saved
    }

    @State private var stage: Stage = .reading
    @State private var payloadText: String?
    @State private var payloadImage: Data?
    @State private var extractedURL: String?
    @State private var editing = false

    private var isPreview: Bool {
        if case .preview = stage { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Mirrors the in-app capture flow's preview title.
            .navigationTitle(isPreview ? "Looks right?" : "Can We Go?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        cancel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .background(alignment: .top) {
                if case .preview(let draft) = stage {
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
        .tint(AppBackground.accent)
        .preferredColorScheme(.dark)
        .task { await run() }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .reading, .parsing:
            ParsingIndicator()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 64)

        case .preview(let draft):
            // Same shape as the in-app capture preview: the card wears its
            // own thumbnail, so no hero image; while editing, the form IS
            // the preview.
            if !editing {
                Label(
                    draft.isPlace ? "Looks like a place" : "Looks like an event",
                    systemImage: draft.isPlace ? "mappin.and.ellipse" : "ticket"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

                ItemCard(item: draft)
            } else {
                ItemForm(item: draft)
                    .transition(.opacity)
            }

            VStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    save(draft)
                } label: {
                    Label("Save to library", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                // Neutral white, matching the in-app flow — murky extracted
                // accents made the main CTA read as disabled.
                .tint(.white.opacity(0.92))
                .foregroundStyle(AppBackground.base)
                .controlSize(.large)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)

                HStack(spacing: 10) {
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy) { editing.toggle() }
                    } label: {
                        Label(
                            editing ? "Show card" : "Edit first",
                            systemImage: editing ? "rectangle.on.rectangle" : "pencil"
                        )
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    // No input stage to fall back to here — the content came
                    // from the share itself, so discarding closes the sheet.
                    Button(role: .destructive) {
                        Haptics.tap()
                        cancel()
                    } label: {
                        Label("Discard", systemImage: "trash")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
            .padding(.top, 4)

            Text("It'll appear in the app the next time you open it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

        case .duplicate:
            VStack(spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                Text("Already in your library")
                    .font(.headline)
                Text("You saved this link before.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    Haptics.tap()
                    Task { await parse() }
                } label: {
                    Text("Save again anyway")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.glass)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)

        case .failed(let message, let retryText):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))

            if let retryText {
                // Parse failed (offline, blocked page…): keep the raw share
                // so nothing is lost — it can be tidied up in the app.
                Button {
                    saveRaw(retryText)
                } label: {
                    Label("Save it anyway", systemImage: "tray.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppBackground.base)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.white)
                .controlSize(.large)
            }

        case .saved:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: true)
                Text("Saved")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        }
    }

    // MARK: - Pipeline

    private func run() async {
        await loadAttachments()
        guard payloadText != nil || payloadImage != nil else {
            stage = .failed("Nothing shareable found.", retryText: nil)
            return
        }
        // The app mirrors saved URLs into the App Group for exactly this.
        if SavedURLIndex.contains(extractedURL) {
            withAnimation(.snappy) { stage = .duplicate }
            return
        }
        await parse()
    }

    private func parse() async {
        stage = .parsing
        editing = false
        do {
            let card = try await ParseClient.parse(text: payloadText, imageJPEG: payloadImage)
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
            item.url = card.url ?? extractedURL
            item.lat = card.lat
            item.lng = card.lng
            item.colorHex = card.color
            item.imageUrl = card.image_url
            withAnimation(.snappy) { stage = .preview(item) }
        } catch {
            stage = .failed(error.localizedDescription, retryText: payloadText)
        }
    }

    private func loadAttachments() async {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        var textParts: [String] = []

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = await loadURL(from: provider),
               !url.isFileURL {
                extractedURL = url.absoluteString
                textParts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                payloadImage = await loadImage(from: provider)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = await loadText(from: provider) {
                textParts.append(text)
            }
        }

        let joined = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        payloadText = joined.isEmpty ? nil : joined
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                if let text = item as? String {
                    cont.resume(returning: text)
                } else if let data = item as? Data {
                    cont.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadImage(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                let image: UIImage? =
                    if let ui = item as? UIImage {
                        ui
                    } else if let url = item as? URL, let data = try? Data(contentsOf: url) {
                        UIImage(data: data)
                    } else if let data = item as? Data {
                        UIImage(data: data)
                    } else {
                        nil
                    }
                cont.resume(returning: image?.compressedForUpload())
            }
        }
    }

    // MARK: - Saving

    private func save(_ item: Item) {
        var pending = SharedInbox.PendingSave(kind: item.kind, title: item.title)
        pending.summary = item.summary
        pending.venue = item.venue
        pending.area = item.area
        pending.address = item.address
        pending.category = item.category
        pending.price = item.price
        pending.startsOn = item.startsOn
        pending.endsOn = item.endsOn
        pending.url = item.url
        pending.lat = item.lat
        pending.lng = item.lng
        pending.colorHex = item.colorHex
        pending.imageUrl = item.imageUrl
        finish(pending)
    }

    private func saveRaw(_ text: String) {
        var pending = SharedInbox.PendingSave(
            kind: Item.Kind.event,
            title: String(text.prefix(120))
        )
        pending.url = extractedURL
        pending.notes = "Saved from the share sheet, needs a tidy-up."
        finish(pending)
    }

    private func finish(_ pending: SharedInbox.PendingSave) {
        do {
            try SharedInbox.write(pending)
            Haptics.success()
            withAnimation(.snappy) { stage = .saved }
            Task {
                try? await Task.sleep(for: .seconds(0.7))
                complete()
            }
        } catch {
            stage = .failed(error.localizedDescription, retryText: nil)
        }
    }
}
