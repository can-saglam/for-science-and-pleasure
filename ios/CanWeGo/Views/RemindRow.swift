import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Opt-in shared reminder. Off until they pick a preset that is still
/// ahead; past windows are hidden. Writes the three reminder fields on
/// `item`. When `persist` is true (detail, already saved) it stamps
/// `updatedAt` and saves so sync picks the change up.
struct RemindRow: View {
    @Bindable var item: Item
    var persist = false
    @Environment(\.modelContext) private var context
    @State private var notificationsDenied = false

    var body: some View {
        if item.canRemind || item.hasReminder {
            // The chip lives outside the Menu label. SwiftUI fades a
            // Menu's own label while the popover is up, and that used
            // to take the whole control with it.
            VStack(alignment: .leading, spacing: 8) {
            chip
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
                    .accessibilityLabel("Remind")
                    .accessibilityValue(item.reminderValueLabel)
                }
                .onAppear {
                    guard persist, item.hasReminder else { return }
                    let before = item.remindAt
                    item.reconcileReminder()
                    if item.remindAt != before {
                        item.updatedAt = .now
                        try? context.save()
                    }
                }
                .onChange(of: item.startsOn) { _, _ in
                    guard !persist else { return }
                    item.reconcileReminder()
                }
                .onChange(of: item.endsOn) { _, _ in
                    guard !persist else { return }
                    item.reconcileReminder()
                }
                .task { await refreshNotificationStatus() }

            if notificationsDenied, item.hasReminder {
                notificationFootnote
            }
            }
        }
    }

    @ViewBuilder
    private var notificationFootnote: some View {
        #if !APP_EXTENSION
        if let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Notifications are off — reminders won\u{2019}t arrive. Open Settings.", destination: url)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        #else
        Text("Notifications are off — reminders won\u{2019}t arrive until they\u{2019}re allowed.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        #endif
    }

    private var chip: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.subheadline)
                .foregroundStyle(AppBackground.ink.opacity(0.35))
                .frame(width: 22)
            Text("Remind")
            Spacer()
            HStack(spacing: 5) {
                Text(item.reminderValueLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(AppBackground.ink.opacity(0.55))
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
            requestNotificationPermission()
        } else {
            item.clearReminder()
        }
        if persist {
            item.updatedAt = .now
            try? context.save()
        }
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
            await refreshNotificationStatus()
        }
    }

    private func refreshNotificationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        await MainActor.run {
            notificationsDenied = status == .denied
        }
    }
}
