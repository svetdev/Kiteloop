import Foundation
import KiteloopCore

/// What the coordinator can see across **every** open project, rather than the
/// one project whose run it happens to be supervising.
///
/// Read-only by construction: it copies values out of the live registry into
/// plain data and holds no reference to anything it read, so nothing downstream
/// can file, edit or start work through it. It is the inventory a later
/// portfolio-level coordinator acts on; this type only reports.
///
/// Built from the same in-app sources the control API's `GET /v1/projects` and
/// `GET /v1/backlog` handlers read (`ControlSessionRegistry` → each entry's
/// `BacklogViewModel` and `BacklogAutopilot`), so the two never disagree.
struct PortfolioSnapshot: Sendable, Equatable {

    /// A project's autopilot as the portfolio sees it. `nil` on `Project.run`
    /// means idle — an idle project is never reported as having a run.
    struct RunState: Sendable, Equatable {
        enum Phase: String, Sendable, Equatable {
            case running, reviewing, paused
        }
        let phase: Phase
        /// The item in flight, when the queue still holds it. Nil for a paused
        /// run whose queue has been cleared.
        let itemID: String?
        let itemTitle: String?
        /// 1-based, for reading — `BacklogAutopilot.Status` counts from 0.
        let position: Int
        let total: Int
        /// Reviewer attempt, `.reviewing` only.
        let attempt: Int?
        /// Where inside the pipeline this run is right now. Nil for `.paused`
        /// and for a run whose first phase hasn't landed yet. Defaulted so
        /// every existing caller of the memberwise initializer — every test
        /// that builds a `RunState` without knowing about the rail — keeps
        /// compiling unchanged.
        var phaseRail: PhaseRail? = nil

        /// The worker → verify → review → wait → merge → gate pipeline a run
        /// moves through, read off `BacklogAutopilot.RunPhase` — the same one
        /// type the fleet board's state cell and the Autopilot tab's in-flight
        /// row both draw, so the two can't disagree about where a run is.
        struct PhaseRail: Sendable, Equatable {
            /// Declaration order is pipeline order — `stepsDone` reads it.
            enum Step: String, CaseIterable, Sendable, Equatable {
                case worker, verify, review
                /// Queued behind another merge on the same project — the merge
                /// gate is held by a sibling run and this one has not started
                /// verifying anything yet. Ordered before `merge` because that
                /// is where the wait happens; like `verify`, it reads done for
                /// a merge that never had to wait, since everything before
                /// `current` is behind the run either way.
                case waitingForGate
                case merge, gate
            }
            /// The step this run is on right now.
            let current: Step
            /// The worker/reviewer round the current step belongs to.
            let attempt: Int
            /// Seconds since the run last did anything recordable — the same
            /// clock `BacklogAutopilot`'s stall watchdog compares against its
            /// own timeout.
            let lastOutputAge: TimeInterval
            /// Half of the project's `stallTimeoutMinutes`, in seconds — the
            /// age past which the rail's clock reads as a warning, ahead of
            /// the watchdog actually firing.
            let warnAtSeconds: TimeInterval

            /// Every step before `current`, in pipeline order.
            var stepsDone: [Step] {
                guard let currentIndex = Step.allCases.firstIndex(of: current) else { return [] }
                return Array(Step.allCases[..<currentIndex])
            }
            /// Whether `lastOutputAge` is far enough along to warn about.
            var isStale: Bool { lastOutputAge >= warnAtSeconds }

            /// The `RunPhase` → `Step` mapping, exhaustive over `RunPhase` so a
            /// case added there and never taught here fails to compile rather
            /// than quietly drawing no step. `verify` is `current` for as long
            /// as the app is running the item's own `verify:` itself — the
            /// pre-review gate's measurement, which is a build and can take the
            /// whole of `verifyTimeout`. An item that declares no verify never
            /// logs the phase, and its `verify` step reads done the moment
            /// `review` (or anything after it) becomes current, since
            /// everything before `current` is behind the run either way.
            static func step(for phase: BacklogAutopilot.RunPhase) -> Step? {
                switch phase {
                case .worker, .workerEmptyDiff, .workerSteer:
                    return .worker
                case .verify:
                    return .verify
                case .reviewer, .reviewerClarify, .reviewerClarifyTimeout:
                    return .review
                case .merge, .mergeWaiting, .pullRequest, .pullRequestChecks, .pullRequestFix,
                     .pullRequestComments, .runStart, .itemStart, .itemRelease, .itemAbort,
                     .itemOverBudget, .itemNearCap, .itemEnd, .itemParked, .agentRestart, .runPause, .runEnd:
                    return stepAtOrPastTheGate(for: phase)
                }
            }

