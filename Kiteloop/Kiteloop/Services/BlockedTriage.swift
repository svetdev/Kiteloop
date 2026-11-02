import Foundation
import KiteloopCore

/// The blocked pile's decision half: given what a run **recorded**, is a blocked
/// item worth **retrying** unchanged, does it need **regrooming**, or has it
/// failed enough times that the only honest answer is to **escalate** and stop?
///
/// The constraint this answers is recovery, not grooming. `QueueRefill` decides
/// which project needs *more* work drafted for it; nothing decided anything about
/// the work already written and stuck. On 2026-08-07 five rejected items were
/// later merged by hand, unchanged: two had run with dead agent sessions and
/// produced empty diffs, two failed a `verify:` that passed cleanly minutes later
/// in isolation, and one was killed by a cost cap mid-review with the work
/// already done. **A rejection often says nothing about the work** — and a loop
/// that only grooms new work would have left all five dead and drafted more on
/// top.
///
/// Everything here is a value: no registry, no backlog, no clock, no git.
/// `CoordinatorBlockedTriage` is the half that observes and applies; this half
/// only decides, so the whole policy — what counts as environmental, when a
/// pattern becomes an escalation, the lifetime retry ceiling and the budget
/// refusal — is exercised without an app running.
///
/// Three properties are load-bearing, and each is enforced here rather than left
/// to a prompt:
///
/// * **Retry needs positive evidence.** A failure is re-runnable only when the
///   record shows the run never got as far as judging the work. Anything else —
///   including a reason nothing here recognises — is substantive and gets
///   feedback, because re-running something you can't explain is just spending.
/// * **The retry ceiling is a lifetime count.** It is read from a ledger on disk
///   (`Ledger`), not from a counter a pass owns, so a new pass — or a new launch
///   — does not reset it.
/// * **An exhausted budget refuses the whole plan**, before a single item is
///   classified. What triage buys is future runs, and those cost money.
enum BlockedTriage {

    // MARK: - Signals

    /// One run on record, as `TaskMetricStore` already holds it.
    ///
    /// Nothing here is derived by re-running anything: the outcome class, the
    /// reason half of `blocked:<reason>`, what the run cost, how long it lasted
    /// and what the judge scored are all written when the run ends.
    struct Run: Sendable, Equatable {
        /// The outcome class — `blocked`, `done`, `awaiting-approval`, `cancelled`.
        let outcome: String
        /// The reason half of `blocked:<reason>`, when the outcome carried one.
        let reason: String?
        let durationSeconds: Double
        let costUSD: Double
        /// The judge's advisory score, where the run has one.
        let qualityScore: Double?
        /// Per-dimension judge scores — `verify_passed`, `scope_respected`,
        /// `tests_meaningful`, `conventions`.
        let judgeDimensions: [String: Double]?
        let completedAt: Date
        /// Whether this run's branch has commits of its own. **Nil is "nobody
        /// looked"**, never "no" — the difference decides whether an empty
        /// worktree can be claimed as evidence at all. Only the newest run can
        /// carry it: a branch says what is on it now, not what was on it three
        /// runs ago.
        var branchHasCommits: Bool?

        init(outcome: String, reason: String? = nil, durationSeconds: Double = 0,
             costUSD: Double = 0, qualityScore: Double? = nil,
             judgeDimensions: [String: Double]? = nil, completedAt: Date = Date(),
             branchHasCommits: Bool? = nil) {
            self.outcome = outcome
            self.reason = reason
            self.durationSeconds = durationSeconds
            self.costUSD = costUSD
            self.qualityScore = qualityScore
            self.judgeDimensions = judgeDimensions
            self.completedAt = completedAt
            self.branchHasCommits = branchHasCommits
        }

        var isBlocked: Bool { outcome == Self.blockedOutcome }

        /// The class `BacklogAutopilot` writes for a blocked item, as
        /// `PortfolioSnapshot.splitOutcome` hands it back.
        static let blockedOutcome = "blocked"
    }

    /// Everything recorded about one blocked item, gathered into what a decision
    /// can be made from.
    struct Signals: Sendable, Equatable {
        let itemID: String
        let title: String
        /// The runs on record for this item, **newest first**.
        let runs: [Run]
        /// How many times triage has *ever* returned this item for a retry, read
        /// from the `Ledger` on disk. Lifetime, not per pass.
        let lifetimeRetries: Int

