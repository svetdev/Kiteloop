import Foundation
import KiteloopCore
import os.log

private let routineLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "routines")

/// The agent a routine's prompt goes to, as the runner needs it: where its
/// project is, whether it is mid-turn, and how to say something to it.
struct RoutineAgent {
    /// The project's folder — where the routine's check runs, and what its
    /// spend is filed under.
    let folder: URL
    let isBusy: @MainActor () -> Bool
    /// Sends the text as a person typing it would, and returns when the turn
    /// it started has ended — or at once, when the agent was mid-turn and the
    /// text only joined its queue.
    let send: @MainActor (String) async -> RoutineTurn
}

/// How a routine's turn ended.
struct RoutineTurn: Equatable {
    var reply: String
    var costUSD: Double
}

/// The loop that sends routines' prompts when they fall due.
///
/// Its bounds are the ones already there, called and not restated:
///
/// * **Off until armed.** A routine fires only while its own `armed` is true,
///   and a routine written by hand or over the API arrives unarmed.
/// * **A turn, not a run.** A routine does what typing its prompt into the
///   agent's chat does. The agent's tools, its permission mode and the cards
///   it stops on are that chat's, so a routine can do nothing the agent could
///   not already be asked to.
/// * **The daily budget.** A scheduled firing is autonomy: it is refused on a
///   day whose budget is spent, and what its turn cost is charged to that day.
///   A person pressing Run now is a person, and is not refused.
/// * **Nothing is dropped in silence.** Every firing — started, queued behind
///   a turn, skipped by its check, refused — is a line in
///   `~/.kiteloop/routine-runs.jsonl` with its reason.
///
/// It wakes for the next occurrence and for nothing else: one sleep, to the
/// earliest moment any armed routine falls. A Mac that slept through that
/// moment wakes the sleep on the way up, and what was missed is then owed as
/// `RoutineSchedule.owed` says — a daily routine late, a poll not at all.
@MainActor
@Observable
final class RoutineRunner {
    private(set) var routines: [Routine] = []
    /// The ledger as read at launch and added to since, oldest first.
    private(set) var runs: [RoutineRun] = []

    /// Finds the agent a routine names, or says what is missing. Set by the
    /// app once the open projects have somewhere to be found.
    var agent: (@MainActor (Routine) -> Result<RoutineAgent, Routine.Refusal>)?
    /// Why the day's budget refuses an autonomous turn in this project's
    /// folder; nil when it does not.
    var budgetRefusal: (@MainActor (URL) -> String?)?
    /// Files a finished turn's cost against the day.
    var charge: (@MainActor (_ costUSD: Double, _ folder: URL) -> Void)?

    private let store: RoutineStore
    private let clock: () -> Date
    private let calendar: () -> Calendar
    /// The latest occurrence each routine has had handled.
    private var handled: [String: Date] = [:]
    /// The occurrence each routine is waiting to have taken, already on record.
    private var waiting: [String: Date] = [:]
    private var wake: Task<Void, Never>?
    private var clockChanges: [NSObjectProtocol] = []
    private var isStarted = false

