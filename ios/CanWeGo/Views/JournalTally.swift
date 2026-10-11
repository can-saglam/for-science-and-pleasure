import SwiftUI

/// One year of the journal, its saves split by month, newest first.
struct JournalYear: Identifiable {
    let year: Int
    let months: [JournalMonth]
    var id: Int { year }
    var count: Int { months.reduce(0) { $0 + $1.items.count } }

    /// `items` must already run newest first by `date`.
    static func group(_ items: [Item], by date: (Item) -> Date) -> [JournalYear] {
        let calendar = DayString.calendar
        var years: [JournalYear] = []
        var months: [JournalMonth] = []
        var current: [Item] = []
        var key: (year: Int, month: Int)?
        func closeMonth() {
            guard let key, !current.isEmpty else { return }
            months.append(JournalMonth(year: key.year, month: key.month, items: current))
            current = []
        }
        func closeYear() {
            closeMonth()
            guard let key, !months.isEmpty else { return }
            years.append(JournalYear(year: key.year, months: months))
            months = []
        }
        for item in items {
            let parts = calendar.dateComponents([.year, .month], from: date(item))
            let next = (year: parts.year ?? 0, month: parts.month ?? 1)
            if let key, key.year != next.year {
                closeYear()
            } else if let key, key.month != next.month {
                closeMonth()
            }
            key = next
            current.append(item)
        }
        closeYear()
        return years
    }
}

struct JournalMonth: Identifiable {
    let year: Int
    let month: Int
    let items: [Item]
    var id: Int { year * 100 + month }
    /// The home calendar carries no month names; the system one does.
    var name: String { Calendar.current.standaloneMonthSymbols[month - 1] }
}

/// "2025  31 things": a year of the journal, tapped to open or fold it.
struct JournalYearHeader: View {
    let year: Int
    let count: String
    let open: Bool
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: String(year))
                    .font(.displaySmallBold(22, relativeTo: .title3))
                    .foregroundStyle(AppBackground.ink)
                Text(count)
                    .font(.footnote)
                    .foregroundStyle(AppBackground.ink.opacity(SectionHeader.countOpacity))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppBackground.ink.opacity(SectionHeader.titleOpacity))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .animation(reduceMotion ? nil : .snappy, value: open)
            }
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("\(year), \(count)")
        .accessibilityHint(open ? "Collapse" : "Expand")
        .accessibilityAddTraits(.isHeader)
    }
}

/// "OCTOBER", faint, over that month's saves.
struct JournalMonthLabel: View {
    let name: String

    var body: some View {
        Text(name.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(AppBackground.secondaryInk.opacity(0.6))
            .padding(.leading, 4)
            .padding(.top, 6)
    }
}

extension Item {
    /// The day it was marked done, or failing that (saves done before
    /// 0045) the planned day, if that's gone by.
    var wentDay: String? {
        let today = DayString.today()
        if let wentOn { return wentOn }
        if let planOn, planOn <= today { return planOn }
        // A one-day event can only have been gone to on its day.
        if isEvent, let startsOn, endsOn == nil || endsOn == startsOn, startsOn <= today { return startsOn }
        return nil
    }

    /// For counting by year: the known day, else when it was last touched.
    var wentDate: Date {
        wentDay.flatMap(DayString.date) ?? updatedAt
    }

    /// "Went 10 Sep" on a journal card, when the day is known.
    var wentLabel: String? {
        wentDay.flatMap { DayString.text($0, .dateTime.day().month(.abbreviated)) }.map { "Went \($0)" }
    }

    /// "Ended 4 Oct" on a missed card in the archive.
    var endedLabel: String? {
        (endsOn ?? startsOn).flatMap { DayString.text($0, .dateTime.day().month(.abbreviated)) }.map { "Ended \($0)" }
    }
}