        init(itemID: String, title: String, runs: [Run] = [], lifetimeRetries: Int = 0) {
            self.itemID = itemID
            self.title = title
            self.runs = runs
            self.lifetimeRetries = lifetimeRetries
        }

        /// The blocked runs, newest first. A `done` or `cancelled` run in the
        /// list says nothing about why this item is stuck.
        var blockedRuns: [Run] { runs.filter(\.isBlocked) }
    }

    // MARK: - What went wrong

    /// The class of failure a recorded run describes — and the whole of the
    /// retry/regroom boundary, since `isEnvironmental` is what decides it.
    ///
    /// The split is not "bad run" vs "good run". It is **did the run ever get as
    /// far as judging the work**: a session that died, a watchdog that ended a
    /// hang and a cap that killed a run mid-review all stopped before any verdict
    /// about the code existed, so the item is re-runnable unchanged. A reviewer
    /// that rejected it, or a `verify:` that failed, *is* a verdict about the
    /// code.
    enum Failure: String, Sendable, CaseIterable {
        /// The run produced nothing at all — no billable work, or an empty
        /// branch, in near-zero time. The dead-session signature.
        case producedNothing
        /// A cost cap ended the run, with the work possibly already done.
        case costCapped
        /// The stall watchdog ended a run that had stopped making progress.
        case stalled
        /// The item's `verify:` failed.
        case verifyFailed
        case verifyUncovered
        /// The reviewer rejected the work, or the worker/reviewer loop ran out
        /// of attempts.
        case reviewRejected
        /// The reviewer answered, but not in a form the run could route — no
        /// pass/fail survived, even after the follow-up ask. No verdict about the
        /// code exists, so this is environmental however substantive the prose
        /// behind it was.
        case verdictUnreadable
        /// A recorded reason nothing here recognises. Substantive by default —
        /// see the type comment.
        case unrecognised

        /// Whether the run failed *around* the work rather than *on* it. Only
        /// these are re-runnable unchanged.
        var isEnvironmental: Bool {
            switch self {
            case .producedNothing, .costCapped, .stalled, .verdictUnreadable: return true
            case .verifyFailed, .verifyUncovered, .reviewRejected, .unrecognised: return false
            }
        }

        /// How the disposition record says it.
        var phrase: String {
            switch self {
            case .producedNothing: return "the run produced nothing in near-zero time (dead session)"
            case .costCapped: return "a cost cap ended the run"
            case .stalled: return "the stall watchdog ended the run"
            case .verifyFailed: return "the item's verify failed"
            case .verifyUncovered: return "the item's verify never runs a command the verify map demands for the diff"
            case .reviewRejected: return "the reviewer rejected the work"
            case .verdictUnreadable: return "the reviewer's verdict could not be read as pass or fail (not a rejection)"
            case .unrecognised: return "the run failed for a reason triage can't classify"
            }
        }
    }

    /// Read one run's recorded reason as a failure class.
    ///
    /// `producedNothing` is asked first because it is the only clause that can be
    /// true *whatever* the reason string says — a session that died before doing
    /// anything still ends with whatever reason the loop happened to write.
    static func failure(of run: Run, policy: Policy = Policy()) -> Failure {
        if producedNothing(run, policy: policy) { return .producedNothing }
        let reason = (run.reason ?? "").lowercased()
        if reason.contains("cost cap") { return .costCapped }
        if reason.contains("stalled") || reason.contains("no progress") { return .stalled }
        // Asked before the verify clause: an unreadable verdict is not a verdict
        // about the code, and the judge's dimension scores — which
        // `judgeMarkedVerifyFailed` reads — describe a review that was never
        // routed. Reading them here would file "nobody could read the answer" as
        // "your verify failed" and send the item back for a fix nobody asked for.
        if reason.contains(BacklogAutopilot.unreadableVerdictReason) { return .verdictUnreadable }
        // Before the verify clause it would otherwise fall into: a coverage gap
        // is not the verify failing, it is the verify never being asked — and
        // unlike a failure its remedy is mechanical, which is what
        // `Verdict.missingVerifyCommands` carries.
        if reason.contains(Self.uncoveredMarker) { return .verifyUncovered }
        if reason.contains("verify") || judgeMarkedVerifyFailed(run, policy: policy) {
            return .verifyFailed
        }
        if reason.contains(BacklogAutopilot.reviewRejectedReason) || reason.contains("max retries") {
            return .reviewRejected
        }
        return .unrecognised
    }

