import Foundation
import KiteloopCore
import os.log

private let triageLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "blocked-triage")

/// The blocked pile's observe-and-apply half: read what each stuck item's runs
/// recorded, ask `BlockedTriage` what to make of it, and carry the dispositions
/// out.
///
/// `BlockedTriage` decides *what* and *why*; this decides nothing on its own. It
/// gathers the signals from what the app already holds — the project's backlog
/// and the `TaskMetricStore` records for its path — adds the one signal that is
/// not in either (whether the item's autopilot branch has commits on it), and
/// then carries them out within the same gates and budget the grooming pass
/// runs under.
///
/// Two properties are load-bearing and each is enforced somewhere it cannot be
/// reasoned around:
///
/// * **The retry ceiling is lifetime.** It is read from `BlockedTriage.Ledger` on
///   disk, and only *applied* retries count — so neither a new pass nor a new
///   launch resets it.
/// * **Escalation writes nothing.** It is the app saying "this has failed twice,
///   stop" — recorded, published, and the item left blocked for a human.
///
/// Starting the retried run is deliberately not here: this returns an item to
/// `ready` and stops. Whatever picks `ready` items up is what runs it.
@MainActor
@Observable
final class CoordinatorBlockedTriage {

    /// What one pass **did**, as opposed to what it decided.
    struct PassResult: Sendable, Equatable {
        let plan: BlockedTriage.Plan

        /// Items returned to `ready` this pass.
        ///
        /// Zero means nothing moved, which is deliberately not the same as an
        /// empty tally: a pile that only escalates decides plenty and recovers
        /// nothing. A caller weighing recovery against grooming needs the
        /// second question answered, not the first.
        let recovered: Int
    }

    // MARK: - Settings

    var policy = BlockedTriage.Policy.default

    /// The most blocked items one pass reads. A bound on *work*, not on the
    /// decision: each item costs a git probe, and a project that has let two
    /// hundred items pile up shouldn't stall a pass. What it leaves out is
    /// carried on the `Plan` as `untriaged`, so the plan's summary, the event
    /// this publishes and `lastPlan` all say how much of the pile went unread —
    /// never dropped silently.
    var maxItemsPerPass = 12

    // MARK: - State

    private(set) var ledger: BlockedTriage.Ledger
    private(set) var lastPlan: BlockedTriage.Plan?

    /// The id each project's blocked pile stopped **after**, last pass. Where
    /// the next pass's window starts, so a pile larger than `maxItemsPerPass`
    /// is read whole over enough passes instead of the same head forever.
    ///
    /// In memory only, keyed by `projectKey` beside the ledger: a relaunch may
    /// legitimately restart the pile at the head, the same way the ledger's
    /// retry count is the only thing here that has to survive one.
    private var cursors: [String: String] = [:]

    private let ledgerURL: URL
    private weak var registry: ControlSessionRegistry?
    private weak var metrics: TaskMetricStore?

    init(ledgerURL: URL = BlockedTriage.Ledger.defaultURL()) {
        self.ledgerURL = ledgerURL
        self.ledger = BlockedTriage.Ledger.load(from: ledgerURL)
    }

    /// Whether anything is wired. Unwired, a pass triages nothing and says so
    /// rather than reporting an empty pile — "there is nothing blocked" and "I
    /// can't see the backlog" are different answers.
    var isConfigured: Bool { registry != nil }

    /// Wire the portfolio it reads from. `metrics` is what turns a blocked item
    /// into a classifiable one: without it every item reports no recorded run
    /// and escalates, which is honest but useless, so an unwired store is worth
    /// noticing.
    func configure(registry: ControlSessionRegistry, metrics: TaskMetricStore?) {
        self.registry = registry
        self.metrics = metrics
    }

    // MARK: - The pass

