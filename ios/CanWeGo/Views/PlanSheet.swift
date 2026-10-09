import SwiftData
import SwiftUI

/// A save is planned or reminded, not both: a toggle picks which row shows,
/// and choosing in one drops the other. Switching the toggle alone changes
/// nothing. Only the row that applies shows when the other can't be used.
struct PlanOrRemind: View {
    @Bindable var item: Item
    @State private var mode: Mode

    enum Mode { case plan, remind }

    init(item: Item) {
        self.item = item
        _mode = State(initialValue: item.hasReminder && item.upcomingPlan == nil ? .remind : .plan)
    }

    private var plans: Bool { item.canPlan || item.upcomingPlan != nil }
    private var reminds: Bool { item.canRemind && (!item.availableReminderChoices.isEmpty || item.hasCustomReminder) }
    private var showsPlan: Bool { plans && (mode == .plan || !reminds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plans && reminds {
                Picker("Plan or remind", selection: $mode.animation(.snappy)) {
                    Text("Plan").tag(Mode.plan)
                    Text("Remind").tag(Mode.remind)
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: mode)
            }
            if showsPlan {
                PlanRow(item: item, title: reminds ? "Pick a day" : "Plan a day")
                if item.hasReminder, item.upcomingPlan == nil {
                    footnote("A plan replaces the reminder.")
                }
            } else {
                RemindRow(item: item, persist: true, title: plans && reminds ? "Pick an option" : "Remind")
                if reminds, let plan = item.planSentenceText, item.upcomingPlan != nil {
                    footnote("A reminder replaces the plan for \(plan).")
                }
            }
        }
        .onChange(of: item.planOn) { _, day in
            if day != nil { mode = .plan }
        }
        .onChange(of: item.remindAt) { _, day in
            if day != nil, item.planOn == nil { mode = .remind }
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AppBackground.secondaryInk)
            .padding(.leading, 4)
    }
}

/// The details' Going row: `title` until there's a plan, then the day
/// (and time). Opens the picker.
struct PlanRow: View {
    @Bindable var item: Item
    var title = "Plan a day"
    @State private var picking = false

    var body: some View {
        if item.canPlan || item.upcomingPlan != nil {
            Button {
                Haptics.tap()
                picking = true
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.upcomingPlan == nil ? title : "Going")
            .accessibilityValue(item.planRowText ?? "")
            .accessibilityHint("Pick the day you're going")
            .sheet(isPresented: $picking) {
                PlanSheet(item: item)
            }
        }
    }

