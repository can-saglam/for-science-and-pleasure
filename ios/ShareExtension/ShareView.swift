import SwiftUI
import UniformTypeIdentifiers

/// The share sheet flow: read whatever was shared (link, text, image),
/// look it up straight away, and show the card to confirm. Only members
/// get that far — signed out, nothing leaves the phone. Saves land in the
/// App Group inbox; the app imports them on next open.
struct ShareView: View {
    let extensionContext: NSExtensionContext?
    let complete: () -> Void
    let cancel: () -> Void

    private enum Stage {
        case reading
        case signedOut
        case parsing
        case preview(Item)
        case duplicate
        case failed(String, retryText: String?)
    }

    @State private var stage: Stage = .reading
    @State private var payloadText: String?
    @State private var payloadImage: Data?
    @State private var extractedURL: String?
    @State private var editing = false
    /// Set on save: the CTA's label crossfades to "Saved" and the sheet
    /// closes a beat later. The card stays where it is — no separate
    /// success screen.
    @State private var saved = false
    @State private var confirmDiscard = false
    @State private var saveAnyway = false
    /// The phone's own preview of a shared link, while the parser reads.
    @State private var peek: LinkPeek?
    @State private var peekTask: Task<Void, Never>?
    /// The parser's fields, while its lookups finish the card.
    @State private var early: Item?

    private var isPreview: Bool {
        if case .preview = stage { return true }
        return false
    }

    private var draft: Item? {
        if case .preview(let item) = stage { return item }
        return nil
    }

    /// Mirrors the in-app capture flow: the wait and the card share one
    /// drawer with the photo edge to edge; editing keeps the plain sheet.
    private var showsDrawer: Bool {
        switch stage {
        case .reading, .parsing: true
        case .preview: !editing
        default: false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if showsDrawer {
                    CaptureDrawer(
                        draft: draft,
                        early: early,
                        peek: peek,
                        input: payloadImage != nil ? .image : (extractedURL != nil || payloadText == nil ? .link : .text),
                        showsMap: false,
                        editFirst: { withAnimation(.snappy) { editing = true } }
                    ) {
                        if let draft {
                            VStack(alignment: .leading, spacing: 16) {
                                preview(draft)
                            }
                        }
                    }
                    .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        content
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .ignoresSafeArea(edges: showsDrawer ? .top : [])
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let draft {
                    previewActions(draft)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            // Mirrors the in-app capture flow's preview title.
            .sheetTitle(
                showsDrawer ? nil : (isPreview ? "Looks right?" : "Can We Go?")
            ) {
                cancel()
            }
            .background(alignment: .top) {
                if case .preview(let draft) = stage {
                    LinearGradient(
                        colors: [draft.accentColor.opacity(0.25), draft.accentColor.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 220)
                    .ignoresSafeArea()
                }
            }
            .background { ThemeFill(color: AppBackground.sheet) }
        }
        .tint(AppBackground.accent)
        .appColorScheme()
        .task { await run() }
        .onDisappear { peekTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .reading, .parsing:
            // Shown in the drawer instead.
            EmptyView()

        case .signedOut:
            VStack(alignment: .leading, spacing: 14) {
                Label("Open Can We Go? and sign in", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                Text("The share sheet uses the same sign-in as the app. Nothing is sent anywhere until you are signed in.")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
                Button {
                    Haptics.tap()
                    if let url = URL(string: "canwego://") {
                        extensionContext?.open(url) { _ in complete() }
                    }
                } label: {
                    Label("Open Can We Go?", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .prominentGlass()
                .controlSize(.large)
            }
            .padding(.vertical, 24)

        case .preview(let draft):
            preview(draft)

        case .duplicate:
            duplicateBlock

        case .failed(let message, let retryText):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(AppBackground.warning)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 12, style: .continuous))

            if let retryText {
                // Parse failed (offline, blocked page…): keep the raw share
                // so nothing is lost — it can be tidied up in the app.
                Button {
                    saveRaw(retryText)
                } label: {
                    SaveMorphLabel("Save anyway", systemImage: "tray.and.arrow.down", saved: saved)
                }
                .prominentGlass()
                .controlSize(.large)
                .allowsHitTesting(!saved)
            }
        }
    }

    @ViewBuilder
    private func preview(_ draft: Item) -> some View {
        if !editing {
            RemindRow(item: draft)
        } else {
            ItemForm(item: draft)
                .transition(.opacity)
        }

        if !saved, draft.isEvent, draft.timeBucket == .past,
           let day = (draft.endsOn ?? draft.startsOn).flatMap({ DayString.text($0) }) {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "This happened on \(day). Add it to \(Voice.didGoSection) instead?",
                    systemImage: "checkmark.seal"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppBackground.secondaryInk)

                Button {
                    draft.status = Item.Status.done
                    draft.wentOn = DayString.today()
                    save(draft)
                } label: {
                    Label(Voice.didGoBang, systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppBackground.ink)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 12, style: .continuous))
        }
    }

    /// The card's actions, floating bottom right like the app's.
    private func previewActions(_ draft: Item) -> some View {
        FloatingActions {
            if !saved {
                FloatingCircleButton(
                    editing ? "Show card" : "Edit first",
                    systemImage: editing ? "rectangle.on.rectangle" : "pencil"
                ) {
                    withAnimation(.snappy) { editing.toggle() }
                }
                .contentTransition(.symbolEffect(.replace))

                FloatingCircleButton("Discard", systemImage: "trash", tint: AppBackground.destructive) {
                    confirmDiscard = true
                }
                .confirmationDialog(
                    "Discard this save?",
                    isPresented: $confirmDiscard,
                    titleVisibility: .visible
                ) {
                    Button("Discard", role: .destructive) { cancel() }
                    Button("Keep editing", role: .cancel) {}
                }
            }

            FloatingMainButton(saved ? "Saved" : "Save", systemImage: saved ? "checkmark.circle.fill" : "checkmark") {
                save(draft)
            }
            .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            .allowsHitTesting(!saved)
        }
    }

    private var duplicateBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Already in your library")
                        .font(.footnote.weight(.semibold))
                    Text("One of you saved this link before.")
                        .font(.footnote)
                        .foregroundStyle(AppBackground.secondaryInk)
                }
            } icon: {
                Image(systemName: "books.vertical")
            }
            .foregroundStyle(AppBackground.warning)