    /// Triage one project's blocked pile.
    ///
    /// The budget is checked inside `BlockedTriage.plan`, before a single item is
    /// classified — what triage buys is future runs, and those cost money.
    @discardableResult
    func triage(project key: String,
                budget: QueueRefill.Budget, now: Date = Date()) async -> PassResult {
        guard let registry, let entry = registry.entry(forProject: key) else {
            let plan = BlockedTriage.Plan(project: key, verdicts: [],
                                          refusal: "\(key) isn't open — nothing to read")
            lastPlan = plan
            return PassResult(plan: plan, recovered: 0)
        }
        // The plan is read by people, so it is the folder that goes on it. What
        // a later pass has to *match* — the ledger — is keyed by `projectKey`
        // instead, and never by this.
        let name = entry.projectName

        // The budget refusal comes before the git probes as well as before the
        // classification: a refused pass should cost nothing at all.
        if let reason = budget.rolled(to: now).spendExhaustionReason {
            return finish(BlockedTriage.Plan(project: name, verdicts: [], refusal: reason),
                          recovered: 0, entry: entry)
        }

        let pile = await signals(forProject: entry, name: name)
        let plan = BlockedTriage.plan(project: name, signals: pile.signals,
                                      untriaged: pile.untriaged,
                                      budget: budget, policy: policy, now: now)
        var recovered = 0
        for verdict in plan.verdicts where carry(verdict, entry: entry, now: now) {
            recovered += 1
        }
        return finish(plan, recovered: recovered, entry: entry)
    }

    private func finish(_ plan: BlockedTriage.Plan, recovered: Int,
                        entry: ControlSessionRegistry.Entry) -> PassResult {
        lastPlan = plan
        triageLog.info("Blocked triage: \(plan.summary)")
        var payload: [String: String] = [
            "kind": "blocked-triage",
            "project": plan.project,
            "detail": plan.summary,
            "retry": String(plan.tally.retry),
            "regroom": String(plan.tally.regroom),
            "escalate": String(plan.tally.escalate)
        ]
        if let refusal = plan.refusal { payload["refusal"] = refusal }
        // Only when there is a remainder, the way `refusal` is only there when
        // there was one. A refused pass gathered nothing, so a `0` here would
        // read as "the pile was read to the end" — which is the misreading this
        // key exists to stop, told the other way round.
        if plan.untriaged > 0 { payload["untriaged"] = String(plan.untriaged) }
        entry.session.orchestrator.publishEvent(
            KiteloopEvent(source: "Coordinator", type: .custom, payload: payload))
        return PassResult(plan: plan, recovered: recovered)
    }

    // MARK: - Signals

    /// What the app already holds about each blocked item, in the shape a
    /// decision can be made from.
    ///
    /// Reads only: the project's loaded backlog, the metric records for its path,
    /// and a couple of read-only git commands per item. Nothing here builds or
    /// tests a branch — asking what a run left behind is not re-running it.
    ///
    /// Returns what it gathered **and** how much of the pile it left behind: this
    /// is the only place that sees both numbers, and the count is what the plan
    /// needs to report a partial pass as one.
    private func signals(forProject entry: ControlSessionRegistry.Entry,
                         name: String) async -> (signals: [BlockedTriage.Signals],
                                                 untriaged: Int) {
        let blocked = (entry.session.backlogViewModel.backlogFile?.sections ?? [])
            .flatMap(\.items).filter { $0.status == .blocked }
        let shown = Self.window(over: blocked, maxItemsPerPass: max(0, maxItemsPerPass),
                                after: cursors[entry.projectKey])
        let untriaged = blocked.count - shown.count
        if let last = shown.last { cursors[entry.projectKey] = last.id }
        if untriaged > 0 {
            let note = "\(name) has \(blocked.count) blocked; triaging \(shown.count) this "
                + "pass, \(untriaged) left for the next"
            triageLog.info("Blocked triage: \(note)")
        }

        let root = entry.session.project.rootURL
        let records = ProjectInspection.records(metrics: metrics,
                                                projectPath: root.path(percentEncoded: false))

        var out: [BlockedTriage.Signals] = []
        for item in shown {
            // Newest first — `ProjectInspection.records` already sorts that way.
            var runs = records.filter { $0.itemID == item.id }.map(Self.run)
            // Only the newest run gets the branch signal: a branch says what is
            // on it now, not what was on it three runs ago.
            if !runs.isEmpty {
                runs[0].branchHasCommits = await Self.branchHasCommits(root: root, itemID: item.id)
            }
            out.append(BlockedTriage.Signals(
                itemID: item.id, title: item.title, runs: runs,
                lifetimeRetries: ledger.retries(project: entry.projectKey, itemID: item.id)))
        }
        return (out, untriaged)
    }

