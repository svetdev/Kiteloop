import Foundation
import KiteloopCore

/// One measured execution of a backlog item — the raw material the learning
/// engine aggregates to predict how long future tasks take. Captured after an
/// autopilot run completes.
struct TaskMetricRecord: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    let projectPath: String
    let projectName: String
    let itemID: String
    let title: String
    let epic: String?
    /// Declared `ItemSize.rawValue` at execution time, if the item had one.
    let declaredSize: String?
    let startedAt: Date
    let completedAt: Date
    let durationSeconds: Double
    let costUSD: Double
    /// Rework loops: extra reviewer passes beyond the first — the v1 "errors" signal.
    let reviewerRetries: Int
    /// This run's review rounds, in order — reject, pass, made readable
    /// on the item's page without opening the transcript. `ReviewRounds.rounds`
    /// reads them off the execution's own steps once, at the moment this record
    /// is written; nil means a record from before this field existed, not that
    /// the run had no rounds.
    var reviewRounds: [ReviewRound]?
    /// The classes (`ReviewFindings.Finding.overrideClass`) of the blocking
    /// findings on the review that ended this run — read at the same moment as
    /// `reviewRounds`, off the same discarded execution. Non-empty only for a
    /// run whose last review rejected and whose own `verify:` salvaged it
    /// anyway (a review can never *pass* while still carrying a blocking
    /// finding — `ReviewFindings.route` forces the verdict false whenever one
    /// exists). What `FindingOverrideLedger` reads when a human then approves
    /// the item at the gate over that unresolved objection. Nil for a record
    /// from before this field existed, which is not the same as "measured, and
    /// there were none" — that reads `[]`.
    var lastReviewBlockingFindingClasses: [String]?
    let outcome: String
    let workerAgent: String?
    let reviewerAgent: String?
    let executionID: String?
    /// Reserved for finer per-tool error counts (permission denials, verify
    /// failures) — not populated in v1.
    var toolErrors: Int?
    /// LLM-as-judge overall quality score (0–1), advisory — set by run-quality-judge.
    var qualityScore: Double?
    /// Per-dimension judge scores (verify_passed / scope_respected / tests_meaningful / conventions).
    var judgeDimensions: [String: Double]?
    /// Why this run has no `qualityScore` — a
    /// `RunQualityJudge.Unavailability.rawValue`. Set whenever the judge didn't
    /// deliver a verdict, so a night of `no-reply` reads as the infrastructure
    /// failure it is rather than as a quality collapse. Stored as a string, not
    /// the enum: an unknown reason from a newer build must not fail the whole
    /// line's decode. Nil alongside a nil score means the record predates this
    /// field, not that the judge succeeded.
    var judgeUnavailableReason: String?
    /// Whether the diff the judge actually saw was cut short before it reached
    /// the judge — `RunQualityJudge.diffCharacterLimit` on the raw diff text,
    /// independent of the diff-stat summary the judge is also shown. A score
    /// read through a truncated window says as much about how big the diff was
    /// as about how good the work was, so it must not be silently averaged in
    /// beside scores taken over the whole diff.
    ///
    /// Nil when the question doesn't apply: the judge was never asked (off for
    /// the project, the item was cancelled, no runtime configured), or the
    /// record predates this field. `false`/`true` are both measurements — a run
    /// whose diff fit whole is as much a fact as one that didn't.
    var qualityScoreDiffTruncated: Bool?
    /// Whether the item's work landed on main. Not derivable from `outcome`:
    /// `done` is reached both by an auto-merge and by a project whose flow has
    /// the approval gate off, and only the first of those actually merged.
    /// Optional so records written before this existed still decode — nil is
    /// "unknown", which `PortfolioReport` counts as not merged rather than
    /// guessing.
    ///
    /// **Nothing sets this when the record is written**, and nothing can: the
    /// row is appended when the run ends, and the merge is decided afterwards at
    /// the gate. It is filled in on the way back out, by `MergeOutcomeFold`
    /// folding the `ItemMergeEvent` recorded at that gate onto this run. A run
    /// whose gate nobody has resolved keeps it nil, which is the truth.
    var merged: Bool?

    /// What actually gated the merge: the commands run on the merged tree, named
    /// as `MergeVerifyPlan.Step.label` (`item verify: …`, `merge-verify: …`), in
    /// run order.
    ///
    /// Nil means no merge was attempted, or the record predates this field. An
    /// **empty** list means one was and nothing checked it — a different fact,
    /// and the one worth finding in a ledger. Recorded because a merge validated
    /// by a suite unrelated to the diff (see `MergeVerifyPlan`) was otherwise
    /// invisible after the fact: reconstructing it meant pairing the diff with
    /// whatever the project config happened to say that night.
    var mergeVerifyCommands: [String]?

    /// What the app measured when it ran the item's own `verify:` before letting
    /// the reviewer near the diff — exit status, the command, the directory it
    /// ran in and the last lines it printed.
    ///
    /// Nil means no verdict was taken: a record written before this field
    /// existed, an item that declares no `verify:`, or a run that ended before
    /// the pre-review gate was ever asked. It is **not** "the verify passed" —
    /// that reads as an `exitStatus` of 0, which is a measurement.
    ///
    /// It exists because the one thing the gate stands on was the one thing
    /// nothing recorded. On 2026-09-08 a run reached the approval gate with its
    /// own new unit test failing deterministically on its branch, and no record
    /// anywhere — metric row, control run record, run log — could say whether
    /// the item's verify had run at all, let alone what it answered.
    var verify: RunVerifyVerdict?

    // MARK: - How long each bounded phase took
    //
    // `durationSeconds` above is the whole run — every phase plus everything
    // between them, including whatever the run waited on. Nothing is ever timed
    // against it, so it cannot set a deadline: `RunTimeouts` derives the worker
    // node's clock and the merge gate's clock from the phase each one actually
    // bounds, and these are where it reads them.
    //
    // Both are the *longest single stretch* the run spent in that phase, not
    // the sum: what they feed is one activation's deadline, and a run that took
    // three worker rounds spent each of them under its own clock.

    /// Seconds in the run's longest worker-node activation — `worker.start` to
    /// the phase that followed it, which is the whole of what
    /// `nodeTimeoutSeconds` bounds (the worker's own `verify:` included).
    ///
    /// Nil means unmeasured: a record written before this field existed, or a
    /// run that never reached a worker phase. `RunTimeouts` skips those rather
    /// than reading them as zero.
    var workerPhaseSeconds: Double?

    /// The turns the worker's session reported on its last hand-off. Nil for a
    /// runtime that counts none, a run whose worker never handed off, and a
    /// record written before this field existed.
    var workerTurns: Int?

    /// Whether a turn cap cut the worker short — its session's own, or the
    /// worker node's `maxTurns` — so the run ended with the work unfinished
    /// rather than on a verdict about it. Nil on a record written before this
    /// field existed, which is not "it finished".
    var workerCutShort: Bool?

    /// Seconds in the run's longest merge-gate stretch — the gate's verify from
    /// the moment it started to the moment it answered, which is what the gate's
    /// own timeout bounds.
    ///
    /// Nil for a run that never reached the gate — most runs — as well as for a
    /// record written before this field existed. A run with both this and
    /// `workerPhaseSeconds` is what `RunTimeouts` counts as a landed run.
    var gatePhaseSeconds: Double?

    /// Seconds in the run's longest pre-review verify — the item's own
    /// `verify:` from the moment the gate started it to the moment it answered.
    ///
    /// The same clock bounds it as bounds `gatePhaseSeconds` (`verifyTimeout`),
    /// and it is the same command on the same class of tree, so `RunTimeouts`
    /// reads both as gate samples and takes the larger of the two. Without it a
    /// project running under `propose` — parking every passed run at the
    /// approval gate, so never measuring a merge phase — could never earn a
    /// measured gate deadline, and kept dying at the 15-minute default.
    ///
    /// Nil for a run that declared no `verify:`, one that ended before the
    /// pre-review gate, and a record written before this field existed. Not a
    /// zero: a verify nobody timed is not a verify that took no time.
    var verifyPhaseSeconds: Double?

    // MARK: - What the run consumed
    //
    // `costUSD` above is a single derived number, frozen at whatever rate
    // applied when the run happened. These say what was actually consumed, so
    // spend can be re-priced when rates move, compared across models, and
    // checked for cache hit rate — the largest lever on what a long run costs.
    //
    // Every one is optional, and **nil means no turn recorded it**, not zero. A
    // run whose usage never arrived must not read as a run that consumed
    // nothing; records written before these fields existed decode with all of
    // them nil for the same reason.

    /// Prompt tokens billed at full price — the uncached remainder only, not the
    /// whole prompt. See `tokenUsage.promptTokens`.
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationTokens: Int?
    var cacheReadTokens: Int?
    /// The model the run's turns ran on, as the CLI reported it. Several joined
    /// by `+` when worker and reviewer ran on different models.
    var model: String?
    /// What each role was sent before it had done anything — `worker` and
    /// `reviewer` keyed to the opening context of their first model call. See
    /// `OpeningContext`, and `docs/opening-context.md` for what it decomposes
    /// into.
    ///
    /// Recorded per run because it is not a constant: it moves with the size of
    /// CLAUDE.md, the agent's knowledge package and the tool schemas, all of
    /// which change under it, and a figure measured once would be stale by the
    /// week. Nil — and a role simply absent from the dictionary — means no turn
    /// of that role reported an opening call, which every record written before
    /// this existed is in. Not zero: a run nobody measured is not a run that was
    /// sent nothing.
    var openingContext: [String: OpeningContext]?
    /// `costUSD` recomputed from the counters at `priceVersion`'s rates. Kept
    /// *beside* the reported figure rather than replacing it: when the two
    /// disagree — a model missing from the table, a rate that moved, a cache
    /// write billed at the 1-hour TTL — the disagreement is the signal.
    var derivedCostUSD: Double?
    /// The `ModelPriceTable` revision `derivedCostUSD` was computed at, so a
    /// re-price can say what it is re-pricing from.
    var priceVersion: String?

    // MARK: - What the run was forecast to cost
    //
    // The forecast that set this run's ceiling, kept beside what the run
    // actually cost. Predictions were made before every run and thrown away
    // afterwards, so the forecast had no error signal and could not improve —
    // "cost cap $8.00 exceeded" said nothing about whether $8 was ever the right
    // number. The pairing is what turns sizing from a guess repeated nightly
    // into a forecast with a measurable error.

    /// What `CostGovernor` predicted this item would cost, at pickup. Nil when
    /// there was nothing to predict from (and on records written before this
    /// existed) — never zero, which would read as a forecast of free.
    var predictedCostUSD: Double?
    /// Which rung produced it — a `CostGovernor.PredictionSource.rawValue`.
    /// Stored as a string so an unknown source from a newer build can't fail the
    /// whole line's decode.
    var predictionSource: String?

    /// Whether this run crossed its per-item cost ceiling.
    ///
    /// The item cap is advisory — `BacklogAutopilot` records the breach and lets
    /// the run finish, because killing an item mid-review threw away work that
    /// had already been paid for. "Records the breach" was, until this field
    /// existed, one log line and an in-memory set cleared at the start of the
    /// next run, so the number the advisory design exists to produce — which
    /// items outgrow their estimate — did not survive the night.
    ///
    /// Optional for the reason every field around it is: nil means the record
    /// was written before this existed, which is not the same as `false`. A run
    /// this app measures always writes one or the other.
    var overItemCap: Bool?

    /// Actual minus predicted: positive means the run cost more than forecast.
    /// Nil when nothing was forecast — an unmeasured error, not an error of 0.
    var costPredictionErrorUSD: Double? {
        predictedCostUSD.map { costUSD - $0 }
    }

    /// The error as a share of the prediction — 0.5 = half again as expensive as
    /// forecast. Nil when there was no usable prediction to be wrong by.
    var costPredictionErrorRatio: Double? {
        guard let predicted = predictedCostUSD, predicted > 0 else { return nil }
        return (costUSD - predicted) / predicted
    }

    // MARK: - Whether the run produced anything

    /// Files the run left changed — its branch against the project's `HEAD`,
    /// plus anything teardown kept uncommitted in its worktree, read before any
    /// auto-merge folded the branch in. Nil means nobody could tell — a
    /// live-tree run with no branch and no worktree of its own, or a record
    /// written before this field existed — which is not the same as a run that
    /// changed nothing.
    var changedFileCount: Int?

    /// Which version of the item this attempt was made against —
    /// `RetryCeiling.specFingerprint` of its What / How / Validation at pickup.
    ///
    /// What makes "re-groom it" a real instruction rather than advice. The retry
    /// ceiling counts an item's empty attempts, and a retired item cannot run, so
    /// nothing it could do would ever clear the count; the only escape was to
    /// rename the item and throw away its history. With the fingerprint recorded,
    /// an attempt made against wording the item no longer has is visibly an
    /// attempt at a different item, and stops counting against this one.
    ///
    /// Nil means the version is unknown — a record written before this field
    /// existed, or an item with no detail file. Unknown counts, so a ledger full
    /// of old records doesn't release every item in it at once.
    var specFingerprint: String?

    // MARK: - Whether the attempt ran at all

    /// How the outcome of an attempt that never started is spelled:
    /// `did-not-run:<clause>`, the clause being the pickup gate that refused it
    /// (`RetryCeiling.PickupRefusal`).
    ///
    /// A refused item used to leave no row at all, so the one bound on an item
    /// that never advances — `RetryCeiling`, which counts rows — could not see
    /// it: a run that started and produced nothing was counted, and an item the
    /// gate turned away at the door was not. Recording the refusal as an outcome
    /// of its own keeps the two distinguishable while making both countable.
    static let didNotRunPrefix = "did-not-run:"

    /// Whether this row records a refusal at pickup rather than an execution.
    ///
    /// A refusal is a real attempt on the item — that is the whole point of
    /// recording it — but it is not a *run*: no session was spawned, so its
    /// zeroes are the absence of an execution rather than a measurement of one.
    /// Anything averaging what runs cost, counting how many there were, or
    /// asking which run a later event belongs to reads this and skips the row;
    /// anything counting attempts (`RetryCeiling`) or listing an item's history
    /// (`ItemRunHistory`) does not.
    var didNotRun: Bool { outcome.hasPrefix(Self.didNotRunPrefix) }

    /// What a recorded run left behind: three answers, not two.
    ///
    /// The third one is the point. A run whose outcome the code cannot place
    /// used to be read as productive, and `blocked:stalled: no progress for 20
    /// min on worker` is exactly such an outcome — so a twenty-minute stall that
    /// left no branch counted as work and cleared `RetryCeiling`'s streak, and
    /// an item alternating stalls with empty runs was never retired. Assuming
    /// work happened is the direction that fails open, and every consumer here
    /// would rather be told the question is open.
    enum WorkEvidence: String, Equatable, Sendable {
        /// The run left files behind.
        case produced
        /// The run left nothing.
        case empty
        /// Nobody can say. No file count was recorded and the outcome is not one
        /// that answers the question by itself.
        case unknown
    }

    /// The outcomes that are themselves evidence a run left work behind, for the
    /// records that carry no file count (~280 of them, written before the count
    /// existed).
    ///
    /// Short on purpose, and matched exactly rather than by prefix. `done` and
    /// `awaiting-approval` are only reached after `RunWorkEvidence.inspect` has
    /// already found a branch with a non-empty diff — an empty run is turned
    /// back before it can wear either. A review rejection is an attempt on the
    /// item's merits: the reviewer read a diff and said no, which is the one
    /// distinction `RetryCeiling` exists to preserve.
    ///
    /// Everything else a run can be blocked on — a stall, a timeout, a cost cap,
    /// exhausted retries — says nothing either way, and is `unknown`.
    ///
    /// `blocked:reviewer verdict unreadable` is deliberately **not** here, and
    /// that is the whole reason it is spelled differently from a rejection. No
    /// verdict was ever routed, so nobody read a diff and said no; counting it as
    /// an attempt on the merits is what let an approval nobody could parse be
    /// filed against the item as a review that found defects. Being absent from
    /// this set is not enough on its own — see `outcomesReachingNoVerdict`.
    static let outcomesShowingWork: Set<String> = [
        "done",
        "awaiting-approval",
        "blocked:review did not pass",
    ]

    /// The outcomes that answer the question *before* the file count does,
    /// because they say no verdict on the work was ever reached.
    ///
    /// The pair to `outcomesShowingWork`, read the same way: matched exactly
    /// rather than by prefix, and short on purpose — a second member is a
    /// decision somebody makes deliberately, not something a prefix sweeps in.
    ///
    /// It exists because leaving `blocked:reviewer verdict unreadable` out of
    /// the set above only bit when no file count had been recorded, and the
    /// count is recorded for every isolated run. A worker that writes files and
    /// a reviewer that keeps answering in a form nothing can route is a run that
    /// looks productive to `RetryCeiling` forever: all five such runs in the
    /// ledger changed files (2, 8, 2, 2 and 6), so all five counted as work and
    /// none counted as an attempt, and nothing bounded the loop. The bound needs
    /// "did this run reach a verdict on its merits?", which the file count is not
    /// an answer to.
    ///
    /// The spelling is `"blocked:" + BacklogAutopilot.unreadableVerdictReason`,
    /// as the run loop composes it; `RetryCeilingTests` asserts the two still
    /// agree, so renaming the reason cannot quietly empty this set.
    static let outcomesReachingNoVerdict: Set<String> = [
        "blocked:reviewer verdict unreadable",
    ]

    /// The outcome of a run that changed no files and said, with evidence, why:
    /// the worker's claim that the item is already built.
    ///
    /// Its own outcome rather than `blocked:run produced no work`, because the
    /// two are different facts wearing one sentence. CLAUDE.md tells a worker
    /// with an empty diff to "either make the change, or say plainly that you
    /// believe it is already implemented and why" — and only the first half had
    /// an ending. The second was filed as a failure and counted against
    /// `RetryCeiling`, so `wizard-hands-off-to-a-first-project` was retired on
    /// 2026-08-21 after three runs by three workers, each of them following the
    /// rule and each of them naming the code it had read.
    ///
    /// `RunWorkEvidence.AlreadyImplementedClaim` is what reads the claim; this
    /// is what the run is then filed under.
    static let alreadyImplementedOutcome = "already-implemented"

    /// The outcome of a run that changed no files because the worker checked
    /// the item's `## Premise` against the tree and refuted it — the other
    /// answer *about* an item, beside the claim above. On 2026-09-03 an item
    /// asserted four functions qualified for a change; the run that measured,
    /// found one did and refused the other three was the day's best run, and
    /// was filed as a diff that added no tests (0.55). `PremiseReport` is what
    /// reads the worker's measurement; this is what the run is then filed
    /// under, and `RetryCeiling` counts it neither for nor against the item.
    static let investigationOutcome = "investigation"

    /// The outcomes that are an answer *about* the item rather than an attempt
    /// *at* it.
    ///
    /// The third member of the family above, read the same way: matched exactly
    /// rather than by prefix, and short on purpose — the second member was a
    /// decision made deliberately, not something a prefix swept in.
    ///
    /// What separates it from `outcomesShowingWork` is that no work is claimed
    /// to exist: the run left no diff, and `workEvidence` below says `.empty`
    /// for it, which is the measurement. What separates it from an ordinary
    /// empty run is that it says something the ledger can act on, and the item
    /// is now sitting at a human gate waiting for that claim to be judged.
    /// `RetryCeiling` reads this and counts such a run neither for nor against
    /// the item, exactly as it treats a cancel.
    static let outcomesClaimingAlreadyImplemented: Set<String> = [
        alreadyImplementedOutcome,
        investigationOutcome,
    ]

    /// Whether this row is a worker's evidenced claim that the item was already
    /// built, rather than an attempt at building it.
    var claimsAlreadyImplemented: Bool {
        Self.outcomesClaimingAlreadyImplemented.contains(outcome)
    }

    /// The outcome `RetryCeiling.refusalRecord` files a row under when the retry
    /// ceiling itself is what turned the item away — spelled out here, not
    /// referenced from `RetryCeiling.PickupRefusal.retired.outcome`, because
    /// `Models` sits below `Services` and cannot import it. `RetryCeilingTests`
    /// asserts the two stay equal.
    static let retiredRefusalOutcome = didNotRunPrefix + "retired"

    /// The outcome of a run the account's usage limit stopped — read from the
    /// CLI's `rate_limit_event`, not an exit code. The item went back to
    /// `ready` for when the limit lifts; the run was not an attempt at it.
    static let usageLimitParkedOutcome = "usage-limit-parked"

    /// Whether this row is a run the usage limit stopped rather than an
    /// attempt at the item. Matched exactly, like `isRetiredRefusal`.
    var isUsageLimitParked: Bool {
        outcome == Self.usageLimitParkedOutcome
    }

    /// Whether this row is the retry ceiling's own refusal to start an item it
    /// has already retired, rather than an attempt at the item.
    ///
    /// Recording it is right — it is the only visible trace that a retired item
    /// keeps being re-selected — but counting it is the bug this exists to fix:
    /// once retired, every later pass over the queue re-selects the item, writes
    /// one more of these, and the reported count climbs forever with no attempt
    /// behind it. It is a consequence of the retirement, not evidence about the
    /// item, so `RetryCeiling` skips it exactly as it skips a cancel.
    var isRetiredRefusal: Bool {
        outcome == Self.retiredRefusalOutcome
    }

    /// The outcomes `RetryCeiling.refusalRecord` files a row under when
    /// `GroundingCheck` or `DefinitionOfReady` refused the item for how it is
    /// *written* — spelled out here for the same reason `retiredRefusalOutcome`
    /// is: `Models` sits below `Services` and cannot import
    /// `RetryCeiling.PickupRefusal`. `RetryCeilingTests` asserts the two stay
    /// equal.
    static let draftedRefusalOutcomes: Set<String> = [
        didNotRunPrefix + "not-grounded",
        didNotRunPrefix + "not-ready",
    ]

    /// Whether this row is a pickup refusal that sent the item back to
    /// `draft` with the refusal as its reason, rather than an attempt at the
    /// item.
    ///
    /// The gate named exactly what to fix and the item now carries that
    /// reason in its own Notes, so the item is a groomed draft waiting on an
    /// edit, not a repeat of the same failed attempt. Counting it would
    /// retire an item over a citation nobody had a chance to read twice: the
    /// same sentence was refused three ticks running and the item was
    /// retired before anyone saw why. `RetryCeiling` skips it exactly as it
    /// skips a cancel or the ceiling's own refusal.
    var isDraftedRefusal: Bool {
        Self.draftedRefusalOutcomes.contains(outcome)
    }

    /// What this record says about whether the run produced anything.
    ///
    /// The file count decides it whenever there is one — a measurement of what
    /// the run left, which is why it is recorded for every isolated run
    /// including the ones that stall or time out. The outcome string is
    /// otherwise the fallback, and only for the two questions it can actually
    /// answer.
    ///
    /// The one exception is `outcomesReachingNoVerdict`, which is read *first*
    /// and vetoes the count. Those runs did leave files behind, so `.empty`
    /// would misreport them; but no verdict on them was ever routed, and every
    /// consumer here — the retry ceiling above all — is asking whether the run
    /// reached one. `.unknown` is the honest reading, and is already what "says
    /// nothing either way" means.
    var workEvidence: WorkEvidence {
        if Self.outcomesReachingNoVerdict.contains(outcome) { return .unknown }
        if let changedFileCount { return changedFileCount > 0 ? .produced : .empty }
        if outcome.contains(RunWorkEvidence.noWorkPrefix) { return .empty }
        if Self.outcomesShowingWork.contains(outcome) { return .produced }
        return .unknown
    }

    /// Whether this run left work behind, and so whether it says anything about
    /// what work of its size costs. Only `produced` counts: a run nobody can
    /// judge is not evidence of work.
    var producedWork: Bool { workEvidence == .produced }

    /// The four counters as one value, or nil when none were recorded.
    var tokenUsage: TokenUsage? {
        guard inputTokens != nil || outputTokens != nil
            || cacheCreationTokens != nil || cacheReadTokens != nil else { return nil }
        return TokenUsage(
            inputTokens: inputTokens ?? 0,
            outputTokens: outputTokens ?? 0,
            cacheCreationTokens: cacheCreationTokens ?? 0,
            cacheReadTokens: cacheReadTokens ?? 0
        )
    }

    /// Share of the run's prompt served from cache. Nil when nothing was
    /// recorded, so "not measured" never renders as a 0% cache.
    var cacheHitRate: Double? { tokenUsage?.cacheHitRate }

    /// Re-prices this run at `table` as of `date` — the whole point of keeping
    /// the counters. Nil when the run recorded no usage, or when its model is
    /// not one the table prices.
    func reprice(with table: ModelPriceTable = .current, on date: Date) -> PricedCost? {
        guard let usage = tokenUsage, let model else { return nil }
        return table.cost(of: usage, model: model, on: date)
    }
}

