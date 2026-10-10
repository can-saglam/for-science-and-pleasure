import SwiftData
import SwiftUI

/// One Settings row: just the words. Destructive rows say so in the
/// theme's legible red rather than the system's, which melts into some
/// pages.
struct SettingsRow: View {
    let title: String
    /// A second, quieter line under the title.
    var subtitle: String? = nil
    var destructive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(destructive ? AppBackground.destructive : AppBackground.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(AppBackground.secondaryInk)
            }
        }
    }
}

/// What the "My group" rows can open — alerts, the invite sheet, the leave
/// confirm — and the actions behind them. Sheets and the "you've left"
/// alert hang off the Settings list (always in the hierarchy). The leave
/// dialog itself lives on the Leave row so iOS 26 anchors the popover there.
@Observable
@MainActor
final class GroupUI {
    var invite: GroupStore.InviteResult?
    var inviting = false
    /// The group is full for its tier; the invite row opens the upsell.
    var showPlus = false
    var showJoin = false
    var editingHome = false
    var renaming = false
    var draftName = ""
    var savingName = false
    var confirmLeave = false
    var leaving = false
    var left: (result: GroupStore.LeaveResult, landed: Bool)?
    /// The last thing that went wrong, shown under the section.
    var note: String?

    private let group = GroupStore.shared

    func run(_ work: () async throws -> Void) async {
        note = nil
        do {
            try await work()
            Haptics.success()
        } catch {
            note = (error as? MembershipError)?.message ?? SyncProblem(error).message
        }
    }

    /// The one invite action, from the seat on the card or the row on the
    /// group page. With room: a live code is reused (codes are multi-use
    /// and last a week) or a fresh one minted; the code itself lives in the
    /// sheet. Full for the free tier: the way to Plus.
    func startInvite(for card: GroupCard) {
        if card.needsPlusToGrow {
            showPlus = true
        } else if let pending = card.invites.first {
            invite = .init(code: pending.formatted, expiresAt: pending.expiresAt, message: nil)
        } else {
            Task { await makeInvite() }
        }
    }

    func makeInvite() async {
        inviting = true
        defer { inviting = false }
        await run {
            let fresh = try await group.invite()
            invite = fresh
        }
    }

    func saveName() async {
        savingName = true
        defer { savingName = false }
        note = nil
        if let problem = await MembersStore.shared.setDisplayName(draftName) {
            note = problem
            return
        }
        Haptics.success()
        await group.refresh()
    }

    func leave(keepCopy: Bool, context: ModelContext) async {
        leaving = true
        defer { leaving = false }
        await run {
            // Edits made on this phone must reach the server while this
            // account can still write to the group; afterwards the rows
            // would be refused and lost.
            guard await SupabaseSync.flush(context: context) else {
                throw MembershipError(message: "Couldn\u{2019}t sync your latest edits. Try again once you\u{2019}re back online.")
            }
            let result = try await group.leave(keepCopy: keepCopy)
            // The local library is the old group's: replace it before the
            // list behind this sheet can show a single stale card.
            let landed = await SupabaseSync.replaceLibrary(context: context)
            left = (result, landed)
        }
    }
}

/// The group page in Settings: who shares this library, room for more,
/// and the way out. The group has no name of its own — it's called after
/// its members, everywhere it's mentioned — so the rows *are* the group.
/// Every action goes through `GroupStore`, which asks the
/// `group-membership` function and shows whatever it answers.
struct GroupSection: View {
    @Bindable var ui: GroupUI
    @State private var group = GroupStore.shared
    @Environment(\.modelContext) private var context

    private var me: UUID? { SupabaseAuth.shared.userId }