            /// The half of the mapping past the review — the merge, the wait in
            /// front of it, the pull-request gate, and every phase the rail
            /// draws nothing for. Split out of `step(for:)` rather than merged
            /// into it so each stays under the complexity gate; both switches
            /// are exhaustive over `RunPhase` with no `default`, so a case
            /// added there is a compile error in two places instead of a
            /// silently unmapped step in one.
            private static func stepAtOrPastTheGate(
                for phase: BacklogAutopilot.RunPhase
            ) -> Step? {
                switch phase {
                case .merge:
                    return .merge
                case .mergeWaiting:
                    return .waitingForGate
                case .pullRequest, .pullRequestChecks, .pullRequestFix, .pullRequestComments:
                    return .gate
                case .worker, .workerEmptyDiff, .workerSteer, .verify,
                     .reviewer, .reviewerClarify, .reviewerClarifyTimeout,
                     .runStart, .itemStart, .itemRelease, .itemAbort, .itemOverBudget,
                     .itemNearCap, .itemEnd, .itemParked, .agentRestart, .runPause, .runEnd:
                    return nil
                }
            }
        }
    }

    /// One finished item, newest first in `Project.recentOutcomes`.
    struct ItemOutcome: Sendable, Equatable {
        let itemID: String
        /// `done`, `awaiting-approval`, `blocked`, `cancelled`.
        let outcome: String
    }

    /// The last thing a project's autopilot decided about starting, when it
    /// decided not to (`BacklogAutopilot.StartOutcome`).
    ///
    /// Copied out as plain strings rather than carried as the outcome itself:
    /// the snapshot holds no reference to anything it read, and the two fields
    /// are the whole of what a reader wants — which gate answered, and what it
    /// said. Nil on `Project.lastStartRefusal` means the last start was accepted
    /// or none has been asked for, which are both "nothing was refused".
    struct StartRefusal: Sendable, Equatable {
        /// The gate that refused — `BacklogAutopilot.StartOutcome.Refusal`'s own
        /// spelling, the same word `logPhase(.runStart, …)` records.
        let gate: String
        /// The gate's own words, verbatim.
        let detail: String
    }

    /// A project running nothing, with work it says could run.
    ///
    /// `idle` is written for two states that mean opposite things: a project
    /// with nothing left to do, and a project with runnable items the fleet
    /// keeps declining to start. Both render as a quiet, healthy-looking row,
    /// and only the second wants anybody's attention. On 2026-08-21 this repo
    /// sat at six runnable items with the fleet idle for roughly half an hour —
    /// the scheduler alive, selecting an item every tick and refusing it every
    /// tick, with the reason recoverable only by reading `control-runs.jsonl` by
    /// hand. Nothing was broken and nothing said anything was wrong.
    ///
    /// The same shape of disagreement `ItemDisagreement` reports, one level up:
    /// the queue says there is work, the fleet says it is doing none, and both
    /// are telling the truth. Held to the same discipline — stated, never acted
    /// on. Nothing here starts, reorders or retries a run; the fleet's decision
    /// stands, it is only being made legible.
    struct IdleWithRunnableWork: Sendable, Equatable {

        /// How many ready items are inside the Definition-of-Ready right now —
        /// `QueueHealth.runnable`, the control API's `queue.runnable`.
        let runnable: Int

        /// What the last start decision refused with, in the deciding gate's own
        /// words — verbatim, for the reason `ItemActions.runReason` quotes the
        /// readiness summary rather than paraphrasing it: a second wording of a
        /// refusal drifts from the one that actually decided, and then the screen
        /// and the run log say different things about the same tick.
        ///
        /// Nil when the last start was accepted, or when none has been asked
        /// for. The contradiction is reported either way — a decision with no
        /// recorded reason is still a project idling on runnable work, it simply
        /// has less to say about why.
        let refusal: String?

        /// The items that refusal names, in backlog order.
        ///
        /// Matched against ids the backlog actually holds rather than parsed out
        /// of the sentence, so this can only ever name an item that exists. The
        /// candidates are the ready items the snapshot names, which is a capped
        /// sample (`ItemSample`) — an id past the cap goes unmatched rather than
        /// guessed at.
        let namedItems: [String]

        /// e.g. `idle, 6 runnable`.
        var headline: String {
            "idle, \(runnable) runnable"
        }

        /// The refusal as the line under that headline, or nil when none was
        /// recorded.
        var refusalLine: String? {
            refusal.map { "declined: \($0)" }
        }
    }

