import Foundation

/// When a routine's trigger falls, as arithmetic over a calendar: the latest
/// occurrence at or before a moment, the next one after it, and which
/// occurrences are owed. Pure, so "does a brief missed overnight still run?"
/// is answered without a clock or a timer.
///
/// Times are the Mac's own local time. A week holds every weekday, so every
/// search here looks across eight days and no further.
package struct RoutineSchedule: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        /// Once a day, at this minute of it.
        case at(minute: Int)
        /// Every `minutes`, from `from` up to and including `until`.
        case every(minutes: Int, from: Int, until: Int)
    }

    package let kind: Kind
    /// `Calendar` weekday numbers, 1 for Sunday; all seven when unrestricted.
    package let weekdays: Set<Int>

    package init(kind: Kind, weekdays: Set<Int> = Set(1...7)) {
        self.kind = kind
        self.weekdays = weekdays
    }

    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static let minutesInDay = 24 * 60
    /// Today and the seven days either side that a weekly pattern can reach.
    private static let reach = 0...7

    // MARK: - Reading a trigger

    package static func parse(_ trigger: Routine.Trigger) -> Result<RoutineSchedule, Routine.Refusal> {
        var problems: [String] = []
        let weekdays = self.weekdays(trigger.days, problems: &problems)
        let kind = self.kind(trigger, problems: &problems)
        guard problems.isEmpty, let kind else { return .failure(Routine.Refusal(problems: problems)) }
        return .success(RoutineSchedule(kind: kind, weekdays: weekdays))
    }

    private static func weekdays(_ days: [String]?, problems: inout [String]) -> Set<Int> {
        guard let days else { return Set(1...7) }
        let numbers = days.compactMap { dayNames.firstIndex(of: $0.lowercased()).map { $0 + 1 } }
        if numbers.count != days.count || days.isEmpty {
            problems.append("\"days\" takes one or more of \(dayNames.joined(separator: ", "))")
        }
        return Set(numbers)
    }

    private static func kind(_ trigger: Routine.Trigger, problems: inout [String]) -> Kind? {
        switch (trigger.at, trigger.every) {
        case (let at?, nil):
            guard let minute = minuteOfDay(at) else {
                problems.append("\"at\" is a time of day as HH:mm")
                return nil
            }
            return .at(minute: minute)
        case (nil, let every?):
            return interval(every, trigger, problems: &problems)
        default:
            problems.append("the trigger takes either \"at\" or \"every\"")
            return nil
        }
    }

    private static func interval(_ every: Int, _ trigger: Routine.Trigger, problems: inout [String]) -> Kind? {
        let from = trigger.from.map(minuteOfDay) ?? 0
        let until = trigger.until.map(minuteOfDay) ?? minutesInDay - 1
        guard every > 0 else {
            problems.append("\"every\" is a number of minutes above zero")
            return nil
        }
        guard let from, let until, from <= until else {
            problems.append("\"from\" and \"until\" are times of day as HH:mm, \"from\" the earlier")
            return nil
        }
        return .every(minutes: every, from: from, until: until)
    }

    /// `HH:mm` as minutes past midnight; nil for anything else.
    static func minuteOfDay(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    // MARK: - Occurrences

    /// The latest occurrence at or before `moment`; nil for a pattern with none
    /// in the week behind it.
    package func latestOccurrence(atOrBefore moment: Date, calendar: Calendar) -> Date? {
        for back in Self.reach {
            guard let day = day(offset: -back, from: moment, calendar: calendar) else { continue }
            if let found = occurrences(on: day, calendar: calendar).last(where: { $0 <= moment }) { return found }
        }
        return nil
    }

    /// The first occurrence after `moment`.
    package func nextOccurrence(after moment: Date, calendar: Calendar) -> Date? {
        for ahead in Self.reach {
            guard let day = day(offset: ahead, from: moment, calendar: calendar) else { continue }
            if let found = occurrences(on: day, calendar: calendar).first(where: { $0 > moment }) { return found }
        }
        return nil
    }

    /// The occurrence owed at `now`, given the last one already handled — or
    /// nil when nothing is.
    ///
    /// A daily routine missed while the Mac slept is still owed when it wakes:
    /// the brief is late, not gone. A poll is different — once its own interval
    /// has passed the next poll has replaced it, and outside its hours nobody
    /// asked for one — so an interval's occurrence is owed only until the one
    /// after it would have come.
    package func owed(at now: Date, handledThrough: Date, calendar: Calendar) -> Date? {
        guard let latest = latestOccurrence(atOrBefore: now, calendar: calendar), latest > handledThrough else {
            return nil
        }
        if case .every(let minutes, _, _) = kind, now >= latest.addingTimeInterval(Double(minutes) * 60) {
            return nil
        }
        return latest
    }

    private func day(offset: Int, from moment: Date, calendar: Calendar) -> Date? {
        guard let shifted = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: moment)),
              weekdays.contains(calendar.component(.weekday, from: shifted)) else { return nil }
        return shifted
    }

    /// Every occurrence on the day that starts at `day`, earliest first.
    private func occurrences(on day: Date, calendar: Calendar) -> [Date] {
        let minutes: [Int]
        switch kind {
        case .at(let minute): minutes = [minute]
        case .every(let step, let from, let until): minutes = Array(stride(from: from, through: until, by: step))
        }
        return minutes.compactMap {
            calendar.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: day)
        }
    }

    // MARK: - In words

    /// The pattern as a person reads it: "Weekdays at 07:00", "Every 30 min,
    /// 08:00–18:00, Mon Wed".
    package var words: String {
        let days = dayWords
        switch kind {
        case .at(let minute):
            return "\(days ?? "Daily") at \(Self.clock(minute))"
        case .every(let step, let from, let until):
            let whole = from == 0 && until == Self.minutesInDay - 1
            let hours = whole ? nil : "\(Self.clock(from))–\(Self.clock(until))"
            return (["Every \(step) min"] + [hours, days].compactMap { $0 }).joined(separator: ", ")
        }
    }

    private var dayWords: String? {
        if weekdays.count == 7 { return nil }
        if weekdays == Set(2...6) { return "Weekdays" }
        // Monday first, as a working week is read.
        let order = [2, 3, 4, 5, 6, 7, 1].filter(weekdays.contains)
        return order.map { Self.dayNames[$0 - 1].capitalized }.joined(separator: " ")
    }

    private static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