    /// The dead-session signature: near-zero time, and nothing to show for it.
    ///
    /// Either half of the second clause is enough. `BacklogAutopilot.isNoWorkBlock`
    /// is the app's existing test for "the worker did no billable work, so its
    /// session was almost certainly dead" and is reused rather than restated; an
    /// empty branch is the same fact seen from the worktree. A `nil`
    /// `branchHasCommits` contributes nothing — nobody looked, which is not
    /// evidence of an empty worktree.
    static func producedNothing(_ run: Run, policy: Policy = Policy()) -> Bool {
        guard run.durationSeconds < policy.sanitized.emptyRunSeconds else { return false }
        return BacklogAutopilot.isNoWorkBlock(blocked: true, costUSD: run.costUSD)
            || run.branchHasCommits == false
    }

    /// Whether the judge marked the verify dimension unmet. A run can be blocked
    /// on "review did not pass" while the dimension scores say precisely which
    /// clause failed, and "your verify failed" is far more use to the next run.
    static func judgeMarkedVerifyFailed(_ run: Run, policy: Policy = Policy()) -> Bool {
        guard let score = run.judgeDimensions?[verifyDimension] else { return false }
        return score < policy.sanitized.unmetDimensionScore
    }

    /// The judge dimension that carries the objective bar. Spelled once, here,
    /// because `RunQualityJudge` and the reviewer rubric both name it.
    /// The phrase `VerifyCoverage.Verdict.summary` writes per gap, as it reaches a
    /// run record: lowercased, because `failure(of:)` reads the reason that way.
    static let uncoveredMarker = "verify never runs"

    static let verifyDimension = "verify_passed"

    /// The judge dimensions, in the order the rubric states them — so the
    /// feedback a regroomed item carries reads the same way every time.
    static let judgeDimensions = ["verify_passed", "scope_respected",
                                  "tests_meaningful", "conventions"]

    // MARK: - Policy

    /// The three numbers the boundary turns on.
    struct Policy: Sendable, Equatable {
        /// How many times an item may **ever** be retried. Lifetime, not per
        /// pass: without that this is a machine for re-running the same doomed
        /// item nightly.
        var maxLifetimeRetries: Int
        /// Blocked runs of the same failure class that make it a pattern rather
        /// than an accident. At this count triage escalates instead of retrying.
        var repeatedFailureLimit: Int
        /// Under this many seconds is "near-zero time" — a run that ended before
        /// an agent could plausibly have done anything.
        var emptyRunSeconds: Double
        /// A judge dimension below this is read as unmet.
        var unmetDimensionScore: Double

        init(maxLifetimeRetries: Int = 2, repeatedFailureLimit: Int = 2,
             emptyRunSeconds: Double = 60, unmetDimensionScore: Double = 0.5) {
            self.maxLifetimeRetries = maxLifetimeRetries
            self.repeatedFailureLimit = repeatedFailureLimit
            self.emptyRunSeconds = emptyRunSeconds
            self.unmetDimensionScore = unmetDimensionScore
        }

        static let `default` = Policy()

        /// A hand-edited config can't turn a bound off. A negative ceiling would
        /// read as "never retry" rather than as an error, which is defensible;
        /// a `repeatedFailureLimit` below 2 would escalate every first failure
        /// and make the whole classification pointless.
        var sanitized: Policy {
            Policy(maxLifetimeRetries: max(0, maxLifetimeRetries),
                   repeatedFailureLimit: max(2, repeatedFailureLimit),
                   emptyRunSeconds: max(0, emptyRunSeconds),
                   unmetDimensionScore: min(max(0, unmetDimensionScore), 1))
        }
    }

    // MARK: - Disposition

