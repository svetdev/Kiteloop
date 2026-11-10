import AppKit
import Foundation
import KiteloopCore

/// Everything known about one backlog item, joined in one place, plus the
/// actions its current state permits.
///
/// The data was all already recorded and none of it was joined: runs in
/// `task-metrics.jsonl`, state changes in the item's `## Notes`, gate decisions
/// in `task-approvals.jsonl`, retirements and releases in `grooming.jsonl`,
/// transcripts in `.kiteloop/transcripts/`, and the only *fact* — whether the
/// work exists — in git. Answering one question about one item meant reading
/// four files and matching timestamps.
///
/// **It reads; it does not recompute.** Runs and approvals come from
/// `MetricIndex`, which already projects those ledgers into SQLite. Building a
/// second opinion out of the raw JSONL here is how two answers to the same
/// question appear, which is the defect this view exists to end.
@Observable
@MainActor
final class BacklogItemDetailViewModel: Identifiable {

    /// The item this model is about. Immutable, so it doubles as the identity
    /// the page is presented on — opening a second item replaces the page rather
    /// than reusing the first one's contents.
    let id: String

    /// What has been read so far. `loading` is the state on open, and the view
    /// renders it rather than an empty frame that looks like an item with no
    /// history.
    private(set) var isLoading = true
    private(set) var runs: [TaskMetricRecord] = []
    /// The item's runs as the page lists them — the measured ledger joined with
    /// the control server's records, which are the only place a blocked run's
    /// reason is written down. See `ItemRunHistory`.
    private(set) var runRows: [ItemRunHistory.Row] = []
    /// Verifying, waiting on a person, or refused — while the item is at the
    /// gate; nil otherwise. Read live off the backlog, so the pill moves the
    /// moment a gate starts or answers.
    var gateState: GateState? { backlog.gateState(for: item) }
    /// Attempts, spend and time, computed from `runRows` and nothing else.
    private(set) var runsSummary = ItemRunHistory.Summary(
        attempts: 0, totalCostUSD: 0, totalDurationSeconds: 0,
        unmeasuredRuns: 0, runsMissingCost: 0, runsMissingDuration: 0)
    private(set) var changes: [ItemStateChange] = []
    private(set) var git: ItemGitTruth
    private(set) var disagreements: [ItemDisagreement] = []
    private(set) var actions: [ItemAction] = []
    /// The Definition-of-Ready gate's answer for this item, and the same answer
    /// clause by clause. Both come from the one evaluation `refreshActions`
    /// makes, so what the readiness section shows and what Run's tooltip says
    /// cannot disagree.
    private(set) var readiness: DefinitionOfReady.Verdict = .ready
    private(set) var readinessRows: [ItemReadinessRow] = []
    private(set) var detail: BacklogItemDetail?
    /// The item as the backlog file has it right now — re-read on every refresh,
    /// because an action taken from here changes it.
    private(set) var item: BacklogItem
    /// What the last action did, kept on screen. A failed merge leaves the item
    /// at the gate, and that must not pass unnoticed.
    private(set) var actionNote: String?
    /// Why the last verify edit was refused, for the page's verify field to
    /// show under itself; nil once one is saved.
    private(set) var verifyRefusal: String?
    /// Why the last needs edit was refused, for the page's needs field to show
    /// under itself; nil once one is saved.
    private(set) var needsRefusal: String?
    /// True while an action that can take minutes (a merge and its verify) runs.
    private(set) var isActing = false
    /// One agent pass over this item's draft, and where it stands. A plain
    /// stored property rather than a shared editor's field: this model is
    /// itself already one per item — opening a different item replaces the
    /// page rather than reusing this one's contents — so a proposal here can
    /// never be applied onto any item but the one this page is about.
    private(set) var groomPhase: GroomPhase = .idle

    enum GroomPhase: Equatable {
        case idle
        case thinking
        case review(BacklogGroomer.Proposal)
        case error(String)
    }

