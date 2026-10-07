import SwiftUI

/// The journal's line for the year: "You've been to 23 things this year".
/// Absent until something has been marked done this year.
struct JournalTally: View {
    let items: [Item]

    private var text: String? {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: .now)
        let n = items.filter { calendar.component(.year, from: $0.wentDate) == year }.count
        guard n > 0 else { return nil }
        let places = items.first?.isPlace == true
        let noun = places ? (n == 1 ? "place" : "places") : (n == 1 ? "thing" : "things")
        return "You've been to \(n) \(noun) this year"
    }

    var body: some View {
        if let text {
            Text(text)
                .font(.displaySmallBold(22, relativeTo: .title3))
                .foregroundStyle(AppBackground.ink)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

extension Item {
    /// The day it was marked done, or failing that (saves done before
    /// 0045) the planned day, if that's gone by.
    var wentDay: String? {
        if let wentOn { return wentOn }
        if let planOn, planOn <= DayString.today() { return planOn }
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
}
