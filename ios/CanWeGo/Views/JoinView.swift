import SwiftData
import SwiftUI
import UIKit

/// Type a code (or take one from the clipboard) and see who you'd be
/// joining before anything moves. Dead ends — expired, revoked, full,
/// unknown, own — are the same screen with different copy, not errors.
struct JoinSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var group = GroupStore.shared
    @FocusState private var focused: Bool

    @State private var draft = ""
    @State private var preview: GroupStore.JoinPreview?
    @State private var lookingUp = false
    @State private var joining = false
    @State private var confirmLeave = false
    @State private var showPlus = false
    @State private var clipboardOffer = false
    @State private var note: String?
    @State private var joinedName: String?

    private var code: String? { GroupStore.normaliseCode(draft) }
    private var inSharedGroup: Bool { (group.card?.members.count ?? 1) > 1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    field
                    if clipboardOffer {
                        clipboardRow
                    }
                    if lookingUp {
                        ProgressView()
                            .padding(.top, 8)
                    } else if let preview {
                        result(preview)
                    } else if let note {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(AppBackground.warning)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .appBackground(AppBackground.sheet)
            .navigationTitle("Join a group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .disabled(joining)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .appColorScheme()
        .onAppear { focused = true }
        .task { await refreshClipboardOffer() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshClipboardOffer() } }
        }
        .onChange(of: draft) { _, _ in
            preview = nil
            note = nil
        }
        .sheet(isPresented: $showPlus) { PlusSheet() }
        .alert(
            "You\u{2019}ve joined \(joinedName ?? "the group")",
            isPresented: Binding(
                get: { joinedName != nil },
                set: { if !$0 { joinedName = nil; dismiss() } }
            )
        ) {
            Button("OK") { dismiss() }
        } message: {
            Text("Their saves are in your library now.")
        }
    }

    // MARK: - Field

    private var field: some View {
        VStack(spacing: 12) {
            TextField("KV7-P2M", text: $draft)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($focused)
                .onChange(of: draft) { _, new in
                    let formatted = Self.formatTyping(new)
                    if formatted != new { draft = formatted }
                }
                .onSubmit { Task { await lookup() } }
                .accessibilityLabel("Invite code")

            Button {
                Haptics.tap()
                Task { await lookup() }
            } label: {
                Text("Look up")
                    .frame(maxWidth: .infinity)
            }
            .prominentGlass()
            .controlSize(.large)
            .disabled(code == nil || lookingUp)
        }
    }

    private var clipboardRow: some View {
        Button {
            Haptics.tap()
            useClipboard()
        } label: {
            Label("Use code from clipboard", systemImage: "clipboard")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .accessibilityHint("Reads the clipboard and looks the code up")
    }

    // MARK: - Result

    @ViewBuilder
    private func result(_ preview: GroupStore.JoinPreview) -> some View {
        VStack(spacing: 16) {
            if preview.status == "own" {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(AppBackground.accent)
            }

            if let name = preview.name, !name.isEmpty, preview.status != "unknown" {
                VStack(spacing: 6) {
                    Text(name)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    if let home = preview.homeLocality, !home.isEmpty {
                        Text(home)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let members = preview.members, !members.isEmpty {
                HStack(spacing: -6) {
                    ForEach(members) { member in
                        Text(member.initial)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(AvatarColour.initial(member.avatarColour))
                            .frame(width: 32, height: 32)
                            .background(AvatarColour.color(member.avatarColour), in: .circle)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(members.map(\.name).joined(separator: ", "))
            }

            Text(preview.message())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if preview.canJoin {
                Button {
                    Haptics.tap()
                    if inSharedGroup {
                        confirmLeave = true
                    } else {
                        Task { await join(keepCopy: false) }
                    }
                } label: {
                    HStack {
                        Text(inSharedGroup ? "Leave this group and join" : "Join")
                        if joining { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .prominentGlass()
                .controlSize(.large)
                .confirmationDialog(
                    "Keep a copy of this group\u{2019}s saves?",
                    isPresented: $confirmLeave,
                    titleVisibility: .visible
                ) {
                    Button("Join and keep a copy", role: .destructive) {
                        Task { await join(keepCopy: true) }
                    }
                    Button("Join without a copy", role: .destructive) {
                        Task { await join(keepCopy: false) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(leaveForJoinMessage)
                }
            } else if preview.askForPlus {
                Button {
                    Haptics.tap()
                    showPlus = true
                } label: {
                    Text("See Plus")
                        .frame(maxWidth: .infinity)
                }
                .prominentGlass()
                .controlSize(.large)
            } else if preview.status == "own" {
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Text("Back to your group")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .padding(.top, 8)
    }

    private var leaveForJoinMessage: String {
        guard let card = group.card else { return "" }
        var lines = [
            "You\u{2019}ll leave \(card.name) to join this one. They keep everything either way.",
        ]
        if let name = preview?.name { lines[0] = "You\u{2019}ll leave \(card.name) to join \(name). They keep everything either way." }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Actions

    private func lookup() async {
        guard let code else {
            note = "Invite codes are six characters — letters and numbers, no I, O, 1 or 0."
            return
        }
        lookingUp = true
        note = nil
        defer { lookingUp = false }
        do {
            preview = try await group.preview(code: code)
            Haptics.selection()
        } catch {
            preview = nil
            note = (error as? MembershipError)?.message ?? SyncProblem(error).message
        }
    }

    private func join(keepCopy: Bool) async {
        guard let code else { return }
        joining = true
        note = nil
        defer { joining = false }
        do {
            guard await SupabaseSync.flush(context: context) else {
                throw MembershipError(message: "Couldn\u{2019}t sync your latest edits — try again once you\u{2019}re back online.")
            }
            _ = try await group.join(code: code, keepCopy: keepCopy)
            _ = await SupabaseSync.replaceLibrary(context: context)
            Haptics.success()
            joinedName = preview?.name ?? group.card?.name ?? "the group"
        } catch {
            note = (error as? MembershipError)?.message ?? SyncProblem(error).message
            preview = nil
        }
    }

    /// `hasStrings` does not trigger the paste banner. The contents are
    /// only read when they tap the offer.
    private func refreshClipboardOffer() async {
        clipboardOffer = UIPasteboard.general.hasStrings
    }

    private func useClipboard() {
        clipboardOffer = false
        guard let raw = UIPasteboard.general.string else {
            note = "Nothing on the clipboard."
            return
        }
        guard let found = GroupStore.normaliseCode(raw) else {
            note = "That wasn\u{2019}t an invite code."
            return
        }
        draft = GroupStore.formatCode(found)
        Task { await lookup() }
    }

    /// Caps at six code characters and drops the hyphen in after three.
    private static func formatTyping(_ raw: String) -> String {
        let chars = raw.uppercased().filter { GroupStore.codeAlphabet.contains($0) }
        let clipped = String(chars.prefix(6))
        if clipped.count > 3 {
            return "\(clipped.prefix(3))-\(clipped.dropFirst(3))"
        }
        return clipped
    }
}