    /// One item the snapshot **names** rather than merely counts, so a question
    /// below the level of "how many" has something to answer with.
    ///
    /// Deliberately thin: an id, a title and a size are what "which items are
    /// stuck?" turns on. Nothing here carries the item's detail file — reading
    /// one project deeply is a different question with a different cost.
    struct Item: Sendable, Equatable {
        let id: String
        let title: String
        /// `ItemSize.rawValue`, or nil for an unsized item.
        let size: String?
        /// What this item's last recorded run ended as. Looked up for **blocked**
        /// items only — that is the question this list exists to answer — so nil
        /// on a `ready` item means "not looked up", and nil on a blocked one
        /// means the item has never been run.
        let lastRun: LastRun?
    }

    /// The last run an item has on record, read from `TaskMetricStore`.
    ///
    /// Its absence is a fact in its own right: an item that has never run has no
    /// reason to report, and the snapshot says so rather than reaching for the
    /// backlog line's own annotation and passing it off as a run's verdict.
    struct LastRun: Sendable, Equatable {
        /// The outcome class — `blocked`, `done`, `awaiting-approval`, `cancelled`.
        let outcome: String
        /// The reason half of `blocked:<reason>`, when the outcome carried one.
        let reason: String?
        /// The judge's advisory score, where the run has one.
        let qualityScore: Double?
    }

    /// A capped list of one status's items, and what the cap left out.
    ///
    /// The snapshot goes into a prompt, so the list is a **sample**: `omitted`
    /// is carried beside it so a reader never mistakes a capped list for the
    /// whole of a status. `Project.statusCounts` stays the authority on totals.
    struct ItemSample: Sendable, Equatable {
        let items: [Item]
        /// How many items of this status are not in `items`.
        let omitted: Int

        static let none = ItemSample(items: [], omitted: 0)
        var isEmpty: Bool { items.isEmpty }
        /// What the sample was drawn from — the true count for this status.
        var total: Int { items.count + omitted }
    }

    /// How the snapshot finds an item's last recorded run.
    ///
    /// A closure rather than the store itself, so the per-project assembly is
    /// exercised without a metric store on disk and the snapshot — which is
    /// plain, `Sendable` data by construction — never holds what it read from.
    typealias LastRunLookup = (String) -> LastRun?

    struct Project: Sendable, Equatable {
        let name: String
        let path: String
        /// Both a worker and a reviewer assigned — the same condition the control
        /// API reports as `autopilotReady`.
        let autopilotReady: Bool
        /// The project's consent to unattended work (`BacklogAutopilot.
        /// autonomousWorkEnabled`). Being able to run is not agreeing to be
        /// run: the scheduler and the grooming loop skip projects without it.
        var autonomousWorkEnabled: Bool = false
        /// Whether this project's own autopilot clears its approval gate itself
        /// (`BacklogAutopilot.approveReviewPassedRuns`). A project on that rung
        /// is never held by `RunScheduling.gateFullDetail` — it drains its own
        /// gate, so a human backing up behind it is not a state this project
        /// can be in.
        var approveReviewPassedRuns: Bool = false
        let statusCounts: [BacklogItemStatus: Int]
        /// A sample of the `ready` items — what would run next. Capped; see
        /// `ItemSample`. `var` with a default for the same reason
        /// `portfolioGoal` is: a caller that only cares about counts (the refill
        /// planner does) keeps the call it already had.
        var readyItems: ItemSample = .none
        /// A sample of the `blocked` items — what is stuck, and what its last
        /// recorded run said it was stuck on.
        var blockedItems: ItemSample = .none
        /// How many of the `ready` items could actually start right now —
        /// `QueueHealth.startable`, read from the project's own queue-health
        /// verdict. Nil when the snapshot was built without one (a caller that
        /// only cares about the raw tally), in which case a reader falls back to
        /// `count(.ready)` — a queue full of items that cannot run looks exactly
        /// like a healthy one to anything that only counts what's in it.
        var startable: Int? = nil
        /// How many of the `ready` items are inside the Definition-of-Ready —
        /// `QueueHealth.runnable`, read from the same verdict `startable` is,
        /// so the pair cannot come from two derivations. Larger than `startable`
        /// by exactly the items a pre-run gate is on record as having refused.
        /// Nil on the same terms: a queue nobody measured, never a queue of
        /// nothing.
        var runnable: Int? = nil
        /// What the project's last start decision refused with, or nil when it
        /// was accepted, when none has been asked for, or when the caller had no
        /// autopilot to ask.
        var lastStartRefusal: StartRefusal? = nil
        /// Nil when the project is idle.
        let run: RunState?
        let recentOutcomes: [ItemOutcome]
        /// Whether a human has parked this project on the fleet board. A project
        /// nobody has touched is running, never parked.
        let paused: Bool
        /// The human's statement of what this project is for. Nil when unstated.
        let goal: String?

