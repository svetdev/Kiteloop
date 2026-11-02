import CryptoKit
import Foundation
import KiteloopCore

/// The autonomous **start** decision: may the Coordinator start a run right now,
/// and if so, in which project and on which item?
///
/// This is the step where the Coordinator stops being a groomer and becomes an
/// operator. Filling a queue costs a model call; starting a run spends money
/// unattended for as long as the run takes, so every bound below is enforced
/// here — before a project is chosen — rather than trusted to a prompt.
///
/// **Nothing here is a new bound.** Each one already exists somewhere and is
/// *called* rather than restated:
///
/// * **Paused** is `PortfolioSnapshot.selectableProjects`, which drops paused
///   projects before a choice exists.
/// * **The daily budgets** are `DailyBudget.decision(for:)`, which refuses an
///   `.autonomous` start on an exhausted day and allows a `.human` one — the
///   ceiling governs autonomy, not the person. Both ceilings are asked: the
///   portfolio's before a project is chosen, and each project's own while
///   choosing, so a project that has spent its allowance is passed over for one
///   that hasn't rather than picked and refused. `BacklogAutopilot.start` asks
///   the same pair again; asking here as well means a refused day costs no work
///   at all.
/// * **One run at a time per project** is `Project.isRunning`, the same run
///   state the portfolio reports everywhere else.
/// * **Which project matters** is `QueueRefill.prefers` — the identical order
///   the refill loop grooms in, shared so the two can't drift apart.
/// * **What is runnable** stays the pickup gates' business: this picks the next
///   `ready` item and `BacklogAutopilot.start` still puts it through
///   `DefinitionOfReady` and `GroundingCheck`.
///
/// Everything is a value — no registry, no autopilot, no clock of its own — so
/// the whole policy is exercised without an app running.
enum RunScheduling {

    // MARK: - What a start would be

    /// The project and item an autonomous start would pick, and why.
    struct Target: Sendable, Equatable {
        let project: String
        let path: String
        let itemID: String
        let itemTitle: String
        /// `ready` items in that project right now.
        let readyCount: Int
        /// Why this project won — its stated priority and how long it had been
        /// idle. Recorded with the start, so a night of them reads back as
        /// decisions rather than as a list of ids.
        let reason: String

        var summary: String { "\(project)/\(itemID) — \(reason)" }
    }

    /// Why no run is being started. Each case is a different answer to "why was
    /// the machine quiet last night", and collapsing any two of them would make
    /// a silent loop impossible to debug.
    enum Hold: Sendable, Equatable {
        /// The kill switch is off. The shipped default.
        case disabled
        /// Nothing is wired to the scheduler, so it can see no portfolio. Not
        /// the same as "off" — an unwired loop would hold even switched on.
        case unwired
        /// Every idle project that could have been started is holding on its own
        /// failures — see `ProjectHold`. Carries each hold's reason, so the
        /// refusal says which project, on what evidence, and what would end it.
        case projectHeld(String)
        /// A daily ceiling is spent — the portfolio's, or every idle project's
        /// own. Carries `DailyBudget`'s own wording, numbers and which ceiling
        /// included.
        case budgetExhausted(String)
        /// Nothing open that may be started for — every project paused, or
        /// without a worker and reviewer, or none open at all.
        case noEligibleProject
        /// Projects could run, but none has consented to unattended work —
        /// distinct from `noEligibleProject` so the standing line says which
        /// switch is missing, not that the fleet is empty.
        case noProjectOptedIn
        /// Every eligible project already has a run in flight.
        case allBusy
        /// Eligible and idle, but nothing `ready` to pick up.
        case nothingRunnable
        /// Every ready item this looked at is a gate refusal that still
        /// stands — see `GateRefusals`. Distinct from `nothingRunnable`: there
        /// *is* work in the queue, and re-selecting it every tick to have the
        /// same gate refuse it again is the loop this exists to stop. Carries
        /// the count, so the standing line says how many are waiting on an
        /// edit rather than reading as a quiet night.
        case itemsRefused(String)
        /// The fleet is being drained for a restart. Distinct from `disabled`:
        /// nobody turned scheduling off, and it resumes on its own the moment the
        /// hold is lifted — reading this as "off" is how an operator spends a
        /// morning wondering who touched the kill switch.
        case quiesced
        /// One or more idle, affordable projects have more `awaitingApproval`
        /// work than the Planner keeps `ready` for them, and their own autopilot
        /// won't clear the gate itself (`approveReviewPassedRuns` off). Starting
        /// another run there only stacks more branches behind a person who is
        /// already behind — on 2026-08-28 one project ran 49 items unattended
        /// and stacked 37 at the gate while a human could clear perhaps ten an
        /// hour. Carries each held project's own sentence, both numbers
        /// included, joined the way `projectHeld` joins several — see
        /// `gateFullDetail`.
        case gateFull(String)