    private let itemID: String
    /// The project's root, which a dependency's link opens its item in.
    let projectPath: String
    private let projectName: String
    private let backlog: BacklogViewModel
    private let autopilot: BacklogAutopilot
    private let metricIndex: MetricIndex
    private let metricStore: TaskMetricStore
    private let groomingLedger: GroomingLedger
    /// The control server's durable run records. Read, never written: this is
    /// where a blocked run's reason and the branch it left behind live.
    private let runRecords: RunRecordStore
    /// Whether the retry ceiling is refusing to start the item. Judged by the
    /// caller, which has already made the same (two-pass, ledger-walking) call
    /// for the whole list — asking again per item would re-scan the ledger for
    /// an answer the list already has.
    private let isRetired: Bool
    /// Where a groom pass runs its one agent turn. Nil on a surface that never
    /// shows a draft (the Autopilot queue), where the action is offered and
    /// says why it can't be taken from there.
    private let aiEditor: BacklogAIEditor?

    init(item: BacklogItem,
         projectPath: String,
         projectName: String,
         isRetired: Bool,
         backlog: BacklogViewModel,
         autopilot: BacklogAutopilot,
         metricIndex: MetricIndex,
         metricStore: TaskMetricStore,
         groomingLedger: GroomingLedger = .shared,
         runRecords: RunRecordStore = .shared,
         aiEditor: BacklogAIEditor? = nil) {
        self.id = item.id
        self.item = item
        self.itemID = item.id
        self.projectPath = projectPath
        self.projectName = projectName
        self.isRetired = isRetired
        self.backlog = backlog
        self.autopilot = autopilot
        self.metricIndex = metricIndex
        self.metricStore = metricStore
        self.groomingLedger = groomingLedger
        self.runRecords = runRecords
        self.aiEditor = aiEditor
        self.git = .unreadable(branch: WorktreeSession.branchName(for: item.id))
    }

    /// Builds the model from an item *id*, for the surfaces that name an item
    /// without holding its backlog line — the Autopilot queue and the run
    /// history, where a row is a record rather than a parsed item.
    ///
    /// Nil when the backlog no longer has the item: a page about an item that
    /// has been removed could show its runs and nothing else it promises, and
    /// the caller disables the row instead of opening a half-page.
    static func make(itemID: String,
                     backlog: BacklogViewModel,
                     autopilot: BacklogAutopilot,
                     metricIndex: MetricIndex,
                     metricStore: TaskMetricStore,
                     groomingLedger: GroomingLedger = .shared,
                     runRecords: RunRecordStore = .shared,
                     aiEditor: BacklogAIEditor? = nil) -> BacklogItemDetailViewModel? {
        guard let item = backlog.item(withID: itemID),
              let root = autopilot.projectRoot else { return nil }
        let projectPath = root.path(percentEncoded: false)
        // Judged for this item alone — the backlog list judges its whole file in
        // two passes because it needs every row's answer; here there is one row.
        let verdict = RetryCeiling.evaluate(
            itemID: itemID, projectPath: projectPath, records: metricStore.records,
            releasedAt: groomingLedger.latestRelease(itemID: itemID, projectPath: projectPath),
            specFingerprint: RetryCeiling.specFingerprint(item: item,
                                                          detail: backlog.loadDetail(for: item)))
        return BacklogItemDetailViewModel(
            item: item,
            projectPath: projectPath,
            projectName: root.lastPathComponent,
            isRetired: verdict.isRetired,
            backlog: backlog,
            autopilot: autopilot,
            metricIndex: metricIndex,
            metricStore: metricStore,
            groomingLedger: groomingLedger,
            runRecords: runRecords,
            aiEditor: aiEditor)
    }

    /// The project, for the paths the view links to.
    var project: KiteloopProject { KiteloopProject(rootURL: URL(fileURLWithPath: projectPath)) }