/// What running an item's own `verify:` answered, kept so a gate that let a red
/// tree through can be audited afterwards.
///
/// Everything here is a measurement of one command: the exit status it returned,
/// the command as it was run, the directory it ran in and the tail of what it
/// printed. Nothing here is an assessment — the judge's `verify_passed`
/// dimension is a reading of the worker's own account, and it scored 0.92 for
/// the run whose test was failing on its branch.
struct RunVerifyVerdict: Codable, Sendable, Equatable {

    /// How many trailing lines of the command's output are kept. Enough to hold
    /// a test runner's failure list and the summary under it, short enough to
    /// sit in a backlog note and a JSON body.
    static let outputTailLines = 40

    /// The command's exit status. 0 — and only 0 — is a pass; negative is
    /// `WorktreeManager.noExitStatus`, meaning no process ever returned one
    /// (the shell could not be spawned, or the deadline killed it).
    let exitStatus: Int32

    /// The command as it was run, after any rewrite the run applied to it (an
    /// isolated run points its builds at the worktree's own build directory).
    /// The command *as run* rather than as declared: what an audit has to be
    /// able to re-run is what actually ran.
    let command: String

    /// Where it ran — the run's worktree, or the project root for a live-tree
    /// run. A verify that passed in the wrong tree is the failure this names.
    let directory: String