    /// The next window over a blocked pile, in backlog order, wrapping around
    /// the end so a pile bigger than `maxItemsPerPass` is read whole over
    /// enough passes rather than the same head forever.
    ///
    /// `after` is the id the previous pass over this project stopped on. A nil
    /// (never triaged before) and an id no longer among `blocked` (recovered,
    /// or edited out of the backlog) are the same case: both start the window
    /// at the head, because there is nothing to resume *from*.
    ///
    /// A pile that already fits inside `maxItemsPerPass` is returned whole
    /// regardless of `after` — reading it in full is what "at or under the
    /// bound" already meant, and finding a resume point for it would only
    /// reorder a full read into a differently-full read.
    nonisolated static func window(over blocked: [BacklogItem], maxItemsPerPass: Int,
                                   after: String?) -> [BacklogItem] {
        guard blocked.count > maxItemsPerPass else { return blocked }
        let start: Int
        if let after, let resumeAt = blocked.firstIndex(where: { $0.id == after }) {
            start = (resumeAt + 1) % blocked.count
        } else {
            start = 0
        }
        return (0..<maxItemsPerPass).map { blocked[(start + $0) % blocked.count] }
    }

    /// One metric record as triage reads it.
    nonisolated static func run(_ record: TaskMetricRecord) -> BlockedTriage.Run {
        let split = PortfolioSnapshot.splitOutcome(record.outcome)
        return BlockedTriage.Run(outcome: split.outcome, reason: split.reason,
                                 durationSeconds: record.durationSeconds,
                                 costUSD: record.costUSD,
                                 qualityScore: record.qualityScore,
                                 judgeDimensions: record.judgeDimensions,
                                 completedAt: record.completedAt)
    }

    /// Whether the item's autopilot branch carries commits that aren't already
    /// in the checked-out history — the "empty worktree" half of the
    /// dead-session signature.
    ///
    /// Nil for "nobody could tell": no such branch, no git, unreadable output.
    /// That is deliberately different from `false`, because only `false` is
    /// evidence, and evidence is what a retry needs.
    ///
    /// The git reads live in `RunWorkEvidence`, shared with the check the
    /// autopilot makes before offering an item for approval — one answer to
    /// "did this run produce anything", so the two can't drift apart. A branch
    /// carrying only empty commits reads as `false` here too: it is the same
    /// empty worktree, one commit later.
    static func branchHasCommits(root: URL, itemID: String) async -> Bool? {
        let verdict = await RunWorkEvidence.inspect(
            projectRoot: root,
            branch: WorktreeSession.branchName(for: itemID),
            isolated: true
        )
        switch verdict {
        case .produced: return true
        // `noChanges` can't come back from `inspect` — it's what the blocked-run
        // read returns — but it says the same thing, so it answers the same way.
        case .noCommits, .emptyDiff, .noChanges: return false
        // A blocked item's worktree is *kept*, branch and all, so a branch that
        // isn't there was never created — nobody isolated the run, which says
        // nothing about whether it produced work. `orphanedCommits` is the same
        // missing branch with the run's commits still in the object store: it
        // is not evidence of an empty run, and it is not a branch anything can
        // count commits on either.
        case .noBranch, .orphanedCommits, .unknown: return nil
        }
    }

    // MARK: - Carrying a verdict out

