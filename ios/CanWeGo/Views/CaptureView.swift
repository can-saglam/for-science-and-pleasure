import ImageIO
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
    @State private var imageJPEG: Data?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var tooVague = false

    /// Unsaved model object; only inserted into the store on "Save".
    @State private var draft: Item?
    @State private var editing = false
    /// True when the card was started blank — no parser involved.
    @State private var manual = false
    @State private var saved = false
    /// A save already in the library that the input points at — shown as a
    /// notice with a way to open it, never as a wall. "Save anyway" sets the
    /// override and the same input parses through.
    @State private var existing: Item?
    @State private var saveAnyway = false
    /// The input stage hugs its content — title plus composer, plus the
    /// error or duplicate notice when there is one — instead of sitting at
    /// half height over empty space. The card preview gets the full sheet.
    @State private var detent: PresentationDetent = .medium
    @State private var headerHeight: CGFloat = 0
    @State private var inputHeight: CGFloat = 0
    @State private var confirmDiscard = false
    /// Set when Save meets a full category: the card stays, Plus is offered.
    @State private var paywall: PlusReason?
    /// The on-device model's quick read, shown while the parser works.
    @State private var firstLook: Item?
    /// Set while the parser reads (and kept once its card is in): what it
    /// was sent. The input stage gives way to the capture drawer.
    @State private var reading: CaptureInput?
    /// The phone's own preview of the link, while the parser reads.
    @State private var peek: LinkPeek?
    @State private var parseTask: Task<Void, Never>?
    @State private var peekTask: Task<Void, Never>?
    /// The last parse failed for want of a connection.
    @State private var offline = false
    @State private var sync = SyncStatus.shared
    /// Making the on-device draft for an offline save.
    @State private var savingOffline = false
    /// What the duplicate checks compare against. Read on opening and after
    /// each parse, not per render: the card's check runs on every keystroke.
    @State private var library: [Item] = []

    private var inputDetent: PresentationDetent {
        guard inputHeight > 0 else { return .medium }
        return .height(headerHeight + inputHeight)
    }

    private var canParse: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageJPEG != nil
    }

    /// Known offline before sending, or found out by a send that failed.
    private var offlineMode: Bool { offline || !sync.online }

    /// The parser's wait and its card share one drawer, photo edge to edge;
    /// editing (and the blank card) keep the plain sheet and its form.
    private var showsDrawer: Bool { (reading != nil || draft != nil) && !editing && !manual }

    /// Past the input stage: the sheet stays at full height.
    private var expanded: Bool { reading != nil || draft != nil }

    private var reveal: Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .spring(duration: 0.45)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if showsDrawer {
                    CaptureDrawer(draft: draft, look: firstLook, peek: peek, input: reading ?? .text) {
                        if let draft {
                            VStack(alignment: .leading, spacing: 18) {
                                previewStage(draft)
                            }
                        }
                    }
                    .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        if let draft {
                            previewStage(draft)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                        } else {
                            inputStage
                        }
                    }
                    .padding(20)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        // Only the input stage drives the small detent; the
                        // drawer and the form go to .large regardless.
                        guard !expanded else { return }
                        inputHeight = height
                    }
                }
            }
            // The drawer's photo runs edge to edge under the close button.
            .ignoresSafeArea(edges: showsDrawer ? .top : [])
            .scrollDismissesKeyboard(.interactively)
            // The header lives in the top safe-area inset, so its height
            // shows up here rather than in the content above.
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { height in
                guard !showsDrawer else { return }
                headerHeight = height
            }
            .sheetTitle(
                showsDrawer ? nil : (draft == nil ? Voice.whereGoing : (manual ? "Add your own" : "Looks right?"))
            ) {
                dismiss()
            }
            // The wash at the top: a faint breath of ink while the parser
            // reads, which turns into the card's own colour as it lands —
            // the sheet takes the save's colour a beat before the card.
            .background(alignment: .top) {
                let tint = draft?.accentColor ?? AppBackground.ink
                let strength: Double = draft != nil ? 0.25 : (busy ? 0.09 : 0)
                LinearGradient(
                    colors: [tint.opacity(strength), tint.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: draft != nil ? 0.8 : 0.4), value: draft?.id)
                .animation(.easeInOut(duration: 0.4), value: busy)
            }
            .background { ThemeFill(color: AppBackground.sheet) }
        }
        .presentationDetents([inputDetent, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(AppBackground.sheet)
        .sensoryFeedback(.success, trigger: saved) { _, new in new }
        .onChange(of: expanded) { _, isExpanded in
            withAnimation(.snappy) { detent = isExpanded ? .large : inputDetent }
        }
        // The measured height settles a frame or two after the sheet
        // appears (and moves when a notice comes or goes): follow it.
        .onChange(of: inputDetent) { _, now in
            guard !expanded else { return }
            withAnimation(.snappy) { detent = now }
        }
        // Closing mid-read stops the parse and the link preview with it.
        .onDisappear {
            parseTask?.cancel()
            peekTask?.cancel()
        }
        .onAppear {
            loadLibrary()
            // A picture from Visual Intelligence is read straight away.
            if imageJPEG == nil, draft == nil, let picture = CaptureGate.take() {
                imageJPEG = picture
                startParse()
            }
            // So is a suggestion chip's link.
            if text.isEmpty, imageJPEG == nil, draft == nil, let link = CaptureGate.takeLink() {
                text = link
                startParse()
            }
            // CWG_BLANK is only set by automated screenshot runs; it jumps
            // straight to the blank-card edit stage.
            if ProcessInfo.processInfo.environment["CWG_BLANK"] != nil, draft == nil {
                startManual()
            }
            // CWG_OFFLINE (screenshot runs): the offline composer, typed into.
            if let typed = ProcessInfo.processInfo.environment["CWG_OFFLINE"] {
                text = typed
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    offline = true
                }
            }
            // CWG_DUPE (screenshot runs): type in a link already in the
            // library and send it, to photograph the duplicate notice.
            if ProcessInfo.processInfo.environment["CWG_DUPE"] != nil,
               let url = library.compactMap(\.url).first {
                text = url
                startParse()
            }
        }
        // A changed input is a new question; the old duplicate verdict goes.
        .onChange(of: text) { _, _ in
            existing = nil
            saveAnyway = false
            forgetFirstLook()
        }
        .onChange(of: imageJPEG) { _, _ in forgetFirstLook() }
        // Back online mid-draft: the button goes back to reading it now.
        .onChange(of: sync.online) { _, online in
            guard online, offline, !saved, !savingOffline else { return }
            withAnimation(.snappy) {
                offline = false
                firstLook = nil
                errorMessage = nil
            }
        }
        .sheet(item: $paywall) { reason in
            PlusPaywall(reason: reason) {
                if let draft { commit(draft) }
            }
        }
    }

    // MARK: - Stage 1: input

    @ViewBuilder
    private var inputStage: some View {
        // The shared composer (also the first-run's save page), here with
        // the blank-card tool next to the photo and camera buttons.
        Composer(
            text: $text, imageJPEG: $imageJPEG,
            busy: busy || savingOffline, offline: offlineMode, onManual: startManual
        ) {
            if offlineMode {
                Task { await saveOffline() }
            } else {
                startParse()
            }
        }

        // Offline is said once, under the field, and the field's own button
        // becomes Save — no second copy of the input.
        if offlineMode {
            Label(
                saved ? "Saved. It'll be finished when you're back online." : "You're offline. Save it now and it'll be finished when you're back.",
                systemImage: saved ? "checkmark" : "wifi.slash"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .contentTransition(.opacity)
            .transition(.opacity)
        }

        if tooVague, !offlineMode {
            SearchNote()
        }

        if let errorMessage, !offlineMode, !tooVague {
            // The input is still in the field above — nothing is lost — so
            // the way forward is one tap, not a re-paste.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(AppBackground.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canParse {
                    Button("Try again") {
                        Haptics.tap()
                        startParse()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 12, style: .continuous))
        }

        if let existing {
            duplicateNotice(existing) {
                saveAnyway = true
                self.existing = nil
                startParse()
            }
            .transition(.opacity)
        }
    }

    /// With the phone's quick read, the save goes into the library now and
    /// is finished later; without one (no Apple Intelligence, or nothing
    /// it could stand behind) the input waits and is looked up later.
    private func saveOffline() async {
        guard canParse, !saved, !savingOffline else { return }
        savingOffline = true
        defer { savingOffline = false }
        let look: Item? = if let firstLook {
            firstLook
        } else {
            await InstantDraft.make(text: trimmedText, imageJPEG: imageJPEG)?.item
        }
        if let look { saveDraft(look) } else { saveForLater() }
    }

    private func saveDraft(_ look: Item) {
        OfflineDrafts.enqueue(id: look.id, text: trimmedText, imageJPEG: imageJPEG, inLibrary: true)
        save(look)
    }

    private func saveForLater() {
        OfflineDrafts.enqueue(id: UUID(), text: trimmedText, imageJPEG: imageJPEG, inLibrary: false)
        Haptics.success()
        withAnimation(.easeInOut(duration: 0.25)) { saved = true }
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            dismiss()
        }
    }

    /// A changed input makes the quick read (and the offline offer) stale.
    private func forgetFirstLook() {
        guard !busy, firstLook != nil || offline else { return }
        withAnimation(.snappy) {
            firstLook = nil
            offline = false
        }
    }

    private var trimmedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Skip the parser: a blank card straight into the form.
    private func startManual() {
        let blank = Item()
        blank.kind = Item.Kind.place
        blank.source = "manual"
        withAnimation(.snappy) {
            draft = blank
            editing = true
            manual = true
        }
    }

    /// Back from the blank card to the composer. Whatever was typed in
    /// the field before is still there.
    private func leaveManual() {
        withAnimation(.snappy) {
            draft = nil
            editing = false
            manual = false
        }
    }

    // MARK: - Stage 2: preview / edit

    @ViewBuilder
    private func previewStage(_ draft: Item) -> some View {
        // Reading, this sits under the drawer's header, which is the
        // card; editing, the form is the preview and the header steps out.
        if editing {
            ItemForm(item: draft)
                .transition(.opacity)
        } else {
            RemindRow(item: draft)
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
           let day = (draft.endsOn ?? draft.startsOn).flatMap({ DayString.text($0) }) {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "This happened on \(day). Add it to \(Voice.didGoSection) instead?",
                    systemImage: "checkmark.seal"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

                Button {
                    draft.status = Item.Status.done
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

        VStack(spacing: 10) {
            Button {
                save(draft)
            } label: {
                SaveMorphLabel("Save to library", systemImage: "checkmark", saved: saved)
            }
            .prominentGlass()
            .controlSize(.large)
            .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            // Not `.disabled`: that would grey the button out under "Saved".
            .allowsHitTesting(!saved)

            if !saved, !draft.isDone, let full = CategoryCap.overflow(draft, context: context) {
                Label(
                    "\(CategoryCap.plural(full)) already has \(CategoryCap.limit) coming up. Saving this one needs Plus, or a different category.",
                    systemImage: "lock"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !saved, manual {
                // A blank card is always in edit mode and the × already
                // throws it away, so the one secondary action is the way
                // back to the composer.
                Button {
                    Haptics.tap()
                    leaveManual()
                } label: {
                    Label("Look it up instead", systemImage: "sparkle.magnifyingglass")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            } else if !saved {
                HStack(spacing: 10) {
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy) { editing.toggle() }
                    } label: {
                        Label(editing ? "Show card" : "Edit first", systemImage: editing ? "rectangle.on.rectangle" : "pencil")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    Button(role: .destructive) {
                        Haptics.tap()
                        confirmDiscard = true
                    } label: {
                        Label("Discard", systemImage: "trash")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .confirmationDialog(
                        "Discard this save?",
                        isPresented: $confirmDiscard,
                        titleVisibility: .visible
                    ) {
                        Button("Discard", role: .destructive) {
                            withAnimation(.snappy) {
                                self.draft = nil
                                reading = nil
                                peek = nil
                                editing = false
                                manual = false
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The card goes away. Nothing is saved.")
                    }
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

    private func loadLibrary() {
        library = (try? context.fetch(FetchDescriptor<Item>())) ?? []
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
            Label(DuplicateFinder.describe(twin), systemImage: "books.vertical")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppBackground.warning)

            // The card itself, as it sits in the library: "already saved"
            // is obvious at a glance, and a tap opens it.
            Button {
                Haptics.tap()
                openExisting(twin)
            } label: {
                ItemCard(item: twin, compact: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(twin.title)")

            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    openExisting(twin)
                } label: {
                    Label("Open it", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .prominentGlass()

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
        .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 12, style: .continuous))
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

    /// Every way into a parse goes through here, so closing the sheet can
    /// stop the one in flight.
    private func startParse() {
        parseTask?.cancel()
        parseTask = Task { await parse() }
    }

    private func parse() async {
        busy = true
        errorMessage = nil
        tooVague = false
        offline = false
        firstLook = nil
        defer { busy = false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Known URL? Say so before spending a parse — unless they've already
        // chosen to save it anyway.
        loadLibrary()
        if !saveAnyway, let twin = duplicate(of: firstURL(in: trimmed)) {
            withAnimation(.snappy) { existing = twin }
            return
        }
        withAnimation(reveal) {
            peek = nil
            reading = CaptureInput(text: trimmed, hasImage: imageJPEG != nil)
        }
        // A screenshot's picture only ever comes from the parser; a link
        // gets the phone's own preview in the meantime.
        peekTask?.cancel()
        if imageJPEG == nil, let url = LinkPeek.firstURL(in: trimmed) {
            peekTask = Task {
                guard let found = await LinkPeek.fetch(url), !Task.isCancelled, busy, draft == nil else { return }
                withAnimation(reveal) { peek = found }
            }
        }
        let look = Task { await InstantDraft.make(text: trimmed, imageJPEG: imageJPEG) }
        Task {
            guard let quick = await look.value, busy, draft == nil else { return }
            withAnimation(reveal) { firstLook = quick.item }
        }
        defer {
            look.cancel()
            peekTask?.cancel()
        }
        do {
            let card = try await ParseClient.parse(
                text: trimmed.isEmpty ? nil : trimmed,
                imageJPEG: imageJPEG
            )
            guard !Task.isCancelled else { return }
            // The card's photo lands with the card when it can.
            if let url = card.image_url.flatMap(URL.init(string:)) {
                await ImageStore.warm(url, variant: .hero, limit: .milliseconds(900))
            }
            firstLook = nil
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
            item.source = card.source
            item.placeId = card.place_id
            // A partner's save may have synced in while the parser worked.
            loadLibrary()
            withAnimation(reveal) { draft = item }
        } catch {
            guard !Task.isCancelled else { return }
            // Back to the composer, the input still in it.
            withAnimation(reveal) {
                reading = nil
                peek = nil
            }
            // ParseError already speaks to a person; everything else
            // (URLError, decoding) gets the same translation sync uses.
            errorMessage = (error as? ParseClient.ParseError)?.errorDescription ?? SyncProblem(error).message
            if case ParseClient.ParseError.tooVague = error { tooVague = true }
            if OfflineDrafts.isOffline(error) {
                // No connection fails fast, usually before the quick read
                // is back: wait for it, it's what gets saved.
                let quick = await look.value
                withAnimation(.snappy) {
                    firstLook = quick?.item
                    offline = true
                }
            } else {
                firstLook = nil
            }
        }
    }

    /// Parse first, paywall second: the finished card is on screen when a
    /// full category is mentioned, and it saves itself once Plus lands.
    private func save(_ item: Item) {
        if !item.isDone, let full = CategoryCap.overflow(item, context: context) {
            Haptics.tap()
            paywall = .category(full)
            return
        }
        commit(item)
    }

    private func commit(_ item: Item) {
        item.createdAt = .now
        item.updatedAt = .now
        item.stampAuthor()
        context.insert(item)
        try? context.save()
        Task { await SupabaseSync.announceSave(item) }
        Haptics.success()
        withAnimation(.easeInOut(duration: 0.25)) { saved = true }
        UndoBin.shared.stashSaved(item)
        // Long enough to read "Saved", short enough not to feel like a wait.
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            dismiss()
        }
    }
}

/// A search instead of a save is a nudge, not a fault: no warning colours,
/// and no retry, since the same words get the same answer.
private struct SearchNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(AppBackground.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("That\u{2019}s a search, not a save")
                    .font(.displaySmall(18, relativeTo: .headline))
                    .foregroundStyle(AppBackground.ink)
                Text("Name one place or show, or paste a link to it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
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

extension Data {
    /// The same upload JPEG, read from an image file's bytes at the target
    /// size: ImageIO decodes straight to 2000 px, so a 48 MP photo never
    /// sits in memory whole (the share extension can't hold one).
    func compressedImageForUpload(maxEdge: CGFloat = 2000) -> Data? {
        guard let source = CGImageSourceCreateWithData(self as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxEdge,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image).compressedForUpload(maxEdge: maxEdge)
    }
}
