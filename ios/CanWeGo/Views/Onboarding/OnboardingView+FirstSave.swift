import AuthenticationServices
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UserNotifications

extension OnboardingView {
    // MARK: First save

    /// Only a home that was actually chosen counts; `HomeStore.home` falls
    /// back to London when nothing is set, and that must not show London
    /// starters to someone in Lisbon who hasn't picked yet.
    var chosenHome: HomeStore.Home? {
        picked ?? (HomeStore.shared.isSet ? HomeStore.shared.home : nil)
    }

    /// The chips: the city's own from the server, things on first, then
    /// places. Nothing without a home; "Looking up…" while they come.
    var starterChips: [ParseClient.Suggestion] {
        guard let home = chosenHome else { return [] }
        return suggestions.mixed(for: home, count: 8)
    }

    /// The city the chips are about. The pool only answers for the chosen
    /// home, so a guess that landed since can't mislabel them.
    var starterCity: String? { chosenHome?.locality }

    var savePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !savedPicks.isEmpty {
                headline(savedPicks.count == 1 ? "There it is." : "There they are.")
                lede("Everything you add lands in the library looking like this. The details fill in as we read each page.")
                let shown = Array(savedPicks.prefix(3))
                // First pick in front: the fan runs back to front.
                cardFan(shown.reversed(), seats: Self.joinedSeats(shown.count), dealt: savedDealt, key: 200, width: 320,
                        reading: reading, overlap: Self.fanOverlap)
                    .scaleEffect(fanScale)
                    .padding(.vertical, tight ? -22 : 0)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottomTrailing) { moreBadge(savedPicks.count - shown.count, dealt: savedDealt) }
                    .padding(.vertical, 8)
                    .zIndex(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(shown.map(\.title).joined(separator: ", "))
                    .onAppear {
                        guard !savedDealt else { return }
                        if reduceMotion { savedDealt = true; return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(0.25))
                            savedDealt = true
                        }
                    }
                themeSwatches
            } else if let parsed {
                headline("There it is.")
                lede(tickedPicks.isEmpty
                     ? "A real save. Everything you add lands in the library looking like this."
                     : "A real save, and the \(tickedPicks.count == 1 ? "one" : "\(tickedPicks.count)") you ticked go in with it. Everything you add lands in the library looking like this.")
                ItemCard(item: parsed, awayHint: false)
                quiet("Try another") {
                    self.parsed = nil
                    linkDraft = ""
                    linkImage = nil
                    note = nil
                    refreshOffers()
                }
                themeSwatches
            } else {
                headline("What would you\ngo to first?")
                lede("Paste a link or name it: a gig, a show, somewhere to eat. We look it up and make the card. Or tap a few from your city.")

                if parsing {
                    formingCard
                        .transition(.opacity)
                    // Some pages take a while to read; nobody has to wait.
                    quiet("Skip this") {
                        parseTask?.cancel()
                        parsing = false
                        advance()
                    }
                } else {
                    // The same composer as the app's add sheet, so the
                    // first save teaches the real thing.
                    Composer(text: $linkDraft, imageJPEG: $linkImage, busy: false) {
                        startParse()
                    }

                    if linkImage == nil {
                        // The add page's chips, so the first save looks like
                        // every one after it. They stay while typing.
                        Recommendations(
                            city: starterChips.isEmpty ? chosenHome?.locality : starterCity,
                            picks: starterChips,
                            loading: suggestions.loading,
                            finding: suggestions.findingEvents,
                            ticked: Set(tickedPicks.map(\.id))
                        ) { pick in
                            if let i = tickedPicks.firstIndex(of: pick) {
                                tickedPicks.remove(at: i)
                            } else {
                                tickedPicks.append(pick)
                            }
                        }
                        .modifier(ColumnClip(on: sideBySide))
                    }

                    // The share-sheet lesson isn't here: it arrives as a
                    // tip in the library on the second launch (ShareTip).
                }
            }

            noteLine
        }
        .animation(ease, value: parsing)
        .animation(ease, value: parsed?.id)
        .animation(ease, value: savedPicks.count)
        .animation(ease, value: starterChips)
        // Preview only: `CWG_ONBOARDING_PICKS=3` ticks and saves that many
        // city picks once they've loaded, for checking the saved cards.
        .task {
            guard preview, savedPicks.isEmpty,
                  let n = ProcessInfo.processInfo.environment["CWG_ONBOARDING_PICKS"].flatMap(Int.init)
            else { return }
            try? await Task.sleep(for: .seconds(3))
            tickedPicks = Array(starterChips.prefix(n))
            commitPicks()
            // `CWG_ONBOARDING_THEN=notify`: carry on to that page after.
            if let then = ProcessInfo.processInfo.environment["CWG_ONBOARDING_THEN"],
               let i = pages.firstIndex(where: { $0.rawValue == then }) {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(ease) { index = i }
            }
        }
        .animation(ease, value: suggestions.loading)
        .onAppear {
            if let home = chosenHome { fetchStarters(for: home) }
        }
    }

    /// The card, forming. Sits exactly where the field was and where the
    /// real card will land: what they typed becomes the title, the lines
    /// the parser will fill sit beneath as shimmering placeholders, and
    /// the status copy runs along the bottom.
    var formingCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(formingTitle)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            SkeletonLine(width: 172)
            SkeletonLine(width: 104)
            HStack(spacing: 8) {
                SmallRing()
                ParsingPhrases(text: linkDraft, hasImage: linkImage != nil)
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { Shimmer(highlight: .white.opacity(themes.current.isLight ? 0.55 : 0.10)) }
        .clipShape(.rect(cornerRadius: 18))
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Making the card for \(formingTitle)")
    }

    /// A link shows as its site while we read it; a name shows as itself;
    /// a photo on its own is called that.
    var formingTitle: String {
        if let host = linkURL?.host() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return query ?? (linkImage != nil ? "Your photo" : "")
    }

    /// Whatever they typed, trimmed: a link or a plain name. The parser
    /// takes both, same as the capture sheet.
    var query: String? {
        let raw = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// True only when the draft is a real link; the paste chip uses this
    /// to decide whether the clipboard was worth offering.
    var linkURL: URL? {
        guard let raw = query else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: withScheme), url.host() != nil, !raw.contains(" ") else { return nil }
        return url
    }

    /// One parse at a time, and cancellable from "Skip this".
    func startParse() {
        parseTask?.cancel()
        parseTask = Task { await parse() }
    }

    func parse() async {
        guard query != nil || linkImage != nil else { return }
        focus = nil
        parsing = true
        note = nil
        defer { if !Task.isCancelled { parsing = false } }
        do {
            let card = try await ParseClient.parse(text: query, imageJPEG: linkImage)
            // Skipped meanwhile: the page has moved on; drop the result.
            guard !Task.isCancelled else { return }
            let item = Item()
            item.take(card)
            parsed = item
            Haptics.success()
        } catch {
            guard !Task.isCancelled else { return }
            let why = (error as? ParseClient.ParseError)?.errorDescription ?? SyncProblem(error).message
            note = "\(why) Try something else, or carry on and add one later."
        }
    }

    /// The typed save, plus anything ticked under it.
    func commitSave() {
        guard let item = parsed else { return }
        if preview { advance(); return }
        let picks = tickedPicks.map(Item.init(suggestion:))
        guard insert([item] + picks) else { return }
        enrich(unread(picks))
        advance()
    }

    /// Ticked picks on their own: saved straight away from what the pool
    /// knows, shown as cards, and filled in from their pages meanwhile.
    func commitPicks() {
        let picks = tickedPicks.map(Item.init(suggestion:))
        guard preview || insert(picks) else { return }
        savedPicks = picks
        enrich(unread(picks))
    }

    /// The saved picks whose card the server hadn't stored yet.
    func unread(_ picks: [Item]) -> [Item] {
        zip(tickedPicks, picks).filter { $0.0.card == nil }.map(\.1)
    }

    func insert(_ items: [Item]) -> Bool {
        for item in items {
            item.createdAt = .now
            item.updatedAt = .now
            item.stampAuthor()
            context.insert(item)
        }
        do {
            try context.save()
        } catch {
            items.forEach(context.delete)
            note = items.count == 1 ? "Couldn't save that. Try again." : "Couldn't save those. Try again."
            return false
        }
        Haptics.success()
        for item in items { Task { await SupabaseSync.announceSave(item) } }
        return true
    }

    /// A pick's full card (summary, address, colour, picture), read from
    /// its page after it's saved. A page that can't be read leaves the
    /// pool's version, which is already a fine save. Not tied to the page,
    /// so moving on doesn't stop it. The preview reads them too (unsaved),
    /// so it shows what a real run shows.
    func enrich(_ items: [Item]) {
        let context = context
        let preview = preview
        for item in items {
            guard let url = item.url else { continue }
            let id = item.id
            reading.insert(id)
            Task { @MainActor in
                defer { reading.remove(id) }
                guard let card = try? await ParseClient.parse(text: url, imageJPEG: nil) else { return }
                // Joining a library meanwhile swaps every row out; a saved
                // one is looked up again, never touched across the wait.
                guard let item = preview ? item : context.item(id), !item.isTrashed else { return }
                item.take(card)
                guard !preview, item.modelContext != nil else { return }
                item.updatedAt = .now
                try? context.save()
                SupabaseSync.schedule(context: context)
            }
        }
    }
}
