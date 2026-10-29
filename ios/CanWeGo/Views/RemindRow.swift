import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Opt-in shared reminder. Off until they pick a preset that is still
/// ahead (past windows are hidden). A day and time of their own is a plan
/// now (`PlanRow`); one set by hand on an older build still shows here,
/// checked, so it can be switched off. Saves with no dates to hang a
/// preset off get no row. Writes the reminder fields on `item`. When
/// `persist` is true (detail, already saved) it stamps `updatedAt` and
/// saves so sync picks the change up. `compact` draws only a bell button
/// and leaves the notifications footnote to the caller.
struct RemindRow: View {
    @Bindable var item: Item
    var persist = false
    var title = "Remind"
    var compact = false
    @Environment(\.modelContext) private var context

    private var offersPresets: Bool { !item.availableReminderChoices.isEmpty }

    var body: some View {
        if item.canRemind && (offersPresets || item.hasCustomReminder) {
            // The chip lives outside the Menu label. SwiftUI fades a
            // Menu's own label while the popover is up, and that used
            // to take the whole control with it.
            VStack(alignment: .leading, spacing: 8) {
            Group {
                if compact { bell } else { chip }
            }
                .overlay {
                    Menu {
                        menuContent
                    } label: {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(.rect)
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .tint(AppBackground.ink)
                    .accessibilityLabel(title)
                    .accessibilityValue(item.reminderValueLabel)
                }
                .onAppear(perform: tidyPersistedReminder)
                .onChange(of: item.startsOn) { _, _ in
                    guard !persist else { return }
                    item.reconcileReminder()
                }
                .onChange(of: item.endsOn) { _, _ in
                    guard !persist else { return }
                    item.reconcileReminder()
                }

            if !compact, item.hasReminder {
                NotificationsOffNote()
            }
            }
        } else if persist, item.hasReminder {
            // Ended events don't offer Remind, but a leftover one should
            // still be dropped the moment the card is opened.
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear(perform: tidyPersistedReminder)
        }
    }

    private func tidyPersistedReminder() {
        guard persist, item.hasReminder else { return }
        let before = item.remindAt
        item.reconcileReminder()
        if item.remindAt != before {
            item.updatedAt = .now
            item.stampAuthor()
            context.saveOrReport()
        }
    }

    private var bell: some View {
        Image(systemName: item.hasReminder ? "bell.fill" : "bell")
            .font(.subheadline)
            .foregroundStyle(AppBackground.ink.opacity(item.hasReminder ? 1 : 0.75))
            .frame(width: 44, height: 44)
            .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }

    private var chip: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.subheadline)
                .foregroundStyle(AppBackground.ink.opacity(0.35))
                .frame(width: 22)
            Text(title)
            Spacer()
            HStack(spacing: 5) {
                Text(item.reminderValueLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(AppBackground.theme.isLight ? AppBackground.secondaryInk : AppBackground.ink.opacity(0.55))
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var menuContent: some View {
        Button("Off") { choose(nil) }
        if item.asksReminderAnchor {
            let starts = item.availableReminderChoices.filter { $0.anchor == "starts_on" }
            let closes = item.availableReminderChoices.filter { $0.anchor == "ends_on" }
            if !starts.isEmpty {
                Section("Before it starts") {
                    ForEach(starts) { choice in
                        choiceButton(choice)
                    }
                }
            }
            if !closes.isEmpty {
                Section("Before it closes") {
                    ForEach(closes) { choice in
                        choiceButton(choice)
                    }
                }
            }
        } else {
            ForEach(item.availableReminderChoices) { choice in
                choiceButton(choice)
            }
        }
        if item.hasCustomReminder {
            Divider()
            Button {} label: {
                Label(item.reminderValueLabel, systemImage: "checkmark")
            }
        }
    }

    @ViewBuilder
    private func choiceButton(_ choice: ReminderChoice) -> some View {
        Button {
            choose(choice)
        } label: {
            if item.reminderOffsetDays == choice.offsetDays,
               item.reminderAnchor == choice.anchor {
                Label(choice.offsetLabel, systemImage: "checkmark")
            } else {
                Text(choice.offsetLabel)
            }
        }
    }

    private func choose(_ choice: ReminderChoice?) {
        Haptics.selection()
        if let choice {
            item.applyReminder(offset: choice.offsetDays, anchor: choice.anchor)
            if item.hasReminder { item.clearPlan() }
            requestNotificationPermission()
        } else {
            item.clearReminder()
        }
        persistIfNeeded()
    }

    private func persistIfNeeded() {
        guard persist else { return }
        item.updatedAt = .now
        item.stampAuthor()
        context.saveOrReport()
    }

    private func requestNotificationPermission() {
        Task {
            #if !APP_EXTENSION
            PushRegistrar.register()
            #else
            let center = UNUserNotificationCenter.current()
            if (await center.notificationSettings()).authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            #endif
            NotificationsOffNote.refresh()
        }
    }
}

/// Under a set reminder when notifications are denied: it won't arrive.
struct NotificationsOffNote: View {
    @State private var denied = false
    private static let changed = Notification.Name("CanWeGo.notificationStatusChanged")

    static func refresh() {
        NotificationCenter.default.post(name: changed, object: nil)
    }

    var body: some View {
        Group {
            if denied {
                #if !APP_EXTENSION
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Notifications are off, so reminders won\u{2019}t arrive. Open Settings.", destination: url)
                }
                #else
                Text("Notifications are off, so reminders won\u{2019}t arrive until they\u{2019}re allowed.")
                #endif
            }
        }
        .font(.footnote)
        .foregroundStyle(AppBackground.secondaryInk)
        .task { await check() }
        .onReceive(NotificationCenter.default.publisher(for: Self.changed)) { _ in
            Task { await check() }
        }
    }

    private func check() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        await MainActor.run { denied = status == .denied }
    }
}