        /// The hard stop. A paused project is off limits to the coordinator, and
        /// this is what says so — not a sentence in a prompt the persona could
        /// reason its way around.
        ///
        /// True either because a human parked the project on the fleet board, or
        /// because its own autopilot is holding the queue (`BacklogAutopilot.
        /// pause()`, `POST /v1/autopilot/pause`) — a queue held mid-run is
        /// exactly as off limits to a fresh pickup as one the fleet board's
        /// switch stopped outright, and pausing is one act now rather than two
        /// that disagree.
        var isPaused: Bool { paused || run?.phase == .paused }

        var isRunning: Bool { run != nil }
        var totalItems: Int { statusCounts.values.reduce(0, +) }
        func count(_ status: BacklogItemStatus) -> Int { statusCounts[status] ?? 0 }

        /// This project's two cells read together: idle, with runnable work, and
        /// what it said when it declined. Nil for every state that is not that
        /// contradiction — see `idleWithRunnableWork(runnable:run:isPaused:…)`.
        var idleWithRunnableWork: IdleWithRunnableWork? {
            PortfolioSnapshot.idleWithRunnableWork(
                runnable: runnable, run: run, isPaused: isPaused,
                refusal: lastStartRefusal, candidateItemIDs: readyItems.items.map(\.id))
        }

        /// What the fleet board's state cell says for this project, first
        /// match wins: the item a run is working on — even in a project parked
        /// while it ran, since that run finishes — then paused (parked by hand,
        /// or a run holding its queue), then idle with runnable work, and
        /// otherwise quiet.
        var boardState: BoardState {
            if let run, let itemID = run.itemID { return .inFlight(run, itemID: itemID) }
            if isPaused { return .paused }
            if let idle = idleWithRunnableWork { return .idleWithWork(idle) }
            return .quiet
        }
    }

    /// The fleet board's state cell — see `Project.boardState`.
    enum BoardState: Sendable, Equatable {
        case inFlight(RunState, itemID: String)
        case paused
        case idleWithWork(IdleWithRunnableWork)
        case quiet
    }

    /// Ordered by project name, so two snapshots of the same portfolio compare
    /// and read the same way.
    let projects: [Project]

    /// The portfolio-level statement from `GlobalConfig`, for when per-project
    /// priorities tie. Nil when nothing is stated.
    var portfolioGoal: String? = nil

    var isEmpty: Bool { projects.isEmpty }
    func project(named name: String) -> Project? { projects.first { $0.name == name } }

    // MARK: - Selection (the hard stop)

    /// The projects a coordinator may choose work in — everything except the
    /// paused ones.
    ///
    /// `paused` is enforced here, in code, rather than left to the persona: the
    /// filter runs before any recommendation is asked for, so a paused project
    /// is not a choice the coordinator declines, it is a choice it is never
    /// offered. Every future selection path must read this and not `projects`.
    var selectableProjects: [Project] { projects.filter { !$0.isPaused } }

    /// Whether the coordinator may act on this project at all. An unknown
    /// project is not selectable — a name that isn't in the portfolio is not a
    /// project the coordinator has been given.
    func isSelectable(projectNamed name: String) -> Bool {
        project(named: name).map { !$0.isPaused } ?? false
    }

    // MARK: - Idle with runnable work

    /// Whether a project is idle with work it could start, and what it said when
    /// it declined.
    ///
    /// Pure, and given the two facts rather than the objects holding them: the
    /// rule is the part worth testing, and it is the part that has to agree with
    /// what the board draws.
    ///
    /// Nil for everything that is not the contradiction, which is most states:
    ///
    /// * **A run in flight.** One run at a time per project is the design, so a
    ///   queue waiting behind a running item is normal and must not be flagged —
    ///   flagging it would make the surface lie about the healthy case. A paused
    ///   run counts as a run here for the same reason: it is queued work
    ///   somebody stopped, and `RunState` reports it precisely so it is not read
    ///   as idleness.
    /// * **A paused project.** The hard stop is the human's, it is the answer to
    ///   "why is nothing running", and the paused control already carries it.
    /// * **Nothing runnable** — the healthy, finished project this state is
    ///   being told apart from.
    /// * **A queue nobody measured** (`runnable == nil`). An unasked question
    ///   has no answer, and reporting one would be a claim nobody made.
    ///
    /// - Parameters:
    ///   - runnable: `QueueHealth.runnable` for this project, or nil if the
    ///     caller never asked for it.
    ///   - candidateItemIDs: the ids a named item may be matched against —
    ///     `Project.readyItems`. Nothing outside this list can be named, so the
    ///     reading cannot invent an item.
    static func idleWithRunnableWork(runnable: Int?,
                                     run: RunState?,
                                     isPaused: Bool,
                                     refusal: StartRefusal?,
                                     candidateItemIDs: [String] = []) -> IdleWithRunnableWork? {
        guard run == nil, !isPaused, let runnable, runnable > 0 else { return nil }
        let detail = refusal?.detail
        return IdleWithRunnableWork(
            runnable: runnable,
            refusal: detail,
            namedItems: detail.map { itemsNamed(in: $0, among: candidateItemIDs) } ?? [])
    }