    /// One id the item's `needs:` names, with that item's status as the backlog
    /// has it now — nil when the backlog has no such item, which is why the
    /// readiness gate counts it as unmet.
    struct Dependency: Equatable {
        let id: String
        let status: BacklogItemStatus?
    }

    /// The item's `needs:`, in order, each resolved against the backlog. Read
    /// live, so the page's `load()` loop moves a status the moment it lands.
    var dependencies: [Dependency] {
        item.needs.map { Dependency(id: $0, status: backlog.item(withID: $0)?.status) }
    }

    /// The item this one was split from — its `from:`, resolved against the
    /// backlog. Nil when the line names no parent; a parent the backlog no
    /// longer has keeps its id with no status.
    var origin: Dependency? {
        item.from.map { Dependency(id: $0, status: backlog.item(withID: $0)?.status) }
    }

    /// Every item whose `from:` names this one, in backlog file order. Read
    /// live, like `dependencies`.
    var children: [Dependency] {
        (backlog.backlogFile?.sections.flatMap(\.items) ?? [])
            .filter { $0.from == item.id }
            .map { Dependency(id: $0.id, status: $0.status) }
    }

    /// The detail file, when the item has one — what "Re-groom" opens.
    var detailURL: URL? { backlog.detailURL(for: item) }

    /// Whether the readiness checklist belongs on screen for the item's stage.
    var showsReadiness: Bool { ItemReadinessChecklist.isShown(for: item.status) }

    /// Where a run's transcript lives. A pointer, not an inlining: a run's
    /// transcript is large, and the pointer is what makes it findable at all.
    func transcriptURL(for run: ItemRunHistory.Row) -> URL? {
        guard let executionID = run.executionID, !executionID.isEmpty else { return nil }
        return project.runTranscriptsURL.appending(path: executionID)
    }

    /// The branch a run left behind, as the history rows present it — the chip
    /// and its menu, resolved against this project's worktrees. Nil where the
    /// run recorded no branch, so a chip always names a ref that existed.
    func branchLink(for run: ItemRunHistory.Row) -> BacklogAutopilot.BranchLink? {
        BacklogAutopilot.branchLink(branch: run.branch,
                                    projectRoot: autopilot.projectRoot
                                        ?? URL(fileURLWithPath: projectPath))
    }

    // MARK: - Loading

    /// Re-reads every source. Cheap enough to call after each action: the index
    /// catch-up reads only what the logs gained, and the git questions are three
    /// `rev-list`-class commands.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        if let fresh = backlog.item(withID: itemID) { item = fresh }
        detail = backlog.loadDetail(for: item)

        let projectID = KiteloopProject.canonicalPath(projectPath)
        // A query that throws leaves the section empty rather than the whole
        // view: an unreadable index must not cost the git reading beside it.
        let indexedRuns = (try? await metricIndex.runs(projectID: projectID, itemID: itemID)) ?? []
        let indexedApprovals = (try? await metricIndex.approvals(projectID: projectID, itemID: itemID)) ?? []
        let grooming = groomingLedger.records.filter {
            $0.itemID == itemID
                && KiteloopProject.canonicalPath($0.projectPath) == projectID
        }