        var reason: String {
            switch self {
            case .disabled:
                return "autonomous scheduling is off"
            case .unwired:
                return "the scheduler isn't wired to a portfolio"
            case .projectHeld(let detail):
                return detail
            case .budgetExhausted(let detail):
                return detail
            case .noEligibleProject:
                return "no eligible project — all paused, unready, or none open"
            case .noProjectOptedIn:
                return "no project has autonomous work switched on — opt one in "
                    + "from its Autopilot settings"
            case .allBusy:
                return "every eligible project already has a run in flight"
            case .nothingRunnable:
                return "nothing ready to run"
            case .itemsRefused(let detail):
                return detail
            case .quiesced:
                return "the fleet is quiesced for a restart"
            case .gateFull(let detail):
                return detail
            }
        }

        /// The case as a stable tag, for a reader deciding rather than reading.
        var kind: String {
            switch self {
            case .disabled: return "disabled"
            case .unwired: return "unwired"
            case .projectHeld: return "projectHeld"
            case .budgetExhausted: return "budgetExhausted"
            case .noEligibleProject: return "noEligibleProject"
            case .noProjectOptedIn: return "noProjectOptedIn"
            case .allBusy: return "allBusy"
            case .nothingRunnable: return "nothingRunnable"
            case .itemsRefused: return "itemsRefused"
            case .quiesced: return "quiesced"
            case .gateFull: return "gateFull"
            }
        }
    }

    /// Whether one project's own approval gate holds more than the Planner
    /// keeps `ready` for it, and if so, the sentence a human reads to act on
    /// it — the gate's own numbers, both of them, so the reason names what to
    /// fix rather than only that something is stuck.
    ///
    /// Nil while the gate isn't full, or while the project's own autopilot
    /// approves review-passed runs itself (`approveReviewPassedRuns`) — a
    /// project on that rung clears its own gate and is never held this way.
    /// The ready floor is `QueueRefill.Policy.targetDepth`, sanitized and
    /// called rather than restated: the number is the same one the Planner
    /// already keeps ready, not a new bound invented here.
    static func gateFullDetail(project: String, awaitingApproval: Int,
                               approveReviewPassedRuns: Bool,
                               policy: QueueRefill.Policy = .default) -> String? {
        guard !approveReviewPassedRuns else { return nil }
        let floor = policy.sanitized.targetDepth
        guard awaitingApproval > floor else { return nil }
        return "\(project): gate holds \(awaitingApproval), more than \(floor) kept ready"
            + " — approve or send back to resume"
    }

    /// Start it, or hold. There is no third verb: the trust boundary lives in
    /// the gates and the ceilings, which run either way, so a decision is
    /// either a start that cleared them all or a hold that names what stopped
    /// it.
    enum Decision: Sendable, Equatable {
        case start(Target)
        case hold(Hold)

        var target: Target? { if case .start(let t) = self { return t } else { return nil } }
        var hold: Hold? { if case .hold(let h) = self { return h } else { return nil } }

        var kind: String {
            switch self {
            case .start: return "start"
            case .hold(let hold): return hold.kind
            }
        }

        var summary: String {
            switch self {
            case .start(let target): return "starting \(target.summary)"
            case .hold(let hold): return "held — \(hold.reason)"
            }
        }
    }

    // MARK: - Holds, and the evidence they stand on

    /// What one project's queue looked like when a run failed.
    ///
    /// A hold has to be able to answer "is what I saw still true?", and a list
    /// of ids cannot: an item re-groomed keeps its id, and an item whose
    /// dependency reaches `done` changes nothing about itself except that it may
    /// now run. So each `ready` item is recorded as **what it asks for** and
    /// **whether a run could be started on it** — and the first of those is
    /// `RetryCeiling.specFingerprint`, called rather than restated, so "the item
    /// was rewritten" means one thing to a hold and to the retry ceiling both.
    ///
    /// What this deliberately does *not* record is anything a failed run writes
    /// down about itself. The attempt count lives in the metric ledger, the
    /// review's feedback and the retirement note live in the item's `## Notes`,
    /// and the item bouncing back to `ready` is the status it already had — none
    /// of which is in here. A hold that expired on its own bookkeeping would
    /// expire on the tick after it formed and hold nothing at all.
    struct QueueEvidence: Sendable, Equatable {