    /// What triage decided to do about one blocked item.
    enum Disposition: Sendable, Equatable {
        /// Re-runnable unchanged: the failure was environmental. Returns the
        /// item to `ready` and nothing else — **starting** the run belongs to
        /// the scheduler.
        case retry
        /// The work itself failed. Returns the item to `ready` *with feedback*,
        /// so the next run is told what the last one ended on.
        case regroom(feedback: String)
        /// It has failed the same way twice, or spent its retries. Said, and
        /// nothing else: the item stays blocked for a human.
        case escalate

        /// The stable tag, for the ledger and the event stream.
        var name: String {
            switch self {
            case .retry: return "retry"
            case .regroom: return "regroom"
            case .escalate: return "escalate"
            }
        }

        /// Whether applying this touches the backlog at all. An escalation is a
        /// sentence, not a write.
        var writesToBacklog: Bool {
            switch self {
            case .retry, .regroom: return true
            case .escalate: return false
            }
        }
    }

    /// One item, its disposition, and **why** — so "why did this run again" has
    /// an answer that doesn't require re-deriving the classification.
    struct Verdict: Sendable, Equatable, Identifiable {
        let itemID: String
        let title: String
        let disposition: Disposition
        /// What the last run was read as. Carried alongside the reason because
        /// it is the thing worth counting across a pile.
        let failure: Failure
        /// The sentence that goes in the ledger and the event.
        let reason: String
        /// The commands the verify map named and the item's verify never ran —
        /// non-empty only for `.verifyUncovered`. Whoever applies a regroom
        /// widens the verify with these before the item goes back to ready;
        /// returning it unwidened queues the same refusal again, which is the
        /// loop that spent 36 runs on 2026-08-24.
        var missingVerifyCommands: [String] = []

        var id: String { itemID }
    }

    /// How a pile came out, for the log and the UI.
    /// `Codable` so a triaging pass survives a relaunch whole — the pass ledger
    /// (`CoordinatorQueueRefill.PassLedger`) writes the outcome it belongs to,
    /// and a tally read back as three zeroes would report a pass that recovered
    /// nothing.
    struct Tally: Sendable, Equatable, Codable {
        var retry = 0
        var regroom = 0
        var escalate = 0

        var total: Int { retry + regroom + escalate }
        var isEmpty: Bool { total == 0 }

        static func of(_ verdicts: [Verdict]) -> Tally {
            var tally = Tally()
            for verdict in verdicts {
                switch verdict.disposition {
                case .retry: tally.retry += 1
                case .regroom: tally.regroom += 1
                case .escalate: tally.escalate += 1
                }
            }
            return tally
        }

        var summary: String { "\(retry) retry, \(regroom) regroom, \(escalate) escalate" }
    }

    // MARK: - Classify