    /// Which of `candidates` a refusal's sentence names, in the order given.
    ///
    /// A match, never a parse: the gates write their reasons in several shapes
    /// (`noRunnableItemsDetail`'s bucket list is only one of them), and a reader
    /// of one shape would silently name nothing for the others. Looking for ids
    /// the backlog already holds works on all of them and can only ever produce
    /// an item that exists.
    ///
    /// An id that is a strict substring of another matched id is dropped: `a`
    /// and `a-b` can both be ready items, and a sentence naming `a-b` contains
    /// `a` — the longer one is what was actually written down.
    static func itemsNamed(in text: String, among candidates: [String]) -> [String] {
        let matched = candidates.filter { !$0.isEmpty && text.contains($0) }
        return matched.filter { id in !matched.contains { $0 != id && $0.contains(id) } }
    }

    // MARK: - Capture

    /// How many finished items each project reports. Enough to see a run of
    /// failures without turning the prompt into a run log.
    static let recentOutcomeLimit = 5

    /// How many items **per status, per project** are named. The hard bound the
    /// item asks for: the snapshot is prompt text, and an unbounded list of a
    /// backlog's `ready` column would make every message more expensive and
    /// eventually push out something that mattered. What the cap leaves out is
    /// reported (`ItemSample.omitted`) rather than dropped silently.
    static let itemLimit = 8

    /// How long an item's title, or its block reason, may be in the prompt. A
    /// phrase, not a paragraph — several of these go on one project's lines.
    static let itemTextLimit = 120

    /// Snapshot every open project. Reads only — nothing here mutates a session,
    /// a backlog or an autopilot.
    ///
    /// Priority and goal are read from each project's own `.kiteloop/config.json`
    /// on every capture, so an edit in the Portfolio takes effect on the next
    /// consult rather than at the next app launch.
    ///
    /// `metrics` is what turns "12 blocked" into "12 blocked, 9 of them on
    /// `verify_passed`". Without it the items are still named — an id, a title
    /// and a size come from the backlog — they simply report no recorded run.
    @MainActor
    static func capture(registry: ControlSessionRegistry,
                        portfolioGoal: String? = nil,
                        metrics: TaskMetricStore? = nil,
                        recentLimit: Int = recentOutcomeLimit,
                        itemLimit: Int = itemLimit) -> PortfolioSnapshot {
        PortfolioSnapshot(
            projects: registry.openProjects.map { entry in
                let config = entry.session.project.loadConfig()
                let path = entry.session.project.rootURL.path(percentEncoded: false)
                return project(
                    name: entry.session.project.rootURL.lastPathComponent,
                    path: path,
                    autopilotReady: entry.autopilot.workerAgentID != nil
                        && entry.autopilot.reviewerAgentID != nil,
                    autonomousWorkEnabled: entry.autopilot.autonomousWorkEnabled,
                    approveReviewPassedRuns: entry.autopilot.approveReviewPassedRuns,
                    backlog: entry.session.backlogViewModel.backlogFile,
                    status: entry.autopilot.status,
                    runQueue: entry.autopilot.runQueue,
                    currentRunPhase: entry.autopilot.currentRunPhase,
                    currentRunAttempt: entry.autopilot.currentRunAttempt,
                    lastActivityAt: entry.autopilot.lastActivityAt,
                    stallTimeoutMinutes: entry.autopilot.stallTimeoutMinutes,
                    results: entry.autopilot.results,
                    paused: config.paused ?? false,
                    goal: KiteloopProject.normalizedStatement(config.goal),
                    recentLimit: recentLimit,
                    itemLimit: itemLimit,
                    lastRun: lastRunLookup(metrics: metrics, projectPath: path),
                    startable: entry.session.backlogViewModel.queueHealth.startable,
                    runnable: entry.session.backlogViewModel.queueHealth.runnable,
                    lastStartRefusal: startRefusal(entry.autopilot.lastStartOutcome)
                )
            },
            portfolioGoal: KiteloopProject.normalizedStatement(portfolioGoal)
        )
    }