    private var chip: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.subheadline)
                .foregroundStyle(AppBackground.ink.opacity(0.35))
                .frame(width: 22)
            Text(item.upcomingPlan == nil ? title : "Going")
            Spacer()
            HStack(spacing: 5) {
                if let text = item.planRowText {
                    Text(text)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(AppBackground.theme.isLight ? AppBackground.secondaryInk : AppBackground.ink.opacity(0.55))
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A save's showings where its dates would go, in the capture preview and
/// the details: a few as chips, more as a count. With `choose`, a chip
/// opens the plan on that showing; without, they only say when it's on.
struct ShowingsLine: View {
    let showings: [Showing]
    let dateLine: String?
    var choose: ((Showing) -> Void)? = nil

    /// Past this many, a list of showings is too long to scan: the details
    /// give a count and the plan sheet opens on its grid.
    static let chipLimit = 6

    var body: some View {
        if showings.count > Self.chipLimit {
            Text([dateLine, "\(showings.count) showings"].compactMap(\.self).joined(separator: " · "))
                .foregroundStyle(AppBackground.secondaryInk)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(showings, id: \.self) { chip($0) }
                }
            }
            .scrollClipDisabled()
            // Chips run on past the trailing edge, but stop at the leading
            // one rather than slide over the row's glyph.
            .mask { Rectangle().padding(.trailing, -1_000).padding(.vertical, -8) }
        }
    }

    @ViewBuilder
    private func chip(_ showing: Showing) -> some View {
        let label = HStack(spacing: 5) {
            Text(DayString.text(showing.date, .dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? showing.date)
                .foregroundStyle(AppBackground.secondaryInk)
            if let time = showing.time {
                Text(OpeningHours.time(time))
                    .monospacedDigit()
                    .foregroundStyle(AppBackground.ink)
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background(AppBackground.wash(0.07), in: .capsule)
        .contentShape(.capsule)

        let spoken = [
            DayString.text(showing.date, .dateTime.weekday(.wide).day().month(.wide)) ?? showing.date,
            showing.time.map(OpeningHours.time),
            showing.note,
        ].compactMap(\.self).joined(separator: ", ")

        if let choose {
            Button {
                Haptics.tap()
                choose(showing)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken)
            .accessibilityHint("Plan this showing")
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }
}

/// Picks the day, and maybe the time, the group means to go: the next two
/// weeks as a grid (days outside the event's run can't be picked; days the
/// venue is usually closed are marked but can), a calendar for later, and
/// an optional time. A save with a few showings opens on those instead,
/// the grid one tap away; in the grid, showing days are marked and picking
/// one offers its times. Says when it'll be on the Lock Screen, and warns
/// when the time falls outside the venue's hours. Everything is on the
/// home clock, like reminders.
struct PlanSheet: View {
    @Bindable var item: Item
    /// Called after a save or a removal, before the sheet goes.
    var onFinish: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var day: String?
    @State private var timed: Bool
    @State private var time: Date
    @State private var later: Bool
    @State private var hours: OpeningHours?
    /// The time put forward for them; nil once they've picked their own.
    @State private var suggested: String?
    /// Half height for the grid; the calendar for a later date needs the rest.
    @State private var detent: PresentationDetent
    /// The showings list in place of the grid.
    @State private var listing: Bool
    /// They want a time of their own on a showing day, not one of its times.
    @State private var ownTime: Bool

    private let showings: [Showing]

    private static let gridDays = 14
    private static let defaultTime = "14:00"

    /// `showing`: the one they tapped in the details, picked from the start.
    init(item: Item, showing chosen: Showing? = nil, onFinish: (() -> Void)? = nil) {
        self.item = item
        self.onFinish = onFinish
        let today = DayString.today()
        let planned = item.upcomingPlan
        let list = Self.showings(of: item)
        showings = list
        // Without a plan, the first showing still ahead is put forward.
        let showing = chosen ?? (planned == nil ? list.first : nil)
        let plannedShowings = list.filter { $0.date == planned }
        let plannedIsShowing = plannedShowings.contains { $0.time == item.planTime }
        let listing = !list.isEmpty && list.count <= ShowingsLine.chipLimit
            && (chosen != nil || planned == nil || plannedIsShowing)
        _listing = State(initialValue: listing)
        _ownTime = State(initialValue: chosen == nil && !plannedShowings.isEmpty && !plannedIsShowing)
        let first = showing?.date ?? item.plannableDays?.lowerBound ?? today
        let grid = DayString.addingDays(Self.gridDays - 1, to: today) ?? today
        let day = showing?.date ?? planned ?? (first <= grid ? first : nil)
        _day = State(initialValue: day)
        let own = showing != nil ? showing?.time : planned != nil ? item.planTime : nil
        _timed = State(initialValue: own != nil)
        let clock = own ?? Self.suggestedTime(day: day, ranges: nil)
        _time = State(initialValue: DayString.instant(day: today, time: clock) ?? .now)
        _suggested = State(initialValue: own == nil ? clock : nil)
        let later = (day ?? first) > grid
        _later = State(initialValue: later)
        _detent = State(initialValue: later && !listing ? .large : .medium)
    }

    /// The listed showings that can still be planned: in the run, and not
    /// already started today.
    static func showings(of item: Item) -> [Showing] {
        guard let range = item.plannableDays else { return [] }
        let today = DayString.today()
        return item.showings.filter { showing in
            guard range.contains(showing.date) else { return false }
            guard showing.date == today, let time = showing.time,
                  let at = DayString.instant(day: today, time: time)
            else { return true }
            return at > .now
        }
    }

    /// 14:00 when the venue is open then with an hour to spare, otherwise the
    /// first whole hour it's open that day; today, never sooner than a whole
    /// hour at least an hour out.
    private static func suggestedTime(day: String?, ranges: [OpeningHours.Range]?) -> String {
        func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        let usual = OpeningHours.minutes(defaultTime)
        var earliest = 0
        if day == nil || day == DayString.today() {
            let now = DayString.calendar.dateComponents([.hour, .minute], from: .now)
            let soon = (now.hour ?? 0) * 60 + (now.minute ?? 0) + 60
            earliest = min(23 * 60, (soon + 59) / 60 * 60)
        }
        if let ranges, !ranges.isEmpty, !OpeningHours.isAllDay(ranges) {
            let fits = ranges.contains {
                usual >= max(OpeningHours.minutes($0.open), earliest) && usual <= OpeningHours.closeMinutes($0) - 60
            }
            if fits { return defaultTime }
            for range in ranges {
                let start = max((OpeningHours.minutes(range.open) + 59) / 60 * 60, earliest)
                if start < OpeningHours.closeMinutes(range), start < 24 * 60 { return hm(start) }
            }
        }
        return hm(max(usual, earliest))
    }

    /// Follows the day (and its hours) until they set a time of their own.
    private func resuggest() {
        guard let suggested else { return }
        guard clock == suggested else {
            self.suggested = nil
            return
        }
        let next = Self.suggestedTime(day: day, ranges: day.flatMap(ranges))
        guard next != suggested, let at = DayString.instant(day: today, time: next) else { return }
        time = at
        self.suggested = next
    }

    private var today: String { DayString.today() }

    private var gridDays: [String] {
        (0..<Self.gridDays).compactMap { DayString.addingDays($0, to: today) }
    }

    private var range: ClosedRange<String>? { item.plannableDays }

    private func pickable(_ day: String) -> Bool { range?.contains(day) ?? false }

    /// Some plannable day lies past the grid.
    private var offersLater: Bool {
        guard let range, let lastInGrid = gridDays.last else { return false }
        return range.upperBound > lastInGrid
    }

    private var showsClosedLegend: Bool {
        gridDays.contains { pickable($0) && !showingDays.contains($0) && ranges($0)?.isEmpty == true }
    }

    private var showingDays: Set<String> { Set(showings.map(\.date)) }

    private var showsShowingLegend: Bool { gridDays.contains(where: showingDays.contains) }

    private var clock: String { DayString.time(time) }

    private var venueName: String {
        if item.isPlace { return item.title }
        return item.venue ?? "The venue"
    }

    private func ranges(_ day: String) -> [OpeningHours.Range]? {
        hours?.ranges(on: day)
    }

    private var timeHasPassed: Bool {
        guard timed, let day, day == today,
              let at = DayString.instant(day: day, time: clock)
        else { return false }
        return at <= .now
    }

    private var canSave: Bool {
        guard let day, pickable(day) else { return false }
        return !timeHasPassed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if listing {
                        showingsList
                    } else {
                        if later {
                            laterPicker
                        } else {
                            grid
                            if offersLater || canList || showsClosedLegend || showsShowingLegend {
                                gridFooter
                            }
                        }

                        if let day {
                            dayLine(day)
                        }

                        timeSection
                    }

                    notes

                    if item.upcomingPlan != nil {
                        Button(role: .destructive) {
                            Haptics.tap()
                            finish(nil)
                        } label: {
                            Label("Remove plan", systemImage: "calendar.badge.minus")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .destructiveGlass()
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            // Pinned, so saving is in reach at half height and at big text
            // sizes alike.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    guard let day else { return }
                    Haptics.success()
                    finish((day, timed ? clock : nil))
                } label: {
                    Text("Save plan")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .prominentGlass()
                .controlSize(.large)
                .disabled(!canSave)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .background {
                    LinearGradient(
                        stops: [.init(color: AppBackground.sheet.opacity(0), location: 0),
                                .init(color: AppBackground.sheet, location: 0.35)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }
            }
            .background { ThemeFill(color: AppBackground.sheet) }
            .sheetTitle("Plan a day") { dismiss() }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(AppBackground.sheet)
        .onAppear { if typeSize.isAccessibilitySize { detent = .large } }
        .onChange(of: later) { _, later in
            if later { detent = .large }
        }
        .onChange(of: day) { _, day in
            resuggest()
            settle(on: day)
        }
        .onChange(of: hours) { _, _ in resuggest() }
        .onChange(of: timed) { _, on in
            if on { resuggest() }
        }
        .task { await loadHours() }
    }

    // MARK: - Showings

    /// Few enough to list instead of the grid.
    private var canList: Bool { !showings.isEmpty && showings.count <= ShowingsLine.chipLimit }

    private func showings(on day: String) -> [Showing] { showings.filter { $0.date == day } }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppBackground.secondaryInk)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// One tap picks a showing's day and time; another day is a tap away.
    private var showingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Showings")
            VStack(spacing: 6) {
                ForEach(showings, id: \.self) { showingRow($0) }
            }
            Button {
                Haptics.tap()
                withAnimation(.snappy) {
                    listing = false
                    later = day.map { !gridDays.contains($0) } ?? false
                }
                if later { detent = .large }
            } label: {
                Label("Another day", systemImage: "calendar")
                    .font(.subheadline)
            }
            .tint(AppBackground.ink)
            .padding(.top, 6)
        }
    }

    /// "Sat 10 Oct   10:30   Paintworks, Bristol".
    private func showingRow(_ showing: Showing) -> some View {
        let chosen = isChosen(showing)
        return Button {
            Haptics.selection()
            choose(showing)
        } label: {
            HStack(spacing: 12) {
                Text(DayString.text(showing.date, .dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? showing.date)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(chosen ? AppBackground.base.opacity(0.8) : AppBackground.secondaryInk)
                    .frame(minWidth: 88, alignment: .leading)
                Text(showing.time.map(OpeningHours.time) ?? "Any time")
                    .font(.body.weight(chosen ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(chosen ? AppBackground.base : AppBackground.ink)
                Spacer(minLength: 8)
                if let note = showing.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(chosen ? AppBackground.base.opacity(0.8) : AppBackground.secondaryInk)
                        .lineLimit(1)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(chosen ? AppBackground.ink : AppBackground.wash(0.06))
            }
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken(showing))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func spoken(_ showing: Showing) -> String {
        [
            DayString.text(showing.date, .dateTime.weekday(.wide).day().month(.wide)) ?? showing.date,
            showing.time.map(OpeningHours.time),
            showing.note,
        ].compactMap(\.self).joined(separator: ", ")
    }

    /// A day picked in the grid that has showings starts on its first one,
    /// so what's highlighted is what gets saved.
    private func settle(on day: String?) {
        ownTime = false
        guard let day, !showings.contains(where: isChosen),
              let first = showings(on: day).first
        else { return }
        choose(first)
    }

    private func isChosen(_ showing: Showing) -> Bool {
        guard day == showing.date else { return false }
        guard let time = showing.time else { return !timed }
        return timed && clock == time
    }

    private func choose(_ showing: Showing) {
        withAnimation(.snappy) {
            day = showing.date
            if let clock = showing.time, let at = DayString.instant(day: today, time: clock) {
                time = at
                timed = true
                suggested = nil
            } else {
                timed = false
            }
            if !listing, !gridDays.contains(showing.date) { later = true }
        }
    }

    /// The day's own times where the time row would go, and a way out to
    /// one of their own.
    @ViewBuilder
    private var timeSection: some View {
        if let day, !ownTime, case let times = showings(on: day), !times.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header(times.count == 1 ? "Showing" : "Showings that day")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(times, id: \.self) { timeChip($0) }
                        otherTimeChip
                    }
                    // Every chip as tall as the tallest, noted or not.
                    .fixedSize(horizontal: false, vertical: true)
                }
                .scrollClipDisabled()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Add a time", isOn: $timed.animation(.snappy))
                if timed {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, DayString.timeZone)
                }
            }
            .tint(AppBackground.accent)
            .padding(12)
            .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        }
    }

    private var otherTimeChip: some View {
        Button {
            Haptics.tap()
            withAnimation(.snappy) {
                ownTime = true
                timed = true
            }
        } label: {
            Text("Other time")
                .font(.subheadline)
                .foregroundStyle(AppBackground.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 44, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppBackground.ink.opacity(0.2), lineWidth: 1)
                }
                .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// "18:15" and the note the page printed with it.
    private func timeChip(_ showing: Showing) -> some View {
        let chosen = isChosen(showing)
        return Button {
            Haptics.selection()
            choose(showing)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(showing.time.map(OpeningHours.time) ?? "Any time")
                    .font(.body.weight(chosen ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(chosen ? AppBackground.base : AppBackground.ink)
                if let note = showing.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(chosen ? AppBackground.base.opacity(0.8) : AppBackground.secondaryInk)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 72, minHeight: 44, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(chosen ? AppBackground.ink : AppBackground.wash(0.06))
            }
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken(showing))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// The links out of the grid, and what its dots mean.
    private var gridFooter: some View {
        let links = HStack(spacing: 18) {
            if canList {
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) {
                        listing = true
                        if !showings.contains(where: isChosen),
                           let back = showings.first(where: { $0.date == day }) ?? showings.first {
                            choose(back)
                        }
                    }
                } label: {
                    Label("Showings", systemImage: "list.bullet")
                }
            }
            if offersLater {
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { later = true }
                } label: {
                    Label("A later date", systemImage: "calendar")
                }
            }
        }
        .font(.subheadline)
        .tint(AppBackground.ink)

        let legend = HStack(spacing: 12) {
            if showsShowingLegend { legendDot(AppBackground.ink, "Showing") }
            if showsClosedLegend { legendDot(AppBackground.warning, "Usually closed") }
        }
        .font(.caption)
        .foregroundStyle(AppBackground.secondaryInk)
        .accessibilityHidden(true)

        return ViewThatFits(in: .horizontal) {
            HStack {
                links
                Spacer(minLength: 12)
                legend
            }
            VStack(alignment: .leading, spacing: 10) {
                links
                legend
            }
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(text)
        }
    }

    // MARK: - Days

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(gridDays, id: \.self) { d in
                dayCell(d)
            }
        }
    }

    private func dayCell(_ d: String) -> some View {
        let open = pickable(d)
        let selected = d == day
        let shows = open && showingDays.contains(d)
        // A showing that day says it's on, whatever the usual hours.
        let closed = !shows && ranges(d)?.isEmpty == true
        let dot: Color = shows
            ? (selected ? AppBackground.base : AppBackground.ink)
            : closed && open ? AppBackground.warning : .clear
        return Button {
            Haptics.selection()
            withAnimation(.snappy) { day = d }
        } label: {
            VStack(spacing: 2) {
                Text(DayString.text(d, .dateTime.weekday(.abbreviated)) ?? "")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selected ? AppBackground.base.opacity(0.8) : AppBackground.secondaryInk)
                Text(DayString.text(d, .dateTime.day()) ?? "")
                    .font(.body.weight(selected ? .semibold : .regular))
                    .monospacedDigit()
                    .strikethrough(!open)
                    .foregroundStyle(selected ? AppBackground.base : open ? AppBackground.ink : AppBackground.secondaryInk.opacity(0.5))
                Circle()
                    .fill(dot)
                    .frame(width: 4, height: 4)
            }
            // Seven to a row: past this size the date breaks over two lines
            // and the weekday clips.
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AppBackground.ink : AppBackground.wash(open ? 0.06 : 0.02))
            }
            .overlay {
                if d == today && !selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppBackground.ink.opacity(0.35), lineWidth: 1)
                }
            }
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!open)
        .accessibilityLabel(
            (d == today ? "Today, " : "") + (DayString.text(d, .dateTime.weekday(.wide).day().month(.wide)) ?? d)
        )
        .accessibilityValue(shows ? "Showing" : closed && open ? "Usually closed" : open ? "" : "Not on")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var laterPicker: some View {
        let lower = range.flatMap { DayString.date($0.lowerBound) } ?? .now
        let upper = range.flatMap { DayString.date($0.upperBound) } ?? lower
        return VStack(alignment: .leading, spacing: 8) {
            DatePicker(
                "Day",
                selection: Binding(
                    get: { day.flatMap(DayString.date) ?? lower },
                    set: { day = DayString.dayAndTime($0).day }
                ),
                in: lower...max(lower, upper),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .environment(\.timeZone, DayString.timeZone)
            .tint(AppBackground.ink)

            Button {
                Haptics.tap()
                withAnimation(.snappy) {
                    later = false
                    if let d = day, !gridDays.contains(d) { day = gridDays.first(where: pickable) }
                }
            } label: {
                Label("The next two weeks", systemImage: "square.grid.3x2")
                    .font(.subheadline)
            }
            .tint(AppBackground.ink)
        }
    }

    /// "Tuesday 6 October · Open 10:00–18:00".
    private func dayLine(_ d: String) -> some View {
        let name = DayString.text(d, .dateTime.weekday(.wide).day().month(.wide)) ?? d
        var open = ""
        if let hours, let r = hours.ranges(on: d) {
            let exact = hours.knowsExactly(d)
            open = r.isEmpty ? (exact ? "Closed" : "Usually closed") : OpeningHours.rangesText(r)
        }
        let title = Text(name).font(.body.weight(.semibold)).foregroundStyle(AppBackground.ink)
        let detail = Text(open.isEmpty ? "" : "  ·  \(open)").font(.subheadline).foregroundStyle(AppBackground.secondaryInk)
        return Text("\(title)\(detail)")
            .contentTransition(.opacity)
    }

    // MARK: - What it means

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let warning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .foregroundStyle(AppBackground.warning)
            }
            if let lockScreen {
                Text(lockScreen)
            }
            if awayFromHome {
                Text("Times are in \(homeZoneName) time, the library\u{2019}s home.")
            }
        }
        .font(.footnote)
        .foregroundStyle(AppBackground.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var warning: String? {
        guard let day else { return nil }
        if timeHasPassed { return "That time has already gone today." }
        guard let r = ranges(day) else { return nil }
        let exact = hours?.knowsExactly(day) ?? false
        if r.isEmpty {
            return exact
                ? "\(venueName) is closed that day."
                : "\(venueName) is usually closed that day."
        }
        guard timed, OpeningHours.range(r, containing: clock) == nil else { return nil }
        if OpeningHours.isAllDay(r) { return nil }
        return "\(venueName) is open \(OpeningHours.rangesText(r)) that day."
    }

    /// "It will appear on your Lock Screen from 16:00 to 18:00." The server's rule: an
    /// hour before the time (10:00 without one), until closing, four hours
    /// after the time, or midnight, whichever comes first.
    private var lockScreen: String? {
        guard let day, !timeHasPassed else { return nil }
        let t = timed ? OpeningHours.minutes(clock) : nil
        var start = t.map { max(0, $0 - 60) } ?? 10 * 60
        if day == today {
            let now = DayString.calendar.dateComponents([.hour, .minute], from: .now)
            let nowMinutes = (now.hour ?? 0) * 60 + (now.minute ?? 0)
            if t == nil && nowMinutes >= 23 * 60 { return nil }
            start = max(start, nowMinutes)
        }
        var end = min(start + 8 * 60, 24 * 60)
        if let t { end = min(end, t + 4 * 60) }
        if let r = ranges(day), !r.isEmpty {
            let within = t.flatMap { OpeningHours.range(r, containing: String(format: "%02d:%02d", $0 / 60, $0 % 60)) }
                ?? (t == nil ? r.last : nil)
            if let within {
                let close = OpeningHours.closeMinutes(within)
                if close < 24 * 60 && close > start { end = min(end, close) }
            }
        }
        guard end - start > 15 else { return nil }
        func hm(_ m: Int) -> String {
            m >= 24 * 60 ? "midnight" : OpeningHours.time(String(format: "%02d:%02d", m / 60, m % 60))
        }
        return "It will appear on your Lock Screen from \(hm(start)) to \(hm(end))."
    }

    private var homeZoneName: String {
        let zone = DayString.timeZone
        return zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
            ?? zone.identifier
    }

    private var awayFromHome: Bool {
        DayString.timeZone.secondsFromGMT(for: time) != TimeZone.current.secondsFromGMT(for: time)
    }

    // MARK: - Saving

    private func finish(_ plan: (day: String, time: String?)?) {
        if let plan {
            item.setPlan(day: plan.day, time: plan.time)
            item.clearReminder()
            #if !APP_EXTENSION
            PushRegistrar.register()
            #endif
        } else {
            item.clearPlan()
        }
        item.updatedAt = .now
        try? context.save()
        onFinish?()
        dismiss()
    }

    private func loadHours() async {
        guard item.hoursApply else { return }
        let loaded = await HoursClient.load(item, planning: true)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) { hours = loaded }
    }
}