    /// Read one blocked item's record into a disposition.
    ///
    /// The order of the gates is the point:
    ///   1. **Nothing on record** — an item that has never run has no verdict to
    ///      read, and triage says so rather than guessing one.
    ///   2. **Failed the same way twice** — a pattern, whatever the class. A
    ///      third identical attempt is spending, so it escalates even when the
    ///      failure was environmental.
    ///   3. **Substantive** — the run judged the work and the work lost. It
    ///      needs feedback, not a re-run.
    ///   4. **The lifetime ceiling** — checked last because it only ever bounds
    ///      a retry, and only an environmental failure gets that far.
    static func classify(_ signals: Signals, policy: Policy = .default) -> Verdict {
        let sane = policy.sanitized

        guard let latest = signals.blockedRuns.first else {
            return Verdict(itemID: signals.itemID, title: signals.title,
                           disposition: .escalate, failure: .unrecognised,
                           reason: "no blocked run on record — nothing to classify from, "
                                 + "so this is a human's call rather than a re-run")
        }

        // Read the sanitized policy, as `producedNothing` and the dimension
        // checks already do. Reading the raw one here meant an unusable limit
        // was honoured in one half of the decision and corrected in the other.
        let policy = policy.sanitized
        let cause = failure(of: latest, policy: sane)
        let sameWay = signals.blockedRuns.filter { failure(of: $0, policy: sane) == cause }.count
        if sameWay >= sane.repeatedFailureLimit {
            return Verdict(itemID: signals.itemID, title: signals.title,
                           disposition: .escalate, failure: cause,
                           reason: "failed the same way \(sameWay) times — \(cause.phrase); "
                                 + "a third identical attempt is spending, not progress"
                                 + repeatedStatedReason(signals.blockedRuns))
        }

        guard cause.isEnvironmental else {
            // "max retries" means the run system already gave up after retrying,
            // so the item is waiting for a human, not for better feedback.
            // Checked *inside* the non-environmental branch: an empty run from a
            // dead session is still retryable however its reason is worded.
            if (latest.reason ?? "").localizedCaseInsensitiveContains("max retries") {
                return Verdict(itemID: signals.itemID, title: signals.title,
                               disposition: .escalate, failure: cause,
                               reason: "the run exhausted its own retries — "
                                     + "another pass is spending, not progress")
            }
            return Verdict(itemID: signals.itemID, title: signals.title,
                           disposition: .regroom(feedback: feedback(latest, failure: cause)),
                           failure: cause,
                           reason: "\(cause.phrase) — the run judged the work and the work "
                                 + "lost, so it needs feedback rather than a re-run",
                           missingVerifyCommands: cause == .verifyUncovered
                               ? VerifyCoverage.commands(inGap: latest.reason ?? "") : [])
        }

        guard signals.lifetimeRetries < sane.maxLifetimeRetries else {
            return Verdict(itemID: signals.itemID, title: signals.title,
                           disposition: .escalate, failure: cause,
                           reason: "\(cause.phrase), but it has been retried "
                                 + "\(signals.lifetimeRetries) time(s) already and the "
                                 + "lifetime ceiling is \(sane.maxLifetimeRetries)")
        }

        return Verdict(itemID: signals.itemID, title: signals.title,
                       disposition: .retry, failure: cause,
                       reason: "\(cause.phrase) — nothing was learned about the work, "
                             + "so it is re-runnable unchanged")
    }

    /// The sentence an escalation adds when the newest blocked runs did not
    /// merely fail in the same class but ended on the **same stated reason**,
    /// word for word — a reviewer refusing the same deviation twice, a verify
    /// naming the same command twice. Two runs that both had to deviate from
    /// the item's How the same way say the How is what cannot be done (a regex
    /// backreference in a crate that has none, on 2026-09-12), and that is
    /// the item's defect rather than either run's. Empty when the reasons
    /// differ or there is only one on record.
    static func repeatedStatedReason(_ runs: [Run]) -> String {
        let stated = runs.prefix(2).map { normalizedReason($0.reason) }
        guard stated.count == 2, !stated[0].isEmpty, stated[0] == stated[1] else { return "" }
        return ". Both runs ended on the same stated reason — \"\(stated[0])\" — which points at "
             + "the item's How rather than at either run: regroom the item before anyone retries it"
    }