        /// One `ready` item, as the evidence sees it.
        struct Row: Sendable, Equatable {
            /// `RetryCeiling.specFingerprint` of the item's What / How /
            /// Validation. Nil where there is no detail file to fingerprint,
            /// which is itself a state: an item that acquires one was groomed.
            let spec: String?
            /// Whether autopilot would actually pick it up — `DefinitionOfReady`
            /// met, and not retired by the retry ceiling. False covers both
            /// halves of "not yet", so a dependency reaching `done` and a human
            /// releasing a retired item are each a change this notices.
            let runnable: Bool
        }

        var rows: [String: Row]

        init(rows: [String: Row] = [:]) { self.rows = rows }

        var isEmpty: Bool { rows.isEmpty }
    }

    /// Read one project's backlog into the evidence a hold is judged against.
    ///
    /// Pure — items and their details in, a value out. `isRetired` is passed in
    /// rather than computed here because the retry ceiling's verdict needs the
    /// run ledger and the grooming ledger; the scheduler asks the project's own
    /// autopilot, which judges it from exactly what pickup judges it from.
    static func evidence(items: [BacklogItem],
                         detail: (BacklogItem) -> BacklogItemDetail?,
                         isRetired: (BacklogItem, BacklogItemDetail?) -> Bool = { _, _ in false })
        -> QueueEvidence {
        // Resolved across every epic, the way `DefinitionOfReady` is asked
        // everywhere else — sequencing routinely crosses them.
        let dependencies = DefinitionOfReady.Dependencies(items: items)
        var rows: [String: QueueEvidence.Row] = [:]
        for item in items where item.status == .ready {
            let detail = detail(item)
            let runnable = !isRetired(item, detail)
                && DefinitionOfReady.evaluate(item: item, detail: detail,
                                              dependencies: dependencies).isReady
            rows[item.id] = QueueEvidence.Row(
                spec: RetryCeiling.specFingerprint(item: item, detail: detail),
                runnable: runnable)
        }
        return QueueEvidence(rows: rows)
    }

    /// A short, stable digest of a `Codable` configuration — what "the settings
    /// changed" is allowed to mean to a hold.
    ///
    /// Sorted keys, so two encodings of one value compare equal. SHA-256 rather
    /// than `Hasher` for the reason `RetryCeiling.specFingerprint` gives: a
    /// per-process seed would make every launch read as a settings change. (A
    /// relaunch *does* clear holds, but because they live in memory and nowhere
    /// else, not because a hash moved.)
    static func fingerprint<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "-" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Why **one project's** autonomous starts are being withheld, and what
    /// would make that stop being true.
    ///
    /// This is what replaced a fleet-global latch. On the night of 2026-08-12
    /// three retries of one item in one project tripped that latch at 20:07 and
    /// every project's starts held until the app happened to be relaunched at
    /// 02:29, budgets barely touched. Two category errors, and this type is
    /// shaped around not repeating either: evidence about one queue is only ever
    /// applied to that queue, and the claim it makes — "starting more runs here
    /// buys nothing" — stops being asserted the moment the queue it describes is
    /// no longer the queue.
    ///
    /// There is no threshold, no cooldown and no backoff here, and no timer
    /// anywhere: a hold ends when its evidence goes stale, which is an event the
    /// backlog watcher and the refill loop already produce.
    struct ProjectHold: Sendable, Equatable {

        /// One failed run. The item and the failure are kept apart because they
        /// have to be compared apart: "the same thing keeps going wrong" is a
        /// comparison of the failures with the item names taken out of them.
        struct Failure: Sendable, Equatable {
            let itemID: String
            /// The outcome in its own words — `blocked: verify failed`.
            let text: String
            /// The queue as this run found it.
            let evidence: QueueEvidence
            /// Everything it depended on that was not the queue — the worker and
            /// reviewer, the caps, the backend. See
            /// `CoordinatorRunScheduler.environment(of:global:)`.
            let environment: String
        }