    /// The per-project assembly, split from `capture` so it is exercised without
    /// a live registry. The parked flag and the goal default to unstated — a
    /// caller that says nothing gets a running project, never a parked one.
    /// `lastRun` defaults to knowing nothing, which reports honestly rather
    /// than emptily.
    static func project(name: String, path: String, autopilotReady: Bool,
                        autonomousWorkEnabled: Bool = false,
                        approveReviewPassedRuns: Bool = false,
                        backlog: BacklogFile?, status: BacklogAutopilot.Status,
                        runQueue: [BacklogItem],
                        currentRunPhase: BacklogAutopilot.RunPhase? = nil,
                        currentRunAttempt: Int = 1,
                        lastActivityAt: Date = Date(),
                        stallTimeoutMinutes: Int = RunTimeouts.defaultWorkerMinutes,
                        results: [BacklogAutopilot.ItemResult],
                        paused: Bool = false, goal: String? = nil,
                        recentLimit: Int = recentOutcomeLimit,
                        itemLimit: Int = itemLimit,
                        lastRun: LastRunLookup = { _ in nil },
                        startable: Int? = nil,
                        runnable: Int? = nil,
                        lastStartRefusal: StartRefusal? = nil) -> Project {
        Project(
            name: name,
            path: path,
            autopilotReady: autopilotReady,
            autonomousWorkEnabled: autonomousWorkEnabled,
            approveReviewPassedRuns: approveReviewPassedRuns,
            statusCounts: statusCounts(backlog),
            // Ready items are what would run next; nothing has run them, so
            // they are named and nothing more.
            readyItems: items(backlog, status: .ready, limit: itemLimit),
            blockedItems: items(backlog, status: .blocked, limit: itemLimit, lastRun: lastRun),
            startable: startable,
            runnable: runnable,
            lastStartRefusal: lastStartRefusal,
            run: runState(status: status, runQueue: runQueue,
                         currentRunPhase: currentRunPhase, currentRunAttempt: currentRunAttempt,
                         lastActivityAt: lastActivityAt, stallTimeoutMinutes: stallTimeoutMinutes),
            recentOutcomes: recentOutcomes(results, limit: recentLimit),
            paused: paused,
            goal: goal
        )
    }

    /// The items of one status, capped — with the overflow counted rather than
    /// discarded.
    ///
    /// The `ready` ones come back in **run order**: lane first, the order the
    /// file is written in second, which is the order `BacklogAutopilot` walks
    /// its queue in. It has to be that order and not the file's, because the
    /// list is capped: a `now` item further down the file than the cap reaches
    /// would otherwise be missing from the "next items" the coordinator reads
    /// and from the queue on the phone, while an item nothing will run for
    /// hours sat at the top of both. Every other status is left in file order —
    /// nothing runs those, so there is no run order to report.
    static func items(_ backlog: BacklogFile?, status: BacklogItemStatus,
                      limit: Int = itemLimit,
                      lastRun: LastRunLookup = { _ in nil }) -> ItemSample {
        let found = (backlog?.sections ?? []).flatMap(\.items).filter { $0.status == status }
        let matching = status == .ready ? BacklogLane.ordered(found) : found
        let shown = matching.prefix(max(0, limit))
        return ItemSample(
            items: shown.map {
                Item(id: $0.id, title: statementLine($0.title, limit: itemTextLimit),
                     size: $0.size?.rawValue, lastRun: lastRun($0.id))
            },
            omitted: matching.count - shown.count
        )
    }

    /// The last start decision as the snapshot carries it, or nil when there is
    /// nothing refused to report.
    ///
    /// An accepted start is deliberately dropped rather than carried as a
    /// refusal with an empty reason: "the run began" is not a reason nothing is
    /// running, and a project that finished the queue it was given would
    /// otherwise report the acceptance that started it as the cause of its
    /// idleness.
    static func startRefusal(_ outcome: BacklogAutopilot.StartOutcome?) -> StartRefusal? {
        guard let outcome, let refusal = outcome.refusal else { return nil }
        return StartRefusal(gate: refusal.rawValue, detail: outcome.detail)
    }

    /// The lookup over a real metric store, **scoped to one project**: records
    /// are global and keyed by item id, so an unscoped lookup would hand one
    /// project's block reason to another project's identically-named item.
    ///
    /// Built once per project rather than scanned per item — the store is
    /// append-only, so the last line for an id is the latest run of it.
    @MainActor
    static func lastRunLookup(metrics: TaskMetricStore?, projectPath: String) -> LastRunLookup {
        guard let metrics else { return { _ in nil } }
        let canonical = KiteloopProject.canonicalPath(projectPath)
        var latest: [String: TaskMetricRecord] = [:]
        for record in metrics.records
        where KiteloopProject.canonicalPath(record.projectPath) == canonical {
            latest[record.itemID] = record
        }
        return { itemID in
            guard let record = latest[itemID] else { return nil }
            let split = splitOutcome(record.outcome)
            return LastRun(outcome: split.outcome, reason: split.reason,
                           qualityScore: record.qualityScore)
        }
    }