    /// A reason as compared across runs: lowercased, whitespace collapsed, a
    /// trailing period dropped.
    private static func normalizedReason(_ reason: String?) -> String {
        var text = (reason ?? "").lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// What a regroomed item is told, written from the record and nothing else.
    ///
    /// It names the reason the run ended on and the judge dimensions the run
    /// marked unmet, because those are the clauses the next attempt has to
    /// answer. It does **not** say what to do about them — triage read a metric
    /// record, it did not read the code.
    static func feedback(_ run: Run, failure: Failure) -> String {
        var parts = ["The last autopilot run ended blocked: \(run.reason ?? failure.phrase)."]
        let unmet = judgeDimensions.filter { name in
            (run.judgeDimensions?[name]).map { $0 < Policy.default.unmetDimensionScore } ?? false
        }
        if !unmet.isEmpty {
            parts.append("The reviewer marked \(unmet.joined(separator: ", ")) unmet.")
        }
        parts.append("Address that before handing off again — this is triage reading the "
                     + "run record, not a review of the code.")
        return parts.joined(separator: " ")
    }

    // MARK: - Withholding a verdict the pickup gate would refuse

    /// Substitute an escalation for a disposition that would write an item back
    /// to `ready` that `DefinitionOfReady` refuses at pickup.
    ///
    /// `retry` and `regroom` both mean "this can run again", and both say it by
    /// setting the item `ready`. Neither consulted the ODD gate, so an ungroomed
    /// blocked item was returned to a queue that could not start it: autopilot
    /// skips it at pickup and `POST /v1/runs` answers 422, and the queue reads as
    /// having work nobody will ever pick up. Nothing here grooms the item —
    /// triage read a run record, and a missing What section is not something it
    /// can write. What it can do is say so, and leave the item blocked for a
    /// human, which is what an escalation already means.
    ///
    /// A ready item's verdict, and an escalation whatever the readiness, come
    /// back untouched: an escalation writes nothing, so there is nothing to
    /// withhold.
    static func withholding(_ verdict: Verdict,
                            readiness: DefinitionOfReady.Verdict) -> Verdict {
        guard !readiness.isReady, verdict.disposition.writesToBacklog else { return verdict }
        return Verdict(itemID: verdict.itemID, title: verdict.title,
                       disposition: .escalate, failure: verdict.failure,
                       reason: "triage decided \(verdict.disposition.name), but the item would "
                             + "be refused at pickup: \(readiness.summary) — returning it to "
                             + "ready would queue work nothing can start, so it stays blocked "
                             + "until a human grooms it")
    }

    // MARK: - Plan

    /// A whole project's blocked pile, triaged — or the refusal that stopped it.
    struct Plan: Sendable, Equatable {
        let project: String
        let verdicts: [Verdict]
        /// Why nothing was triaged. Nil when something was.
        let refusal: String?
        /// How many blocked items the pass **did not read**, because the caller
        /// bounded what one pass gathers. Zero is "the pile was read to the end",
        /// so a plan that says nothing about it is saying that.
        ///
        /// Load-bearing for the summary: "triaged 12 blocked" on a project with
        /// two hundred blocked items reads as a finished pile, and the caller
        /// that knows better used to keep the number to itself.
        let untriaged: Int

        /// Explicit rather than memberwise so `untriaged` can default to zero —
        /// a plan built from a whole pile, which is every caller that doesn't
        /// bound one.
        init(project: String, verdicts: [Verdict], refusal: String?, untriaged: Int = 0) {
            self.project = project
            self.verdicts = verdicts
            self.refusal = refusal
            self.untriaged = max(0, untriaged)
        }

        var tally: Tally { Tally.of(verdicts) }
        var isRefused: Bool { refusal != nil }

        /// How many blocked items there were to read, triaged or not.
        var blockedCount: Int { verdicts.count + untriaged }

        var summary: String {
            if let refusal { return "\(project): not triaged — \(refusal)" }
            guard !verdicts.isEmpty || untriaged > 0 else {
                return "\(project): nothing blocked to triage"
            }
            guard untriaged > 0 else {
                return "\(project): triaged \(verdicts.count) blocked — \(tally.summary)"
            }
            return "\(project): triaged \(verdicts.count) of \(blockedCount) blocked — "
                 + "\(tally.summary); \(untriaged) not read this pass"
        }
    }

    /// Triage a project's blocked pile.
    ///
    /// The budget is checked **first and for the whole plan**, the way it is in
    /// `QueueRefill.decide`: a ceiling that classified everything and then
    /// declined to act would have spent nothing but would also have recorded a
    /// pile of dispositions nobody may carry out. The *spend* ceiling only —
    /// `maxPasses` bounds how often the grooming loop wakes up, and triage runs
    /// inside a pass that has already been counted.
    ///
    /// `untriaged` is what the caller left out when it gathered the signals —
    /// this half owns no backlog and cannot count the pile itself. A refused
    /// plan carries none of it: nothing was gathered, so there is no remainder
    /// to report, and a zero there would claim a pile nobody read was read.
    static func plan(project: String, signals: [Signals], untriaged: Int = 0,
                     budget: QueueRefill.Budget = QueueRefill.Budget(),
                     policy: Policy = .default, now: Date = Date()) -> Plan {
        if let reason = budget.rolled(to: now).spendExhaustionReason {
            return Plan(project: project, verdicts: [], refusal: reason)
        }
        return Plan(project: project,
                    verdicts: signals.map { classify($0, policy: policy) },
                    refusal: nil, untriaged: untriaged)
    }

    // MARK: - Ledger

    /// What triage has already decided about each item — and, load-bearing, how
    /// many times each one has been retried **ever**.
    ///
    /// Append-only JSONL beside the coordinator's other logs, following
    /// `QueueRefill.Ledger`: the count has to survive a relaunch, or the ceiling
    /// would reset every time the app started and the loop would re-run the same
    /// doomed item nightly — the exact failure the ceiling exists to prevent.
    ///
    /// Every disposition is recorded, escalations included. "Why did this run
    /// again" and "why has nothing touched this in a week" are the same question
    /// asked from two sides, and both are answered here.
    struct Ledger: Sendable, Equatable {
        private(set) var entries: [Entry]

        struct Entry: Codable, Sendable, Equatable {
            let at: Date
            let project: String
            let itemID: String
            /// `retry`, `regroom` or `escalate`.
            let disposition: String
            /// Why triage decided that.
            let reason: String
            /// Whether the disposition **changed the backlog**. False for a
            /// proposal awaiting approval, and false for an escalation, which is
            /// a sentence rather than a write. A reader must be able to tell the
            /// two apart from a real one — a proposal nobody approved must not
            /// count against the retry ceiling.
            let applied: Bool
        }

        init(entries: [Entry] = []) {
            self.entries = entries
        }

        /// How many times this item has ever been **retried**. Only applied
        /// retries count: proposing one in advisory mode spends nothing and
        /// re-runs nothing.
        func retries(project key: String, itemID: String) -> Int {
            entries.filter {
                Self.matches($0.project, key) && $0.itemID == itemID
                    && $0.disposition == Disposition.retry.name && $0.applied
            }.count
        }

        /// Every disposition recorded for one item, oldest first — the answer to
        /// "what has triage already made of this?".
        func history(project key: String, itemID: String) -> [Entry] {
            entries.filter { Self.matches($0.project, key) && $0.itemID == itemID }
        }

        /// Whether a recorded line belongs to the project a reader asked about.
        ///
        /// The key a reader asks with is the canonical project path. Lines
        /// written before triage keyed by path carry the bare folder name, and
        /// the retry ceiling is a **lifetime** count: a reader that ignored them
        /// would hand every already-retried item a fresh allowance the moment
        /// this shipped, which is precisely what the ceiling exists to prevent.
        /// Nothing rewrites the file — the reader accepts both spellings.
        ///
        /// One direction only. A legacy line is claimed by an open project whose
        /// folder it names, but a line written under a path is never claimed by a
        /// bare name: that is the ambiguity keying by path removed, and reading
        /// it back in would put it straight back.
        private static func matches(_ recorded: String, _ key: String) -> Bool {
            if recorded == key { return true }
            guard let folder = key.split(separator: "/").last else { return false }
            return recorded == String(folder)
        }

        mutating func record(project: String, itemID: String, disposition: String,
                             reason: String, applied: Bool, at: Date = Date()) {
            entries.append(Entry(at: at, project: project, itemID: itemID,
                                 disposition: disposition, reason: reason, applied: applied))
        }

        // MARK: Persistence

        static func defaultURL(home: URL = KiteloopHome.url) -> URL {
            home.appending(path: ".kiteloop").appending(path: "coordinator-triage.jsonl")
        }

        /// Reads what's there. A corrupt line is skipped rather than failing the
        /// load: a half-written record must not reset every item's retry count.
        /// Split on the newline byte rather than read as one string, so a line
        /// that is not UTF-8 costs only itself.
        static func load(from url: URL) -> Ledger {
            guard let data = try? Data(contentsOf: url) else { return Ledger() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = data.split(separator: UInt8(ascii: "\n")).compactMap { line -> Entry? in
                guard String(data: line, encoding: .utf8) != nil else { return nil }
                return try? decoder.decode(Entry.self, from: line)
            }
            return Ledger(entries: entries)
        }

        static func append(_ entry: Entry, to url: URL) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entry),
                  let line = String(data: data, encoding: .utf8) else { return }

            // Through `AtomicFileWriter.append`, which makes the directory when it
            // is missing and starts a new line first when the ledger doesn't end in
            // one. A plain seek-to-end writes this entry onto the remnant of one a
            // kill cut short, and the pair decodes as neither — so the triage
            // recorded after the crash is lost, and the item it gave up on is tried
            // again as though nothing had ever been decided about it.
            try? AtomicFileWriter.append(Data((line + "\n").utf8), to: url)
        }
    }
}
