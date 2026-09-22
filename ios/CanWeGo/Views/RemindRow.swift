import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Opt-in shared reminder. Off until they pick a preset that is still
/// ahead (past windows are hidden) or a day and time of their own. Places
/// have no dates, so their chip goes straight to the picker. Writes the
/// reminder fields on `item`. When `persist` is true (detail, already
/// saved) it stamps `updatedAt` and saves so sync picks the change up.
struct RemindRow: View {
    @Bindable var item: Item
    var persist = false
    @Environment(\.modelContext) private var context
    @State private var notificationsDenied = false
    @State private var pickingDate = false

    /// Presets need a date to hang off; places and undated events only
    /// get the picker.
    private var offersPresets: Bool { !item.availableReminderChoices.isEmpty }

    var body: some View {
        if item.canRemind {
            // The chip lives outside the Menu label. SwiftUI fades a
            // Menu's own label while the popover is up, and that used
            // to take the whole control with it.
            VStack(alignment: .leading, spacing: 8) {
            chip
                .overlay {
                    if offersPresets {
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
                    } else {
                        Button {
                            Haptics.tap()
                            pickingDate = true
                        } label: {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remind")
                        .accessibilityValue(item.reminderValueLabel)
                        .accessibilityHint("Pick a day and time")
                    }
                }
                .sheet(isPresented: $pickingDate) {
                    ReminderPickerSheet(
                        initial: item.suggestedCustomReminderDate,
                        canRemove: item.hasReminder
                    ) { picked in
                        chooseCustom(picked)
                    }
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
                .task { await refreshNotificationStatus() }

            if notificationsDenied, item.hasReminder {
                notificationFootnote
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
            try? context.save()
        }
    }

    @ViewBuilder
    private var notificationFootnote: some View {
        #if !APP_EXTENSION
        if let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Notifications are off, so reminders won\u{2019}t arrive. Open Settings.", destination: url)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        #else
        Text("Notifications are off, so reminders won\u{2019}t arrive until they\u{2019}re allowed.")
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
                // A menu flips open in place; the picker is a sheet.
                Image(systemName: offersPresets ? "chevron.up.chevron.down" : "chevron.right")
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
        Divider()
        Button {
            Haptics.tap()
            pickingDate = true
        } label: {
            if item.hasCustomReminder {
                Label(item.reminderValueLabel, systemImage: "checkmark")
            } else {
                Label("Pick a day and time\u{2026}", systemImage: "calendar.badge.clock")
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
        persistIfNeeded()
    }

    /// From the picker sheet: a date sets a hand-picked reminder, nil
    /// means "Remove reminder".
    private func chooseCustom(_ date: Date?) {
        Haptics.selection()
        if let date {
            item.applyCustomReminder(at: date)
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
        try? context.save()
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

/// Native day + time picker for a hand-picked reminder. Runs on the home
/// clock so everyone sharing the library reads the same moment; a footnote
/// says so when the phone is somewhere else. `onPick(nil)` removes.
struct ReminderPickerSheet: View {
    var initial: Date
    var canRemove: Bool
    var onPick: (Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(initial: Date, canRemove: Bool, onPick: @escaping (Date?) -> Void) {
        self.initial = initial
        self.canRemove = canRemove
        self.onPick = onPick
        _date = State(initialValue: initial)
    }

    private var homeZone: TimeZone { DayString.timeZone }

    private var awayFromHome: Bool {
        homeZone.secondsFromGMT(for: date) != TimeZone.current.secondsFromGMT(for: date)
    }

    /// "London" out of "Europe/London".
    private var homeZoneName: String {
        homeZone.identifier
            .split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
            ?? homeZone.identifier
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DatePicker(
                        "Remind on",
                        selection: $date,
                        in: Date.now...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                    .environment(\.timeZone, homeZone)
                    .tint(AppBackground.ink)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("A notification goes out at that moment to every phone on this library.")
                        if awayFromHome {
                            Text("Times are in \(homeZoneName) time, the library\u{2019}s home.")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if canRemove {
                        Button(role: .destructive) {
                            onPick(nil)
                            dismiss()
                        } label: {
                            Label("Remove reminder", systemImage: "bell.slash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Remind")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        onPick(date)
                        dismiss()
                    }
                    .disabled(date <= .now)
                }
            }
        }
        .presentationDetents([.large])
    }
}
