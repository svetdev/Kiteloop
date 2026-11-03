import Foundation
import KiteloopCore
import os.log

private let autopilotLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "backlog-autopilot")

@Observable
@MainActor
class BacklogAutopilot {
    enum Status: Equatable {
        case idle
        case running(itemIndex: Int, total: Int)
        case reviewing(itemIndex: Int, total: Int, attempt: Int)
        case paused

        /// The one word for this status — what the control API reports and what a
        /// refusal names. One mapping, so the API and the run log can't drift.
        var label: String {
            switch self {
            case .idle: return "idle"
            case .running: return "running"
            case .reviewing: return "reviewing"
            case .paused: return "paused"
            }
        }
    }

    /// A run actually in flight, and what it is — the answer to "what do you
    /// think you're running?".
    ///
    /// `status` alone cannot answer that: it is a flag the run loop sets and
    /// clears, and every path that leaves it set with nothing behind it turns
    /// into a project that refuses work forever. This is derived from the two
    /// things that can only be true while something is running, so it cannot go
    /// stale on its own.
    struct InFlightRun: Equatable {
        var itemID: String?
        var itemTitle: String?
        /// The workflow execution driving it, once one exists. Nil in the gap
        /// between the loop picking an item up and the workflow spinning up.
        var executionID: String?
        /// When this item became the one in flight — the "since when" half of
        /// "what are you running?". Nil only when the run was staged rather than
        /// started (a test seam), since a real pickup always stamps it.
        var startedAt: Date?

        /// How a refusal names it. A 409 that can't say what it is running is
        /// unfalsifiable from the outside — naming it is what makes a stale
        /// claim obvious immediately.
        var summary: String {
            let what: String
            switch (itemID, itemTitle) {
            case (let id?, let title?): what = "\(id) (\(title))"
            case (let id?, nil): what = id
            default: what = "an item"
            }
            guard let executionID else { return "running \(what)" }
            return "running \(what) as run \(executionID)"
        }
    }

    /// What this autopilot is doing right now, in the form an operator asks for
    /// it: is a run in flight, on what, since when — and does the autopilot's own
    /// `status` agree with the answer.
    ///
    /// Derived from `inFlightRun()`, the same call the busy guard makes, so a
    /// project that reports `running` here is exactly a project that would refuse
    /// the next run request. Two answers that can disagree is the failure this
    /// exists to prevent, not a second view of it.
    struct RunState: Equatable {
        /// The four states a project can be in, as one word.
        ///
        /// `held` and `inconsistent` are both "not running with a non-idle
        /// status", and telling them apart is the whole point: a `held` queue has
        /// items and a `resume` that picks them up, while an `inconsistent` one
        /// is a claim with nothing behind it — the state that had a project
        /// refusing every item with no run to wait for.
        enum Phase: String {
            case idle, running, held, inconsistent
        }

        var phase: Phase
        /// The run itself, present exactly when `phase == .running`.
        var inFlight: InFlightRun?
        /// What `status` reads, so a caller can compare the claim against the
        /// fact rather than take either on trust.
        var statusLabel: String
        /// Items still queued from the current index on, the one in flight
        /// included — so for a `held` queue this is exactly what a resume would
        /// pick up, and it is the same count `reconcileStatus` reports abandoning.
        var heldItems: Int
        /// Why the phase is what it is, when that isn't self-evident — set for
        /// `held` and `inconsistent`, nil for the two states that need no
        /// explanation.
        var detail: String?

        /// Whether a run is actually in flight. The busy guard refuses a new run
        /// on exactly this condition.
        var isRunning: Bool { phase == .running }
    }

    /// What became of a `start()` — said by the gate that decided it, and kept as
    /// a value so nobody has to infer it from the log.
    ///
    /// `POST /v1/runs` used to infer it from `log.last`, which is a narration and
    /// not a cause. Four seconds into a start the last line is the cost
    /// governor's informational cap statement, so a run that was spinning up
    /// perfectly normally was reported as `Run did not start: Cost cap: $8.00` —
    /// with a 422, which a driver correctly reads as permanent, so the item was
    /// dropped from its rotation while the run it named was executing.
    struct StartOutcome: Equatable {

        /// Which gate refused, or nil when the queue was accepted and the run
        /// began. The cases are the `reason` field `logPhase(.runStart, …)`
        /// already records, so the value and the log say the same word.
        enum Refusal: String {
            /// A run is already executing for this project.
            case runInFlight = "run-in-flight"
            /// An autonomous start met a spent daily ceiling.
            case dailyBudget = "daily-budget"
            /// The session's budget is spent, so the queue would be held before
            /// its first item began. Cleared by a resume, which opens a fresh
            /// session ledger — a condition of the moment, like the one above.
            case sessionCap = "session-cap"
            /// No orchestrator or backlog view model wired up.
            case notConfigured = "not-configured"
            case noWorkerOrReviewer = "no-worker-or-reviewer"
            case noBacklog = "no-backlog"
            /// The pickup gates took every selected item: wrong status, not
            /// ready, retired, or not grounded. The one refusal that is about
            /// the *item* rather than the moment.
            case noRunnableItems = "no-runnable-items"
            case noAgentSession = "no-agent-session"
            /// The fleet-wide hold is on — the same flag `POST /v1/runs`
            /// answers 409 over. Lifted by a resume, like the session cap
            /// above; unlike it, nothing here is project-specific.
            case fleetQuiesced = "fleet-quiesced"
            /// This project itself is paused — either a human parked it on the
            /// fleet board (`KiteloopProject.isPaused`) or its own queue is held
            /// (`pause()`, `POST /v1/autopilot/pause`). Project-specific,
            /// unlike the fleet-wide hold above; lifted the same way, by a
            /// resume.
            case paused = "paused"
        }

        /// Which `start()` this answers. Monotonic per autopilot, so a caller
        /// that noted the count before it asked can tell this outcome from the
        /// one before it without consulting a clock.
        let attempt: Int
        /// Nil when the run began.
        let refusal: Refusal?
        /// The deciding gate's own words, written down at the moment it decided
        /// rather than whatever the log happens to say when someone reads it.
        let detail: String

        var isAccepted: Bool { refusal == nil }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    struct ItemResult: Identifiable {
        let id: String
        let title: String
        /// Mutable because the gate can still move it after the item's workflow
        /// has ended: an auto-merge, or an automatic approval, turns an
        /// `awaiting-approval` ending into `done` without rebuilding the result
        /// around it and dropping the fields filled in on the way here.
        var outcome: Outcome
        let duration: TimeInterval
        /// The workflow execution that produced this result. `id` is the *item*
        /// id, and an item run twice in one session appears twice under it — this
        /// is what tells the two entries apart, so a control-API run record is
        /// closed with the ending of the run it names rather than with whichever
        /// attempt finished last. Nil where no execution was ever started (the
        /// error path below `startWorkflow`), and on a result a test staged.
        var executionID: String?
        var branch: String?
        /// The judge's advisory overall score (0–1), filled in after the run when
        /// the judge is enabled and answered. Nil = not scored, which is not the
        /// same as a bad score and must never render as one.
        var qualityScore: Double?
        /// Why there is no score, when the judge was asked and didn't deliver
        /// one. Nil when it did — or when nobody asked.
        var judgeUnavailable: RunQualityJudge.Unavailability?
        /// The worker's last words, on a run that produced no work — either its
        /// closing message or `RunClosingMessage.noOutput` when it said nothing.
        /// Nil on every other run: a run that delivered explains itself with its
        /// diff, and quoting the worker there would be noise.
        ///
        /// A field of its own rather than more text in `outcome`, because the
        /// outcome string is a `GROUP BY` column in the metric index
        /// (`MetricGrouping.outcome`) and free-form prose in it would shatter
        /// the largest bucket into one group per run.
        var closingMessage: String?
        /// The pull request this run's branch was published as, when
        /// `openPullRequest` is on and one could be opened. Nil otherwise —
        /// including when the attempt was skipped, which is recorded in the
        /// item's Notes rather than here: there is no URL to link to.
        var pullRequestURL: String?
        /// Who resolved this item's approval gate, when the run resolved it
        /// rather than parking it. Nil is the ordinary case and means "nobody
        /// did, here" — an item still at the gate, one that never reached it,
        /// or one a person approved later, which happens long after this
        /// result is written.
        var approval: Approval?
        /// Whether this run's own merge landed the branch — true, false when
        /// one was attempted and refused, nil when none was attempted: a gate
        /// that waits for a person, or a project that never merges. A merge a
        /// person triggers later at the gate happens after this result is
        /// written, so nil says "not by this run", not "not merged".
        var merged: Bool?
        /// The commit the branch became on the base when `merged` is true.
        var mergeCommit: String?
        enum Outcome {
            case done
            case awaitingApproval
            case blocked(String)
            case cancelled
            /// The run changed no files and said why, with evidence: the worker
            /// believes the item is already built. A third ending, neither
            /// work-produced nor a failed attempt — the item is parked at the
            /// human gate carrying the claim, and `RetryCeiling` counts the run
            /// neither for nor against it. See
            /// `RunWorkEvidence.AlreadyImplementedClaim`.
            ///
            /// The claim's own words ride on `closingMessage`, and its evidence
            /// is written to the item's Notes, where the human at the gate will
            /// read it. Nothing is carried in the case itself, because the
            /// outcome is a `GROUP BY` column in the metric index and prose in
            /// it would shatter the bucket — the same reason `closingMessage`
            /// exists.
            case alreadyImplemented
            /// The run changed no files because the worker checked the item's
            /// `## Premise` against the tree and refuted it — the fourth ending,
            /// and the other answer *about* an item beside the claim above. It
            /// carries the worker's report (`PremiseReport.text`): the
            /// measurement is the result, and it is what the judge scores and
            /// the reviewer reads. `outcomeString` still files it under one
            /// word, so the metric index's `GROUP BY` bucket stays whole.
            ///
            /// 2026-09-03: an item asserted four functions qualified for a
            /// change; the run that measured, found one did and refused the
            /// other three was scored 0.55 as a diff that added no tests. The
            /// item is parked at the human gate with the report in its Notes,
            /// the worktree is kept, and `RetryCeiling` counts the run neither
            /// for nor against the item.
            case investigation(String)
            /// The account's usage limit stopped the run, not anything about
            /// the item: it goes back to `ready`, the run pauses until `until`,
            /// and `RetryCeiling` counts it neither for nor against the item.
            case usageLimitParked(until: Date)
        }
        /// The vocabulary the run record and the control API report an approval
        /// in. One case today: a human approval is not recorded here at all,
        /// and adding a `.human` case would claim a run knew something it never
        /// sees.
        enum Approval: String, Codable { case automatic }
    }

    /// The cost vocabulary lives in `CostGovernor` now; these keep the names the
    /// panel, the control API and the coordinator already use.
    typealias CostPredictionSource = CostGovernor.PredictionSource
    typealias CostReadout = CostGovernor.Readout

    struct ExecutionSpan: Identifiable {
        let id = UUID()
        let nodeID: String
        let agentName: String
        let startedAt: Date
        var completedAt: Date?
        var outcome: SpanOutcome?

        enum SpanOutcome {
            case success
            case failed(String)
            case running
        }

        var isRunning: Bool { completedAt == nil }
        var duration: TimeInterval {
            (completedAt ?? Date()).timeIntervalSince(startedAt)
        }
    }

    struct RunRecord: Codable, Identifiable {
        let id: String
        let startedAt: Date
        var completedAt: Date?
        var items: [ItemRecord]
        var workerAgentName: String
        var reviewerAgentName: String

        /// The run's headline quality figure: the mean of the items the judge
        /// actually scored. Nil when none were (judge off, all cancelled, or a
        /// record written before scores were kept).
        var qualityBadge: QualityBadge? { QualityBadge.average(of: items.map(\.qualityScore)) }

        /// Why the run has no badge, when the judge was asked and failed. Only
        /// reported for a run where *nothing* was scored: one scored item is
        /// enough for a badge, and that badge — averaged over what was actually
        /// judged — is the honest figure to show.
        var judgeUnavailable: RunQualityJudge.Unavailability? {
            guard qualityBadge == nil else { return nil }
            return items.compactMap(\.judgeUnavailable).first { $0.isFailure }
        }

        struct ItemRecord: Codable, Identifiable {
            let id: String
            let title: String
            let outcome: String
            let duration: TimeInterval
            let executionID: String?
            /// Judge's overall score (0–1). Optional so history written before the
            /// judge existed still decodes; nil means unscored, not zero.
            var qualityScore: Double?
            /// The branch the item's work landed on, when the run was isolated and
            /// the branch outlived it. Optional for the same reason as the score:
            /// history written before this existed still decodes.
            var branch: String?
            /// Why the item has no score — a `RunQualityJudge.Unavailability`
            /// raw value, set when the judge was asked and didn't deliver. Kept
            /// as a string rather than the enum so a reason written by a newer
            /// build can't fail the whole history file's decode.
            var judgeUnavailableReason: String?
            /// What the worker said as it finished, on a run that produced no
            /// work — see `ItemResult.closingMessage`. Optional for the same
            /// reason as the fields above: history written before this existed
            /// still decodes.
            var closingMessage: String?
            /// `automatic` when the run itself resolved the item's approval
            /// gate (`approveReviewPassedRuns`), absent when it did not — which
            /// includes every item a person accepted, since that happens after
            /// this row is written. A string rather than the enum for the same
            /// reason as `judgeUnavailableReason`: a word written by a newer
            /// build must not fail the whole history file's decode.
            var approval: String?
            /// Whether the run's own merge landed the branch, and the commit it
            /// became — see `ItemResult.merged`. Absent when the run attempted
            /// no merge, and on history written before the field existed.
            var merged: Bool?
            var mergeCommit: String?

            /// `judgeUnavailableReason` as the enum, when it is one this build
            /// knows about. Computed, so it stays off the wire.
            var judgeUnavailable: RunQualityJudge.Unavailability? {
                judgeUnavailableReason.flatMap(RunQualityJudge.Unavailability.init(rawValue:))
            }
        }
    }

    /// A finished item's branch as the history rows present it: the ref to show,
    /// plus the worktree path when one is still on disk to open. Worktrees only
    /// survive a blocked item (kept for inspection) — after a successful run the
    /// branch itself is all there is left to point at, which is why the path is
    /// optional rather than the whole link being.
    struct BranchLink: Equatable, Sendable {
        /// Full ref, e.g. `kiteloop/ui-branch-link` — what you'd type at git.
        let branch: String
        /// The ref without the `kiteloop/` prefix every autopilot branch carries.
        /// Rows are narrow and the prefix is the same on all of them.
        let shortName: String
        /// Non-nil only while the item's worktree directory still exists.
        let worktreePath: URL?
    }

    /// Resolves what a row can offer for `branch`, checking the filesystem for the
    /// worktree rather than assuming from the outcome — a worktree left for
    /// inspection may have been cleaned up by hand long before anyone opens the
    /// history. Nil when the item ran in the live tree (no branch to show).
    nonisolated static func branchLink(
        branch: String?,
        projectRoot: URL?,
        worktreeExists: (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    ) -> BranchLink? {
        guard let branch, !branch.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let shortName = branch.hasPrefix("kiteloop/")
            ? String(branch.dropFirst("kiteloop/".count))
            : branch
        var path: URL?
        if let projectRoot, !shortName.isEmpty {
            let candidate = WorktreeSession.worktreeDirectory(for: shortName, projectRoot: projectRoot)
            if worktreeExists(candidate) { path = candidate }
        }
        return BranchLink(branch: branch, shortName: shortName, worktreePath: path)
    }

    /// `branchLink` bound to this run's project root, for the history UI.
    func branchLink(for branch: String?) -> BranchLink? {
        Self.branchLink(branch: branch, projectRoot: projectRoot)
    }

    /// The judge's advisory score as the run list shows it — a 0–100 figure plus
    /// the band that colours it. Advisory only: a low score never blocked
    /// anything, so the badge informs, it doesn't accuse.
    struct QualityBadge: Equatable, Sendable {
        /// Clamped to 0…1 on the way in — a judge that answers 1.4 shouldn't
        /// render as "140".
        let score: Double

        init(score: Double) { self.score = min(max(score, 0), 1) }

        enum Band { case good, fair, poor }

        /// Rounded percentage, e.g. 0.925 → "93". No "%" — the badge is labelled
        /// "Q" and a percent sign reads like a pass rate.
        var text: String { "\(Int((score * 100).rounded()))" }

        /// The rubric wants four dimensions broadly satisfied, so ≥ 0.8 is the
        /// bar for "as asked". Below half means the judge found the work wrong,
        /// not merely rough — worth looking at even though nothing was blocked.
        var band: Band {
            if score >= 0.8 { return .good }
            if score >= 0.5 { return .fair }
            return .poor
        }

        /// Mean of the scores that exist. Unscored items are skipped rather than
        /// counted as zero, which would drag a run down for the judge being off.
        static func average(of scores: [Double?]) -> QualityBadge? {
            let scored = scores.compactMap { $0 }
            guard !scored.isEmpty else { return nil }
            return QualityBadge(score: scored.reduce(0, +) / Double(scored.count))
        }
    }

    /// The built-in values for the tunable run settings. The property
    /// initializers below and `resetConfigToDefaults()` both read them, so
    /// "default" means one thing everywhere (the docs and the control API
    /// included). Settings whose default is "unset" — the cost caps and the
    /// auto-merge verify command — are simply nil and aren't listed here.
    enum Defaults {
        /// Three worker/reviewer rounds per item. Enough for a reviewer to send
        /// work back twice and still see it land; more than that and the pair is
        /// usually arguing rather than converging, which is a person's problem.
        static let maxRetries = 3
        /// No ceiling of this project's own — the portfolio's is what governs it
        /// until someone gives the project a number. Listed rather than left
        /// implicit because it is the one nil whose *absence* means "governed
        /// elsewhere" rather than "unbounded".
        static let dailyBudgetUSD: Double? = nil
        /// The branch runs fork from and land on. Nil is the checkout's own
        /// `HEAD` — what every project ran on before the setting existed. Listed
        /// for the same reason `dailyBudgetUSD` is: this nil means "wherever the
        /// checkout is", not "nowhere", and a reset has to be able to say so.
        static let baseBranch: String? = nil
        /// 15 minutes — long enough for an ordinary build+test merge-verify,
        /// short enough that a hung one still ends the run in reasonable time.
        /// A project whose merge-verify is its whole CI raises this rather than
        /// living with a refusal that says nothing about the diff.
        static let autoMergeVerifyTimeoutMinutes = 15
        static let openPullRequest = false
        /// `propose`, and per project. This is ADR-0001's human gate, so the
        /// default is the gate: a project only stops asking because someone
        /// said so.
        static let approvalGate = ApprovalGate.propose
        /// Off, and per project: having a worker and reviewer configured is
        /// being *able* to run — it is not consent to be run unattended. The
        /// scheduler and the grooming loop only touch projects that opted in.
        static let autonomousWorkEnabled = false
    }

    /// The boundaries a run crosses, one structured log line each. The in-memory
    /// `log` buffer holds only the last `logCapacity` lines and dies with the
    /// app; these go to the unified log, which is what's left to reconstruct an
    /// unattended marathon from afterwards:
    ///
    ///     log stream --predicate 'subsystem == "ai.kasatkin.kiteloop"
    ///                             AND category == "backlog-autopilot"'
    ///
    /// The raw values are the log's contract — anything grepping or parsing the
    /// stream keys off them, so rename with the same care as a public API.
    enum RunPhase: String, CaseIterable {
        case runStart = "run.start"
        case itemStart = "item.start"
        /// An item the retry ceiling had retired was picked up anyway, because a
        /// release discounted the attempts that retired it.
        case itemRelease = "item.release"
        case worker = "worker.start"
        /// The worker was told, once, that it had changed no files — before it
        /// handed off, while it could still act (`EmptyDiffHandoff`).
        case workerEmptyDiff = "worker.empty-diff"
        /// An operator handed the worker a note mid-run (`RunSteerNote`). Its own
        /// phase because a run someone steered and a run that ran unattended are
        /// different runs, and a merged diff can't be attributed without knowing
        /// which it was.
        case workerSteer = "worker.steer"
        /// The app is running the item's own `verify:` on the run's tree —
        /// the pre-review gate's measurement, and the salvage re-check, which
        /// are one command run one way (`measureVerify`). Its own phase
        /// because it is the one stretch of a run where nothing is talking to
        /// a model: a build that takes the whole of `verifyTimeout` used to
        /// leave the rail on `worker` with its clock ageing, so a run
        /// deliberately building read as a worker gone quiet.
        case verify = "verify.start"
        case reviewer = "reviewer.start"
        /// The reviewer answered without a machine-readable verdict and was asked
        /// once for one. Its own phase so an extraction failure is countable
        /// rather than inferred from a run that ended strangely.
        case reviewerClarify = "reviewer.clarify"
        /// The follow-up ask's own clock ran out before it restated a verdict
        /// — resolved rather than failed (`WorkflowNode.TimeoutFallback`), so
        /// this records that it happened without the item ever reaching
        /// `itemAbort`.
        case reviewerClarifyTimeout = "reviewer.clarify-timeout"
        /// The watchdog ended the item in flight (session cost cap, stall, or no
        /// work to review). Every line under this phase is an item that stopped
        /// here — counting them counts endings.
        case itemAbort = "item.abort"
        /// The item crossed its own cost cap and the run **continued** — the item
        /// cap is advisory by design, so this records an overrun, not an ending.
        /// Its own phase precisely so it isn't counted as one: a run that
        /// outgrew its estimate and then finished normally must not read as an
        /// aborted run to anything grepping the stream.
        case itemOverBudget = "item.over-budget"
        /// The item's spend crossed `CostGovernor.Readout.warnThreshold` of its
        /// effective cap while still under it — the first sign a run is heading
        /// for `itemAbort`/`itemOverBudget`, early enough that a person watching
        /// could raise the cap or cancel cheaply. Once per item.
        case itemNearCap = "item.near-cap"
        case itemEnd = "item.end"
        /// A worker/reviewer session restarted because the item it just ran
        /// produced nothing (`noWorkBlockLimit`).
        case agentRestart = "agent.restart"
        case merge = "merge"
        /// The merge gate is queued behind another merge on the same project
        /// (`WorktreeManager.MergeGateLock`) and has not started verifying
        /// anything yet. Its own phase because a merge that is waiting and a
        /// merge that is running cost different things and mean different
        /// things to whoever is watching: without it, a queued gate read as a
        /// gate already verifying.
        case mergeWaiting = "merge.waiting"
        /// A finished run's branch was published as a pull request — or wasn't,
        /// and why (`openPullRequest`).
        case pullRequest = "pull-request"
        /// How following that pull request's checks ended — green, given up on,
        /// timed out (`PullRequestChecks`). One line per terminal state, so a
        /// night's runs can be counted by how many reached the gate green.
        case pullRequestChecks = "pull-request.checks"
        /// One fix round: a failing check handed back to the worker.
        case pullRequestFix = "pull-request.fix"
        /// How the one pass over the pull request's unresolved review threads
        /// ended — the tally of what it fixed and what it answered, or why it
        /// didn't run (`PullRequestComments`).
        case pullRequestComments = "pull-request.comments"
        case runPause = "run.pause"
        /// A run the usage limit stopped, parked back to `ready` — its own
        /// phase, so the ledger never reads it as a failure.
        case itemParked = "item.parked"
        case runEnd = "run.end"
    }

    /// Formats one phase line as `phase=<name> key=value …`. Fields keep the
    /// order given; nil and empty ones are dropped rather than logged as blanks,
    /// and a value carrying a space, `=` or a quote is quoted and escaped — an
    /// item title is free text, and one apostrophe shouldn't cost the line its
    /// parseability.
    nonisolated static func phaseLine(_ phase: RunPhase, _ fields: [(String, String?)]) -> String {
        let rendered = fields.compactMap { key, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(key)=\(quotedFieldValue(value))"
        }
        return (["phase=\(phase.rawValue)"] + rendered).joined(separator: " ")
    }

    /// Why an item's status kept it out of the queue, in the one wording both the
    /// run log and an aborted start's reason use — so the line someone reads and
    /// the reason the control API hands back say the same thing.
    nonisolated static func wrongStatusSkipSummary(status: BacklogItemStatus,
                                                   pickupStages: [BacklogItemStatus]) -> String {
        "status \(status.displayName), autopilot only runs "
            + pickupStages.map(\.displayName).joined(separator: "/")
    }

    /// The `item.start` row a wrong-status skip writes. Its siblings —
    /// definition-of-ready, retry-ceiling, grounding-check — each name the check
    /// that refused in `source` and what it saw; this one names the status the
    /// item had and the stages that would have been picked up.
    nonisolated static func wrongStatusSkipFields(itemID: String,
                                                  status: BacklogItemStatus,
                                                  pickupStages: [BacklogItemStatus]) -> [(String, String?)] {
        [
            ("item", itemID),
            ("status", "skipped"),
            ("source", "pickup-stage"),
            ("stage", status.rawValue),
            ("pickupStages", pickupStages.map(\.rawValue).joined(separator: ",")),
        ]
    }

    /// The `verify.start` row the app writes before it runs the item's own
    /// `verify:` itself. The deadline is named beside the command because a
    /// line saying only that a build began cannot be read against the run that
    /// timed out under it — `deadlineSec` is what "it had this long" means.
    nonisolated static func verifyPhaseFields(itemID: String,
                                              command: String,
                                              timeout: TimeInterval) -> [(String, String?)] {
        [
            ("item", itemID),
            ("command", command),
            ("deadlineSec", String(Int(timeout))),
        ]
    }

    /// The reason a start records when the selection emptied out. Every bucket
    /// contributes both its count and the items it holds: "wrong status: 2" alone
    /// doesn't say which two, and this string is what the control API returns as
    /// its 422.
    nonisolated static func noRunnableItemsDetail(selected: Int,
                                                  wrongStatus: [(id: String, summary: String)],
                                                  notReady: [(id: String, summary: String)],
                                                  retired: [(id: String, summary: String)],
                                                  notGrounded: [(id: String, summary: String)]) -> String {
        let why = (wrongStatus + notReady + retired + notGrounded)
            .map { "\($0.id) (\($0.summary))" }
            .joined(separator: ", ")
        return "No runnable items selected (selected: \(selected), wrong status: \(wrongStatus.count),"
            + " not ready: \(notReady.count), retired: \(retired.count), not grounded: \(notGrounded.count))"
            + (why.isEmpty ? "" : " — \(why)")
    }

    private nonisolated static func quotedFieldValue(_ value: String) -> String {
        let needsQuoting = value.contains { $0 == " " || $0 == "=" || $0 == "\"" || $0.isNewline }
        guard needsQuoting else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// Seconds and dollars at fixed precision, so the same quantity always reads
    /// the same width in the stream.
    private nonisolated static func secondsField(_ interval: TimeInterval) -> String {
        String(format: "%.1f", interval)
    }
    private nonisolated static func usdField(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
    /// Which of the two daily ceilings a refusal came from, as a stable tag a
    /// reader can grep for rather than a sentence they have to parse.
    private nonisolated static func budgetScopeField(_ scope: DailyBudget.Scope) -> String {
        switch scope {
        case .portfolio: return "portfolio"
        case .project: return "project"
        }
    }

    /// Emits one phase line. Explicitly `.public`: `Logger` redacts interpolated
    /// strings by default, and a stream of `<private>` tells no one anything —
    /// these fields are item ids and outcomes from the user's own backlog.
    /// `isError` for the phases that ended something badly, so the unified log's
    /// level filter alone surfaces the failures.
    private func logPhase(_ phase: RunPhase, _ fields: [(String, String?)], isError: Bool = false) {
        let line = Self.phaseLine(phase, fields)
        if isError {
            autopilotLog.error("\(line, privacy: .public)")
        } else {
            autopilotLog.info("\(line, privacy: .public)")
        }
        noteRunPhase(phase, fields: fields)
    }

    /// The one place every `RunPhase` event reaches the phase rail's live
    /// fields, so nothing else has to be taught to keep `currentRunPhase` in
    /// step with the run log. A phase the rail draws no step for
    /// (`PortfolioSnapshot.RunState.PhaseRail.step(for:)` returning nil)
    /// leaves the last known step alone — a cost warning fired mid-review
    /// must not blank out "review".
    private func noteRunPhase(_ phase: RunPhase, fields: [(String, String?)],
                              now: Date = Date()) {
        lastActivityAt = now
        // A new item's own boundary — the one moment the item before it
        // could otherwise leak a stale step into this one's first tick.
        if phase == .itemStart {
            currentRunPhase = nil
            currentRunAttempt = 1
            phaseStepSeconds = [:]
            openPhaseStep = nil
            return
        }
        guard let step = PortfolioSnapshot.RunState.PhaseRail.step(for: phase) else { return }
        markPhaseStep(step, at: now)
        currentRunPhase = phase
        if let raw = fields.first(where: { $0.0 == "attempt" })?.1, let attempt = Int(raw) {
            currentRunAttempt = attempt
        }
    }

    /// The longest single stretch the item in flight has spent in each
    /// phase-rail step. Written by `markPhaseStep` off the same phase lines the
    /// rail draws, so the durations the ledger records and the steps a person
    /// watches are the same measurement. Cleared at `item.start`.
    private var phaseStepSeconds: [PortfolioSnapshot.RunState.PhaseRail.Step: TimeInterval] = [:]
    /// The step the run is in right now and when it entered it — the stretch
    /// `phaseStepSeconds` gains when the run leaves it.
    private var openPhaseStep: (step: PortfolioSnapshot.RunState.PhaseRail.Step, since: Date)?

    /// Writes down how long the run has now been in the step it is in, and
    /// starts the clock afresh when `step` is one it has just entered.
    ///
    /// The longest stretch per step, never the sum: what these durations feed
    /// is a *node's* deadline (`RunTimeouts`), and a run that took three worker
    /// rounds spent each of them under its own clock — their total is a
    /// duration nothing ever waited out.
    ///
    /// A second line about the step the run is already in — the worker being
    /// told its diff was empty, the merge gate saying what it decided —
    /// records the stretch so far without restarting it, so a phase is
    /// measured from the moment it began however many times it speaks.
    private func markPhaseStep(_ step: PortfolioSnapshot.RunState.PhaseRail.Step, at now: Date) {
        if let open = openPhaseStep {
            let elapsed = now.timeIntervalSince(open.since)
            phaseStepSeconds[open.step] = max(phaseStepSeconds[open.step] ?? 0, elapsed)
            if open.step == step { return }
        }
        openPhaseStep = (step, now)
    }

    /// How many log lines are kept. The log is a rolling buffer covering the whole
    /// project, not one log per run, so anything reading it back — the Autopilot
    /// tab, `GET /v1/runs/{id}/log` — has to know where "everything we still have"
    /// ends in order to say when a run's earlier lines were dropped.
    static let logCapacity = 50

    private(set) var status: Status = .idle
    /// True exactly while the run loop is executing — set where a run begins and
    /// cleared by a `defer` when it returns, so no exit path can leave it set.
    /// `status` is set by the same paths but says which *phase* a run is in, and
    /// a phase that outlives its run is the bug this exists to make impossible.
    private(set) var isExecutingRun = false
    /// When the item in flight became the current one — what `InFlightRun`
    /// reports as its `startedAt`. Stamped at pickup and cleared with the queue,
    /// so it never outlives the run it describes.
    private(set) var currentItemStartedAt: Date?
    private(set) var log: [LogEntry] = []
    /// What became of the most recent `start()`, or nil if none has been asked
    /// for yet. Recorded at the moment a gate decides — before the run loop is
    /// awaited — so it is readable while the run it accepted is still going, and
    /// so a caller is never left reading the log for a cause.
    private(set) var lastStartOutcome: StartOutcome?
    /// How many times `start()` has reached a decision. Only ever incremented,
    /// and only by `recordStartOutcome`.
    private var startAttempts = 0
    /// The execution the item in flight is running under, and nothing else.
    /// Cleared by `releaseExecutionSlot()` as each item ends, whatever ended it:
    /// an id that outlives its item reads as a run in flight forever, which is
    /// how a project came to hold its own run slot until the app was restarted.
    private(set) var currentExecutionID: String?
    private(set) var runQueue: [BacklogItem] = []
    private(set) var results: [ItemResult] = []
    /// Items that ran past their per-item cost cap this session. The cap is
    /// advisory: exceeding it is recorded here and the run continues, so this is
    /// the measure of which items outgrow their estimate. The session cap is the
    /// hard stop.
    private(set) var costOverrunItemIDs: Set<String> = []
    /// Which version of each queued item's spec this run was started against —
    /// `RetryCeiling.specFingerprint`, taken at pickup and written to the item's
    /// metric record when it finishes.
    ///
    /// Taken at pickup rather than at record time so it names the wording the
    /// worker was actually handed: a human who rewrites the item while the run is
    /// in flight has rewritten it *after* this attempt, and the next pickup
    /// should see that.
    private var pickupSpecFingerprints: [String: String] = [:]
    private(set) var completedExecutionIDs: [String] = []
    private(set) var runHistory: [RunRecord] = []
    private(set) var currentItemSpans: [ExecutionSpan] = []
    /// The current item's phase, as the phase rail draws it — set from every
    /// `RunPhase` this run logs (`noteRunPhase`), so `PortfolioSnapshot`'s
    /// fleet cell and this project's own Autopilot tab read the same value.
    /// Nil before the item's first phase has landed.
    private(set) var currentRunPhase: RunPhase?
    /// The worker/reviewer round the current phase belongs to — the same
    /// `attempt` figure every worker/reviewer phase line already carries.
    private(set) var currentRunAttempt = 1
    /// When the run last did anything recordable: a phase transition, or —
    /// while `awaitWorkflowCompletion` is polling — the same tick its stall
    /// watchdog resets its own clock on. The phase rail's "40s ago" reads this
    /// against `stallTimeoutMinutes`, the watchdog's own timeout.
    private(set) var lastActivityAt = Date()
    var selectedItemIDs: Set<String> = []
    var workerAgentID: String? { didSet { if !isLoadingConfig { saveConfig() } } }
    var reviewerAgentID: String? { didSet { if !isLoadingConfig { saveConfig() } } }
    /// How many worker/reviewer rounds one item gets in a single run — the
    /// graph's `maxIterations`, so a reviewer that keeps sending the work back
    /// past this many passes fails the execution rather than looping forever.
    /// Always within `maxRetriesRange`: zero rounds is a run that cannot reach
    /// its own reviewer.
    ///
    /// Not `RetryCeiling`, which is the across-runs ceiling on items that keep
    /// producing nothing. This one is spent inside a single run.
    var maxRetries: Int = Defaults.maxRetries {
        didSet {
            let clamped = Self.clampMaxRetries(maxRetries)
            // Re-entering `didSet` once is fine: `clamped` is already in range,
            // so the second pass falls through to the save.
            if clamped != maxRetries { maxRetries = clamped; return }
            if !isLoadingConfig { saveConfig() }
        }
    }
    /// The two run deadlines, derived from this project's own landed runs
    /// rather than set by hand (`RunTimeouts`) — re-read whenever the ledger
    /// gains a run, and `RunTimeouts.Deadlines.defaults` for a project that has
    /// not landed enough of them to be measured yet.
    ///
    /// Cached rather than computed per read: the phase rail asks for the stall
    /// clock on every tick, and the ledger is one file for every project this
    /// app has ever run.
    private(set) var runTimeouts: RunTimeouts.Deadlines = .defaults {
        didSet { costGovernor.itemCostBound = runTimeouts.itemCost }
    }

    /// A worker/reviewer node making no progress for this long is treated as
    /// stalled and ended (item → blocked), so an unattended run can't be killed
    /// by a single hang (e.g. an agent waiting on a permission prompt).
    ///
    /// No longer a setting: it is this project's p95 worker phase plus half
    /// again, floored and capped by `RunTimeouts`. It was a number set once per
    /// project from a guess, and a guess fails in both directions — a literal
    /// 600 seconds killed nine worker rounds whose trees were green.
    var stallTimeoutMinutes: Int { runTimeouts.workerMinutes }

    /// How long the merge gate's verify may run — the item's own `verify:` and
    /// the project's `autoMergeVerifyCommand` share this one clock — before a
    /// step still running is killed and the merge refused.
    ///
    /// Derived, like `stallTimeoutMinutes`, and from the phases it bounds: this
    /// project's p95 verify phase — the merge gate's and the pre-review one,
    /// the larger per run — plus half again, floored by `RunTimeouts` and
    /// deliberately uncapped, since a project whose merge-verify is its whole
    /// CI legitimately takes as long as its CI does.
    var autoMergeVerifyTimeoutMinutes: Int { runTimeouts.gateMinutes }

    /// How many turns the worker may take on one item — its node's `maxTurns`
    /// and its session's `--max-turns`. Derived, like the two clocks: this
    /// project's p95 worker turn count plus half again, floored at 50 and capped
    /// by `RunTimeouts`, or 50 until five of its runs carry a turn count.
    var workerMaxTurns: Int { runTimeouts.workerTurns.turns }

    /// That deadline in seconds — the one clock every verify the app runs
    /// itself is held to, so none of them can be given a different one.
    ///
    /// The pre-review verify runs the item's own `verify:`, the same command
    /// the merge gate runs at the end, and it used to fall through to the
    /// shell helper's fixed 900-second default. A project whose verify is its
    /// whole CI, and takes longer than fifteen minutes in a cold per-tree
    /// build directory, would then see every run end as "verify timed out
    /// before it answered" at the pre-review gate while the identical command
    /// passed at the merge gate — the same tree judged two ways by two clocks.
    var verifyTimeout: TimeInterval { TimeInterval(autoMergeVerifyTimeoutMinutes * 60) }

    /// The base tips already judged under the merge-verify, by sha — see
    /// `noteBaseHealth`. In memory only: a relaunch asks again, which is
    /// the cheaper mistake.
    private var baseHealthByTip: [String: WorktreeManager.BaseVerdict] = [:]
    /// The check in flight for a tip, so a second `start()` during a slow
    /// merge-verify waits on it instead of starting another.
    private var baseHealthChecks: [String: Task<WorktreeManager.BaseVerdict?, Never>] = [:]

    /// Re-reads the two deadlines off the ledger. Called where the ledger is
    /// wired up and again each time this project lands a run in it, so a
    /// project that has just crossed `RunTimeouts.minimumLandedRuns` starts
    /// running on its own measurements with the next item rather than the next
    /// launch.
    private func refreshRunTimeouts() {
        runTimeouts = RunTimeouts.deadlines(
            landed: Self.landedPhaseSamples(records: metricStore?.records ?? [],
                                            projectPath: projectPath))
    }

    /// This project's runs, as `RunTimeouts` reads them. A record is a sample
    /// if it carries any phase duration, and each deadline counts only the
    /// phases it bounds — a run that ended at the approval gate measured no
    /// merge phase and is still a worker sample. A record carrying none, which
    /// is every record written before those fields existed, is skipped rather
    /// than counted as zero.
    ///
    /// The gate's sample is `RunTimeouts.gateSeconds(merge:verify:)` over the
    /// run's two verify readings — the merge gate's and the pre-review one, the
    /// same command on the same class of tree under the same clock — so a
    /// project whose runs stop at the approval gate measures its gate deadline
    /// off the verify it does run.
    nonisolated static func landedPhaseSamples(records: [TaskMetricRecord],
                                               projectPath: String?) -> [RunTimeouts.Sample] {
        guard let projectPath else { return [] }
        return records.compactMap { record in
            guard KiteloopProject.isSamePath(record.projectPath, projectPath) else { return nil }
            let gate = RunTimeouts.gateSeconds(merge: record.gatePhaseSeconds,
                                               verify: record.verifyPhaseSeconds)
            guard record.workerPhaseSeconds != nil || gate != nil else { return nil }
            return RunTimeouts.Sample(workerSeconds: record.workerPhaseSeconds, gateSeconds: gate,
                                      workerTurns: record.workerTurns, costUSD: record.costUSD)
        }
    }

    /// The values `maxRetries` may take — what the Autopilot control offers, and
    /// what a hand-edited config or control-API value is clamped to. One round is
    /// the worker having a single go with no rework, which is a legitimate way to
    /// run a queue; ten is well past the point where a pair that hasn't converged
    /// is going to.
    nonisolated static let maxRetriesRange = 1...10

    nonisolated static func clampMaxRetries(_ rounds: Int) -> Int {
        min(max(rounds, maxRetriesRange.lowerBound), maxRetriesRange.upperBound)
    }

    /// Whether the run moved between two polls — the only thing that resets the
    /// stall watchdog's clock.
    ///
    /// `node` is the node the execution *is on*, read fresh on every poll, not
    /// the last one the run announced. Those two used to be the same variable,
    /// and the announced one is only written once a node has actually started —
    /// so a run parked on `reviewer` with the pre-review evidence gate unanswered
    /// compared a node that never advanced against a node it never reached and
    /// reported progress on every poll, leaving the watchdog permanently
    /// disarmed on exactly the hang it exists to end.
    nonisolated static func madeProgress(
        node: String,
        previousNode: String,
        stepCount: Int,
        previousStepCount: Int,
        agentWorking: Bool
    ) -> Bool {
        node != previousNode || stepCount != previousStepCount || agentWorking
    }

    private var lastStallReason: String?

    /// Set for the length of a gate-refresh round's `awaitWorkflowCompletion`
    /// call — a refresh round is a different execution from the item's own
    /// run, so the board write below (`itemStatus(forNode:)`) must not treat
    /// its worker node as a reason to move an item onto the board. Guarded the
    /// same way `lastStallReason` is: saved before, restored after, so a
    /// refresh started while an item's own run is already mid-flight cannot
    /// clobber this run's read of it.
    private var isRunningGateRefresh = false

    /// Where the pre-review evidence gate stands for the item in flight.
    ///
    /// The reviewer node is entered the instant the worker's turn ends, but the
    /// gate decides whether it is activated at all — so the execution can say
    /// `reviewer` while no reviewer is running, or ever will. The run loop polls
    /// that same execution, and this is what keeps it from announcing a reviewer
    /// that never started.
    private enum ReviewGate: Equatable {
        /// The reviewer has not been let through: either the run hasn't reached
        /// it, or the gate is still reading git.
        case pending
        /// Git says there is work to review; the reviewer is running.
        case open
        /// Git says the run produced nothing, and the run ended here rather than
        /// spending a review pass on an empty diff. Carries the signal it ended
        /// on, in the words the run log and the item's outcome both use.
        case closed(signal: String)
    }
    private var reviewGate: ReviewGate = .pending
    /// What the item's own `verify:` answered on this run's tree, measured by
    /// `measureVerify` — at the pre-review gate, or at the salvage re-check
    /// that decides a cut-short run on its own. Nil until one of them has run,
    /// and for an item that declares none.
    ///
    /// The last measurement, not the first: a rejected round sends the work
    /// back to the worker and the gate measures the changed tree again, so what
    /// the record keeps is the verdict on the tree the run actually ended with.
    private var lastVerifyVerdict: RunVerifyVerdict?
    /// The turns the worker's session reported on its last hand-off, and — when
    /// a turn cap is what ended it — the budget it used. Read by
    /// `readWorkerTurns` at the pre-review gate and when the execution ends,
    /// filed on the metric record, and cleared with the gate for each item.
    private var lastWorkerTurns: Int?
    private var workerCutShortTurns: Int?
    /// The paths this run's diff touches, as of the last time the reviewer was
    /// let through (`openReviewGate`) — what a rejecting round's findings are
    /// checked against for drift (`ReviewFindings.markDrift`). Nil until then,
    /// which is read as "unknown" rather than "nothing changed": a review
    /// cannot have drifted before there was a diff to compare it to.
    ///
    /// `refineNodeOutput` reads this as `Optional<Set<String>>` rather than
    /// `Set<String>?`: lizard's Swift reader mis-scopes the `reviewerOutputSchema`
    /// dict literal below as a "function" spanning down into `refineNodeOutput`,
    /// and reads a bare `?` there as a ternary, one point of cyclomatic
    /// complexity `check-complexity.sh` then fails the baseline on — the
    /// spelling is a workaround for that false reading, not a real branch.
    private var lastReviewedChangedFiles: Set<String>?
    /// The approval-gate summons for the item in flight, held while its pull
    /// request's checks are followed (see `accept` and `flushGateNotification`).
    /// Nil the rest of the time — every item that sets it also flushes it.
    private var pendingGateNotification: GateNotification?
    /// Whether each item runs in an isolated git worktree/branch
    /// `kiteloop/<item-id>` (ADR-0001), where changes never touch the live tree.
    ///
    /// A fact about the checkout, not a setting: a root that is a git
    /// repository always isolates, and one that is not runs in the live tree,
    /// which is the only place it has (`WorktreeSession.decide` logs why). A
    /// `useWorktree` key in a config file written before this stopped being a
    /// setting is ignored.
    ///
    /// Read from the filesystem rather than by asking git: this is answered
    /// synchronously, on the main actor, and `.git` at the root is exactly the
    /// question — present for a clone and for a worktree alike.
    var useWorktree: Bool {
        guard let projectRoot else { return false }
        return FileManager.default.fileExists(
            atPath: projectRoot.appendingPathComponent(".git").path)
    }
    /// Readable so the Autopilot panel's approval gate can merge against the
    /// same repository the run used; only this class sets it.
    private(set) var projectRoot: URL?
    private var runtimeFactory: (() -> any AgentRuntime)?
    private var globalConfigStore: GlobalConfigStore?
    private var reporter: StoreProblemReporter = .shared
    /// The name this store reports under. A human reads it in a notification
    /// title, and it is half the dedup key, so it is spelled once.
    static let storeName = "Autopilot config"
    /// The run history's own name in the same dedup key — distinct from
    /// `storeName` so a history failure and a config failure never collapse
    /// into one report.
    static let historyStoreName = "Autopilot run history"
    /// What every project together has spent today. Portfolio-wide and shared by
    /// all the autopilots in the app; nil in tests and previews, which simply
    /// have no daily ceiling.
    private var dailySpendLedger: DailySpendLedger?
    /// Every cost decision this autopilot makes — the caps, the prediction chain,
    /// the session's spend. Held as a value so mutating it publishes to the panel
    /// like any other observed property.
    private(set) var costGovernor = CostGovernor()

    /// The portfolio-wide daily ceiling (USD); nil = none. **Not a per-project
    /// setting**: it lives in `~/.kiteloop/global-config.json`, every project
    /// shares one number and one day's spend, and it is deliberately untouched by
    /// `resetConfigToDefaults()`, which resets this project's knobs. Set it
    /// through the Coordinator panel or `PUT /v1/coordinator/scheduling`.
    var portfolioDailyBudgetUSD: Double? {
        get { globalConfigStore?.config.dailyBudgetUSD }
        set { globalConfigStore?.setDailyBudgetUSD(newValue) }
    }

    /// **This project's own** daily ceiling (USD); nil = no ceiling of its own,
    /// in which case the portfolio's is all that governs it. A project setting
    /// like the cost caps: persisted to `.kiteloop/autopilot-config.json` and
    /// cleared by a reset.
    ///
    /// It exists because one number for the whole portfolio means a busy project
    /// spends the ceiling every other project was relying on. It is a floor on
    /// nothing, though: a project's own budget never licenses it past the
    /// portfolio's — see `ProjectDailyBudget`.
    var dailyBudgetUSD: Double? = Defaults.dailyBudgetUSD {
        didSet {
            // The one budget also governs the session hard-stop — see
            // `budgetUSD`.
            costGovernor.sessionCapUSD = dailyBudgetUSD
            if !isLoadingConfig { saveConfig() }
        }
    }

    /// The project's one budget — the settings page and the control API's name
    /// for `dailyBudgetUSD`, now that it is the only cap a person sets: nil
    /// means the fleet's own ceiling (`PUT /v1/coordinator/scheduling`) is all
    /// that governs this project. Setting it also sets the session's hard
    /// stop (`dailyBudgetUSD`'s `didSet`), so one number bounds both a day and
    /// a sitting; the per-item ceiling is no longer a setting at all — see
    /// `CostGovernor.effectiveItemCap(for:)`, read off this project's runs.
    var budgetUSD: Double? {
        get { dailyBudgetUSD }
        set { dailyBudgetUSD = newValue }
    }

    /// Today's portfolio-wide budget as it stands: the ceiling joined with what
    /// every project has spent since local midnight. Uncapped and unspent when no
    /// ledger is attached — no ledger is no ceiling, not an unreadable one.
    var dailyBudget: DailyBudget {
        DailyBudget(budgetUSD: portfolioDailyBudgetUSD, spentUSD: dailySpendLedger?.spentTodayUSD ?? 0,
                    spendUnknown: dailySpendLedger?.loadProblem != nil)
    }

    /// This project's own ceiling joined with its own share of today's spend.
    /// Unspent without a ledger or a project path — an autopilot that can't be
    /// told apart from another one must not be charged for its neighbour.
    ///
    /// A ledger that could not read today carries that here too: the per-project
    /// totals live in the same file as the portfolio one, so a file the decoder
    /// refused took both down together.
    var projectDailyBudget: DailyBudget {
        let spent = projectPath.map { dailySpendLedger?.spentTodayUSD(inProject: $0) ?? 0 } ?? 0
        return DailyBudget(budgetUSD: dailyBudgetUSD, spentUSD: spent,
                           scope: .project(projectName ?? "this project"),
                           spendUnknown: dailySpendLedger?.loadProblem != nil)
    }

    /// Both ceilings this project's autonomous runs answer to. The gate `start`
    /// asks, and the same pair the run scheduler asks one step earlier.
    var dailyBudgetGate: ProjectDailyBudget {
        ProjectDailyBudget(project: projectDailyBudget, portfolio: dailyBudget)
    }

    /// The cost-settings vocabulary, kept at the names the Autopilot tab and the
    /// control API already call. See `CostGovernor` for what they do.
    nonisolated static func parseCostCapUSD(_ text: String) -> Double? {
        CostGovernor.parseCapUSD(text)
    }
    nonisolated static func formatCostCapUSD(_ value: Double?) -> String {
        CostGovernor.formatCapUSD(value)
    }
    /// Whether an approved item is merged into the project's main branch
    /// **unattended** — but only if the merge is clean and the verify map's
    /// rules the diff reaches pass on the merged tree (main never breaks).
    /// A failed merge/verify leaves the item at Awaiting Approval for a human.
    /// Requires worktree isolation (there must be a branch to merge). Read off
    /// `approvalGate`: only `land` merges.
    var autoMergeOnApproval: Bool { approvalGate == .land }
    /// No longer a setting: the merge-verify command an earlier release stored
    /// in `autopilot-config.json`, read back and written through unchanged so
    /// a save does not drop it. A verify-map rule matching every path says
    /// the same thing in the one place a project now says it; until the map
    /// has one, this release still runs the stored command as that rule and
    /// logs the rule to add (`storedMergeVerify(beside:)`).
    var autoMergeVerifyCommand: String? { didSet { if !isLoadingConfig { saveConfig() } } }
    /// The command run in every worktree Kiteloop creates for this project —
    /// the worker's, the merge gate's scratch tree, the rebase scratch tree —
    /// right after it is checked out and before anything else runs there:
    /// `npm ci`, `xcodegen generate`, whatever a cold tree needs before its
    /// own `verify:` can even start. Empty (the default) is today's
    /// behaviour: nothing extra runs. Not a verify step — it never appears
    /// in `MergeVerifyPlan.summary` or `verifyRan` — so a setup failure is
    /// its own refusal, distinct from the item's verify or the merge-verify
    /// command failing.
    var worktreeSetupCommand: String? { didSet { if !isLoadingConfig { saveConfig() } } }

    /// The merge-verify the gate runs: a command stored by an earlier release
    /// while the map has no rule matching every path, else what the verify
    /// map's widest rule implies (`RepoConventions`). `source` says which,
    /// for `GET /v1/autopilot`.
    var effectiveMergeVerify: RepoConventions.Derived {
        let map = projectRoot.map { VerifyMapFile.load(for: KiteloopProject(rootURL: $0)) }
        if let stored = storedMergeVerify(beside: map) {
            return RepoConventions.Derived(command: stored, source: RepoConventions.Derived.configured)
        }
        guard let projectRoot, let map else { return RepoConventions.Derived(command: nil, source: "no project") }
        return RepoConventions.mergeVerifyCommand(projectRoot: projectRoot, map: map)
    }

    /// The setup a fresh worktree gets: the configured command when a person
    /// set one, else what the tree's lockfiles and generators imply.
    var effectiveWorktreeSetup: RepoConventions.Derived {
        if let configured = worktreeSetupCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return RepoConventions.Derived(command: configured, source: RepoConventions.Derived.configured)
        }
        guard let projectRoot else { return RepoConventions.Derived(command: nil, source: "no project") }
        return RepoConventions.setupCommand(projectRoot: projectRoot)
    }
    /// The branch this project's runs fork from and merge into — `main`,
    /// `quality/rebased`, whatever the work is meant to land on. Nil means the
    /// checkout's own `HEAD`, which is exactly how every run behaved before the
    /// setting existed. With a name here an item's worktree forks from the
    /// local `refs/heads/<name>` (no fetch), its diff is read against that
    /// ref, and a verified merge lands on that ref — by fast-forward when the
    /// checkout is on it, by a compare-and-swap `update-ref` when it is not —
    /// without the app ever switching the checkout (`WorktreeManager
    /// .mergeAndVerify`). A pull request opens against it too.
    ///
    /// Before this, "run on a branch" meant switching the checkout by hand or
    /// registering the same directory a second time under another branch —
    /// which on 2026-09-03 left the base checked out in a stale scratch
    /// worktree the merge then moved the ref under. Trimmed on the way in; an
    /// empty name is nil, so the field, the control API and the Reset control
    /// all agree on what "unset" looks like.
    var baseBranch: String? = Defaults.baseBranch {
        didSet {
            let normalized = Self.normalizeBaseBranch(baseBranch)
            if normalized != baseBranch { baseBranch = normalized; return }
            if !isLoadingConfig { saveConfig() }
        }
    }

    /// Whitespace trimmed, blank read as unset — the one reading the text
    /// field, the config file and `PUT /v1/autopilot` all go through.
    nonisolated static func normalizeBaseBranch(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
    /// When on, a run that reaches the approval gate with a branch has that
    /// branch **pushed** and a pull request opened for it (ADR-0001's PR half),
    /// so the diff can be reviewed where code review already happens. Never
    /// merges and never changes the gate: `autoMergeOnApproval` alone still
    /// decides whether the branch lands. A project with no remote, no `gh`, or a
    /// `gh` nobody has logged in to skips the PR and says so in the item's
    /// Notes — the run itself still succeeds. Off by default.
    var openPullRequest: Bool = Defaults.openPullRequest { didSet { if !isLoadingConfig { saveConfig() } } }
    /// What happens to a run the reviewer passed — one value, so the two
    /// halves of the decision (approve without a person; merge on approval)
    /// cannot be set apart. `propose` parks it at the approval gate for a
    /// person, and their approval does not merge; `land` approves it and
    /// merges it. Independent of `autonomousWorkEnabled`, which decides who
    /// starts runs: `land` with unattended runs off is "runs I start land
    /// themselves".
    enum ApprovalGate: String, Codable, CaseIterable, Sendable {
        case propose
        case land

        /// A config or request written before the gate was one value carried
        /// two switches. Only both on spelled `land`; every half-set pair
        /// reads as `propose`, the side that asks a person.
        nonisolated static func fromLegacy(approveReviewPassedRuns: Bool, autoMergeOnApproval: Bool) -> ApprovalGate {
            approveReviewPassedRuns && autoMergeOnApproval ? .land : .propose
        }
    }
    var approvalGate: ApprovalGate = Defaults.approvalGate {
        didSet { if !isLoadingConfig { saveConfig() } }
    }
    /// Whether an item the **reviewer passed** clears its approval gate without
    /// a person: the run approves it itself and it goes to Done, feeding the
    /// same `autoMergeOnApproval` path an approval has always fed. Read off
    /// `approvalGate`: only `land` approves.
    ///
    /// It exists because an unattended night driven from the app stalled at that
    /// gate — the scheduler started the runs, the reviewer passed them, and each
    /// one waited for someone asleep. The only thing that cleared the gate
    /// unattended was the external harness's `--auto-approve`, i.e. the same
    /// widening, available only to an operator driving from outside the app.
    ///
    /// Deliberately narrow. Nothing else changes: a rejected or blocked run
    /// routes exactly as it did, a run salvaged by its own `verify:` is not a
    /// reviewer pass and is not approved, and a merge that was attempted and
    /// refused leaves the item at the gate rather than stamping Done over work
    /// that never landed. See `gateResolution`, which is the whole rule.
    var approveReviewPassedRuns: Bool { approvalGate == .land }
    /// This project's consent to unattended work. Read by the portfolio
    /// snapshot, which is how the scheduler and the grooming loop see it; a
    /// human start never consults it.
    var autonomousWorkEnabled: Bool = Defaults.autonomousWorkEnabled {
        didSet { if !isLoadingConfig { saveConfig() } }
    }

    /// How far this project may go on its own — one dial over
    /// `autonomousWorkEnabled` and `approvalGate`.
    enum Autonomy: String, Codable, CaseIterable, Sendable {
        /// `autonomousWorkEnabled` off: the project is never picked up
        /// unattended.
        case off
        /// Runs start unattended, and every review-passed run parks at the
        /// human approval gate.
        case propose
        /// Runs start unattended, a review-passed run is approved without
        /// asking, and an approved item is merged.
        case land

        var displayName: String {
            switch self {
            case .off: return "Off"
            case .propose: return "Propose"
            case .land: return "Land"
            }
        }
    }

    /// Reads and writes `autonomousWorkEnabled` and `approvalGate` together.
    /// `off` leaves the gate at `propose`; a project with unattended runs off
    /// and the gate at `land` reads as `off` here, and its hand-started runs
    /// still land.
    var autonomy: Autonomy {
        get {
            guard autonomousWorkEnabled else { return .off }
            return approvalGate == .land ? .land : .propose
        }
        set {
            autonomousWorkEnabled = newValue != .off
            approvalGate = newValue == .land ? .land : .propose
        }
    }

    /// What the items this session has already finished cost. The item in flight
    /// is counted separately (`currentItemSpendUSD`) until it's charged here, so
    /// the panel's session figure is the two added — see `costReadout`.
    var sessionCostSoFar: Double { costGovernor.spentThisSession }
    /// What the item in flight has spent so far. Sampled by the run watchdog
    /// every ~16s (each sample reads the turn spans), 0 between items.
    var currentItemSpendUSD: Double { costGovernor.currentItemSpendUSD }
    /// The effective ceiling for the item in flight (`effectiveCostCap`), so the
    /// panel can show the number the run is actually measured against rather
    /// than the flat cap in settings. Nil between items, or when uncapped.
    var currentItemCostCapUSD: Double? { costGovernor.currentItemCapUSD }
    /// What this run leaves the end-of-run distiller. One entry per finished
    /// item, cleared at the start of every run — a run's learnings are about
    /// that run, and carrying the last one's items into it would distil a
    /// history nobody watched.
    private var runKnowledgeEvents: [RunKnowledgeDistiller.Event] = []
    /// Consecutive items that finished having produced nothing at all. One means
    /// the agent's session probably died (fd/resource exhaustion) and is restarted
    /// before the next item; a run of them means restarting isn't fixing it, and
    /// the breaker pauses instead of burning the rest of the queue.
    private var consecutiveNoWorkBlocks = 0
    /// How many no-work items in a row end the run. Small on purpose: two
    /// restarts is enough to tell "that session had died" from "restarting does
    /// not help", and every attempt past that costs the queue another item.
    nonisolated static let noWorkBlockLimit = 3
    /// The breaker's counter after one item: any item that produced work — or
    /// whose emptiness nobody could establish — puts it back to zero, so only an
    /// unbroken run of empty items reaches the limit.
    nonisolated static func noWorkStreak(previous: Int, signal: String?) -> Int {
        signal == nil ? 0 : previous + 1
    }
    /// Whether the run stops rather than restarting and carrying on.
    nonisolated static func shouldStopForNoWork(streak: Int) -> Bool {
        streak >= noWorkBlockLimit
    }
    /// A blocked item whose spend is ~$0 — the worker did no billable work, so its
    /// session was almost certainly dead.
    ///
    /// **Corroboration, not a trigger.** Cost read $0 on nine of thirty-one runs
    /// on 2026-08-08 for reasons that had nothing to do with the agent, so the
    /// autopilot's own dead-session detector asks git (`RunWorkEvidence`) and
    /// only logs the cost alongside. `CoordinatorBlockedTriage` still reads this
    /// over recorded history, where a git worktree is long gone.
    nonisolated static func isNoWorkBlock(blocked: Bool, costUSD: Double) -> Bool { blocked && costUSD < 0.05 }
    /// What the Autopilot panel shows about money while a run is live: what the
    /// item in flight has spent against its own effective ceiling, and what the
    /// session has spent against the session cap. Both spends trail the live turn
    /// by at most one watchdog sample (~16s).
    var costReadout: CostReadout { costGovernor.readout }

    /// What the Autopilot panel shows about whether that money is buying
    /// anything: the cost of a delivered item and the share of spend that
    /// produced nothing, for this run and for today. Read straight off the
    /// metric records the run loop has already written — see `RunEconomics`, and
    /// note that asking for it starts no agent and spends nothing.
    ///
    /// The backlog goes in with the ledger because whether spend bought anything
    /// is a question about the *item*, asked fresh every time this is read: a run
    /// that ended `awaiting-approval` and was approved a minute later stops being
    /// waste the moment its item reads `done`. With no backlog loaded there is no
    /// such answer, and the figures say so rather than calling the day's work
    /// wasted for want of a file.
    var economics: RunEconomics.Windows {
        // No project identity means no run of this project's is on record —
        // `recordMetric` writes nothing without one — and a nil path is
        // portfolio-wide to `RunEconomics`, which would fill this project's
        // panel with another project's spend.
        guard let projectPath else { return RunEconomics.Windows(run: .empty, today: .empty) }
        return RunEconomics.windows(records: metricStore?.records ?? [],
                                    projectPath: projectPath,
                                    itemStatus: backlogViewModel?.backlogFile?.statusByItemID ?? [:],
                                    runStartedAt: runStartedAt,
                                    now: Date())
    }

    var onExecutionStarted: ((String) -> Void)?
    /// Fired when a run parks on the account's usage limit, with when it
    /// lifts. The scheduler listens: the limit is the account's, so every
    /// project is held until then.
    var onUsageLimitParked: ((UsageLimitStop) -> Void)?
    private var configURL: URL?
    private var isLoadingConfig = false
    /// Set when `autopilot-config.json` exists but its bytes could not be read
    /// or decoded — names the file and which step failed. Nil once a load
    /// succeeds, and nil when there was no file to fail on: an absent config
    /// is not a failure. The Autopilot tab's read of "why is this project not
    /// ready" has nowhere else to look, since `loadConfig()` falling through
    /// leaves every setting at its default with nothing else to say why.
    private(set) var configLoadFailure: String?
    var onStarted: (() -> Void)?
    /// Reads the fleet-wide hold. Nil in every context that hasn't wired one
    /// up (tests, and this type's own default init) reads as not quiesced,
    /// so the gate is inert unless the app attaches it — which is where a
    /// real hold actually lives, in `FleetQuiesceControl`.
    var isFleetQuiesced: (() -> Bool)?
    /// Reads this project's own `KiteloopProject.isPaused` — the fleet board's
    /// pause, which `status` alone cannot see since it can be set while this
    /// autopilot is sitting idle. Nil (tests, this type's own default init)
    /// reads as not paused, the same default `isFleetQuiesced` uses; the app
    /// wires it to the project's own config.
    var isProjectPaused: (() -> Bool)?
    /// Fired once the run loop has finished the whole queue. The queue-refill
    /// loop listens here: this is the moment a project's `ready` count is most
    /// likely to have hit zero.
    var onRunFinished: (() -> Void)?

    private weak var orchestrator: Orchestrator?
    private weak var backlogViewModel: BacklogViewModel?
    private var metricStore: TaskMetricStore?
    /// Where the pickup checks write their verdicts, so a refusal outlives the
    /// 50-line in-memory log and can explain a rejection later
    /// (`PortfolioReport`). Settable for tests; the app shares one ledger.
    var groomingLedger: GroomingLedger = .shared
    /// Where `retryGateMerges` reads and writes its lifetime attempt count.
    /// Settable for tests, the same way `groomingLedger` is — a test must
    /// never write under `~/.kiteloop`, and the app shares one file.
    private var gateRetryLedgerURL: URL = GateRetry.Ledger.defaultURL()
    /// Where the rescue extension reads and writes which items have already
    /// spent their one rescue. Settable for tests, for the same reason as
    /// `gateRetryLedgerURL`.
    private var rescueLedgerURL: URL = RescueRun.Ledger.defaultURL()
    private var projectPath: String?
    private(set) var projectName: String?
    private var currentIndex = 0
    private var shouldStop = false
    /// Whether the halt in flight came from `stop()` rather than `pause()` — the run
    /// loop only learns "stop" through `shouldStop`, which pause sets too.
    private var stopRequested = false
    /// Whether a person is holding this project's queue — set by `pause()`, and
    /// lifted only by `resume()` (or by `stop()`, which ends the queue the hold
    /// was over).
    ///
    /// A fact of its own rather than a reading of `status`, because `status` is
    /// the *run's* and the hold is the *project's*. A pause lands at the next
    /// item boundary, so the item in flight keeps going — and the path that
    /// ends it wrote `idle` over the pause, which made the hold last exactly as
    /// long as the item it was meant to outlive: the next scheduler tick found
    /// an idle project and started another run nobody asked for. The completion
    /// path reads this instead of assuming idle.
    private(set) var queueHeld = false
    /// Whether this autopilot is holding its queue, whichever way it was taken:
    /// a person's pause (`queueHeld`, which outlives the run in flight) or a
    /// status left `paused` by the session cap or the circuit breaker. What the
    /// Run button's refusal, `GET /v1/projects`' `paused` and the control API's
    /// pause/resume all read, so no two of them can disagree.
    var isHoldingQueue: Bool { queueHeld || status == .paused }
    private var currentRunRecord: RunRecord?
    /// When the run in flight started — the boundary the panel's "this run"
    /// economics are measured from. Deliberately **not** cleared when the run
    /// ends: a finished run's cost per delivered item is exactly what tells you
    /// whether to start another, so the figures stay on screen the way the
    /// session spend does. In memory only, like `results`.
    private(set) var runStartedAt: Date?

    /// This project's own run history file, inside its `.kiteloop` directory —
    /// nil when configured without a project root, so history then lives only
    /// in memory and touches no file at all (never the legacy shared one).
    private var historyURL: URL? {
        guard let projectRoot else { return nil }
        let project = KiteloopProject(rootURL: projectRoot)
        try? FileManager.default.createDirectory(at: project.kiteloopDirURL, withIntermediateDirectories: true)
        return project.autopilotHistoryURL
    }

    /// The follow-up ask that stands between an unreadable review and `blocked`.
    /// Named once here because the run log, the span labels and the retry count
    /// all have to agree on which visits were reviews and which was this.
    nonisolated static let reviewerClarifyNodeID = "reviewer-clarify"

    /// The stage an item sits in while a run holds it at `nodeID` — nil for a
    /// node that should leave the item's status alone.
    ///
    /// `useReviewStage` is the project's own choice
    /// (`BacklogWorkflowConfig.useReviewStage`), and until this existed it drew a
    /// column nothing ever wrote to: an item stayed `active` through the
    /// reviewer's whole pass, so In Review stood empty on every board that had it
    /// turned on. Off, both nodes answer nil — the item keeps the `.active` it
    /// got at pickup, which is exactly what such a project sees today.
    ///
    /// The follow-up ask counts as review for the same reason the panel keeps
    /// reading `.reviewing` through it: it is the same attempt, still waiting on
    /// the same verdict. Every other node — `done`, `blocked` — answers nil,
    /// because what those write is the run's outcome, not where it has got to.
    nonisolated static func itemStatus(forNode nodeID: String,
                                       useReviewStage: Bool) -> BacklogItemStatus? {
        guard useReviewStage else { return nil }
        switch nodeID {
        case "worker": return .active
        case "reviewer", reviewerClarifyNodeID: return .inReview
        default: return nil
        }
    }

    /// Whether the node in hand is the worker's rather than the reviewer's —
    /// which agent is running, in other words. Everything that has to reach the
    /// agent behind the current node asks this: the stall watchdog (to read
    /// whether it is working), the cost cap (to stop it), and the run log (to
    /// name it).
    nonisolated static func isWorkerNode(_ nodeID: String) -> Bool {
        nodeID == "worker"
    }

    /// Whether entering this node has to pass the pre-review evidence gate —
    /// there is something to review (`allowReviewerToRun`).
    ///
    /// The one node that reads a diff, and neither of the two that don't: the
    /// follow-up ask is a question about a verdict that already exists, and the
    /// worker is what produces the diff in the first place.
    nonisolated static func isGatedReviewNode(_ nodeID: String) -> Bool {
        nodeID == "reviewer"
    }

    /// The verdict the graph routes on. Shared by the reviewer and the follow-up
    /// ask so the two can never drift into asking for different fields.
    ///
    /// `findings` is optional and stays optional: a reviewer that answers with a
    /// bare `passed` routes exactly as it always has. What the list buys is a
    /// severity — only a `blocking` finding rejects, and an `advisory` one
    /// survives an approval into the item's Notes instead of dying with the run
    /// (`ReviewFindings`).
    ///
    /// Each field is spelled `OutputSchema.SchemaField(…)` rather than `.init(…)`:
    /// lizard's Swift reader takes a leading `.init(` for a function declaration
    /// and measures a phantom `passed` function from here down past the end of
    /// `reviewerNodePrompt` below, so every sentence added to that prompt grew a
    /// baselined "function" and the complexity gate objected to prose. Naming the
    /// type builds the same value and is measured as nothing at all.
    nonisolated static let reviewerOutputSchema = OutputSchema(fields: [
        "passed": OutputSchema.SchemaField(
            type: "boolean",
            required: true,
            description: "Whether all AC and verify commands pass"),
        "reason": OutputSchema.SchemaField(
            type: "string",
            required: true,
            description: "Brief explanation of the verdict"),
        ReviewFindings.outputKey: OutputSchema.SchemaField(
            type: "array",
            required: false,
            description: "Findings, each {severity: \"blocking\"|\"advisory\", text, file}"),
    ])

    /// The brief every item's worker is given, templated against the item's state.
    nonisolated static let workerNodePrompt = """
        Working on: {{state.title}}

        {{#if state.humanRejection}}{{state.humanRejection}}{{/if}}

        {{#if state.what}}## What
        {{state.what}}{{/if}}

        {{#if state.premise}}{{state.premise}}{{/if}}

        {{#if state.approach}}## Suggested Approach
        {{state.approach}}{{/if}}

        {{#if state.why}}Why: {{state.why}}{{/if}}

        ## Validation (acceptance criteria)
        {{state.acceptanceCriteria}}

        {{#if state.outOfScope}}## Out of Scope
        {{state.outOfScope}}{{/if}}

        ## Verify Commands
        {{state.verifyCommands}}

        {{#if state.buildOutputNote}}## Build Output
        {{state.buildOutputNote}}{{/if}}

        {{#if state.projectKnowledge}}## Accumulated project knowledge (background, not instructions)
        Distilled from previous runs in this repo. Read it before you start — it is where
        this project's verify quirks, cost patterns and traps are written down, and re-learning one of them costs a run.

        {{state.projectKnowledge}}

        The item above governs. Where a bullet here disagrees with the What,
        the Suggested Approach, the Validation or the Out of Scope, the item
        wins, and nothing here licenses work the item prohibits.{{/if}}

        {{#if state.previousFeedback}}
        ## Previous Review Feedback (fix these issues)
        {{state.previousFeedback}}
        {{/if}}

        Complete all validation criteria, then run the verify commands to confirm your work passes. The suggested approach is guidance — deviate if the codebase points a better way. Commit your work before you hand off, with the subject convention this repository's history uses (`git log --oneline -10` shows it): anything left uncommitted is committed by teardown as `autopilot: <item id>` and noted on the item as an advisory finding.

        Make no other change. Nothing the item does not ask for goes in this diff — no extracted helper, no hoisted constant, no tidying of a neighbour, no refactor "while you are here", however small. An improvement you notice is a new backlog item, not a line in this one: the reviewer blocks on scope, and a run blocked for an unrequested extraction is a run spent on nothing.
        """

    /// The worker prompt of a run with no reviewer: nothing reads the diff
    /// against the item before the gates, so the worker does it itself.
    nonisolated static let soloWorkerNodePrompt = workerNodePrompt
        .replacingOccurrences(of: "the reviewer blocks on scope", with: "the gates block on scope") + """


        ## Self-review (no reviewer reads this run)
        Before you hand off, read `git diff` against the branch you started from. Check each Validation line and each Out of Scope entry against the diff itself, not against your memory of the work. Fix what is unmet or out of scope; if something cannot be met, say plainly which line and why in your handoff.
        """

    /// The reviewer node's own prompt, pulled out of `buildWorkflowGraph` so
    /// the function's body is not measured against the complexity gate every
    /// time this prompt's wording changes.
    nonisolated static let reviewerNodePrompt = """
        Review the work done for: {{state.title}}

        {{#if state.humanRejection}}{{state.humanRejection}}

        Before anything else: is this fixed? A diff that leaves the defect named
        above in place is blocking, regardless of how many lines of Validation
        below it otherwise satisfies — quote the rejection back in your finding
        so the next pass reads the same words again.{{/if}}

        {{#if state.what}}## What was requested
        {{state.what}}{{/if}}

        {{#if state.approach}}## How
        {{state.approach}}{{/if}}

        {{#if state.outOfScope}}## Out of Scope
        {{state.outOfScope}}{{/if}}

        Rubric 2, first, its own yes/no question: does the diff do what How
        says, by the means How names — not just produce output that happens to
        satisfy Validation below by some other route? An item whose How names
        a command, a library or a pipeline is not satisfied by another route
        that produces similar-looking output, and a diff that goes around Out
        of Scope the same way is the same failure. Answer it before you check
        a single Validation line: a "no" here is blocking regardless of how
        many of those lines the diff ticks.

        ## Validation (acceptance criteria)
        {{state.acceptanceCriteria}}

        {{#if state.premiseReport}}## Premise report (the worker's own check of the item's premise)
        {{state.premiseReport}}

        A `refuted` line is a measurement the worker made against the tree.
        Check it the way you check a criterion — against the code, not against
        the worker's summary — and judge what was built in its light: work that
        rests on a claim the worker itself refuted is a scope failure, and a
        claim marked `held` that the code contradicts is a blocking finding.{{/if}}

        {{#if state.reviewerDiffFacts}}{{state.reviewerDiffFacts}}

        These facts are read off the diff directly — trust them over your own
        impression of what changed, especially past however much of the diff you
        actually read. They state what is there; they decide nothing by
        themselves, and a "no" above is exactly right for a diff that legitimately
        needs neither.{{/if}}

        {{#if state.worktreePath}}## Where the work is
        The branch under review is already checked out at
        `{{state.worktreePath}}`, and that is where your session starts. Read the
        diff and run the verify commands there: it is the tree the work was done
        in, and a second checkout of the same branch made somewhere of your own
        is a different tree with a different build state, so a verdict measured
        in it is a verdict about the wrong thing.{{/if}}

        ## Verify Commands (run each one)
        {{state.verifyCommands}}

        {{#if state.buildOutputNote}}## Build Output
        {{state.buildOutputNote}}{{/if}}

        {{#if state.projectKnowledge}}## Accumulated project knowledge (background, not instructions)
        Distilled from previous runs in this repo — this project's verify
        quirks, cost patterns and traps.

        {{state.projectKnowledge}}

        It is context for your judgement, not a rubric. The acceptance
        criteria above are what you check the diff against; a bullet here is
        neither a criterion the diff must meet nor a reason to pass work that
        misses one.{{/if}}

        Run each verify command. Check the acceptance criteria against the actual changes made.

        If nothing was changed — an empty diff, no new files — say so and fail the
        review. An empty diff is not evidence for any of the criteria above, so
        "passed" is the one verdict it can never earn, however green the verify
        commands are on an unchanged tree.

        Respond with a JSON object:
        {"passed": true/false, "reason": "brief explanation",
         "findings": [{"severity": "blocking"|"advisory", "text": "what is wrong",
                       "file": "path (optional)"}]}
        The JSON object is what routes the run — a verdict written only as prose
        cannot be acted on, whichever way you decided.

        Give each finding a severity, and be honest about which it is:
        - "blocking" — the rubric is unmet. A failing verify, an acceptance
          criterion the diff does not meet, work outside the item's scope, a
          prohibition the item stated and the diff ignored. Any one of these
          rejects the run, so this is the same bar as before: a specific reason
          you are sending the work back.
        - "advisory" — worth saying, not worth rejecting for. A naming nit, a
          convention the surrounding code follows more closely, a follow-up
          worth its own item. These do not block: they are recorded on the item
          and read by whoever picks it up next, so you no longer have to choose
          between rejecting over a nit and swallowing it.
        "findings" is optional — omit it when you have nothing to say beyond the
        verdict. Do not soften a blocking finding to advisory to let work
        through, and do not raise a nit to blocking to make a point.
        """

    /// The follow-up ask's own prompt, pulled out of `buildWorkflowGraph` for
    /// the same reason `reviewerNodePrompt` is: kept out of the function the
    /// complexity gate measures.
    nonisolated static let reviewerClarifyPrompt = """
        Your review of "{{state.title}}" did not include a machine-readable verdict,
        so the run cannot route it.

        Do not review the work again and do not change your mind — you have already
        decided. State that same decision in the structured form.

        Reply with a JSON object and nothing else:
        {"passed": true/false, "reason": "brief explanation"}

        `passed: true` = you are approving the work as it stands.
        `passed: false` = you are sending it back to the worker with your findings.
        """

    /// What the follow-up ask's own timeout resolves to — pulled out of
    /// `buildWorkflowGraph` alongside its prompt, for the same reason.
    nonisolated static let reviewerClarifyTimeoutFallback = WorkflowNode.TimeoutFallback(
        key: "passed", trueValue: "true", falseValue: "false",
        note: clarifyTimeoutNote, feedbackKey: ReviewFindings.feedbackKey
    )

    /// The reviewer read the diff and said no.
    nonisolated static let reviewRejectedReason = "review did not pass"

    /// The reviewer answered, but not in a form the run can route — no `passed`
    /// field, even after being asked for one. Spelled differently from a
    /// rejection on purpose: it is what the outcome, the run log, the item Notes
    /// and every metric keyed on the outcome string read, and for as long as the
    /// two shared a string an approval written as prose was filed as the reviewer
    /// finding defects.
    nonisolated static let unreadableVerdictReason = "reviewer verdict unreadable"

    /// Left in `state["_timeoutFallbackNote"]` (`WorkflowNode.TimeoutFallback`)
    /// when the follow-up ask's own 120s clock runs out. Its silence says
    /// nothing about the verdict the reviewer already gave — the ask exists
    /// only to restate it in a form the graph can route — so the run is
    /// handed that verdict as it stood rather than ending at `blocked`: `done`
    /// if it already read `passed: true`, back to the worker otherwise, which
    /// is every other case including nothing at all.
    nonisolated static let clarifyTimeoutNote =
        "clarification timed out after 120s; verdict as given"

    /// The note `resolveTimeoutFallback` left behind, if this run ever hit
    /// the clarify node's timeout — nil for every run that didn't.
    nonisolated static func clarifyTimeoutFallbackNote(state: [String: AnyCodable]) -> String? {
        state["_timeoutFallbackNote"]?.stringValue
    }

    /// Why a run that ended at `blocked` ended there.
    ///
    /// The graph routes on `passed` alone — `true` to `done`, `false` back to the
    /// worker — so `blocked` is reached only by the fallback behind the follow-up
    /// ask, i.e. when no verdict could be read at all. The rejection branch is
    /// kept because the state can still carry a `false` an edge didn't act on, and
    /// because a graph edit that reintroduces the case should not silently start
    /// mislabelling it again.
    /// What a node's answer means to the graph, applied before the graph routes
    /// on it — the refinement an item's run installs on the orchestrator for the
    /// length of that run.
    ///
    /// A review's answer is more than what it says. Its findings decide the
    /// verdict alongside its boolean, and become the feedback the next worker
    /// pass reads (`ReviewFindings.route`). That has to happen here rather than
    /// being read off the finished state, because the thing that reads it is an
    /// edge condition evaluated the instant the node completes.
    ///
    /// Every other node answers exactly what it said.
    nonisolated static func refineNodeOutput(nodeID: String, output: [String: AnyCodable],
                                             knownPaths: Set<String> = [], changedFiles: Optional<Set<String>> = nil) -> [String: AnyCodable] {
        switch nodeID {
        case "reviewer", reviewerClarifyNodeID:
            return ReviewFindings.route(output, knownPaths: knownPaths, changedFiles: changedFiles)
        default:
            return output
        }
    }

    /// The circuit-breaker's own sentence for an execution it ended — "Node
    /// timeout (1200s) exceeded for node 'worker'" — or nil when the execution
    /// ended some other way. What `_failureReason` holds is written by
    /// `WorkflowEngine.endForCircuitBreaker`.
    nonisolated static func breakerReason(state: [String: AnyCodable]?) -> String? {
        state?["_failureReason"]?.stringValue
    }

    /// The reason a run whose worker ran out of turns ends on — what the item's
    /// Notes and its blocked outcome both say, in place of a verify failure.
    nonisolated static func workerCutShortReason(turns: Int) -> String {
        "worker cut short: it used its \(turns)-turn budget with the work unfinished"
    }

    /// The turns the worker's session reported on its last hand-off. Nil when
    /// the worker never handed off or its runtime counts no turns.
    nonisolated static func workerTurns(in steps: [ExecutionStep]) -> Int? {
        steps.last(where: { $0.nodeID == "worker" })?
            .output?[StreamEvent.ResultPayload.turnsOutputKey]?.stringValue.flatMap { Int($0) }
    }

    /// The turn budget a turn cap cut the worker short on, or nil when none did.
    ///
    /// Either cap counts: the session's own, which its last hand-off reports
    /// (`StreamEvent.ResultPayload.turnCapOutputKey`), and the worker node's
    /// `maxTurns`, which the engine ends the execution on once `engineTurns` —
    /// its count of the worker's hand-offs — passes it. A session cap reported
    /// without a turn count is still a cut-short worker, and reads as the
    /// node's budget.
    nonisolated static func workerCutShortTurns(steps: [ExecutionStep],
                                                engineTurns: Int,
                                                maxTurns: Int?) -> Int? {
        if let maxTurns, engineTurns > maxTurns { return maxTurns }
        let output = steps.last(where: { $0.nodeID == "worker" })?.output
        guard output?[StreamEvent.ResultPayload.turnCapOutputKey] == .bool(true) else { return nil }
        return workerTurns(in: steps) ?? maxTurns ?? 0
    }

    nonisolated static func blockedReviewReason(state: [String: AnyCodable]) -> String {
        state["passed"]?.stringValue == "false" ? reviewRejectedReason : unreadableVerdictReason
    }

    /// The worker/reviewer loop an item is executed as.
    ///
    /// `nodeTimeoutSeconds` is the worker's and reviewer's per-round wall clock —
    /// derived from the project's `stallTimeoutMinutes` by the caller, never a
    /// constant of this file: a round that runs the core suite inside its verify
    /// is longer than any number chosen here in advance (2026-08-30: nine rounds
    /// died to a literal 600 while every check on their trees was green).
    /// `workerMaxTurns` is the worker's turn budget, derived the same way by the
    /// caller from the project's own runs.
    ///
    /// With no `reviewerAgentID` the graph is worker → done: reaching `done`
    /// is what marks the run review-passed, and the empty-diff and stray-work
    /// refusals read the worker's handoff and the finished run, not a verdict.
    static func buildWorkflowGraph(workerAgentID: String,
                                   reviewerAgentID: String?,
                                   maxIterations: Int,
                                   nodeTimeoutSeconds: Int = RunTimeouts.defaultWorkerMinutes * 60,
                                   workerMaxTurns: Int = RunTimeouts.workerTurnsFloor) -> WorkflowGraph {
        let workerNode = WorkflowNode(
            id: "worker",
            agentID: workerAgentID,
            prompt: reviewerAgentID == nil ? Self.soloWorkerNodePrompt : Self.workerNodePrompt,
            maxTurns: workerMaxTurns,
            timeoutSeconds: nodeTimeoutSeconds
        )

        let doneNode = WorkflowNode(id: "done", prompt: "")
        let blockedNode = WorkflowNode(id: "blocked", prompt: "")
        guard let reviewerAgentID else {
            return workflowGraph(
                nodes: ["worker": workerNode, "done": doneNode, "blocked": blockedNode],
                edges: [WorkflowEdge(from: "worker", to: "done", condition: .always, priority: 0)],
                maxIterations: maxIterations)
        }

        let reviewerNode = WorkflowNode(
            id: "reviewer",
            agentID: reviewerAgentID,
            prompt: Self.reviewerNodePrompt,
            maxTurns: 20,
            timeoutSeconds: nodeTimeoutSeconds,
            outputSchema: Self.reviewerOutputSchema
        )

        // Asked when the reviewer's answer carried no `passed` field. The
        // judgement has already been formed and paid for; this asks for it in the
        // form the edges can route, instead of throwing a finished review away.
        // Deliberately symmetric — it must not make "approved" the easier answer.
        let clarifyNode = WorkflowNode(
            id: reviewerClarifyNodeID,
            agentID: reviewerAgentID,
            prompt: Self.reviewerClarifyPrompt,
            maxTurns: 5,
            timeoutSeconds: 120,
            outputSchema: Self.reviewerOutputSchema,
            timeoutFallback: Self.reviewerClarifyTimeoutFallback
        )

        let nodes: [WorkflowGraph.NodeID: WorkflowNode] = [
            "worker": workerNode,
            "reviewer": reviewerNode,
            reviewerClarifyNodeID: clarifyNode,
            "done": doneNode,
            "blocked": blockedNode,
        ]

        return workflowGraph(nodes: nodes, edges: Self.reviewLoopEdges, maxIterations: maxIterations)
    }

    /// The edges of a run with a reviewer.
    ///
    /// The reviewer's fallback is the follow-up ask, not `blocked`: an
    /// unreadable verdict is not a verdict, and dead-ending on one discarded a
    /// reviewed, build-verified diff (2026-08-09) and turned a one-line
    /// correction into manual triage on the very next item. `blocked` stays as
    /// the last resort behind the follow-up, so a reviewer that never answers
    /// in the structured form still terminates.
    nonisolated static let reviewLoopEdges: [WorkflowEdge] = [
        WorkflowEdge(from: "worker", to: "reviewer", condition: .always, priority: 0),
        WorkflowEdge(from: "reviewer", to: "done", condition: .outputMatch(key: "passed", value: "true"), priority: 0),
        WorkflowEdge(from: "reviewer", to: "worker", condition: .outputMatch(key: "passed", value: "false"), priority: 1),
        WorkflowEdge(from: "reviewer", to: reviewerClarifyNodeID, condition: .always, priority: 10),
        WorkflowEdge(from: reviewerClarifyNodeID, to: "done", condition: .outputMatch(key: "passed", value: "true"), priority: 0),
        WorkflowEdge(from: reviewerClarifyNodeID, to: "worker", condition: .outputMatch(key: "passed", value: "false"), priority: 1),
        WorkflowEdge(from: reviewerClarifyNodeID, to: "blocked", condition: .always, priority: 10),
    ]

    /// The graph an item runs as, around the nodes and edges
    /// `buildWorkflowGraph` chose for it.
    private static func workflowGraph(nodes: [WorkflowGraph.NodeID: WorkflowNode],
                                      edges: [WorkflowEdge],
                                      maxIterations: Int) -> WorkflowGraph {
        WorkflowGraph(
            id: "backlog-autopilot-\(UUID().uuidString.prefix(8))",
            name: "Backlog Item Execution",
            version: 1,
            nodes: nodes,
            edges: edges,
            entryNode: "worker",
            terminalNodes: ["done", "blocked"],
            metadata: .init(description: "Executes a backlog item with worker/reviewer validation loop"),
            maxIterations: maxIterations
        )
    }

    func configure(
        orchestrator: Orchestrator,
        backlogViewModel: BacklogViewModel,
        configURL: URL? = nil,
        metricStore: TaskMetricStore? = nil,
        projectPath: String? = nil,
        projectName: String? = nil,
        runtimeFactory: (() -> any AgentRuntime)? = nil,
        globalConfigStore: GlobalConfigStore? = nil,
        dailySpendLedger: DailySpendLedger? = nil,
        reporter: StoreProblemReporter = .shared
    ) {
        self.orchestrator = orchestrator
        self.backlogViewModel = backlogViewModel
        self.configURL = configURL
        self.metricStore = metricStore
        self.projectPath = projectPath
        self.reporter = reporter
        // The governor predicts from the same history; set here so there is one
        // place where a project's metric source is wired up.
        self.costGovernor.metricStore = metricStore
        self.costGovernor.projectPath = projectPath
        self.projectName = projectName
        self.projectRoot = projectPath.map { URL(fileURLWithPath: $0) }
        self.runtimeFactory = runtimeFactory
        self.globalConfigStore = globalConfigStore
        self.dailySpendLedger = dailySpendLedger
        refreshRunTimeouts()
        loadHistory()
        loadConfig()
    }

    var canStart: Bool {
        !selectedItemIDs.isEmpty && workerAgentID != nil && status == .idle
    }

    /// Says, once per base tip, whether the base itself passes the project's
    /// merge-verify with no diff on it — so a failure that belongs to the
    /// branch is read as the branch's rather than attributed to every item's
    /// merge in turn.
    ///
    /// **A warning, never a refusal.** It refused the start until 2026-09-15,
    /// and that stopped a project outright: the check runs the merge-verify in
    /// a cold scratch worktree, and a project whose verify needs something that
    /// worktree does not have — travel's runs inside a container that
    /// bind-mounts the real checkout — fails there for reasons that say nothing
    /// about the base. A run that is stopped before it starts cannot even leave
    /// its work on a branch, so the reading is reported and the run goes ahead.
    /// Only an unattended gate asks, and only when a merge-verify is configured.
    private func noteBaseHealth() async {
        guard autoMergeOnApproval, approveReviewPassedRuns, let projectRoot,
              let command = effectiveMergeVerify.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return }
        let manager = WorktreeManager(projectRoot: projectRoot)
        guard let verdict = await baseVerdict(manager: manager, command: command), !verdict.ok else { return }
        let detail = Self.baseRedDetail(base: baseBranch, sha: verdict.sha, reason: verdict.reason ?? "verify failed")
        appendLog("Warning: \(detail)")
        logPhase(.runStart, [("status", "warning"), ("reason", "base-red"), ("base", verdict.sha)], isError: true)
    }

    /// The base tip's verdict, from the cache when this tip was already
    /// judged — a merge-verify is a build and a suite, and a tip that has not
    /// moved has not changed its answer.
    ///
    /// One check per tip at a time. The fleet's next look calls `start()`
    /// again while a slow merge-verify is still running on the base, and on
    /// 2026-09-13 that started a second `ci-local.sh` two minutes into the
    /// first, in the same scratch worktree — which the second check clears
    /// first, so the first fails as "removed" and the tip is cached red. A
    /// second start now waits on the check already running.
    private func baseVerdict(manager: WorktreeManager, command: String) async -> WorktreeManager.BaseVerdict? {
        guard let tip = await manager.tipSHA(of: baseBranch.map { "refs/heads/\($0)" } ?? "HEAD") else { return nil }
        if let cached = baseHealthByTip[tip] { return cached }
        if let running = baseHealthChecks[tip] {
            appendLog("The base \(tip.prefix(7)) is still being checked against the merge-verify — waiting for it")
            return await running.value
        }
        appendLog("Checking the base \(baseBranch ?? "HEAD") at \(tip.prefix(7)) against the merge-verify "
                  + "before the run — a red base would refuse every merge")
        let (base, timeout, setup) = (baseBranch, verifyTimeout, effectiveWorktreeSetup.command)
        let check = Task { await manager.verifyBase(command: command, base: base, timeout: timeout, setupCommand: setup) }
        baseHealthChecks[tip] = check
        let verdict = await check.value
        baseHealthChecks.removeValue(forKey: tip)
        if let verdict { baseHealthByTip[verdict.sha] = verdict }
        return verdict
    }

    /// The warning's own words for a red base.
    nonisolated static func baseRedDetail(base: String?, sha: String, reason: String) -> String {
        "the base \(base ?? "HEAD") at \(sha.prefix(7)) fails the project's merge-verify with no item's "
            + "diff on it — \(reason). Merges will be refused for it until it is green, or until the "
            + "verify is made runnable in a cold worktree; the items are not at fault"
    }

    /// Writes down what this `start()` decided, in the deciding gate's words.
    ///
    /// Every exit from `start()` goes through here — the refusals and the
    /// acceptance alike — so a caller can always tell "refused, and why" from
    /// "accepted, still spinning up". Those two were indistinguishable from the
    /// outside, and guessing between them by wall-clock is what made a live run
    /// report itself as never started.
    private func recordStartOutcome(_ refusal: StartOutcome.Refusal?, _ detail: String) {
        startAttempts += 1
        lastStartOutcome = StartOutcome(attempt: startAttempts, refusal: refusal, detail: detail)
    }

    /// Runs the selected items.
    ///
    /// `initiator` says who asked. An autonomous start is refused once **either**
    /// this project's own daily budget or the portfolio's is spent — the point of
    /// the ceiling is that a subscription gets used all day and nobody wakes up
    /// to a night of work nobody asked for, and the point of the project's own is
    /// that one busy project shouldn't spend everybody else's allowance. The
    /// refusal names the ceiling that stopped it. A human start is never refused
    /// for budget: the ceiling governs autonomy, not the person. Defaults to
    /// `.human`, so the buttons in the app keep working exactly as before.
    ///
    /// The **session** cost cap refuses whoever asked, because it is not a rule
    /// about autonomy: a spent session budget stops the queue at the next item
    /// however it was started, so a start over one has nothing to offer anybody.
    /// A resume is what opens the next session and lets a start through again.
    func start(initiator: RunInitiator = .human) async {
        // The gates about the moment rather than the items come first, in the
        // order a caller meets them over `POST /v1/runs`: a hold, then a spent
        // budget. Each records its own refusal before it returns, so "refused,
        // and why" is never guessed at from the outside.
        if refusedByHold() || refusedByBudget(initiator: initiator) { return }
        guard let context = startContext() else { return }
        let outcome = await admitSelection(context: context)
        guard !runQueue.isEmpty else {
            refuseNoRunnableItems(outcome)
            return
        }
        await noteBaseHealth()
        resetRunState()
        guard hasAgentSessions(context) else { return }
        isExecutingRun = true
        defer { isExecutingRun = false }
        beginRun(context: context, skipped: outcome.skippedCount)
        await continueFromCurrentIndex()
        finalizeRunRecord()
        selectedItemIDs.removeAll()
    }

    /// The holds that refuse a start before anything about the items matters,
    /// and `true` when one of them did — having already said so in the log, the
    /// start outcome and the phase line.
    private func refusedByHold() -> Bool {
        // The fleet gate, before anything else this could do — mirrors the 409
        // `POST /v1/runs` answers over the same flag. Quiescing a project does
        // not stop this path on its own (a paused queue is discarded and run
        // anyway by the guards below), so without this the Start button would
        // begin a fresh run into a fleet held for a restart, which is exactly
        // what the drain exists to avoid stranding.
        if isFleetQuiesced?() == true {
            let detail = "the fleet is quiesced for a restart — no new runs are being accepted; "
                + "a resume lifts the hold"
            appendLog("Cannot start: \(detail)")
            recordStartOutcome(.fleetQuiesced, detail)
            logPhase(.runStart, [("status", "aborted"), ("reason", "fleet-quiesced")], isError: true)
            return true
        }
        // The project's own hard stop — mirrors the 409 `POST /v1/runs` answers
        // over the same condition. `isHoldingQueue` is this autopilot holding its
        // own queue (`pause()`, which outlives the run it interrupted — that is
        // what `queueHeld` is for); `isProjectPaused` is the fleet board's pause,
        // which leaves `status` untouched while the project sits idle. A pause is
        // one act now: without this the Autopilot tab's Run button would begin a
        // fresh run into a project a human just told the fleet to leave alone.
        if isHoldingQueue || isProjectPaused?() == true {
            let detail = "this project is paused — no new runs are being accepted; a resume lifts the hold"
            appendLog("Cannot start: \(detail)")
            recordStartOutcome(.paused, detail)
            logPhase(.runStart, [("status", "aborted"), ("reason", "paused")], isError: true)
            return true
        }
        // One run at a time, enforced where the run actually is rather than by
        // whoever asked. A second loop over the same queue would fight the first
        // one for `currentIndex`, the cost session and the agents' sessions.
        if isExecutingRun {
            let detail = "a run is already executing for this project"
            appendLog("Cannot start: \(detail)")
            recordStartOutcome(.runInFlight, detail)
            logPhase(.runStart, [("status", "aborted"), ("reason", "run-in-flight")], isError: true)
            return true
        }
        return false
    }

    /// The spend gates, and `true` when one of them refused this start.
    ///
    /// The daily ceilings govern autonomy, so they read `initiator`; the session
    /// cap refuses whoever asked, because a spent session budget holds the queue
    /// at its next item however the run began.
    private func refusedByBudget(initiator: RunInitiator) -> Bool {
        if case .refuse(let refusal) = dailyBudgetGate.decision(for: initiator) {
            appendLog(refusal.logLine)
            recordStartOutcome(.dailyBudget, refusal.logLine)
            logPhase(.runStart, [
                ("status", "aborted"),
                ("reason", "daily-budget"),
                // Which ceiling refused. Two of them govern a start now, and a
                // log line that didn't say would send a reader to raise the
                // wrong number.
                ("budgetScope", Self.budgetScopeField(refusal.scope)),
                ("initiator", initiator.rawValue),
                ("budgetUSD", Self.usdField(refusal.budgetUSD)),
                ("spentTodayUSD", Self.usdField(refusal.spentUSD)),
            ], isError: true)
            orchestrator?.publishEvent(KiteloopEvent(source: "Autopilot", type: .workflowFailed, payload: [
                "reason": refusal.eventReason,
                "spentTodayUSD": String(format: "%.2f", refusal.spentUSD),
            ]))
            return true
        }
        // A session budget that is already spent holds the queue before its first
        // item begins, so there is no run to report: `continueFromCurrentIndex`
        // meets the same check a moment later, pauses at index 0 and mints no
        // execution — and `POST /v1/runs`, finding neither an execution nor a
        // refusal, waited its window out and answered "accepted and spinning up"
        // for a run that never existed. Said here, in the pause's own words, it
        // is an answer the caller gets on the first poll. The check inside the
        // loop stays: that one holds a queue *mid-run*, which this cannot see.
        if let pause = costGovernor.sessionPause {
            appendLog(pause.logLine)
            recordStartOutcome(.sessionCap, pause.logLine)
            logPhase(.runStart, [
                ("status", "aborted"),
                ("reason", "session-cap"),
                ("capUSD", Self.usdField(pause.capUSD)),
                ("spentUSD", pause.spentText),
            ], isError: true)
            orchestrator?.publishEvent(KiteloopEvent(source: "Autopilot", type: .workflowFailed, payload: [
                "reason": pause.eventReason,
                "spentUSD": pause.spentText,
            ]))
            return true
        }
        return false
    }

    /// Everything a run needs that is wired up rather than decided: the two
    /// collaborators, the worker, the reviewer if the project has one, and the
    /// loaded backlog file.
    private struct StartContext {
        let orchestrator: Orchestrator
        let backlogViewModel: BacklogViewModel
        let worker: String
        let reviewer: String?
        let file: BacklogFile
    }

    /// The wiring a run needs, or `nil` when something is missing — in which
    /// case the refusal naming what is missing is already recorded.
    private func startContext() -> StartContext? {
        guard let orchestrator, let backlogViewModel else {
            let detail = "orchestrator or backlogViewModel not configured"
            appendLog("Cannot start: \(detail)")
            recordStartOutcome(.notConfigured, detail)
            logPhase(.runStart, [
                ("status", "aborted"),
                ("reason", "not-configured"),
                ("orchestrator", String(orchestrator != nil)),
                ("backlogVM", String(backlogViewModel != nil)),
            ], isError: true)
            return nil
        }
        guard let worker = workerAgentID else {
            let detail = "select a worker agent"
            appendLog("Cannot start: \(detail)")
            recordStartOutcome(.noWorkerOrReviewer, detail)
            logPhase(.runStart, [
                ("status", "aborted"),
                ("reason", "no-worker-or-reviewer"),
                ("worker", workerAgentID ?? "unset"),
                ("reviewer", reviewerAgentID ?? "unset"),
            ], isError: true)
            return nil
        }
        guard let file = backlogViewModel.backlogFile else {
            let detail = "no backlog loaded"
            appendLog("Cannot start: \(detail)")
            recordStartOutcome(.noBacklog, detail)
            logPhase(.runStart, [("status", "aborted"), ("reason", "no-backlog")], isError: true)
            return nil
        }
        return StartContext(orchestrator: orchestrator, backlogViewModel: backlogViewModel,
                            worker: worker, reviewer: reviewerAgentID, file: file)
    }

    /// What the pickup gates made of a selection: for each gate that turned an
    /// item away, the id and the reason it gave. The queue itself is `runQueue`,
    /// narrowed one gate at a time.
    private struct PickupOutcome {
        var wrongStatus: [(id: String, summary: String)] = []
        var notReady: [(id: String, summary: String)] = []
        var retired: [(id: String, summary: String)] = []
        var notGrounded: [(id: String, summary: String)] = []

        /// The skip count the run-start line carries: wrong status, not ready
        /// and retired.
        var skippedCount: Int { wrongStatus.count + notReady.count + retired.count }
    }

    /// Narrows the selection into `runQueue`, a gate at a time: the stages this
    /// project's flow allows, the Definition of Ready, the retry ceiling and the
    /// grounding check. The order the queue is walked in is settled first —
    /// lane, then the order the file is written in — so every gate sees the run
    /// order rather than the selection's. Each gate says what it turned away — in the log, on the
    /// item, and in the outcome the "no runnable items" refusal is built from.
    private func admitSelection(context: StartContext) async -> PickupOutcome {
        var outcome = PickupOutcome()
        let pickupStages = context.backlogViewModel.workflow.autopilotPickupStages
        let selected = context.file.sections.flatMap(\.items).filter { selectedItemIDs.contains($0.id) }
        outcome.wrongStatus = refuseWrongStatus(selected.filter { !pickupStages.contains($0.status) },
                                                pickupStages: pickupStages)
        // Lane first, document order second — and before the gates, so what
        // they log, refuse and report is in the order the run will walk. A
        // `now` item in the last epic is ahead of every `later` one however far
        // up the file it sits; within a lane the file still decides.
        runQueue = BacklogLane.ordered(selected.filter { pickupStages.contains($0.status) })
        outcome.notReady = filterNotReady(context: context)
        surfaceVerifySourceDisagreements(for: runQueue)
        outcome.retired = filterRetired(context: context)
        outcome.notGrounded = await filterUngrounded(context: context)
        return outcome
    }

    /// Says what the stage gate turned away. Only items from stages the flow
    /// allows are pulled (default: Ready); drafts are excluded on purpose —
    /// ungroomed items have no What/How/Validation for the agent to work
    /// against.
    private func refuseWrongStatus(_ items: [BacklogItem],
                                   pickupStages: [BacklogItemStatus]) -> [(id: String, summary: String)] {
        var refused: [(id: String, summary: String)] = []
        for item in items {
            let summary = Self.wrongStatusSkipSummary(status: item.status, pickupStages: pickupStages)
            appendLog("Skipped: \(item.id) — \(summary)")
            logPhase(.itemStart, Self.wrongStatusSkipFields(itemID: item.id,
                                                            status: item.status,
                                                            pickupStages: pickupStages), isError: true)
            recordPickupRefusal(item, .wrongStatus)
            refused.append((id: item.id, summary: summary))
        }
        return refused
    }

    /// The ODD gate. An item that isn't groomed — no What/How/Validation, no
    /// verify to pass, no size or one too big — is skipped rather than run:
    /// there is nothing for the worker to build against or the reviewer to
    /// check, so the cycle would only end in a `blocked` an hour later.
    /// Built from the whole file, not the selection: an item's `needs:` may
    /// name something nobody picked for this run, and "not selected" is not
    /// "done". An item with no `verify:` passes when the project's verify map
    /// has a rule matching every path, which the merge gate runs regardless.
    private func filterNotReady(context: StartContext) -> [(id: String, summary: String)] {
        let dependencies = DefinitionOfReady.Dependencies(file: context.file)
        let mapCoversEveryPath = projectRoot.map {
            VerifyMapFile.load(for: KiteloopProject(rootURL: $0)).rules.contains(where: Self.matchesEveryPath)
        } ?? false
        let qaProfile = projectRoot.map { QAProfile.load(projectRoot: $0) }
        var notReady: [(item: BacklogItem, verdict: DefinitionOfReady.Verdict)] = []
        runQueue = runQueue.filter { item in
            let verdict = DefinitionOfReady.evaluate(
                item: item,
                detail: context.backlogViewModel.loadDetail(for: item),
                dependencies: dependencies,
                verifyMapCoversEveryPath: mapCoversEveryPath,
                qaProfile: qaProfile)
            guard verdict.isReady else {
                notReady.append((item, verdict))
                return false
            }
            return true
        }
        for entry in notReady {
            reportNotReady(entry.item, entry.verdict)
        }
        return notReady.map { (id: $0.item.id, summary: $0.verdict.summary) }
    }

    /// Says what the Definition of Ready refused, and records it against the
    /// item.
    private func reportNotReady(_ item: BacklogItem, _ verdict: DefinitionOfReady.Verdict) {
        appendLog("Skipped: \(item.id) — not ready: \(verdict.summary)")
        logPhase(.itemStart, [
            ("item", item.id),
            ("status", "skipped"),
            ("source", "definition-of-ready"),
            ("unmet", verdict.unmet.map(\.rawValue).joined(separator: ",")),
        ], isError: true)
        recordCheckFailure(item, check: GroomingRecord.Check.definitionOfReady,
                           reason: verdict.summary)
        // Only when the gate refused the item for how it is *written*. An
        // item held back solely by an unmet `needs:` is waiting its turn,
        // not failing — see `RetryCeiling.refusal(for:)`.
        if let refusal = RetryCeiling.refusal(for: verdict) {
            recordMisgroomedRefusal(item, refusal, reason: verdict.summary)
        }
    }

    /// The retry ceiling. Groomed is not the same as productive: an item whose
    /// last few attempts all produced nothing is one that starting again buys
    /// nothing from, and the within-run breaker cannot stop it because a
    /// driver starting a fresh run per item resets that counter every time.
    /// Read from the recorded history instead, so the count survives the
    /// restart the loop lives across — and refuse *before* the run rather than
    /// stopping it after, because the point is not to spend.
    ///
    /// Retirement is not permanent, and the two things that lift it are read
    /// right here: a release a human recorded, and the fingerprint of the item
    /// as it reads now. An item rewritten since its last attempt is judged on
    /// attempts made against *this* wording, which is what makes "re-groom it"
    /// in the retirement note a working instruction rather than a dead end.
    private func filterRetired(context: StartContext) -> [(id: String, summary: String)] {
        var retired: [(item: BacklogItem, verdict: RetryCeiling.Verdict)] = []
        pickupSpecFingerprints.removeAll()
        runQueue = runQueue.filter { item in
            let detail = context.backlogViewModel.loadDetail(for: item)
            let verdict = retryCeilingVerdict(item: item, detail: detail)
            guard !verdict.isRetired else {
                retired.append((item, verdict))
                return false
            }
            noteRetirementRelease(item, verdict)
            pickupSpecFingerprints[item.id] = RetryCeiling.specFingerprint(item: item, detail: detail)
            return true
        }
        for entry in retired {
            reportRetired(entry.item, entry.verdict)
        }
        return retired.map { (id: $0.item.id, summary: $0.verdict.summary) }
    }

    /// Said out loud, because an item that was retired last night and runs
    /// tonight is exactly the thing someone reading the log will stop at.
    private func noteRetirementRelease(_ item: BacklogItem, _ verdict: RetryCeiling.Verdict) {
        guard let release = verdict.release else { return }
        appendLog("\(item.id) — \(release.explanation)")
        logPhase(.itemRelease, [
            ("item", item.id),
            ("release", release.logValue),
            ("discounted", String(release.discountedAttempts)),
        ])
    }

    /// Says what the retry ceiling retired, and records the retirement against
    /// the item so the next pickup reads it from history rather than re-deriving
    /// it.
    private func reportRetired(_ item: BacklogItem, _ verdict: RetryCeiling.Verdict) {
        appendLog("Skipped: \(item.id) — \(verdict.summary)")
        logPhase(.itemStart, [
            ("item", item.id),
            ("status", "skipped"),
            ("source", "retry-ceiling"),
            ("noWorkAttempts", String(verdict.noWorkAttempts)),
            ("ceiling", String(verdict.limit)),
        ], isError: true)
        recordCheckFailure(item, check: GroomingRecord.Check.retryCeiling,
                           reason: verdict.summary)
        recordRetirement(item, verdict: verdict)
        recordPickupRefusal(item, .retired)
    }

    /// Shaped right is not the same as true. An item that cites a file or a
    /// symbol the repo doesn't have sends the worker hunting for something
    /// that was never there, so the same disposition applies: skipped, with
    /// the unresolved references named so the next grooming pass can fix or
    /// drop them. The audit line is logged for the items that pass too — a
    /// green run should say what it checked, not merely that nothing fired.
    private func filterUngrounded(context: StartContext) async -> [(id: String, summary: String)] {
        guard let root = projectRoot, !runQueue.isEmpty else { return [] }
        var ungrounded: [(item: BacklogItem, verdict: GroundingCheck.Verdict)] = []
        let sources = await groundingSources(root: root)
        runQueue = runQueue.filter { item in
            let verdict = GroundingCheck.evaluate(item: item,
                                                  detail: context.backlogViewModel.loadDetail(for: item),
                                                  sources: sources)
            if !verdict.checked.isEmpty {
                appendLog("Grounding \(item.id): \(verdict.audit)")
            }
            guard verdict.isGrounded else {
                ungrounded.append((item, verdict))
                return false
            }
            return true
        }
        for entry in ungrounded {
            reportUngrounded(entry.item, entry.verdict)
        }
        return ungrounded.map { (id: $0.item.id, summary: $0.verdict.summary) }
    }

    /// One index for the whole queue, built off the main actor: it walks the
    /// tree and reads every source file. The vault comes along because an item's
    /// own backlog and detail files live there rather than in the repo, and a
    /// citation of one is a citation of a real file — as is a path in a sibling
    /// project the vault's registry knows about, for an item that names that
    /// project. The index reads the project's own `extraExecutablePaths` for the
    /// executables its verify commands run.
    private func groundingSources(root: URL) async -> GroundingCheck.Sources {
        let vault = globalConfigStore?.vaultURL
        return await Task.detached {
            GroundingCheck.Sources.repository(root: root, vault: vault)
        }.value
    }

    /// Says what the grounding check refused, naming the references that
    /// resolved nowhere so the next grooming pass can fix or drop them.
    private func reportUngrounded(_ item: BacklogItem, _ verdict: GroundingCheck.Verdict) {
        appendLog("Skipped: \(item.id) — not grounded: \(verdict.summary)")
        logPhase(.itemStart, [
            ("item", item.id),
            ("status", "skipped"),
            ("source", "grounding-check"),
            ("unresolved", verdict.unresolved.map(\.text).joined(separator: ",")),
        ], isError: true)
        recordCheckFailure(item, check: GroomingRecord.Check.grounding,
                           reason: verdict.summary)
        recordMisgroomedRefusal(item, .notGrounded, reason: verdict.summary)
    }

    /// The refusal for a selection every pickup gate emptied. The reasons ride
    /// along on the summary line: this is what the control API hands back as its
    /// 422, and "1 not ready" alone wouldn't say which clause to go and fix.
    private func refuseNoRunnableItems(_ outcome: PickupOutcome) {
        let detail = Self.noRunnableItemsDetail(
            selected: selectedItemIDs.count,
            wrongStatus: outcome.wrongStatus,
            notReady: outcome.notReady,
            retired: outcome.retired,
            notGrounded: outcome.notGrounded)
        appendLog(detail)
        recordStartOutcome(.noRunnableItems, detail)
        logPhase(.runStart, [
            ("status", "aborted"),
            ("reason", "no-runnable-items"),
            ("selected", String(selectedItemIDs.count)),
            ("wrongStatus", String(outcome.wrongStatus.count)),
            ("notReady", String(outcome.notReady.count)),
            ("retired", String(outcome.retired.count)),
            ("notGrounded", String(outcome.notGrounded.count)),
        ], isError: true)
    }

    /// The bookkeeping a queue about to run starts from.
    private func resetRunState() {
        shouldStop = false
        stopRequested = false
        currentIndex = 0
        results = []
        costOverrunItemIDs = []
        // The item's bookkeeping only: the session ledger carries over from the
        // runs before this one, because under run-at-a-time driving a run is not
        // a sitting — see `CostGovernor.startRun`.
        costGovernor.startRun()
        consecutiveNoWorkBlocks = 0
    }

    /// Whether both agents have a session to run the queue in — and, when one
    /// doesn't, the refusal saying so and an emptied queue.
    private func hasAgentSessions(_ context: StartContext) -> Bool {
        let worker = context.orchestrator.hasSession(for: context.worker)
        let reviewer = context.reviewer.map { context.orchestrator.hasSession(for: $0) } ?? true
        guard worker, reviewer else {
            let detail = "worker or reviewer agent has no active session — open the agent chat first"
            appendLog("Cannot start: \(detail)")
            recordStartOutcome(.noAgentSession, detail)
            logPhase(.runStart, [
                ("status", "aborted"),
                ("reason", "no-agent-session"),
                ("workerSession", String(worker)),
                ("reviewerSession", String(reviewer)),
            ], isError: true)
            runQueue = []
            return false
        }
        return true
    }

    /// Opens the run: the status the UI reads, the record the history keeps and
    /// the start outcome a caller waiting on `POST /v1/runs` polls for.
    ///
    /// The outcome is recorded here — past every gate, before the queue is
    /// awaited — because this is the instant the answer to "did it start?"
    /// becomes yes. `start()` does not return until the whole queue is done, so
    /// anything waiting on its return value would be waiting for the run to be
    /// over.
    private func beginRun(context: StartContext, skipped: Int) {
        appendLog("Starting autopilot: \(runQueue.count) items queued")
        status = .running(itemIndex: 0, total: runQueue.count)
        recordStartOutcome(nil, "\(runQueue.count) item(s) queued")

        let orchestrator = context.orchestrator
        let workerName = orchestrator.agents.first { $0.id == context.worker }?.name ?? context.worker
        let reviewerName = context.reviewer.map { id in orchestrator.agents.first { $0.id == id }?.name ?? id } ?? ""
        let startedAt = Date()
        currentRunRecord = RunRecord(
            id: UUID().uuidString,
            startedAt: startedAt,
            items: [],
            workerAgentName: workerName,
            reviewerAgentName: reviewerName
        )
        runStartedAt = startedAt

        logPhase(.runStart, [
            ("run", currentRunRecord?.id),
            ("items", String(runQueue.count)),
            ("skipped", String(skipped)),
            ("worker", workerName),
            ("reviewer", reviewerName),
            ("worktree", String(useWorktree)),
        ])

        onStarted?()
        runKnowledgeEvents = []
    }

    func pause() {
        shouldStop = true
        stopRequested = false
        queueHeld = true
        status = .paused
        appendLog("Paused by user")
        logPhase(.runPause, [("reason", "user"), ("resumeAt", String(currentIndex))])
    }

    /// Picks the queue back up from where a pause left it — and, for a queue the
    /// session cost cap stopped, opens a fresh session budget on the way.
    ///
    /// That reset is here because the session ledger now survives across runs: a
    /// spent budget would otherwise hold the queue until the app was relaunched,
    /// since starting a new run no longer clears it. A person asking a paused
    /// queue to continue *is* the session boundary — nothing about the pause
    /// itself changes, and only a spent cap resets anything, so a queue held by
    /// the user, the circuit breaker or a quiesce resumes on the spend it had.
    ///
    /// This is also the one act that lifts `queueHeld`, which is why it does not
    /// require a queue to pick back up: a project a person paused while its last
    /// item was in flight is held with nothing left to run, and a resume it
    /// declined to answer would leave that project held with no remedy at all.
    func resume() async {
        guard isHoldingQueue else { return }
        queueHeld = false
        var closedSessionSpend: String?
        if let pause = costGovernor.sessionPause {
            costGovernor.startSession()
            appendLog(pause.resumeLine)
            closedSessionSpend = pause.spentText
        }
        shouldStop = false
        stopRequested = false
        appendLog("Resumed")
        // A hold with no queue behind it: the run it interrupted finished under
        // it, so there is nothing left to pick up. Lifting the hold is the whole
        // act — re-entering the loop here would narrate a second "Run complete"
        // over a queue nobody restarted.
        guard currentIndex < runQueue.count else {
            status = .idle
            logPhase(.runStart, [
                ("status", "resumed"),
                ("resumeAt", "none"),
                ("sessionReset", closedSessionSpend),
            ])
            return
        }
        logPhase(.runStart, [
            ("status", "resumed"),
            ("run", currentRunRecord?.id),
            ("resumeAt", String(currentIndex)),
            ("items", String(runQueue.count)),
            // Only on the resume that opened a fresh ledger: what the session it
            // closed had spent.
            ("sessionReset", closedSessionSpend),
        ])
        isExecutingRun = true
        defer { isExecutingRun = false }
        await continueFromCurrentIndex()
    }

    /// What this autopilot is actually running, if anything.
    ///
    /// Only one thing can be true while a run is in flight: the run loop is
    /// executing. Anything else — a status left `paused` by a cap that fired
    /// before the item began, a phase nobody cleared, an execution the loop
    /// walked away from — is a claim with nothing behind it, and treating such a
    /// claim as "busy" is how a project stops accepting work until the app is
    /// restarted. So callers that need to know whether they may start something
    /// ask this, not `status`.
    ///
    /// A live execution is deliberately *not* enough on its own. Nobody advances
    /// an execution the run loop has left behind and nobody will read its result,
    /// so it is not a run — it is the contradiction `strandedExecutionID()`
    /// names and `reconcileStatus` clears.
    func inFlightRun() async -> InFlightRun? {
        guard isExecutingRun else { return nil }
        let live = await hasLiveExecution()
        let item = runQueue.indices.contains(currentIndex) ? runQueue[currentIndex] : nil
        return InFlightRun(itemID: item?.id,
                           itemTitle: item?.title,
                           executionID: live ? currentExecutionID : nil,
                           startedAt: currentItemStartedAt)
    }

    /// An execution still live with no run loop behind it — a run that ended
    /// while the workflow it started did not.
    ///
    /// This is the state that wedged a project on 2026-08-11: the run history
    /// read `finished`, `GET /v1/projects` read `running` for the same item, and
    /// neither a run request nor reopening the project could shift it, because
    /// what held the slot was the execution id rather than the status. It is a
    /// contradiction the app can detect, so it is reported and cleared rather
    /// than waited on.
    private func strandedExecutionID() async -> String? {
        guard !isExecutingRun, let executionID = currentExecutionID else { return nil }
        return await hasLiveExecution() ? executionID : nil
    }

    /// Lets go of the execution this autopilot was running, so the project's one
    /// run slot goes back. Called as every item ends — from a `defer`, so an
    /// error thrown before the workflow ever started releases it too — and from
    /// `reconcileStatus` for a slot some other path managed to strand.
    ///
    /// Calling the execution off matters as much as forgetting it: an abandoned
    /// execution still holds its agents in the workflow engine's reservation
    /// queue, and the next item's wait for those agents is what times out
    /// against it — "Timed out waiting for agents" is that timeout. Cancelling
    /// an execution that already reached a terminal status is a no-op, so the
    /// ordinary endings pass through this untouched.
    private func releaseExecutionSlot() {
        guard let stranded = currentExecutionID else { return }
        currentExecutionID = nil
        guard let orchestrator else { return }
        // Only the cancellation is left to a task, because a `defer` cannot
        // await. The slot itself is already given up above, synchronously.
        Task { await orchestrator.cancelWorkflow(executionID: stranded) }
    }

    /// The same answer `inFlightRun()` gives, plus what the autopilot's `status`
    /// claims — so an operator asking "is it stuck?" gets one reading instead of
    /// four sources that can disagree.
    ///
    /// The `inconsistent` phase is deliberately reported rather than smoothed
    /// over: it is exactly the state `reconcileStatus` would clear, and seeing it
    /// named is what turns "kiteloop refuses everything and I don't know why"
    /// into a two-minute check. It is not an error — the next run request or
    /// project open puts it right — but nothing else in the API can show it.
    func runState() async -> RunState {
        let inFlight = await inFlightRun()
        let held = max(0, runQueue.count - currentIndex)
        let label = status.label

        if let inFlight {
            return RunState(phase: .running, inFlight: inFlight, statusLabel: label, heldItems: held)
        }
        // A run that ended while its execution did not. Reported before the
        // `idle` check because the status is usually idle here — the run loop
        // returned normally — and answering `idle` would hide the one fact an
        // operator needs: what is still holding the slot, and that it will go
        // the moment anything asks.
        if let stranded = await strandedExecutionID() {
            return RunState(
                phase: .inconsistent, statusLabel: label, heldItems: held,
                detail: "run \(stranded) is still live with no run loop behind it — a finished "
                      + "run's execution, cleared by the next run request or by reopening the project"
            )
        }
        if status == .idle {
            return RunState(phase: .idle, statusLabel: label, heldItems: held)
        }
        // The one non-idle state with something behind it: a pause taken at an
        // item boundary, which `resume()` picks up. `reconcileStatus` leaves this
        // alone for the same reason, and the two must agree about which is which.
        if case .paused = status, held > 0 {
            return RunState(phase: .held, statusLabel: label, heldItems: held,
                            detail: "paused with \(held) item(s) still queued — resume picks them up")
        }
        // The same hold with its queue behind it: the pause was taken while the
        // last item was in flight, and that item finished. There is nothing to
        // pick back up and nothing stale — the hold stands until a resume lifts
        // it, which is exactly what it was asked to do.
        if queueHeld {
            return RunState(phase: .held, statusLabel: label, heldItems: 0,
                            detail: "paused with the queue finished — a resume lifts the hold")
        }
        return RunState(
            phase: .inconsistent, statusLabel: label, heldItems: held,
            detail: "autopilot reads \(label) with no run behind it — a stale claim, "
                  + "cleared by the next run request or by reopening the project"
        )
    }

    /// Whether the execution this autopilot last started is still going. A
    /// terminal (or vanished) execution is not something anyone is waiting on.
    private func hasLiveExecution() async -> Bool {
        guard let orchestrator, let executionID = currentExecutionID else { return false }
        guard let execution = await orchestrator.workflowEngine.execution(id: executionID) else { return false }
        return !execution.status.isTerminal
    }

    /// Puts the status back in line with what is actually running, and says so.
    ///
    /// Called where a stale claim would otherwise go unnoticed: when a project is
    /// opened (which is also what launch does for every restored project — the
    /// autopilot instance is cached per project, so a status survives a close and
    /// reopen), and before a run request is accepted. Returns whether it cleared
    /// anything, so a caller can report it.
    ///
    /// A `paused` queue with items still to run is left alone: that is a genuine
    /// hold a resume can pick up, not a stale flag. A `running` or `reviewing`
    /// status with no run behind it is stale whatever the queue holds — there is
    /// no such thing as resuming into it.
    ///
    /// A stale claim is not always a stale `status`. An execution left live by a
    /// run that has ended holds the slot on its own, with the status reading a
    /// perfectly ordinary `idle` — which is why this used to answer "nothing to
    /// do" to the one state nobody could get out of. That is checked first, and
    /// separately, so the two kinds of stale claim can't hide each other.
    @discardableResult
    func reconcileStatus(reason: String) async -> Bool {
        var cleared = false
        if let stranded = await strandedExecutionID() {
            appendLog("Cleared a stale busy state (\(reason)): run \(stranded) was still live "
                      + "with no run loop behind it")
            logPhase(.runEnd, [
                ("status", "reconciled"),
                ("reason", reason),
                ("was", "stranded execution"),
                ("execution", stranded),
            ], isError: true)
            currentExecutionID = nil
            // Awaited rather than left to a task, unlike the `defer`'s release:
            // an operator is being told the slot is free, and the agents that
            // execution held have to actually be back by the time the answer is
            // given — the next run's reservation wait is what times out against
            // them otherwise.
            await orchestrator?.cancelWorkflow(executionID: stranded)
            cleared = true
        }

        guard status != .idle else { return cleared }
        guard await inFlightRun() == nil else { return cleared }
        let held = max(0, runQueue.count - currentIndex)
        // A pause is never stale, whatever the queue has left: it was
        // taken deliberately and only a resume lifts it. Clearing it here is how
        // a project paused over its last item would have gone back to idle the
        // moment anything asked it what it was doing.
        if queueHeld { return cleared }
        if case .paused = status, held > 0 { return cleared }

        let stale = status
        appendLog("Cleared a stale busy state (\(reason)): autopilot read \(stale.label) "
                  + "with no run behind it")
        logPhase(.runEnd, [
            ("status", "reconciled"),
            ("reason", reason),
            ("was", stale.label),
            ("abandoned", String(held)),
        ], isError: true)
        releaseQueue()
        return true
    }

    /// Drops what is left of the queue and returns to idle. The items themselves
    /// are untouched — a released queue is one nobody is executing, not a verdict
    /// on the work — so they stay exactly as the backlog has them.
    private func releaseQueue() {
        shouldStop = true
        stopRequested = true
        runQueue = []
        status = .idle
        currentItemStartedAt = nil
    }

    /// Where the run loop leaves the status once the whole queue is behind it:
    /// `idle`, or — for a project someone is holding — the hold the run ended
    /// into.
    ///
    /// The hold outliving the run is the point. A pause lands at the next item
    /// boundary, and the one-item queues the scheduler starts have no next
    /// boundary to land on, so this is where the pause used to be written over
    /// with `idle` — and the next tick, finding an idle project, started
    /// another run the person pausing had just asked it not to.
    private func settleStatusAfterRun() {
        guard queueHeld else {
            status = .idle
            return
        }
        // Past the last item rather than on it: nothing is queued behind this
        // hold, and it is the same index `resume()` reads to know there is
        // nothing left to pick back up.
        currentIndex = runQueue.count
        status = .paused
    }

    func stop() {
        let abandoned = max(0, runQueue.count - currentIndex)
        // The hold goes with the queue it was over. A pause holds this project
        // *for* the items it still has; stopping throws those away, and a hold
        // left standing over nothing would refuse the next run with a pause the
        // Autopilot tab — which reads `status`, now `idle` — could not show.
        queueHeld = false
        releaseQueue()
        appendLog("Stopped by user")
        logPhase(.runEnd, [("status", "stopped"), ("abandoned", String(abandoned))])
    }

    func removeFromQueue(id: String) {
        guard let idx = runQueue.firstIndex(where: { $0.id == id }) else { return }
        let currentIdx: Int = {
            switch status {
            case .running(let i, _), .reviewing(let i, _, _): return i
            default: return -1
            }
        }()
        guard idx > currentIdx else { return }
        let removed = runQueue.remove(at: idx)
        appendLog("Removed from queue: \(removed.title)")
    }

    func moveInQueue(fromOffset: Int, toOffset: Int) {
        let currentIdx: Int = {
            switch status {
            case .running(let i, _), .reviewing(let i, _, _): return i
            default: return -1
            }
        }()
        guard fromOffset > currentIdx, toOffset > currentIdx else { return }
        runQueue.move(fromOffsets: IndexSet(integer: fromOffset), toOffset: toOffset)
    }

    func executionHistory() async -> [WorkflowExecution] {
        guard let orchestrator else { return [] }
        var executions: [WorkflowExecution] = []
        for id in completedExecutionIDs {
            if let exec = await orchestrator.workflowEngine.execution(id: id) {
                executions.append(exec)
            }
        }
        return executions
    }

    private func continueFromCurrentIndex() async {
        guard let orchestrator, let backlogViewModel else { return }
        guard let worker = workerAgentID else { return }
        let reviewer = reviewerAgentID

        for index in currentIndex..<runQueue.count {
            guard !shouldStop else {
                // `stop()` abandons the queue outright, so the run is over rather
                // than held: reporting `paused` here would leave a stopped autopilot
                // looking resumable, and would 409 the next run for 30s first.
                status = stopRequested ? .idle : .paused
                return
            }

            currentIndex = index
            let item = runQueue[index]
            // Don't start an item there's no budget for — pause with the item
            // untouched so a resume picks it up from the top.
            if let pause = costGovernor.sessionPause {
                pauseForSessionCap(pause, resumeAt: index)
                return
            }
            // Autopilot is unattended: the worker's and reviewer's sessions run in
            // Claude Code's auto mode for this item, its classifier deciding each
            // tool call (e.g. the reviewer running the verify Bash command), since
            // there is no human to answer a prompt.
            if let worker = workerAgentID { orchestrator.setUnattended(worker, true); orchestrator.updateAgent(id: worker) { $0.maxTurns = workerMaxTurns } }
            if let reviewer = reviewerAgentID { orchestrator.setUnattended(reviewer, true) }
            // Marked first, then the sessions: a process's environment is fixed
            // when it spawns, so a session started for a human was started on a
            // human's terms — Claude Code's own memory left on. Handing the item
            // to that process would run it outside the decision the flag above
            // stands for.
            await replaceAttendedSessions(itemID: item.id)
            defer {
                if let worker = workerAgentID { orchestrator.setUnattended(worker, false); orchestrator.updateAgent(id: worker) { $0.maxTurns = nil } }
                if let reviewer = reviewerAgentID { orchestrator.setUnattended(reviewer, false) }
                // Installed below once the item has a worktree to read; cleared
                // here so no exit path can leave a finished item's check
                // answering for the next one.
                orchestrator.workflowHandoffCheck = nil
                // Same reason: a note typed seconds before the item ended has no
                // worker left to reach, and leaving it queued would deliver an
                // operator's correction about *this* item to whatever that agent
                // does next.
                if let worker = workerAgentID { orchestrator.clearSteerNotes(for: worker) }
                // Same reason as the steer notes above: attribution recorded
                // for this item's worker and reviewer has nothing left to say
                // once the item is over, and leaving it would let a later
                // item's stray-work check credit this one's writes to itself.
                orchestrator.clearWrittenPaths(for: worker)
                if let reviewer { orchestrator.clearWrittenPaths(for: reviewer) }
                // The backstop under the held approval summons: whatever path
                // this item left by, the human it was waiting for is told. The
                // normal path has already flushed it (with the pull request's
                // state attached), and flushing is idempotent.
                flushGateNotification()
                costGovernor.endItem()
                // The item is over however it ended — reviewed, blocked,
                // cancelled, or thrown out of before the workflow ever started —
                // so the execution it was running under is no longer this
                // project's run. In a `defer` because the ending that wedged a
                // project was the one no ordinary path covers: the reservation
                // wait timing out, which throws past everything below.
                releaseExecutionSlot()
            }
            currentItemSpans = []
            costGovernor.beginItem(item)
            // Stamped as the item becomes the current one rather than reusing the
            // `startTime` below: this is what "running since" answers for an
            // operator, and it should start where the status does, not after the
            // previous-attempt check that runs in between.
            currentItemStartedAt = Date()
            status = .running(itemIndex: index, total: runQueue.count)
            appendLog("Executing: \(item.title)")
            appendLog(costCapLogLine(for: item))
            // Does the label describe the work? Asked here because this is the
            // cheap moment to notice — the alternative is finding out an hour
            // later, from a cost cap that was set for a smaller item. Advisory:
            // the item runs either way.
            let sizeFlag = costGovernor.sizeFlag(for: item)
            if let sizeFlag {
                appendLog("Size check: \(sizeFlag.summary)")
            }
            // Never start over the top of a previous attempt's work in silence.
            // A blocked run commits what it did to `kiteloop/<id>` and keeps its
            // worktree, and `WorktreeSession.begin` below force-removes both to
            // make room. Paying twice for the same diff is the cost of not
            // saying so: one item was run three times on 2026-08-08 while a
            // finished implementation of it sat there unmentioned.
            let previousWork = await previousAttemptWork(for: item)
            if let summary = previousWork?.summary {
                appendLog("A previous attempt at \(item.id) left \(summary) — "
                          + "this run starts from scratch and replaces it")
            }
            // What this repo has learned from the runs before this one. Both the
            // worker and the reviewer start the item holding it, rather than
            // paying again for a lesson already written down. Said out loud, with
            // its size, because a prompt nobody kept is otherwise the only record
            // that it went over. Silent when the project has no such file — the
            // section, and its tokens, are absent rather than empty.
            let background = projectPath.flatMap { CoordinatorKnowledge.background(projectPath: $0) }
            if let background {
                appendLog("Background knowledge: \(background.bullets) bullet(s) from "
                          + ".kiteloop/\(CoordinatorKnowledge.fileName) — the worker and the reviewer both see it")
            }
            // A person's own rejection of a previous run of this item, still
            // unanswered — read back from `GateRejection` rather than the
            // item's Notes, so it opens the worker's and the reviewer's prompt
            // instead of sitting unread among every other note the item has
            // ever collected.
            let rejection = projectPath.flatMap {
                GateRejection.outstanding(itemID: item.id, entries: GateRejection.read(from: GateRejection.url(projectPath: $0)))
            }
            if rejection != nil {
                appendLog("A person rejected the previous run of \(item.id) — the reason opens the "
                          + "worker's and the reviewer's prompt")
            }
            logPhase(.itemStart, [
                ("item", item.id),
                ("index", String(index + 1)),
                ("total", String(runQueue.count)),
                ("size", item.size?.rawValue),
                ("title", item.title),
                ("predictedUSD", predictedCostUSD(for: item).map(Self.usdField)),
                ("capUSD", effectiveCostCap(for: item).map(Self.usdField)),
                ("sizeFlag", sizeFlag.map { "\($0.edge.rawValue)-band" }),
                ("sizeBand", sizeFlag?.band.summary),
                ("worktree", String(useWorktree)),
                ("previousWork", previousWork?.summary),
                ("knowledgeBullets", background.map { String($0.bullets) }),
            ])

            let startTime = Date()
            backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .active)
            // Nil when the item runs in the live tree; every worktree-shaped step
            // below is conditioned on it rather than re-deriving the decision.
            let session: WorktreeSession?
            switch await WorktreeSession.begin(
                baseBranch: baseBranch,
                itemID: item.id,
                projectRoot: projectRoot,
                agentIDs: [worker, reviewer].compactMap { $0 },
                orchestrator: orchestrator,
                setupCommand: effectiveWorktreeSetup.command,
                log: { [weak self] in self?.appendLog($0) }
            ) {
            case .isolated(let started):
                session = started
            case .liveTree:
                session = nil
            case .failed(let reason):
                // Isolation was asked for and could not be had, so there is
                // nowhere for this item to be built that isn't the project's own
                // checkout. It is blocked rather than run: a git project always
                // isolates, so its checkout is not where work may land, and a run that cannot
                // honour it has nothing to offer but contamination.
                let blocked = "worktree isolation could not be established (\(reason))"
                appendLog("Blocked: \(item.title) — \(blocked)")
                backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .blocked)
                backlogViewModel.appendNote(itemID: item.id, blocked)
                let itemResult = ItemResult(id: item.id, title: item.title,
                                            outcome: .blocked(blocked), duration: 0)
                results.append(itemResult)
                recordItemResult(itemResult, executionID: nil)
                logPhase(.itemEnd, [
                    ("item", item.id),
                    ("outcome", "blocked"),
                    ("reason", blocked),
                ], isError: true)
                continue
            }

            // What the project's own checkout looks like before the worker
            // starts. An isolated run must leave it exactly as it is, and this
            // is what that claim is checked against afterwards — see
            // `strayWorkRefusal` below, which still reads it only for an
            // isolated run: with isolation off the live tree *is* where the
            // work goes.
            let rootBefore = await RunWorkEvidence.snapshotProjectRoot(projectRoot)

            // Ask git before the worker hands off, not only after it has gone.
            // A worker that has changed nothing is told so once, while it can
            // still act — see `EmptyDiffHandoff`. Nothing here weakens the
            // post-run evidence check below; this is the earlier chance.
            toldWorkerDiffWasEmpty = false
            lastReviewedChangedFiles = nil
            orchestrator.workflowHandoffCheck = { [weak self] execID, nodeID in
                await self?.emptyDiffHandoff(executionID: execID, nodeID: nodeID, session: session)
            }

            let detail = backlogViewModel.loadDetail(for: item)
            let knownPaths = Self.knownItemPaths(item: item, detail: detail)
            var initialState = Self.buildInitialState(item: item, detail: detail,
                                                      worktree: session?.path,
                                                      background: background,
                                                      rejection: rejection)
            // Where a shell stage runs: the item's tree, else the project.
            if let tree = session?.path ?? projectRoot {
                initialState["_cwd"] = .string(tree.path(percentEncoded: false))
            }

            let baseGraph = Self.buildWorkflowGraph(
                workerAgentID: worker,
                reviewerAgentID: reviewer,
                maxIterations: maxRetries,
                nodeTimeoutSeconds: max(1, stallTimeoutMinutes) * 60,
                workerMaxTurns: workerMaxTurns
            )
            // A `flow:qa` item runs the QA stages around that graph, driven by
            // the profile in its own tree — pickup has already refused one in a
            // project without a usable profile.
            let qaProfile = item.flow == .qa
                ? (session?.path ?? projectRoot).flatMap { QAProfile.load(projectRoot: $0).profile } : nil
            let graph = qaProfile.map {
                QAFlowStages.apply(to: baseGraph, profile: $0, itemID: item.id, agentID: worker)
            } ?? baseGraph

            // A run whose worker left nothing behind must not reach the reviewer:
            // with no diff there is nothing to have reviewed, and "passed" is the
            // one answer a reviewer without one cannot honestly give. Installed
            // per item and cleared when it ends, so no other workflow this
            // orchestrator runs is gated by it.
            reviewGate = .pending
            // Cleared with the gate: a verdict measured on the previous item's
            // tree must never be filed against this one.
            lastVerifyVerdict = nil
            lastWorkerTurns = nil
            workerCutShortTurns = nil
            orchestrator.nodeActivationGate = { [weak self] executionID, nodeID in
                guard let self, Self.isGatedReviewNode(nodeID) else { return true }
                return await self.allowReviewerToRun(executionID: executionID, session: session)
            }
            defer { orchestrator.nodeActivationGate = nil }

            // What a node's answer means to the graph, applied before the graph
            // routes on it — see `refineNodeOutput`. Installed for this item
            // only: it is a seam on the orchestrator rather than a read of the
            // finished state because what consumes it is an edge condition.
            orchestrator.workflowOutputRefinement = { [weak self] nodeID, output in
                let changedFiles = await self?.lastReviewedChangedFiles
                return Self.refineNodeOutput(nodeID: nodeID, output: output,
                                             knownPaths: knownPaths, changedFiles: changedFiles)
            }
            defer { orchestrator.workflowOutputRefinement = nil }

            do {
                let execID = try await orchestrator.startWorkflow(graph: graph, initialState: initialState)
                currentExecutionID = execID
                onExecutionStarted?(execID)

                let result = await awaitWorkflowCompletion(executionID: execID)
                let duration = Date().timeIntervalSince(startTime)
                completedExecutionIDs.insert(execID, at: 0)
                if completedExecutionIDs.count > 50 { completedExecutionIDs.removeLast() }

                // The execution as it ended, read once and shared by everything
                // below that asks what the run actually did.
                let finalExecution = await orchestrator.workflowEngine.execution(id: execID)
                await readWorkerTurns(executionID: execID)

                recordDriftFindings(execution: finalExecution, item: item, backlog: backlogViewModel)
                recordQAReport(execution: finalExecution, item: item, tree: session?.path ?? projectRoot,
                               backlog: backlogViewModel)

                var itemResult: ItemResult
                // Whether the reviewer is what accepted this item — the one
                // ending `approveReviewPassedRuns` covers. A run salvaged by its
                // own `verify:` reaches the same gate and is deliberately not
                // it: nobody reviewed that diff.
                var reviewPassed = false
                switch result {
                case .completed:
                    // A completed execution reached one of two terminal nodes:
                    // the reviewer passed (`done`) or the run dead-ended
                    // (`blocked`). Distinguish by the final node — and, at
                    // `blocked`, by what the reviewer's verdict actually said,
                    // because "the reviewer rejected this" and "nobody could read
                    // the verdict" need different things next and were recorded
                    // identically until now.
                    if finalExecution?.currentNode == "blocked" {
                        let reason = Self.blockedReviewReason(state: finalExecution?.state ?? [:])
                        if reason == Self.unreadableVerdictReason {
                            appendLog("Blocked: \(item.title) — the reviewer's verdict could not be read "
                                      + "as pass or fail, even after being asked for it again. This is not "
                                      + "a rejection: the work is committed and the branch is kept, so read "
                                      + "the review or re-run.")
                            // The Notes are where the next run and the human both
                            // look, and this is the one thing they can't infer:
                            // that nobody rejected anything.
                            backlogViewModel.appendNote(
                                itemID: item.id,
                                "\(Self.unreadableVerdictReason) — the reviewer gave no machine-readable "
                                + "pass/fail, even after a follow-up ask. Not a rejection; read the review "
                                + "before re-running.")
                        } else {
                            appendLog("Blocked: \(item.title) — \(reason)")
                        }
                        backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .blocked)
                        itemResult = ItemResult(id: item.id, title: item.title, outcome: .blocked(reason), duration: duration)
                    } else {
                        recordAdvisoryFindings(review: Self.lastReviewOutput(in: finalExecution),
                                               item: item,
                                               backlog: backlogViewModel)
                        reviewPassed = true
                        if let projectPath { Self.clearGateRejectionIfOutstanding(itemID: item.id, projectPath: projectPath) }
                        itemResult = await accept(item, backlog: backlogViewModel, duration: duration,
                                            why: "review passed", reviewPassed: true)
                    }
                case .failed, .timedOut:
                    // A breaker-ended execution wrote why into its state; "max
                    // retries" without it sent an operator hunting for review
                    // failures that never happened (2026-08-30, three items).
                    let reason = lastStallReason
                        ?? Self.breakerReason(state: finalExecution?.state)
                        ?? "max retries"
                    lastStallReason = nil
                    // Asked first: a run the account's usage limit stopped is not
                    // a verdict on anything below — not a worker cut short, not a
                    // tree to salvage — and a retry spent on it is a retry wasted.
                    if let parked = parkIfUsageLimited(item, duration: duration, backlog: backlogViewModel) {
                        itemResult = parked
                    } else
                    // A run cut short (cost cap, stall, retry ceiling) can still have
                    // produced correct work — the loop just never got to a passing
                    // review. Re-check the item's own verify: green means it clears
                    // the same objective bar acceptance uses, so salvage it rather
                    // than discarding the branch and re-running from scratch.
                    // Not a worker that ran out of turns: its tree is half-written
                    // by its own account, and a verify cannot make it finished.
                    if let turns = workerCutShortTurns {
                        let cutShort = noteWorkerCutShort(item, turns: turns, backlog: backlogViewModel)
                        backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .blocked)
                        itemResult = ItemResult(id: item.id, title: item.title, outcome: .blocked(cutShort), duration: duration)
                    } else if await salvageVerifyPasses(item: item, detail: detail, worktree: session?.path) {
                        itemResult = await accept(item, backlog: backlogViewModel, duration: duration,
                                            why: "verify passed after \(reason) — salvaged",
                                            reviewPassed: false)
                    } else {
                        appendLog("Blocked: \(item.title) — \(reason)")
                        backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .blocked)
                        itemResult = ItemResult(id: item.id, title: item.title, outcome: .blocked(reason), duration: duration)
                    }
                case .cancelled:
                    if case .closed(let signal) = reviewGate {
                        // Not a human cancelling: the pre-review gate ended this
                        // run because there was nothing for the reviewer to read.
                        // Blocked, so teardown keeps the worktree and the
                        // post-teardown check below asks git the same question
                        // again — its answer is what returns the item to Ready and
                        // counts the no-work streak. No log line here; the gate
                        // already said why, at the point the run ended.
                        backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .blocked)
                        itemResult = ItemResult(id: item.id, title: item.title,
                                                outcome: .blocked(signal), duration: duration)
                    } else {
                        appendLog("Cancelled: \(item.title)")
                        backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .ready)
                        itemResult = ItemResult(id: item.id, title: item.title, outcome: .cancelled, duration: duration)
                    }
                default:
                    backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .blocked)
                    itemResult = ItemResult(id: item.id, title: item.title, outcome: .blocked(result.rawValue), duration: duration)
                }
                let teardown = await session?.end(outcome: itemResult.outcome); noteTeardownCommit(teardown, item: item)
                itemResult.branch = teardown?.branch
                // A blocked run's evidence is the tree teardown kept. Take it from
                // the teardown rather than reading `session.path` beforehand: this
                // is nil unless a worktree actually survived, so a run whose tree
                // was removed can't be asked about a directory that isn't there.
                let worktreePath = teardown?.worktreePath

                // Did this run produce anything at all? Ask git — the same
                // question of both endings, because the failure it catches is the
                // same one: a dead session that walks the workflow without doing
                // any work.
                //
                // At the gate, that run asks a human to approve a change that
                // doesn't exist, and approving it stamps the item Done. Blocked,
                // it looks like a rejection on the merits and consumes the item
                // for a run that said nothing about it.
                //
                // Either way the item goes back to `ready` — nothing was
                // attempted, so this is not a verdict on the work — and the
                // signal is recorded as the reason. Non-nil here is what
                // `consecutiveNoWorkBlocks` below counts and restarts on.
                //
                // The verdict is kept, not just its signal: the day's ledger
                // asks the same question before charging an unreported cost, and
                // reading git twice is how two answers end up disagreeing.
                var workEvidence: RunWorkEvidence.Verdict = .unknown
                switch itemResult.outcome {
                case .awaitingApproval:
                    workEvidence = await RunWorkEvidence.inspect(
                        projectRoot: projectRoot,
                        branch: itemResult.branch,
                        isolated: session != nil
                    )
                case .blocked:
                    workEvidence = await RunWorkEvidence.inspectBlocked(
                        projectRoot: projectRoot,
                        branch: itemResult.branch,
                        worktree: worktreePath,
                        isolated: session != nil
                    )
                // `.alreadyImplemented` is not reachable here: it is an ending
                // this loop *derives* from the verdict below, so nothing wears
                // it yet at the point the verdict is read.
                case .done, .cancelled, .alreadyImplemented, .investigation, .usageLimitParked:
                    break
                }
                // Did this run's own session write into the project's checkout
                // rather than its worktree? Asked of an isolated run only, and
                // asked *before* the auto-merge below, which writes to that
                // same tree.
                //
                // This is the case the branch signals above cannot see. A run
                // that built into the main checkout leaves a worktree with
                // nothing in it and a branch with nothing on it, which reads as
                // an empty run — and an empty run is returned to Ready for
                // another go, on top of a tree that now holds the last
                // attempt's uncommitted work. Naming the paths is what turns
                // that into something a person can act on.
                //
                // Not every path that turned up dirty is the run's, though — a
                // human editing the same checkout, a second Claude Code
                // session, the gate's own verify appending a status row all
                // leave the same signature. `writtenBySession` is what this
                // worker's and reviewer's own file-writing tool calls named,
                // so only a path attributed to one of them blocks the
                // run; the rest is a `## Notes` observation, not a verdict.
                let strayReport = await RunWorkEvidence.strayWork(
                    projectRoot: projectRoot,
                    since: rootBefore,
                    isolated: session != nil,
                    writtenBySession: orchestrator.writtenPaths(for: worker)
                        .union(reviewer.map { orchestrator.writtenPaths(for: $0) } ?? []),
                    ignoring: backlogPathsInProjectRoot(for: item)
                )
                if let foreignNote = RunWorkEvidence.foreignDirtNote(paths: strayReport.foreign) {
                    backlogViewModel.appendNote(itemID: item.id, foreignNote)
                }
                if let stray = RunWorkEvidence.strayWorkRefusal(paths: strayReport.attributed) {
                    appendLog("Blocked: \(item.title) — \(stray)")
                    backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .blocked)
                    backlogViewModel.appendNote(itemID: item.id, stray)
                    logPhase(.itemEnd, [
                        ("item", item.id),
                        ("execution", execID),
                        ("outcome", "blocked"),
                        ("reason", stray),
                        ("branch", itemResult.branch),
                        ("strayPaths", String(strayReport.attributed.count)),
                    ], isError: true)
                    itemResult = ItemResult(id: item.id, title: item.title,
                                            outcome: .blocked(stray), duration: duration,
                                            branch: itemResult.branch)
                    results.append(itemResult)
                    recordItemResult(itemResult, executionID: execID)
                    continue
                }

                // Nil once the ending is decided, unless the run really is one
                // that achieved nothing: it is what counts the no-work streak,
                // restarts the agents on the assumption their sessions are dead,
                // and skips the coverage check below. A worker that changed
                // nothing *and said why* is none of those things — its session
                // plainly answered — so the claim path clears it.
                var noWorkSignal = workEvidence.missingSignal
                if let missing = noWorkSignal {
                    // Git says the run left nothing; the worker's own last words
                    // say why, and are the only thing that separates a session
                    // that died from one that read the code and correctly
                    // declined to redo an item already implemented. Recorded
                    // verbatim — nothing here reads a category out of them.
                    //
                    // Except for one thing, which is structure rather than
                    // category: a claim written in the shape CLAUDE.md asks for,
                    // carrying the evidence that makes it a claim. That has an
                    // ending of its own — see `RunWorkEvidence
                    // .AlreadyImplementedClaim` for why it needed one. The raw
                    // message is what is parsed, because `phrase` bounds it to
                    // 300 characters and a truncated object is not one.
                    let raw = await workerClosingMessage(executionID: execID)
                    let closing = RunClosingMessage.phrase(raw)
                    // Two shapes, one reader (`noWorkEnding`): a refuted premise
                    // — the worker measured the claim the item rests on and
                    // stopped — and the already-implemented claim. Either is an
                    // answer about the item rather than an attempt at it.
                    if let ending = Self.noWorkEnding(closingMessage: raw) {
                        appendLog("\(ending.headline): \(item.title) — \(ending.summary); "
                                  + "\(closing); awaiting your approval")
                        backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .awaitingApproval)
                        // The Notes are the whole interface at the gate: an item
                        // waiting there with no diff behind it has to say why,
                        // and say that nothing has checked the claim.
                        backlogViewModel.appendNote(itemID: item.id, ending.note)
                        // The gate is the point — nothing moves until a human
                        // looks, and here there is not even a diff for them to
                        // stumble across. Held rather than fired, so it goes out
                        // through `flushGateNotification` with every other
                        // summons this run raises.
                        pendingGateNotification = GateNotification(
                            title: "Approval needed in \(projectName ?? "this project")",
                            body: "\(item.id) — \(item.title) (\(ending.gateLabel))",
                            itemID: item.id
                        )
                        itemResult = ItemResult(id: item.id, title: item.title,
                                                outcome: ending.outcome, duration: duration,
                                                branch: itemResult.branch)
                        itemResult.closingMessage = closing
                        noWorkSignal = nil
                    } else {
                        appendLog("Blocked: \(item.title) — \(missing); \(closing); returned to Ready")
                        backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .ready)
                        // The Notes are where the next run and the human both look.
                        // Without this the item goes back to the pile saying only
                        // that nothing came of the last attempt.
                        backlogViewModel.appendNote(itemID: item.id,
                                                    "\(missing) — \(closing); returned to Ready")
                        itemResult = ItemResult(id: item.id, title: item.title,
                                                outcome: .blocked(missing), duration: duration,
                                                branch: itemResult.branch)
                        itemResult.closingMessage = closing
                    }
                }

                // Does the item's verify: cover what the run actually changed?
                // Asked only of a run whose work stands — a blocked or empty one
                // is already being turned back, and re-reporting it as a coverage
                // gap would bury the reason it was turned back.
                //
                // A gap blocks rather than warns: the point of a deterministic
                // check is that it can. The work is committed and the branch is
                // kept, so nothing is lost — someone widens the item's verify:
                // (or says why the path is exempt) and the diff is re-checked.
                if noWorkSignal == nil {
                    switch itemResult.outcome {
                    case .awaitingApproval, .done:
                        if let gap = await verifyCoverageGap(
                            item: item, detail: detail,
                            branch: itemResult.branch, isolated: session != nil, worktree: worktreePath
                        ) {
                            appendLog("Blocked: \(item.title) — \(gap)")
                            backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .blocked)
                            itemResult = ItemResult(id: item.id, title: item.title,
                                                    outcome: .blocked(gap), duration: duration,
                                                    branch: itemResult.branch)
                        }
                        // And the two Definition-of-Done rules the diff answers
                        // by itself (`DiffRules`): a row in docs/suite-status.md
                        // from an unrelated item blocks like a gap; Swift changed
                        // without a CHANGELOG.md line is noted on the item.
                        itemResult = await applyDiffRules(
                            item: item, itemResult: itemResult, duration: duration, isolated: session != nil)
                    // A claim run changed no files, so there is no diff for a
                    // verify to cover and nothing a gap could be reported
                    // against. It reaches here — unlike the ordinary empty run,
                    // which `noWorkSignal` turns back — only because clearing
                    // that signal is what keeps it out of the no-work streak.
                    case .blocked, .cancelled, .alreadyImplemented, .investigation, .usageLimitParked:
                        break
                    }
                }

                // A blocked run's work is committed and its worktree kept; this
                // is what tells anyone so. Without it the item goes back to the
                // pile reading only "review did not pass" and the next attempt
                // rebuilds a diff that already exists.
                let workLeftBehind = await reportWorkLeftBehind(
                    item: item, outcome: itemResult.outcome,
                    teardown: teardown, isolated: session != nil)

                // How much this run changed — read *before* the auto-merge
                // below, which folds the branch into `HEAD` and leaves the same
                // diff reading empty. It decides whether this run counts as
                // evidence when the size bands are computed (a run that changed
                // nothing says nothing about what an S costs) and whether it
                // counts against the item's retry ceiling. The kept worktree is
                // part of the question: a run that stalled or was capped holds
                // whatever teardown couldn't commit in there.
                let changedFileCount = await runChangedFileCount(
                    branch: itemResult.branch, worktree: worktreePath, isolated: session != nil)

                // Where the quality judge's diff starts — read here, before the
                // merge below folds the branch into `HEAD` and leaves `git
                // merge-base` answering the branch tip itself.
                let judgeDiffBase = await runDiffBase(
                    branch: itemResult.branch, isolated: session != nil)

                // The judge, asked here — before the merge folds the branch
                // in — scores the run and notes any scope deviation it names
                // as advisory; it never changes the outcome. `judgeOutcome` is
                // what `recordMetric` files below; it is never asked for twice.
                let reviewerRetriesSoFar = await reviewerRetries(executionID: execID)
                let judgeOutcome = await judgeBeforeMerge(
                    item: item, itemResult: itemResult, reviewerRetries: reviewerRetriesSoFar,
                    diffBase: judgeDiffBase, executionID: execID)

                // Auto-merge accepted work into main, gated on a clean merge + a
                // green verify of the merged tree (the objective bar — never the
                // judge's opinion). A failure leaves the item for a human.
                // What gated it, carried down to the metric record below. Nil
                // when no merge was attempted — a different fact from a merge
                // nothing checked, which is an empty plan.
                var mergeVerify: MergeVerifyPlan?
                /// Whether the branch actually landed, so the approval note can
                /// tell "approved, and the work is in main" from "approved, and
                /// the work is still sitting on a branch".
                var didAutoMerge = false
                // Why a merge that was attempted did not land, when one didn't.
                // Nil covers both "it landed" and "none was attempted" — the
                // gate resolution below only asks whether a merge *refused*,
                // because that is the one state an automatic approval must not
                // stamp Done over.
                var mergeRefusal: String?
                // Whether this run's gate is going to clear itself. Asked
                // *before* the merge, because the merge is what an approval
                // does — not something that happens on the way to deciding
                // whether there is one.
                //
                // It used to run the other way round, and that made
                // `approveReviewPassedRuns` unreachable whenever the merge
                // landed: the merge marked the item `done`, `gateResolution`
                // only acts on `.awaitingApproval`, so it fell straight through
                // to `.human` and did nothing. A project with auto-merge on and
                // the human gate *off* still merged to main with nobody
                // looking — which is what the ladder's "Every merge still waits
                // for a person at the approval gate" claimed could not happen.
                //
                // `mergeRefusal` is still fed to the real resolution below, so a
                // merge that was attempted and refused cannot be stamped Done.
                if Self.shouldAutoMerge(outcome: itemResult.outcome,
                                        hasBranch: itemResult.branch != nil,
                                        autoMergeOnApproval: autoMergeOnApproval,
                                        reviewPassed: reviewPassed,
                                        autoApproveReviewPassed: approveReviewPassedRuns) {
                    // The rail says `merge` for as long as the gate verifies,
                    // not only once it has answered — a gate is a step a person
                    // can watch, and the line below names what it decided.
                    logPhase(.merge, [("item", item.id), ("branch", itemResult.branch), ("phase", "verifying")])
                    let (merged, reason, plan, verifyOutput, landedCommit) = await attemptAutoMerge(for: item, session: session)
                    mergeVerify = plan
                    // On the result itself, so the run record and the history
                    // row answer "did it land" without a join against the merge
                    // ledger — thirty records on 2026-09-18 each read `done`
                    // with nothing to say which of them had shipped.
                    itemResult.merged = merged
                    itemResult.mergeCommit = landedCommit
                    logPhase(.merge, [
                        ("item", item.id),
                        ("branch", itemResult.branch),
                        ("merged", String(merged)),
                        // Which commands stood between this diff and main. A
                        // merge validated by a suite unrelated to what changed
                        // used to be invisible unless someone compared the diff
                        // with the project config by hand.
                        ("verify", plan.summary),
                        ("reason", merged ? nil : reason),
                    ])
                    // What the gate decided, filed against this run. The metric
                    // row is written further down — this happens first, which is
                    // exactly why the outcome is its own event and names the
                    // execution: `MergeOutcomeFold` joins the two whichever
                    // arrives first. `verifyOutput` rides along whenever a step
                    // needed a retry — a recovered merge as well as a refused
                    // one — since a merge nobody could otherwise reread ran on
                    // a scratch worktree already gone by the time this row is
                    // read.
                    recordMergeOutcome(itemID: item.id, merged: merged,
                                       reason: merged ? plan.summary : reason,
                                       executionID: execID, verifyOutput: verifyOutput, commit: landedCommit)
                    if let verifyOutput {
                        backlogViewModel.appendNote(itemID: item.id, verifyOutput)
                    }
                    if let landedCommit {
                        backlogViewModel.appendNote(itemID: item.id,
                                                    WorktreeManager.landedNote(commit: landedCommit, base: baseBranch))
                        // The merged tree that just passed the plan *is* the new
                        // base tip: it is green by the same measurement, so the
                        // next start does not spend a full merge-verify learning it.
                        baseHealthByTip[landedCommit] = WorktreeManager.BaseVerdict(sha: landedCommit, ok: true, reason: nil)
                    }
                    if merged {
                        // Deliberately *not* `markDone` here. The item stays at
                        // `.awaitingApproval` so `gateResolution` below is the
                        // one thing that ends it — writing the outcome here is
                        // exactly what used to consume the state the gate reads.
                        didAutoMerge = true
                        appendLog("Auto-merged \(item.id) into main (verify green: \(plan.summary))")
                        await tidyMergedBranch(itemID: item.id)
                        await refreshGateFreshnessIfPossible(backlog: backlogViewModel)
                    } else {
                        mergeRefusal = reason
                        appendLog("Not auto-merged \(item.id): \(reason) — left at Awaiting Approval for review")
                    }
                }

                // The PR half of ADR-0001: work that reached the gate is
                // published for review where review happens. After the
                // auto-merge above deliberately — a branch that just landed on
                // main has nothing left to open a pull request for, and one that
                // failed to land is exactly the work a human now has to look at.
                // A missing remote or `gh` skips it with a reason; the run has
                // already succeeded and must not be failed over a side effect.
                //
                // Opened, it is then *followed*: the checks are read until they
                // settle and a failing one goes back to the worker, so the
                // human below is called to a green pull request rather than to
                // a red one they have to fix themselves.

                // What those fix rounds cost. Charged to the item below with the
                // rest of its spend — they are work done for this item, and the
                // item's cap is what bounds them.
                var checksCostUSD = 0.0
                // And what the one pass over its review comments cost, charged
                // the same way and for the same reason.
                var commentsCostUSD = 0.0
                // What the human being summoned is told about the pull request,
                // when there is one to tell them about: the state of its checks,
                // then how its review threads were left.
                var gateDetails: [String?] = []
                if openPullRequest, case .awaitingApproval = itemResult.outcome {
                    // A run made with `useWorktree` off leaves no branch, and
                    // there is nothing to push — but that is a reason, not a
                    // reason to say nothing, so it goes down the same
                    // note/log/phase path as every other skip. `open` is not
                    // called for it: its first act is a subprocess, and it could
                    // only answer about the remote, not about the branch that
                    // isn't there.
                    let branch = itemResult.branch
                    let published: PullRequestPublisher.Outcome
                    if let branch {
                        published = await PullRequestPublisher.open(
                            projectRoot: projectRoot,
                            branch: branch, base: baseBranch,
                            title: PullRequestPublisher.title(for: item),
                            body: PullRequestPublisher.body(item: item, detail: detail)
                        )
                    } else {
                        published = PullRequestPublisher.noBranch
                    }
                    let note = PullRequestPublisher.note(for: published)
                    appendLog("\(item.id): \(note)")
                    // The Notes carry it either way — the URL when there is one,
                    // and why there isn't when there isn't. A run that quietly
                    // opened no PR is indistinguishable from one where the
                    // setting was off.
                    backlogViewModel.appendNote(itemID: item.id, note)
                    if case .opened(let url) = published { itemResult.pullRequestURL = url }
                    logPhase(.pullRequest, [
                        ("item", item.id),
                        ("branch", branch),
                        ("url", itemResult.pullRequestURL),
                        ("skipped", itemResult.pullRequestURL == nil ? note : nil),
                    ])
                    // Opening the pull request is half of what `openPullRequest`
                    // means; the other half is following it until it is green.
                    // A `.skipped` outcome has nothing to follow.
                    if case .opened(let url) = published, let branch {
                        let followed = await followPullRequestChecks(
                            item: item, branch: branch, url: url, executionID: execID
                        )
                        checksCostUSD = followed.costUSD
                        gateDetails.append(PullRequestChecks.gateDetail(for: followed.outcome))
                        let checksNote = PullRequestChecks.note(for: followed.outcome)
                        appendLog("\(item.id): \(checksNote)")
                        backlogViewModel.appendNote(itemID: item.id, checksNote)

                        // The last stage before the human: the pull request's
                        // review threads, read once and each one either fixed or
                        // answered. Only behind green checks — a red pull request
                        // is going to a human over the check anyway, and spending
                        // the item's remaining cap arguing with a bot about a
                        // branch that doesn't build buys that human nothing.
                        if followed.outcome.isGreen {
                            let addressed = await addressPullRequestComments(
                                item: item, detail: detail, branch: branch, url: url,
                                executionID: execID, alreadySpentUSD: checksCostUSD
                            )
                            commentsCostUSD = addressed.costUSD
                            gateDetails.append(
                                PullRequestComments.gateDetail(for: addressed.outcome))
                            let commentsNote = PullRequestComments.note(for: addressed.outcome)
                            appendLog("\(item.id): \(commentsNote)")
                            backlogViewModel.appendNote(itemID: item.id, commentsNote)
                        }
                    }
                }
                // The approval gate itself, resolved by this project's setting
                // rather than by a person (`approveReviewPassedRuns`). Last,
                // deliberately: everything an approval feeds — the auto-merge,
                // the pull request and its checks — has already run against the
                // item as it stood at the gate, so nothing about merging or
                // publishing changes shape because the gate cleared itself.
                switch Self.gateResolution(outcome: itemResult.outcome,
                                           reviewPassed: reviewPassed,
                                           autoApproveReviewPassed: approveReviewPassedRuns,
                                           mergeRefusal: mergeRefusal) {
                case .automatic:
                    // Said in three places on purpose: the log for whoever
                    // watches the run, the item's Notes for whoever reads the
                    // backlog in the morning, and the run record for anything
                    // counting the night. A morning that can't tell "a human
                    // accepted this" from "the setting accepted this" is the
                    // whole reason the setting records itself.
                    let note = Self.automaticApprovalNote(
                        unmergedBranch: didAutoMerge ? nil : itemResult.branch)
                    appendLog("Approved automatically: \(item.title) — \(note)")
                    backlogViewModel.approve(itemID: item.id, closure: .autoApproved)
                    backlogViewModel.appendNote(itemID: item.id, note)
                    itemResult.outcome = .done
                    itemResult.approval = .automatic
                    // Nobody left to summon: this item's gate is closed.
                    pendingGateNotification = nil
                case .human:
                    break
                }
                // The summons held since the gate opened. Fired here — after the
                // pull request has been followed to a terminal state — so a
                // human is only called to a PR that is green, or to one the loop
                // has given up on and named.
                flushGateNotification(detail: Self.joinedGateDetail(gateDetails))

                itemResult.executionID = execID
                results.append(itemResult)
                recordItemResult(itemResult, executionID: execID)
                // Charge the item to the session budget here — not inside
                // recordMetric, which no-ops without a metric store and would
                // otherwise leave the session cap unenforced.
                let completedAt = Date()
                let spans = await runTurnSpans()
                // The item's own execution, plus the CI fix rounds that followed
                // its pull request and the one pass over its review comments.
                // Those are separate executions of the same worker doing this
                // item's work, so a total that left them out would under-report
                // the item to the session budget, the day's ledger and every
                // calibration that reads them back.
                let itemCost = Self.costOfTurnSpans(spans, executionID: execID)
                             + checksCostUSD + commentsCostUSD
                let costByRole = Self.costByRole(spans, executionID: execID)
                let runUsage = Self.usageOfTurnSpans(spans, executionID: execID)
                costGovernor.chargeItem(itemCost)
                // And to the portfolio's day. A $0 here is charged the item's
                // prediction rather than nothing, so spend the app never saw a
                // turn for still counts against the ceiling — *unless* git says
                // the run produced nothing, in which case there was no spend to
                // stand in for and it is charged nothing. An item that never
                // reached this point (the `catch` below) spent nothing and is
                // charged nothing.
                let dailyCharge = chargeDailyBudget(cost: itemCost, item: item,
                                                    evidence: workEvidence)
                await recordMetric(
                    item: item,
                    itemResult: itemResult,
                    startTime: startTime,
                    completedAt: completedAt,
                    costUSD: itemCost,
                    usage: runUsage,
                    openingContext: Self.openingContextByRole(spans, executionID: execID),
                    changedFileCount: changedFileCount,
                    judgeOutcome: judgeOutcome,
                    mergeVerify: mergeVerify,
                    executionID: execID
                )
                // After `recordMetric` so the judge's score — filed on the metric
                // record moments ago — lands on the same line as the outcome it
                // scored, rather than in a second line the reader has to join.
                let head: [(String, String?)] = [
                    ("item", item.id),
                    ("execution", execID),
                    ("outcome", Self.outcomeString(itemResult.outcome)),
                    ("durationSec", Self.secondsField(duration)),
                    ("costUSD", Self.usdField(itemCost)),
                    ("costByRole", Self.roleCostField(costByRole)),
                ]
                let tail: [(String, String?)] = [
                    // The forecast this item was started on, and how wrong it
                    // was. Logged on the same line as the actual because a
                    // prediction nobody ever compares to an outcome cannot get
                    // better — the pair is the error signal.
                    ("predictedUSD", costGovernor.currentItemPrediction.map { Self.usdField($0.usd) }),
                    ("predictionSource", costGovernor.currentItemPrediction?.source.rawValue),
                    ("costErrorUSD", costGovernor.currentItemPrediction.map {
                        Self.usdField(itemCost - $0.usd)
                    }),
                    ("changedFiles", changedFileCount.map(String.init)),
                    ("chargedUSD", dailyCharge.map { Self.usdField($0.amountUSD) }),
                    ("chargeBasis", dailyCharge?.basis.rawValue),
                    ("spentTodayUSD", dailyCharge.map { _ in Self.usdField(dailyBudget.spentUSD) }),
                    ("branch", itemResult.branch),
                    // `automatic` when the run cleared the item's approval gate
                    // itself, absent otherwise. The unified log is what a
                    // marathon is reconstructed from, and `outcome=done` alone
                    // does not say whether anybody agreed to it.
                    ("approval", itemResult.approval?.rawValue),
                    ("workLeftBehind", workLeftBehind?.summary),
                    // On a run that produced nothing: what the worker said as it
                    // finished, on the same line as the ending it explains.
                    // Absent on every other run — see `ItemResult.closingMessage`.
                    ("closingMessage", itemResult.closingMessage), ("reason", Self.endingReason(itemResult.outcome)),
                    // A score when there is one, else why there isn't. The
                    // unified log is all that's left to reconstruct a marathon
                    // from, and a run of `quality=unavailable:no-reply` names an
                    // infrastructure failure that a field going quiet does not.
                    ("quality", Self.qualityField(latestMetric(itemID: item.id))),
                ]
                logPhase(.itemEnd, head + Self.usageFields(runUsage) + tail)

                // What the end-of-run distiller learns from. Recorded for every
                // item rather than for the ones that look interesting — it is
                // `RunKnowledgeDistiller` that decides whether the run was worth
                // a call, and a blocked item is explained by the ones around it.
                recordRunKnowledgeEvent(item: item, result: itemResult, costUSD: itemCost)

                // An item that produced nothing was run against a session that had
                // already died, so the next item must not be handed to the same
                // one: restart it first. And bound that — a restart that doesn't
                // fix the cause must not become a restart loop chewing through the
                // backlog, so a run of no-work items pauses and says why.
                consecutiveNoWorkBlocks = Self.noWorkStreak(previous: consecutiveNoWorkBlocks,
                                                            signal: noWorkSignal)
                if let noWorkSignal {
                    if Self.shouldStopForNoWork(streak: consecutiveNoWorkBlocks) {
                        appendLog("Circuit breaker: \(consecutiveNoWorkBlocks) items in a row produced no work "
                                  + "(\(noWorkSignal)) — restarting the agents didn't help; pausing. "
                                  + "Relaunch the app, then re-run.")
                        logPhase(.runPause, [
                            ("reason", "circuit-breaker"),
                            ("cause", noWorkSignal),
                            ("noWorkBlocks", String(consecutiveNoWorkBlocks)),
                            ("resumeAt", String(index + 1)),
                        ], isError: true)
                        orchestrator.publishEvent(KiteloopEvent(source: "Autopilot", type: .workflowFailed, payload: [
                            "reason": "agent sessions dead — \(consecutiveNoWorkBlocks) consecutive no-work items "
                                    + "(\(noWorkSignal)); paused"
                        ]))
                        shouldStop = true
                        status = .paused
                        return
                    }
                    await restartAgentsAfterNoWork(itemID: item.id, signal: noWorkSignal, costUSD: itemCost)
                }

                if stopsAfter(itemResult, at: index) { return }
            } catch {
                appendLog("Error: \(item.title): \(error.localizedDescription)")
                backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .blocked)
                var itemResult = ItemResult(id: item.id, title: item.title, outcome: .blocked(error.localizedDescription), duration: 0)
                let teardown = await session?.end(outcome: itemResult.outcome); noteTeardownCommit(teardown, item: item)
                itemResult.branch = teardown?.branch
                // An item that errored out still had a worker in its worktree —
                // whatever it finished before the error is worth naming for the
                // same reason a blocked run's is.
                let workLeftBehind = await reportWorkLeftBehind(
                    item: item, outcome: itemResult.outcome,
                    teardown: teardown, isolated: session != nil)
                results.append(itemResult)
                recordItemResult(itemResult, executionID: nil)
                logPhase(.itemEnd, [
                    ("item", item.id),
                    ("outcome", "error"),
                    ("reason", error.localizedDescription),
                    ("branch", itemResult.branch),
                    ("workLeftBehind", workLeftBehind?.summary),
                ], isError: true)
            }
        }

        await refreshStaleGateItems()
        await distillRunKnowledge()
        settleStatusAfterRun()
        appendLog("Run complete: \(runQueue.count) items processed")
        logPhase(.runEnd, [
            ("status", "complete"),
            ("run", currentRunRecord?.id),
            ("items", String(runQueue.count)),
            ("done", String(outcomeCount(prefix: "done"))),
            ("awaitingApproval", String(outcomeCount(prefix: "awaiting-approval"))),
            // Counted on its own line rather than folded into either neighbour:
            // these items are at the approval gate like the ones above, but with
            // no diff behind them, and a marathon reconstructed from this log
            // would otherwise show them nowhere at all.
            ("alreadyImplemented",
             String(outcomeCount(prefix: TaskMetricRecord.alreadyImplementedOutcome))), ("investigation", String(outcomeCount(prefix: TaskMetricRecord.investigationOutcome))),
            ("blocked", String(outcomeCount(prefix: "blocked"))),
            ("cancelled", String(outcomeCount(prefix: "cancelled"))),
            ("durationSec", currentRunRecord.map { Self.secondsField(Date().timeIntervalSince($0.startedAt)) }),
        ])
        onRunFinished?()
    }

    /// How many of this run's results ended in the given outcome. Matches on
    /// prefix because `blocked` carries its reason in the same string.
    private func outcomeCount(prefix: String) -> Int {
        results.filter { Self.outcomeString($0.outcome).hasPrefix(prefix) }.count
    }

    /// Charges a finished item to this project's day **and** the portfolio's, and
    /// says so in the run log with what's left of each — a run that later refuses
    /// to start has to be traceable to the runs that spent the day. Nil (and
    /// silent) when no ledger is attached, which is the "no daily budget at all"
    /// case.
    ///
    /// The charge is attributed to `projectPath`: without it the spend lands on
    /// the portfolio alone and this project's own ceiling has nothing to be
    /// enforced against.
    ///
    /// `evidence` is what git said this run left behind; it decides whether an
    /// unreported cost is a stand-in worth charging or a run that spent nothing.
    @discardableResult
    private func chargeDailyBudget(
        cost: Double,
        item: BacklogItem,
        evidence: RunWorkEvidence.Verdict? = nil
    ) -> DailySpendLedger.Charge? {
        guard let dailySpendLedger else { return nil }
        let charge = dailySpendLedger.charge(costUSD: cost,
                                             estimateUSD: predictedCostUSD(for: item),
                                             evidence: evidence,
                                             project: projectPath)
        let budget = dailyBudget
        var line = "Daily spend: \(budget.text)"
        if let note = charge.note { line += " (\(note))" }
        if let remaining = budget.remainingUSD {
            line += String(format: " — $%.2f left today", remaining)
        }
        // Only when the project has a ceiling of its own: otherwise this is the
        // portfolio's number written twice.
        let own = projectDailyBudget
        if own.budgetUSD != nil {
            line += " · this project: \(own.text)"
            if let remaining = own.remainingUSD {
                line += String(format: " ($%.2f left)", remaining)
            }
        }
        appendLog(line)
        return charge
    }

    /// Whether the reviewer may run — the gate `continueFromCurrentIndex`
    /// installs on the orchestrator for the item in flight.
    ///
    /// A worker whose session died walks the graph without writing anything, and
    /// the reviewer that follows has no diff to read: not one of its dimensions
    /// has any evidence behind it, and "passed" is the one verdict it cannot
    /// honestly return. It returned it anyway on 2026-08-09 — six and a half
    /// minutes of worker, nothing written, "review passed; awaiting your
    /// approval" — and only the post-teardown check kept an empty change from a
    /// human. This asks git the same question one step earlier, so an empty run
    /// never buys the more expensive half of itself.
    ///
    /// Only an isolated run's *empty-diff* signal can be judged: a live-tree
    /// run's edits are indistinguishable from a human's, so there is no
    /// evidence for `no-work-before-review` and the reviewer is never stopped
    /// for it. Nothing is committed yet at this point — teardown is what
    /// commits — so an isolated run's work, if there is any, is sitting
    /// uncommitted in the worktree, which is what `inspectInFlight` reads.
    private func allowReviewerToRun(
        executionID: String,
        session: WorktreeSession?
    ) async -> Bool {
        // A worker that ran out of turns handed off unfinished work: not a
        // verify failure, and not a diff for the reviewer. Asked first, so it
        // is what the run ends saying.
        await readWorkerTurns(executionID: executionID)
        if let turns = workerCutShortTurns, runQueue.indices.contains(currentIndex) {
            let cutShort = noteWorkerCutShort(runQueue[currentIndex], turns: turns, backlog: backlogViewModel)
            return await closeReviewGate(cutShort, cause: "worker-turn-cap", executionID: executionID)
        }
        guard let session else {
            return await verifyThenOpenReviewGate(executionID: executionID, session: nil)
        }
        let verdict = await RunWorkEvidence.inspectInFlight(
            projectRoot: projectRoot,
            branch: session.branch,
            worktree: session.path,
            isolated: true
        )
        guard let missing = verdict.missingSignal else {
            return await verifyThenOpenReviewGate(executionID: executionID, session: session)
        }
        return await closeReviewGate(missing,
                                     cause: "no-work-before-review",
                                     executionID: executionID)
    }

    /// The last gate before the reviewer, and the only place the app itself
    /// runs the item's `verify:` on the run's own tree.
    ///
    /// Until this existed nothing but the worker ever ran it, so the one thing
    /// the whole gate stands on was known only as the worker's account of it —
    /// and on 2026-09-08 a run reached the approval gate with its own new unit
    /// test failing deterministically on its branch, with no record anywhere
    /// able to say whether the verify had run at all. Now the exit status, the
    /// command, the tree it ran in and the tail of its output are measured
    /// here, kept on the run (`lastVerifyVerdict` → the metric record and the
    /// control API's run result) and written to the item's Notes beside what
    /// the review and the merge gate write there.
    ///
    /// A non-zero status ends the run at this gate: a reviewer cannot honestly
    /// pass a diff whose own verify is red, and rubric 1 says so. An item that
    /// declares no `verify:` has nothing to measure and is let through exactly
    /// as before.
    private func verifyThenOpenReviewGate(executionID: String, session: WorktreeSession?) async -> Bool {
        guard await verifyAllowsReview(worktree: session?.path, executionID: executionID,
                                       timeout: verifyTimeout) else { return false }
        return await openReviewGate(executionID: executionID, session: session)
    }

    /// The gate's answer about the verify alone: true when the review may go
    /// ahead — it was green, or the item declares none to run — and false when
    /// it was red, in which case the gate is already shut with the verdict's
    /// own words and the run ends here.
    private func verifyAllowsReview(worktree: URL?, executionID: String,
                                    timeout: TimeInterval) async -> Bool {
        guard let verdict = await measureVerifyForRecord(worktree: worktree, timeout: timeout),
              !verdict.passed else { return true }
        return await closeReviewGate(verdict.signal, cause: "verify-failed", executionID: executionID)
    }

    /// Runs the item's `verify:` in the tree the run's work is sitting in and
    /// records what it answered. Nil when there is nothing to run — no item in
    /// flight, no declared verify, or no directory to run it in — which is not
    /// the same as a verify that passed, and is why the field stays nil rather
    /// than reading as an exit status of 0.
    ///
    /// The command and the tree are `verifyRun(for:detail:worktree:)`'s — the
    /// same pair the salvage re-check runs, so the two can never judge a tree
    /// differently, and with the builds pointed at the tree's own build
    /// directory rather than at the DerivedData the launching Xcode shares.
    ///
    /// `timeout` is `verifyTimeout` — the gate's own clock, passed in rather
    /// than left to the shell helper's fixed default, so the two places that
    /// run this command hold it to the same deadline. It is logged with the
    /// command, because "timed out before it answered" is only readable
    /// against how long it was given.
    private func measureVerifyForRecord(worktree: URL?, timeout: TimeInterval) async -> RunVerifyVerdict? {
        guard runQueue.indices.contains(currentIndex) else { return nil }
        let item = runQueue[currentIndex]
        guard let verdict = await measureVerify(item: item,
                                                detail: backlogViewModel?.loadDetail(for: item),
                                                worktree: worktree, timeout: timeout,
                                                announcing: "Verifying \(item.id) before review")
        else { return nil }
        appendLog(verdict.passed
            ? "Verify passed for \(item.id) — letting the review run"
            : "\(verdict.signal) for \(item.id) — the review does not run")
        return verdict
    }

    /// Runs the item's verify once and writes down what it answered — the body
    /// both the pre-review gate and the salvage re-check are, so a verify that
    /// decides a run is measured the same way and held to the same clock
    /// wherever it is run from. Nil when there is nothing to run.
    ///
    /// The salvage re-check had this backwards until 2026-09-08: it answered a
    /// bare true/false through the shell helper's fixed default, so the one run
    /// whose acceptance rests entirely on a verify was the only run with no
    /// verify on its record — and a project whose build outgrew that default
    /// had its work discarded as "nothing to salvage" by a command that was
    /// killed rather than answered.
    ///
    /// `announcing` is the caller's own phrase for what it is about to run; the
    /// deadline and the command are appended to it, because "timed out before
    /// it answered" is only readable against how long it was given.
    private func measureVerify(item: BacklogItem, detail: BacklogItemDetail?,
                               worktree: URL?, timeout: TimeInterval,
                               announcing: String) async -> RunVerifyVerdict? {
        guard let (command, directory) = verifyRun(for: item, detail: detail, worktree: worktree)
        else { return nil }
        appendLog("\(announcing) (deadline \(Int(timeout / 60))m) — \(command)")
        // Before the command, not after it: the rail's `verify` step is what
        // the run is on for as long as this takes, and the line is also what
        // refreshes `lastActivityAt` so a long build doesn't read as stale.
        logPhase(.verify, Self.verifyPhaseFields(itemID: item.id, command: command, timeout: timeout))
        let root = projectRoot
        let result = await Task.detached {
            WorktreeManager.runShellCapturingStatus(command, in: directory,
                                                    timeout: timeout, projectRoot: root)
        }.value
        let verdict = RunVerifyVerdict(
            exitStatus: result.status,
            command: command,
            directory: directory.path(percentEncoded: false),
            outputTail: RunVerifyVerdict.tail(of: result.output),
            timedOut: result.timedOut
        )
        lastVerifyVerdict = verdict
        backlogViewModel?.appendNote(itemID: item.id, Self.verifyNote(verdict))
        return verdict
    }

    /// The verify verdict as one note on the item, beside what the review and
    /// the merge gate write there — the record a person reads first when a
    /// green gate is in doubt. Both endings are written, not only the red one:
    /// a pass nobody recorded is exactly the gap this item was filed for.
    static func verifyNote(_ verdict: RunVerifyVerdict) -> String {
        var note = verdict.passed
            ? "verify passed (exit 0)"
            : verdict.signal
        note += " — `\(verdict.command)` in `\(verdict.directory)`"
        guard !verdict.outputTail.isEmpty else { return note }
        return note + "\n\n```\n" + verdict.outputTail + "\n```"
    }

    /// Opens the gate and, before letting the reviewer run, writes the
    /// per-file facts block (`ReviewerDiffFacts`) into the execution's state
    /// so the reviewer's own prompt — rendered right after this returns, in
    /// `Orchestrator.activateWorkflowNode` — carries it. A block that could
    /// not be built (no directory to read) leaves state untouched; the
    /// reviewer's prompt template already tolerates the key being absent.
    private func openReviewGate(executionID: String, session: WorktreeSession?) async -> Bool {
        reviewGate = .open
        if let block = await reviewerDiffFactsBlock(directory: session?.path) {
            await orchestrator?.workflowEngine.mergeState(executionID: executionID,
                                                          updates: ["reviewerDiffFacts": .string(block)])
        }
        // And the worker's own check of the item's premise, when its handoff
        // carried one: the reviewer checks a `refuted` line against the code
        // the way it checks a criterion. Read off the worker's step, which is
        // complete by the time the reviewer's node is activated.
        if let report = PremiseReport.parse(await workerClosingMessage(executionID: executionID)) {
            await orchestrator?.workflowEngine.mergeState(executionID: executionID,
                                                          updates: ["premiseReport": .string(report.text)])
        }
        return true
    }

    /// The reviewer's per-file facts block, read from the working tree
    /// directly: nothing is committed until teardown (see
    /// `allowReviewerToRun`'s own doc comment), so a run's whole diff — every
    /// tracked edit and every brand-new file alike — is sitting uncommitted
    /// right where the worker left it. `directory` is the isolated run's
    /// worktree, or nil for a live-tree run — in which case the project root
    /// itself is read.
    ///
    /// Internal, not private: tested directly against a `ScriptedSubprocessRunner`,
    /// the way `runDiffStat` and `runDiffBase` already are.
    ///
    /// Nil when there is no directory to read.
    func reviewerDiffFactsBlock(directory: URL?) async -> String? {
        guard let directory = directory ?? projectRoot else { return nil }
        let root = directory.path(percentEncoded: false)
        let (tracked, untrackedPaths): ([ReviewerDiffFacts.ChangedFile], [String]) =
            await Task.detached(priority: .userInitiated) {
                let numstat = SubprocessOutput.git(["-C", root, "diff", "--numstat", "HEAD"])
                let tracked = numstat.status == 0 ? ReviewerDiffFacts.parseNumstat(numstat.output) : []
                let status = SubprocessOutput.git(["-C", root, "status", "--porcelain"])
                let untracked: [String] = status.status == 0 ? status.output
                    .split(whereSeparator: \.isNewline)
                    .compactMap { line -> String? in
                        guard line.hasPrefix("??") else { return nil }
                        return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    } : []
                return (tracked, untracked)
            }.value
        let newFiles = Self.newFileLineCounts(directory: root, paths: untrackedPaths)
        let changedFiles = tracked + newFiles
        // The same list, kept for the drift check a rejecting round's findings
        // are read against (`ReviewFindings.markDrift`) — one `git diff` this
        // round, not a second one just for that.
        lastReviewedChangedFiles = Set(changedFiles.map { GroundingCheck.SourceIndex.normalize($0.path) })
        return ReviewerDiffFacts.block(changedFiles: changedFiles)
    }

    /// Untracked new files `git diff --numstat` never lists — they are in
    /// neither the index nor a commit — read directly so a run's new file
    /// counts among the changed files reported to the reviewer, the same as a
    /// modified one. `added` is counted as numstat counts it
    /// (`ReviewerDiffFacts.newFileLineCount`), nil for a file that couldn't be
    /// read or holds a NUL byte, matching numstat's own placeholder for a
    /// binary file; `deleted` is always 0, since a file that did not exist
    /// before deleted nothing.
    private static func newFileLineCounts(directory: String, paths: [String]) -> [ReviewerDiffFacts.ChangedFile] {
        paths.map { path in
            let data = try? Data(contentsOf: URL(fileURLWithPath: directory + "/" + path))
            let added = data.flatMap(ReviewerDiffFacts.newFileLineCount)
            return ReviewerDiffFacts.ChangedFile(path: path, added: added, deleted: 0)
        }
    }

    /// Shuts the pre-review gate: record why, say so in the log and the run
    /// phases, and cancel the workflow so the reviewer never activates.
    ///
    /// One exit for every refusal, so a run stopped for running out of turns
    /// is recorded the same shape as one stopped for producing nothing — same
    /// gate state, same abort phase, differing only in the `cause` an operator
    /// greps for.
    private func closeReviewGate(_ signal: String,
                                 cause: String,
                                 executionID: String) async -> Bool {
        reviewGate = .closed(signal: signal)
        let itemID = runQueue.indices.contains(currentIndex) ? runQueue[currentIndex].id : nil
        appendLog("Skipping review — \(signal); ending the run here")
        logPhase(.itemAbort, [
            ("item", itemID),
            ("execution", executionID),
            ("node", "reviewer"),
            ("cause", cause),
            ("reason", signal),
        ], isError: true)
        await orchestrator?.cancelWorkflow(executionID: executionID)
        return false
    }

    /// Restarts the worker and reviewer sessions after an item produced nothing,
    /// so the next item isn't handed to a process that has already died.
    ///
    /// Fresh sessions rather than resumed ones: a session that died mid-run is
    /// the thing being replaced, and resuming its id is one more way for the
    /// restart to fail. An isolated run's next item restarts them again into its
    /// own worktree — this one covers the live-tree run, and the case where that
    /// restart is itself what failed.
    ///
    /// Every restart is logged with the signal that caused it (`agent.restart`),
    /// because "why did this agent restart four times" has to be answerable from
    /// the run log afterwards. A restart that throws is logged and left: the
    /// breaker above is what stops the run if it keeps happening.
    private func restartAgentsAfterNoWork(itemID: String, signal: String, costUSD: Double) async {
        guard let orchestrator else { return }
        for agentID in [workerAgentID, reviewerAgentID].compactMap({ $0 }) {
            let workspace = orchestrator.agents.first { $0.id == agentID }?.workspacePath
            guard let cwd = projectRoot ?? workspace.flatMap({
                $0.isEmpty ? nil : URL(fileURLWithPath: $0)
            }) else {
                appendLog("Could not restart agent \(agentID) — no working directory")
                logPhase(.agentRestart, [
                    ("item", itemID), ("agent", agentID), ("cause", signal),
                    ("restarted", "false"), ("error", "no working directory"),
                ], isError: true)
                continue
            }
            orchestrator.stopAgent(agentID)
            do {
                try await orchestrator.startAgent(agentID, cwd: cwd)
                appendLog("Restarted agent session for \(agentID) — \(signal)")
                logPhase(.agentRestart, [
                    ("item", itemID),
                    ("agent", agentID),
                    ("cause", signal),
                    ("restarted", "true"),
                    ("streak", String(consecutiveNoWorkBlocks)),
                    // Corroboration only — the git signal above is the trigger.
                    ("costUSD", Self.usdField(costUSD)),
                ])
            } catch {
                appendLog("Failed to restart agent session for \(agentID): \(error.localizedDescription)")
                logPhase(.agentRestart, [
                    ("item", itemID), ("agent", agentID), ("cause", signal),
                    ("restarted", "false"), ("error", error.localizedDescription),
                ], isError: true)
            }
        }
    }

    /// Restarts whichever of the pair is sitting on a session that was started
    /// for a human, so the process this item is handed to is one an unattended
    /// run spawned — which is also what decides whether the agent keeps a
    /// self-maintained memory outside Kiteloop's gates (see
    /// `ClaudeCodeCLIRuntime.sessionEnvironment(_:unattended:)`).
    ///
    /// Fires at most once a run in practice: after it, both sessions are ones an
    /// unattended run started, and a session an agent has not sent through has
    /// spawned no process yet — which is also why an isolated run restarting the
    /// pair into its worktree a moment later costs nothing. An agent with no
    /// session at all is left alone: the next `startAgent` makes one on the
    /// right terms anyway.
    private func replaceAttendedSessions(itemID: String) async {
        guard let orchestrator, let projectRoot else { return }
        for agentID in [workerAgentID, reviewerAgentID].compactMap({ $0 })
        where orchestrator.liveSessionIsUnattended(for: agentID) == false {
            orchestrator.stopAgent(agentID)
            do {
                try await orchestrator.startAgent(agentID, cwd: projectRoot)
                appendLog("Restarted agent session for \(agentID) — it was started for a chat, "
                          + "and an unattended agent keeps no Claude Code memory of its own")
                logPhase(.agentRestart, [
                    ("item", itemID), ("agent", agentID), ("cause", "attended-session"),
                    ("restarted", "true"),
                ])
            } catch {
                appendLog("Failed to restart agent session for \(agentID): \(error.localizedDescription)")
                logPhase(.agentRestart, [
                    ("item", itemID), ("agent", agentID), ("cause", "attended-session"),
                    ("restarted", "false"), ("error", error.localizedDescription),
                ], isError: true)
            }
        }
    }

    /// Stops the session on a spent budget: the queue keeps its remaining items
    /// and `resume()` continues from `resumeAt`, so nothing is silently dropped.
    /// Whether the run stops once `result`, item `index`, is finished — and
    /// if so, it has been stopped. Two reasons, both about the account rather
    /// than the item: its usage limit refused the run, or the session's spend
    /// reached its cap.
    private func stopsAfter(_ result: ItemResult, at index: Int) -> Bool {
        // The account can make no model call until the limit lifts, so the
        // next item would only learn the same thing. The run ends rather than
        // pausing: a paused project is one the scheduler leaves for a person,
        // and the parked item, back in `ready` at its place in the queue, is
        // what its first start after the reset picks up.
        if case .usageLimitParked(let until) = result.outcome {
            endRunForUsageLimit(until: until)
            return true
        }
        guard let pause = costGovernor.takeSessionPause() else { return false }
        // This item is finished — resume should start at the next one.
        pauseForSessionCap(pause, resumeAt: index + 1)
        return true
    }

    /// Ends the run on a usage-limit park; nothing queued behind the parked
    /// item is started into the same wall.
    private func endRunForUsageLimit(until: Date) {
        let resumes = UsageLimitStop(resetsAt: until, window: nil, resetReported: true).resumeText(now: Date())
        appendLog("Usage limit — ending the run; scheduled runs resume \(resumes)")
        logPhase(.runEnd, [
            ("status", "usage-limit"),
            ("run", currentRunRecord?.id),
            ("resetAt", ISO8601DateFormatter().string(from: until)),
        ], isError: true)
        releaseQueue()
    }

    /// A run that ended badly while the account's usage limit stands: the
    /// item back to `ready` with a note saying when it resumes, and the
    /// scheduler told. Nil when no limit stands — an ordinary failure.
    private func parkIfUsageLimited(_ item: BacklogItem, duration: TimeInterval,
                                    backlog: BacklogViewModel) -> ItemResult? {
        let now = Date()
        guard let limit = orchestrator?.usageLimit(standingAt: now) else { return nil }
        let resumes = limit.resumeText(now: now)
        let source = limit.resetReported ? "the CLI's reset time" : "no reset time given; the 5-hour session window"
        appendLog("Usage limit — \(item.title) parked; resumes \(resumes)")
        backlog.appendNote(itemID: item.id,
                           "Usage limit hit — parked back to Ready, no retry charged; resumes \(resumes) (\(source)).")
        backlog.updateItemStatus(itemID: item.id, newStatus: .ready)
        logPhase(.itemParked, [
            ("item", item.id),
            ("window", limit.window),
            ("resetAt", ISO8601DateFormatter().string(from: limit.resetsAt)),
            ("resetReported", String(limit.resetReported)),
        ])
        onUsageLimitParked?(limit)
        return ItemResult(id: item.id, title: item.title, outcome: .usageLimitParked(until: limit.resetsAt),
                          duration: duration)
    }

    private func pauseForSessionCap(_ pause: CostGovernor.SessionPause, resumeAt index: Int) {
        currentIndex = index
        appendLog(pause.logLine)
        logPhase(.runPause, [
            ("reason", pause.eventReason),
            ("source", "session-cap"),
            ("spentUSD", pause.spentText),
            ("resumeAt", String(index)),
        ], isError: true)
        orchestrator?.publishEvent(KiteloopEvent(
            source: "Autopilot",
            type: .workflowFailed,
            payload: [
                "reason": pause.eventReason,
                "spentUSD": pause.spentText,
            ]
        ))
        shouldStop = true
        status = .paused
    }

    /// Most recent recorded metric for an item (for the control API to report
    /// the quality score alongside a run result).
    func latestMetric(itemID: String) -> TaskMetricRecord? {
        metricStore?.records.last { $0.itemID == itemID }
    }

    /// The record **this run** wrote, addressed by execution id. Deliberately not
    /// `latestMetric(itemID:)`: an item that has run before has records the
    /// current run did not write, and reporting one of those as this run's cost
    /// would charge it spend that belongs to a different attempt. No record means
    /// no cost is attributable — not a cost of zero.
    func metric(executionID: String) -> TaskMetricRecord? {
        metricStore?.records.last { $0.executionID == executionID }
    }

    /// The item's own `verify:` and the detail frontmatter's are both declared
    /// and both run (`declaredVerifyCommands` unions them), but a human
    /// editing one without noticing the other still stands is exactly what
    /// cost two runs on 2026-08-26. Advisory, not a refusal — every item here
    /// already passed the Definition-of-Ready gate.
    private func surfaceVerifySourceDisagreements(for items: [BacklogItem]) {
        guard let backlogViewModel else { return }
        for item in items {
            guard let disagreement = Self.verifySourceDisagreement(
                item: item, detail: backlogViewModel.loadDetail(for: item)) else { continue }
            appendLog("\(item.id) — \(disagreement)")
            backlogViewModel.appendNote(itemID: item.id, disagreement)
        }
    }

    /// Writes a pickup refusal to the grooming ledger. The unified log already
    /// carries it, but only until the stream is rotated and only for whoever is
    /// tailing it — the ledger is what the portfolio report reads days later to
    /// say *why* a patch of grooming went bad. Silent without a project identity:
    /// a verdict that can't say which project it belongs to isn't reportable.
    private func recordCheckFailure(_ item: BacklogItem, check: String, reason: String) {
        guard let projectPath, let projectName else { return }
        groomingLedger.recordCheckFailure(itemID: item.id, projectPath: projectPath,
                                          projectName: projectName, check: check, reason: reason)
    }

    /// Writes a pickup refusal to the **run** ledger, which is the one the retry
    /// ceiling counts.
    ///
    /// The grooming ledger and the run log already say a gate refused the item,
    /// and neither is countable: the ceiling is deliberately read off recorded
    /// attempts, so an attempt with no row in `task-metrics.jsonl` is one it
    /// cannot see. That is the hole this closes — a run that started and
    /// produced nothing was bounded, an item the gate turned away was not,
    /// though both are the item failing to advance.
    ///
    /// Silent without a store or a project identity, on the same terms as
    /// `recordCheckFailure`: a row that can't say which project it belongs to
    /// would be counted against whichever project shares the item's id.
    private func recordPickupRefusal(_ item: BacklogItem, _ refusal: RetryCeiling.PickupRefusal) {
        guard let metricStore, let projectPath, let projectName else { return }
        let detail = backlogViewModel?.loadDetail(for: item)
        let epic = backlogViewModel?.backlogFile?.sections
            .first { $0.items.contains { $0.id == item.id } }?.name
        metricStore.append(RetryCeiling.refusalRecord(
            item: item, refusal: refusal,
            projectPath: projectPath, projectName: projectName, epic: epic,
            specFingerprint: RetryCeiling.specFingerprint(item: item, detail: detail)))
    }

    /// A grounding or definition-of-ready refusal, end to end: recorded on the
    /// run ledger like any other pickup refusal (so the history is kept), and
    /// the item sent to `draft` with the refusal as its reason — fixed by
    /// editing the item, not by another attempt, so leaving it `ready` would
    /// only buy the same refusal, for the same wording, at the next pickup.
    /// See `BacklogViewModel.sendBackToDraft` and `RetryCeiling.isNotEvidence`,
    /// which is what keeps this class of refusal off the ceiling's count.
    private func recordMisgroomedRefusal(_ item: BacklogItem, _ refusal: RetryCeiling.PickupRefusal,
                                         reason: String) {
        recordPickupRefusal(item, refusal)
        backlogViewModel?.sendBackToDraft(itemID: item.id, reason: reason)
    }

    /// The retry ceiling's verdict on one item, judged from the run ledger, the
    /// release and the fingerprint **pickup** judges it from.
    ///
    /// Exposed because the run scheduler asks it too: an autonomous hold's
    /// evidence has to record whether a run could have been started on an item,
    /// and "autopilot would refuse this one" is not a thing to re-derive from
    /// the outside — the two would drift, and the drift would show up as a hold
    /// that never expires.
    func retryCeilingVerdict(item: BacklogItem, detail: BacklogItemDetail?) -> RetryCeiling.Verdict {
        RetryCeiling.evaluate(
            itemID: item.id, projectPath: projectPath,
            records: metricStore?.records ?? [],
            releasedAt: projectPath.flatMap {
                groomingLedger.latestRelease(itemID: item.id, projectPath: $0)
            },
            specFingerprint: RetryCeiling.specFingerprint(item: item, detail: detail))
    }

    /// Says in the item's own file that the retry ceiling stopped it.
    ///
    /// The run log and the ledger both record the refusal, but neither is where
    /// anyone looks when they wonder why an item never runs — and an item that
    /// silently stops being picked up reads exactly like one nobody has got to
    /// yet. Written once: the marker in the note is checked first, so selecting a
    /// retired item again doesn't add the same paragraph a second time.
    private func recordRetirement(_ item: BacklogItem, verdict: RetryCeiling.Verdict) {
        guard let backlogViewModel else { return }
        guard RetryCeiling.needsNote(existingNotes: backlogViewModel.loadDetail(for: item)?.notes) else { return }
        backlogViewModel.appendNote(itemID: item.id, verdict.note)
    }

    // MARK: - Learning Engine Capture

    /// Records one measured execution for the learning engine: duration, cost
    /// (already summed from the worker/reviewer turn spans by the run loop),
    /// what it consumed in tokens, reviewer retries (rework loops), outcome,
    /// epic, and declared size.
    ///
    /// `usage` is rolled up by the caller from the same spans the cost came
    /// from. It is what makes a run's spend analysable afterwards rather than
    /// frozen: the counters can be re-priced when rates move, the model says
    /// what produced them, and the cache read share says where the money went.
    private func recordMetric(
        item: BacklogItem,
        itemResult: ItemResult,
        startTime: Date,
        completedAt: Date,
        costUSD cost: Double,
        usage: RunTokenUsage,
        openingContext: [String: OpeningContext],
        changedFileCount: Int?,
        judgeOutcome: (judgement: RunQualityJudge.Judgement, diffTruncated: Bool?),
        mergeVerify: MergeVerifyPlan? = nil,
        executionID: String?
    ) async {
        guard let metricStore, let projectPath, let projectName else { return }

        let reviewerRetries = await reviewerRetries(executionID: executionID)
        let epic = backlogViewModel?.backlogFile?.sections
            .first { $0.items.contains { $0.id == item.id } }?.name

        var record = TaskMetricRecord(
            projectPath: projectPath,
            projectName: projectName,
            itemID: item.id,
            title: item.title,
            epic: epic,
            declaredSize: item.size?.rawValue,
            startedAt: startTime,
            completedAt: completedAt,
            durationSeconds: completedAt.timeIntervalSince(startTime),
            costUSD: cost,
            reviewerRetries: reviewerRetries,
            outcome: Self.outcomeString(itemResult.outcome),
            workerAgent: workerAgentID.flatMap { id in orchestrator?.agents.first { $0.id == id }?.name },
            reviewerAgent: reviewerAgentID.flatMap { id in orchestrator?.agents.first { $0.id == id }?.name },
            executionID: executionID,
            toolErrors: nil
        )

        // Left nil — never zeroed — when the run recorded no usage: a record
        // that reports 0 tokens claims the run consumed nothing, which is a
        // different fact from the app never having seen a counter.
        record.inputTokens = usage.usage?.inputTokens
        record.outputTokens = usage.usage?.outputTokens
        record.cacheCreationTokens = usage.usage?.cacheCreationTokens
        record.cacheReadTokens = usage.usage?.cacheReadTokens
        record.model = usage.model
        record.derivedCostUSD = usage.derivedCostUSD
        record.priceVersion = usage.priceVersion
        // Left nil rather than empty when no role reported an opening call: an
        // empty dictionary would say the run measured every role and found
        // nothing, which is not what an unmeasured run did.
        record.openingContext = openingContext.isEmpty ? nil : openingContext

        // The forecast this run was started on, kept beside what it cost. Read
        // off the governor rather than re-derived: the prediction chain's first
        // rung is this item's own past runs, and by now this run is one of them.
        record.predictedCostUSD = costGovernor.currentItemPrediction?.usd
        record.predictionSource = costGovernor.currentItemPrediction?.source.rawValue
        // Whether the run crossed that forecast's ceiling. The advisory branch
        // above inserts whichever id it had — the item's when the queue index
        // still pointed at it, the execution's otherwise — so both are checked
        // here. Written on every measured run, so `false` means "measured, did
        // not overrun" and nil stays what it says on the field: a record from
        // before this existed. The set is cleared at the start of each run, so
        // this row is the only place the fact outlives the session.
        record.overItemCap = costOverrunItemIDs.contains(item.id)
            || executionID.map(costOverrunItemIDs.contains) == true
        // Left nil when nobody could read a diff (a live-tree run has no branch)
        // — "unknown" and "changed nothing" are different facts, and only the
        // second one disqualifies the run as evidence.
        record.changedFileCount = changedFileCount
        // The version of the item this attempt was made against, so a later
        // rewrite can be told from a re-run of the same wording. Falls back to
        // the item as it reads now for a run that never went through the queue —
        // the conservative direction, since a record whose fingerprint matches
        // the current spec counts against it.
        record.specFingerprint = pickupSpecFingerprints[item.id]
            ?? RetryCeiling.specFingerprint(item: item, detail: backlogViewModel?.loadDetail(for: item))
        // What stood between this run's diff and main. Nil where no merge was
        // attempted; an empty list where one was and nothing checked it — the
        // two readings a single "no commands" would have collapsed.
        record.mergeVerifyCommands = mergeVerify?.labels

        // Scored by `judgeBeforeMerge`, before the merge and the approval gate
        // acted on the reviewer's "passed" alone — never asked for twice.
        await applyJudgeOutcome(judgeOutcome, to: &record, item: item, executionID: executionID)

        fileMetric(record, to: metricStore)
    }

    /// Files the finished record, with the run's phase durations on it, and
    /// re-reads the deadlines now that this run is one of the ledger's own.
    ///
    /// The durations are read here rather than at the phase lines themselves
    /// because the gate has already answered by the time a row is written — a
    /// merge attempted for this item happens further up the same run loop — so
    /// every stretch is complete and none is still running.
    private func fileMetric(_ record: TaskMetricRecord, to store: TaskMetricStore) {
        var record = record
        record.workerPhaseSeconds = phaseStepSeconds[.worker]
        record.workerTurns = lastWorkerTurns
        record.workerCutShort = workerCutShortTurns != nil
        record.gatePhaseSeconds = phaseStepSeconds[.merge]
        // The pre-review verify is timed by the same rail step a person watches
        // it on, and bounded by the same clock as the merge gate's verify — so
        // it is a gate sample too, and `landedPhaseSamples` folds the two.
        // Absent for an item that declares no `verify:`: the phase is never
        // logged, so the step has no stretch to read.
        record.verifyPhaseSeconds = phaseStepSeconds[.verify]
        // And what the pre-review gate measured of the item's own `verify:`,
        // read here for the same reason: it is run-scoped state the next item
        // clears, so this is the last moment it can reach the ledger. Nil where
        // no verdict was taken, never a stand-in zero — see the field.
        record.verify = lastVerifyVerdict
        store.append(record)
        refreshRunTimeouts()
    }

    /// Folds the judge's verdict — or the reason it has none — into `record`,
    /// and files the same log line and event `recordMetric` used to write
    /// inline. Split out only to hold `recordMetric` under the complexity
    /// gate's line ceiling; the behaviour is unchanged. Also where this run's
    /// review rounds land on the record, for the same reason: the execution
    /// they are read off is discarded once the item ends, so this is the one
    /// chance to keep what it recorded.
    private func applyJudgeOutcome(
        _ judgeOutcome: (judgement: RunQualityJudge.Judgement, diffTruncated: Bool?),
        to record: inout TaskMetricRecord,
        item: BacklogItem,
        executionID: String?
    ) async {
        record.reviewRounds = await reviewRounds(executionID: executionID)
        record.lastReviewBlockingFindingClasses = await lastReviewBlockingFindingClasses(executionID: executionID)
        // Whether the diff the judge actually saw was cut short — nil when the
        // judge was never asked, so nobody fetched a diff to measure.
        record.qualityScoreDiffTruncated = judgeOutcome.diffTruncated
        switch judgeOutcome.judgement {
        case .scored(let verdict):
            record.qualityScore = verdict.overall
            record.judgeDimensions = verdict.dimensions
            // The run list reads its badge off the result/history rows, not the
            // metric store, so the score has to land on both. This runs before
            // `finalizeRunRecord()`, so the score is part of what gets persisted.
            attachQualityScore(verdict.overall, itemID: item.id)
            appendLog(String(format: "Quality %.2f — %@", verdict.overall, verdict.rationale))
            orchestrator?.publishEvent(KiteloopEvent(source: "QualityJudge", type: .custom, payload: [
                "executionID": executionID ?? "",
                "item": item.id,
                "score": String(format: "%.2f", verdict.overall),
                "rationale": verdict.rationale
            ]))
        case .unavailable(let reason):
            // Score and dimensions stay nil — the run was not assessed, which is
            // a different fact from "assessed and found wanting", and only the
            // reason distinguishes them afterwards.
            record.judgeUnavailableReason = reason.rawValue
            attachJudgeUnavailable(reason, itemID: item.id)
            // Only reported when the judge was actually asked: a run of these
            // says the judge is broken, and that's worth seeing. "The judge is
            // off" on every item would just be noise.
            guard reason.isFailure else { return }
            appendLog("Quality not scored — \(reason.explanation)")
            orchestrator?.publishEvent(KiteloopEvent(source: "QualityJudge", type: .custom, payload: [
                "executionID": executionID ?? "",
                "item": item.id,
                "unavailable": reason.rawValue,
                "rationale": reason.explanation
            ]))
        }
    }

    /// Files what the auto-merge decided about this run's work.
    ///
    /// A separate line in a separate log, not a field on the metric row, because
    /// the row does not exist yet: the merge is attempted while the run is still
    /// finishing and `recordMetric` runs after it. The event names the execution,
    /// which is what lets `MergeOutcomeFold` join it to the row when that lands.
    ///
    /// Written only where a merge was actually attempted. A run that ended
    /// blocked, or one in a project that does not auto-merge, reaches no decision
    /// here and leaves `merged` nil — unknown, until a human resolves the gate.
    /// How many files this run left changed — its branch against the project's
    /// `HEAD`, plus anything still uncommitted in a worktree teardown kept.
    ///
    /// Asked of every ending, not only the ones that reach review. A stall, a
    /// timeout and a cost cap all end blocked, and a blocked run's work is
    /// exactly the work nobody could otherwise account for: without a count its
    /// record falls back to its outcome string, where "stalled" says nothing
    /// about whether anything was written. That fallback is what let a stall
    /// clear `RetryCeiling`'s streak.
    ///
    /// Nil — never 0 — when the question can't be asked: a live-tree run has no
    /// branch and no worktree of its own, and its edits are indistinguishable
    /// from a human's. The metric record keeps that distinction because
    /// calibration drops runs that changed nothing, and an unreadable run must
    /// not be dropped for looking like one.
    private func runChangedFileCount(branch: String?, worktree: URL?, isolated: Bool) async -> Int? {
        guard isolated, let projectRoot else { return nil }
        let name = (branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = name.isEmpty ? nil
            : (await RunWorkEvidence.changedFiles(projectRoot: projectRoot, branch: name) ?? []).count
        var uncommitted: Int?
        if let worktree { uncommitted = await RunWorkEvidence.uncommittedFileCount(worktree: worktree) }
        return RunWorkEvidence.totalChangedFiles(committed: committed, uncommitted: uncommitted)
    }

    /// The paths this item's own bookkeeping dirties in the project root, so the
    /// stray-work check does not report the run for them.
    private func backlogPathsInProjectRoot(for item: BacklogItem) -> [String] {
        Self.backlogPaths(projectRoot: projectRoot,
                          backlogURL: backlogViewModel?.backlogURL,
                          detailPath: item.detailPath)
    }

    /// Repo-relative paths a run writes into the project root as a matter of
    /// course: the backlog file, whose statuses it moves for every item it
    /// touches, the detail file it appends Notes to, and `.kiteloop/`, where
    /// transcripts and traces land.
    ///
    /// They are not the worker's edits, so they are not evidence that a run
    /// wrote outside its worktree — and a project-local `BACKLOG.md` would
    /// otherwise make that check fire on every single item.
    ///
    /// Pure and static so the exclusion can be read without a run: a rule that
    /// silently over-excludes is a check that never fires.
    nonisolated static func backlogPaths(projectRoot: URL?, backlogURL: URL?, detailPath: String?) -> [String] {
        var paths = [".kiteloop/"]
        guard let projectRoot, let backlogURL else { return paths }
        let root = projectRoot.path(percentEncoded: false)
        /// The path relative to the project root, or nil when `url` is outside
        /// it — a vault backlog dirties nothing in this repository.
        func relative(_ url: URL) -> String? {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            let full = url.path(percentEncoded: false)
            guard full.hasPrefix(prefix) else { return nil }
            return String(full.dropFirst(prefix.count))
        }
        if let backlog = relative(backlogURL) { paths.append(backlog) }
        if let detailPath, !detailPath.isEmpty,
           let detail = relative(backlogURL.deletingLastPathComponent().appending(path: detailPath)) {
            paths.append(detail)
        }
        return paths
    }

    /// Runs the LLM-as-judge for a run whose deterministic checks have already
    /// run (an advisory score — see `judgeBeforeMerge`). Skips cancelled runs
    /// and no-ops when the runtime isn't configured — each of which is reported as its own
    /// reason, so "nobody asked the judge" is never confused with "the judge
    /// failed the work".
    ///
    /// `diffTruncated` is nil exactly when the judge was never asked — nobody
    /// fetched a diff to measure — and `false`/`true` otherwise: whether the diff
    /// the judge received was cut short by `RunQualityJudge.diffCharacterLimit`.
    /// Read by the caller and stamped onto the metric record alongside the
    /// score, so a night's average can exclude the runs measured through a
    /// keyhole rather than blending them in with the ones measured whole.
    ///
    /// `diffBase` is `runDiffBase`'s answer, captured by the caller *before*
    /// the auto-merge this now runs ahead of (`judgeBeforeMerge`) — by the time
    /// a merge lands, `HEAD` may already contain the branch and re-deriving the
    /// base here would read empty.
    ///
    /// `executionID` is where the worker's premise report is read from: its
    /// closing message, on the execution's steps. Handed to the judge for any
    /// run that carried one, and — for an investigation — with the terms the
    /// run is scored on instead of its diff (`RunQualityJudge.investigationScoring`).
    private func judgeRun(item: BacklogItem, itemResult: ItemResult,
                          reviewerRetries: Int, projectPath: String, diffBase: String?,
                          executionID: String? = nil)
        async -> (judgement: RunQualityJudge.Judgement, diffTruncated: Bool?) {
        let judge: RunQualityJudge
        switch judgeToAsk(for: itemResult) {
        case .unavailable(let reason): return (.unavailable(reason), nil)
        case .ask(let ready): judge = ready
        }
        let diff = await runDiff(base: diffBase, branch: itemResult.branch)
        let premise = await premiseFraming(itemResult: itemResult, executionID: executionID)
        let judgement = await judge.judge(
            item: item,
            detail: backlogViewModel?.loadDetail(for: item),
            diff: diff,
            diffStat: await runDiffStat(base: diffBase, branch: itemResult.branch),
            outcome: Self.outcomeString(itemResult.outcome),
            reviewerRetries: reviewerRetries,
            projectPath: projectPath,
            premiseReport: premise.report,
            investigation: premise.investigation
        )
        return (judgement, RunQualityJudge.isDiffTruncated(diff))
    }

    /// The judge to ask about this run, or the reason nobody is asking it —
    /// the two ways a run reaches the judge and gets no score for a cause
    /// that has nothing to do with its diff. Each is its own `Unavailability`
    /// so the record can say which, rather than blaming the work.
    ///
    /// The order is the answer when both hold, and it is deliberate: a
    /// cancelled run has no finished work to score, whatever the app is wired
    /// to; and only then is a missing runtime the reason.
    ///
    /// Internal, not private, and split out of `judgeRun`: it is a decision
    /// with named outcomes, and `RunQualityJudgeTests` asks it for each
    /// of them directly rather than through a judge session.
    func judgeToAsk(for itemResult: ItemResult) -> JudgeRequest {
        if case .cancelled = itemResult.outcome { return .unavailable(.cancelled) }
        guard let runtimeFactory, let globalConfigStore else { return .unavailable(.notConfigured) }
        return .ask(RunQualityJudge(runtimeFactory: runtimeFactory, globalConfigStore: globalConfigStore))
    }

    /// `judgeToAsk`'s answer: a judge to ask, or the reason nobody is asking
    /// one. An enum of its own rather than an optional pair, so "there is a
    /// judge" and "here is why there isn't" cannot both be read off one
    /// value — the same distinction `RunQualityJudge.Judgement` keeps between
    /// a verdict and an unavailability.
    enum JudgeRequest {
        case ask(RunQualityJudge)
        case unavailable(RunQualityJudge.Unavailability)
    }

    /// What the judge is told about the run's premise: the worker's premise
    /// report, and whether the run is to be scored as an investigation
    /// (`RunQualityJudge.investigationScoring`) instead of on its diff.
    ///
    /// An ordinary run carries a report only if the worker wrote one — parsed
    /// out of its closing message on the execution's steps. An investigation
    /// carries its own report and overrides that one: the outcome *is* the
    /// report, and it is the finding the run is judged on.
    ///
    /// Internal, not private, for the same reason as `judgeToAsk`:
    /// `RunQualityJudgeTests` reads the framing for each kind of run without
    /// standing up a judge.
    func premiseFraming(itemResult: ItemResult, executionID: String?)
        async -> (report: String?, investigation: Bool) {
        if case .investigation(let report) = itemResult.outcome { return (report, true) }
        guard let executionID else { return (nil, false) }
        return (PremiseReport.parse(await workerClosingMessage(executionID: executionID))?.text, false)
    }

    /// Asks the judge, before the merge/approval gate, and writes the scope
    /// deviation it names to the item's Notes as an advisory finding. The
    /// score never decides the run's outcome: of 533 runs the judge blocked 7,
    /// every one a false block against a How that had gone stale, while the
    /// mechanical gates refused 35. The score is still filed by `recordMetric`
    /// for the coordinator, triage and the advisor to read.
    ///
    /// Returns only the judgement, so the caller can hand it to `recordMetric`
    /// without asking the judge a second time — and so nothing here can
    /// change the run's result.
    private func judgeBeforeMerge(
        item: BacklogItem,
        itemResult: ItemResult,
        reviewerRetries: Int,
        diffBase: String?,
        executionID: String?
    ) async -> (judgement: RunQualityJudge.Judgement, diffTruncated: Bool?) {
        guard let projectPath else { return (.unavailable(.notConfigured), nil) }
        let judgeOutcome = await judgeRun(item: item, itemResult: itemResult, reviewerRetries: reviewerRetries,
                                          projectPath: projectPath, diffBase: diffBase, executionID: executionID)
        noteJudgeFinding(itemID: item.id, judgement: judgeOutcome.judgement)
        return judgeOutcome
    }

    /// Writes the judge's finding, when it named one, to the item's Notes as
    /// advisory. "quality judge" first, deliberately — a reviewer's note reads
    /// as the reviewer's own words, and this must not be mistaken for one.
    ///
    /// Internal, not private: `RunQualityJudgeTests` calls it against a real
    /// backlog to read the note back and the item's status unchanged.
    func noteJudgeFinding(itemID: String, judgement: RunQualityJudge.Judgement) {
        guard let finding = Self.judgeAdvisoryFinding(judgement) else { return }
        appendLog("Quality judge on \(itemID) — \(finding.text)")
        backlogViewModel?.appendNote(itemID: itemID, "quality judge — [\(finding.severity.rawValue)] \(finding.line)")
    }

    /// The finding a scored judgement earns: its `scopeDeviation`, as an
    /// advisory finding — never a blocking one, whatever the score. Nil when
    /// the judge named no deviation or was unavailable.
    nonisolated static func judgeAdvisoryFinding(_ judgement: RunQualityJudge.Judgement) -> ReviewFindings.Finding? {
        guard case .scored(let verdict) = judgement, !verdict.scopeDeviation.isEmpty else { return nil }
        return ReviewFindings.Finding(severity: .advisory, text: verdict.scopeDeviation)
    }

    /// Where `branch` forked from `HEAD`, read with `git merge-base` *before*
    /// the auto-merge below folds the branch back into `HEAD` — after that, the
    /// merge-base of the two is the branch tip itself and every range built from
    /// it is empty. Threaded down to `judgeRun` so the diff it hands the judge
    /// covers everything the run committed, not just the branch's last commit
    /// (`runDiff`/`runDiffStat` used to read `<branch>~1..<branch>`, which is
    /// exactly one commit — teardown's `commitAll` and the PR fix/comment
    /// rounds can each add another).
    ///
    /// Nil — never a range that would fall back to diffing the whole repo —
    /// when this isn't an isolated run, there's no branch, or git couldn't
    /// answer.
    ///
    /// Internal, not private: `RunQualityJudgeTests` calls this and the two
    /// below directly, against a `BacklogAutopilot` wired to a
    /// `ScriptedSubprocessRunner`, to assert the git arguments without
    /// spinning up a real run.
    func runDiffBase(branch: String?, isolated: Bool) async -> String? {
        guard isolated, let branch, let projectRoot else { return nil }
        let root = projectRoot.path(percentEncoded: false)
        // The ref the run forked from: the project's `baseBranch` when it has
        // one, else the checkout's `HEAD` — the same choice `WorktreeSession
        // .begin` made, so the diff starts where the branch actually started.
        let base = baseBranch.map { "refs/heads/\($0)" } ?? "HEAD"
        return await Task.detached(priority: .userInitiated) {
            let result = SubprocessOutput.git(["-C", root, "merge-base", base, branch])
            guard result.status == 0 else { return nil }
            let sha = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.isEmpty ? nil : sha
        }.value
    }

    /// Everything the run's branch added since it forked from its base — `base`
    /// is `runDiffBase`'s answer, captured before the auto-merge. Empty when
    /// there is no base to diff from, so the judge is handed nothing rather
    /// than a diff of the whole repository.
    func runDiff(base: String?, branch: String?) async -> String {
        guard let base, let branch, let projectRoot else { return "" }
        let root = projectRoot.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            // Through the one runner, which drains stdout before waiting and
            // sends stderr to the null device — the deadlock this used to carry
            // its own copy of the fix for (098848e).
            SubprocessOutput.git(["-C", root, "diff", "\(base)..\(branch)"]).output
        }.value
    }

    /// `git diff --stat` for the same range `runDiff` reads — every file the run
    /// touched, with its added/deleted line counts. Passed to the judge beside
    /// the (possibly truncated) diff body: a stat line is bounded by how many
    /// files a run touches rather than by how many lines it changes, so it
    /// stays whole on a diff too large for the body to fit, and answers "were
    /// tests added" without needing the hunks that didn't make the cut.
    func runDiffStat(base: String?, branch: String?) async -> String {
        guard let base, let branch, let projectRoot else { return "" }
        let root = projectRoot.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            SubprocessOutput.git(["-C", root, "diff", "--stat", "\(base)..\(branch)"]).output
        }.value
    }

    /// Rework loops = reviewer passes beyond the first.
    ///
    /// Only the `reviewer` node counts. The follow-up ask (`reviewer-clarify`) is
    /// a second question about the same review, not a second review, and counting
    /// it would report rework on a run that had none.
    private func reviewerRetries(executionID: String?) async -> Int {
        guard let executionID,
              let execution = await orchestrator?.workflowEngine.execution(id: executionID) else { return 0 }
        let reviewerVisits = execution.steps.filter { $0.nodeID == "reviewer" }.count
        return max(0, reviewerVisits - 1)
    }

    /// This run's review rounds, read off the execution's own steps once, at
    /// the moment the run's metric is written — the live execution is discarded
    /// once the item ends, so this is the one chance to keep what it recorded.
    private func reviewRounds(executionID: String?) async -> [ReviewRound] {
        guard let executionID,
              let execution = await orchestrator?.workflowEngine.execution(id: executionID) else { return [] }
        return ReviewRounds.rounds(steps: execution.steps)
    }

    /// The classes of blocking findings on the review that ended this run,
    /// read off the same discarded execution `reviewRounds(executionID:)`
    /// reads, at the same moment. Empty whenever the last review passed —
    /// `ReviewFindings.route` never lets a blocking finding through a passing
    /// verdict — so this is non-empty only for a run its own `verify:`
    /// salvaged over a rejecting review the retry budget ran out on.
    private func lastReviewBlockingFindingClasses(executionID: String?) async -> [String] {
        guard let executionID,
              let execution = await orchestrator?.workflowEngine.execution(id: executionID) else { return [] }
        let output = Self.lastReviewOutput(in: execution)
        return ReviewFindings.findings(in: output)
            .filter { $0.severity == .blocking }
            .map(\.overrideClass)
    }

    /// What the run identified by `executionID` has cost so far.
    private func costForItem(executionID: String) async -> Double {
        Self.costOfTurnSpans(await runTurnSpans(), executionID: executionID)
    }

    /// Every turn span written by the run's worker and reviewer, unfiltered — the
    /// caller selects the run it wants out of them.
    private func runTurnSpans() async -> [TraceSpan] {
        guard let store = orchestrator?.traceStore else { return [] }
        var spans: [TraceSpan] = []
        for agentID in [workerAgentID, reviewerAgentID].compactMap({ $0 }) {
            spans += await store.loadSpans(for: agentID)
        }
        return spans
    }

    /// Sums the `costUSD` of the `.turn` spans this execution owns.
    ///
    /// Ownership is *recorded*, not inferred: `ChatViewModel` stamps every turn it
    /// writes with the execution the agent was reserved by (`TraceSpan.MetadataKey`),
    /// so this is a lookup on that id.
    ///
    /// There is deliberately no time-window fallback. Attribution used to be
    /// reconstructed — load the worker's and reviewer's spans, keep the ones whose
    /// `startTime` fell inside the item's window — and when that inference missed,
    /// the item read `$0` with nothing to say it had. It missed often (9 of 31 runs
    /// on 2026-08-08), and the consequences were not cosmetic: `effectiveCostCap`
    /// compared against zero, so the ceiling was inert, and `isNoWorkBlock` read a
    /// run that had plainly worked as "the agent did nothing" and fed that into the
    /// circuit breaker. A fallback that silently returns a wrong number is the
    /// failure being removed, not a safety net for it.
    nonisolated static func costOfTurnSpans(_ spans: [TraceSpan], executionID: String) -> Double {
        turnSpans(spans, executionID: executionID).reduce(0.0) { $0 + Self.costUSD(of: $1) }
    }

    /// The same spend, split by the role that incurred it (`worker`, `reviewer`, …).
    /// A run is otherwise a single number, which cannot answer whether review is a
    /// third of the spend.
    nonisolated static func costByRole(_ spans: [TraceSpan], executionID: String) -> [String: Double] {
        var totals: [String: Double] = [:]
        for span in turnSpans(spans, executionID: executionID) {
            let role = span.metadata[TraceSpan.MetadataKey.role] ?? "unknown"
            totals[role, default: 0] += Self.costUSD(of: span)
        }
        return totals
    }

    /// The turns belonging to one execution. A span carrying no execution id — a
    /// human's chat turn — belongs to no run and is never swept in.
    private nonisolated static func turnSpans(_ spans: [TraceSpan], executionID: String) -> [TraceSpan] {
        spans.filter {
            $0.type == .turn && $0.metadata[TraceSpan.MetadataKey.executionID] == executionID
        }
    }

    /// A span's own contribution to spend: the delta the turn added to its
    /// session's running total, when the span carries one. `reportedCostUSD`
    /// is the CLI's running total at that turn, not what the turn itself
    /// cost — falling back to it (for a span written before the delta was
    /// recorded) both overcounts a multi-turn session and is the only figure
    /// an old span has.
    private nonisolated static func costUSD(of span: TraceSpan) -> Double {
        span.costDeltaUSD ?? span.reportedCostUSD ?? 0
    }

    /// What the run consumed, rolled up from the turns it owns: the four token
    /// counters, the model that produced them, and the cost re-derived from them
    /// at the rate card each turn was priced at.
    ///
    /// Separate from `costOfTurnSpans`, which stays the CLI's reported figure.
    /// Neither replaces the other — a run reports both, and a gap between them
    /// is a finding rather than a conflict to resolve.
    nonisolated static func usageOfTurnSpans(_ spans: [TraceSpan], executionID: String) -> RunTokenUsage {
        RunTokenUsage.rollUp(turnSpans(spans, executionID: executionID))
    }

    /// What each role of this run was sent before it had done anything — read
    /// off the **first** turn each role recorded, which is the one that opened
    /// its session.
    ///
    /// Deliberately not rolled up like the counters above: summing an opening
    /// context over a run's turns would answer a different question, since every
    /// later turn re-sends the same rules on top of a conversation that has
    /// grown. The first one is the whole measurement.
    nonisolated static func openingContextByRole(_ spans: [TraceSpan],
                                                 executionID: String) -> [String: OpeningContext] {
        OpeningContext.byRole(turnSpans(spans, executionID: executionID))
    }

    /// The usage fields of an `item.end` line, in log order. Each is nil — and so
    /// dropped by `phaseLine` — when the run recorded nothing for it: a field
    /// going quiet says "not measured", which a `0` would misreport as "spent
    /// nothing". `cacheHitRate` is here because a run whose cache suddenly stops
    /// hitting is a cost regression, and the dollar figure alone never shows it.
    nonisolated static func usageFields(_ run: RunTokenUsage) -> [(String, String?)] {
        [
            ("model", run.model),
            ("inputTokens", run.usage.map { String($0.inputTokens) }),
            ("outputTokens", run.usage.map { String($0.outputTokens) }),
            ("cacheWriteTokens", run.usage.map { String($0.cacheCreationTokens) }),
            ("cacheReadTokens", run.usage.map { String($0.cacheReadTokens) }),
            ("cacheHitRate", run.usage.map(\.cacheHitRateText)),
            ("derivedCostUSD", run.derivedCostUSD.map(usdField)),
            ("priceVersion", run.priceVersion),
        ]
    }

    /// `reviewer=$1.4600 worker=$4.2400` — nil when the run attributed nothing.
    /// The `quality=` field of an `item.end` line: the judge's score, or
    /// `unavailable:<reason>` when it produced none. Nil only for a record the
    /// judge never touched at all (history from before the reason was kept), so
    /// a silent field never has to stand in for a failure.
    nonisolated static func qualityField(_ metric: TaskMetricRecord?) -> String? {
        guard let metric else { return nil }
        if let score = metric.qualityScore { return String(format: "%.2f", score) }
        return metric.judgeUnavailableReason.map { "unavailable:\($0)" }
    }

    private nonisolated static func roleCostField(_ byRole: [String: Double]) -> String? {
        guard !byRole.isEmpty else { return nil }
        return byRole.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(usdField($0.value))" }
            .joined(separator: " ")
    }

    /// How an ending is spelled in the metric ledger, the run record and the
    /// unified log — the one producer of the string every one of those is
    /// grouped by.
    ///
    /// `nonisolated static` so the spelling can be asserted without a run, like
    /// `shouldAutoMerge` and `gateResolution`: `RetryCeiling` exempts a run by
    /// matching one of these strings exactly, and a test that could only check a
    /// literal would not notice the two coming apart.
    nonisolated static func outcomeString(_ outcome: ItemResult.Outcome) -> String {
        switch outcome {
        case .done: return "done"
        case .awaitingApproval: return "awaiting-approval"
        case .blocked(let reason): return "blocked:\(reason)"
        case .cancelled: return "cancelled"
        case .alreadyImplemented: return TaskMetricRecord.alreadyImplementedOutcome
        case .investigation: return TaskMetricRecord.investigationOutcome
        case .usageLimitParked: return TaskMetricRecord.usageLimitParkedOutcome
        }
    }

    /// The one word the `item.end` phase line carries beside an outcome that
    /// ends a run without a diff — `premise-refuted` for an investigation, so
    /// a night's log can be counted by how many items were found not to need
    /// building rather than built. Nil for every other ending: `blocked`
    /// already carries its reason inside the outcome string.
    nonisolated static func endingReason(_ outcome: ItemResult.Outcome) -> String? {
        if case .investigation = outcome { return "premise-refuted" }
        return nil
    }

    /// The `## Premise — verify before building` block of the worker's prompt,
    /// rendered whole into the run's state so the prompt template carries it
    /// in one line ahead of the Suggested Approach; nil — and so no block —
    /// for an item that states no premise.
    ///
    /// It asks for exactly the report `PremiseReport` reads back, and says the
    /// thing the 2026-09-03 item never said: that a refuted claim is a place
    /// to stop, not a premise to build four justifications on.
    nonisolated static func premiseBlock(_ claims: [String]) -> AnyCodable? {
        guard !claims.isEmpty else { return nil }
        let list = claims.map { "- \($0)" }.joined(separator: "\n")
        return .string("""
            ## Premise — verify before building
            The item rests on these claims. Verify each against the tree before changing anything:
            \(list)

            Report each at the top of your handoff, one line per claim, as `held`, \
            `refuted: <measurement>` or `unverifiable: <why>`. A refuted premise is a \
            legitimate end to the run: stop, state the measurement and what, if anything, \
            still qualifies, and hand off. Do not build on a claim you refuted.
            """)
    }

    /// How a run that git says changed nothing can still end as an answer
    /// about the item — and which answer. Read off the worker's raw closing
    /// message (`RunClosingMessage.rawLastMessage`, not the condensed form:
    /// both shapes are structure a 300-character cut destroys).
    ///
    /// A refuted premise is read first: a worker that measured the item's
    /// claim false and *also* wrote an already-implemented object has given
    /// the more specific finding, and it is the measurement a person at the
    /// gate needs to check. A report with every claim `held` is not an ending
    /// by itself — the worker was then expected to build.
    struct NoWorkEnding {
        /// The run-log headline — "Investigation", "Already implemented (claimed)".
        let headline: String
        /// The finding in a log line's words.
        let summary: String
        /// What the item's `## Notes` carry to the gate.
        let note: String
        /// The parenthetical on the gate notification.
        let gateLabel: String
        let outcome: ItemResult.Outcome
    }

    nonisolated static func noWorkEnding(closingMessage: String?) -> NoWorkEnding? {
        if let report = PremiseReport.parse(closingMessage), report.isRefuted {
            return NoWorkEnding(headline: "Investigation", summary: report.summary, note: report.note,
                                gateLabel: "premise refuted", outcome: .investigation(report.text))
        }
        if let claim = RunWorkEvidence.AlreadyImplementedClaim.parse(closingMessage) {
            return NoWorkEnding(headline: "Already implemented (claimed)", summary: claim.summary,
                                note: claim.note, gateLabel: "claimed already implemented",
                                outcome: .alreadyImplemented)
        }
        return nil
    }

    // MARK: - The WRITE loop: compound repo knowledge at the end of a run

    /// Fold one finished item into what the distiller will be shown.
    ///
    /// `mergeAttempted` is derived the same way the run's own auto-merge is: a
    /// branch, a reviewer that passed, and the flag on. It matters because
    /// "review passed and nothing landed" is one of the patterns worth learning
    /// — the shape of the tracked-`.pyc` dirty-tree bug — and it is invisible
    /// from the outcome alone.
    private func recordRunKnowledgeEvent(item: BacklogItem, result: ItemResult, costUSD: Double) {
        let reviewerPassed: Bool = {
            switch result.outcome {
            // A claim run never reached the reviewer — the pre-review gate ends
            // a run with nothing to review — so there is no verdict to report as
            // a pass, and `mergeAttempted` below must not be derived from one.
            case .blocked, .cancelled, .alreadyImplemented, .investigation: return false
            default: return true
            }
        }()
        let mergeAttempted = autoMergeOnApproval && result.branch != nil && reviewerPassed
        let merged = mergeAttempted && { if case .done = result.outcome { return true } else { return false } }()
        let metric = latestMetric(itemID: item.id)
        let outcome = Self.outcomeString(result.outcome)
        runKnowledgeEvents.append(RunKnowledgeDistiller.Event(
            itemID: item.id,
            outcome: outcome,
            merged: merged,
            mergeAttempted: mergeAttempted,
            costUSD: costUSD,
            predictedCostUSD: predictedCostUSD(for: item),
            reviewerRetries: metric?.reviewerRetries ?? 0,
            qualityScore: metric?.qualityScore,
            stalled: outcome.localizedCaseInsensitiveContains("stall")
        ))
    }

    /// End of the run: distil what happened into the repo's
    /// `coordinator-knowledge.md`, which the grooming loop, the Coordinator chat
    /// and the persona composer all read back on their next pass.
    ///
    /// Unconditional — there is no flag in front of it. It used to hang off the
    /// per-project run supervisor's `finish()`, so a project that never switched
    /// that seam on accumulated nothing. Silent without a runtime, a config
    /// store or a project path: those are what a headless call needs, and a run
    /// in a test harness has none of them.
    private func distillRunKnowledge() async {
        guard let runtimeFactory, let globalConfigStore, let projectPath,
              !runKnowledgeEvents.isEmpty else { return }
        let distiller = RunKnowledgeDistiller(
            advisor: CoordinatorAdvisor(runtimeFactory: runtimeFactory,
                                        globalConfigStore: globalConfigStore),
            projectPath: projectPath
        )
        let learnings = await distiller.run(events: runKnowledgeEvents)
        guard !learnings.isEmpty else { return }
        orchestrator?.publishEvent(KiteloopEvent(source: "Coordinator", type: .custom,
            payload: ["kind": "learned", "count": String(learnings.count)]))
    }

    /// The run's state, as the worker and reviewer see it. `worktree` is the
    /// isolated checkout the run happens in (nil in the live tree): the verify
    /// commands it hands the agents are rewritten to build into that worktree's
    /// own DerivedData, so the copy of the app a run builds dies with the
    /// worktree instead of registering itself alongside the real one
    /// (`WorktreeBuildOutput`). It also reaches the reviewer as
    /// `worktreePath`, the checkout the branch is already open at: both agents
    /// are started there (`WorktreeSession.begin`), so naming it is what stops
    /// a reviewer with a shell from checking the branch out somewhere of its
    /// own and judging a tree the work never happened in. Both keys stay unset
    /// in the live tree, and both prompt sections collapse.
    ///
    /// `background` is what the repo has learned from the runs before this one
    /// (`CoordinatorKnowledge.background`). Nil — a project with no
    /// `coordinator-knowledge.md`, or an empty one — leaves the key unset, and
    /// both prompt sections collapse to nothing rather than to a bare header.
    ///
    /// `rejection` renders to the same `humanRejection` text on both the
    /// worker's and the reviewer's prompt (`GateRejection.promptBlock`); nil
    /// for an item with nothing outstanding.
    nonisolated static func buildInitialState(
        item: BacklogItem, detail: BacklogItemDetail?, worktree: URL?,
        background: CoordinatorKnowledge.Background? = nil, rejection: GateRejection.Record? = nil
    ) -> [String: AnyCodable] {
        var state: [String: AnyCodable] = [
            "itemID": .string(item.id),
            "title": .string(item.title),
        ]
        // Assigning nil to a key removes it, which is what an absent section
        // wants: the prompt template collapses the section rather than
        // rendering a bare header over nothing.
        state["projectKnowledge"] = background.map { AnyCodable.string($0.text) }
        state["humanRejection"] = rejection.flatMap(GateRejection.promptBlock).map(AnyCodable.string)
        state["buildOutputNote"] = worktree.map { AnyCodable.string(runBuildOutputNote(worktree: $0)) }
        state["worktreePath"] = worktree.map { AnyCodable.string($0.path(percentEncoded: false)) }

        for (key, value) in Self.detailState(detail) {
            state[key] = value
        }

        let verifyLines = Self.promptVerifyLines(item: item, detail: detail, worktree: worktree)
        if !verifyLines.isEmpty {
            state["verifyCommands"] = .string(verifyLines.joined(separator: "\n"))
        }

        if state["acceptanceCriteria"] == nil {
            state["acceptanceCriteria"] = .string("Complete the task described in the title.")
        }
        if state["verifyCommands"] == nil {
            state["verifyCommands"] = .string("No specific verify commands — use your judgment.")
        }

        return state
    }

    /// The prompt keys a groomed detail file carries — everything the item's
    /// own markdown says, and nothing the run's environment says. Empty for an
    /// ungroomed item, which is how `buildInitialState`'s fallbacks come to
    /// stand in for the missing acceptance criteria.
    ///
    /// A key is only present when the detail states it: an absent `## Why`, an
    /// empty out-of-scope list and an item with no premise each leave their key
    /// unset rather than setting it to an empty string.
    private nonisolated static func detailState(_ detail: BacklogItemDetail?) -> [String: AnyCodable] {
        guard let detail else { return [:] }
        var state: [String: AnyCodable] = [:]
        state["what"] = detail.what.map(AnyCodable.string)
        state["approach"] = detail.approach.map(AnyCodable.string)
        state["why"] = detail.why.map(AnyCodable.string)
        state["premise"] = Self.premiseBlock(detail.premise)
        state["outOfScope"] = Self.bulletList(detail.outOfScope)
        state["acceptanceCriteria"] = Self.bulletList(detail.acceptanceCriteria)
        return state
    }

    /// A markdown bullet list, or nil for an empty one so the caller's key stays
    /// unset and the prompt section collapses.
    private nonisolated static func bulletList(_ lines: [String]) -> AnyCodable? {
        guard !lines.isEmpty else { return nil }
        return .string(lines.map { "- \($0)" }.joined(separator: "\n"))
    }

    /// Where an isolated run must build, spelled out for the worker: the
    /// worktree's own DerivedData, so the copy of the app the run builds dies
    /// with the worktree instead of registering itself alongside the real one.
    /// The pull request rounds have their own wording of the same rule
    /// (`buildOutputNote(worktree:)`), which cites no verify commands because
    /// they are handed none.
    ///
    /// Only an isolated run has somewhere disposable to build into, so the
    /// caller leaves the key unset — and the prompt section collapses — in the
    /// live tree.
    private nonisolated static func runBuildOutputNote(worktree: URL) -> String {
        let path = WorktreeBuildOutput.derivedDataDirectory(for: worktree).path(percentEncoded: false)
        return """
            This run happens in a throwaway git worktree. Build into it: pass \
            `-derivedDataPath \(path)` to every `xcodebuild` you run — the verify \
            commands above already do. Without it Xcode derives a new DerivedData \
            tree from this worktree's path and registers a second copy of the app \
            that outlives the worktree.
            """
    }

    /// The `verifyCommands` prompt block, unioned from both sources: the
    /// groomed detail's commands (name, `cmd`, and an optional expectation),
    /// then the item line's own `verify:` appended when its text isn't
    /// already among them. Mirrors `declaredVerifyCommands`'s union so what
    /// the worker is briefed on and what the coverage gate holds it to never
    /// diverge — a line widened to satisfy the verify map used to do nothing
    /// here, because a non-empty groomed list crowded it out entirely
    /// (`item-verify-has-two-sources-and-the-quiet-one-wins`).
    private nonisolated static func promptVerifyLines(
        item: BacklogItem,
        detail: BacklogItemDetail?,
        worktree: URL?
    ) -> [String] {
        let groomed = detail?.verifyCommands ?? []
        var lines = groomed.map {
            let cmd = WorktreeBuildOutput.redirectingBuilds(in: $0.cmd, worktree: worktree)
            return "\($0.name): `\(cmd)`" + ($0.expect.map { " (expect: \($0))" } ?? "")
        }
        let groomedCmds = groomed.map { $0.cmd.trimmingCharacters(in: .whitespacesAndNewlines) }
        let verify = (item.verify ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !verify.isEmpty, !groomedCmds.contains(verify) {
            lines.append(WorktreeBuildOutput.redirectingBuilds(in: verify, worktree: worktree))
        }
        return lines
    }

    /// Per-item cost ceiling for this item (see `CostGovernor`).
    func effectiveCostCap(for item: BacklogItem) -> Double? {
        costGovernor.effectiveItemCap(for: item)
    }

    /// The paths this item's own text names, read the way `GroundingCheck`
    /// reads a draft but without its invention check: a file the item proposes
    /// to create is exactly as much "about this item" as one it says is
    /// already there (unlike in `GroundingCheck.citations(in:)`).
    nonisolated static func knownItemPaths(item: BacklogItem, detail: BacklogItemDetail?) -> Set<String> {
        let text = GroundingCheck.draftText(item: item, detail: detail)
        let paths = GroundingCheck.backtickedSpans(in: text)
            .compactMap { GroundingCheck.classify($0.text) }
            .filter { $0.kind == .path }
            .map { GroundingCheck.SourceIndex.normalize($0.text) }
        return Set(paths)
    }

    /// What the review that ended this run actually said — its own step output,
    /// not the execution state.
    ///
    /// A run can review more than once (reject → worker → review again), and the
    /// engine's state is carry-forward: it merges each node's output over the
    /// last and never removes a key. Reading findings from state would therefore
    /// attribute an earlier round's findings to the round that approved. Empty
    /// for an execution that never reached a review at all.
    nonisolated static func lastReviewOutput(in execution: WorkflowExecution?) -> [String: AnyCodable] {
        execution?.steps.last {
            $0.nodeID == "reviewer" || $0.nodeID == reviewerClarifyNodeID
        }?.output ?? [:]
    }

    /// Writes a passing review's advisory findings to the item's `## Notes`.
    ///
    /// This is the only moment they exist: an approval has no feedback channel,
    /// so without this an advisory finding is either escalated to a rejection or
    /// lost when the execution is discarded. Nothing here changes the outcome —
    /// the review passed, and these are the things it decided were not worth
    /// blocking for.
    private func recordAdvisoryFindings(
        review: [String: AnyCodable],
        item: BacklogItem,
        backlog: BacklogViewModel
    ) {
        let notes = ReviewFindings.advisoryNotes(in: review)
        guard !notes.isEmpty else { return }
        for note in notes {
            _ = backlog.appendNote(itemID: item.id, note)
        }
        appendLog("Review passed with \(notes.count) advisory finding\(notes.count == 1 ? "" : "s") "
                  + "for \(item.id) — recorded in the item's Notes")
    }

    /// Answers a person's outstanding rejection now that a review has passed:
    /// appends a `.cleared` entry to `GateRejection`, so `outstanding` reads
    /// nil from here on and the next run's prompts carry no `## Rejected last
    /// time` section. Silent — no read, no write — for the item every other
    /// run is: one that was never rejected.
    nonisolated static func clearGateRejectionIfOutstanding(itemID: String, projectPath: String) {
        let url = GateRejection.url(projectPath: projectPath)
        guard GateRejection.outstanding(itemID: itemID, entries: GateRejection.read(from: url)) != nil else { return }
        GateRejection.append(GateRejection.Record(itemID: itemID, kind: .cleared, reason: nil, ref: nil, at: Date()),
                             to: url)
    }

    /// Writes every rejecting round's drift findings to the item's `## Notes` —
    /// each `drift:` line `ReviewFindings.route` wrote to `driftKey`, never
    /// routed to the worker as a fix (that is the loop this exists to break),
    /// so this is the only place they survive the run at all.
    ///
    /// Walks every review-ish step rather than just the last: a run can reject
    /// more than once, and a drift finding on an earlier round is exactly the
    /// kind of thing a human re-reading a multi-round rejection needs to see,
    /// not only the round the run happened to end on.
    /// A QA run's report and storyboard, on the item's Notes — where a person
    /// reads what QA saw before approving. Nothing for a run QA never reached.
    /// The storyboard is copied out of `tree` first — the run's worktree is
    /// removed after this — and the note names the kept copy.
    private func recordQAReport(execution: WorkflowExecution?, item: BacklogItem, tree: URL?,
                                backlog: BacklogViewModel) {
        guard item.flow == .qa, let execution else { return }
        let reported = execution.state["storyboard"]?.stringValue
        let kept = reported.flatMap { board in tree.flatMap { tree in
            QAStoryboardArchive.keep(storyboard: board, worktree: tree,
                                     into: QAStoryboardArchive.destination(itemID: item.id, runID: execution.id))
        } }
        guard let note = QAFlowStages.note(report: execution.state["qa_report"]?.stringValue,
                                           storyboard: kept?.path(percentEncoded: false) ?? reported,
                                           passed: execution.currentNode == "done",
                                           reachedQA: execution.steps.contains { $0.nodeID == QAFlowStages.qaNodeID },
                                           found: kept != nil)
        else { return }
        _ = backlog.appendNote(itemID: item.id, note)
    }

    private func recordDriftFindings(
        execution: WorkflowExecution?,
        item: BacklogItem,
        backlog: BacklogViewModel
    ) {
        guard let steps = execution?.steps else { return }
        let reviewNodeIDs: Set<String> = ["reviewer", Self.reviewerClarifyNodeID]
        let lines = steps
            .filter { reviewNodeIDs.contains($0.nodeID) }
            .compactMap { $0.output?[ReviewFindings.driftKey]?.stringValue }
            .flatMap { $0.split(separator: "\n") }
        guard !lines.isEmpty else { return }
        for line in lines {
            backlog.appendNote(itemID: item.id, String(line))
        }
        appendLog("\(lines.count) review finding\(lines.count == 1 ? "" : "s") flagged as scope drift "
                  + "for \(item.id) — recorded in the item's Notes, not sent to the worker as a fix")
    }

    /// Records an item that cleared the objective bar. Passing is not the same as
    /// acceptance: unless the approval gate is off, park at Awaiting Approval for
    /// a human. `why` explains what cleared it (review, or a salvaged verify).
    ///
    /// `reviewPassed` says which of those two cleared it, because only one of
    /// them can be approved unattended: a run salvaged by its own `verify:`
    /// never reached a passing review, and `approveReviewPassedRuns` approves
    /// review-passed runs. It also decides whether the human is summoned now or
    /// the summons is held — see below.
    private func accept(
        _ item: BacklogItem,
        backlog: BacklogViewModel,
        duration: TimeInterval,
        why: String,
        reviewPassed: Bool
    ) async -> ItemResult {
        if backlog.workflow.stageAfterAgentReview == .done {
            appendLog("Passed: \(item.title) — \(why); marked Done (approval gate off)")
            backlog.markDone(itemID: item.id, queries: nil, cost: nil)
            return ItemResult(id: item.id, title: item.title, outcome: .done, duration: duration)
        }
        appendLog("Passed: \(item.title) — \(why); awaiting your approval")
        backlog.updateItemStatus(itemID: item.id, newStatus: .awaitingApproval)
        // Known the moment the item reaches the gate, rather than only once a
        // human clicks Approve and the merge itself discovers a conflict.
        await refreshGateFreshnessIfPossible(backlog: backlog)
        // The gate is the point of the whole run: nothing else moves until a
        // human looks. Tell them, wherever they are.
        //
        // Unless this run is about to publish the work as a pull request and
        // follow its checks: a gate opened on a red PR summons a human to do
        // exactly what `PullRequestChecks` is there to do unattended, which is
        // the human being re-inserted below the gate ADR-0001 put them above. So
        // the summons is *held* and fired when the PR is green — or when the
        // loop gives up, with the failing check attached. Held, never dropped:
        // `flushGateNotification` runs on every path out of the item, including
        // the one where no pull request could be opened at all.
        //
        // And unless this project approves review-passed runs itself, which is
        // the same argument one step further: the run is about to resolve this
        // gate, and a person woken to approve what has already been approved is
        // being summoned to nothing. Held rather than dropped, because the run
        // may yet leave the item here — a merge it attempted and could not keep
        // does exactly that, and then the summons is the only thing that says so.
        let gate = GateNotification(
            title: "Approval needed in \(projectName ?? "this project")",
            body: "\(item.id) — \(item.title)",
            itemID: item.id
        )
        if openPullRequest || (approveReviewPassedRuns && reviewPassed) {
            pendingGateNotification = gate
        } else {
            notify(gate: gate, detail: nil)
        }
        return ItemResult(id: item.id, title: item.title, outcome: .awaitingApproval, duration: duration)
    }

    /// Who resolves the approval gate an item has ended at.
    enum GateResolution: Equatable {
        /// The run approves it itself: `approveReviewPassedRuns` is on and the
        /// reviewer passed. The item goes to Done, recorded as an automatic
        /// approval, and everything downstream of an approval follows.
        case automatic
        /// Exactly what every run did before the setting existed — the item is
        /// left for a person. Covers the item parked at the gate *and* the one
        /// that never reached a gate at all, because neither is something this
        /// run may resolve.
        case human
    }

    /// The whole rule for `approveReviewPassedRuns`, in one place so it can be
    /// read and tested without a run.
    ///
    /// Four things have to hold, and each of the other answers is a case the
    /// setting deliberately does not cover:
    ///
    /// - the item is **at the gate** — a blocked, cancelled or rejected run has
    ///   no gate to clear and routes exactly as it does today;
    /// - the **setting is on** for this project;
    /// - the **reviewer passed**, rather than the run being salvaged by its own
    ///   `verify:` — that is the objective bar, not a review, and the setting
    ///   says review-passed;
    /// - **no merge was attempted and refused**. A refused merge leaves the work
    ///   unlanded, and approving over it would stamp Done on a branch `main` has
    ///   never seen — the failure `resolveGate` refuses for the same reason.
    /// Whether this run should merge its own branch — the question that has to
    /// be asked *before* the merge, because merging is what an approval does.
    ///
    /// It is `autoMergeOnApproval` **and** a gate that is going to clear itself.
    /// The second half is the part that was missing: the merge used to run on
    /// `autoMergeOnApproval` alone, mark the item `done`, and thereby consume
    /// the `.awaitingApproval` state `gateResolution` reads — so with
    /// `approveReviewPassedRuns` **off**, work still reached `main` with nobody
    /// looking, and the setting that exists to keep a person in the loop had no
    /// effect whenever the merge succeeded.
    ///
    /// `mergeRefusal` is deliberately nil here: no merge has been attempted yet,
    /// so there is no refusal to weigh. The real resolution afterwards is given
    /// the refusal, which is what stops a failed merge being stamped Done.
    nonisolated static func shouldAutoMerge(
        outcome: ItemResult.Outcome,
        hasBranch: Bool,
        autoMergeOnApproval: Bool,
        reviewPassed: Bool,
        autoApproveReviewPassed: Bool
    ) -> Bool {
        guard autoMergeOnApproval, hasBranch else { return false }
        guard case .awaitingApproval = outcome else { return false }
        return gateResolution(outcome: outcome,
                              reviewPassed: reviewPassed,
                              autoApproveReviewPassed: autoApproveReviewPassed,
                              mergeRefusal: nil) == .automatic
    }

    nonisolated static func gateResolution(
        outcome: ItemResult.Outcome,
        reviewPassed: Bool,
        autoApproveReviewPassed: Bool,
        mergeRefusal: String?
    ) -> GateResolution {
        guard case .awaitingApproval = outcome else { return .human }
        guard autoApproveReviewPassed, reviewPassed, mergeRefusal == nil else { return .human }
        return .automatic
    }

    /// What the item's Notes say when the setting, rather than a person, cleared
    /// the gate. It is the only thing that tells the two apart when someone
    /// reads the night in the morning, so it says plainly that nobody looked.
    ///
    /// `unmergedBranch` is the item's branch when its work is still sitting on
    /// one — an approval with `autoMergeOnApproval` off lands nothing, and an
    /// item that reads Done with commits `main` has never seen has to say where
    /// they are. Nil when the run had no branch at all.
    nonisolated static func automaticApprovalNote(unmergedBranch: String?) -> String {
        let base = "Approved automatically: the reviewer passed and this project has "
            + "\"approve review-passed runs\" on. No human accepted this item."
        guard let unmergedBranch, !unmergedBranch.isEmpty else { return base }
        return base + " The work is on branch \(unmergedBranch) and has not been merged — "
            + "autoMergeOnApproval is off, so it is waiting for a human merge."
    }

    /// The summons a human gets when an item reaches the approval gate, held
    /// between the moment the gate opens and the moment the run knows whether
    /// the pull request behind it is green.
    struct GateNotification: Equatable {
        let title: String
        let body: String
        /// The item waiting at the gate, so the notice in the inbox can open its
        /// page rather than only naming it.
        let itemID: String
    }

    /// Fires the held summons, if there is one, and forgets it — so calling this
    /// twice on one item notifies once.
    private func flushGateNotification(detail: String? = nil) {
        guard let pending = pendingGateNotification else { return }
        pendingGateNotification = nil
        notify(gate: pending, detail: detail)
    }

    private func notify(gate: GateNotification, detail: String?) {
        orchestrator?.notify(
            agentID: workerAgentID ?? "",
            type: .approval,
            title: gate.title,
            body: Self.gateNotificationBody(gate.body, detail: detail),
            itemID: gate.itemID,
            projectPath: projectRoot?.path(percentEncoded: false)
        )
    }

    /// What the human reads: the item, plus the state of its pull request when
    /// there is one to report. The detail is the difference between "go and
    /// look" and "go and look, CI is failing on `build`".
    nonisolated static func gateNotificationBody(_ base: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return base }
        return "\(base) — \(detail)"
    }

    /// The pull request's several clauses as one, in the order the stages ran:
    /// the checks, then the review comments. Nil when no stage had anything to
    /// say, so a run that reported nothing still reads as a bare summons rather
    /// than as one with an empty dash hanging off it.
    nonisolated static func joinedGateDetail(_ parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }

    /// Runs the item's verify against the run's tree after the run ended early, to
    /// decide whether its work is worth salvaging. Runs off the main actor (it's a
    /// build/test command). False when the item declares no verify — with no
    /// objective bar there is nothing to salvage on.
    ///
    /// Measured and recorded by `measureVerify`, exactly as the pre-review
    /// gate's is: this is the one acceptance that rests on nothing but a
    /// verify, so the verdict that decided it belongs on the run's record
    /// (`lastVerifyVerdict` → the metric record) and in the item's Notes —
    /// whether it salvaged the work or blocked the item.
    private func salvageVerifyPasses(item: BacklogItem, detail: BacklogItemDetail?,
                                     worktree: URL?, timeout: TimeInterval? = nil) async -> Bool {
        guard let verdict = await measureVerify(
            item: item, detail: detail, worktree: worktree, timeout: timeout ?? verifyTimeout,
            announcing: "Run ended early — re-checking verify for \(item.id) before blocking")
        else { return false }
        appendLog(verdict.passed
            ? "Verify passed for \(item.id) — salvaging the run's work"
            : "\(verdict.signal) for \(item.id) — nothing to salvage")
        return verdict.passed
    }

    /// The verify-coverage gate: does the run's diff reach past what the item's
    /// `verify:` exercises? Returns the failure to block on, or nil when it does
    /// not — which is the answer in every one of these cases:
    ///
    ///   * the project configured no `.kiteloop/verify-map.json` (the default —
    ///     this must not gate every project until someone writes a map);
    ///   * the run wasn't isolated, or produced no branch, so there is no diff
    ///     to compare and git can't be asked one;
    ///   * every changed file that matched a mapped glob is covered by a command
    ///     the item declared, or matched no glob at all.
    ///
    /// A map file that exists but contributes no rules — unparseable, or parsed
    /// to nothing usable — is logged and treated as absent: a typo in config must
    /// not block a finished run. So is a diff git can't be asked for — the gate
    /// still fails open, but a run that passed it having compared nothing says so
    /// rather than reading as covered.
    ///
    /// A gap is not the last word: `runCoverageGapCommandsOnRunTree` runs each
    /// missing command on the run's tree, and only one that fails or times out
    /// blocks.
    private func verifyCoverageGap(
        item: BacklogItem,
        detail: BacklogItemDetail?,
        branch: String?,
        isolated: Bool,
        worktree: URL?
    ) async -> String? {
        guard let projectRoot else { return nil }
        let (map, problem) = VerifyMapFile.loadReporting(
            for: KiteloopProject(rootURL: projectRoot))
        if let problem { appendLog(problem) }
        guard !map.isEmpty else { return nil }
        guard isolated, let branch, !branch.isEmpty else { return nil }

        guard let changed = await RunWorkEvidence.changedFiles(
            projectRoot: projectRoot, branch: branch) else {
            appendLog(VerifyCoverage.unreadableDiff(branch: branch))
            return nil
        }
        let verdict = VerifyCoverage.evaluate(
            changedFiles: changed,
            ranCommands: Self.declaredVerifyCommands(item: item, detail: detail),
            map: map
        )
        if verdict.isCovered { return nil }
        return await runCoverageGapCommandsOnRunTree(
            verdict: verdict, map: map, item: item, branch: branch, worktree: worktree)
    }

    /// Where a gap's commands run: the run's kept `worktree` when there is one,
    /// else `branch` checked out afresh into a scratch tree under the project's
    /// setup command, and removed after. The second is the usual case, not a
    /// fallback: the gate asks only of a run whose work stands, and a run that
    /// finished for approval or merge has had its worktree removed by teardown
    /// already — so until this checked the branch out, every such gap reached
    /// `runCoverageGapCommands` with no tree and blocked on the summary alone.
    /// A branch that cannot be checked out still blocks, saying why.
    private func runCoverageGapCommandsOnRunTree(
        verdict: VerifyCoverage.Verdict,
        map: VerifyCoverage.Map,
        item: BacklogItem,
        branch: String,
        worktree: URL?,
        timeout: TimeInterval? = nil
    ) async -> String? {
        if let worktree {
            return await runCoverageGapCommands(
                verdict: verdict, map: map, item: item, worktree: worktree, timeout: timeout)
        }
        guard let projectRoot else { return verdict.summary }
        let manager = WorktreeManager(projectRoot: projectRoot)
        let deadline = timeout ?? verifyTimeout
        appendLog("Coverage gap for \(item.id) — the run's worktree is gone; checking out \(branch) to run the check on")
        switch await manager.checkOutScratch(
            of: branch, setupCommand: effectiveWorktreeSetup.command, timeout: deadline) {
        case .failure(let failure):
            return verdict.summary + " — the run's tree could not be checked out to run it: " + failure.reason
        case .success(let tree):
            let reason = await runCoverageGapCommands(
                verdict: verdict, map: map, item: item, worktree: tree, timeout: deadline)
            await manager.removeScratchCheckout(tree)
            return reason
        }
    }

    /// Runs each command a coverage gap names in the run's worktree, under the
    /// verify gate's own deadline, rather than blocking a finished run over a
    /// check nobody ran. Nil when every one passed — each is then noted on the
    /// item as passed. Otherwise the gap's summary plus the first failing
    /// command's exit (or its timeout) and the end of its output. With no
    /// worktree there is nothing to run in, and the summary blocks as it is.
    ///
    /// A rule's `runnable` spelling is what runs, not its prefix-only
    /// `command`. Not `measureVerify`: that verdict is the item's own verify's
    /// on the run's record, and these commands are not the item's verify.
    private func runCoverageGapCommands(
        verdict: VerifyCoverage.Verdict,
        map: VerifyCoverage.Map,
        item: BacklogItem,
        worktree: URL?,
        timeout: TimeInterval? = nil
    ) async -> String? {
        guard let worktree else { return verdict.summary }
        let timeout = timeout ?? verifyTimeout
        var passed: [(runnable: String, command: String)] = []
        for command in verdict.gaps.map(\.command) where !passed.contains(where: { $0.command == command }) {
            let runnable = map.rules.first { $0.command == command }?.runnable ?? command
            let redirected = WorktreeBuildOutput.redirectingBuilds(in: runnable, worktree: worktree)
            let gated = WorktreeManager.gateCommand(redirected, projectRoot: worktree)
            appendLog("Coverage gap for \(item.id) — running `\(runnable)` (deadline \(Int(timeout / 60))m)")
            let root = projectRoot
            let result = await Task.detached {
                WorktreeManager.runShellCapturingStatus(gated, in: worktree, timeout: timeout, projectRoot: root)
            }.value
            guard result.status == 0 else {
                return verdict.summary + " — " + Self.coverageGapFailure(runnable, result: result)
            }
            passed.append((runnable, command))
        }
        for check in passed {
            _ = backlogViewModel?.appendNote(itemID: item.id, Self.coverageGapPassNote(check, verdict: verdict))
        }
        return nil
    }

    /// The advisory a passing gap command leaves on the item: what ran, for
    /// which verify-map rules, and that the item's verify never named it.
    private static func coverageGapPassNote(
        _ check: (runnable: String, command: String), verdict: VerifyCoverage.Verdict
    ) -> String {
        let globs = verdict.gaps.filter { $0.command == check.command }.map { "`\($0.glob)`" }
        return "ran `\(check.runnable)` for \(globs.joined(separator: ", ")) on the run's tree — passed (exit 0); "
            + "verify never named `\(check.command)`, which the verify map asks for"
    }

    /// How one gap command failed, for the reason the run is blocked with: its
    /// exit status, or that the deadline killed it, then the end of its output.
    private static func coverageGapFailure(
        _ command: String, result: (status: Int32, output: String, timedOut: Bool)
    ) -> String {
        let how = result.timedOut
            ? "`\(command)` timed out before it answered"
            : "`\(command)` failed (exit \(result.status))"
        let tail = RunVerifyVerdict.tail(of: result.output)
        return tail.isEmpty ? how : how + "\n\n```\n" + tail + "\n```"
    }

    /// Routes `DiffRules`' findings for a run whose work stands: a blocking
    /// finding blocks the item with its reason, an advisory one is noted on it.
    /// Anything already turned back is left alone.
    private func applyDiffRules(
        item: BacklogItem,
        itemResult: ItemResult,
        duration: TimeInterval,
        isolated: Bool
    ) async -> ItemResult {
        guard let backlogViewModel else { return itemResult }
        switch itemResult.outcome {
        case .blocked, .cancelled, .alreadyImplemented, .investigation, .usageLimitParked:
            return itemResult
        case .awaitingApproval, .done:
            break
        }
        var result = itemResult
        for finding in await diffRuleFindings(item: item, branch: itemResult.branch, isolated: isolated) {
            switch finding.severity {
            case .blocking:
                appendLog("Blocked: \(item.title) — \(finding.text)")
                backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .blocked)
                result = ItemResult(id: item.id, title: item.title,
                                    outcome: .blocked(finding.text), duration: duration,
                                    branch: itemResult.branch)
            case .advisory:
                appendLog("Note: \(item.title) — \(finding.text)")
                _ = backlogViewModel.appendNote(itemID: item.id, finding.text)
            }
        }
        return result
    }

    /// `DiffRules` over what the run changed: empty when the run is not
    /// isolated (no branch to diff) or git cannot be asked, for the reason
    /// `verifyCoverageGap` fails open in the same cases.
    private func diffRuleFindings(
        item: BacklogItem,
        branch: String?,
        isolated: Bool
    ) async -> [DiffRules.Finding] {
        guard let projectRoot, isolated, let branch, !branch.isEmpty else { return [] }
        guard let changed = await RunWorkEvidence.changedFiles(projectRoot: projectRoot, branch: branch) else {
            return []
        }
        let diffText = await Self.branchDiffText(projectRoot: projectRoot, branch: branch)
        return DiffRules.evaluate(changedFiles: changed, itemID: item.id, itemTitle: item.title, diffText: diffText)
    }

    /// The same `HEAD...branch` range `RunWorkEvidence.changedFiles` reads its
    /// paths from, in patch form — what `DiffRules`' secret-pattern rule scans
    /// an added line against. Empty, not nil, when git couldn't answer:
    /// `evaluate` treats an empty diff as nothing to scan, same as no diff.
    private static func branchDiffText(projectRoot: URL, branch: String) async -> String {
        let root = projectRoot.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            let result = SubprocessOutput.git(["-C", root, "diff", "HEAD...\(branch)"])
            return result.status == 0 ? result.output : ""
        }.value
    }

    /// The commands the item declares as its objective bar, as written — the
    /// union of the groomed detail's and the item line's, not one preferred
    /// over the other. Unlike `salvageVerifyCommand` these are not rewritten
    /// for a worktree: coverage compares them against a repo-level map, and a
    /// `-derivedDataPath` the run added is not part of what the map's author
    /// wrote.
    ///
    /// A groomed list used to crowd the line out entirely, so widening the
    /// line's `verify:` to satisfy the map did nothing while the frontmatter
    /// stayed non-empty — the gate blocked on a command the operator could
    /// see plainly declared (`item-verify-has-two-sources-and-the-quiet-one-wins`).
    static func declaredVerifyCommands(item: BacklogItem, detail: BacklogItemDetail?) -> [String] {
        var out = (detail?.verifyCommands ?? [])
            .map { $0.cmd.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let verify = (item.verify ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !verify.isEmpty, !out.contains(verify) {
            out.append(verify)
        }
        return out
    }

    /// Whether the item's two verify sources disagree loudly enough to tell a
    /// human: both non-empty, and neither's text is a whitespace-normalized
    /// substring of the other — the same containment `VerifyCoverage.wasRun`
    /// uses to decide a command was run, so a line widened to also cover the
    /// frontmatter's command (or vice versa) is agreement, not a split.
    /// `declaredVerifyCommands` already unions both for execution; this exists
    /// only to name the split before it costs a run, for the operator who
    /// edits one source without noticing the other still stands.
    static func verifySourceDisagreement(item: BacklogItem, detail: BacklogItemDetail?) -> String? {
        let groomed = (detail?.verifyCommands ?? [])
            .map { $0.cmd.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !groomed.isEmpty else { return nil }
        let line = (item.verify ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let normalizedLine = Self.normalizeVerifyWhitespace(line)
        let agrees = groomed.contains { command in
            let normalizedCommand = Self.normalizeVerifyWhitespace(command)
            return normalizedCommand.contains(normalizedLine) || normalizedLine.contains(normalizedCommand)
        }
        guard !agrees else { return nil }

        return "verify: the backlog line and the detail frontmatter disagree — "
            + "line: `\(line)`; frontmatter: \(groomed.map { "`\($0)`" }.joined(separator: ", ")). "
            + "Both run (the worker and the coverage gate union them), but only one is likely "
            + "what you meant to edit."
    }

    /// Collapses whitespace runs so a command written across two lines and the
    /// same command on one line compare equal — matching `VerifyCoverage`'s
    /// own normalization, kept separate since that type's is private.
    private static func normalizeVerifyWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The item's verify as it is actually run, and the tree it runs in: the
    /// one answer both the pre-review gate (`measureVerifyForRecord`) and the
    /// salvage re-check (`salvageVerifyPasses`) take theirs from, so the two
    /// cannot judge one tree differently. Nil when the item declares no verify,
    /// or there is no directory to run it in.
    ///
    /// The command is wrapped in `WorktreeManager.gateCommand` against that
    /// directory — the same wrapping the merge gate's own steps run under. An
    /// isolated run's command already names the worktree's DerivedData, so the
    /// rewrite is a no-op there; a live-tree run's `xcodebuild` would otherwise
    /// build into the DerivedData the launching Xcode shares, which is exactly
    /// the reuse that once had the merge gate refuse a tree for a call that did
    /// exist. A verdict on the record has to be a reading of the tree the run
    /// is sitting in.
    private func verifyRun(
        for item: BacklogItem,
        detail: BacklogItemDetail?,
        worktree: URL?
    ) -> (command: String, directory: URL)? {
        guard let declared = Self.salvageVerifyCommand(item: item, detail: detail, worktree: worktree),
              let directory = worktree ?? projectRoot else { return nil }
        return (WorktreeManager.gateCommand(declared, projectRoot: directory), directory)
    }

    /// The command that decides whether a cut-short run's work still stands: the
    /// item's groomed verify commands (all must pass), else its `verify:` field.
    /// Nil when it declares none. On an isolated run its builds are pointed at the
    /// worktree's disposable DerivedData (`WorktreeBuildOutput`), so a salvage
    /// re-check doesn't leave a build tree behind after the worktree is gone.
    static func salvageVerifyCommand(
        item: BacklogItem,
        detail: BacklogItemDetail?,
        worktree: URL? = nil
    ) -> String? {
        let groomed = (detail?.verifyCommands ?? [])
            .map { $0.cmd.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let command: String?
        if !groomed.isEmpty {
            command = groomed.joined(separator: " && ")
        } else if let verify = item.verify?.trimmingCharacters(in: .whitespacesAndNewlines), !verify.isEmpty {
            command = verify
        } else {
            command = nil
        }
        return command.map { WorktreeBuildOutput.redirectingBuilds(in: $0, worktree: worktree) }
    }

    /// Predicted per-item cost — the precedence chain lives in `CostGovernor`.
    func predictedCostUSD(for item: BacklogItem) -> Double? {
        costGovernor.predictedCostUSD(for: item)
    }

    /// `predictedCostUSD` plus the rung it came from, for the cap log line.
    func predictedCost(for item: BacklogItem) -> CostGovernor.Prediction? {
        costGovernor.predictedCost(for: item)
    }

    /// The one-line budget statement logged before each item runs.
    func costCapLogLine(for item: BacklogItem) -> String {
        costGovernor.capLogLine(for: item)
    }

    private func awaitWorkflowCompletion(executionID: String) async -> ExecutionStatus {
        guard let orchestrator else { return .failed }

        // Two nodes, deliberately apart. `lastAnnouncedNode` is the one the run
        // has opened a span and written a phase row for, so it only moves once
        // `hasStarted(node:)` says the node is really running. `lastObservedNode`
        // is what the execution said on the previous poll, whether or not it had
        // started — which is what the watchdog below has to compare against, or a
        // node that never starts reads as one that keeps changing.
        var lastAnnouncedNode = ""
        var lastObservedNode = ""
        var lastStepCount = -1
        var pollCount = 0
        // Announced once, the poll after the clarify node's timeout fallback
        // wrote it (`WorkflowNode.TimeoutFallback`) — state carries it forward
        // for the rest of the run, so this guards against logging it again on
        // every later poll.
        var clarifyTimeoutAnnounced = false
        let stallTimeout = TimeInterval(max(1, stallTimeoutMinutes) * 60)
        // The item the phase lines below belong to. Read once: the queue can be
        // emptied by `stop()` while this loop is still winding down.
        let itemID = runQueue.indices.contains(currentIndex) ? runQueue[currentIndex].id : nil

        while true {
            try? await Task.sleep(for: .seconds(2))
            pollCount += 1
            guard let execution = await orchestrator.workflowEngine.execution(id: executionID) else {
                closeCurrentSpan(outcome: .failed("execution lost"))
                return .failed
            }

            switch await sampleCost(execution: execution, executionID: executionID, itemID: itemID,
                                    orchestrator: orchestrator, pollCount: pollCount) {
            case .carryOn: break
            case .nextPoll: continue
            case .end(let status): return status
            }

            announceClarifyTimeoutIfNeeded(
                execution: execution, executionID: executionID, itemID: itemID,
                orchestrator: orchestrator, announced: &clarifyTimeoutAnnounced
            )

            // Stall watchdog: reset the clock on any progress — a node transition,
            // a new step, or the executing agent actively working. If none of those
            // happen for `stallTimeout` while the run is live, end it (a hung node,
            // e.g. an agent stuck at a permission prompt, would otherwise wait forever).
            let runningAgentID = agentID(forNode: execution.currentNode)
            if Self.madeProgress(
                node: execution.currentNode,
                previousNode: lastObservedNode,
                stepCount: execution.steps.count,
                previousStepCount: lastStepCount,
                agentWorking: isWorking(agentID: runningAgentID, orchestrator: orchestrator)
            ) {
                lastActivityAt = Date()
            }
            lastObservedNode = execution.currentNode
            lastStepCount = execution.steps.count

            if let stalled = await handleStall(
                execution: execution, executionID: executionID, itemID: itemID,
                activeAgentID: runningAgentID, lastProgressAt: lastActivityAt, stallTimeout: stallTimeout
            ) {
                return stalled
            }

            announceNodeTransitionIfNeeded(
                execution: execution, executionID: executionID, itemID: itemID,
                orchestrator: orchestrator, lastAnnouncedNode: &lastAnnouncedNode
            )

            guard let ending = Self.runOutcome(for: execution.status) else { continue }
            closeCurrentSpan(outcome: ending.span)
            return ending.status
        }
    }

    /// The agent the node running now belongs to — the one a cost cap or a stall
    /// has to stop, and the one whose state says whether the run is still moving.
    private func agentID(forNode node: String) -> String? {
        Self.isWorkerNode(node) ? workerAgentID : reviewerAgentID
    }

    /// Whether that agent is mid-turn, which counts as progress for the watchdog
    /// even on a poll where neither the node nor the step count moved.
    private func isWorking(agentID: String?, orchestrator: Orchestrator) -> Bool {
        agentID.flatMap { id in orchestrator.agents.first(where: { $0.id == id })?.state } == .working
    }

    /// How each way of ending reads on the span it closes: the one that
    /// succeeded, and the three whose failure text says which ending it was.
    /// A table rather than a switch because it answers one question only — how
    /// an ending reads. *Which* statuses end a run is `ExecutionStatus`'s own
    /// `isTerminal`, and `testTheEndingTableCoversExactlyTheTerminalStatuses`
    /// pins the two together, so a status added to the model without a reason
    /// here fails a test rather than leaving the poll loop spinning on it.
    private nonisolated static let endingSpanOutcomes: [ExecutionStatus: ExecutionSpan.SpanOutcome] = [
        .completed: .success,
        .failed: .failed("failed"),
        .cancelled: .failed("cancelled"),
        .timedOut: .failed("timed out"),
    ]

    /// How a finished execution ends the poll loop: the status handed back, and
    /// the outcome the open span is closed with. Nil while the execution is still
    /// live — the loop's cue to poll again.
    nonisolated static func runOutcome(
        for status: ExecutionStatus
    ) -> (status: ExecutionStatus, span: ExecutionSpan.SpanOutcome)? {
        guard let span = endingSpanOutcomes[status] else { return nil }
        return (status, span)
    }

    // MARK: - Cost sampling

    /// What one cost sample asks of the poll loop that took it.
    enum CostSampleOutcome: Equatable {
        /// Nothing this poll has to act on — finish it as usual.
        case carryOn
        /// The item cap was recorded and the run keeps developing; this poll ends
        /// here, so nothing below the sample runs on it.
        case nextPoll
        /// A cap ended the run — hand this status back to the caller.
        case end(ExecutionStatus)
    }

    /// Live spend: sampled every ~16s to bound trace reads, and sampled whether or
    /// not a cap is set — it's what the panel's cost readout shows. With caps set
    /// it also decides whether to end the run: past this item's own ceiling, or
    /// past the session cap (which additionally pauses autopilot). `breach` is nil
    /// when neither cap exists, so an uncapped run only pays for the sample.
    private func sampleCost(
        execution: WorkflowExecution, executionID: String, itemID: String?,
        orchestrator: Orchestrator, pollCount: Int
    ) async -> CostSampleOutcome {
        guard pollCount % 8 == 0,
              execution.status == .running || execution.status == .pending else { return .carryOn }
        let spent = await costForItem(executionID: executionID)
        warnOfNearCap(spent: spent, execution: execution, executionID: executionID,
                      itemID: itemID, orchestrator: orchestrator)

        guard let breach = costGovernor.sample(itemSpendUSD: spent) else { return .carryOn }
        let reason = CostGovernor.breachReason(breach, node: execution.currentNode)

        // The **item** cap is advisory: it records the overrun and lets the run
        // finish. Killing an item mid-review threw away work that had already been
        // paid for — twice on 2026-08-07, at $16.16 and $16.95, both during review
        // with the expensive part done. A number that tells you which items outgrew
        // their estimate is worth more than one that destroys them.
        //
        // The **session** cap stays hard. Something has to bound the night, and
        // that is the one that does.
        if case .item = breach {
            recordItemCapOverrun(reason: reason, spent: spent, execution: execution,
                                 executionID: executionID, itemID: itemID, orchestrator: orchestrator)
            return .nextPoll   // keep developing
        }
        return .end(await endRunOverCap(reason: reason, spent: spent, execution: execution,
                                        executionID: executionID, itemID: itemID,
                                        orchestrator: orchestrator))
    }

    /// Warns once, before the cap fires: the first sample past `warnThreshold` of
    /// this item's own effective cap. Read against the same `currentItemCapUSD`
    /// the breach check reads, so the two can't disagree about the ceiling.
    /// Ambient — an event, not a notification: nothing is asked of anyone, it's
    /// the same "worth watching, not worth a badge" shape as `cost-overrun`
    /// (`notifications-signal-vs-noise`).
    private func warnOfNearCap(
        spent: Double, execution: WorkflowExecution, executionID: String,
        itemID: String?, orchestrator: Orchestrator
    ) {
        guard let warning = costGovernor.nearCapWarning(itemSpendUSD: spent) else { return }
        appendLog("Approaching cost cap — \(warning.logLine) on \(execution.currentNode)")
        logPhase(.itemNearCap, [
            ("item", itemID),
            ("execution", executionID),
            ("node", execution.currentNode),
            ("cause", "cost-cap-warning"),
            ("capUSD", Self.usdField(warning.capUSD)),
            ("spentUSD", Self.usdField(warning.spentUSD)),
        ], isError: false)
        orchestrator.publishEvent(KiteloopEvent(
            source: "Autopilot", type: .custom,
            payload: ["kind": "cost-warning", "item": itemID ?? executionID,
                      "capUSD": Self.usdField(warning.capUSD),
                      "spentUSD": Self.usdField(warning.spentUSD)]
        ))
        orchestrator.notify(
            agentID: "",
            type: .event,
            title: "Approaching cost cap",
            body: "\(itemID ?? executionID): \(warning.logLine)",
            itemID: itemID,
            projectPath: projectRoot?.path(percentEncoded: false)
        )
    }

    /// Counts an item that outgrew its own ceiling, once — the advisory half of
    /// the cap. The run carries on from here.
    private func recordItemCapOverrun(
        reason: String, spent: Double, execution: WorkflowExecution,
        executionID: String, itemID: String?, orchestrator: Orchestrator
    ) {
        // `itemID` is nil only when the queue index has moved on; fall back to the
        // execution so an overrun is still counted.
        let overrunID = itemID ?? executionID
        guard !costOverrunItemIDs.contains(overrunID) else { return }
        costOverrunItemIDs.insert(overrunID)
        appendLog("Over item cap — \(reason); continuing (advisory). "
                  + "\(costOverrunItemIDs.count) item(s) over cap this session")
        logPhase(.itemOverBudget, [
            ("item", itemID),
            ("execution", executionID),
            ("node", execution.currentNode),
            ("cause", "cost-cap-advisory"),
            ("reason", reason),
            ("spentUSD", Self.usdField(spent)),
            ("overrunCount", String(costOverrunItemIDs.count)),
        ], isError: false)
        orchestrator.publishEvent(KiteloopEvent(
            source: "Autopilot", type: .custom,
            payload: ["kind": "cost-overrun", "item": overrunID,
                      "reason": reason,
                      "spentUSD": Self.usdField(spent),
                      "overrunItems": String(costOverrunItemIDs.count)]
        ))
    }

    /// Ends the run on the hard half of the cap: stop the agent that is spending,
    /// cancel the execution, and hand `.timedOut` back to the poll loop.
    private func endRunOverCap(
        reason: String, spent: Double, execution: WorkflowExecution,
        executionID: String, itemID: String?, orchestrator: Orchestrator
    ) async -> ExecutionStatus {
        appendLog("Cost cap — \(reason); ending run")
        logPhase(.itemAbort, [
            ("item", itemID),
            ("execution", executionID),
            ("node", execution.currentNode),
            ("cause", "cost-cap"),
            ("reason", reason),
            ("spentUSD", Self.usdField(spent)),
        ], isError: true)
        lastStallReason = reason
        if let running = agentID(forNode: execution.currentNode) { orchestrator.stopAgent(running) }
        await orchestrator.cancelWorkflow(executionID: executionID)
        orchestrator.publishEvent(KiteloopEvent(
            source: "Autopilot",
            type: .workflowFailed,
            payload: ["executionID": executionID, "reason": reason, "node": execution.currentNode]
        ))
        closeCurrentSpan(outcome: .failed("cost cap"))
        return .timedOut
    }

    // MARK: - Node transitions

    /// Closes the span the run is leaving, opens the one it has entered, and says
    /// so on the board, in the run log and on the phase stream — once per node,
    /// and only once the node has actually started.
    private func announceNodeTransitionIfNeeded(
        execution: WorkflowExecution, executionID: String, itemID: String?,
        orchestrator: Orchestrator, lastAnnouncedNode: inout String
    ) {
        guard execution.currentNode != lastAnnouncedNode,
              hasStarted(node: execution.currentNode) else { return }

        if !lastAnnouncedNode.isEmpty {
            closeSpan(leaving: lastAnnouncedNode, entering: execution.currentNode)
        }
        lastAnnouncedNode = execution.currentNode

        let attempt = execution.steps.filter { $0.nodeID == "reviewer" }.count + 1
        let agentName = openSpan(forNode: execution.currentNode, orchestrator: orchestrator)
        updateBoardStatus(forNode: execution.currentNode, itemID: itemID)
        announceNodeStart(node: execution.currentNode, agentName: agentName, attempt: attempt,
                          itemID: itemID, executionID: executionID)
    }

    /// A rejection can arrive from either review node — the reviewer's own answer,
    /// or the follow-up ask that finally put a verdict on it. Both send the item
    /// back to the worker, and the span should say so either way.
    private func closeSpan(leaving previous: String, entering next: String) {
        let cameFromReview = previous == "reviewer"
            || previous == Self.reviewerClarifyNodeID
        let outcome: ExecutionSpan.SpanOutcome = Self.isWorkerNode(next) && cameFromReview
            ? .failed("review failed") : .success
        closeCurrentSpan(outcome: outcome)
    }

    /// Opens the span for the node just entered, and answers with the agent name
    /// the log line and phase row below it carry.
    private func openSpan(forNode node: String, orchestrator: Orchestrator) -> String {
        let running = agentID(forNode: node)
        let agentName = orchestrator.agents.first { $0.id == running }?.name ?? node
        currentItemSpans.append(ExecutionSpan(nodeID: node, agentName: agentName, startedAt: Date()))
        return agentName
    }

    /// The board follows the run: the item reads In Review for as long as the
    /// reviewer holds it, and Active again when a rejection sends the work back
    /// for another round. `itemStatus` is the whole decision, including the
    /// project that wants none of it — see it for why each node answers as it
    /// does. Not for a gate-refresh round: its worker node is the same node ID a
    /// real item's run uses, and `itemID` here is whatever item the *outer* run
    /// loop last touched, which a refresh started after that loop finished is not.
    private func updateBoardStatus(forNode node: String, itemID: String?) {
        guard let itemID, let backlogViewModel, !isRunningGateRefresh,
              let stage = Self.itemStatus(forNode: node,
                                          useReviewStage: backlogViewModel.workflow.useReviewStage)
        else { return }
        backlogViewModel.updateItemStatus(itemID: itemID, newStatus: stage)
    }

    /// Writes the node's arrival where a person reads it: the panel's status, the
    /// run log and the phase stream. A node `nodeEntry` says nothing about leaves
    /// all three alone — its span is already open either way.
    private func announceNodeStart(node: String, agentName: String, attempt: Int,
                                   itemID: String?, executionID: String) {
        guard let entry = Self.nodeEntry(forNode: node, attempt: attempt) else { return }
        status = entry.isReview
            ? .reviewing(itemIndex: currentIndex, total: runQueue.count, attempt: attempt)
            : .running(itemIndex: currentIndex, total: runQueue.count)
        appendLog(entry.message)
        logPhase(entry.phase, [
            ("item", itemID),
            ("execution", executionID),
            ("agent", agentName),
            ("attempt", String(attempt)),
        ])
    }

    /// How entering a node is announced.
    struct NodeEntry: Equatable {
        let phase: RunPhase
        let message: String
        /// Whether the panel reads the node as reviewing rather than running.
        let isReview: Bool
    }

    /// What the run says when it enters `nodeID` on its `attempt`-th review round —
    /// nil for a node it says nothing about, which is every node but the two the
    /// worker and the reviewer take turns on plus the clarify ask.
    nonisolated static func nodeEntry(forNode nodeID: String, attempt: Int) -> NodeEntry? {
        switch nodeID {
        case "worker":
            return NodeEntry(phase: .worker,
                             message: attempt > 1 ? "→ Worker (retry \(attempt - 1))" : "→ Worker started",
                             isReview: false)
        case "reviewer":
            return NodeEntry(phase: .reviewer, message: "→ Reviewer (attempt \(attempt))", isReview: true)
        // Still reviewing as far as the panel is concerned — the same attempt, not
        // a new one. Logged as its own phase because "the reviewer had to be asked
        // twice" is the signal that says whether the follow-up is carrying the run.
        case reviewerClarifyNodeID:
            return NodeEntry(phase: .reviewerClarify,
                             message: "→ Reviewer verdict unreadable — asking once for a pass/fail",
                             isReview: true)
        default:
            return nil
        }
    }

    /// The clarify node's own clock ran out and was resolved rather than
    /// failed (`WorkflowNode.TimeoutFallback`, `WorkflowEngine.resolveTimeoutFallback`).
    /// Surfaced once, promptly, out of `awaitWorkflowCompletion`'s poll loop —
    /// the note otherwise only shows up in a debugger's read of the finished
    /// state, and the run may continue for a long time yet. `announced` is
    /// the loop's own guard against logging it again on every later poll.
    private func announceClarifyTimeoutIfNeeded(
        execution: WorkflowExecution, executionID: String, itemID: String?,
        orchestrator: Orchestrator, announced: inout Bool
    ) {
        guard !announced, let note = Self.clarifyTimeoutFallbackNote(state: execution.state) else { return }
        announced = true
        appendLog("Reviewer clarify — \(note)")
        if let itemID { backlogViewModel?.appendNote(itemID: itemID, note) }
        logPhase(.reviewerClarifyTimeout, [
            ("item", itemID),
            ("execution", executionID),
            ("node", execution.currentNode),
            ("cause", "clarify-timeout"),
            ("reason", note),
        ], isError: false)
        orchestrator.publishEvent(KiteloopEvent(
            source: "Autopilot", type: .custom,
            payload: ["kind": "clarify-timeout", "item": itemID ?? executionID, "reason": note]
        ))
    }

    /// Ends the run as stalled once nothing has moved for `stallTimeout` — a
    /// hung node, e.g. an agent stuck at a permission prompt or one deferring
    /// hand-off on a background-agent launch that never got a next turn
    /// (`ChatViewModel.finishTurn`, `PendingAgentLaunch`), would otherwise wait
    /// forever. Returns the ended status, or nil to keep polling.
    private func handleStall(
        execution: WorkflowExecution, executionID: String, itemID: String?,
        activeAgentID: String?, lastProgressAt: Date, stallTimeout: TimeInterval
    ) async -> ExecutionStatus? {
        guard execution.status == .running || execution.status == .pending,
              Date().timeIntervalSince(lastProgressAt) > stallTimeout,
              let orchestrator else { return nil }

        let pendingAgents = activeAgentID.map { orchestrator.pendingBackgroundAgentCount(for: $0) } ?? 0
        var reason = "stalled: no progress for \(stallTimeoutMinutes) min on \(execution.currentNode)"
        if pendingAgents > 0 {
            reason += " — still waiting on \(pendingAgents) background agent\(pendingAgents == 1 ? "" : "s")"
            if let itemID { backlogViewModel?.appendNote(itemID: itemID, reason) }
        }
        appendLog("Stalled — \(reason); ending run")
        logPhase(.itemAbort, [
            ("item", itemID),
            ("execution", executionID),
            ("node", execution.currentNode),
            ("cause", "stall"),
            ("reason", reason),
            ("stallTimeoutMin", String(stallTimeoutMinutes)),
        ], isError: true)
        lastStallReason = reason
        if let activeAgentID { orchestrator.stopAgent(activeAgentID) }
        await orchestrator.cancelWorkflow(executionID: executionID)
        orchestrator.publishEvent(KiteloopEvent(
            source: "Autopilot",
            type: .workflowFailed,
            payload: ["executionID": executionID, "reason": reason, "node": execution.currentNode]
        ))
        closeCurrentSpan(outcome: .failed("stalled"))
        return .timedOut
    }

    /// Whether the node the execution has moved to is actually running.
    ///
    /// Every node but the two that read a diff starts the moment the execution
    /// enters it. Those wait on the pre-review evidence gate, which may never let
    /// them start at all — and the run loop, polling the execution, would
    /// otherwise open a span and log "→ Reviewer" for a run that reviewed
    /// nothing. One the gate lets through is announced on the next poll instead.
    private func hasStarted(node: String) -> Bool {
        Self.nodeHasStarted(node, reviewGateOpen: reviewGate == .open)
    }

    /// The rule behind `hasStarted(node:)`, apart from the gate that answers it
    /// so it can be asserted without an orchestrator.
    nonisolated static func nodeHasStarted(_ node: String, reviewGateOpen: Bool) -> Bool {
        isGatedReviewNode(node) ? reviewGateOpen : true
    }

    private func closeCurrentSpan(outcome: ExecutionSpan.SpanOutcome) {
        guard !currentItemSpans.isEmpty else { return }
        let lastIdx = currentItemSpans.count - 1
        currentItemSpans[lastIdx].completedAt = Date()
        currentItemSpans[lastIdx].outcome = outcome
    }

    private func appendLog(_ message: String) {
        autopilotLog.info("\(message)")
        log.append(LogEntry(timestamp: Date(), message: message))
        if log.count > Self.logCapacity {
            log.removeFirst(log.count - Self.logCapacity)
        }
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard let historyURL else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        runHistory = QuarantiningJSONFile.load(
            [RunRecord].self,
            from: historyURL,
            store: Self.historyStoreName,
            decoder: decoder,
            reporter: reporter
        ) ?? []
    }

    private func saveHistory() {
        guard let historyURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(runHistory) else { return }
        // Durably, not just `.atomic` — see `saveConfig()`: a write that fails
        // outright must be reported, not silently discarded, or the panel keeps
        // showing a run that is no longer on disk.
        do {
            try AtomicFileWriter.write(data, to: historyURL)
        } catch {
            reporter.report(store: Self.historyStoreName, operation: .write, url: historyURL, error: error)
        }
    }

    private func recordItemResult(_ result: ItemResult, executionID: String?) {
        // `outcomeString` rather than a second copy of the same switch: this
        // record and the metric row are read side by side, and the two spellings
        // had already been written out twice.
        let record = RunRecord.ItemRecord(
            id: result.id,
            title: result.title,
            outcome: Self.outcomeString(result.outcome),
            duration: result.duration,
            executionID: executionID,
            branch: result.branch,
            closingMessage: result.closingMessage,
            approval: result.approval?.rawValue,
            merged: result.merged,
            mergeCommit: result.mergeCommit
        )
        currentRunRecord?.items.append(record)
    }

    /// Files a judged score against the run rows for an item. Matches the *last*
    /// entry for the id in each list: an item re-run in the same session appears
    /// twice, and the score belongs to the pass that just finished.
    private func attachQualityScore(_ score: Double, itemID: String) {
        if let index = results.lastIndex(where: { $0.id == itemID }) {
            results[index].qualityScore = score
        }
        if let index = currentRunRecord?.items.lastIndex(where: { $0.id == itemID }) {
            currentRunRecord?.items[index].qualityScore = score
        }
    }

    /// The other half of `attachQualityScore`: files *why* an item has no score,
    /// against the same rows. Without it the run list can't tell a run the judge
    /// never saw from one it saw and scored badly.
    private func attachJudgeUnavailable(_ reason: RunQualityJudge.Unavailability, itemID: String) {
        if let index = results.lastIndex(where: { $0.id == itemID }) {
            results[index].judgeUnavailable = reason
        }
        if let index = currentRunRecord?.items.lastIndex(where: { $0.id == itemID }) {
            currentRunRecord?.items[index].judgeUnavailableReason = reason.rawValue
        }
    }

    private func finalizeRunRecord() {
        guard var record = currentRunRecord else { return }
        record.completedAt = Date()
        runHistory.insert(record, at: 0)
        if runHistory.count > 30 { runHistory.removeLast() }
        currentRunRecord = nil
        saveHistory()
    }

    // MARK: - Autopilot Config Persistence

    private struct AutopilotConfig: Codable {
        var workerAgentID: String?
        var reviewerAgentID: String?
        var maxRetries: Int?
        var dailyBudgetUSD: Double?
        /// Read from a file written before `approvalGate`, never written.
        var autoMergeOnApproval: Bool?
        var autoMergeVerifyCommand: String?
        var worktreeSetupCommand: String?
        var baseBranch: String?
        var openPullRequest: Bool?
        /// Read from a file written before `approvalGate`, never written.
        var approveReviewPassedRuns: Bool?
        var autonomousWorkEnabled: Bool?
        var approvalGate: ApprovalGate?
    }

    /// Put the tunable run settings — the cost caps, the cost margin and the
    /// behaviour flags — back to `Defaults`. The worker/reviewer assignment is
    /// deliberately left alone: resetting the knobs isn't disbanding the pair,
    /// and re-assigning agents is what `PUT /v1/autopilot` is for. Writes the
    /// config once rather than once per property.
    /// Whether every tunable run setting already holds its `Defaults` value —
    /// i.e. a reset would write nothing. The Autopilot tab's Reset control reads
    /// this so "nothing to reset" is a visibly disabled button rather than a
    /// button that appears to do something and doesn't.
    var isConfigAtDefaults: Bool {
        maxRetries == Defaults.maxRetries
            && dailyBudgetUSD == Defaults.dailyBudgetUSD
            && worktreeSetupCommand == nil
            && baseBranch == Defaults.baseBranch
            && openPullRequest == Defaults.openPullRequest
            && approvalGate == Defaults.approvalGate
            && autonomousWorkEnabled == Defaults.autonomousWorkEnabled
    }

    /// Whether a reset is offerable right now. Mirrors the control API's guard
    /// (`POST /v1/autopilot/reset` 409s mid-run): the caps are actively enforced
    /// against the running item, so clearing them out from under it would
    /// silently unbound a run in flight.
    var canResetConfigToDefaults: Bool { status == .idle && !isConfigAtDefaults }

    func resetConfigToDefaults() {
        isLoadingConfig = true
        maxRetries = Defaults.maxRetries
        // This project's own ceiling only. The portfolio's lives in the global
        // config and is deliberately not something a per-project reset can
        // clear.
        dailyBudgetUSD = Defaults.dailyBudgetUSD
        worktreeSetupCommand = nil
        baseBranch = Defaults.baseBranch
        openPullRequest = Defaults.openPullRequest
        // Back to asking. A reset is the way out of a session where nobody can
        // remember what was tuned, and the one knob it must not leave widened is
        // the one that decides whether a person is asked at all.
        approvalGate = Defaults.approvalGate
        // Reset disarms: the safe direction. Re-opting-in is one switch; a
        // reset that left a project enrolled in unattended work would be the
        // one widening nobody asked for.
        autonomousWorkEnabled = Defaults.autonomousWorkEnabled
        isLoadingConfig = false
        saveConfig()
    }

    private func loadConfig() {
        guard let url = configURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // No file is not a failure — there is nothing to have lost.
            configLoadFailure = nil
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            failConfigLoad(url: url, preserving: nil, step: "could not be read")
            return
        }
        guard let config = try? JSONDecoder().decode(AutopilotConfig.self, from: data) else {
            failConfigLoad(url: url, preserving: data, step: "could not be decoded")
            return
        }
        configLoadFailure = nil
        applyLoadedConfig(config)
    }

    /// Copies every field of a successfully decoded config onto the live
    /// properties, each through the same setter a person moving the slider
    /// would use — split out of `loadConfig()` so the read/decode branches
    /// that can fail carry their own, much smaller, complexity.
    ///
    /// The copy is split again by what the settings are *for*: the pair is
    /// named here, and the run knobs, the budget, the merge gate and the
    /// autonomy switches each land in their own helper below. A setting
    /// joining one of those groups then changes one small function instead of
    /// adding another branch to the one function every setting shared.
    private func applyLoadedConfig(_ config: AutopilotConfig) {
        isLoadingConfig = true
        // Both verbatim: a file that names no pair means no pair, not "leave
        // whoever is assigned" — clearing the assignment is a real setting.
        workerAgentID = config.workerAgentID
        reviewerAgentID = config.reviewerAgentID
        applyLoadedRunSettings(config)
        applyLoadedBudget(config)
        applyLoadedMergeGate(config)
        applyLoadedAutonomy(config)
        isLoadingConfig = false
    }

    /// How a run is attempted: how many retries it gets and which extra rounds
    /// it plays. Each is applied only when the
    /// file names it, so a key written by no older version leaves its property
    /// at the `Defaults` value rather than overwriting it with nothing.
    private func applyLoadedRunSettings(_ config: AutopilotConfig) {
        if let r = config.maxRetries { maxRetries = r }
    }

    /// What a run is allowed to spend: the project's one budget. The per-item
    /// cap is not a setting — it is read off the project's runs — so a file
    /// still holding `perItemCostCapUSD`, `costCapMargin` or
    /// `sessionCostCapUSD` loads with those keys ignored.
    private func applyLoadedBudget(_ config: AutopilotConfig) {
        dailyBudgetUSD = config.dailyBudgetUSD
    }

    /// The merge gate: whether an approval merges at all, what it runs on the
    /// way (`applyLoadedCommands`), and whether the landed branch is offered as
    /// a pull request.
    private func applyLoadedMergeGate(_ config: AutopilotConfig) {
        applyLoadedCommands(config)
        if let pr = config.openPullRequest { openPullRequest = pr }
    }

    /// The two settings that decide how much happens without anyone being
    /// asked: whether a review-passed run still stops at the approval gate,
    /// and whether the project is enrolled in unattended work at all. Each of
    /// them widens when it is read wrongly, so they are copied together where
    /// that is visible rather than spread through the rest of the load.
    /// A `protectedPaths` key in a config file written before that stopped
    /// being a setting is ignored.
    /// A file written before `approvalGate` carries its two switches instead,
    /// read the way `ApprovalGate.fromLegacy` reads them.
    private func applyLoadedAutonomy(_ config: AutopilotConfig) {
        approvalGate = config.approvalGate ?? .fromLegacy(approveReviewPassedRuns: config.approveReviewPassedRuns ?? false,
                                                      autoMergeOnApproval: config.autoMergeOnApproval ?? false)
        if let aw = config.autonomousWorkEnabled { autonomousWorkEnabled = aw }
    }

    /// The merge gate's own settings a loaded config carries — optional-string
    /// fields taken verbatim, nil being a real, cleared value for each rather
    /// than "absent" — split out so `applyLoadedMergeGate` doesn't grow a line
    /// for every one that joins them. The gate's timeout is not among them: it is
    /// derived from the project's own gate phases (`RunTimeouts`), so an old
    /// file's copy of it is read past like any other key no setting answers to.
    private func applyLoadedCommands(_ config: AutopilotConfig) {
        autoMergeVerifyCommand = config.autoMergeVerifyCommand
        worktreeSetupCommand = config.worktreeSetupCommand
        baseBranch = config.baseBranch
    }

    /// Records why `loadConfig()` gave up on `url`, and — when `data` is what
    /// was actually read from disk — preserves it before anything can write
    /// over it. `saveConfig()` runs on the very next setting change, from the
    /// defaults `loadConfig()` left every property at, and that write must not
    /// be the last copy of what was there before — so the message names both
    /// the config path that is about to be rewritten from defaults and the
    /// sibling that holds the only surviving copy, or says plainly that the
    /// copy never landed.
    ///
    /// The sibling is written once: a second failed load finds it already
    /// there and leaves it alone, so a later run — reading an
    /// already-overwritten `autopilot-config.json` — cannot clobber the one
    /// copy of the original.
    private func failConfigLoad(url: URL, preserving data: Data?, step: String) {
        let path = url.path(percentEncoded: false)
        let message = preservationMessage(forOriginalAt: path, data: data, url: url, step: step)
        configLoadFailure = message
        appendLog(message)
    }

    private func preservationMessage(forOriginalAt path: String, data: Data?, url: URL, step: String) -> String {
        let prefix = "Autopilot config at \(path) \(step) — using defaults; \(path) itself is rewritten from defaults on the next setting change"
        guard let data else { return prefix }
        let sibling = url.appendingPathExtension("unreadable")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return "\(prefix); the original bytes are preserved at \(sibling.path(percentEncoded: false))"
        }
        do {
            try data.write(to: sibling)
            return "\(prefix); the original bytes are preserved at \(sibling.path(percentEncoded: false))"
        } catch {
            return "Autopilot config at \(path) \(step) — using defaults; \(path) itself is rewritten from defaults on the next setting change, but the original bytes could not be preserved: \(error.localizedDescription)"
        }
    }

    /// A digest of everything in `.kiteloop/autopilot-config.json` — the pair,
    /// the caps, the flags.
    ///
    /// What it is for is `RunScheduling.ProjectHold`: a hold formed by two
    /// different items failing identically is not about either item, so nothing
    /// in the backlog clears it and this is half of what does. Taken off the
    /// same value `saveConfig` writes, so a setting that can be changed is a
    /// setting the hold notices.
    var configFingerprint: String { RunScheduling.fingerprint(currentConfig) }

    private var currentConfig: AutopilotConfig {
        AutopilotConfig(
            workerAgentID: workerAgentID,
            reviewerAgentID: reviewerAgentID,
            maxRetries: maxRetries,
            dailyBudgetUSD: dailyBudgetUSD,
            autoMergeOnApproval: nil,
            autoMergeVerifyCommand: autoMergeVerifyCommand,
            worktreeSetupCommand: worktreeSetupCommand,
            baseBranch: baseBranch,
            openPullRequest: openPullRequest,
            approveReviewPassedRuns: nil,
            autonomousWorkEnabled: autonomousWorkEnabled,
            approvalGate: approvalGate
        )
    }

    private func saveConfig() {
        guard let url = configURL else { return }
        guard let data = try? JSONEncoder().encode(currentConfig) else { return }
        // Durably, not just `.atomic` — an unclean shutdown must never leave a
        // truncated config behind, because the next launch would read it as an
        // empty one and the first save would make that permanent.
        do {
            try AtomicFileWriter.write(data, to: url)
        } catch {
            // Every setter saves, so a config that has stopped saving looks
            // exactly like one nobody changed: the setting reverts on the next
            // launch and nothing anywhere said why. Discarding this error was
            // how that happened.
            reporter.report(store: Self.storeName, operation: .write, url: url, error: error)
        }
    }

    // MARK: - Work a run left behind
    //
    // The worktree lifecycle around a run — isolate, pin the agents, commit or
    // drop, restore — lives in `WorktreeSession`. What follows is only the
    // saying-so: git already holds the answer, and `RunWorkEvidence` is the one
    // place it is read, so the blocked path and the approval gate can't come to
    // different conclusions about whether a run produced anything.

    /// Says where a blocked run's work went — in the run log, in the item's
    /// Notes, and (via the return value) in the structured `item.end` line.
    ///
    /// Teardown commits a blocked run's changes and keeps its worktree, but that
    /// happens in silence: the item returns to the pile recording only that
    /// review did not pass, and a reader deciding whether to re-run has no way
    /// to know a previous attempt finished. On 2026-08-08 that cost three runs
    /// of one item, one of which had already implemented it.
    ///
    /// Returns nil when there is nothing to say. A run that genuinely produced
    /// nothing — the common dead-session case — must not be reported as having
    /// left work, and neither must an outcome that isn't blocked at all.
    private func reportWorkLeftBehind(
        item: BacklogItem,
        outcome: ItemResult.Outcome,
        teardown: WorktreeSession.Teardown?,
        isolated: Bool
    ) async -> RunWorkEvidence.LeftBehind? {
        guard case .blocked(let reason) = outcome else { return nil }
        let evidence = await RunWorkEvidence.leftBehind(
            projectRoot: projectRoot,
            branch: teardown?.branch,
            isolated: isolated,
            worktreePath: teardown?.worktreePath
        )
        guard let summary = evidence.summary else { return nil }
        appendLog("\(item.id): \(summary) — re-running starts over unless it is used")
        // The Notes are what the next run and the human both read. They get the
        // evidence as well as the reason: "review did not pass" alone is what
        // made a finished implementation look like nothing.
        backlogViewModel?.appendNote(
            itemID: item.id,
            "blocked (\(reason)) — \(summary). A re-run starts from scratch and replaces it.")
        return evidence
    }

    // MARK: - Steering a live run

    /// What came of an operator's attempt to hand the worker a note.
    ///
    /// A refusal carries its reason as text a panel can show, because every way
    /// this can fail is something the operator can act on — start a run, type
    /// something — and "nothing happened" is the one answer that leaves them
    /// wondering whether the note went somewhere.
    enum SteerOutcome: Equatable {
        /// Queued for the worker, carrying the note as it will be delivered.
        case sent(String)
        case refused(String)
    }

    /// Whether there is a worker in flight to steer — what the panel's note
    /// field is enabled by, and the reason sending with no run is a no-op rather
    /// than something that queues quietly for the next one.
    ///
    /// `.running` is the worker's phase and `.reviewing` is the reviewer's, so
    /// this is false for the whole of review. That is deliberate: the reviewer's
    /// independence is part of what its verdict is worth, and an operator who
    /// could lean on it mid-review would be reviewing their own run.
    var canSteer: Bool {
        guard isExecutingRun, workerAgentID != nil else { return false }
        if case .running = status { return true }
        return false
    }

    /// Hands `raw` to the worker of the run in flight, delivered at its next
    /// turn boundary (`RunSteerNote`).
    ///
    /// The note is recorded as it is queued — in the run log, in the phase log
    /// and in the item's `## Notes` — so a run whose worker never gets to read
    /// it still shows that someone tried to steer it. An unrecorded steer would
    /// make the run's outcome unattributable: nobody reading the merged diff
    /// afterwards could tell which decisions in it were the worker's own.
    ///
    /// Steering cannot approve, raise a cap, or touch the item or the reviewer.
    /// Nothing here reaches any of those — the note goes to one session, and the
    /// framing `RunSteerNote.prompt` wraps it in tells the worker the same.
    @discardableResult
    func steerWorker(_ raw: String) -> SteerOutcome {
        guard canSteer, let orchestrator, let worker = workerAgentID else {
            return .refused("No worker running — a note can only be handed to a run in flight")
        }
        guard let note = RunSteerNote.sanitize(raw) else {
            return .refused("Nothing to send")
        }

        orchestrator.queueSteerNote(note, for: worker)
        appendLog(RunSteerNote.logLine(note))
        logPhase(.workerSteer, [
            ("item", currentItemID),
            ("execution", currentExecutionID),
            ("agent", orchestrator.agents.first { $0.id == worker }?.name ?? worker),
            ("note", String(note.prefix(200))),
        ])
        if let itemID = currentItemID {
            backlogViewModel?.appendNote(itemID: itemID, RunSteerNote.itemNoteLine(note))
        }
        return .sent(note)
    }

    /// The item the run is on, or nil once the queue index has moved past it.
    private var currentItemID: String? {
        runQueue.indices.contains(currentIndex) ? runQueue[currentIndex].id : nil
    }

    /// Whether this item's worker has already been told its diff was empty.
    /// Reset where the hand-off check is installed, so "once" means once per
    /// item run — the worker node is visited again on every review rejection,
    /// and a worker that was told and still changed nothing has answered.
    private var toldWorkerDiffWasEmpty = false

    /// A teardown that had to commit the worker's files is an advisory finding
    /// on the item: the work reached the gate, but the worker handed off an
    /// uncommitted tree, and the commit carrying the run now reads
    /// `autopilot: <item-id>` — the app's subject, which two readers match to
    /// find stranded work and which looked, on 2026-09-03, like the worker's
    /// convention slipping in four of eight runs. The next worker pass reads
    /// the Notes, so the instruction to commit goes where it will be seen.
    private func noteTeardownCommit(_ teardown: WorktreeSession.Teardown?, item: BacklogItem) {
        guard let count = teardown?.committedByTeardown else { return }
        let note = "advisory: the worker left \(count) file(s) uncommitted; teardown committed them as "
            + "`\(RunWorkEvidence.teardownSubject(for: item.id))` — commit with the repository's own "
            + "subject convention before handing off"
        appendLog("\(item.id): \(note)")
        backlogViewModel?.appendNote(itemID: item.id, note)
    }

    /// What to say to a worker that is about to hand off, or nil to let its node
    /// complete untouched. Installed on the orchestrator for the length of an
    /// item's run; see `EmptyDiffHandoff` for why it exists.
    ///
    /// Four things have to hold before a word is said, and each of them is a way
    /// this could otherwise fire at the wrong agent: it must be the **worker**
    /// node (the reviewer's empty tree is normal — it reviews, it doesn't
    /// build), of **this item's** execution, **not already told**, and the run
    /// must be **isolated** — a live-tree run has no worktree to read and its
    /// edits are indistinguishable from a human's.
    private func emptyDiffHandoff(
        executionID: String,
        nodeID: String,
        session: WorktreeSession?
    ) async -> String? {
        guard nodeID == "worker",
              executionID == currentExecutionID,
              !toldWorkerDiffWasEmpty,
              let session else { return nil }

        // The same reader the post-run check uses, in the shape that fits a run
        // still in flight: nothing is committed yet, so the evidence is the
        // worktree itself — which is exactly what `inspectBlocked` reads.
        let verdict = await RunWorkEvidence.inspectBlocked(
            projectRoot: projectRoot,
            branch: session.branch,
            worktree: session.path,
            isolated: true
        )
        guard EmptyDiffHandoff.shouldTell(verdict: verdict, alreadyTold: toldWorkerDiffWasEmpty)
        else { return nil }

        toldWorkerDiffWasEmpty = true
        appendLog(EmptyDiffHandoff.logLine)
        logPhase(.workerEmptyDiff, [
            ("item", runQueue.indices.contains(currentIndex) ? runQueue[currentIndex].id : nil),
            ("execution", executionID),
            ("branch", session.branch),
        ])
        return EmptyDiffHandoff.prompt
    }

    /// What the worker said as it finished this execution, or nil when it said
    /// nothing — which is what a dead session leaves behind, and is reported as
    /// such rather than as a silence.
    ///
    /// Read off the execution's steps, so it is the *worker's* last words and
    /// not the reviewer's: a rejected item runs the worker again, and the run
    /// ended on the last of those attempts. `ChatViewModel` puts them there as
    /// each node completes — see `RunClosingMessage`.
    ///
    /// Raw, not condensed: the caller both quotes it (through
    /// `RunClosingMessage.phrase`, which condenses) and parses it for a
    /// structured claim, and a 300-character bound would leave the second
    /// reading a truncated object.
    /// Reads what the worker's turns came to on this execution into
    /// `lastWorkerTurns` and `workerCutShortTurns`. Leaves both as they were
    /// when the execution is gone — nothing read is not "not cut short".
    private func readWorkerTurns(executionID: String) async {
        guard let engine = orchestrator?.workflowEngine,
              let execution = await engine.execution(id: executionID) else { return }
        let maxTurns = await engine.registeredGraph(id: execution.graphID)?.nodes["worker"]?.maxTurns
        lastWorkerTurns = Self.workerTurns(in: execution.steps)
        workerCutShortTurns = Self.workerCutShortTurns(
            steps: execution.steps,
            engineTurns: await engine.turns(executionID: executionID, nodeID: "worker"),
            maxTurns: maxTurns)
    }

    /// Says a worker ran out of turns, in the run log and as one line in the
    /// item's Notes, and returns the reason the run ends on.
    private func noteWorkerCutShort(_ item: BacklogItem, turns: Int, backlog: BacklogViewModel?) -> String {
        let reason = Self.workerCutShortReason(turns: turns)
        appendLog("Blocked: \(item.title) — \(reason); skipping verify, the branch keeps the work")
        backlog?.appendNote(itemID: item.id, reason)
        return reason
    }

    private func workerClosingMessage(executionID: String) async -> String? {
        guard let orchestrator,
              let execution = await orchestrator.workflowEngine.execution(id: executionID)
        else { return nil }
        return RunClosingMessage.rawLastMessage(in: execution.steps, node: "worker")
    }

    /// What the item's last attempt left on its branch, read before this one
    /// starts. Nil when there is nothing there, when the run isn't isolated (no
    /// branch to read), or when git couldn't answer.
    private func previousAttemptWork(for item: BacklogItem) async -> RunWorkEvidence.LeftBehind? {
        guard useWorktree else { return nil }
        let evidence = await RunWorkEvidence.leftBehind(
            projectRoot: projectRoot,
            branch: WorktreeSession.branchName(for: item.id),
            isolated: true
        )
        return evidence.hasWork ? evidence : nil
    }

    // MARK: - Following the pull request's checks (ADR-0001)

    /// Follows the pull request this run just opened until its checks settle,
    /// handing a failing one back to the worker for at most
    /// `PullRequestChecks.maxFixRounds` rounds. Returns how it ended and what
    /// those rounds cost, for the caller to charge to the item.
    ///
    /// What has to be true before a run may follow at all — a project root to
    /// read checks from, and no empty-diff handoff left armed — and then the
    /// loop, which is `pollUntilChecksSettle`.
    private func followPullRequestChecks(
        item: BacklogItem,
        branch: String,
        url: String,
        executionID: String
    ) async -> (outcome: PullRequestChecks.Outcome, costUSD: Double) {
        guard let projectRoot else {
            return (.unavailable(reason: "the project has no root to read checks from"), 0)
        }
        // The empty-diff handoff belongs to the item's own workflow, which has
        // already finished; a fix round is a different execution and must not be
        // told the item's diff was empty. Cleared here rather than relied on to
        // no-op.
        orchestrator?.workflowHandoffCheck = nil

        appendLog("Following \(item.id)'s pull request checks — \(url)")
        return await pollUntilChecksSettle(
            item: item, branch: branch, url: url,
            executionID: executionID, projectRoot: projectRoot)
    }

    /// The following loop itself, once there is a root to read checks from:
    /// poll, ask `PullRequestChecks.next` what that reading means, do it,
    /// repeat. Separated from `followPullRequestChecks` because the two change
    /// for different reasons — what has to be true before a run may follow at
    /// all, against how a poll's answer is acted on.
    ///
    /// Every terminal state returns from here, so no path leaves a `gh` poll
    /// running behind a finished item.
    private func pollUntilChecksSettle(
        item: BacklogItem,
        branch: String,
        url: String,
        executionID: String,
        projectRoot: URL
    ) async -> (outcome: PullRequestChecks.Outcome, costUSD: Double) {
        let startedAt = Date()
        // The no-checks clock: the last moment checks could have started —
        // following began, or a fix round's push landed. Distinct from
        // `startedAt`, which is the deadline clock and never resets, because a
        // fix round's push gives GitHub a fresh commit to register checks
        // against.
        var noChecksOpportunityAt = startedAt
        var rounds = 0
        var costUSD = 0.0

        while true {
            // A stopped or paused run stops following: the queue is being torn
            // down and there is nobody left to spend the next round for.
            if shouldStop {
                return (.unavailable(reason: "the run was stopped before the checks settled"), costUSD)
            }
            let state = await PullRequestChecks.poll(pullRequest: url, in: projectRoot)
            let spent = await costForItem(executionID: executionID) + costUSD
            let step = PullRequestChecks.next(
                state: state,
                roundsUsed: rounds,
                elapsed: Date().timeIntervalSince(startedAt),
                sinceNoChecksOpportunity: Date().timeIntervalSince(noChecksOpportunityAt),
                canAffordFix: PullRequestChecks.canAfford(
                    spentUSD: spent, capUSD: effectiveCostCap(for: item))
            )
            switch step {
            case .finish(let outcome):
                logChecksSettled(
                    item: item, url: url, outcome: outcome,
                    rounds: rounds, startedAt: startedAt, costUSD: costUSD)
                return (outcome, costUSD)

            case .wait:
                try? await Task.sleep(for: .seconds(PullRequestChecks.pollInterval))

            case .fix(let check):
                rounds += 1
                let result = await handleFailingCheck(
                    check: check, item: item, branch: branch, url: url,
                    rounds: rounds, startedAt: startedAt, costUSD: costUSD)
                costUSD = result.costUSD
                if let outcome = result.outcome { return (outcome, costUSD) }
                // The push gave GitHub a fresh commit to register checks
                // against, so an empty answer to the next poll means those
                // checks haven't been registered yet, not that there are none.
                noChecksOpportunityAt = Date()
            }
        }
    }

    /// The one phase line a settled pull request leaves behind: which terminal
    /// state, after how many rounds, how long and at what cost. An error line
    /// unless the checks went green, so a night's failures grep out.
    private func logChecksSettled(
        item: BacklogItem,
        url: String,
        outcome: PullRequestChecks.Outcome,
        rounds: Int,
        startedAt: Date,
        costUSD: Double
    ) {
        logPhase(.pullRequestChecks, [
            ("item", item.id),
            ("url", url),
            ("outcome", Self.checksOutcomeName(outcome)),
            ("rounds", String(rounds)),
            ("elapsedSec", Self.secondsField(Date().timeIntervalSince(startedAt))),
            ("costUSD", Self.usdField(costUSD)),
            ("detail", PullRequestChecks.note(for: outcome)),
        ], isError: !outcome.isGreen)
    }

    /// One fix round plus its bookkeeping: runs it, logs it, and — if it ends
    /// the loop — the `gaveUp` outcome and its own log line. `outcome` is nil
    /// to keep following; `costUSD` is always the running total, round
    /// included, for the caller to carry into the next iteration.
    private func handleFailingCheck(
        check: PullRequestChecks.Check,
        item: BacklogItem,
        branch: String,
        url: String,
        rounds: Int,
        startedAt: Date,
        costUSD: Double
    ) async -> (outcome: PullRequestChecks.Outcome?, costUSD: Double) {
        appendLog("\(item.id): check \(check.name) is failing — fix round \(rounds) "
                  + "of \(PullRequestChecks.maxFixRounds)")
        let round = await runCheckFixRound(
            item: item, branch: branch, url: url, check: check, round: rounds)
        let costUSD = costUSD + round.costUSD
        logPhase(.pullRequestFix, [
            ("item", item.id),
            ("check", check.name),
            ("round", String(rounds)),
            ("costUSD", Self.usdField(round.costUSD)),
            ("failure", round.failure),
        ], isError: round.failure != nil)
        guard let failure = round.failure else { return (nil, costUSD) }
        let outcome = PullRequestChecks.Outcome.gaveUp(
            check: check.name, rounds: rounds, reason: failure)
        logPhase(.pullRequestChecks, [
            ("item", item.id),
            ("url", url),
            ("outcome", Self.checksOutcomeName(outcome)),
            ("rounds", String(rounds)),
            ("elapsedSec", Self.secondsField(Date().timeIntervalSince(startedAt))),
            ("costUSD", Self.usdField(costUSD)),
            ("detail", PullRequestChecks.note(for: outcome)),
        ], isError: true)
        return (outcome, costUSD)
    }

    /// The one word a phase line calls a terminal state, so a night's runs can
    /// be counted by grepping for it.
    nonisolated static func checksOutcomeName(_ outcome: PullRequestChecks.Outcome) -> String {
        switch outcome {
        case .green: return "green"
        case .gaveUp: return "gave-up"
        case .timedOut: return "timed-out"
        case .unavailable: return "unavailable"
        }
    }

    /// One fix round: re-open the item's branch as a worktree, put the worker in
    /// it with the failing check's log, commit and push what it did. Returns the
    /// reason the round is the end of the road (nil when it isn't) and what it
    /// cost.
    ///
    /// The worktree has to be re-created because teardown already removed it —
    /// the branch is what survived a finished item, and this checks it back out
    /// rather than letting an agent loose in the live project root.
    private func runCheckFixRound(
        item: BacklogItem,
        branch: String,
        url: String,
        check: PullRequestChecks.Check,
        round: Int
    ) async -> (failure: String?, costUSD: Double) {
        guard let orchestrator, let projectRoot, let worker = workerAgentID else {
            return ("there is no worker to hand the failing check to", 0)
        }

        let log = await PullRequestChecks.failureLog(for: check, in: projectRoot)
        let manager = WorktreeManager(projectRoot: projectRoot)
        let worktree: URL
        do {
            worktree = try await manager.reopen(for: item.id, branch: branch)
        } catch {
            return ("\(branch) could not be checked out to fix it "
                    + "(\(error.localizedDescription))", 0)
        }

        /// Puts the worker back on the project root and drops the checkout,
        /// keeping the branch — the pull request is built from it. Every exit
        /// from here on goes through this: a worker left pinned to a directory
        /// this function deletes is a session editing a tree that isn't there.
        func restore(_ failure: String?, _ costUSD: Double) async -> (String?, Double) {
            orchestrator.unpinWorkingDirectory(for: worker)
            orchestrator.stopAgent(worker)
            await manager.removeWorktree(for: item.id, keepBranch: true)
            try? await orchestrator.startAgent(worker, cwd: projectRoot)
            return (failure, costUSD)
        }

        orchestrator.stopAgent(worker)
        // Held there for the round, so nothing else can restart the worker into
        // the project's checkout while it is fixing a branch — the same
        // confinement an item's own run gets from `WorktreeSession`.
        orchestrator.pinWorkingDirectory(worktree, for: worker)
        do {
            try await orchestrator.startAgent(worker, cwd: worktree)
        } catch {
            return await restore("the worker could not be started in \(branch)'s worktree "
                                 + "(\(error.localizedDescription))", 0)
        }

        let backup = await manager.backUpUnmergedTip(for: item.id)
        let before = await PullRequestChecks.headSHA(in: worktree)
        let prompt = PullRequestChecks.fixPrompt(
            item: item, branch: branch, url: url, check: check, log: log, round: round,
            buildOutputNote: Self.buildOutputNote(worktree: worktree)
        )
        var costUSD = 0.0
        do {
            let execID = try await orchestrator.startWorkflow(
                graph: Self.buildCheckFixGraph(workerAgentID: worker,
                                               nodeTimeoutSeconds: max(1, stallTimeoutMinutes) * 60),
                initialState: ["fixPrompt": .string(prompt)]
            )
            // The watchdog inside `awaitWorkflowCompletion` writes why it ended
            // a run to `lastStallReason`, which the *item's* failure path reads.
            // That path is behind us; a fix round stalling must not leave a
            // reason there for the next item to be labelled with.
            let stallReasonBefore = lastStallReason
            _ = await awaitWorkflowCompletion(executionID: execID)
            lastStallReason = stallReasonBefore
            costUSD = await costForItem(executionID: execID)
        } catch {
            return await restore("the fix round could not be started "
                                 + "(\(error.localizedDescription))", costUSD)
        }

        // Whatever the round did is committed even if it ended badly: the
        // checkout is about to be deleted, and uncommitted work in a directory
        // nobody is told about is work lost.
        _ = await manager.commitAll(for: item.id,
                                    message: "autopilot: fix \(check.name) for \(item.id)")
        if let refusal = await roundLandingRefusal(manager: manager, item: item, branch: branch,
                                                   worktree: worktree, before: before, backup: backup) {
            return await restore(refusal, costUSD)
        }

        if let failure = await PullRequestChecks.push(
            branch: branch, from: worktree, projectRoot: projectRoot) {
            return await restore(failure, costUSD)
        }
        appendLog("\(item.id): pushed fix round \(round) to \(branch) — re-reading the checks")
        return await restore(nil, costUSD)
    }

    /// Why a round's result is not pushed: the tip it started from is no longer
    /// on the branch, so the worker reset or rebased rather than added — and a
    /// push would replace the commits the pull request was built from with a
    /// history that has orphaned them. Nil when the branch still carries
    /// `before`, or there was no tip to start from. The refusal names where
    /// `WorktreeManager.backUpUnmergedTip` kept the old tip, so nothing is
    /// lost either way — only not published.
    private func rewrittenHistoryRefusal(
        manager: WorktreeManager, item: BacklogItem, branch: String, before: String?, backup: String?
    ) async -> String? {
        guard let before, await manager.historyRewritten(for: item.id, since: before) else { return nil }
        let kept = backup.map { " (the previous tip is kept at \($0))" } ?? ""
        return "the round rewrote \(branch)'s history — \(before.prefix(7)) is no longer on it, "
             + "so nothing was pushed\(kept)"
    }

    /// Why a round's result is not pushed, or nil when it may be. Two
    /// refusals: the tip did not move at all — nothing changed, so nothing can
    /// have been fixed, and saying so ends the loop here rather than pushing
    /// an identical branch, waiting out another CI run and spending the item's
    /// last round to learn the same thing — or it moved by rewriting history
    /// (`rewrittenHistoryRefusal`).
    private func roundLandingRefusal(
        manager: WorktreeManager, item: BacklogItem, branch: String, worktree: URL,
        before: String?, backup: String?
    ) async -> String? {
        let after = await PullRequestChecks.headSHA(in: worktree)
        guard let after, after != before else { return "the fix round changed nothing on \(branch)" }
        return await rewrittenHistoryRefusal(manager: manager, item: item, branch: branch,
                                             before: before, backup: backup)
    }

    /// The one-node graph a fix round runs: the worker, once, with the failing
    /// check in front of it. No reviewer — the diff on this branch has already
    /// been reviewed, and what this round is judged by is CI itself.
    static func buildCheckFixGraph(workerAgentID: String,
                                   nodeTimeoutSeconds: Int = RunTimeouts.defaultWorkerMinutes * 60) -> WorkflowGraph {
        let workerNode = WorkflowNode(
            id: "worker",
            agentID: workerAgentID,
            prompt: "{{state.fixPrompt}}",
            maxTurns: 30,
            timeoutSeconds: nodeTimeoutSeconds
        )
        return WorkflowGraph(
            id: "backlog-autopilot-pr-fix-\(UUID().uuidString.prefix(8))",
            name: "Pull Request Check Fix",
            version: 1,
            nodes: ["worker": workerNode, "done": WorkflowNode(id: "done", prompt: "")],
            edges: [WorkflowEdge(from: "worker", to: "done", condition: .always, priority: 0)],
            entryNode: "worker",
            terminalNodes: ["done"],
            metadata: .init(description: "Hands one failing pull request check back to the worker"),
            maxIterations: 1
        )
    }

    // MARK: - Rebasing a stale item at the approval gate

    /// Rebases one item sitting at the gate, if and only if it has actually
    /// gone stale — merges the project root's current branch into the item's
    /// branch, resolves conflicts, re-runs the item's `verify:`, and commits.
    /// The item never leaves `awaitingApproval` and the reviewer is never
    /// consulted again: the merge carries no new intent, so `verify:` is the
    /// whole check.
    ///
    /// Callable both automatically — when the project is otherwise idle and a
    /// gate item has gone stale — and by hand, through
    /// `POST /v1/backlog/refresh`, which is why this returns a value rather
    /// than only logging: the control server reports it as the request's
    /// answer, including the 409s.
    enum GateRefreshRequestOutcome: Equatable {
        /// The round ran and the branch reads clean again.
        case refreshed
        /// The item isn't at the gate, has no branch there, wasn't stale, or was
        /// already retired by an earlier call — nothing ran. The caller (409)
        /// doesn't need to tell these apart further; `detail` says which.
        case nothingToRefresh(detail: String)
        /// This round ran, failed, and was the third failure in a row — the
        /// item is now retired. Still 200: a round did run, and this is what it
        /// found.
        case retired
        /// This round ran and failed, with rounds still left; `detail` is what
        /// went wrong.
        case failed(detail: String)
    }

    /// Sweeps every item sitting at the gate for staleness, once a run has
    /// finished its ready-item work and the project is about to go idle — the
    /// automatic half of `refreshGateItem`. A human reaches the same round by
    /// hand through `POST /v1/backlog/refresh`; both go through the one
    /// method, so a fresh item costs nothing more here than the two git reads
    /// `refreshGateItem` starts with.
    private func refreshStaleGateItems() async {
        guard let backlogViewModel else { return }
        let gateItems = (backlogViewModel.backlogFile?.sections ?? [])
            .flatMap(\.items)
            .filter { $0.status == .awaitingApproval }
        for item in gateItems {
            guard !shouldStop else { return }
            await refreshGateItem(itemID: item.id)
        }
    }

    /// What the two git reads and the ledger say about one item before any
    /// round is started — the whole of the "should this run at all" question,
    /// separated from running it so that a new precondition is added here and
    /// nowhere else.
    private enum GateRefreshEligibility {
        /// Nothing runs; `detail` is the 409's reason, in the caller's words.
        case ineligible(detail: String)
        /// A round may run. `detail` is the item's groomed detail file, read
        /// once here so the failure path does not read it again.
        case eligible(item: BacklogItem, detail: BacklogItemDetail?, manager: WorktreeManager)
    }

    /// Decides whether the item named is one a refresh round may touch: it
    /// exists, it is at the gate, it has a branch there, that branch has gone
    /// stale, and the retry ceiling has not already retired it. Cheap on the
    /// common path — a fresh item costs the two git reads and stops.
    private func gateRefreshEligibility(itemID: String) async -> GateRefreshEligibility {
        guard let backlogViewModel, let projectRoot,
              let item = backlogViewModel.item(withID: itemID) else {
            return .ineligible(detail: "no such item")
        }
        guard item.status == .awaitingApproval else {
            return .ineligible(detail: "not awaiting approval (status: \(item.status.rawValue))")
        }
        let manager = WorktreeManager(projectRoot: projectRoot)
        guard await manager.branchExists(for: item.id) else {
            return .ineligible(detail: "the item has no branch to rebase")
        }
        guard await manager.isStale(for: item.id) else {
            return .ineligible(detail: "already fresh")
        }
        let detail = backlogViewModel.loadDetail(for: item)
        guard !retryCeilingVerdict(item: item, detail: detail).isRetired else {
            return .ineligible(detail: "retired by the retry ceiling — three refresh rounds already failed")
        }
        return .eligible(item: item, detail: detail, manager: manager)
    }

    @discardableResult
    func refreshGateItem(itemID: String) async -> GateRefreshRequestOutcome {
        switch await gateRefreshEligibility(itemID: itemID) {
        case .ineligible(let detail):
            return .nothingToRefresh(detail: detail)
        case .eligible(let item, let detail, let manager):
            return await runEligibleGateRefresh(item: item, detail: detail, manager: manager)
        }
    }

    /// Runs the round for an item eligibility has already cleared, and turns
    /// its outcome into the request's answer. Changes when what a round does
    /// changes; the preconditions above it and the ledger below it move
    /// separately.
    private func runEligibleGateRefresh(
        item: BacklogItem, detail: BacklogItemDetail?, manager: WorktreeManager
    ) async -> GateRefreshRequestOutcome {
        let branch = WorktreeSession.branchName(for: item.id)
        appendLog("\(item.id): stale at the gate — starting a refresh round")
        switch await runGateRefreshRound(item: item, branch: branch, manager: manager) {
        case .fresh:
            appendLog("\(item.id): refreshed at the gate")
            return .refreshed
        case .failed(let reason):
            appendLog("\(item.id): refresh round failed — \(reason)")
            return fileFailedGateRefresh(item, detail: detail, reason: reason)
        }
    }

    /// Files one failed round on the retry ledger and asks the ceiling what
    /// that makes of the item — retired on the third failure in a row, still
    /// at the gate with rounds left otherwise.
    private func fileFailedGateRefresh(
        _ item: BacklogItem, detail: BacklogItemDetail?, reason: String
    ) -> GateRefreshRequestOutcome {
        recordGateRefreshFailure(item, detail: detail)
        let verdict = retryCeilingVerdict(item: item, detail: detail)
        guard verdict.isRetired else { return .failed(detail: reason) }
        recordRetirement(item, verdict: verdict)
        return .retired
    }

    /// Files a failed refresh round on the same ledger a pickup refusal is
    /// filed on — `did-not-run:`, zero cost and zero duration, and
    /// `changedFileCount = 0` so `RetryCeiling.evaluate` counts it as a
    /// no-work attempt without reading its outcome string. It is what makes
    /// the third failed round retire the item with the ceiling's own note
    /// (`recordRetirement`, called by the caller once this pushes the streak
    /// past the limit) rather than a second, parallel counter.
    private func recordGateRefreshFailure(_ item: BacklogItem, detail: BacklogItemDetail?) {
        guard let metricStore, let projectPath, let projectName else { return }
        let epic = backlogViewModel?.backlogFile?.sections
            .first { $0.items.contains { $0.id == item.id } }?.name
        let now = Date()
        var record = TaskMetricRecord(
            projectPath: projectPath, projectName: projectName, itemID: item.id, title: item.title,
            epic: epic, declaredSize: item.size?.rawValue, startedAt: now, completedAt: now,
            durationSeconds: 0, costUSD: 0, reviewerRetries: 0,
            outcome: GateRefresh.failedOutcome, workerAgent: workerAgentID, reviewerAgent: nil,
            executionID: nil, toolErrors: nil)
        record.changedFileCount = 0
        record.specFingerprint = RetryCeiling.specFingerprint(item: item, detail: detail)
        metricStore.append(record)
    }

    /// One rebase round: re-open the item's branch as a worktree, put the
    /// worker in it with the merge instruction, commit whatever it left,
    /// re-check freshness and `verify:`. Modeled on `runCheckFixRound` — the
    /// same confinement, the same one-node graph, the same "every exit path
    /// restores the worker" shape — but there is no push: the branch never
    /// leaves this repository, and the gate reads it locally.
    ///
    /// Three steps, each changing for its own reason: the worker is confined to
    /// the checkout (`confineWorker`), it takes its turn, and what it left
    /// behind is judged (`gateRefreshResult`). What is left here is their order
    /// and the single exit — `restore` — every one of them leaves through.
    private func runGateRefreshRound(
        item: BacklogItem, branch: String, manager: WorktreeManager
    ) async -> GateRefresh.Outcome {
        guard let orchestrator, let projectRoot, let worker = workerAgentID else {
            return .failed(note: "there is no worker to hand the rebase to")
        }
        let worktree: URL
        do {
            worktree = try await manager.reopen(for: item.id, branch: branch)
        } catch {
            return .failed(note: "\(branch) could not be checked out to rebase it "
                                 + "(\(error.localizedDescription))")
        }
        // The round hands the branch to a worker. Whatever it does to the
        // history, the tip it was given survives under a backup ref.
        _ = await manager.backUpUnmergedTip(for: item.id)

        // Read rather than assumed — `refreshGateItem` only starts a round on
        // an item already at the gate — so `restore` below puts the item back
        // exactly where it found it, whatever the round did.
        let statusBefore = item.status

        /// Restores the worker, the item's status, and leaves the round's
        /// result as a dated note rather than a status change — and refreshes
        /// the approval gate's freshness cache, which the round's own commit
        /// may have moved. Every exit from here on goes through this, as
        /// `runCheckFixRound`'s `restore` does.
        func restore(_ outcome: GateRefresh.Outcome) async -> GateRefresh.Outcome {
            orchestrator.unpinWorkingDirectory(for: worker)
            orchestrator.stopAgent(worker)
            await manager.removeWorktree(for: item.id, keepBranch: true)
            try? await orchestrator.startAgent(worker, cwd: projectRoot)
            backlogViewModel?.updateItemStatus(itemID: item.id, newStatus: statusBefore)
            recordGateRefreshOutcome(itemID: item.id, branch: branch, outcome: outcome)
            await backlogViewModel?.refreshGateFreshness(projectRoot: projectRoot, base: baseBranch)
            return outcome
        }

        if let refusal = await confineWorker(worker, to: worktree, of: branch,
                                             orchestrator: orchestrator) {
            return await restore(refusal)
        }

        let checkout = await manager.currentBranchName()
        let base = baseBranch ?? checkout
        let verify = (item.verify ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = GateRefresh.prompt(
            base: base.isEmpty ? "the project's default branch" : base, branch: branch, verify: verify)
        do {
            try await runGateRefreshWorkflow(orchestrator: orchestrator, worker: worker, prompt: prompt)
        } catch {
            return await restore(.failed(note: "the refresh round could not be started "
                                               + "(\(error.localizedDescription))"))
        }
        return await restore(await gateRefreshResult(
            item: item, branch: branch, base: base, verify: verify, manager: manager))
    }

    /// Holds the worker in `worktree` for the round: stopped where it is,
    /// pinned to the checkout so nothing else can restart it into the project's
    /// own tree while it is rebasing a branch — the same confinement an item's
    /// own run gets from `WorktreeSession` — and started there. Answers with the
    /// outcome the round fails with when the worker will not start, and `nil`
    /// when it is in place.
    private func confineWorker(
        _ worker: String, to worktree: URL, of branch: String, orchestrator: Orchestrator
    ) async -> GateRefresh.Outcome? {
        orchestrator.stopAgent(worker)
        orchestrator.pinWorkingDirectory(worktree, for: worker)
        do {
            try await orchestrator.startAgent(worker, cwd: worktree)
        } catch {
            return .failed(note: "the worker could not be started in \(branch)'s "
                                 + "worktree (\(error.localizedDescription))")
        }
        return nil
    }

    /// What the worker's turn actually left on the branch, judged once it is
    /// over: the branch has to read fresh against `base`, and the item's
    /// `verify:` has to pass on the merged tree — an item with no `verify:` is
    /// asked only the freshness question. These are the round's acceptance
    /// rules, and they change when the rules do rather than when the worker's
    /// confinement does.
    ///
    /// Whatever the round did is committed first, even when it ended badly: the
    /// checkout is about to be deleted, and uncommitted work in a directory
    /// nobody is told about is work lost.
    private func gateRefreshResult(
        item: BacklogItem, branch: String, base: String, verify: String, manager: WorktreeManager
    ) async -> GateRefresh.Outcome {
        _ = await manager.commitAll(for: item.id, message: "autopilot: rebase \(item.id) at the gate")

        guard !(await manager.isStale(for: item.id)) else {
            return .failed(note: "\(branch) is still behind \(base) after the round")
        }
        guard !verify.isEmpty else { return .fresh }
        guard await manager.runVerify(for: item.id, command: verify) else {
            return .failed(note: "verify failed on the rebased branch")
        }
        return .fresh
    }

    /// Runs the round's one-node workflow to completion, then puts the
    /// autopilot's own bookkeeping back exactly where it was. `awaitWorkflowCompletion`
    /// is the same poller an item's own run uses, and it writes `lastStallReason`
    /// and moves `status` to `.running` / `.reviewing` as the graph's worker
    /// node activates — right for a run, wrong for a refresh round, which must
    /// leave the autopilot exactly as busy, or exactly as idle, as it found
    /// it, and must not leave a stall reason behind for the next item.
    /// `isRunningGateRefresh` additionally keeps the poller from writing this
    /// execution's worker node onto whatever item the outer run loop last
    /// touched.
    private func runGateRefreshWorkflow(
        orchestrator: Orchestrator, worker: String, prompt: String
    ) async throws {
        let execID = try await orchestrator.startWorkflow(
            graph: Self.buildCheckFixGraph(workerAgentID: worker,
                                           nodeTimeoutSeconds: max(1, stallTimeoutMinutes) * 60),
            initialState: ["fixPrompt": .string(prompt)]
        )
        let stallReasonBefore = lastStallReason
        let statusBefore = status
        isRunningGateRefresh = true
        _ = await awaitWorkflowCompletion(executionID: execID)
        isRunningGateRefresh = false
        status = statusBefore
        lastStallReason = stallReasonBefore
    }

    /// The round's result, dated onto the item's `## Notes` — never a status
    /// change, since the merge carries no new intent.
    private func recordGateRefreshOutcome(itemID: String, branch: String, outcome: GateRefresh.Outcome) {
        switch outcome {
        case .fresh:
            backlogViewModel?.appendNote(itemID: itemID, "gate refresh: refreshed \(branch)")
        case .failed(let note):
            backlogViewModel?.appendNote(itemID: itemID, "gate refresh failed: \(note)")
        }
    }

    // MARK: - Addressing the pull request's review comments (ADR-0001)

    /// What the run's own state says about a comment pass before a single
    /// thread is read — the whole of the "may this pass run at all" question,
    /// separated from running it so a new precondition is added here and
    /// nowhere else. Nothing is logged as a phase on this path: no pull request
    /// was read, so there is no reading to file.
    private enum CommentPassEligibility {
        /// No pass runs; `reason` is what the item's outcome is skipped with.
        case refused(reason: String)
        /// A pass may run, in the project root it will be read and applied from.
        case eligible(projectRoot: URL)
    }

    /// Decides whether the pull request's threads may be touched at all: there
    /// is a project to read them from, the run has not been stopped out from
    /// under it, and the item still has cap to spend.
    private func commentPassEligibility(
        item: BacklogItem, executionID: String, alreadySpentUSD: Double
    ) async -> CommentPassEligibility {
        guard let projectRoot else {
            return .refused(reason: "the project has no root to read the pull request from")
        }
        if shouldStop {
            return .refused(reason: "the run was stopped before the comments were read")
        }
        // Asked before the threads are: the cap is the spend backstop, and a
        // pass that would breach it is not worth starting to find out. Read the
        // same way the fix rounds read it, against the same ceiling.
        let spent = await costForItem(executionID: executionID) + alreadySpentUSD
        guard PullRequestChecks.canAfford(spentUSD: spent, capUSD: effectiveCostCap(for: item)) else {
            return .refused(reason: "the item's cost cap is spent")
        }
        return .eligible(projectRoot: projectRoot)
    }

    /// What GitHub had to say when asked for the pull request's review threads.
    private enum CommentThreadReading {
        /// No pass is worth starting, and `outcome` is already the answer —
        /// either GitHub could not be read, or every thread is settled.
        case nothingToAddress(outcome: PullRequestComments.Outcome)
        /// The unresolved threads to put in front of the worker, never empty.
        case toAddress(threads: [PullRequestComments.Thread])
    }

    /// Reads the pull request's threads and narrows them to the ones a pass can
    /// act on. Changes when what counts as actionable changes; the pass below
    /// it does not.
    private func unresolvedThreads(
        on url: String, in projectRoot: URL
    ) async -> CommentThreadReading {
        switch await PullRequestComments.list(pullRequest: url, in: projectRoot) {
        case .unavailable(let reason):
            return .nothingToAddress(outcome: .skipped(reason: reason))
        case .threads(let all):
            let actionable = PullRequestComments.actionableThreads(in: all)
            guard !actionable.isEmpty else { return .nothingToAddress(outcome: .nothingToAddress) }
            return .toAddress(threads: actionable)
        }
    }

    /// The one pass over the pull request's unresolved review threads, run once
    /// its checks are green and before the human is summoned. Returns how it
    /// ended and what it cost, for the caller to charge to the item.
    ///
    /// One pass and no loop, deliberately: the bots are still commenting while
    /// this runs, and a second pass would chase them with the item's remaining
    /// cap. Threads that arrive after it are the human's, which is what the gate
    /// is for.
    ///
    /// Three decisions, each made elsewhere: whether a pass may run at all
    /// (`commentPassEligibility`), what it has to work on (`unresolvedThreads`),
    /// and what the worker's answers come to (`runAndApplyCommentPass`). This
    /// one sequences them and files every reading that reached GitHub.
    private func addressPullRequestComments(
        item: BacklogItem,
        detail: BacklogItemDetail?,
        branch: String,
        url: String,
        executionID: String,
        alreadySpentUSD: Double
    ) async -> (outcome: PullRequestComments.Outcome, costUSD: Double) {
        let projectRoot: URL
        switch await commentPassEligibility(
            item: item, executionID: executionID, alreadySpentUSD: alreadySpentUSD) {
        case .refused(let reason):
            return (.skipped(reason: reason), 0)
        case .eligible(let root):
            projectRoot = root
        }

        let threads: [PullRequestComments.Thread]
        switch await unresolvedThreads(on: url, in: projectRoot) {
        case .nothingToAddress(let outcome):
            logCommentsPhase(item: item, url: url, outcome: outcome, threads: 0, costUSD: 0)
            return (outcome, 0)
        case .toAddress(let found):
            threads = found
        }

        let pass = await runAndApplyCommentPass(
            item: item, detail: detail, branch: branch, url: url,
            threads: threads, in: projectRoot)
        logCommentsPhase(item: item, url: url, outcome: pass.outcome,
                         threads: threads.count, costUSD: pass.costUSD)
        return pass
    }

    /// Puts the worker in front of the threads and acts on what it says: the
    /// pass runs, its dispositions are narrowed to what the branch supports,
    /// and the ones left are replied to and resolved. Reports the outcome and
    /// the cost; filing the phase is the caller's.
    private func runAndApplyCommentPass(
        item: BacklogItem,
        detail: BacklogItemDetail?,
        branch: String,
        url: String,
        threads: [PullRequestComments.Thread],
        in projectRoot: URL
    ) async -> (outcome: PullRequestComments.Outcome, costUSD: Double) {
        appendLog("\(item.id): \(threads.count) unresolved review "
                  + "\(threads.count == 1 ? "thread" : "threads") on \(url) — one pass")
        let pass = await runCommentPass(
            item: item, detail: detail, branch: branch, url: url, threads: threads)
        guard let output = pass.output else {
            return (.skipped(reason: pass.failure ?? "the pass produced no readable dispositions"),
                    pass.costUSD)
        }
        let actionable = honouredDispositions(
            in: output, threads: threads, committed: pass.committed, item: item, branch: branch)
        let acted = await apply(actionable, in: projectRoot, item: item)
        return (PullRequestComments.outcome(threads: threads.count, acted: acted), pass.costUSD)
    }

    /// What the worker said, narrowed to what the tree supports: a `fixed`
    /// claim over a branch that did not move is dropped whole rather than
    /// posted and resolved, and the drop is said out loud so whoever reads the
    /// log knows why those threads are still open at the gate.
    private func honouredDispositions(
        in output: [String: AnyCodable],
        threads: [PullRequestComments.Thread],
        committed: Bool,
        item: BacklogItem,
        branch: String
    ) -> [PullRequestComments.Disposition] {
        let claimed = PullRequestComments.dispositions(in: output, threads: threads)
        if !committed, claimed.contains(where: { $0.action == .fixed }) {
            appendLog("\(item.id): the comment pass claimed fixes but committed nothing on "
                      + "\(branch) — those threads are left open for the gate")
        }
        return PullRequestComments.actionable(claimed, committed: committed)
    }

    /// Posts each disposition's reply, and resolves the threads that were fixed.
    /// Returns the ones GitHub actually accepted — the tally is counted off what
    /// landed, not off what the worker intended, so a resolve the API refused
    /// cannot be reported to the human as a settled thread.
    ///
    /// The reply goes first and the resolve second: a resolve that lands without
    /// its reply leaves a thread closed with no explanation on it, which is worse
    /// than one still open.
    private func apply(
        _ dispositions: [PullRequestComments.Disposition],
        in projectRoot: URL,
        item: BacklogItem
    ) async -> [PullRequestComments.Disposition] {
        var acted: [PullRequestComments.Disposition] = []
        for disposition in dispositions {
            if !disposition.reply.isEmpty,
               let failure = await PullRequestComments.reply(
                threadID: disposition.threadID, body: disposition.reply, in: projectRoot) {
                appendLog("\(item.id): could not reply on a review thread — \(failure)")
                continue
            }
            if disposition.action == .fixed,
               let failure = await PullRequestComments.resolve(
                threadID: disposition.threadID, in: projectRoot) {
                appendLog("\(item.id): could not resolve a review thread — \(failure)")
                continue
            }
            acted.append(disposition)
        }
        return acted
    }

    private func logCommentsPhase(
        item: BacklogItem,
        url: String,
        outcome: PullRequestComments.Outcome,
        threads: Int,
        costUSD: Double
    ) {
        let isError: Bool
        if case .skipped = outcome { isError = true } else { isError = false }
        logPhase(.pullRequestComments, [
            ("item", item.id),
            ("url", url),
            ("outcome", PullRequestComments.outcomeName(outcome)),
            ("threads", String(threads)),
            ("costUSD", Self.usdField(costUSD)),
            ("detail", PullRequestComments.note(for: outcome)),
        ], isError: isError)
    }

    /// The pass itself: re-open the item's branch as a worktree, put the worker
    /// in it with every thread in front of it, commit and push what it did.
    ///
    /// Shaped like `runCheckFixRound` and for the same reasons — the worktree was
    /// torn down when the item finished, and an agent let loose in the live
    /// project root would be editing the tree the next item runs in.
    ///
    /// What this one holds is the confinement: the worker is pinned into the
    /// checkout and put back on the project root by `restore` on every exit. The
    /// turn itself is `runCommentPassWorkflow`, and committing and pushing what
    /// it did is `landCommentPass`.
    private func runCommentPass(
        item: BacklogItem,
        detail: BacklogItemDetail?,
        branch: String,
        url: String,
        threads: [PullRequestComments.Thread]
    ) async -> (output: [String: AnyCodable]?, committed: Bool, failure: String?, costUSD: Double) {
        guard let orchestrator, let projectRoot, let worker = workerAgentID else {
            return (nil, false, "there is no worker to hand the review comments to", 0)
        }
        // The empty-diff handoff belongs to the item's own workflow, which
        // finished long before this; a pass told the item's diff was empty would
        // be answering a question nobody asked here.
        orchestrator.workflowHandoffCheck = nil

        let manager = WorktreeManager(projectRoot: projectRoot)
        let worktree: URL
        do {
            worktree = try await manager.reopen(for: item.id, branch: branch)
        } catch {
            return (nil, false, "\(branch) could not be checked out to address them "
                                + "(\(error.localizedDescription))", 0)
        }

        /// Puts the worker back on the project root and drops the checkout,
        /// keeping the branch — the pull request is built from it. Every exit
        /// from here on goes through this: a worker left pinned to a directory
        /// this function deletes is a session editing a tree that isn't there.
        func restore(
            _ output: [String: AnyCodable]?,
            _ committed: Bool,
            _ failure: String?,
            _ costUSD: Double
        ) async -> ([String: AnyCodable]?, Bool, String?, Double) {
            orchestrator.unpinWorkingDirectory(for: worker)
            orchestrator.stopAgent(worker)
            await manager.removeWorktree(for: item.id, keepBranch: true)
            try? await orchestrator.startAgent(worker, cwd: projectRoot)
            return (output, committed, failure, costUSD)
        }

        orchestrator.stopAgent(worker)
        orchestrator.pinWorkingDirectory(worktree, for: worker)
        do {
            try await orchestrator.startAgent(worker, cwd: worktree)
        } catch {
            return await restore(nil, false, "the worker could not be started in \(branch)'s "
                                             + "worktree (\(error.localizedDescription))", 0)
        }

        let (backup, before) = (await manager.backUpUnmergedTip(for: item.id), await PullRequestChecks.headSHA(in: worktree))
        let pass = await runCommentPassWorkflow(
            orchestrator: orchestrator,
            worker: worker,
            prompt: PullRequestComments.prompt(
                item: item, detail: detail, branch: branch, url: url, threads: threads,
                buildOutputNote: Self.buildOutputNote(worktree: worktree)
            )
        )
        if let failure = pass.failure {
            return await restore(nil, false, failure, pass.costUSD)
        }

        let landing = await landCommentPass(
            manager: manager, item: item, branch: branch,
            worktree: worktree, projectRoot: projectRoot, before: before, backup: backup)
        if let failure = landing.failure {
            return await restore(nil, false, failure, pass.costUSD)
        }
        return await restore(pass.output, landing.committed, nil, pass.costUSD)
    }

    /// The pass's single workflow turn: start it, wait it out, and read back the
    /// state the worker left and what the turn cost.
    ///
    /// A throw on the way in comes back as a `failure` rather than an empty
    /// state, so the caller can tell "the pass never ran" — which leaves every
    /// thread open — from "the pass ran and disposed of nothing".
    private func runCommentPassWorkflow(
        orchestrator: Orchestrator,
        worker: String,
        prompt: String
    ) async -> (output: [String: AnyCodable], failure: String?, costUSD: Double) {
        do {
            let execID = try await orchestrator.startWorkflow(
                graph: Self.buildCommentPassGraph(workerAgentID: worker),
                initialState: ["commentPrompt": .string(prompt)]
            )
            // The watchdog inside `awaitWorkflowCompletion` writes why it ended a
            // run to `lastStallReason`, which the *item's* failure path reads.
            // That path is behind us; this pass stalling must not leave a reason
            // there for the next item to be labelled with.
            let stallReasonBefore = lastStallReason
            _ = await awaitWorkflowCompletion(executionID: execID)
            lastStallReason = stallReasonBefore
            let costUSD = await costForItem(executionID: execID)
            let state = await orchestrator.workflowEngine.execution(id: execID)?.state ?? [:]
            return (state, nil, costUSD)
        } catch {
            return ([:], "the comment pass could not be started "
                         + "(\(error.localizedDescription))", 0)
        }
    }

    /// Lands whatever the pass did on `branch`, and reports whether the branch
    /// actually moved — which is what decides whether a `fixed` disposition is
    /// honoured, read from git rather than from the worker.
    ///
    /// Whatever the pass did is committed even if it ended badly: the checkout is
    /// about to be deleted, and uncommitted work in a directory nobody is told
    /// about is work lost. The push happens before a single thread is answered —
    /// a reply saying "fixed in the latest push" is only true once the push has
    /// happened, and a resolve is permanent in a way a failed push is not.
    private func landCommentPass(
        manager: WorktreeManager,
        item: BacklogItem,
        branch: String,
        worktree: URL,
        projectRoot: URL,
        before: String?,
        backup: String?
    ) async -> (committed: Bool, failure: String?) {
        _ = await manager.commitAll(for: item.id,
                                    message: "autopilot: address review comments for \(item.id)")
        let after = await PullRequestChecks.headSHA(in: worktree)
        guard let after, after != before else { return (false, nil) }
        if let refusal = await rewrittenHistoryRefusal(manager: manager, item: item, branch: branch,
                                                       before: before, backup: backup) {
            return (false, refusal)
        }
        if let failure = await PullRequestChecks.push(
            branch: branch, from: worktree, projectRoot: projectRoot) {
            return (false, failure)
        }
        appendLog("\(item.id): pushed the comment pass's fixes to \(branch)")
        return (true, nil)
    }

    /// The one-node graph the comment pass runs: the worker, once, with every
    /// unresolved thread in front of it. No reviewer — the diff on this branch
    /// has already been reviewed, and what this pass answers to is the people who
    /// left the comments.
    static func buildCommentPassGraph(workerAgentID: String) -> WorkflowGraph {
        let workerNode = WorkflowNode(
            id: "worker",
            agentID: workerAgentID,
            prompt: "{{state.commentPrompt}}",
            maxTurns: 40,
            timeoutSeconds: 1_200,
            outputSchema: PullRequestComments.outputSchema
        )
        return WorkflowGraph(
            id: "backlog-autopilot-pr-comments-\(UUID().uuidString.prefix(8))",
            name: "Pull Request Comment Pass",
            version: 1,
            nodes: ["worker": workerNode, "done": WorkflowNode(id: "done", prompt: "")],
            edges: [WorkflowEdge(from: "worker", to: "done", condition: .always, priority: 0)],
            entryNode: "worker",
            terminalNodes: ["done"],
            metadata: .init(
                description: "Hands the pull request's unresolved review threads to the worker, once"),
            maxIterations: 1
        )
    }

    /// The build-output note an agent working in `worktree` is given — the same
    /// one an item's own run gets, so a fix round can't be the thing that
    /// registers a second copy of the app.
    private nonisolated static func buildOutputNote(worktree: URL) -> String {
        let path = WorktreeBuildOutput.derivedDataDirectory(for: worktree).path(percentEncoded: false)
        return """
            This round happens in a throwaway git worktree. Build into it: pass \
            `-derivedDataPath \(path)` to every `xcodebuild` you run. Without it \
            Xcode derives a new DerivedData tree from this worktree's path and \
            registers a second copy of the app that outlives the worktree.
            """
    }

    /// The base branch a project's autopilot config names, read off the file
    /// without an autopilot — for the worktree sweep at project open, which
    /// runs before any is built and judged every branch against `HEAD` until
    /// 2026-09-20. Nil when the file, or the key, is not there.
    nonisolated static func configuredBaseBranch(projectRoot: URL) -> String? {
        let url = projectRoot.appending(path: ".kiteloop/autopilot-config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = json["baseBranch"] as? String, !base.isEmpty else { return nil }
        return base
    }

    // MARK: - Auto-merge (ADR-0001)

    /// After a landed merge the item's branch is entirely inside the base and
    /// the ref is all that is left of it. Removed, and the log says so either
    /// way — a kept branch names git's reason.
    private func tidyMergedBranch(itemID: String) async {
        guard let projectRoot else { return }
        let manager = WorktreeManager(projectRoot: projectRoot)
        let branch = WorktreeSession.branchName(for: itemID)
        if let kept = await manager.removeMergedBranch(for: itemID, base: baseBranch) {
            appendLog("Kept branch \(branch) after the merge: \(kept)")
        } else {
            appendLog("Removed branch \(branch) — its commits are in \(baseBranch ?? "the checkout's branch")")
        }
    }

    /// Merges the item's branch into the project's main branch, gated on a clean
    /// merge and a green verify of the merged tree. The branch was already committed
    /// and its worktree removed by `WorktreeSession.end`, so the merge runs in the
    /// live project root. Returns whether the merge landed (and why not, if it didn't).
    private func attemptAutoMerge(
        for item: BacklogItem,
        session: WorktreeSession?
    ) async -> (merged: Bool, reason: String, verify: MergeVerifyPlan, verifyOutput: String?, commit: String?) {
        let plan = await mergeVerifyPlan(for: item)
        guard let session else { return (false, "no worktree", plan, nil, nil) }
        if let drift = plan.flagDriftWarning { appendLog("\(item.id): \(drift)") }
        backlogViewModel?.beginGateVerify(itemID: item.id)
        defer { backlogViewModel?.endGateVerify(itemID: item.id) }
        let branch = session.branch
        let result = await session.merge(
            message: "autopilot: merge \(item.id)",
            verify: plan,
            timeout: verifyTimeout,
            setupCommand: effectiveWorktreeSetup.command,
            onGateWait: { [weak self] wait in await self?.noteMergeGateWait(wait, itemID: item.id, branch: branch) }
        )
        return (result.merged, result.reason, plan,
               WorktreeManager.verifyStepOutputsNote(result.stepOutputs), result.mergeCommit)
    }

}

// MARK: - The merge gate's queue (a merge waiting behind another on this project)
//
// An extension for the same reason the gate-retry section below is one: the
// complexity tool's Swift reader measures `buildCommentPassGraph`'s declared
// length off where this file's `class BacklogAutopilot { … }` block ends, so a
// method added inside the class near its end inflates that unrelated function's
// measurement by exactly this section's line count and fails the ratchet. An
// extension leaves the class's own span where it was, and Swift's `private`
// reaches every extension of a type in the same file, so `logPhase` is as
// available here as it was there.
extension BacklogAutopilot {
    /// The one place a queued merge gate is said out loud. While the wait
    /// lasts the rail reads `waitingForGate` rather than `merge`, and an
    /// `autopilot-merge-waiting` event goes on the bus, so a second merge on
    /// the same project can be told from one already verifying instead of both
    /// reading as a gate that is simply taking a long time; the moment the
    /// gate is held, the ordinary `merge` line puts the rail back where it
    /// was. Only `WorktreeManager.mergeAndVerify` can say either — it is the
    /// only thing that knows the gate was contended.
    /// Everything that must pass on the merged tree before a merge is kept: the
    /// item's own `verify:` **and** every verify-map rule the branch's diff
    /// reaches, not one or the other — see `MergeVerifyPlan` for the merge this
    /// rule exists because of. A merge-verify command an earlier release
    /// stored runs as a rule matching every path while the map has none, and
    /// the log names the rule to add; a project with no map runs the derived
    /// command as that rule, exactly as before.
    private func mergeVerifyPlan(for item: BacklogItem) async -> MergeVerifyPlan {
        guard let projectRoot else {
            return MergeVerifyPlan.resolve(projectCommand: effectiveMergeVerify.command, itemVerify: item.verify)
        }
        let map = VerifyMapFile.load(for: KiteloopProject(rootURL: projectRoot))
        let stored = storedMergeVerify(beside: map)
        if let stored { appendLog(Self.storedMergeVerifyNotice(stored)) }
        let rules = map.isEmpty ? effectiveMergeVerify.command.map { [MergeVerifyPlan.catchAll($0)] } ?? []
                                : (stored.map { [MergeVerifyPlan.catchAll($0)] } ?? []) + map.rules
        let paths = await RunWorkEvidence.changedFiles(
            projectRoot: projectRoot, branch: WorktreeSession.branchName(for: item.id))
        return MergeVerifyPlan.resolve(rules: rules, paths: paths, itemVerify: item.verify)
    }

    /// The command an earlier release stored as `autoMergeVerifyCommand`,
    /// while `map` has no rule matching every path — nil once it has one,
    /// which runs instead.
    func storedMergeVerify(beside map: VerifyCoverage.Map?) -> String? {
        guard let stored = autoMergeVerifyCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else { return nil }
        let covered = map?.rules.contains(where: Self.matchesEveryPath) ?? false
        return covered ? nil : stored
    }

    /// Whether `rule` reaches every path: a file at the root and one nested
    /// under a directory and extension this repo does not have. Stricter than
    /// `VerifyCoverage.isUnconditional`, which also counts `**/*.swift`.
    nonisolated static func matchesEveryPath(_ rule: VerifyCoverage.Rule) -> Bool {
        ["zz-probe-7d1e", "zz-probe-7d1e/nested/zz-probe-7d1e.zz"]
            .allSatisfy { VerifyCoverage.matches(glob: rule.glob, path: $0) }
    }

    /// The log line for a stored command still run this release: what it is,
    /// and the verify-map rule that replaces it.
    nonisolated static func storedMergeVerifyNotice(_ command: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(MergeVerifyPlan.catchAll(command))).flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"glob": "**", "command": …}"#
        return "The stored merge-verify command `\(command)` is no longer a setting and runs this release only — "
            + "add the rule \(json) to kiteloop-verify.json so the verify map runs it"
    }

    private func recordMergeOutcome(itemID: String, merged: Bool, reason: String?,
                                    executionID: String?, verifyOutput: String? = nil,
                                    commit: String? = nil) {
        guard let metricStore, let projectPath, let projectName else { return }
        metricStore.appendMergeEvent(ItemMergeEvent(
            projectPath: projectPath,
            projectName: projectName,
            itemID: itemID,
            merged: merged,
            at: Date(),
            executionID: executionID,
            reason: reason,
            verifyOutput: verifyOutput,
            commit: commit
        ))
    }

    func noteMergeGateWait(_ wait: WorktreeManager.MergeGateWait, itemID: String, branch: String?) {
        switch wait {
        case .waiting:
            logPhase(.mergeWaiting, [("item", itemID), ("branch", branch), ("phase", "waiting")])
            orchestrator?.publishEvent(KiteloopEvent(source: "Autopilot", type: .custom, payload: [
                "kind": "autopilot-merge-waiting",
                "item": itemID,
                "branch": branch ?? "",
            ]))
        case .acquired:
            logPhase(.merge, [("item", itemID), ("branch", branch), ("phase", "verifying")])
        }
    }
}

// MARK: - Gate retry (main moving re-attempts a parked merge)
//
// A separate extension, deliberately: `buildCommentPassGraph` just above measures
// its declared length off where this file's `class BacklogAutopilot { … }` block
// ends, not off its own closing brace — a pre-existing quirk in the complexity
// tool's Swift reader, not a fact about that function. Adding this section's
// methods *inside* the class (including `refreshGateFreshnessIfPossible`, moved
// here whole so its one new line of body doesn't count either) would inflate that
// unrelated function's measurement by exactly this section's line count and fail
// the complexity ratchet for a function nothing here touches; a same-file
// extension leaves the class's own span exactly where it was, with full access to
// its `private` members either way — Swift's `private` reaches every extension of
// a type in the same file.
extension BacklogAutopilot {
    /// Refreshes every item now sitting at the gate's merge-freshness — called
    /// both when an item just reached `awaiting-approval` and after a merge
    /// that just moved the base, since either one is exactly what can turn a
    /// sibling's clean branch stale. Nil `projectRoot` (no worktree isolation)
    /// has no base to check against. A helper of its own so the call adds no
    /// branch to the run loop it is called from.
    private func refreshGateFreshnessIfPossible(backlog: BacklogViewModel) async {
        guard let projectRoot else { return }
        await backlog.refreshGateFreshness(projectRoot: projectRoot, base: baseBranch)
        await retryGateMerges(backlog: backlog, projectRoot: projectRoot)
    }

    /// Retries parked gate merges: for every item at `awaiting-approval`
    /// whose last recorded merge attempt failed on a conflict or a base race
    /// — not on its own verify, which the merge landing again cannot fix —
    /// attempts the merge again, oldest first and one at a time, through the
    /// same `resolveGate` a human's Approve click uses. A landing marks the
    /// item Done in that same call and refreshes freshness for whatever
    /// comes after it in this loop, so nothing here has to.
    ///
    /// Only runs when the project's gate is set to clear itself unattended —
    /// `autoMergeOnApproval` and `approveReviewPassedRuns` both on. Either
    /// one off and this loop must not act on a human's behalf, the same
    /// coupling `shouldAutoMerge` already enforces for a run's own first
    /// attempt.
    ///
    /// Serial by construction: this `for` loop `await`s each `resolveGate`
    /// before the next iteration starts, so two merges never run at once
    /// against this project root.
    private func retryGateMerges(backlog: BacklogViewModel, projectRoot: URL) async {
        guard autoMergeOnApproval, approveReviewPassedRuns else { return }
        let gateItems = (backlog.backlogFile?.sections.flatMap(\.items) ?? [])
            .filter { $0.status == .awaitingApproval }
        guard !gateItems.isEmpty else { return }

        let key = KiteloopProject.canonicalPath(projectPath ?? projectRoot.path(percentEncoded: false))
        let ledgerURL = gateRetryLedgerURL
        var ledger = GateRetry.Ledger.load(from: ledgerURL)
        let rescueLedgerURL = rescueLedgerURL
        var rescueLedger = RescueRun.Ledger.load(from: rescueLedgerURL)
        let manager = WorktreeManager(projectRoot: projectRoot)

        for item in gateItems {
            guard !ledger.isExcluded(project: key, itemID: item.id) else { continue }
            guard await manager.branchExists(for: item.id) else { continue }
            let signals = GateRetry.Signals(
                itemID: item.id,
                lastAttempt: lastMergeAttempt(for: item.id),
                attemptsByThisLoop: ledger.attempts(project: key, itemID: item.id))
            await applyGateRetryVerdict(GateRetry.classify(signals), for: item, backlog: backlog,
                                        projectRoot: projectRoot, key: key,
                                        ledger: &ledger, ledgerURL: ledgerURL,
                                        rescueLedger: &rescueLedger, rescueLedgerURL: rescueLedgerURL)
        }
    }

    /// The most recent recorded merge attempt for an item, read from the same
    /// `TaskMetricStore` every merge path already writes to — the run's own
    /// auto-merge, a human's `resolveGate`, and this loop's own retries. Nil
    /// without a metric store attached (tests, embedded use): the loop then
    /// has no record to retry from and does nothing, the same "it just isn't
    /// measured" fallback the rest of this file takes.
    private func lastMergeAttempt(for itemID: String) -> GateRetry.Attempt? {
        guard let metricStore else { return nil }
        let canonical = projectPath.map(KiteloopProject.canonicalPath)
        return metricStore.mergeEvents.last {
            $0.itemID == itemID && KiteloopProject.canonicalPath($0.projectPath) == canonical
        }.map { GateRetry.Attempt(merged: $0.merged, reason: $0.reason) }
    }

    /// Carries out one item's verdict: a retry attempts the merge and records
    /// what happened either way; an exclusion hands the item to the rescue
    /// extension (`handleGateExclusion`), which decides whether one capped
    /// agent run is worth spending on it before the item is left for a human.
    /// A skip does nothing at all — see `GateRetry.Disposition.skip`.
    private func applyGateRetryVerdict(
        _ verdict: GateRetry.Verdict, for item: BacklogItem, backlog: BacklogViewModel,
        projectRoot: URL, key: String, ledger: inout GateRetry.Ledger, ledgerURL: URL,
        rescueLedger: inout RescueRun.Ledger, rescueLedgerURL: URL
    ) async {
        switch verdict.disposition {
        case .skip:
            return
        case .exclude(let reason):
            recordGateRetryOutcome(itemID: item.id, key: key,
                                   disposition: GateRetry.Ledger.Entry.excludedDisposition,
                                   reason: reason, ledger: &ledger, ledgerURL: ledgerURL)
            await handleGateExclusion(item: item, reason: reason, backlog: backlog, projectRoot: projectRoot,
                                      key: key, rescueLedger: &rescueLedger, rescueLedgerURL: rescueLedgerURL)
        case .retry:
            let outcome = await backlog.resolveGate(
                itemID: item.id, approve: true,
                autoMerge: autoMergeOnApproval,
                verify: await mergeVerifyPlan(for: item),
                projectRoot: projectRoot,
                isolationExpected: useWorktree,
                base: baseBranch,
                setupCommand: effectiveWorktreeSetup.command,
                timeout: verifyTimeout,
                closure: .autoApproved)
            let (merged, reason) = Self.gateRetryLedgerFacts(for: outcome)
            recordGateRetryOutcome(itemID: item.id, key: key,
                                   disposition: GateRetry.Ledger.Entry.retryDisposition,
                                   reason: reason, ledger: &ledger, ledgerURL: ledgerURL)
            appendLog(merged
                ? "Gate retry: \(item.id) merged and approved automatically (\(reason))"
                : "Gate retry: \(item.id) still not merged — \(reason)")
        }
    }

    /// One write, kept in memory and on disk together — the same pairing
    /// `CoordinatorBlockedTriage.record` makes for `BlockedTriage.Ledger`.
    private func recordGateRetryOutcome(
        itemID: String, key: String, disposition: String, reason: String,
        ledger: inout GateRetry.Ledger, ledgerURL: URL, at: Date = Date()
    ) {
        ledger.record(project: key, itemID: itemID, disposition: disposition, reason: reason, at: at)
        GateRetry.Ledger.append(
            GateRetry.Ledger.Entry(at: at, project: key, itemID: itemID,
                                   disposition: disposition, reason: reason),
            to: ledgerURL)
    }

    /// Reads a `resolveGate` outcome into what the ledger records. Both
    /// landings (`.approvedAndMerged`, the "nothing to merge" half of
    /// `.approvedWithoutMerge`) are not failures; the three refusal cases
    /// each name why in their own payload. `.rejected` is never reached here
    /// — this loop always calls `resolveGate` with `approve: true`.
    private nonisolated static func gateRetryLedgerFacts(
        for outcome: BacklogViewModel.GateOutcome
    ) -> (merged: Bool, reason: String) {
        switch outcome {
        case .approvedAndMerged: return (true, "merged")
        case .approvedWithoutMerge(let reason): return (true, reason)
        case .mergeFailed(let reason, _): return (false, reason)
        case .workNotOnBranch(let reason): return (false, reason)
        case .rejected: return (false, "rejected")
        }
    }
}

// MARK: - Rescue run (a conflicted merge summons a rescue run, not a human)
//
// A separate extension for the same reason the gate-retry one above is: see its
// own comment. This is the escalation `GateRetry`'s own exclusion has none of
// today — a content conflict past the rebase, or a merged tree whose own
// verify stays red, currently just writes a `## Notes` line and waits for a
// human. This spends one capped, measured agent run on it first, in a fresh
// worktree cut from the item's own branch, before it is left for one.
extension BacklogAutopilot {
    /// What an excluded item's rescue is worth, and — when it is — carries it
    /// out. Called once per exclusion, from `applyGateRetryVerdict`.
    ///
    /// A skip still writes the exclusion's own note: `RescueRun.classify`'s
    /// reason is appended alongside it rather than replacing it, so an item
    /// nobody may rescue reads exactly as it did before this existed.
    private func handleGateExclusion(
        item: BacklogItem, reason: String, backlog: BacklogViewModel, projectRoot: URL, key: String,
        rescueLedger: inout RescueRun.Ledger, rescueLedgerURL: URL
    ) async {
        let signals = RescueRun.Signals(
            itemID: item.id,
            autonomousWorkEnabled: autonomousWorkEnabled,
            alreadyRescued: rescueLedger.hasRescued(project: key, itemID: item.id))
        switch RescueRun.classify(signals) {
        case .skip(let skipReason):
            backlog.appendNote(itemID: item.id, "\(reason) — \(skipReason)")
            appendLog("Gate retry: \(item.id) — \(reason)")
        case .spawn:
            appendLog("Gate retry: \(item.id) — \(reason); spawning a rescue run")
            await spawnRescueRun(item: item, exclusionReason: reason, backlog: backlog,
                                 projectRoot: projectRoot, key: key,
                                 rescueLedger: &rescueLedger, rescueLedgerURL: rescueLedgerURL)
        }
    }

    /// One rescue, start to finish, as three decisions that each change for
    /// their own reason: whether it may start at all
    /// (`rescueAgentsAreFree`), the worktree it runs in
    /// (`runRescueInFreshWorktree`), and what the run it came back with means
    /// for the item (`landRescueOutcome`). A worktree that could never be cut
    /// is the one failure this level still reads, since nothing ran and the
    /// item has only that to be told.
    private func spawnRescueRun(
        item: BacklogItem, exclusionReason: String, backlog: BacklogViewModel, projectRoot: URL, key: String,
        rescueLedger: inout RescueRun.Ledger, rescueLedgerURL: URL
    ) async {
        guard let orchestrator, let worker = workerAgentID, let reviewer = reviewerAgentID else { return }
        guard rescueAgentsAreFree(item: item, worker: worker, reviewer: reviewer, orchestrator: orchestrator)
        else { return }

        let outcome: RescueOutcome
        do {
            outcome = try await runRescueInFreshWorktree(
                item: item, exclusionReason: exclusionReason, worker: worker, reviewer: reviewer,
                orchestrator: orchestrator, projectRoot: projectRoot)
        } catch {
            finishFailedRescue(item: item, reason: "could not prepare a rescue worktree: \(error.localizedDescription)",
                               exclusionReason: exclusionReason, backlog: backlog, key: key,
                               rescueLedger: &rescueLedger, rescueLedgerURL: rescueLedgerURL)
            return
        }

        await landRescueOutcome(item: item, outcome: outcome, exclusionReason: exclusionReason,
                                backlog: backlog, projectRoot: projectRoot, key: key,
                                rescueLedger: &rescueLedger, rescueLedgerURL: rescueLedgerURL)
    }

    /// Whether both agents a rescue needs are free. One already holding
    /// another run's worktree is left alone rather than pulled out from under
    /// it — the same guard `WorktreeSession.begin` applies for an ordinary
    /// item. The rescue is not spent by this: the next sweep tries again.
    private func rescueAgentsAreFree(
        item: BacklogItem, worker: String, reviewer: String, orchestrator: Orchestrator
    ) -> Bool {
        guard orchestrator.pinnedWorkingDirectory(for: worker) == nil,
              orchestrator.pinnedWorkingDirectory(for: reviewer) == nil else {
            appendLog("Rescue: \(item.id) — the worker or reviewer is already busy with another run; "
                     + "not spent, tried again next sweep")
            return false
        }
        return true
    }

    /// The rescue worktree's whole life: cut from the item's own branch
    /// merged against the current base, run over, committed, then removed
    /// with the branch kept — whatever the rescue resolved is what the gate
    /// merges next. Throwing means the worktree was never cut, so no agent
    /// ran and nothing was spent.
    private func runRescueInFreshWorktree(
        item: BacklogItem, exclusionReason: String, worker: String, reviewer: String,
        orchestrator: Orchestrator, projectRoot: URL
    ) async throws -> RescueOutcome {
        let manager = WorktreeManager(projectRoot: projectRoot)
        let rescueKey = "\(item.id)-rescue"
        let rescueWorktree = try await manager.prepareRescueWorktree(
            key: rescueKey, branch: WorktreeSession.branchName(for: item.id), base: baseBranch)

        let outcome = await runRescueWorkflow(item: item, exclusionReason: exclusionReason,
                                              worktree: rescueWorktree, worker: worker, reviewer: reviewer,
                                              orchestrator: orchestrator, projectRoot: projectRoot)
        _ = await manager.commitAll(for: rescueKey, message: "autopilot rescue: \(item.id)")
        await manager.removeWorktree(for: rescueKey, keepBranch: true)
        return outcome
    }

    /// What a finished rescue means for the item: one that never reached a
    /// passing review parks it for a human, and one that did takes the same
    /// gate an ordinary approval takes — a merge that still fails there parks
    /// it too, with the whole trail on the note. Either way the rescue's own
    /// spend is measured and its verdict written to the ledger, which is what
    /// keeps an item from ever being rescued twice.
    private func landRescueOutcome(
        item: BacklogItem, outcome: RescueOutcome, exclusionReason: String, backlog: BacklogViewModel,
        projectRoot: URL, key: String, rescueLedger: inout RescueRun.Ledger, rescueLedgerURL: URL
    ) async {
        guard outcome.passed else {
            finishFailedRescue(item: item, reason: outcome.reason, exclusionReason: exclusionReason,
                               backlog: backlog, key: key, rescueLedger: &rescueLedger, rescueLedgerURL: rescueLedgerURL)
            recordRescueMetric(item: item, outcome: RescueRun.rescueFailedOutcome,
                               costUSD: outcome.costUSD, duration: outcome.duration)
            return
        }

        let gateOutcome = await backlog.resolveGate(
            itemID: item.id, approve: true, autoMerge: autoMergeOnApproval,
            verify: await mergeVerifyPlan(for: item), projectRoot: projectRoot,
            isolationExpected: useWorktree, base: baseBranch,
            setupCommand: effectiveWorktreeSetup.command,
            timeout: verifyTimeout,
            closure: .autoApproved)
        let (merged, mergeReason) = Self.gateRetryLedgerFacts(for: gateOutcome)
        recordRescueMetric(item: item, outcome: merged ? RescueRun.rescuedOutcome : RescueRun.rescueFailedOutcome,
                           costUSD: outcome.costUSD, duration: outcome.duration)
        recordRescueLedgerEntry(itemID: item.id, key: key, outcome: merged ? "rescued" : "failed",
                                reason: mergeReason, rescueLedger: &rescueLedger, rescueLedgerURL: rescueLedgerURL)
        guard merged else {
            backlog.appendNote(itemID: item.id,
                "\(exclusionReason). A rescue run resolved the review but the merge still failed: "
                + "\(mergeReason) — parked for a human; nothing further will be retried automatically.")
            appendLog("Rescue: \(item.id) — review passed but the merge still failed: \(mergeReason)")
            return
        }
        appendLog("Rescue: \(item.id) resolved and merged (\(mergeReason))")
    }

    /// One rescue's own agent run: pins the worker and reviewer into its
    /// worktree, runs the same worker/reviewer graph an ordinary item gets,
    /// and restores both agents to the project root whatever the outcome —
    /// the same pairing `WorktreeSession.begin`/`end` keep for an ordinary
    /// item's pin.
    private func runRescueWorkflow(
        item: BacklogItem, exclusionReason: String, worktree: WorktreeManager.RescueWorktree,
        worker: String, reviewer: String, orchestrator: Orchestrator, projectRoot: URL
    ) async -> RescueOutcome {
        for agentID in [worker, reviewer] {
            orchestrator.stopAgent(agentID)
            orchestrator.pinWorkingDirectory(worktree.path, for: agentID)
            try? await orchestrator.startAgent(agentID, cwd: worktree.path)
        }

        let outcome = await executeRescueGraph(item: item, exclusionReason: exclusionReason,
                                                worktree: worktree, worker: worker, reviewer: reviewer,
                                                orchestrator: orchestrator)

        for agentID in [worker, reviewer] {
            orchestrator.unpinWorkingDirectory(for: agentID)
            orchestrator.stopAgent(agentID)
            try? await orchestrator.startAgent(agentID, cwd: projectRoot)
        }
        return outcome
    }

    /// What one rescue's agent run ended as.
    private struct RescueOutcome {
        let passed: Bool
        let reason: String
        let costUSD: Double
        let duration: Double
    }

    /// Builds the rescue's own initial state and workflow graph — the same
    /// `buildWorkflowGraph` an ordinary item runs, so a rescue cannot reach
    /// any node, retry budget or reviewer rubric an ordinary run doesn't
    /// already have — and interprets how it ended.
    private func executeRescueGraph(
        item: BacklogItem, exclusionReason: String, worktree: WorktreeManager.RescueWorktree,
        worker: String, reviewer: String, orchestrator: Orchestrator
    ) async -> RescueOutcome {
        let detail = backlogViewModel?.loadDetail(for: item)
        let initialState = Self.buildRescueInitialState(
            item: item, detail: detail, worktree: worktree.path,
            exclusionReason: exclusionReason, conflictedPaths: worktree.conflictedPaths)
        let graph = Self.buildWorkflowGraph(workerAgentID: worker, reviewerAgentID: reviewer,
                                            maxIterations: maxRetries,
                                            nodeTimeoutSeconds: max(1, stallTimeoutMinutes) * 60,
                                            workerMaxTurns: workerMaxTurns)

        let startedAt = Date()
        guard let execID = try? await orchestrator.startWorkflow(graph: graph, initialState: initialState) else {
            return RescueOutcome(passed: false, reason: "could not start the rescue workflow", costUSD: 0, duration: 0)
        }
        let status = await awaitRescueCompletion(executionID: execID, orchestrator: orchestrator)
        let duration = Date().timeIntervalSince(startedAt)
        let finalExecution = await orchestrator.workflowEngine.execution(id: execID)
        let costUSD = await costForItem(executionID: execID)

        guard status == .completed, finalExecution?.currentNode != "blocked" else {
            let reason = Self.breakerReason(state: finalExecution?.state)
                ?? Self.blockedReviewReason(state: finalExecution?.state ?? [:])
            return RescueOutcome(passed: false, reason: reason, costUSD: costUSD, duration: duration)
        }
        return RescueOutcome(passed: true, reason: "review passed", costUSD: costUSD, duration: duration)
    }

    /// Polls a rescue's own execution to a terminal state. Lighter than
    /// `awaitWorkflowCompletion`, which is keyed to `runQueue`/`currentIndex`
    /// — state a rescue, spawned from the gate sweep rather than the run
    /// loop, does not have a slot in. The graph's own `maxIterations` and
    /// per-node `timeoutSeconds` are what bound it, exactly as they bound an
    /// ordinary item.
    private func awaitRescueCompletion(executionID: String, orchestrator: Orchestrator) async -> ExecutionStatus {
        while true {
            guard let execution = await orchestrator.workflowEngine.execution(id: executionID) else { return .failed }
            if execution.status.isTerminal { return execution.status }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// A rescue that never reached a passing review, or one that did but
    /// still failed to land: recorded as `RescueRun.rescueFailedOutcome` and
    /// left for a human with a note that carries the whole trail — the
    /// exclusion, and now what the rescue itself found.
    private func finishFailedRescue(
        item: BacklogItem, reason: String, exclusionReason: String, backlog: BacklogViewModel, key: String,
        rescueLedger: inout RescueRun.Ledger, rescueLedgerURL: URL
    ) {
        backlog.appendNote(itemID: item.id,
            "\(exclusionReason). A rescue run was attempted and did not resolve it: \(reason) — "
            + "parked for a human; nothing further will be retried automatically.")
        appendLog("Rescue: \(item.id) — \(reason)")
        recordRescueLedgerEntry(itemID: item.id, key: key, outcome: "failed", reason: reason,
                                rescueLedger: &rescueLedger, rescueLedgerURL: rescueLedgerURL)
    }

    /// One write, kept in memory and on disk together — the same pairing
    /// `recordGateRetryOutcome` makes for `GateRetry.Ledger`.
    private func recordRescueLedgerEntry(
        itemID: String, key: String, outcome: String, reason: String,
        rescueLedger: inout RescueRun.Ledger, rescueLedgerURL: URL, at: Date = Date()
    ) {
        rescueLedger.record(project: key, itemID: itemID, outcome: outcome, reason: reason, at: at)
        RescueRun.Ledger.append(
            RescueRun.Ledger.Entry(at: at, project: key, itemID: itemID, outcome: outcome, reason: reason),
            to: rescueLedgerURL)
    }

    /// Files the rescue's own measured run — its own row, distinct from the
    /// run whose gate it rescued, since it is its own spend and its own
    /// verdict. `reviewerRetries: 0` because a rescue's own worker/reviewer
    /// loop is not what `FirstPassRate` means by a rework loop on the item's
    /// *original* attempt.
    private func recordRescueMetric(item: BacklogItem, outcome: String, costUSD: Double, duration: Double) {
        guard let metricStore, let projectPath, let projectName else { return }
        let epic = backlogViewModel?.backlogFile?.sections
            .first { $0.items.contains { $0.id == item.id } }?.name
        let completedAt = Date()
        metricStore.append(TaskMetricRecord(
            projectPath: projectPath,
            projectName: projectName,
            itemID: item.id,
            title: item.title,
            epic: epic,
            declaredSize: item.size?.rawValue,
            startedAt: completedAt.addingTimeInterval(-duration),
            completedAt: completedAt,
            durationSeconds: duration,
            costUSD: costUSD,
            reviewerRetries: 0,
            outcome: outcome,
            workerAgent: workerAgentID.flatMap { id in orchestrator?.agents.first { $0.id == id }?.name },
            reviewerAgent: reviewerAgentID.flatMap { id in orchestrator?.agents.first { $0.id == id }?.name },
            executionID: nil,
            toolErrors: nil
        ))
    }

    /// The rescue's own initial state: the ordinary item state
    /// (`buildInitialState`), with `what` and `acceptanceCriteria` replaced by
    /// what the rescue is actually being asked to do — the exclusion's own
    /// reason, the paths a conflict named (or, for a red verify, that there
    /// were none to name), and the scope a rescue may not exceed. Both the
    /// worker and the reviewer read `what` (see `reviewerNodePrompt`'s "What
    /// was requested" section), so the same sentence that tells the worker
    /// what to touch is what the reviewer checks the diff against.
    nonisolated static func buildRescueInitialState(
        item: BacklogItem, detail: BacklogItemDetail?, worktree: URL,
        exclusionReason: String, conflictedPaths: [String]
    ) -> [String: AnyCodable] {
        var state = Self.buildInitialState(item: item, detail: detail, worktree: worktree)
        state["title"] = .string("Rescue: \(item.title)")

        let scopeSurface = conflictedPaths.isEmpty
            ? "the failing verify command(s) below name"
            : conflictedPaths.map { "- \($0)" }.joined(separator: "\n")

        state["what"] = .string("""
            This item's merge to the project's base could not be completed automatically: \(exclusionReason)

            The worktree is the item's own branch, already merged against the current base — resolve it as it \
            stands. Keep both sides' tests and behavior; integrate them rather than redesigning either. Change \
            nothing outside \(conflictedPaths.isEmpty ? "what the failing verify names" : "the conflicted paths"):
            \(scopeSurface)

            Once resolved, run the full verify plan below and commit. This is a rescue run: it exists because \
            the gate's own automatic retry already gave up, so the fix has to be a real integration, not \
            another mechanical re-merge.
            """)

        state["acceptanceCriteria"] = .string("""
            - The merge/verify failure named above is resolved
            - Both sides' tests and behavior are preserved
            - Nothing changes outside \(conflictedPaths.isEmpty ? "the failing verify's own surface" : "the conflicted paths: " + conflictedPaths.joined(separator: ", "))
            - The verify commands below pass on the merged tree
            """)

        if let notes = detail?.notes, !notes.isEmpty {
            state["previousFeedback"] = .string(
                "Notes recorded on this item so far, most recent first:\n\n\(notes)")
        }

        return state
    }
}

#if DEBUG
/// Test seam. Staging a run in flight for real means a workflow engine, two live
/// agent sessions and minutes of wall clock; these setters put the autopilot
/// into the state such a run would have reached so callers of it — the control
/// API's cancel and log endpoints — can be tested against it. In the same file
/// because the properties are `private(set)`, and DEBUG-only so no release path
/// can use them as a back door.
extension BacklogAutopilot {
    /// Runs the gate's retry sweep on demand — what `refreshGateFreshnessIfPossible`
    /// invokes after every freshness recompute, without needing a live run
    /// or a fired trigger to reach it.
    func retryGateMergesForTesting(backlog: BacklogViewModel, projectRoot: URL) async {
        await retryGateMerges(backlog: backlog, projectRoot: projectRoot)
    }
    /// The plan the merge gate would run for `item`, without merging anything.
    func mergeVerifyPlanForTesting(for item: BacklogItem) async -> MergeVerifyPlan {
        await mergeVerifyPlan(for: item)
    }
    /// Redirects the retry ceiling's ledger to a temp file — the real one
    /// lives under `~/.kiteloop`, which a test must never write to.
    func stageGateRetryLedgerURLForTesting(_ url: URL) { gateRetryLedgerURL = url }
    /// The same redirection for the rescue extension's own ledger.
    func stageRescueLedgerURLForTesting(_ url: URL) { rescueLedgerURL = url }
    /// Drives one exclusion straight into the rescue extension, the way
    /// `retryGateMergesForTesting` drives a sweep into the ordinary gate
    /// retry — without needing to first manufacture the exact ceiling
    /// `GateRetry.classify` itself already has its own tests for.
    func handleGateExclusionForTesting(
        item: BacklogItem, reason: String, backlog: BacklogViewModel, projectRoot: URL
    ) async {
        let key = KiteloopProject.canonicalPath(projectPath ?? projectRoot.path(percentEncoded: false))
        var rescueLedger = RescueRun.Ledger.load(from: rescueLedgerURL)
        await handleGateExclusion(item: item, reason: reason, backlog: backlog, projectRoot: projectRoot,
                                  key: key, rescueLedger: &rescueLedger, rescueLedgerURL: rescueLedgerURL)
    }
    func stageExecutionIDForTesting(_ id: String?) { currentExecutionID = id }
    /// The one step of the run loop this file's hold depends on: where the loop
    /// leaves the status once the whole queue is behind it. Driving the loop
    /// itself means a workflow engine and two live sessions; this is the act
    /// that used to write `idle` over a pause, run on its own.
    func settleStatusAfterRunForTesting() { settleStatusAfterRun() }
    /// What a `start()` decided, without one having to be driven all the way to
    /// the gate that decides it — the state `POST /v1/runs` reads to tell a
    /// refused start from one still spinning up. Goes through the same recorder
    /// production does, so the attempt counter advances the way it really would.
    func stageStartOutcomeForTesting(refusal: StartOutcome.Refusal?, detail: String) {
        recordStartOutcome(refusal, detail)
    }
    func stageResultForTesting(_ result: ItemResult) { results.append(result) }
    /// Drives the pre-review gate's verify — the last thing between a run's diff
    /// and the reviewer — without the live workflow execution that is otherwise
    /// the only way to reach it. Returns what the gate returns: true lets the
    /// review run, false ends the run here.
    ///
    /// `timeout` defaults to nil, which runs the clock production runs on
    /// (`verifyTimeout`). A test watching the deadline actually fire passes a
    /// short one instead of sitting out the ten-minute floor a derived gate
    /// deadline can never go below.
    func verifyAllowsReviewForTesting(worktree: URL?, timeout: TimeInterval? = nil) async -> Bool {
        await verifyAllowsReview(worktree: worktree, executionID: "test-execution",
                                 timeout: timeout ?? verifyTimeout)
    }
    /// Drives the salvage re-check — the verify a cut-short run's work is
    /// judged on — without a run having to be cost-capped to reach it. Runs the
    /// same command against the same tree the pre-review gate does.
    ///
    /// `timeout` defaults to nil, the clock production runs on
    /// (`verifyTimeout`); a test watching the deadline fire passes a short one
    /// rather than sitting out the gate deadline's ten-minute floor.
    func salvageVerifyPassesForTesting(item: BacklogItem, detail: BacklogItemDetail?,
                                       worktree: URL?, timeout: TimeInterval? = nil) async -> Bool {
        await salvageVerifyPasses(item: item, detail: detail, worktree: worktree, timeout: timeout)
    }
    /// Drives the coverage gate's run of the commands a gap names, against a
    /// verdict and map a test builds by hand rather than a run's real diff.
    /// `timeout` defaults to nil, the verify gate's own clock.
    func runCoverageGapCommandsForTesting(verdict: VerifyCoverage.Verdict, map: VerifyCoverage.Map,
                                          item: BacklogItem, worktree: URL?,
                                          timeout: TimeInterval? = nil) async -> String? {
        await runCoverageGapCommands(verdict: verdict, map: map, item: item, worktree: worktree, timeout: timeout)
    }
    /// What the pre-review gate or the salvage re-check measured of the item's
    /// `verify:` — the value `recordMetric` files on the run's metric record.
    var lastVerifyVerdictForTesting: RunVerifyVerdict? { lastVerifyVerdict }
    /// The signal the gate was shut with, or nil while it is not shut.
    var closedReviewGateSignalForTesting: String? {
        guard case .closed(let signal) = reviewGate else { return nil }
        return signal
    }
    /// What the *next* run does to the last one's evidence: `start()` clears the
    /// in-memory results before it queues anything. Anything that reported a
    /// finished run by reading them has to survive this.
    func clearResultsForTesting() { results = [] }
    /// The pair that says "a run is in flight": what phase it is in and the queue
    /// its index points into. Set together — an index with no queue behind it is
    /// a state a real run never reaches.
    func stageRunForTesting(status: Status, queue: [BacklogItem]) {
        runQueue = queue
        self.status = status
    }
    /// One phase boundary through the real bookkeeping — the same call
    /// `logPhase` makes, which is what times each rail step — so a test can
    /// measure what a run's phases put on its metric record instead of staging
    /// the durations it is checking. `now` is explicit because the durations
    /// are differences between these instants.
    func notePhaseForTesting(_ phase: RunPhase, at now: Date) {
        noteRunPhase(phase, fields: [], now: now)
    }
    /// Files `record` the way a finished run does, so the phase durations the
    /// run measured are read onto it here rather than written by the test.
    func fileMetricForTesting(_ record: TaskMetricRecord, to store: TaskMetricStore) {
        fileMetric(record, to: store)
    }
    /// The phase rail's live fields, without driving a real `logPhase` call to
    /// set them.
    func stagePhaseRailForTesting(phase: RunPhase?, attempt: Int = 1, lastActivityAt: Date = Date()) {
        currentRunPhase = phase
        currentRunAttempt = attempt
        self.lastActivityAt = lastActivityAt
    }
    /// The run loop being mid-execution — the half of "a run is in flight" that
    /// no observable property can be staged into, since it is set and cleared
    /// around the loop itself.
    func stageExecutingRunForTesting(_ executing: Bool) { isExecutingRun = executing }
    /// A session budget already spent: what a run stopped by the session cost cap
    /// leaves behind, and the state a resume opens a fresh session out of.
    func stageSpentSessionForTesting(capUSD: Double, spentUSD: Double) {
        costGovernor.sessionCapUSD = capUSD
        costGovernor.chargeItem(spentUSD)
    }
    /// The cost figures an item in flight has once the watchdog has sampled it:
    /// what it has spent, the ceiling `beginItem` fixed for it, and the forecast
    /// that ceiling came from — what the control API reports on a live run.
    func stageInFlightCostForTesting(
        spentUSD: Double,
        capUSD: Double?,
        prediction: CostGovernor.Prediction? = nil
    ) {
        costGovernor.stageInFlightForTesting(spendUSD: spentUSD, capUSD: capUSD, prediction: prediction)
    }
    /// The learning-engine store `configure` wires up, for tests that need the
    /// autopilot to answer for a run it recorded without standing up a project.
    func stageMetricStoreForTesting(_ store: TaskMetricStore) {
        metricStore = store
        costGovernor.metricStore = store
    }
    /// When the staged item was picked up — what the run-state endpoints report
    /// as `startedAt`. Stamped by the run loop in production, so a staged run has
    /// to place it explicitly.
    func stageItemStartedAtForTesting(_ date: Date?) { currentItemStartedAt = date }
    /// How far into the queue a paused run got, so a test can stage a hold that
    /// still has items to resume (a genuine hold) or one that has none (stale).
    func stageQueueIndexForTesting(_ index: Int) { currentIndex = index }
    /// Timestamps are explicit: the log endpoint slices by them, so a test has to
    /// place lines before, during and after a run's window. Rolls at
    /// `logCapacity` the way `appendLog` does — a test staging a full buffer has
    /// to get a full buffer and not one line more, or it is testing a state the
    /// autopilot never reaches.
    func stageLogEntryForTesting(_ message: String, at timestamp: Date) {
        log.append(LogEntry(timestamp: timestamp, message: message))
        if log.count > Self.logCapacity {
            log.removeFirst(log.count - Self.logCapacity)
        }
    }
    /// Empties the buffer, so staged lines are the whole of it. Anything the
    /// autopilot narrated while a fixture drove it into position — `pause()`
    /// logs "Paused by user" — is stamped with the real clock, and a real
    /// timestamp mixed in with staged ones defeats every test that slices by
    /// time.
    func clearLogForTesting() { log = [] }
    /// The park a run that ended badly takes when the usage limit stands —
    /// reached in production only at the end of a live workflow.
    func parkIfUsageLimitedForTesting(_ item: BacklogItem, backlog: BacklogViewModel) -> ItemResult? {
        parkIfUsageLimited(item, duration: 1, backlog: backlog)
    }
    /// One cost sample of the execution as the poll loop takes it on poll
    /// `pollCount`. The loop polls every 2s and samples on every eighth poll,
    /// so a test reaching the sample through a live run waits 16s for it —
    /// and covered it only when a run happened to be that slow.
    func sampleCostForTesting(executionID: String, itemID: String?, pollCount: Int) async -> CostSampleOutcome? {
        guard let orchestrator,
              let execution = await orchestrator.workflowEngine.execution(id: executionID) else { return nil }
        return await sampleCost(execution: execution, executionID: executionID, itemID: itemID,
                                orchestrator: orchestrator, pollCount: pollCount)
    }
    /// Puts a run in flight the way `start()` does right before it begins
    /// executing the queue — the state `finalizeRunRecordForTesting` needs
    /// something to fold into `runHistory`.
    func stageCurrentRunRecordForTesting(_ record: RunRecord) { currentRunRecord = record }
    /// What `start()` does at the end of every run: fold `currentRunRecord`
    /// into `runHistory` (newest first, capped at 30) and persist it — the
    /// same path a test for the per-project history file exercises without
    /// driving a whole workflow through it.
    func finalizeRunRecordForTesting() { finalizeRunRecord() }
    /// Re-reads `runHistory` from disk — what a fresh launch of the same
    /// project does — so a test can tell a save actually reached the file
    /// rather than only updating the in-memory array.
    func reloadHistoryForTesting() { loadHistory() }
    /// The pickup pass on its own: `runQueue` as the gates leave it — same
    /// order, same refusals — without the two live sessions the rest of
    /// `start()` needs. `start()` itself is no substitute here: a selection
    /// with no agent session behind it is emptied on the way past, so the
    /// queue it built cannot be read from outside afterwards.
    func admitSelectionForTesting() async {
        guard let context = startContext() else { return }
        _ = await admitSelection(context: context)
    }
    /// The drift half of an item's exit path, over an execution a test builds
    /// by hand rather than one a reviewer ran.
    func recordDriftFindingsForTesting(execution: WorkflowExecution?, item: BacklogItem,
                                       backlog: BacklogViewModel) {
        recordDriftFindings(execution: execution, item: item, backlog: backlog)
    }
    /// One tick of the stall watchdog, with the clock handed in: the real
    /// deadline has a floor of minutes, which no test should sit out.
    func handleStallForTesting(execution: WorkflowExecution, itemID: String?, activeAgentID: String?,
                               lastProgressAt: Date, stallTimeout: TimeInterval) async -> ExecutionStatus? {
        await handleStall(execution: execution, executionID: execution.id, itemID: itemID,
                          activeAgentID: activeAgentID, lastProgressAt: lastProgressAt,
                          stallTimeout: stallTimeout)
    }
    /// Why the watchdog last ended a run — what the item's failure path reads.
    var lastStallReasonForTesting: String? { lastStallReason }
    /// Follows a pull request's checks the way a run that just opened one does,
    /// without the run: `gh` is whatever the test's subprocess runner answers.
    func followPullRequestChecksForTesting(item: BacklogItem, branch: String,
                                           url: String) async -> PullRequestChecks.Outcome {
        await followPullRequestChecks(item: item, branch: branch, url: url,
                                      executionID: "test-execution").outcome
    }
    /// The comment pass as a run reaches it, behind green checks.
    func addressPullRequestCommentsForTesting(item: BacklogItem, url: String,
                                              alreadySpentUSD: Double) async -> PullRequestComments.Outcome {
        await addressPullRequestComments(item: item, detail: nil, branch: "kiteloop/\(item.id)", url: url,
                                         executionID: "test-execution",
                                         alreadySpentUSD: alreadySpentUSD).outcome
    }
    /// Lands a comment pass's work from the checkout `WorktreeManager` keeps
    /// for `item` — the half of `runCommentPass` that runs once the worker is done.
    func landCommentPassForTesting(item: BacklogItem, branch: String, worktree: URL,
                                   before: String?, backup: String?) async -> (committed: Bool, failure: String?) {
        guard let projectRoot else { return (false, "no project root") }
        return await landCommentPass(manager: WorktreeManager(projectRoot: projectRoot), item: item,
                                     branch: branch, worktree: worktree, projectRoot: projectRoot,
                                     before: before, backup: backup)
    }
    /// The verify-coverage gate against a branch the test made, rather than
    /// one a run left.
    func verifyCoverageGapForTesting(item: BacklogItem, branch: String?, isolated: Bool,
                                     worktree: URL?) async -> String? {
        await verifyCoverageGap(item: item, detail: backlogViewModel?.loadDetail(for: item),
                                branch: branch, isolated: isolated, worktree: worktree)
    }
}
#endif