    var body: some View {
        if SupabaseAuth.shared.signedIn {
            Group {
                if let card = group.card?.forScreenshots {
                    sections(card)
                } else if group.loaded {
                    Section {
                        Button {
                            Task { await group.refresh() }
                        } label: {
                            SettingsRow(title: "Couldn\u{2019}t load your group. Tap to retry")
                        }
                    }
                    .listRowBackground(SettingsView.rowBackground)
                } else {
                    Section {
                        LabeledContent { ProgressView() } label: {
                            SettingsRow(title: "Loading…")
                        }
                    }
                    .listRowBackground(SettingsView.rowBackground)
                }
            }
            .disabled(ui.leaving)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func sections(_ card: GroupCard) -> some View {
        Section {
            ForEach(card.members) { member in
                memberRow(member)
            }
            cityRow(card)
        }
        .listRowBackground(SettingsView.rowBackground)

        Section {
            if !card.isFull || card.needsPlusToGrow {
                inviteRow(card)
            }
            Button {
                Haptics.tap()
                ui.showJoin = true
            } label: {
                SettingsRow(title: card.members.count == 1 ? "Join someone\u{2019}s library" : "Join another group")
            }
            .accessibilityHint("Enter an invite code")
        } footer: {
            footer
        }
        .listRowBackground(SettingsView.rowBackground)

        if card.members.count > 1 {
            Section {
                leaveRow(card)
            }
            .listRowBackground(SettingsView.rowBackground)
        }
    }

    private func cityRow(_ card: GroupCard) -> some View {
        Button {
            Haptics.tap()
            ui.editingHome = true
        } label: {
            HStack {
                if let home = card.homeLocality, !home.isEmpty {
                    SettingsRow(title: "City")
                    Spacer()
                    Text(home)
                        .foregroundStyle(AppBackground.secondaryInk)
                        .lineLimit(1)
                } else {
                    SettingsRow(title: "Set a home city")
                    Spacer()
                }
                chevron
            }
        }
        .accessibilityHint("Changes the city your cards and map use")
    }

    /// Present until the group is at four.
    private func inviteRow(_ card: GroupCard) -> some View {
        let pending = card.invites.first
        return Button {
            Haptics.tap()
            ui.startInvite(for: card)
        } label: {
            HStack {
                SettingsRow(title: "Invite people")
                    .fontWeight(.semibold)
                Spacer()
                if ui.inviting {
                    ProgressView()
                } else if card.needsPlusToGrow {
                    Text("Plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppBackground.secondaryInk)
                }
            }
        }
        .disabled(ui.inviting)
        .accessibilityHint(card.needsPlusToGrow ? "Opens Plus, which adds two more seats"
            : pending == nil ? "Creates an invite code to share" : "Shows your invite code")
        .swipeActions(edge: .trailing) {
            if let pending, !card.needsPlusToGrow {
                Button("Cancel invite", role: .destructive) {
                    Task { await ui.run { try await group.revoke(pending.code) } }
                }
            }
        }
        .contextMenu {
            if let pending, !card.needsPlusToGrow {
                Button("Cancel invite", systemImage: "xmark.circle", role: .destructive) {
                    Task { await ui.run { try await group.revoke(pending.code) } }
                }
            }
        }
    }

    private func leaveRow(_ card: GroupCard) -> some View {
        Button(role: .destructive) {
            Haptics.tap()
            ui.confirmLeave = true
        } label: {
            HStack {
                SettingsRow(title: "Leave group", destructive: true)
                Spacer()
                if ui.leaving { ProgressView() }
            }
        }
        // On the button, not the list — iOS 26 parks a list-level
        // confirmation dialog at the top of the section.
        .confirmationDialog(
            "Keep a copy of the group\u{2019}s saves?",
            isPresented: $ui.confirmLeave,
            titleVisibility: .visible
        ) {
            Button("Leave and keep a copy", role: .destructive) {
                Task { await ui.leave(keepCopy: true, context: context) }
            }
            Button("Leave with an empty library", role: .destructive) {
                Task { await ui.leave(keepCopy: false, context: context) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(leaveMessage(for: card))
        }
    }

    private func leaveMessage(for card: GroupCard) -> String {
        var lines = ["You\u{2019}ll get your own library. \(card.name) keeps everything either way."]
        if let mine = card.member(me), mine.isPlus,
           !card.members.contains(where: { $0.isPlus && $0.userId != me }) {
            lines.append("You\u{2019}re the only one with Plus. The group loses it when you go.")
        }
        return lines.joined(separator: "\n\n")
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppBackground.ink.opacity(0.45))
            .accessibilityHidden(true)
    }

    /// Your own row renames you; everyone else's only shows.
    @ViewBuilder
    private func memberRow(_ member: GroupCard.Member) -> some View {
        if member.userId == me {
            Button {
                Haptics.tap()
                ui.draftName = member.displayName ?? ""
                ui.renaming = true
            } label: {
                HStack {
                    memberLabel(member, isMe: true)
                    if ui.savingName { ProgressView() } else { chevron }
                }
            }
            .disabled(ui.savingName)
            .accessibilityHint("Changes your name")
        } else {
            // The hidden chevron keeps Plus badges in one column with yours.
            HStack {
                memberLabel(member, isMe: false)
                chevron.hidden()
            }
        }
    }

    private func memberLabel(_ member: GroupCard.Member, isMe: Bool) -> some View {
        HStack(spacing: 12) {
            Text(member.initial)
                .font(.footnote.weight(.bold))
                // Per-swatch ink, the same as Join: white on the deep
                // swatches, black on the light ones.
                .foregroundStyle(AvatarColour.initial(member.avatarColour))
                .frame(width: 28, height: 28)
                .background(AvatarColour.color(member.avatarColour), in: .circle)
                .accessibilityHidden(true)
            Text(member.name)
                .lineLimit(1)
                .truncationMode(.tail)
            if isMe {
                Text("you")
                    .font(.caption)
                    .foregroundStyle(AppBackground.secondaryInk)
            }
            Spacer()
            if member.isPlus {
                Text("Plus")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(AppBackground.accent.opacity(0.25), in: .capsule)
                    .accessibilityLabel("Has Plus")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(member.name)\(isMe ? ", you" : "")\(member.isPlus ? ", has Plus" : "")")
    }

    // MARK: - Copy

    private var footer: some View {
        Group {
            if let note = ui.note {
                Text(note).foregroundStyle(AppBackground.warning)
            } else if let card = group.card?.forScreenshots, card.members.count == 1 {
                Text("Invite someone to share your library. You can both see and edit everything.")
            } else if let card = group.card?.forScreenshots, card.isFull, !card.needsPlusToGrow {
                Text("Everyone here shares one library. A group holds up to four people.")
            } else {
                Text("Everyone here shares one library. Anyone can invite. You can leave, but you can\u{2019}t remove anyone.")
            }
        }
        .font(.footnote)
        .foregroundStyle(AppBackground.secondaryInk)
    }
}

/// The top of Settings: everyone who shares this library, a seat to
/// invite into while there's room, and the way to the rest of the group.
struct GroupHeroCard: View {
    let card: GroupCard
    @Bindable var ui: GroupUI
    let manage: () -> Void

    private var me: UUID? { SupabaseAuth.shared.userId }
    private var solo: Bool { card.members.count == 1 }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(card.members) { member in
                    seat(member)
                }
                if !card.isFull || card.needsPlusToGrow {
                    inviteSeat
                }
            }
            // Alone, your own name over your own library reads oddly; the
            // card says what it is instead, and the button what's next.
            Text(solo ? "Your library" : card.name)
                .font(.displaySmallBold(30, relativeTo: .title2))
                .foregroundStyle(AppBackground.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Button {
                Haptics.tap()
                manage()
            } label: {
                Text(solo ? "Invite or join someone" : "Manage group")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func seat(_ member: GroupCard.Member) -> some View {
        let isMe = member.userId == me
        return VStack(spacing: 6) {
            Text(member.initial)
                .font(.title3.weight(.bold))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                // Per-swatch ink, the same as Join: white on the deep
                // swatches, black on the light ones.
                .foregroundStyle(AvatarColour.initial(member.avatarColour))
                .frame(width: 56, height: 56)
                .background(AvatarColour.color(member.avatarColour), in: .circle)
            Text(isMe ? "You" : member.name)
                .font(.footnote)
                .foregroundStyle(AppBackground.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 66)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(member.name)\(isMe ? ", you" : "")\(member.isPlus ? ", has Plus" : "")")
    }

    private var inviteSeat: some View {
        Button {
            Haptics.tap()
            ui.startInvite(for: card)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(AppBackground.ink.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    if ui.inviting {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    }
                }
                .frame(width: 56, height: 56)
                Text("Invite")
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(AppBackground.ink)
            .frame(width: 66)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(ui.inviting)
        .accessibilityLabel("Invite people")
        .accessibilityHint(card.needsPlusToGrow ? "Opens Plus, which adds two more seats" : "Shares an invite code")
    }
}

/// Sheets and the "you've left" alert. Applied to the Settings list,
/// which is always in the hierarchy while Settings is up.
struct GroupPresentations: ViewModifier {
    @Bindable var ui: GroupUI
    @State private var group = GroupStore.shared

    private var card: GroupCard? { group.card?.forScreenshots }

    func body(content: Content) -> some View {
        content
            .task { await group.refresh() }
            .sheet(item: $ui.invite) { InviteSheet(invite: $0, groupName: card?.name ?? "the group") }
            .sheet(isPresented: $ui.showPlus) { PlusPaywall(reason: .seats) }
            .sheet(isPresented: $ui.showJoin) { JoinSheet() }
            .sheet(isPresented: $ui.editingHome) { HomeCitySheet() }
            .alert("Your name", isPresented: $ui.renaming) {
                TextField("Name", text: $ui.draftName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                Button("Save") { Task { await ui.saveName() } }
                    .disabled(ui.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your group sees this on the saves you add.")
            }
            // CWG_SETTINGS=city is only set by automated test runs.
            .task {
                if ProcessInfo.processInfo.environment["CWG_SETTINGS"] == "city" {
                    try? await Task.sleep(for: .seconds(1.5))
                    ui.editingHome = true
                }
            }
            .alert(
                "You\u{2019}ve left \(ui.left?.result.formerGroupName ?? "the group")",
                isPresented: Binding(get: { ui.left != nil }, set: { if !$0 { ui.left = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(leftMessage)
            }
    }

    private var leftMessage: String {
        guard let left = ui.left else { return "" }
        if !left.landed {
            return "Your new library will fill in once you\u{2019}re back online."
        }
        return left.result.copied > 0
            ? "Your new library has a copy of everything from the group."
            : "Your new library starts empty."
    }
}

/// The code, big enough to read across a table, with share and copy.
struct InviteSheet: View {
    let invite: GroupStore.InviteResult
    let groupName: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var message: String {
        invite.message ?? "Join me on Can We Go? \u{2014} code \(invite.code)"
    }

    var body: some View {
        NavigationStack {
            // Scrolls: a plain stack taller than the sheet gets centred,
            // and takes the title up past the sheet's top edge.
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text(invite.code)
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .kerning(2)
                            .textSelection(.enabled)
                            .accessibilityLabel("Invite code \(invite.code.map(String.init).joined(separator: " "))")
                        Text("Valid until \(invite.expiresAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                            .font(.footnote)
                            .foregroundStyle(AppBackground.secondaryInk)
                    }
                    VStack(spacing: 12) {
                        ShareLink(item: message) {
                            Label("Share invite", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .prominentGlass()
                        .controlSize(.large)
                        Button {
                            UIPasteboard.general.string = invite.code
                            Haptics.success()
                            withAnimation(.snappy) { copied = true }
                        } label: {
                            Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                    Text("Anyone with this code can join until it expires or you cancel it. Their saves come with them.")
                        .font(.footnote)
                        .foregroundStyle(AppBackground.secondaryInk)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .appBackground(AppBackground.sheet)
            .sheetTitle(groupName) {
                dismiss()
            }
        }
        .presentationDetents([.fraction(0.55), .large])
        .presentationDragIndicator(.visible)
        .appColorScheme()
    }
}