        /// The project's display name, for the reason a human reads.
        let project: String
        /// Its root path — how a hold is matched to a start decision.
        let path: String
        private(set) var failures: [Failure]

        init(project: String, path: String, failures: [Failure] = []) {
            self.project = project
            self.path = path
            self.failures = failures
        }

        /// The failure texts that **two different items** have both produced.
        ///
        /// One item failing is that item's problem. The same spawn error or the
        /// same gate refusal on two of them is by definition not about either,
        /// which is what makes it evidence of a different kind.
        static func sameCause(among failures: [Failure]) -> Set<String> {
            var itemsByText: [String: Set<String>] = [:]
            for failure in failures { itemsByText[failure.text, default: []].insert(failure.itemID) }
            return Set(itemsByText.filter { $0.value.count > 1 }.keys)
        }

        var isSystemic: Bool { !Self.sameCause(among: failures).isEmpty }

        /// Distinct items among the failures — what the systemic reason counts.
        var itemCount: Int { Set(failures.map(\.itemID)).count }

        /// Whether this is yet enough to withhold a start.
        ///
        /// The repetition bound is `RetryCeiling.limit`, called rather than
        /// restated, and that is not a coincidence to be tidied away: the run
        /// that forms an ordinary hold is the run that retires the item, which
        /// takes the item out of the runnable set, which makes the evidence
        /// below stale on the very next look. The two bounds are the same bound.
        ///
        /// Same-cause evidence needs no repetition at all — two different items
        /// failing identically *is* the evidence.
        var isActive: Bool { isSystemic || failures.count >= RetryCeiling.limit }

        /// What is left of this hold once the queue and the environment have
        /// been read again. A hold whose failures all fall away is over.
        ///
        /// Each failure is tested against the state *it* observed, not against a
        /// single snapshot taken at the end, so a queue that moved between two
        /// failures retires the first one without taking the second with it.
        func standing(against evidence: QueueEvidence, environment: String) -> ProjectHold {
            let current = failures.filter { $0.environment == environment }
            // Same-cause failures make no claim about the queue, so a queue that
            // has moved on says nothing about them either way. Only the things
            // outside those runs clear them — which is what `environment` is.
            let systemic = Self.sameCause(among: current)
            return ProjectHold(
                project: project, path: path,
                failures: current.filter { systemic.contains($0.text) || $0.evidence == evidence })
        }

        mutating func record(_ failure: Failure) { failures.append(failure) }

        /// Why, in the words the `run-scheduler` log, the sidebar and `/health`
        /// all carry. It names the evidence *and* what would end it: "runs
        /// halted" on its own is the line somebody read at 3am and could do
        /// nothing with.
        var reason: String {
            let runs = "\(failures.count) autonomous run\(failures.count == 1 ? "" : "s")"
            let last = failures.last.map { "\($0.itemID) \($0.text)" } ?? "nothing recorded"
            guard isSystemic else {
                return "\(runs) in \(project) failed (last: \(last))"
                    + " — held until its queue changes"
            }
            return "\(runs) in \(project) across \(itemCount) items failed the same way"
                + " (last: \(last)) — held until its autopilot or the app changes"
        }
    }

    /// Every project's hold, keyed by project path. Nothing aggregates across
    /// them: a failure in one project is evidence about that project's queue and
    /// is never applied to another's.
    struct Holds: Sendable, Equatable {
        private(set) var byPath: [String: ProjectHold] = [:]

        init() {}

        /// The paths anything has been recorded against — including holds not
        /// yet withholding anything, which still have to be re-read so a single
        /// failure doesn't outlive the queue it was about.
        var paths: [String] { Array(byPath.keys) }

        /// The holds actually withholding a start, by project name so two
        /// readings of one state read the same way.
        var active: [ProjectHold] {
            byPath.values.filter(\.isActive).sorted { $0.project < $1.project }
        }

        var isEmpty: Bool { byPath.isEmpty }

        /// The hold withholding starts in this project, or nil.
        func hold(atPath path: String) -> ProjectHold? {
            byPath[path].flatMap { $0.isActive ? $0 : nil }
        }

        /// Everything recorded against this project, whether or not it withholds
        /// anything yet.
        func recorded(atPath path: String) -> ProjectHold? { byPath[path] }