    /// An escalation writes nothing — it is the app saying "this has failed
    /// twice, stop", recorded and published for a human — while a retry or a
    /// regroom is carried out on the spot.
    /// Returns whether this pass **moved** anything — a backlog write.
    @discardableResult
    private func carry(_ verdict: BlockedTriage.Verdict,
                       entry: ControlSessionRegistry.Entry,
                       now: Date) -> Bool {
        guard verdict.disposition.writesToBacklog else {
            record(verdict, project: entry.projectKey, applied: false, now: now)
            publish(verdict, entry: entry, applied: false)
            return false
        }
        return apply(verdict, entry: entry, now: now).disposition.writesToBacklog
    }

    /// The one write path, so every carried-out disposition is the same change,
    /// recorded the same way.
    ///
    /// A disposition that would return the item to `ready` is checked against the
    /// pickup gate first — see `BlockedTriage.withholding`. It happens here rather
    /// than in `classify` because readiness is read off the backlog, and the
    /// decision half owns no backlog; and it happens before the `switch` so the
    /// substituted verdict is the one the write, the ledger and the event all see.
    /// Returns the verdict that was actually carried out, which is what the caller
    /// has to report — not the one it asked for.
    @discardableResult
    private func apply(_ verdict: BlockedTriage.Verdict,
                       entry: ControlSessionRegistry.Entry,
                       now: Date) -> BlockedTriage.Verdict {
        let backlog = entry.session.backlogViewModel
        let verdict = BlockedTriage.withholding(
            verdict, readiness: readiness(ofItem: verdict.itemID, in: backlog))
        switch verdict.disposition {
        case .retry:
            // Unchanged, on purpose: the failure said nothing about the work, so
            // there is nothing to tell the next run that it doesn't already have.
            backlog.updateItemStatus(itemID: verdict.itemID, newStatus: .ready)
        case .regroom(let feedback):
            // `reject` is the app's existing "back to ready, with feedback the
            // next worker run reads" — the same path the human gate uses.
            // A coverage gap is widened first: sent back unwidened, the same
            // gate refuses the same diff and the item circles until escalated.
            let widened = widenVerify(verdict, entry: entry)
            backlog.reject(itemID: verdict.itemID, reason: feedback + (widened ?? ""))
        case .escalate:
            break   // said, not done — the item stays blocked
        }
        // A verdict withheld above changed nothing, so it is recorded as the
        // sentence it became rather than as a write. Claiming otherwise would
        // both misstate the ledger's `applied` and defeat its dedup, appending a
        // fresh copy of the same withheld escalation on every pass forever.
        let wrote = verdict.disposition.writesToBacklog
        record(verdict, project: entry.projectKey, applied: wrote, now: now)
        publish(verdict, entry: entry, applied: wrote)
        return verdict
    }

    /// What the pickup gate makes of the item a verdict is about.
    ///
    /// An item the view model can't find reads as **ready**: a lookup that missed
    /// is not a readiness verdict, and withholding on one would turn "the backlog
    /// moved under us" into a permanent escalation nobody can groom their way out
    /// of. The disposition is left to do whatever it would have done.
    /// Adds the commands a `.verifyUncovered` verdict names to the item's
    /// verify — the line, and the detail's frontmatter list when it has one —
    /// and says what was added, for the note. Nil when there was nothing to
    /// add: not a gap verdict, or a verify that already ran them.
    private func widenVerify(_ verdict: BlockedTriage.Verdict,
                             entry: ControlSessionRegistry.Entry) -> String? {
        guard !verdict.missingVerifyCommands.isEmpty else { return nil }
        let map = VerifyMapFile.load(for: entry.session.project)
        let added = entry.session.backlogViewModel.widenVerify(
            itemID: verdict.itemID, adding: verdict.missingVerifyCommands, map: map)
        guard let added else { return nil }
        triageLog.info("Blocked triage: widened verify of \(verdict.itemID) with \(added)")
        return " The verify: now also runs `\(added)` — the verify map demands it "
             + "for the files the diff touched, and the last line never did."
    }

    private func readiness(ofItem id: String,
                           in backlog: BacklogViewModel) -> DefinitionOfReady.Verdict {
        guard let item = backlog.item(withID: id) else { return .ready }
        return Self.readiness(of: item, detail: backlog.loadDetail(for: item),
                              in: backlog.backlogFile)
    }

