import Foundation

/// A routine as a person fills it in: the fields of the Routines page's
/// editor, before they are a `Routine`.
///
/// A `Routine.Trigger` is how a schedule is written down — `at`, or `every`
/// with `from` and `until`, as text — and is awkward to edit: a form wants a
/// time to be a time and the days to be a set. A draft holds them that way,
/// reads itself from a routine and writes itself back, and says in a person's
/// words what is still missing.
package struct RoutineDraft: Equatable, Sendable {
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
    package var pattern = Pattern.daily
    /// The time of day a daily routine falls at, in minutes past midnight.
    package var atMinute = 9 * 60
    package var everyMinutes = 30
    /// The hours an interval routine keeps, in minutes past midnight.
    package var fromMinute = 8 * 60
    package var untilMinute = 18 * 60
    /// `Calendar` weekday numbers, 1 for Sunday.
    package var days: Set<Int> = RoutineDraft.everyDay
    package var armed = false
    /// Which chat each run's prompt goes into.
    package var conversation = Routine.Conversation.continues

    package static let everyDay = Set(1...7)
    package static let weekdays = Set(2...6)
    /// The days in the order a working week is read, Monday first.
    package static let dayOrder = [2, 3, 4, 5, 6, 7, 1]
    private static let lastMinute = 24 * 60 - 1

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
        let trigger = routine.trigger
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

    // MARK: - Writing it down

    /// The schedule as a routine keeps it. Every day is written as no days at
    /// all, and hours that span the whole day as no hours.
    package var trigger: Routine.Trigger {
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
            conversation: conversation == (existing?.conversation ?? .continues) ? existing?.conversation : conversation)
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
        if days.isEmpty { found.append("Choose at least one day.") }
        if pattern == .interval {
            if everyMinutes < 1 { found.append("The interval is at least one minute.") }
            if fromMinute > untilMinute { found.append("The hours end before they start.") }
        }
        return found
    }

    /// The schedule in words — "Weekdays at 09:00" — or nil while it cannot
    /// be read as one.
    package var scheduleWords: String? {
        try? RoutineSchedule.parse(trigger).get().words
    }

    /// `HH:mm` for a minute of the day.
    package static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