        mutating func record(_ failure: ProjectHold.Failure, project: String, path: String) {
            var hold = byPath[path] ?? ProjectHold(project: project, path: path)
            hold.record(failure)
            byPath[path] = hold
        }

        /// A run that got somewhere is the end of the matter for that project.
        mutating func clear(path: String) { byPath[path] = nil }

        /// Re-read one project and drop whatever it no longer supports.
        mutating func expire(path: String, against evidence: QueueEvidence, environment: String) {
            guard let hold = byPath[path] else { return }
            let standing = hold.standing(against: evidence, environment: environment)
            byPath[path] = standing.failures.isEmpty ? nil : standing
        }

        /// Forget every project not in this set. A project that has been closed
        /// is not being started from either way, and a hold nobody can act on is
        /// noise in `/health`.
        mutating func retain(paths: Set<String>) {
            byPath = byPath.filter { paths.contains($0.key) }
        }

        /// Every hold, gone — the human override.
        mutating func clear() { byPath.removeAll() }
    }

    /// A pickup gate's refusal of one item **as it was written when the gate
    /// looked**, remembered so a scheduler tick can skip it without asking the
    /// gate again.
    ///
    /// This is what a free refusal was missing: nothing recorded that
    /// `DefinitionOfReady` or `GroundingCheck` had already answered "no" for
    /// this item, so the same ungroomed item was reselected and re-refused
    /// every five minutes — 44 times over one 2026-08-16 night for a single
    /// stale citation. A refusal is a verdict about the item **as written**,
    /// so what retires it is not a cooldown but the same event that retires a
    /// `RetryCeiling` release: the wording it was judged against no longer
    /// reads the way it did. `itemFingerprint` covers both halves of "the
    /// item" — the backlog line and its detail file — because a `verify:`
    /// fixed on the line is as much a rewrite as a reworded Validation
    /// section, and an inline-groomed item (no detail file at all) still has
    /// to be able to clear its own refusal by being edited.
    ///
    /// Keyed by project path and item id, exactly the way `Holds` is: a
    /// refusal is evidence about one item in one project, never carried to
    /// another.
    struct GateRefusals: Sendable, Equatable {
        struct Refusal: Sendable, Equatable {
            /// `itemFingerprint` of the item as it read when the gate refused it.
            let fingerprint: String
            /// The gate's own words.
            let reason: String
        }

        private(set) var byPath: [String: [String: Refusal]] = [:]

        init() {}

        /// Every item refused anywhere, for the standing line's count.
        var count: Int { byPath.values.reduce(0) { $0 + $1.count } }

        mutating func record(itemID: String, path: String, fingerprint: String, reason: String) {
            byPath[path, default: [:]][itemID] = Refusal(fingerprint: fingerprint, reason: reason)
        }

        /// Whether this item's refusal still stands — recorded, and its
        /// fingerprint unchanged since. The only question a caller needs
        /// answered before skipping the item without asking the gate again.
        func stands(itemID: String, path: String, fingerprint: String) -> Bool {
            byPath[path]?[itemID]?.fingerprint == fingerprint
        }

        func reason(itemID: String, path: String) -> String? { byPath[path]?[itemID]?.reason }

        /// Forget every project not in this set. A project that has been
        /// closed is not being started from either way.
        mutating func retain(paths: Set<String>) {
            byPath = byPath.filter { paths.contains($0.key) }
        }

        /// Every refusal, gone — the human override.
        mutating func clear() { byPath.removeAll() }
    }

    /// The key a refused item is looked up by — one project's item, never
    /// confused with another project's item of the same id.
    static func refusalKey(path: String, itemID: String) -> String { "\(path)\u{0}\(itemID)" }

    /// A fingerprint of the item **as written** — the backlog line and its
    /// detail file together — so a `verify:` fixed on the line counts as a
    /// rewrite exactly as much as a reworded Validation section does, and an
    /// inline-groomed item (no detail file) still has a fingerprint that
    /// moves when its line is edited.
    static func itemFingerprint(item: BacklogItem, detail: BacklogItemDetail?) -> String {
        struct ItemText: Encodable {
            let line: String
            let detail: BacklogItemDetail?
        }
        return fingerprint(ItemText(line: BacklogSerializer.serializeItem(item), detail: detail))
    }

    // MARK: - Decide

