import SwiftData
import SwiftUI

/// One row, modern-settings style: a small icon squircle, then the title.
/// Monochrome — every badge wears the current theme's accent, with the
/// glyph in the theme base for contrast.
struct SettingsRow: View {
    let title: String
    let icon: String

    var body: some View {
        Label {
            // No explicit color: lets callers tint the title (e.g. Sign out).
            Text(title)
        } icon: {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppBackground.base)
                .frame(width: 28, height: 28)
                .background(AppBackground.accent.gradient, in: .rect(cornerRadius: 7, style: .continuous))
        }
    }
}

/// What the "My group" rows can open — alerts, the invite sheet, the leave
/// dialog — and the actions behind them. Lives outside the rows so the
/// presenters can hang off the Settings list itself: a List row is lazy and
/// may be off screen (or a Section, which would present once per row), and
/// a presenter that isn't in the hierarchy shows nothing.
@Observable
@MainActor
final class GroupUI {
    var renaming = false
    var draftGroupName = ""
    var invite: GroupStore.InviteResult?
    var inviting = false
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

    func makeInvite() async {
        inviting = true
        defer { inviting = false }
        await run {
            let fresh = try await group.invite()
            invite = fresh
        }
    }

    func leave(keepCopy: Bool, context: ModelContext) async {
        leaving = true
        defer { leaving = false }
        await run {
            // Edits made on this phone must reach the server while this
            // account can still write to the group; afterwards the rows
            // would be refused and lost.
            guard await SupabaseSync.flush(context: context) else {
                throw MembershipError(message: "Couldn\u{2019}t sync your latest edits — try again once you\u{2019}re back online.")
            }
            let result = try await group.leave(keepCopy: keepCopy)
            // The local library is the old group's: replace it before the
            // list behind this sheet can show a single stale card.
            let landed = await SupabaseSync.replaceLibrary(context: context)
            left = (result, landed)
        }
    }
}

/// "My group" at the top of Settings: who shares this library, room for
/// more, pending invites, and the two things you can change (the group's
/// name and your own). Every action goes through `GroupStore`, which asks
/// the `group-membership` function and shows whatever it answers.
struct GroupSection: View {
    @Bindable var ui: GroupUI
    @State private var group = GroupStore.shared

    private var me: UUID? { SupabaseAuth.shared.userId }

    var body: some View {
        if SupabaseAuth.shared.signedIn {
            Section {
                if let card = group.card {
                    rows(card)
                } else if group.loaded {
                    Button {
                        Task { await group.refresh() }
                    } label: {
                        SettingsRow(title: "Couldn\u{2019}t load your group — tap to retry", icon: "arrow.clockwise")
                    }
                } else {
                    LabeledContent { ProgressView() } label: {
                        SettingsRow(title: "Loading…", icon: "person.2.fill")
                    }
                }
            } header: {
                Text("My group")
            } footer: {
                footer
            }
            .listRowBackground(SettingsView.rowBackground)
            .disabled(ui.leaving)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rows(_ card: GroupCard) -> some View {
        // The group itself: name, headcount, home. Tap to rename.
        Button {
            Haptics.tap()
            ui.draftGroupName = card.namePinned ? card.name : ""
            ui.renaming = true
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.name)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(headline(card))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "pencil")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.name), \(headline(card))")
        .accessibilityHint("Renames the group")

        ForEach(card.members) { member in
            memberRow(member)
        }

        // One call to action while there's room. A live code is reused
        // (codes are multi-use and last a week); otherwise a fresh one is
        // minted. The code itself lives in the sheet, not on the row.
        if !card.isFull {
            let pending = card.invites.first
            Button {
                Haptics.tap()
                if let pending {
                    ui.invite = .init(code: pending.formatted, expiresAt: pending.expiresAt, message: nil)
                } else {
                    Task { await ui.makeInvite() }
                }
            } label: {
                HStack {
                    SettingsRow(title: "Invite people", icon: "person.badge.plus")
                        .fontWeight(.semibold)
                    Spacer()
                    if ui.inviting { ProgressView() }
                }
            }
            .disabled(ui.inviting)
            .accessibilityHint(pending == nil ? "Creates an invite code to share" : "Shows your invite code")
            .swipeActions(edge: .trailing) {
                if let pending {
                    Button("Cancel invite", role: .destructive) {
                        Task { await ui.run { try await group.revoke(pending.code) } }
                    }
                }
            }
            .contextMenu {
                if let pending {
                    Button("Cancel invite", systemImage: "xmark.circle", role: .destructive) {
                        Task { await ui.run { try await group.revoke(pending.code) } }
                    }
                }
            }
        }

        if card.members.count > 1 {
            Button(role: .destructive) {
                Haptics.tap()
                ui.confirmLeave = true
            } label: {
                HStack {
                    SettingsRow(title: "Leave group", icon: "person.2.slash.fill")
                        .foregroundStyle(.red)
                    Spacer()
                    if ui.leaving { ProgressView() }
                }
            }
        }
    }