    /// The last `outputTailLines` lines of the command's combined stdout and
    /// stderr. Empty when it printed nothing, or when there was nowhere to
    /// capture to.
    let outputTail: String

    /// Whether the deadline is what ended it, rather than the command
    /// answering. A killed command judged nothing about the tree, and its
    /// `exitStatus` cannot say so on its own.
    let timedOut: Bool

    var passed: Bool { exitStatus == 0 }

    /// The one-line reason a failed verify ends the run with — the words the
    /// run log, the item's outcome and the pre-review gate's phase line share.
    var signal: String {
        timedOut
            ? "verify timed out before it answered"
            : "verify failed (exit \(exitStatus))"
    }

    /// The last `outputTailLines` lines of `output`, trailing blank lines
    /// dropped so a command ending in newlines does not spend the budget on
    /// them.
    static func tail(of output: String) -> String {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.suffix(outputTailLines).joined(separator: "\n")
    }
}

/// A backlog item entering or leaving an **accepted** state — the raw material
/// for success metric #3b, the escaped-defect rate.
///
/// Transitions rather than statuses: an item read as `ready` at one moment
/// cannot tell you whether it was ever approved, so the moment it crosses the
/// line is what gets recorded.
struct ItemApprovalEvent: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// The item reached `done` — accepted, either by a human at the approval
        /// gate or by the project's flow when the gate is off.
        case approved
        /// An accepted item came back to `ready` or `blocked`. A reviewer
        /// bouncing an item that never reached `done` is a first-pass failure
        /// (metric #3a), not an escaped defect, and is not recorded here.
        case reopened
    }

    var id: String = UUID().uuidString
    let projectPath: String
    let projectName: String
    let itemID: String
    let kind: Kind
    let at: Date
    /// `.reopened` only: when the item had been approved, so the reopen can be
    /// placed inside or outside the 7-day window. A reopen is only recorded when
    /// its approval was observed, so this is always set on events this app
    /// writes; optional so a truncated or hand-edited log still decodes.
    var approvedAt: Date?
    /// `.reopened` only: the `BacklogItemStatus.rawValue` it came back to.
    var toStatus: String?
}