    /// May a run start, and where?
    ///
    /// The order of the gates is the point:
    ///   1. **the kill switch** — off is off, before anything is even read;
    ///   2. **the portfolio's daily budget** — `DailyBudget`'s own refusal, so an
    ///      exhausted day is refused identically here and in
    ///      `BacklogAutopilot.start`;
    ///   3. **paused / not autopilot-ready** — read through `selectableProjects`,
    ///      so a paused project is never a choice that gets declined;
    ///   4. **already running** — one run at a time per project;
    ///   5. **that project's own hold** — its failed runs, scoped to the queue
    ///      they were about (`ProjectHold`);
    ///   6. **the project's own daily budget** — a project that has spent its
    ///      allowance is passed over, not picked and then refused downstream;
    ///   7. **the project's own approval gate** — held when it holds more than
    ///      the Planner keeps `ready` for it and its autopilot won't clear it
    ///      itself (`gateFullDetail`);
    ///   8. **has ready work**, then **priority, then idle longest**.
    ///
    /// Holds and the project ceiling are both asked *after* "already running" on
    /// purpose. A project that is busy was not going to start anything anyway,
    /// and a refusal naming a budget nobody was about to spend — or a hold on a
    /// project that is mid-run — sends the operator to fix the wrong thing.
    ///
    /// Note where the hold is **not**: it is not a gate over the portfolio. It
    /// is a filter over the candidates, so one project's failures cost that
    /// project's starts and nobody else's.
    ///
    /// - Parameters:
    ///   - holds: what each project's own failed runs are still evidence for,
    ///     already re-read against the queue as it stands — see
    ///     `CoordinatorRunScheduler.refreshHolds`.
    ///   - idleSince: when each project was last seen with nothing running, kept
    ///     by `QueueRefill.trackIdle` — the same clock the refill loop breaks a
    ///     priority tie with.
    ///   - projectBudgets: each project's **own** daily ceiling and its own share
    ///     of today's spend, keyed by project path. A project absent from the map
    ///     has no ceiling of its own and is governed by `budget` alone.
    ///   - queueRefillPolicy: the same policy `QueueRefill` fills queues by —
    ///     `targetDepth` is the ready floor a full approval gate is measured
    ///     against, called rather than restated.
    ///   - refusedItems: `refusalKey(path:itemID:)` of every ready item whose
    ///     gate refusal still stands — computed by the caller, which has the
    ///     backlog and detail files this needs and this does not. Skipped
    ///     without being picked, so the same ungroomed item is not reselected
    ///     only to be refused downstream again; a ready item not in this set
    ///     is picked exactly as before.
    static func decide(portfolio: PortfolioSnapshot,
                       enabled: Bool,
                       budget: DailyBudget,
                       holds: Holds = Holds(),
                       refusedItems: Set<String> = [],
                       idleSince: [String: Date] = [:],
                       projectBudgets: [String: DailyBudget] = [:],
                       queueRefillPolicy: QueueRefill.Policy = .default, startingPaths: Set<String> = [],
                       now: Date = Date()) -> Decision {
        guard enabled else { return .hold(.disabled) }
        if case .refuse(let refusal) = budget.decision(for: .autonomous) {
            return .hold(.budgetExhausted(refusal.eventReason))
        }

        let capable = portfolio.selectableProjects.filter(\.autopilotReady)
        guard !capable.isEmpty else { return .hold(.noEligibleProject) }

        // Consent, after capability: a worker and reviewer make a project able
        // to run, and only its own opt-in makes it run unattended.
        let eligible = capable.filter(\.autonomousWorkEnabled)
        guard !eligible.isEmpty else { return .hold(.noProjectOptedIn) }

        let idle = idleProjects(eligible, startingPaths: startingPaths)
        guard !idle.isEmpty else { return .hold(.allBusy) }

        // Each project's own hold, asked one project at a time for exactly the
        // reason the ceilings below are: a project holding on its own failures
        // must not cost a quiet one its night.
        var heldReasons: [String] = []
        let unheld = idle.filter { project in
            guard let hold = holds.hold(atPath: project.path) else { return true }
            heldReasons.append(hold.reason)
            return false
        }
        guard !unheld.isEmpty else { return .hold(.projectHeld(heldReasons.joined(separator: "; "))) }

        // Each project's own ceiling, asked one project at a time. Skipping the
        // exhausted ones rather than refusing the whole tick is the point: with
        // one busy project over its allowance and a quiet one under it, the
        // quiet one still gets its night.
        var projectRefusals: [String] = []
        let affordable = unheld.filter { project in
            guard case .refuse(let refusal) =
                    (projectBudgets[project.path] ?? DailyBudget()).decision(for: .autonomous)
            else { return true }
            projectRefusals.append(refusal.eventReason)
            return false
        }
        guard !affordable.isEmpty else {
            return .hold(.budgetExhausted(projectRefusals.joined(separator: "; ")))
        }

        // Each project's own approval gate, asked one project at a time for the
        // same reason the budget above is: a project stuck behind a person who
        // cannot keep up must not cost a quiet one its start. The ready floor
        // already bounds how much the Planner keeps ready, so it bounds how
        // much may pile up unlooked-at too — a project whose own autopilot
        // clears its gate (`approveReviewPassedRuns` on) is never held here.
        var gateReasons: [String] = []
        let gateOpen = affordable.filter { project in
            guard let detail = Self.gateFullDetail(
                project: project.name, awaitingApproval: project.count(.awaitingApproval),
                approveReviewPassedRuns: project.approveReviewPassedRuns,
                policy: queueRefillPolicy) else { return true }
            gateReasons.append(detail)
            return false
        }
        guard !gateOpen.isEmpty else {
            return .hold(.gateFull(gateReasons.joined(separator: "; ")))
        }

        // A start needs an item to name, not just a count: the snapshot's ready
        // sample is what the autopilot would be handed, so a project whose
        // sample is empty has nothing this can start even if it counts some.
        var pool = gateOpen.filter { !$0.readyItems.items.isEmpty }
        guard !pool.isEmpty else { return .hold(.nothingRunnable) }

        // Walk projects in preference order, and within each take the first
        // ready item that isn't a standing refusal — so a refused item A never
        // shadows a runnable item B, whether B is later in the same project's
        // queue or the next project over. A project whose whole sample is
        // refused is dropped from the pool and the next preferred one is asked
        // instead, exactly as if that project had had no ready items at all.
        var refusedCount = 0
        while let chosen = pool.min(by: { prefers($0, over: $1, idleSince: idleSince, now: now) }) {
            let runnable = chosen.readyItems.items.filter {
                !refusedItems.contains(Self.refusalKey(path: chosen.path, itemID: $0.id))
            }
            refusedCount += chosen.readyItems.items.count - runnable.count
            if let item = runnable.first {
                let target = Target(project: chosen.name, path: chosen.path,
                                    itemID: item.id, itemTitle: item.title,
                                    readyCount: chosen.count(.ready),
                                    reason: choiceReason(chosen, idleSince: idleSince, now: now))
                return .start(target)
            }
            pool.removeAll { $0.path == chosen.path }
        }

        guard refusedCount > 0 else { return .hold(.nothingRunnable) }
        return .hold(.itemsRefused(
            "\(refusedCount) item\(refusedCount == 1 ? "" : "s") refused as written — edit or release to retry"))
    }