    init(store: RoutineStore = RoutineStore(), clock: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = { .current }) {
        self.store = store
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: - Starting

    /// Reads the routines and the ledger, takes whatever is already owed, and
    /// sets the sleep for what comes next.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        routines = store.routines()
        armHandWrittenRoutines()
        runs = store.runs(now: clock())
        // A `waiting` line is an occurrence nobody took: still owed.
        for run in runs where run.outcome != .waiting {
            guard let occurrence = run.scheduledFor else { continue }
            handled[run.routine] = max(handled[run.routine] ?? .distantPast, occurrence)
        }
        // A clock set by hand or a new time zone moves every occurrence.
        clockChanges = [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.look() }
            }
        }
        look()
    }

    /// A routine armed by editing the file carries no arming time, and one
    /// with none would owe nothing for ever. It is armed as of this launch.
    private func armHandWrittenRoutines() {
        guard routines.contains(where: { $0.armed && $0.armedAt == nil }) else { return }
        let now = clock()
        routines = routines.map { routine in
            guard routine.armed, routine.armedAt == nil else { return routine }
            var armed = routine
            armed.armedAt = now
            return armed
        }
        try? store.save(routines)
    }

    // MARK: - Looking

    /// One look: fire what is owed, then sleep until the next occurrence.
    /// Returns the firings it began, so a caller that needs them done can
    /// await them.
    ///
    /// An occurrence whose agent cannot be reached — its project is not open
    /// yet, the fleet is held — stays owed: it is written down once as
    /// `waiting` and taken by the first look that finds the agent, which is
    /// why the app looks again whenever a project opens.
    @discardableResult
    func look() -> [Task<Void, Never>] {
        let now = clock()
        var fired: [Task<Void, Never>] = []
        for routine in routines {
            guard let occurrence = routine.owed(at: now, lastHandled: handled[routine.id], calendar: calendar()) else {
                continue
            }
            switch resolve(routine) {
            case .failure(let refusal):
                noteWaiting(routine, occurrence: occurrence, reason: refusal.reason, now: now)
            case .success(let target):
                // Marked before anything is awaited: the next look must not
                // see this occurrence as still owed.
                handled[routine.id] = occurrence
                waiting[routine.id] = nil
                fired.append(Task { await self.fire(routine, scheduledFor: occurrence, target: target) })
            }
        }
        syncWake(now: now)
        return fired
    }

    private func resolve(_ routine: Routine) -> Result<RoutineAgent, Routine.Refusal> {
        agent?(routine) ?? .failure(Routine.Refusal(problems: ["Kiteloop has no projects open yet"]))
    }

    /// One `waiting` line per occurrence, however many looks find it stuck.
    private func noteWaiting(_ routine: Routine, occurrence: Date, reason: String, now: Date) {
        guard waiting[routine.id] != occurrence else { return }
        waiting[routine.id] = occurrence
        record(RoutineRun(routine: routine.id, scheduledFor: occurrence, at: now, outcome: .waiting, reason: reason))
    }

    /// The earliest moment an armed routine next falls; nil with none armed.
    var nextWake: Date? {
        let now = clock()
        return routines.filter(\.armed).compactMap { next(for: $0, after: now) }.min()
    }

    /// When `routine` next falls after `moment`, armed or not.
    func next(for routine: Routine, after moment: Date? = nil) -> Date? {
        routine.schedule?.nextOccurrence(after: moment ?? clock(), calendar: calendar())
    }

    private func syncWake(now: Date) {
        wake?.cancel()
        wake = nil
        guard isStarted, let next = nextWake else { return }
        let delay = max(0, next.timeIntervalSince(now))
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.look()
        }
    }

    // MARK: - Firing

    /// Runs `id` now because a person asked: no arming, no budget, and a check
    /// that finds nothing does not stop it. Nil for an id nobody has.
    func runNow(_ id: String) -> Task<Void, Never>? {
        guard let routine = routines.first(where: { $0.id == id }) else { return nil }
        return Task {
            switch self.resolve(routine) {
            case .failure(let refusal):
                self.record(RoutineRun(routine: id, scheduledFor: nil, at: self.clock(), outcome: .refused),
                            refused: refusal.reason)
            case .success(let target):
                await self.fire(routine, scheduledFor: nil, target: target)
            }
        }
    }

    private func fire(_ routine: Routine, scheduledFor: Date?, target: RoutineAgent) async {
        let byHand = scheduledFor == nil
        var run = RoutineRun(routine: routine.id, scheduledFor: scheduledFor, at: clock(), outcome: .refused)
        if !byHand, let refusal = budgetRefusal?(target.folder) { return record(run, refused: refusal) }

        let check = await check(routine, in: target.folder)
        if !byHand, let nothing = check.nothingToDo {
            run.outcome = .skipped
            run.reason = nothing
            return record(run)
        }
        let text = Self.text(prompt: routine.prompt, command: routine.precheck, output: check.output)
        guard !target.isBusy() else {
            run.outcome = .queued
            record(run)
            _ = await target.send(text)
            return
        }
        run.outcome = .started
        record(run)
        await finish(run, with: await target.send(text), in: target.folder)
    }

    private func finish(_ started: RoutineRun, with turn: RoutineTurn, in folder: URL) {
        var run = started
        run.finishedAt = clock()
        run.reply = turn.reply.split(separator: "\n").first.map(String.init)
        if turn.costUSD > 0 {
            run.costUSD = turn.costUSD
            charge?(turn.costUSD, folder)
        }
        record(run)
    }

    private func record(_ run: RoutineRun, refused reason: String) {
        var refused = run
        refused.outcome = .refused
        refused.reason = reason
        record(refused)
    }

    private func record(_ run: RoutineRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index] = run } else { runs.append(run) }
        store.append(run)
        routineLog.info("routine \(run.routine, privacy: .public) \(run.outcome.rawValue, privacy: .public)")
    }

    // MARK: - The check

    /// What a routine's check said.
    struct Check: Equatable {
        var output = ""
        /// Why the turn is not worth starting; nil when it is.
        var nothingToDo: String?
    }

    /// Runs the routine's check in the project's folder, off the main actor.
    /// It has until the routine next falls: a check still running then is hung.
    private func check(_ routine: Routine, in folder: URL) async -> Check {
        guard let command = routine.precheck else { return Check() }
        let now = clock()
        let deadline = next(for: routine, after: now)?.timeIntervalSince(now) ?? Self.day
        let result = await Task.detached {
            SubprocessOutput.runWithDeadline(executable: "/bin/zsh", arguments: ["-lc", command], directory: folder,
                                             timeout: deadline, discardStandardError: true)
        }.value
        return Self.check(status: result.status, output: result.output, timedOut: result.timedOut)
    }

    /// A week has every pattern's next occurrence in it, so this only bounds a
    /// routine whose trigger no longer parses.
    private static let day: TimeInterval = 24 * 60 * 60

    static func check(status: Int32, output: String, timedOut: Bool) -> Check {
        let said = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut { return Check(output: said, nothingToDo: "its check was still running when the routine next fell") }
        if status != 0 { return Check(output: said, nothingToDo: "its check failed (status \(status))") }
        return Check(output: said, nothingToDo: said.isEmpty ? "its check found nothing" : nil)
    }

    /// What the agent is sent: the prompt, and under it what the check printed.
    static func text(prompt: String, command: String?, output: String) -> String {
        guard let command, !output.isEmpty else { return prompt }
        return "\(prompt)\n\nOutput of this routine's check (`\(command)`):\n\n```\n\(output)\n```"
    }

    // MARK: - Changing routines

    /// Adds `routine`, or replaces the one with its id. Arming it, or changing
    /// when an armed one falls, starts what it owes from now.
    func put(_ routine: Routine) throws {
        var taken = routine
        let existing = routines.first { $0.id == routine.id }
        let rearmed = taken.armed && (existing?.armed != true || existing?.trigger != taken.trigger)
        if rearmed || (taken.armed && taken.armedAt == nil) { taken.armedAt = clock() }
        var next = routines
        if let index = next.firstIndex(where: { $0.id == taken.id }) { next[index] = taken } else { next.append(taken) }
        try save(next)
    }

    /// Removes the routine with `id`; false when there is none.
    func remove(_ id: String) throws -> Bool {
        guard routines.contains(where: { $0.id == id }) else { return false }
        try save(routines.filter { $0.id != id })
        handled[id] = nil
        waiting[id] = nil
        return true
    }

    func setArmed(_ id: String, _ armed: Bool) throws {
        guard var routine = routines.first(where: { $0.id == id }), routine.armed != armed else { return }
        routine.armed = armed
        try put(routine)
    }

    private func save(_ next: [Routine]) throws {
        try store.save(next)
        routines = next
        if isStarted { look() }
    }

    // MARK: - Reading

    /// The newest run of `id`, if it has run.
    func lastRun(of id: String) -> RoutineRun? {
        runs.last { $0.routine == id }
    }
}
