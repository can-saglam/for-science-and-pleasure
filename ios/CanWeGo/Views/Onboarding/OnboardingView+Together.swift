import AuthenticationServices
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UserNotifications

extension OnboardingView {
    // MARK: Together

    /// Who it's for: two answers, and under them the way in for someone
    /// who was sent an invite. The invite opens its field in place.
    var togetherPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("Who\u{2019}s it for?")
            lede("You can change this any time in Settings.")

            choiceTile("person.fill", "Just me",
                       "A list of your own.",
                       selected: together == .solo) { chooseTogether(.solo) }
                .disabled(joined)
            choiceTile("person.2.fill", "Me and others",
                       "One list you share with a partner or friends. You\u{2019}ll invite them next.",
                       selected: together == .start) { chooseTogether(.start) }
                .disabled(joined)

            if together == .code {
                codeEntry
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Button {
                    Haptics.tap()
                    chooseTogether(.code)
                } label: {
                    Text("Got an invite? \(Text("Enter the link or code").fontWeight(.semibold).underline())")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(frozen)
                .transition(.opacity)
            }

            noteLine
        }
        .animation(ease, value: codePreview?.status)
        .animation(ease, value: together)
    }

    /// One answer to a page's question: a glass slab with a radio mark.
    /// Picking only selects; the bottom bar's Continue turns the page.
    func choiceTile(
        _ icon: String, _ title: String, _ detail: String,
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                row(icon, title, detail)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(selected ? .semibold : .regular))
                    .foregroundStyle(AppBackground.ink.opacity(selected ? 1 : 0.4))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(
            selected ? .regular.tint(AppBackground.accent.opacity(0.3)).interactive() : .regular.interactive(),
            in: .rect(cornerRadius: 18)
        )
        .disabled(frozen)
        .animation(ease, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Starting a shared list puts the invite page after the first
    /// save; the other answers take it out.
    func chooseTogether(_ choice: Together) {
        note = nil
        withAnimation(ease) {
            together = choice
            placeInvitePage()
        }
        if choice == .code {
            refreshOffers()
            if codeDraft.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus = .code }
            }
        } else {
            focus = nil
        }
    }

    func placeInvitePage() {
        let wanted = together == .start && !joined && (preview || !alreadyShared)
        if wanted, !pages.contains(.invite), let i = pages.firstIndex(of: .notify) {
            pages.insert(.invite, at: i)
        } else if !wanted, let i = pages.firstIndex(of: .invite) {
            pages.remove(at: i)
        }
    }

    // MARK: Code

    /// The field, the paste offer and the group it opens — shown once
    /// they've said they have a code.
    var codeEntry: some View {
        VStack(alignment: .leading, spacing: 18) {
            InviteCodeField(code: $codeDraft, busy: lookingUp)
                .focused($focus, equals: .code)
                .disabled(joined)

            if clipboardHasText, codeDraft.isEmpty, !joined {
                chip("Paste your invite", icon: "doc.on.clipboard") {
                    // Read only now, on the tap: reading earlier would put
                    // up the system paste prompt the moment the page opened.
                    let board = UIPasteboard.general
                    if let s = board.string ?? board.url?.absoluteString, let c = GroupStore.normaliseCode(s) {
                        codeDraft = JoinSheet.formatTyping(c)
                    } else {
                        clipboardHasText = false
                        note = "Nothing that looks like an invite on the clipboard."
                    }
                }
            }

            if let p = codePreview {
                codePreviewCard(p)
            }

            if preview, codePreview != nil, !joined {
                lede("Preview: any code opens Joyce\u{2019}s list. Nothing is joined for real.")
            }
        }
    }

    func codePreviewCard(_ p: GroupStore.JoinPreview) -> some View {
        slab {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Text(joined ? "You're in with" : "You'll be joining")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppBackground.secondaryInk)
                    Spacer(minLength: 8)
                    if let home = p.homeLocality, !home.isEmpty {
                        homeBadge(home)
                    }
                }
                // One row per person: a group holds at most four, so the
                // list never outgrows the card.
                if let members = p.members, !members.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(members.prefix(4).enumerated()), id: \.offset) { i, m in
                            if i > 0 {
                                Divider().overlay(AppBackground.wash(0.10)).padding(.leading, 50)
                            }
                            memberRow(m, invitedYou: m.displayName != nil && m.displayName == p.inviter)
                        }
                    }
                }
                if joined {
                    Label("You're in", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                } else if !p.canJoin {
                    Text(p.message())
                        .font(.footnote)
                        .foregroundStyle(AppBackground.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    func memberRow(_ m: GroupStore.JoinPreview.PreviewMember, invitedYou: Bool) -> some View {
        HStack(spacing: 12) {
            Text(m.initial)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AvatarColour.initial(m.avatarColour))
                .frame(width: 38, height: 38)
                .background(AvatarColour.color(m.avatarColour), in: .circle)
                .accessibilityHidden(true)
            Text(m.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if invitedYou {
                Text("Invited you")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppBackground.secondaryInk)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(AppBackground.wash(0.08), in: .capsule)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// The group's home as a small pill: an ink disc with the house cut
    /// out of it, then the city.
    func homeBadge(_ city: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "house.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppBackground.base)
                .frame(width: 20, height: 20)
                .background(AppBackground.ink, in: .circle)
            Text(city)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 11)
        .padding(.vertical, 4)
        .background(AppBackground.wash(0.08), in: .capsule)
        .overlay(Capsule().strokeBorder(AppBackground.wash(0.14), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Home: \(city)")
    }

    func codeTyped(_ raw: String) {
        // The paste chip and programmatic sets bypass the binding.
        let formatted = JoinSheet.formatTyping(raw)
        if formatted != raw { codeDraft = formatted; return }
        codePreview = nil
        note = nil
        guard let code else { return }
        Task { await lookup(code) }
    }

    /// In the preview any well-formed code "belongs" to Joyce, so the
    /// join flow can be walked end to end without a second account.
    /// `CWG_ONBOARDING_MEMBERS=Joyce,Sam` (test runs only) previews a
    /// bigger group; the first name is the inviter.
    static var previewInvite: GroupStore.JoinPreview {
        let names = ProcessInfo.processInfo.environment["CWG_ONBOARDING_MEMBERS"]?
            .split(separator: ",").map(String.init) ?? ["Joyce"]
        return GroupStore.JoinPreview(
            status: "ok",
            inviter: names.first,
            name: "\(names.first ?? "Joyce")\u{2019}s list",
            homeLocality: "London",
            capacity: max(2, names.count + 1),
            isPlus: names.count > 1,
            members: names.map { .init(displayName: $0, avatarColour: "coral") }
        )
    }

    func lookup(_ code: String) async {
        lookingUp = true
        defer { lookingUp = false }
        do {
            if preview {
                try await Task.sleep(for: .milliseconds(600))
                guard self.code == code else { return }
                codePreview = Self.previewInvite
                Haptics.tap()
                return
            }
            let p = try await group.preview(code: code)
            guard self.code == code else { return }
            codePreview = p
            Haptics.tap()
        } catch {
            guard self.code == code else { return }
            note = "Couldn't look that code up. Check the connection and try again."
        }
    }

    func join() async {
        guard let code else { return }
        if preview {
            // Pretend: the same state changes a real join produces, none
            // of the network. Their group already has a home, so that
            // page drops out exactly as it would for real.
            focus = nil
            Haptics.success()
            joined = true
            note = nil
            drop(.home)
            showJoined()
            return
        }
        busy = true
        defer { busy = false }
        focus = nil
        do {
            guard await SupabaseSync.flush(context: context) else {
                note = "Couldn't sync your latest edits. Try again once you're back online."
                return
            }
            _ = try await group.join(code: code, keepCopy: false)
            let landed = await SupabaseSync.replaceLibrary(context: context)
            guard landed else {
                note = "You\u{2019}re in, but this phone couldn\u{2019}t load the list. Open the app again when you\u{2019}re online."
                return
            }
            await members.refresh()
            // Their group's home is now ours: the clock on every card
            // should tick in that city from the very first save.
            await HomeStore.shared.refresh()
            Haptics.success()
            joined = true
            note = nil
            JoinGate.pendingCode = nil
            // Their group already knows where home is.
            if OnboardingGate.hasHome { drop(.home) }
            showJoined()
        } catch {
            note = "Couldn't join. \(SyncProblem(error).message)"
        }
    }

    /// A join answers "what's the first thing you'd go to?" better than
    /// any typed link could: the list is already full of their saves.
    /// The save page gives way to a look at it.
    func showJoined() {
        let all = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        groupCards = all
            .filter { $0.status == Item.Status.saved && $0.deletedAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
        withAnimation(ease) {
            if let i = pages.firstIndex(of: .save) {
                pages[i] = .joined
            } else if !pages.contains(.joined), let n = pages.firstIndex(of: .notify) {
                pages.insert(.joined, at: n)
            }
        }
    }

    // MARK: Joined

    /// Everyone else in the group once joined, the one who invited first.
    var groupmates: [String] {
        var names: [String]
        if !preview, let card = group.card, card.members.count > 1 {
            let me = SupabaseAuth.shared.userId
            names = card.members.filter { $0.userId != me }.map(\.name)
        } else if joined, let invite = codePreview {
            names = (invite.members ?? []).map(\.name)
            if names.isEmpty, let inviter = invite.inviter { names = [inviter] }
        } else {
            return []
        }
        if let inviter = codePreview?.inviter, let i = names.firstIndex(of: inviter) {
            names.insert(names.remove(at: i), at: 0)
        }
        return names
    }

    /// "Joyce", "Joyce and Sam", "Joyce, Sam and Alex" (or "or").
    static func listed(_ names: [String], _ conjunction: String) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " \(conjunction) " + last
    }

    var joinedPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("You're in.")
            if groupCards.isEmpty {
                lede(groupmates.count > 1
                     ? "Nothing saved yet — you'll be the first. Anything any of you shares into the app lands here for all of you."
                     : "Nothing saved yet — you'll be the first. Anything either of you shares into the app lands here for both of you.")
            } else {
                let who = groupmates.isEmpty ? "they" : Self.listed(groupmates, "and")
                lede("Some of what \(who) \(groupmates.count > 1 || groupmates.isEmpty ? "have" : "has") saved so far. It\u{2019}s your list now too: edit anything, add anything.")
                let shown = Array(groupCards.prefix(3))
                let seats = Self.joinedSeats(shown.count)
                // Newest in front: the fan runs back to front.
                cardFan(shown.reversed(), seats: seats, dealt: joinedDealt, key: 100, width: 320, overlap: Self.fanOverlap)
                    .scaleEffect(fanScale)
                    .padding(.vertical, tight ? -22 : 0)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottomTrailing) { moreBadge(groupCards.count - shown.count, dealt: joinedDealt) }
                    .padding(.vertical, 8)
                    .zIndex(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(shown.map(\.title).joined(separator: ", "))
                    .onAppear {
                        guard !joinedDealt else { return }
                        if reduceMotion { joinedDealt = true; return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(0.25))
                            joinedDealt = true
                        }
                    }
            }
            themeSwatches
        }
    }
}