    /// Names come from Apple (or the account), so rows only show; nothing
    /// here is tappable.
    private func memberRow(_ member: GroupCard.Member) -> some View {
        let isMe = member.userId == me
        return HStack(spacing: 12) {
            Text(member.initial)
                .font(.footnote.weight(.bold))
                .foregroundStyle(AppBackground.base)
                .frame(width: 28, height: 28)
                .background(AvatarColour.color(member.avatarColour), in: .circle)
                .accessibilityHidden(true)
            Text(member.name)
                .lineLimit(1)
                .truncationMode(.tail)
            if isMe {
                Text("you")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// "2 of 4 · London" — headcount against the seats this tier allows.
    private func headline(_ card: GroupCard) -> String {
        var parts = ["\(card.members.count) of \(card.capacity)"]
        if let home = card.homeLocality, !home.isEmpty { parts.append(home) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        Group {
            if let note = ui.note {
                Text(note).foregroundStyle(.orange)
            } else if let card = group.card, card.members.count == 1 {
                Text("Invite someone and you\u{2019}ll share one library — everyone sees and edits everything.")
            } else if let card = group.card, card.needsPlusToGrow {
                Text("Everyone here sees and edits the same library. Free groups have two seats — Plus, coming soon, opens two more.")
            } else if let card = group.card, card.isFull {
                Text("Everyone here sees and edits the same library. Four is the most a group can hold.")
            } else {
                Text("Everyone here sees and edits the same library. Anyone can invite or rename the group; nobody can remove anyone but themselves.")
            }
        }
    }
}

/// The alerts, sheet and dialog the group rows open. Applied to the
/// Settings list, which is always in the hierarchy while Settings is up.
struct GroupPresentations: ViewModifier {
    @Bindable var ui: GroupUI
    @Environment(\.modelContext) private var context
    @State private var group = GroupStore.shared

    private var me: UUID? { SupabaseAuth.shared.userId }
    private var card: GroupCard? { group.card }

    func body(content: Content) -> some View {
        content
            .task { await group.refresh() }
            .alert("Group name", isPresented: $ui.renaming) {
                TextField(card?.namePinned == false ? (card?.name ?? "") : "Can & Joyce", text: $ui.draftGroupName)
                    .textInputAutocapitalization(.words)
                Button("Save") { Task { await ui.run { try await group.rename(ui.draftGroupName) } } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Up to 30 characters. Leave it blank and the group goes back to naming itself after its members.")
            }
            .sheet(item: $ui.invite) { InviteSheet(invite: $0, groupName: card?.name ?? "the group") }
            .confirmationDialog(
                "Keep a copy of the group\u{2019}s saves?",
                isPresented: $ui.confirmLeave,
                titleVisibility: .visible
            ) {
                // Both leave — that's the part that can't be undone — so both
                // wear the same weight; neither deletes anything from the group.
                Button("Leave and keep a copy", role: .destructive) { Task { await ui.leave(keepCopy: true, context: context) } }
                Button("Leave with an empty library", role: .destructive) { Task { await ui.leave(keepCopy: false, context: context) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(leaveMessage)
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

    private var leaveMessage: String {
        guard let card else { return "" }
        var lines = ["You\u{2019}ll leave \(card.name) and get a library of your own. The group keeps everything either way."]
        if let mine = card.member(me), mine.isPlus,
           !card.members.contains(where: { $0.isPlus && $0.userId != me }) {
            lines.append("You\u{2019}re the only one with Plus — the group loses it when you go.")
        }
        return lines.joined(separator: "\n\n")
    }

    private var leftMessage: String {
        guard let left = ui.left else { return "" }
        if !left.landed {
            return "You\u{2019}ve got a library of your own now; it\u{2019}ll fill in as soon as the app can reach the server."
        }
        return left.result.copied > 0
            ? "You\u{2019}ve got a library of your own now, with a copy of everything the group had."
            : "You\u{2019}ve got a library of your own now, starting empty."
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
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Text(invite.code)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .kerning(2)
                        .textSelection(.enabled)
                        .accessibilityLabel("Invite code \(invite.code.map(String.init).joined(separator: " "))")
                    Text("Valid until \(invite.expiresAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    ShareLink(item: message) {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                Text("Anyone with this code can join until it expires, or until you cancel it in Settings. They\u{2019}ll bring their own saves with them and see everything in \(groupName).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // Never squeezed to one line by the spacers around it.
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(24)
            .appBackground(AppBackground.sheet)
            .navigationTitle(groupName)
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
        }
        .presentationDetents([.fraction(0.55), .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
