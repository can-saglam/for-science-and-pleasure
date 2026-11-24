import AuthenticationServices
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UserNotifications

extension OnboardingView {
    // MARK: Invite

    /// What this run saved first: the typed one, else the first ticked.
    var firstSave: Item? { parsed ?? savedPicks.first }

    /// Only for someone who chose to start a shared library, right after
    /// their first saves, so the invite has something in it worth opening.
    var invitePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("Now bring\nthem in")
            lede("Send this to whoever you go out with. It opens the app on their phone and puts them straight into your library.")

            if let firstSave {
                ItemCard(item: firstSave, awayHint: false)
                    .allowsHitTesting(false)
            }

            if let invite {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your invite code")
                            .font(.footnote)
                            .foregroundStyle(AppBackground.ink.opacity(0.72))
                        Text(invite.code)
                            .font(.displaySmallBold(30, relativeTo: .title2))
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    chip(copiedCode ? "Copied" : "Copy link", icon: copiedCode ? "checkmark" : "link") {
                        UIPasteboard.general.url = URL(string: GroupStore.inviteLink(invite.code))
                        copiedCode = true
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .transition(.opacity)
            } else if !inviteFailed {
                ProgressView().controlSize(.small).padding(.vertical, 8)
            }

            quiet("Later, from Settings") { advance() }

            noteLine
        }
        .animation(ease, value: invite?.code)
        .task { await loadInvite() }
        .sheet(isPresented: $sharingInvite) {
            ActivitySheet(items: [inviteMessage]) { sent in
                guard sent else { return }
                sharingInvite = false
                Haptics.success()
                advance()
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// The server's sentence (code and store link), led by the first save
    /// so it reads as a reason to come, not a sign-up.
    var inviteMessage: String {
        guard let invite else { return "" }
        let base = invite.message ?? "Join me on Can We Go? \(GroupStore.inviteLink(invite.code))"
        guard let title = firstSave?.title, !title.isEmpty else { return base }
        return "First on my list: \(title).\n\n\(base)"
    }

    func loadInvite() async {
        guard invite == nil, !inviteFailed else { return }
        if preview {
            invite = .init(code: "KV7-P2M", expiresAt: .now.addingTimeInterval(7 * 86_400), message: nil)
            return
        }
        do {
            invite = try await group.invite()
        } catch {
            inviteFailed = true
            note = "Couldn't make an invite just now. Send one any time from Settings."
        }
    }

    // MARK: Done

    /// The close: the three ways things get in from now on, the share
    /// sheet first because it's the one people don't find on their own.
    var donePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline("See it? Save it. Sort it.")
            lede("Next time something catches your eye, here\u{2019}s how to keep it.")

            VStack(alignment: .leading, spacing: 16) {
                row("square.and.arrow.up", "Share from anywhere",
                    "Tap Share in Instagram, Maps or Safari, then pick us from the row (or under More).")
                row("square.grid.2x2", "A widget for what's on",
                    "Hold the Home Screen, tap Edit, then Add Widget.")
                row("waveform", "Ask Siri",
                    "\u{201C}Add something to Can We Go?\u{201D} or \u{201C}What's closing soon in Can We Go?\u{201D}")
            }
        }
    }

    // MARK: Notify

    /// "Joyce", or "Joyce or Sam" in a bigger group: who the new-save
    /// ping is about.
    var partnerName: String? {
        groupmates.isEmpty ? nil : Self.listed(groupmates, "or")
    }

    /// What they saved on the page before, first pick first.
    var firstSaves: [Item] { [parsed].compactMap(\.self) + savedPicks }

    /// Any of their saves can be planned.
    var planExample: ShowcaseSave {
        firstSaves.first.map(ShowcaseSave.init) ?? .toor
    }

    /// A reminder is about a date: their first dated event, the one that
    /// runs for a while first. Places can't be reminded, so with none,
    /// an event on in their city from the suggestions; Salman Toor only
    /// when there are none of those either.
    var remindExample: ShowcaseSave {
        let events = firstSaves.filter { $0.isEvent && ($0.endsOn ?? $0.startsOn) != nil }
        if let pick = events.first(where: { $0.endsOn != nil && $0.endsOn != $0.startsOn }) ?? events.first {
            return ShowcaseSave(pick)
        }
        let today = DayString.today()
        let local = suggestions.events.filter {
            $0.image?.isEmpty == false && ($0.endsOn ?? $0.startsOn).map { $0 >= today } ?? false
        }
        let pick = local.first { $0.endsOn != nil && $0.endsOn != $0.startsOn } ?? local.first
        return pick.map(ShowcaseSave.init) ?? .toor
    }

    /// Plan and Remind, as they'd arrive. Only reminders need the
    /// notification permission this page asks for; a plan's Live Activity
    /// arrives either way, and the page says so.
    var notifyPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The title sits over the phone's faded top.
            ZStack(alignment: .topLeading) {
                PlanRemindStack(plan: planExample, remind: remindExample,
                                icon: themes.current.iconPreviewName, isLight: themes.current.isLight,
                               still: reduceMotion)
                   // At the column's full width it fills the open Duo's height.
                   .frame(maxWidth: sideBySide ? 340 : nil)
                   .frame(maxWidth: .infinity)
                   .padding(.top, 70)
                VStack(alignment: .leading, spacing: 8) {
                    headline("Never miss it.")
                    lede(partnerName == nil
                         ? "Pick the day you\u{2019}re going, or ask for a nudge before it closes."
                         : "Pick the day you\u{2019}re going, or ask for a nudge before it closes. You\u{2019}ll also hear when \(partnerName ?? "someone") adds something.")
                }
            }

            switch notifyStatus {
            case .denied:
                // Asking again would do nothing; iOS only prompts once.
                // Say so, and point at the switch that actually works.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) {
                        row("bell.slash", "Notifications are off for this app",
                            "Turn them on in iOS Settings and pings arrive from then on.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(AppBackground.wash(0.12), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            case .authorized, .provisional, .ephemeral:
                Label("Already on. Nothing more to do.", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
            default:
                EmptyView()
            }
        }
        .task {
            // Preview shows the ask as a new person would see it.
            guard !preview else { return }
            notifyStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }
}