/// What became of a run's work at the merge gate — whether it reached the
/// project's main line, recorded at the moment that was decided.
///
/// An event rather than a field written on the run, because the two facts are
/// known at different times and the ledger is append-only. A run's
/// `TaskMetricRecord` is written when the run ends; the merge happens later, at
/// approval — so for as long as the record was the only place to put the answer,
/// there was no moment at which anything could have set it, and every row ever
/// written read `merged: nil`. `MergeOutcomeFold` folds these onto the runs they
/// describe when the records are read back.
///
/// Recorded only where the outcome is actually known. "The branch was already
/// merged, or there never was one" is two opposite answers and gets no event at
/// all: nil means unknown, and that is what nobody knowing means.
struct ItemMergeEvent: Codable, Identifiable, Sendable, Equatable {
    var id: String = UUID().uuidString
    let projectPath: String
    let projectName: String
    let itemID: String
    /// Whether the work reached the project's main line.
    let merged: Bool
    let at: Date
    /// The run this outcome belongs to, when the writer knows it. The autopilot's
    /// auto-merge does — it happens inside the run, *before* that run's metric row
    /// has been appended, so an id is the only thing that can join the two.
    /// The human gate has no run to name: the run ended long ago, and the event
    /// is placed by time instead. See `MergeOutcomeFold`.
    var executionID: String?
    /// Why, in the words the caller already had — the verify that gated the merge,
    /// or the reason there wasn't one. Carried for the reader of the log; nothing
    /// routes on it.
    var reason: String?
    /// The tail of what a retried verify step printed — the failing attempt,
    /// whether or not the step went on to pass — present only when a step
    /// needed a retry. The merged tree it ran against is a scratch worktree
    /// gone by the time anyone reads this row, so this is the one surviving
    /// copy of what it saw.
    var verifyOutput: String?
    /// The commit the base points at after a merge that landed — the durable
    /// link from the item to the work that satisfied it. Nil on a refusal,
    /// and on rows written before this field existed.
    var commit: String? = nil
}