    /// `blocked:<reason>`, as `BacklogAutopilot` writes it into
    /// `TaskMetricRecord.outcome`, split back into the class and the reason. An
    /// outcome that carries no reason — `done`, `cancelled` — is all class.
    static func splitOutcome(_ raw: String) -> (outcome: String, reason: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return (trimmed, nil) }
        let reason = trimmed[trimmed.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(trimmed[..<colon]), reason.isEmpty ? nil : reason)
    }

    /// Items per status across every epic. Statuses with no items are absent
    /// rather than zero — the reader wants what exists, not the whole enum.
    static func statusCounts(_ backlog: BacklogFile?) -> [BacklogItemStatus: Int] {
        var counts: [BacklogItemStatus: Int] = [:]
        for section in backlog?.sections ?? [] {
            for item in section.items {
                counts[item.status, default: 0] += 1
            }
        }
        return counts
    }

    /// `.idle` is the one status that is genuinely no run; a paused run is still
    /// a run the portfolio has to account for, so it is reported with its phase.
    static func runState(status: BacklogAutopilot.Status, runQueue: [BacklogItem]) -> RunState? {
        func item(_ index: Int) -> BacklogItem? {
            runQueue.indices.contains(index) ? runQueue[index] : nil
        }
        switch status {
        case .idle:
            return nil
        case .running(let index, let total):
            return RunState(phase: .running, itemID: item(index)?.id, itemTitle: item(index)?.title,
                            position: index + 1, total: total, attempt: nil)
        case .reviewing(let index, let total, let attempt):
            return RunState(phase: .reviewing, itemID: item(index)?.id, itemTitle: item(index)?.title,
                            position: index + 1, total: total, attempt: attempt)
        case .paused:
            return RunState(phase: .paused, itemID: nil, itemTitle: nil,
                            position: 0, total: runQueue.count, attempt: nil)
        }
    }

    /// `runState`, with the phase rail attached from the run's live phase
    /// fields — split out so the plain two-argument form every existing
    /// caller (every test included) keeps compiling, and keeps its own
    /// baselined complexity, unchanged.
    static func runState(status: BacklogAutopilot.Status, runQueue: [BacklogItem],
                         currentRunPhase: BacklogAutopilot.RunPhase?,
                         currentRunAttempt: Int,
                         lastActivityAt: Date,
                         stallTimeoutMinutes: Int,
                         now: Date = Date()) -> RunState? {
        guard var state = runState(status: status, runQueue: runQueue) else { return nil }
        // A paused run has stopped mid-pipeline with nothing currently active
        // to ring — the same reason `runState` never gives `.paused` a rail.
        guard state.phase != .paused else { return state }
        state.phaseRail = phaseRail(currentRunPhase: currentRunPhase, attempt: currentRunAttempt,
                                    lastActivityAt: lastActivityAt,
                                    stallTimeoutMinutes: stallTimeoutMinutes, now: now)
        return state
    }

    /// The phase rail derivation, callable directly wherever a `BacklogAutopilot`
    /// is at hand without a whole snapshot — the control API's per-project `run`
    /// object and the Autopilot tab's in-flight row both read it this way, so a
    /// fleet-wide capture is never the only way to ask "where is this run?".
    /// Nil when the phase is unknown or the pipeline draws no step for it.
    static func phaseRail(currentRunPhase: BacklogAutopilot.RunPhase?, attempt: Int,
                          lastActivityAt: Date, stallTimeoutMinutes: Int,
                          now: Date = Date()) -> RunState.PhaseRail? {
        guard let currentRunPhase, let step = RunState.PhaseRail.step(for: currentRunPhase) else { return nil }
        return RunState.PhaseRail(
            current: step, attempt: attempt,
            lastOutputAge: now.timeIntervalSince(lastActivityAt),
            warnAtSeconds: TimeInterval(max(1, stallTimeoutMinutes) * 60) / 2
        )
    }

    /// The last finished items, newest first. `results` is the autopilot's own
    /// per-project list; the persisted run history is deliberately not used —
    /// it is one file shared by every project and carries no project identity.
    static func recentOutcomes(_ results: [BacklogAutopilot.ItemResult],
                               limit: Int = recentOutcomeLimit) -> [ItemOutcome] {
        results.suffix(max(0, limit)).reversed().map {
            ItemOutcome(itemID: $0.id, outcome: outcomeName($0.outcome))
        }
    }

    /// Blocked items carry a reason; the portfolio view wants the class, not the
    /// paragraph — the reason belongs to that project's own run diagnostics.
    static func outcomeName(_ outcome: BacklogAutopilot.ItemResult.Outcome) -> String {
        switch outcome {
        case .done: return "done"
        case .awaitingApproval: return "awaiting-approval"
        case .blocked: return "blocked"
        case .cancelled: return "cancelled"
        case .alreadyImplemented: return TaskMetricRecord.alreadyImplementedOutcome
        case .investigation: return TaskMetricRecord.investigationOutcome
        case .usageLimitParked: return TaskMetricRecord.usageLimitParkedOutcome
        }
    }

    // MARK: - Prompt rendering

    /// The snapshot as a section of the advisor prompt. Empty string when no
    /// project is open, so the prompt gains nothing rather than an empty heading.
    ///
    /// Paused projects are still listed — the coordinator should be able to see
    /// why nothing is moving there — but annotated as off limits. The listing is
    /// context; `selectableProjects` is what actually enforces the stop.
    var promptSection: String {
        guard !projects.isEmpty else { return "" }
        var out = "## Portfolio (\(projects.count) project\(projects.count == 1 ? "" : "s") open)\n"
        if let portfolioGoal {
            out += "Portfolio goal: \(Self.statementLine(portfolioGoal))\n"
        }
        for project in projects {
            out += "- \(project.name): \(Self.countsLine(project.statusCounts))"
            out += " | autopilot \(project.autopilotReady ? "ready" : "not ready")"
            out += " | \(Self.runLine(project.run))"
            if !project.recentOutcomes.isEmpty {
                out += " | recent: " + project.recentOutcomes
                    .map { "\($0.itemID)=\($0.outcome)" }
                    .joined(separator: ", ")
            }
            if project.isPaused {
                out += " | paused (hard stop — never select this project for work)"
            }
            if let goal = project.goal {
                out += " | goal: \(Self.statementLine(goal))"
            }
            out += "\n"
            out += Self.itemLines(project)
        }
        return out
    }

    /// The named items under a project's line: what would run next, and what is
    /// stuck. Indented sub-lines, so the counts line keeps the shape it had and
    /// a reader that only wants totals can skip past them. A status with no
    /// items contributes nothing at all.
    static func itemLines(_ project: Project) -> String {
        var out = ""
        if !project.readyItems.isEmpty {
            out += "    ready \(sampleNote(project.readyItems)): "
            out += project.readyItems.items.map(itemPhrase).joined(separator: "; ") + "\n"
        }
        if !project.blockedItems.isEmpty {
            out += "    blocked \(sampleNote(project.blockedItems)):\n"
            for item in project.blockedItems.items {
                out += "      - \(itemPhrase(item)) — \(lastRunPhrase(item.lastRun))\n"
            }
        }
        return out
    }

    private static func itemPhrase(_ item: Item) -> String {
        var phrase = "\(item.id) “\(item.title)”"
        if let size = item.size { phrase += " [\(size)]" }
        return phrase
    }

    /// Says the list is a sample whenever it is one. A capped list read as a
    /// complete one is the failure mode worth spending characters against —
    /// "12 blocked" would become "8 blocked" the moment anyone counted the
    /// lines instead of reading the counts.
    private static func sampleNote(_ sample: ItemSample) -> String {
        sample.omitted == 0
            ? "(all \(sample.items.count))"
            : "(\(sample.items.count) of \(sample.total), \(sample.omitted) not shown)"
    }

    /// Why the last run said this item was stuck — or that no run ever said
    /// anything about it, which is the honest answer and never a guessed reason.
    private static func lastRunPhrase(_ run: LastRun?) -> String {
        guard let run else { return "no recorded run" }
        var phrase = "last run \(run.outcome)"
        if let reason = run.reason { phrase += ": \(statementLine(reason, limit: itemTextLimit))" }
        if let score = run.qualityScore { phrase += String(format: " (quality %.2f)", score) }
        return phrase
    }

    /// How long a stated goal may be in the prompt. A paragraph, not an essay —
    /// the goal is context for a judgment, and the prompt has a run to describe
    /// as well.
    static let statementLimit = 240

    /// A free-text statement flattened onto one line and capped, so a multi-line
    /// goal can't break the one-project-per-line shape the reader depends on.
    static func statementLine(_ text: String, limit: Int = statementLimit) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// Counts in the stage order an item moves through, so two projects line up.
    private static func countsLine(_ counts: [BacklogItemStatus: Int]) -> String {
        let parts = BacklogItemStatus.allCases.compactMap { status -> String? in
            guard let count = counts[status], count > 0 else { return nil }
            return "\(status.rawValue) \(count)"
        }
        return parts.isEmpty ? "no items" : parts.joined(separator: ", ")
    }

    private static func runLine(_ run: RunState?) -> String {
        guard let run else { return "idle" }
        switch run.phase {
        case .paused:
            return "paused (\(run.total) queued)"
        case .running, .reviewing:
            var line = "\(run.phase.rawValue) \(run.position)/\(run.total)"
            if let itemID = run.itemID { line += " \(itemID)" }
            if let attempt = run.attempt { line += " (attempt \(attempt))" }
            return line
        }
    }
}
