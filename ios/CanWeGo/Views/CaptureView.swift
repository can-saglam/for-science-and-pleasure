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

    /// What a blank card starts as: the tab Add was tapped from.
    var manualKind: String = Item.Kind.place

    @State private var text = ""
    @State private var imageJPEG: Data?
    @State private var busy = false
    @State private var errorMessage: String?
    /// A parse that came back as a nudge rather than a fault.
    @State private var nudge: CaptureNudge?

    /// Unsaved model object; only inserted into the store on "Save".
    @State private var draft: Item?
    @State private var editing = false
    /// True when the card was started blank — no parser involved.
    @State private var manual = false
    @State private var saved = false
    @State private var confirmDiscard = false
    /// Set when Save meets a full category or a full day: the card stays,
    /// Plus is offered.
    @State private var paywall: PlusReason?
    /// Plus, and today's fifty are in.
    @State private var busyDay = false
    /// The on-device model's quick read, shown while the parser works.
    @State private var firstLook: Item?
    /// The parser's fields, while its lookups finish the card.
    @State private var early: Item?
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
    @State private var suggestions = Suggestions.shared
    /// A tapped recommendation's name, venue and dates, shown in the
    /// drawer while the parser reads its page.
    @State private var pickedLook: Item?
    /// The question and the drawer's title are one thing on screen.
    @Namespace private var titleSpace

    private var canParse: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageJPEG != nil
    }

    /// Known offline before sending, or found out by a send that failed.
    private var offlineMode: Bool { offline || !sync.online }

    /// The parser's wait and its card share one drawer, photo edge to edge;
    /// editing (and the blank card) keep the plain sheet and its form.
    private var showsDrawer: Bool { (reading != nil || draft != nil) && !editing && !manual }

    private var home: HomeStore.Home? { HomeStore.shared.isSet ? HomeStore.shared.home : nil }

    /// Only on an empty page: anything typed or attached is the thing.
    private var recommendations: [ParseClient.Suggestion] {
        guard text.isEmpty, imageJPEG == nil, !offlineMode, let home else { return [] }
        return suggestions.mixed(for: home, excluding: library)
    }

    private var reveal: Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .spring(duration: 0.45)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if showsDrawer {
                    CaptureDrawer(
                        draft: draft, early: early, look: pickedLook ?? firstLook, peek: peek, input: reading ?? .text,
                        notice: draft.flatMap(twin(of:)).map { twin in
                            AnyView(DuplicateStrip(twin: twin, open: { openExisting(twin) }))
                        },
                        editFirst: { withAnimation(.snappy) { editing = true } },
                        typed: reading == .text ? trimmedText : nil,
                        titleSpace: titleSpace,
                        growsIn: true
                    ) {
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
                    // The page clears out quickly so the drawer doesn't
                    // land on top of it; only the title travels.
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity.animation(.easeOut(duration: 0.15))
                    ))
                }
            }
            // The drawer's photo runs edge to edge under the close button.
            .ignoresSafeArea(edges: showsDrawer ? .top : [])
            .scrollDismissesKeyboard(.interactively)
            // The bar and the card's actions take the same strip, so the
            // thumb ends where it started.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let draft {
                    previewActions(draft)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                } else if reading == nil {
                    composerBar
                        .transition(.opacity)
                }
            }
            // The page draws its own question, so it can carry into the
            // drawer's title.
            .sheetTitle(
                showsDrawer || draft == nil ? nil : (manual ? "Add your own" : "Looks right?")
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
        .foregroundStyle(AppBackground.ink)
        .appColorScheme()
        // One height throughout: reading and the card are full height, so
        // the page is too, and nothing jumps on send.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppBackground.sheet)
        // Closing mid-read stops the parse and the link preview with it.
        .onDisappear {
            parseTask?.cancel()
            peekTask?.cancel()
        }
        .onAppear {
            loadLibrary()
            if let home { suggestions.load(for: home) }
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
            // library and send it, to photograph the duplicate strip.
            if ProcessInfo.processInfo.environment["CWG_DUPE"] != nil,
               let url = library.compactMap(\.url).first {
                text = url
                startParse()
            }
        }
        .onChange(of: text) { _, now in
            forgetFirstLook()
            if now != pickedLook?.url { pickedLook = nil }
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
            PlusPaywall(
                reason: reason,
                incoming: draft,
                onUnlocked: { if let draft { commit(draft) } }
            )
        }
        .sheet(isPresented: $busyDay) {
            BusyDaySheet(incoming: draft, onLater: saveForTomorrow)
        }
    }

    // MARK: - Stage 1: input

    @ViewBuilder
    private var inputStage: some View {
        Text(Voice.whereGoing)
            .font(.displaySmallBold(38, relativeTo: .largeTitle))
            .foregroundStyle(AppBackground.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .matchedTitle(in: titleSpace)
            .accessibilityAddTraits(.isHeader)
            // Level with the close button, and clear of it.
            .padding(.top, 14)
            .padding(.trailing, 56)

        // Offline is said once, under the field, and the field's own button
        // becomes Save — no second copy of the input.
        if offlineMode {
            Label(
                saved ? "Saved. It'll be finished when you're back online." : "You're offline. Save it now and it'll be finished when you're back.",
                systemImage: saved ? "checkmark" : "wifi.slash"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppBackground.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .contentTransition(.opacity)
            .transition(.opacity)
        }

        if let nudge, !offlineMode {
            NudgeNote(nudge: nudge)
        }

        if let errorMessage, !offlineMode, nudge == nil {
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

        Recommendations(
            city: home?.locality,
            picks: recommendations,
            loading: suggestions.loading && text.isEmpty && imageJPEG == nil && !offlineMode,
            onPick: pick
        )
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.3), value: recommendations)
    }

    /// The shared composer (also the first-run's save page), docked on
    /// the keyboard, with the blank card in its + menu.
    private var composerBar: some View {
        Composer(
            text: $text, imageJPEG: $imageJPEG,
            busy: busy || savingOffline, offline: offlineMode, onManual: startManual,
            focusOnAppear: true
        ) {
            if offlineMode {
                Task { await saveOffline() }
            } else {
                startParse()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// A recommendation is read straight away, like a shared link, with
    /// what it already knows standing in until the parser's fields land.
    private func pick(_ suggestion: ParseClient.Suggestion) {
        withAnimation(reveal) {
            pickedLook = Item(suggestion: suggestion)
            reading = .link
        }
        startParse(link: suggestion.url)
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
        blank.kind = manualKind
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
            // The drawer says it under its title; the form says it on top.
            if let match = twin(of: draft) {
                DuplicateStrip(twin: match, open: { openExisting(match) })
            }
            ItemForm(item: draft)
                .transition(.opacity)
        } else {
            RemindRow(item: draft)
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

    /// The card's actions, floating bottom right like the detail drawer's.
    private func previewActions(_ draft: Item) -> some View {
        let match = twin(of: draft)
        return FloatingActions {
            if !saved, manual {
                // A blank card is always in edit mode and the × already
                // throws it away, so the one side action is the way back
                // to the composer.
                FloatingCircleButton("Look it up instead", systemImage: "sparkle.magnifyingglass") {
                    leaveManual()
                }
            } else if !saved {
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
                    Button("Discard", role: .destructive) {
                        withAnimation(.snappy) {
                            self.draft = nil
                            early = nil
                            reading = nil
                            peek = nil
                            editing = false
                            manual = false
                        }
                        // Typed words go back in the bar; a recommendation
                        // leaves the page as it was, its list included.
                        if pickedLook != nil {
                            pickedLook = nil
                            text = ""
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The card goes away. Nothing is saved.")
                }
            }

            FloatingMainButton(
                saved ? "Saved" : (match != nil ? "Save anyway" : "Save"),
                systemImage: saved ? "checkmark.circle.fill" : (match != nil ? "plus" : "checkmark")
            ) {
                save(draft)
            }
            .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            // Not `.disabled`: that would grey the button out under "Saved".
            .allowsHitTesting(!saved)
        }
        .animation(reduceMotion ? nil : .snappy, value: editing)
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

    /// The card may be something we already have — the link that was
    /// pasted, the same URL after redirects, or the same gig from a
    /// different ticket site. Said on the card, never blocked: the pair
    /// may genuinely want two entries.
    private func twin(of card: Item) -> Item? {
        guard !saved else { return nil }
        return duplicate(ofCard: card) ?? (manual ? nil : duplicate(of: firstURL(in: text)))
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
    private func startParse(link: String? = nil) {
        parseTask?.cancel()
        parseTask = Task { await parse(link: link) }
    }

    /// `link` is a recommendation's, read without passing through the
    /// field: the bar fading out still shows the field's text. It goes in
    /// the field once the read is over, for the duplicate check and Try
    /// again.
    private func parse(link: String? = nil) async {
        busy = true
        errorMessage = nil
        nudge = nil
        offline = false
        firstLook = nil
        early = nil
        defer { busy = false }
        let trimmed = (link ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
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
            ) { fields in
                guard !Task.isCancelled, busy, draft == nil else { return }
                withAnimation(reveal) { early = item(from: fields) }
            }
            guard !Task.isCancelled else { return }
            // The card's photo lands with the card when it can.
            if let url = card.image_url.flatMap(URL.init(string:)) {
                await ImageStore.warm(url, variant: .hero, limit: .milliseconds(900))
            }
            firstLook = nil
            if let link { text = link }
            let parsed = item(from: card)
            // A partner's save may have synced in while the parser worked.
            loadLibrary()
            withAnimation(reveal) { draft = parsed }
        } catch {
            guard !Task.isCancelled else { return }
            if let link { text = link }
            // Back to the composer, the input still in it (a
            // recommendation's link too, for Try again).
            withAnimation(reveal) {
                reading = nil
                peek = nil
                early = nil
                pickedLook = nil
            }
            // ParseError already speaks to a person; everything else
            // (URLError, decoding) gets the same translation sync uses.
            errorMessage = (error as? ParseClient.ParseError)?.errorDescription ?? SyncProblem(error).message
            if case ParseClient.ParseError.tooVague(_, let firm) = error {
                nudge = firm ? .stillSearching : .search
            } else if (error as? ParseClient.ParseError)?.isRestingForToday == true {
                nudge = .tomorrow
            }
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

    /// An unsaved card from the parser's answer.
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
        item.url = card.url
        item.lat = card.lat
        item.lng = card.lng
        item.colorHex = card.color
        item.imageUrl = card.image_url
        item.source = card.source
        item.placeId = card.place_id
        item.showings = card.showings ?? []
        return item
    }

    /// Parse first, paywall second: the finished card is on screen when a
    /// full day or a full category is mentioned, and it saves itself once
    /// Plus lands.
    private func save(_ item: Item) {
        if DailyCap.isFull(adding: item, context: context) {
            Haptics.tap()
            if GroupStore.shared.card?.isPlus == true { busyDay = true } else { paywall = .daily }
            return
        }
        if !item.isDone, let full = CategoryCap.overflow(item, context: context) {
            Haptics.tap()
            paywall = .category(full)
            return
        }
        commit(item)
    }

    /// Today is full: the card goes to the phone's inbox, which lands it
    /// as soon as there's room — tomorrow, unless one of today's goes.
    /// The drawer has already asked, so the inbox doesn't ask again.
    private func saveForTomorrow() {
        guard let draft, let userId = SupabaseAuth.shared.userId else { return }
        guard let file = try? SharedInbox.write(SharedInbox.PendingSave(item: draft, userId: userId)) else { return }
        SharedInbox.markAsked(file)
        Haptics.success()
        withAnimation(.easeInOut(duration: 0.25)) { saved = true }
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            dismiss()
        }
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

enum CaptureNudge {
    case search
    /// The fifth search of the day, and after.
    case stillSearching
    /// The day's lookups are used up; never named as such.
    case tomorrow
}

/// A search instead of a save, or a day that's had enough, is a nudge,
/// not a fault: no warning colours, and no retry, since the same words
/// get the same answer.
private struct NudgeNote: View {
    let nudge: CaptureNudge

    private var title: String {
        switch nudge {
        case .search: "That\u{2019}s a search, not a save"
        case .stillSearching: "We save, we don\u{2019}t search"
        case .tomorrow: "Let\u{2019}s pick this up tomorrow"
        }
    }

    private var detail: String {
        switch nudge {
        case .search: "Name one place or show, or paste a link to it."
        case .stillSearching: "Found somewhere you like? Paste its link, share a screenshot, or type its name."
        case .tomorrow: "You can still fill the card in yourself with Add manually."
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(AppBackground.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.displaySmall(18, relativeTo: .headline))
                    .foregroundStyle(AppBackground.ink)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
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