/// Success metric #3b as computed over a window: the share of approvals that
/// came back within `windowDays` days.
struct EscapedDefectRate: Sendable, Equatable {
    /// The seven days the metric is defined over, inclusive at the boundary.
    /// Read from `EscapedDefectWindow.standard` rather than restated here, so
    /// this and `EscapedDefectReader` cannot drift on what counts as escaped.
    static let standardWindow: TimeInterval = EscapedDefectWindow.standard

    /// Approvals observed — the denominator. An item approved, reopened and
    /// approved again counts twice, because it passed review twice.
    let approvals: Int
    /// Approvals followed by a reopen *inside* the window — the numerator.
    let reopened: Int
    /// Reopens observed outside the window. Reported alongside so a rate of 0%
    /// can be told apart from "everything came back, just on day 30".
    let lateReopened: Int
    let windowDays: Int
    /// Nil with no approvals: 0/0 is "not measured yet", not "0%".
    var rate: Double? { approvals == 0 ? nil : Double(reopened) / Double(approvals) }
}

/// Success metric #3a: the share of judged runs a reviewer passed on the first
/// worker attempt.
///
/// The population is decided by `TaskMetricRecord.outcome` alone, and the three
/// prefixes below are the whole definition. They live here rather than on either
/// store because both compute the rate — `TaskMetricStore` by walking its array,
/// `MetricIndex` by counting in SQL — and a rule written twice in two places
/// drifts. The SQL is generated from these constants for the same reason.
///
/// What the classification turns on:
///
/// - A run that **passed** ends `done` or `awaiting-approval` — the two states
///   `BacklogAutopilot.accept` produces, one per flow (approval gate off, or a
///   human waiting at it). Reaching either means review said yes.
/// - A run that was **judged and did not pass** ends `blocked:<reason>`. That
///   covers a reviewer rejection, and also the ways a run can be cut short
///   before any reviewer saw it — a stall, a timeout, a cost cap. All of them
///   count against the rate: the SLO asks what share of started work review
///   passed first time, and a run that never got that far did not.
/// - A **cancelled** run is in neither half. A human stopped it, so it says
///   nothing about whether the loop's quality control works.
///
/// An outcome matching none of the prefixes — one a newer build writes — is
/// counted nowhere rather than guessed at.
struct FirstPassRate: Sendable, Equatable {
    /// Outcomes meaning review passed the run.
    static let passedPrefixes = ["done", "awaiting-approval"]
    /// The outcome family meaning the run was judged and did not pass.
    static let rejectedPrefix = "blocked"

