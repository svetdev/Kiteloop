import Foundation

/// A routine as a person fills it in: the fields of the Routines page's
/// editor, before they are a `Routine`.
///
/// A `Routine.Trigger` is how a trigger is written down — `at`, or `every`
/// with `from` and `until`, as text, or `on`, or `watch` — and is awkward to
/// edit: a form wants a time to be a time, the days to be a set and the kind
/// of trigger to be one choice. A draft holds them that way, reads itself
/// from a routine and writes itself back, and says what is still missing.
///
/// What is wrong with an event, a folder or a budget is asked of the code the
/// control API asks — `Routine.triggerProblems`, `SpendBudget.problems` — so
/// the form refuses exactly what the API refuses.
package struct RoutineDraft: Equatable, Sendable {
    /// What fires the routine.
    package enum Kind: String, CaseIterable, Sendable {
        /// A time of day, or an interval within hours.
        case clock
        /// An event of one kind published in its project.
        case event
        /// A change in a folder of its project.
        case folder
    }

    package enum Pattern: String, CaseIterable, Sendable {
        /// Once a day, at a time.
        case daily
        /// Every so many minutes, between two times.
        case interval
    }

    package var name = ""
    /// The agent the prompt goes to, by name.
    package var agent = ""
    package var prompt = ""
    /// The shell command that decides whether there is anything to do; empty
    /// for a routine that sends its prompt every time.
    package var precheck = ""
    package var kind = Kind.clock
    package var pattern = Pattern.daily
    /// The time of day a daily routine falls at, in minutes past midnight.
    package var atMinute = 9 * 60
    package var everyMinutes = 30
    /// The hours an interval routine keeps, in minutes past midnight.
    package var fromMinute = 8 * 60
    package var untilMinute = 18 * 60
    /// `Calendar` weekday numbers, 1 for Sunday.
    package var days: Set<Int> = RoutineDraft.everyDay
    /// The event kind an event routine fires on, as the feed names it.
    package var event = RoutineDraft.eventKinds.first ?? ""
    /// The folder a folder routine fires on, written relative to its project.
    package var watch = ""
    package var armed = false
    /// Which chat each run's prompt goes into.
    package var conversation = Routine.Conversation.continues
    /// Whether the routine has a budget of its own.
    package var limitsSpend = false
    /// The budget's ceiling in dollars, as typed.
    package var ceiling = ""
    package var period = SpendBudget.Period.day
    /// The parts of a budget the form has no field for, kept as they were.
    private var warnAtFraction = SpendBudget.defaultWarnAtFraction
    private var consequence = SpendBudget.Consequence.refuse

    package static let everyDay = Set(1...7)
    package static let weekdays = Set(2...6)
    /// The days in the order a working week is read, Monday first.
    package static let dayOrder = [2, 3, 4, 5, 6, 7, 1]
    private static let lastMinute = 24 * 60 - 1

    /// The event kinds a routine can fire on: every kind the app's event feed
    /// publishes, which is every kind of notice.
    package static let eventKinds = NotificationItem.NotificationType.allCases.map(\.rawValue)

    /// A new routine for `agent`: weekdays at nine, not armed.
    package init(agent: String = "") {
        self.agent = agent
        days = Self.weekdays
    }

    /// The draft that edits `routine`. A trigger that does not parse keeps the
    /// defaults for whatever it did not say, so the form opens on something a
    /// person can correct.
    package init(routine: Routine) {
        name = routine.name
        agent = routine.agent
        prompt = routine.prompt
        precheck = routine.precheck ?? ""
        armed = routine.armed
        conversation = routine.conversation ?? .continues
        read(routine.trigger)
        if let budget = routine.budget { read(budget) }
    }

    private mutating func read(_ trigger: Routine.Trigger) {
        if let folder = trigger.watch {
            kind = .folder
            watch = folder
        } else if let on = trigger.on {
            kind = .event
            event = on
        }
        if let at = trigger.at.flatMap(RoutineSchedule.minuteOfDay) { atMinute = at }
        if let every = trigger.every {
            pattern = .interval
            everyMinutes = every
            fromMinute = trigger.from.flatMap(RoutineSchedule.minuteOfDay) ?? 0
            untilMinute = trigger.until.flatMap(RoutineSchedule.minuteOfDay) ?? Self.lastMinute
        }
        if let named = trigger.days {
            days = Set(named.compactMap { RoutineSchedule.dayNames.firstIndex(of: $0.lowercased()).map { $0 + 1 } })
        }
    }

    private mutating func read(_ budget: SpendBudget) {
        limitsSpend = true
        ceiling = Self.amount(budget.ceilingUSD)
        period = budget.period
        warnAtFraction = budget.warnAtFraction
        consequence = budget.consequence
    }

    // MARK: - Writing it down

    /// The trigger as a routine keeps it: the folder, the event kind, or the
    /// schedule — and only the one the draft's kind names.
    package var trigger: Routine.Trigger {
        switch kind {
        case .folder: return Routine.Trigger(watch: watch.trimmingCharacters(in: .whitespacesAndNewlines))
        case .event: return Routine.Trigger(on: event)
        case .clock: return schedule
        }
    }

    /// The schedule as a routine keeps it. Every day is written as no days at
    /// all, and hours that span the whole day as no hours.
    private var schedule: Routine.Trigger {
        let named = days == Self.everyDay ? nil : Self.dayOrder.filter(days.contains).map { RoutineSchedule.dayNames[$0 - 1] }
        switch pattern {
        case .daily:
            return Routine.Trigger(at: Self.clock(atMinute), days: named)
        case .interval:
            return Routine.Trigger(
                every: everyMinutes,
                from: fromMinute == 0 ? nil : Self.clock(fromMinute),
                until: untilMinute == Self.lastMinute ? nil : Self.clock(untilMinute),
                days: named)
        }
    }

    /// The routine's own budget, or nil for a routine without one. A ceiling
    /// that is not a number is zero, as the API reads one, and so is refused.
    package var budget: SpendBudget? {
        guard limitsSpend else { return nil }
        let typed = ceiling.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        return SpendBudget(ceilingUSD: Double(typed) ?? 0, period: period,
                           warnAtFraction: warnAtFraction, consequence: consequence)
    }

    /// The routine this draft describes. Editing `existing` keeps its id, its
    /// project and when it was armed; a new one takes `id` and `project`.
    package func routine(id: String, project: String, existing: Routine? = nil) -> Routine {
        let check = precheck.trimmingCharacters(in: .whitespacesAndNewlines)
        return Routine(
            id: existing?.id ?? id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            project: existing?.project ?? project,
            agent: agent,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            trigger: trigger,
            precheck: check.isEmpty ? nil : check,
            armed: armed,
            armedAt: existing?.armedAt,
            // A routine saved before there was a choice keeps having none
            // until the choice is changed: nil already means `continues`.
            conversation: conversation == (existing?.conversation ?? .continues) ? existing?.conversation : conversation,
            budget: budget)
    }

    /// An id for a routine called `name` that none of `taken` has: the name in
    /// lowercase letters, digits and hyphens, numbered when that is in use.
    package static func id(forName name: String, taken: Set<String>) -> String {
        let words = name.lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }
            .split(separator: " ")
            .map { String($0) }
        let base = words.isEmpty ? "routine" : words.joined(separator: "-")
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    // MARK: - What is missing

    /// What stops this draft being saved, one sentence each, in the order the
    /// form asks; empty for one that can be.
    package var problems: [String] {
        var found: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append("Give the routine a name.") }
        if agent.isEmpty { found.append("Choose the agent the prompt goes to.") }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append("Write the prompt to send.") }
        return found + triggerProblems + budgetProblems
    }

    /// What is wrong with the trigger. A schedule is checked in the form's
    /// own words; an event and a folder by the check the control API makes.
    package var triggerProblems: [String] {
        switch kind {
        case .clock: return scheduleProblems
        case .event, .folder:
            return Routine(id: "draft", name: "", project: "", agent: "", prompt: "", trigger: trigger).triggerProblems
        }
    }

    private var scheduleProblems: [String] {
        var found: [String] = []
        if days.isEmpty { found.append("Choose at least one day.") }
        if pattern == .interval {
            if everyMinutes < 1 { found.append("The interval is at least one minute.") }
            if fromMinute > untilMinute { found.append("The hours end before they start.") }
        }
        return found
    }

    /// What is wrong with the budget, by the check the control API makes.
    package var budgetProblems: [String] {
        budget?.problems ?? []
    }

    /// The trigger in words — "Weekdays at 09:00" — or nil while it cannot
    /// be read as one.
    package var scheduleWords: String? {
        trigger.words
    }

    // MARK: - What the form offers

    /// The event kinds the form's picker offers: the feed's, and the one the
    /// routine already names when the feed has no such kind — so opening the
    /// form does not quietly change what the routine fires on.
    package static func eventChoices(current: String) -> [String] {
        eventKinds.contains(current) ? eventKinds : eventKinds + [current]
    }

    /// An event kind as the picker names it: "An approval is needed".
    package static func eventLabel(_ kind: String) -> String {
        guard let phrase = NotificationItem.NotificationType(rawValue: kind)?.routinePhrase else {
            return "\(kind) (not an event kind)"
        }
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    /// `HH:mm` for a minute of the day.
    package static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    /// A ceiling as the form shows it: dollars and cents when that is all it
    /// is, and otherwise every digit it has, so reading it back changes nothing.
    static func amount(_ dollars: Double) -> String {
        let cents = String(format: "%.2f", dollars)
        return Double(cents) == dollars ? cents : "\(dollars)"
    }
}

// MARK: - A routine in words

extension NotificationItem.NotificationType {
    /// What has happened when an event of this kind is published, as the end
    /// of "When …".
    package var routinePhrase: String {
        switch self {
        case .approval: return "an approval is needed"
        case .question: return "an agent asks a question"
        case .complete: return "an agent finishes"
        case .error: return "something fails"
        case .event: return "the project posts an update"
        }
    }
}

extension Routine.Trigger {
    /// When the routine fires, as a person reads it: "Weekdays at 07:00",
    /// "When something fails", "When the folder notes/inbox changes". Nil for
    /// a trigger that cannot be read as one.
    package var words: String? {
        if let watch {
            return WatchedFolder.isInsideAsWritten(watch) ? "When the folder \(watch) changes" : nil
        }
        if let on {
            return NotificationItem.NotificationType(rawValue: on).map { "When \($0.routinePhrase)" }
        }
        return try? RoutineSchedule.parse(self).get().words
    }
}

extension Routine {
    /// The routine's own budget in words — "up to $5.00 a day" — or nil for a
    /// routine without one.
    package var budgetWords: String? {
        budget.map { "up to $\(RoutineDraft.amount($0.ceilingUSD)) a \($0.period.rawValue)" }
    }
}