    /// The gate's verdict on one item, asked with the same three arguments
    /// `BacklogAutopilot` passes at pickup — the item, its detail file, and the
    /// backlog its `needs:` resolve against.
    ///
    /// The backlog is the half that used to be missing. `DefinitionOfReady`
    /// leaves the sequencing clause *silent* when no dependencies are supplied
    /// rather than treating it as satisfied, so an item waiting on something that
    /// isn't `done` read as ready here while the pickup gate withheld it: triage
    /// returned it to `ready`, every pass skipped it, and triage — which reads
    /// only `blocked` items — never looked at it again. Resolved across the whole
    /// file, since a `needs:` routinely names an item in another epic.
    ///
    /// A nil file leaves the clause silent, as it does everywhere else: nothing
    /// to resolve against is not evidence a dependency is unmet.
    ///
    /// Static, and taking what it judges rather than the view model that holds
    /// it, so the readiness question can be asserted on its own.
    nonisolated static func readiness(of item: BacklogItem, detail: BacklogItemDetail?,
                                      in file: BacklogFile?) -> DefinitionOfReady.Verdict {
        DefinitionOfReady.evaluate(
            item: item, detail: detail,
            dependencies: file.map(DefinitionOfReady.Dependencies.init(file:)))
    }

    // MARK: - Recording

    /// Both halves of remembering: the in-memory ledger this pass reads its retry
    /// counts from, and the JSONL that survives a relaunch.
    ///
    /// An unapplied disposition identical to this item's last recorded one is
    /// **not** written again. Without that, a pile of escalations would append
    /// twelve lines every fifteen minutes forever and the ledger would stop being
    /// readable — which is the only thing it is for. Anything actually applied is
    /// always recorded: it changed the backlog.
    ///
    /// `key` is the canonical project path and nothing else: this is the file the
    /// lifetime ceiling is read back from, so two same-named projects writing
    /// under one string would share a ceiling neither of them spent.
    private func record(_ verdict: BlockedTriage.Verdict, project key: String,
                        applied: Bool, now: Date) {
        let name = verdict.disposition.name
        guard applied || ledger.history(project: key, itemID: verdict.itemID)
                .last?.disposition != name else { return }
        ledger.record(project: key, itemID: verdict.itemID, disposition: name,
                      reason: verdict.reason, applied: applied, at: now)
        BlockedTriage.Ledger.append(
            BlockedTriage.Ledger.Entry(at: now, project: key, itemID: verdict.itemID,
                                       disposition: name, reason: verdict.reason,
                                       applied: applied),
            to: ledgerURL)
    }

    /// The event names the **folder**, as the pass event does: this is the stream
    /// a person reads, and a canonical path there would be noise nobody asked for.
    private func publish(_ verdict: BlockedTriage.Verdict,
                         entry: ControlSessionRegistry.Entry, applied: Bool) {
        entry.session.orchestrator.publishEvent(KiteloopEvent(
            source: "Coordinator", type: .custom, payload: [
                "kind": applied ? "triage-applied" : "triage-proposed",
                "project": entry.projectName,
                "item": verdict.itemID,
                "disposition": verdict.disposition.name,
                "failure": verdict.failure.rawValue,
                "reason": verdict.reason
            ]))
    }
}

/// The two spellings of a project triage deals in, so which one a call site wants
/// is decided here once rather than at each of them.
///
/// The rule: **anything a later pass has to match on is keyed by `projectKey`**
/// — the ledger the lifetime ceiling is read from. `projectName` goes only
/// where a person reads it: the plan's summary and the event payloads.
///
/// They differ exactly when two open projects' folders share a name —
/// `~/work/kiteloop` and `~/oss/kiteloop` are one string under the name and two
/// under the path — which is the whole reason for the split.
extension ControlSessionRegistry.Entry {
    /// The canonical project path. The same string the registry files this entry
    /// under and `PersistedRunRecord.projectID` already chose for this reason.
    var projectKey: String { session.project.id }

    /// The folder, as a human names the project.
    var projectName: String { session.project.rootURL.lastPathComponent }
}