        runs = indexedRuns
        // The same runs as the control server wrote them down — the half that
        // carries the reason a blocked run ended, and the runs no measurement
        // survives at all.
        let controlRuns = runRecords.records.filter {
            $0.itemID == itemID && KiteloopProject.canonicalPath($0.projectID) == projectID
        }
        // A run still going has no ending yet, and says so — rather than
        // reading as one nobody recorded.
        let inFlightItem = await autopilot.inFlightRun()?.itemID
        let inFlight = inFlightItem == itemID || backlog.gateActivity[itemID] != nil
        runRows = ItemRunHistory.rows(metrics: indexedRuns, controlRuns: controlRuns, inFlight: inFlight)
        runsSummary = ItemRunHistory.summary(of: runRows)
        changes = ItemTimeline.changes(notes: detail?.notes,
                                       approvals: indexedApprovals,
                                       grooming: grooming)
        git = await ItemGitTruth.read(projectRoot: autopilot.projectRoot
                                        ?? URL(fileURLWithPath: projectPath),
                                      itemID: itemID)
        disagreements = ItemDisagreements.detect(status: item.status,
                                                 latestRun: runs.first,
                                                 git: git)
        await refreshActions()
    }

    /// Rebuilds what the item's state permits. Split out so an action can put
    /// the buttons right without re-reading git and the ledgers.
    func refreshActions() async {
        let inFlight = await autopilot.inFlightRun()?.itemID
        // The ODD gate, asked here with the same three arguments
        // `BacklogAutopilot` passes at pickup — the item, its detail file and
        // the whole backlog its `needs:` resolve against — so Run is offered
        // only for an item the gate would actually accept. The detail is re-read
        // rather than taken from `detail`, which an action-only refresh has not
        // necessarily loaded.
        let groomed = backlog.loadDetail(for: item)
        let dependencies = backlog.backlogFile.map { DefinitionOfReady.Dependencies(file: $0) }
        let readiness = DefinitionOfReady.evaluate(item: item, detail: groomed,
                                                   dependencies: dependencies)
        self.readiness = readiness
        // The same verdict, laid out for the person grooming the item. Mapped
        // rather than re-derived: a second reading of the gate is how the
        // checklist and the button that quotes it come apart.
        readinessRows = ItemReadinessChecklist.rows(item: item, detail: groomed,
                                                    verdict: readiness,
                                                    judgedDependencies: dependencies != nil)
        actions = ItemActions.offered(ItemActions.Context(
            itemID: itemID,
            status: item.status,
            pickupStages: backlog.workflow.autopilotPickupStages,
            isRetired: isRetired,
            hasWorkerAndReviewer: autopilot.workerAgentID != nil && autopilot.reviewerAgentID != nil,
            readiness: readiness,
            inFlightItemID: inFlight,
            hasDetailFile: item.detailPath != nil,
            hasProjectRoot: autopilot.projectRoot != nil,
            hasGroomRunner: aiEditor != nil))
    }

    func action(_ kind: ItemAction.Kind) -> ItemAction? {
        actions.first { $0.kind == kind }
    }

    // MARK: - Acting

    /// Runs this item alone. Deliberately replaces the panel's selection rather
    /// than adding to it: the person clicking Run here asked for *this* item,
    /// and inheriting a selection made somewhere else would start work they
    /// never saw.
    func run() async {
        guard action(.run)?.isAvailable == true else { return }
        autopilot.selectedItemIDs = [itemID]
        actionNote = "Started a run for \(itemID)"
        Task { await autopilot.start() }
        // Let the run take hold before the buttons are re-read; the start is
        // asynchronous and asking immediately reports the state before it.
        await refreshActions()
    }

    /// Stops the project's queue. Named as what it does — `cancel` stops the
    /// whole queue, not only the item in flight — so nobody reads it as "skip
    /// this one".
    func cancel() async {
        guard action(.cancel)?.isAvailable == true else { return }
        autopilot.stop()
        actionNote = "Stopped the run — the project's remaining queue is released too"
        await refreshActions()
    }

    /// Resolves the human gate, through the same path the Autopilot panel and
    /// the control API use, so approving from here merges exactly as approving
    /// from there does.
    func resolveGate(approve: Bool, reason: String = "") async {
        guard action(approve ? .approve : .reject)?.isAvailable == true,
              let root = autopilot.projectRoot else { return }
        isActing = true
        defer { isActing = false }
        let plan = MergeVerifyPlan.resolve(projectCommand: autopilot.autoMergeVerifyCommand,
                                           itemVerify: item.verify)
        let outcome = await backlog.resolveGate(
            itemID: itemID,
            approve: approve,
            reason: approve ? "" : (reason.isEmpty ? "Rejected from the item detail view" : reason),
            autoMerge: autopilot.autoMergeOnApproval,
            verify: plan,
            projectRoot: root,
            isolationExpected: autopilot.useWorktree, base: autopilot.baseBranch,
            setupCommand: autopilot.worktreeSetupCommand, timeout: TimeInterval(autopilot.autoMergeVerifyTimeoutMinutes) * 60)
        switch outcome {
        case .approvedAndMerged:
            actionNote = "Merged and marked done — verified by \(plan.summary)"
        case .approvedWithoutMerge(let why):
            actionNote = "Done — \(why)"
        case .mergeFailed(let why, _), .workNotOnBranch(let why):
            actionNote = "Not approved — \(why)"
        case .rejected:
            actionNote = "Returned to Ready with feedback"
        }
        await load()
    }

    /// Lifts the block to Draft, keeping the reason in the Notes — the same
    /// call `POST /v1/backlog/groom` makes for a blocked item. Draft rather
    /// than Ready because a block usually means something about the item has
    /// to change, and Run on this page says what still stands in the way.
    func unblock() async {
        guard action(.unblock)?.isAvailable == true else { return }
        let lifted = backlog.unblock(itemID: itemID, to: .draft)
        actionNote = lifted
            ? "Unblocked — back to Draft; the reason it was blocked for is in the Notes"
            : "Not unblocked — the item is no longer blocked"
        await load()
    }

    /// Lets a retired item be picked up again as it stands, through the same
    /// call the backlog list and `POST /v1/backlog/release` make — so the
    /// release is written to both the ledger and the item's Notes, and shows up
    /// in the timeline above.
    func release() async {
        guard action(.release)?.isAvailable == true else { return }
        let outcome = RetryCeilingRelease.apply(
            itemID: itemID, projectPath: projectPath, projectName: projectName,
            source: "item detail", ledger: groomingLedger, backlog: backlog,
            records: metricStore.records)
        actionNote = outcome.wasRetired
            ? "Released — \(outcome.noWorkAttemptsBefore) no-work attempts no longer count"
            : "Released — the item was not retired, so nothing was discounted"
        await load()
    }

    /// Opens the detail file so it can be re-groomed where it lives. This view
    /// reads the groomed content and never edits it; re-grooming is an edit, so
    /// it happens in the editor the file is already opened with.
    func regroom() {
        guard action(.regroom)?.isAvailable == true, let detailURL else { return }
        NSWorkspace.shared.open(detailURL)
    }

    /// Runs one agent pass proposing a grooming for this draft — a `verify:`,
    /// a size, and What/How/Validation/Out of Scope — and checks it against
    /// the repo. Nothing is written; `applyGroom()` is the human's separate
    /// approval of what comes back.
    func groom() async {
        guard action(.groom)?.isAvailable == true, let aiEditor,
              let root = autopilot.projectRoot, let backlogFile = backlog.backlogFile else { return }
        groomPhase = .thinking
        let (vaultURL, base) = (backlog.vaultURL, autopilot.baseBranch)
        let grant = RepoRead.Grant(projectName: projectName, projectPath: projectPath)
        do {
            // Walks the tree, so it happens off this actor rather than
            // blocking it for however long a large repo takes to index.
            let sources = await Task.detached {
                GroundingCheck.Sources.repository(root: root, vault: vaultURL, baseBranch: base)
            }.value
            let proposal = try await BacklogGroomer.propose(
                item: item, detail: detail, backlog: backlogFile, sources: sources,
                runOneShot: { prompt in
                    try await aiEditor.runOneShot(
                        prompt: prompt, cwd: root,
                        systemPrompt: BacklogGroomer.personaPrompt + "\n\n" + RepoRead.contract(for: grant),
                        agentName: "Backlog Groomer", access: grant)
                })
            groomPhase = .review(proposal)
        } catch {
            groomPhase = .error(error.localizedDescription)
        }
    }

    /// Writes the previewed grooming through `BacklogViewModel.writeGrooming`:
    /// the detail file, and the line's own `verify:` and size — never the
    /// title or the status, since promotion past Draft is `promote()`'s own
    /// separate, gated step. A write that doesn't land says so rather than
    /// claiming the item groomed, and leaves the proposal open.
    func applyGroom() {
        guard case .review(let proposal) = groomPhase else { return }
        if let refusal = backlog.writeGrooming(proposal) {
            actionNote = "\(itemID) was not groomed — \(refusal)"
            return
        }
        groomPhase = .idle
        actionNote = proposal.readiness.isReady
            ? "Groomed \(itemID) — every Definition-of-Ready clause is met; promote it to Ready when you're ready to run it"
            : "Groomed \(itemID) — \(proposal.readiness.summary)"
        Task { await load() }
    }

    /// Why a proposed `verify:` can't go on the backlog line — the refusals
    /// `BacklogViewModel.setItemVerify(itemID:to:)` applies, in its words. The
    /// serializer would otherwise put the previous line back over it. Nil when
    /// the line can hold it.
    static func groomVerifyRefusal(_ verify: String) -> String? {
        let trimmed = verify.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "a verify can't be empty" }
        guard trimmed.contains(DefinitionOfReady.fieldSeparator) else { return nil }
        return "a verify can't contain “\(DefinitionOfReady.fieldSeparator)”, the backlog line's field separator — "
            + "write the pipe without spaces"
    }

    func discardGroom() {
        groomPhase = .idle
    }

    /// Writes `command` as the line's `verify:` through the backlog, which
    /// owns the refusals. Returns whether it was saved, so the field closes
    /// only then; a refusal stays open over `verifyRefusal`.
    @discardableResult
    func setVerify(_ command: String) -> Bool {
        let outcome = backlog.setItemVerify(itemID: itemID, to: command)
        guard outcome == .applied else {
            verifyRefusal = outcome == .noBacklogOpen
                ? "Couldn't change the verify: no backlog is open"
                : backlog.operationMessage
            return false
        }
        verifyRefusal = nil
        Task { await load() }
        return true
    }

    func clearVerifyRefusal() {
        verifyRefusal = nil
    }

    /// Writes `ids` as the line's `needs:` through the backlog, which owns the
    /// refusals. Returns whether it was saved, so the field closes only then; a
    /// refusal stays open over `needsRefusal`.
    @discardableResult
    func setNeeds(_ ids: String) -> Bool {
        let outcome = backlog.setItemNeeds(itemID: itemID, to: ids)
        guard outcome == .applied else {
            needsRefusal = outcome == .noBacklogOpen
                ? "Couldn't change the needs: no backlog is open"
                : backlog.operationMessage
            return false
        }
        needsRefusal = nil
        Task { await load() }
        return true
    }

    func clearNeedsRefusal() {
        needsRefusal = nil
    }

    /// Appends `text` to the item's `## Notes` — where the next worker run is
    /// told what to do differently — through the same writer rejections use.
    /// Returns whether it landed, so the field closes only then: a blank note
    /// writes nothing, and a failed write says so in `actionNote`.
    @discardableResult
    func addNote(_ text: String) async -> Bool {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return false }
        guard backlog.appendNote(itemID: itemID, note) else {
            actionNote = "The note didn't reach \(itemID)'s detail file — nothing was saved"
            return false
        }
        await load()
        return true
    }

    /// Moves a draft to Ready, once the Definition-of-Ready agrees — whether
    /// that came from a groom pass here or from a hand-written detail file.
    func promote() async {
        guard action(.promote)?.isAvailable == true else { return }
        backlog.updateItemStatus(itemID: itemID, newStatus: .ready)
        actionNote = "Promoted \(itemID) to Ready"
        await load()
    }

    /// Reveals a run's transcript directory in Finder. Nil-safe: a run with no
    /// execution id has no directory, and the view disables the link.
    func revealTranscript(for run: ItemRunHistory.Row) {
        guard let url = transcriptURL(for: run) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