    /// The refill loop's own ordering, called rather than restated — "which
    /// project matters" has to mean one thing.
    /// The projects free to take a run: not running, and not one whose start
    /// this scheduler is still awaiting — that counts as running even before
    /// its snapshot says so, since the snapshot was taken a few statements ago
    /// and a second look must not hand the same project a second run.
    private static func idleProjects(_ eligible: [PortfolioSnapshot.Project],
                                     startingPaths: Set<String>) -> [PortfolioSnapshot.Project] {
        eligible.filter { !$0.isRunning && !startingPaths.contains($0.path) }
    }

    private static func prefers(_ a: PortfolioSnapshot.Project, over b: PortfolioSnapshot.Project,
                                idleSince: [String: Date], now: Date) -> Bool {
        QueueRefill.prefers(a, over: b, idleSince: idleSince, now: now)
    }

    /// Why this project was chosen, in the words the record keeps.
    static func choiceReason(_ project: PortfolioSnapshot.Project,
                             idleSince: [String: Date], now: Date) -> String {
        let idle = QueueRefill.idleDuration(project, idleSince: idleSince, now: now)
        return "\(idlePhrase(idle)), \(project.count(.ready)) ready"
    }

    /// How long a project has been waiting, rounded to what a reader cares
    /// about. Under a minute reads as "just idle" rather than "0m".
    static func idlePhrase(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes == 0 { return "just idle" }
        if minutes < 60 { return "idle \(minutes)m" }
        return "idle \(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
}
