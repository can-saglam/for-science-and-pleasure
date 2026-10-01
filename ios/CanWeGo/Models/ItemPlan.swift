import Foundation

/// Plans: the day, and maybe the time, the group means to go. One per
/// save, shared like the save. On the day the server puts it on everyone's
/// Lock Screen (an hour before the time, or 10:00 without one); the morning
/// after, the app asks whether you made it.
extension Item {
    /// How far ahead a day can be planned.
    static let planHorizonDays = 365
    /// A timed plan's calendar entry runs this long.
    static let planCalendarHours = 2.0

    /// A plan still ahead, today included, on a save still on the list.
    var upcomingPlan: String? {
        guard !isDone, !isDeleted, let planOn, planOn >= DayString.today() else { return nil }
        return planOn
    }

    /// A plan whose day has gone by, waiting for the morning-after question.
    var planIsOver: Bool {
        guard !isDone, !isDeleted, let planOn else { return false }
        return planOn < DayString.today()
    }

    /// The days that can be planned: from today (or the day it opens)
    /// through the day it closes, at most a year out. Nil when none are left.
    var plannableDays: ClosedRange<String>? {
        guard !isDone, !isDeleted else { return nil }
        let today = DayString.today()
        var first = today
        var last = DayString.addingDays(Self.planHorizonDays, to: today) ?? today
        if isEvent {
            if let startsOn, startsOn > first { first = startsOn }
            if let endsOn, endsOn < last { last = endsOn }
        }
        return first <= last ? first...last : nil
    }

    var canPlan: Bool { plannableDays != nil }

    /// The moment a timed plan names, on the home clock.
    var planInstant: Date? {
        guard let planOn, let planTime else { return nil }
        return DayString.instant(day: planOn, time: planTime)
    }

    /// Who set it is the server's to say; this is just until the next pull.
    func setPlan(day: String, time: String?) {
        planOn = day
        planTime = time
        plannedBy = SupabaseAuth.shared.userId
    }

    func clearPlan() {
        planOn = nil
        planTime = nil
        plannedBy = nil
    }

    /// After the dates change: drop a plan they no longer allow. A day
    /// already gone by stays for the morning-after question.
    func reconcilePlan() {
        guard let planOn, planOn >= DayString.today() else { return }
        if !(plannableDays?.contains(planOn) ?? false) { clearPlan() }
    }

    /// "Today", "Tomorrow", "Tue" within the week, then "13 Oct".
    static func planDayName(_ day: String) -> String {
        switch DayString.daysFromToday(day) ?? 7 {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2..<7: return DayString.text(day, .dateTime.weekday(.abbreviated)) ?? day
        default: return DayString.text(day) ?? day
        }
    }

    /// The cards' phrasing ("Opens this Saturday"): "Today", "Tomorrow",
    /// "This Saturday", "Next Thursday" through next week, then "Tue 13 Oct".
    /// `inSentence` keeps the words lower case: "for this Saturday".
    static func planDayLongName(_ day: String, inSentence: Bool = false) -> String {
        if let days = DayString.daysFromToday(day), let friendly = Item.friendlyDay(days, day) {
            return inSentence ? friendly : friendly.prefix(1).uppercased() + friendly.dropFirst()
        }
        return DayString.text(day, .dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? day
    }

    /// The card's pill: "Tue · 17:00", "Sat", "Today · 5:00 PM".
    var planPillText: String? {
        guard let day = upcomingPlan else { return nil }
        guard let planTime else { return Self.planDayName(day) }
        return "\(Self.planDayName(day)) · \(OpeningHours.time(planTime))"
    }

    /// The details' Going row: "This Saturday · 17:00", "Tue 13 Oct".
    var planRowText: String? { planText(inSentence: false) }

    /// The same, mid-sentence: "for this Saturday · 17:00".
    var planSentenceText: String? { planText(inSentence: true) }

    private func planText(inSentence: Bool) -> String? {
        guard let day = upcomingPlan else { return nil }
        let name = Self.planDayLongName(day, inSentence: inSentence)
        guard let planTime else { return name }
        return "\(name) · \(OpeningHours.time(planTime))"
    }

    /// For VoiceOver: "Going this Saturday at 17:00".
    var planSpokenText: String? {
        guard let day = upcomingPlan else { return nil }
        let when = Self.planDayLongName(day, inSentence: true)
        guard let planTime else { return "Going \(when)" }
        return "Going \(when) at \(OpeningHours.time(planTime))"
    }
}