    /// Whether review passed this run — the numerator's first half.
    static func passedReview(_ outcome: String) -> Bool {
        passedPrefixes.contains { outcome.hasPrefix($0) }
    }

    /// Whether this run belongs in the denominator at all.
    static func reachedVerdict(_ outcome: String) -> Bool {
        passedReview(outcome) || outcome.hasPrefix(rejectedPrefix)
    }

    /// Passed, with no rework loop behind it. `reviewerRetries` is reviewer
    /// passes *beyond the first*, so zero of them alongside a pass is exactly
    /// "the reviewer said yes to the first worker attempt".
    static func isFirstPass(outcome: String, reviewerRetries: Int) -> Bool {
        passedReview(outcome) && reviewerRetries == 0
    }

    /// Runs that reached a verdict — the denominator.
    let judged: Int
    /// Of those, the ones review passed on the first attempt — the numerator.
    let firstPass: Int
    /// Nil with nothing judged: 0/0 is "not measured yet", not "nothing passed".
    var rate: Double? { judged == 0 ? nil : Double(firstPass) / Double(judged) }
}

/// A pre-execution scope of a backlog item. Persisted so predictions can later
/// be calibrated against the matching `TaskMetricRecord`.
struct TaskEstimate: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    let itemID: String
    let projectPath: String
    let createdAt: Date
    /// Estimated `ItemSize.rawValue`.
    let estimatedSize: String
    let predictedDurationSeconds: Double
    let predictedCostUSD: Double?
    let predictedRetries: Int?
    /// 0…1 — higher when backed by more historical samples.
    let confidence: Double
    /// How the estimate was produced, e.g. "hybrid".
    let source: String
    let rationale: String
}

/// Rolled-up actuals for a size bucket (or epic), used by scoping and Insights.
struct TaskMetricSummary: Sendable {
    let sampleCount: Int
    let avgDurationSeconds: Double
    let avgCostUSD: Double
    let avgReviewerRetries: Double

    /// The Insights row's line under a bucket: cost, rework, run count —
    /// "$2.27 · 1.5 rework loops · 4 runs".
    var insightsDetail: String {
        let cost = "$" + String(format: "%.2f", avgCostUSD)
        let runs = "\(sampleCount) run\(sampleCount == 1 ? "" : "s")"
        return "\(cost) · \(reworkLabel) · \(runs)"
    }

    /// Rework is reviewer passes beyond the first; an average rounding to 0.0 is none.
    private var reworkLabel: String {
        let loops = String(format: "%.1f", avgReviewerRetries)
        if loops == "0.0" { return "no rework" }
        if loops == "1.0" { return "1 rework loop" }
        return "\(loops) rework loops"
    }
}