            HStack(spacing: 10) {
                if let id = SavedURLIndex.id(for: extractedURL),
                   let url = URL(string: "canwego://item/\(id.uuidString)") {
                    Button {
                        Haptics.tap()
                        extensionContext?.open(url) { _ in complete() }
                    } label: {
                        Label("Open it", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .prominentGlass()
                }

                Button {
                    Haptics.tap()
                    saveAnyway = true
                    Task { await parse() }
                } label: {
                    Label("Save anyway", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 12, style: .continuous))
        .padding(.vertical, 24)
    }

    // MARK: - Pipeline

    private func run() async {
        _ = HomeStore.shared // home clock for the preview card's time label
        guard SupabaseAuth.shared.signedIn else {
            stage = .signedOut
            return
        }
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
        // Straight to the lookup: the whole point of sharing is to get a
        // card back, not a form. The signed-out gate above still means
        // nothing leaves the phone for anyone who isn't a member.
        await parse()
    }

    private func parse() async {
        withAnimation(.snappy) { stage = .parsing }
        editing = false
        early = nil
        peekTask?.cancel()
        if payloadImage == nil, let url = extractedURL.flatMap(URL.init(string:)) {
            peekTask = Task {
                guard let found = await LinkPeek.fetch(url), !Task.isCancelled, !isPreview else { return }
                withAnimation(.spring(duration: 0.45)) { peek = found }
            }
        }
        defer { peekTask?.cancel() }
        do {
            let card = try await ParseClient.parse(text: payloadText, imageJPEG: payloadImage) { fields in
                guard !Task.isCancelled, !isPreview else { return }
                withAnimation(.spring(duration: 0.45)) { early = item(from: fields) }
            }
            // The card's photo lands with the card when it can.
            if let url = card.image_url.flatMap(URL.init(string:)) {
                await ImageStore.warm(url, variant: .hero, limit: .milliseconds(900))
            }
            let item = item(from: card)
            withAnimation(.spring(duration: 0.45)) { stage = .preview(item) }
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) {
                peek = nil
                early = nil
                stage = .failed((error as? ParseClient.ParseError)?.errorDescription ?? SyncProblem(error).message, retryText: payloadText)
            }
        }
    }

    private func item(from card: ParseClient.Card) -> Item {
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
        item.source = card.source
        item.placeId = card.place_id
        item.showings = card.showings ?? []
        return item
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
                let jpeg: Data? =
                    if let ui = item as? UIImage {
                        ui.compressedForUpload()
                    } else if let url = item as? URL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                        data.compressedImageForUpload()
                    } else if let data = item as? Data {
                        data.compressedImageForUpload()
                    } else {
                        nil
                    }
                cont.resume(returning: jpeg)
            }
        }
    }

    // MARK: - Saving

    private func save(_ item: Item) {
        guard SupabaseAuth.shared.signedIn, let userId = SupabaseAuth.shared.userId else {
            stage = .signedOut
            return
        }
        var pending = SharedInbox.PendingSave(item: item, userId: userId)
        pending.allowDuplicate = saveAnyway ? true : nil
        finish(pending)
    }

    private func saveRaw(_ text: String) {
        guard SupabaseAuth.shared.signedIn, let userId = SupabaseAuth.shared.userId else {
            stage = .signedOut
            return
        }
        var pending = SharedInbox.PendingSave(
            kind: Item.Kind.event,
            title: String(text.prefix(120))
        )
        pending.url = extractedURL
        pending.notes = "Saved from the share sheet, needs a tidy-up."
        pending.userId = userId.uuidString
        pending.groupId = GroupStore.shared.card?.groupId.uuidString
        finish(pending)
    }

    private func finish(_ pending: SharedInbox.PendingSave) {
        do {
            try SharedInbox.write(pending)
            Haptics.success()
            withAnimation(.easeInOut(duration: 0.25)) { saved = true }
            Task {
                try? await Task.sleep(for: .seconds(0.6))
                complete()
            }
        } catch {
            stage = .failed((error as? ParseClient.ParseError)?.errorDescription ?? SyncProblem(error).message, retryText: nil)
        }
    }
}
