import Foundation
import KiteloopCore
import os.log

private let backlogVMLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "backlog-vm")

@Observable
@MainActor
class BacklogViewModel {
    private let globalConfigStore: GlobalConfigStore
    private var watcher: BacklogFileWatcher?
    private var repoPath: String?
    var backlogFile: BacklogFile?
    private(set) var backlogURL: URL?
    /// Why the backlog could not be *loaded*; drawn in place of the list.
    private(set) var errorMessage: String?
    /// Why the last *edit* was refused; a banner above the list, cleared by the next edit that lands.
    private(set) var operationMessage: String?
    /// Lines of the backlog file the parser rejected on the last load. Shown as
    /// a banner in the panel — the file still loads, but these lines are lost
    /// on the next write-back, so the user has to see them.
    private(set) var parseIssues: [BacklogParseIssue] = []
    var selectedItemID: String?

    /// The project's stage flow (Project Settings → Backlog Flow).
    private(set) var workflow: BacklogWorkflowConfig = .default
    private var workflowStore: BacklogWorkflowConfigStore?

    /// The pre-run ledger, when the app attached one. Nil is a legitimate state
    /// — tests and embedded use — and the queue still reports how much of it is
    /// groomed; what it cannot report without this is what the grounding check
    /// and the retry ceiling refused the last time they looked. See `QueueHealth`.
    var groomingLedger: GroomingLedger?

    /// How much of the `ready` column could actually start, and what holds the
    /// rest — the reading the panel carries above its item list.
    ///
    /// Stored rather than computed on demand: judging an item reads its
    /// `backlog/<id>.md` off disk, and this is a `@MainActor` type a SwiftUI body
    /// re-evaluates whenever a transcript streams. Recomputed wherever
    /// `backlogFile` changes, which is the backlog reload the panel already
    /// performs — no second watcher.
    private(set) var queueHealth: QueueHealth = .empty

    /// Records approve/reopen transitions for success metric #3b. Nil when no
    /// metric store is attached (tests, embedded use) — the backlog works the
    /// same, it just isn't measured.
    private var escapedDefects: EscapedDefectTracker?

    /// Where `resolveGate` records whether the work landed. Nil when no metric
    /// store is attached (tests, embedded use) — the gate resolves the same, it
    /// just isn't measured.
    private var mergeOutcomeStore: TaskMetricStore?
    private var mergeOutcomeProjectPath: String?
    private var mergeOutcomeProjectName: String?

    /// Whether each item now sitting at the approval gate still merges cleanly
    /// onto the project's current base, keyed by item id — read live by
    /// `resolveGate` (to answer a stale approval before a merge is attempted)
    /// and by `WaitingOnYou`'s synchronous cross-project capture, neither of
    /// which can await a subprocess at the point they need the answer.
    /// Refreshed by `refreshGateFreshness`, called once an item reaches the
    /// gate and again after any merge that could have made a sibling's branch
    /// stale — see `BacklogAutopilot.accept` and the auto-merge path beside it,
    /// and `resolveGate`'s own successful merge below.
    private(set) var freshnessByItemID: [String: WorktreeManager.BranchFreshness] = [:]

    /// Items whose merge gate is verifying the merged tree right now, and
    /// since when — set around every `mergeAndVerify`, whoever asked for it,
    /// so a gate is a visible step rather than a status that arrived early.
    private(set) var gateActivity: [String: Date] = [:]

    func beginGateVerify(itemID: String) { gateActivity[itemID] = Date() }
    func endGateVerify(itemID: String) { gateActivity.removeValue(forKey: itemID) }

    /// The newest merge record for an item, as the ledger has it.
    func lastMergeEvent(for itemID: String) -> ItemMergeEvent? {
        guard let store = mergeOutcomeStore else { return nil }
        return store.mergeEvents
            .filter { event in
                event.itemID == itemID
                    && mergeOutcomeProjectPath.map { KiteloopProject.isSamePath(event.projectPath, $0) } ?? true
            }
            .max { $0.at < $1.at }
    }

    /// Verifying, waiting on a person, or refused — for an item at the gate;
    /// nil for any other status.
    func gateState(for item: BacklogItem) -> GateState? {
        let last = lastMergeEvent(for: item.id).map {
            GateState.LastMerge(merged: $0.merged, at: $0.at, reason: $0.reason)
        }
        return GateState.resolve(isAwaitingApproval: item.status == .awaitingApproval,
                                 verifyingSince: gateActivity[item.id],
                                 lastMerge: last)
    }

    /// Why autopilot holds `item` back on its `needs:` — the readiness gate's
    /// own phrases, one per unmet dependency. Empty for a done item, an item
    /// whose needs are all done, or when no backlog is open.
    func unmetDependencies(for item: BacklogItem) -> [String] {
        guard let file = backlogFile, item.status != .done else { return [] }
        return DefinitionOfReady.Dependencies(file: file).unmet(for: item)
    }

    /// The items at `awaiting-approval` as the Waiting-on-you drawer reads
    /// them: each with its stale-file count from the freshness cache and, when
    /// the merge gate already ran and refused, the refusal — so a refused
    /// merge is never listed as a decision waiting on a person.
    var gatedItemsForDrawer: [WaitingOnYou.ProjectReading.GatedItem] {
        (backlogFile?.sections.flatMap(\.items) ?? [])
            .filter { $0.status == .awaitingApproval }
            .map { item in
                let freshness = freshnessByItemID[item.id]
                let staleCount = (freshness?.clean == false) ? freshness?.conflicts.count : nil
                let gate = gateState(for: item)
                let refusal = gate?.kind == .refused ? (gate?.reason ?? "no reason recorded") : nil
                return .init(id: item.id, title: item.title, staleFileCount: staleCount, gateRefusal: refusal)
            }
    }

    /// Recomputes `freshnessByItemID` for every item now at `awaiting-approval`,
    /// against `projectRoot`'s current base. A full rebuild rather than an
    /// incremental update — gate items are rare, and this is the only way the
    /// cache ever drops an item whose approval resolved since the last call.
    /// `base` is the project's configured base branch, when it has one: the
    /// freshness question is "does this branch still merge onto what the merge
    /// will land on", and with a base set that is the base, not the checkout.
    func refreshGateFreshness(projectRoot: URL, base: String? = nil) async {
        let gateItems = (backlogFile?.sections.flatMap(\.items) ?? [])
            .filter { $0.status == .awaitingApproval }
        guard !gateItems.isEmpty else {
            freshnessByItemID = [:]
            return
        }
        let manager = WorktreeManager(projectRoot: projectRoot)
        var updated: [String: WorktreeManager.BranchFreshness] = [:]
        for item in gateItems {
            updated[item.id] = await manager.checkFreshness(branch: WorktreeSession.branchName(for: item.id),
                                                            against: base.map { "refs/heads/\($0)" } ?? "HEAD")
        }
        freshnessByItemID = updated
    }

    /// Open items `StaleItemSweep` finds nothing has touched inside its
    /// window, read live by `WaitingOnYou`'s synchronous cross-project
    /// capture — the same reason `freshnessByItemID` above is a cache rather
    /// than a live read. Only ever populated for a backlog on the shared
    /// branch: the sweep reads `.kiteloop/backlog-tree`'s own git history,
    /// and a project-local `BACKLOG.md` or a vault backlog has no such
    /// checkout to read.
    private(set) var staleFlags: [StaleItemSweep.FlaggedItem] = []

    /// The sweep now in flight, so the next one can supersede it. `reload()` is
    /// what the file watcher calls on every write to the backlog, which during a
    /// run is every status change and every appended note — so two sweeps
    /// overlapping is the normal case, not the rare one. Nothing used to
    /// serialise them: each read git at its own pace and assigned `staleFlags`
    /// whenever it finished, so an earlier sweep finishing last overwrote the
    /// newer reading with flags computed from a backlog that had already moved.
    private var staleFlagsRefresh: Task<Void, Never>?

    /// Recomputes `staleFlags` against the shared branch's checkout, off the
    /// main actor — one `git log` per open item with a detail path is exactly
    /// the synchronous I/O this actor may never block on. A no-op, clearing
    /// whatever the cache held, for a project with no branch-backed backlog.
    ///
    /// The last caller wins: this cancels whatever sweep was already in flight,
    /// and a cancelled sweep both stops spawning git (`StaleItemSweep.lastTouched`
    /// checks between items) and drops the reading it did get rather than
    /// assigning it over a newer one.
    func refreshStaleFlags() async {
        staleFlagsRefresh?.cancel()
        guard let branchProjectRoot, let file = backlogFile else {
            staleFlagsRefresh = nil
            staleFlags = []
            return
        }
        let items = file.sections.flatMap(\.items)
        let checkout = BacklogBranch.checkoutURL(projectRoot: branchProjectRoot)
        let sweep = Task { [weak self] in
            let lastTouched = await Self.readLastTouched(items: items, checkout: checkout)
            guard !Task.isCancelled else { return }
            self?.staleFlags = StaleItemSweep.flag(items: items, lastTouched: lastTouched)
        }
        staleFlagsRefresh = sweep
        await sweep.value
    }

    /// The git half of the sweep, off the main actor and cancellable with the
    /// task that awaits it. `Task.detached` inherits nothing, cancellation
    /// included, so the handler forwards it by hand — without which a superseded
    /// sweep would run its whole item list out.
    private static func readLastTouched(items: [BacklogItem], checkout: URL) async -> [String: Date] {
        let reading = Task.detached(priority: .utility) {
            StaleItemSweep.lastTouched(items: items, checkout: checkout)
        }
        return await withTaskCancellationHandler {
            await reading.value
        } onCancel: {
            reading.cancel()
        }
    }

    /// Where a note that could not reach its detail file is reported. The
    /// `## Notes` section is the only thing a rejection reason, a retirement note
    /// and a "returned to ready" explanation are written into, and it is what the
    /// next worker run is handed — so a write nobody could make has to say so
    /// rather than read like a run that had nothing to say.
    private let reporter: StoreProblemReporter

    /// The name a failed note write reports under. A human reads it in a
    /// notification title, and it is half the dedup key, so it is spelled once.
    static let notesStoreName = "Item notes"

    /// Where a write that kept an item's existing line is reported, for the
    /// backlog file it was made for. Kept across writes so each item is
    /// reported once, not on every save; a different file starts afresh.
    @ObservationIgnored private var keptLines: (url: URL, report: BacklogKeptLineReport)?

    /// The inbox this project's approval notices live in, when one is attached.
    ///
    /// An "Approval needed" row is not a record that a gate once opened — it is
    /// the gate, shown somewhere else. So it closes when the gate closes, from
    /// whichever surface closed it, and every path here that takes an item out
    /// of `awaitingApproval` says so. Before this the row could only be cleared
    /// by a click, and a gate resolved over the API, by auto-approve or by a
    /// marathon left it standing forever: 2,138 unresolved notices on
    /// 2026-08-15, almost all about items merged days earlier.
    private let notifications: (any NotificationStoring)?

    /// Whether the one-off sweep over the notices left behind by earlier
    /// launches has run. `reload()` is called on every file-watcher wake, and
    /// the sweep must run once — a rolled-up row filed by *this* launch is a
    /// live reading, and re-running the sweep would resolve it out from under
    /// the operator.
    private var didBackfillNotices = false

    init(globalConfigStore: GlobalConfigStore, reporter: StoreProblemReporter = .shared,
         notifications: (any NotificationStoring)? = nil) {
        self.globalConfigStore = globalConfigStore
        self.reporter = reporter
        self.notifications = notifications
    }

    /// Starts measuring escaped defects for this project. The backlog as it
    /// stands right now becomes the baseline: statuses already on disk are a
    /// state, not transitions, so nothing is recorded until something moves.
    func configureEscapedDefectTracking(store: TaskMetricStore, projectPath: String, projectName: String) {
        let tracker = EscapedDefectTracker(store: store, projectPath: projectPath, projectName: projectName)
        tracker.observe(backlogFile)
        escapedDefects = tracker
    }

    /// Starts recording what the human gate does to an item's branch. Without
    /// this, resolving a gate still merges — it just leaves no record that it
    /// did, and the run reads as "nobody said" forever.
    func configureMergeOutcomeRecording(store: TaskMetricStore, projectPath: String, projectName: String) {
        mergeOutcomeStore = store
        mergeOutcomeProjectPath = projectPath
        mergeOutcomeProjectName = projectName
    }

    func configureWorkflow(configURL: URL) {
        let store = BacklogWorkflowConfigStore(url: configURL)
        workflowStore = store
        workflow = store.load()
    }

    /// Applies a flow edited in Project Settings → Backlog Flow: memory first, so
    /// the run in flight obeys the new gate immediately, then the file.
    ///
    /// Throws rather than swallowing, because the one caller — the Backlog Flow
    /// tab — shows the failure beside the controls that caused it, and a save
    /// that did not reach disk must not read like one that did.
    func updateWorkflow(_ config: BacklogWorkflowConfig) throws {
        workflow = config.sanitized()
        do {
            try workflowStore?.save(workflow)
        } catch {
            backlogVMLog.error("Failed to save backlog workflow: \(error.localizedDescription)")
            throw error
        }
    }

    /// Items parked at Awaiting Approval, surfaced as a badge on the panel.
    var awaitingApprovalCount: Int {
        backlogFile?.sections.flatMap(\.items).count { $0.status == .awaitingApproval } ?? 0
    }

    /// The ids of those items — what the notification backfill compares its
    /// standing "Approval needed" rows against as a project loads.
    ///
    /// Empty when no backlog has loaded yet, which is why the backfill runs
    /// after `loadForProject` and not before: an empty set there would read as
    /// "no item is at the gate" and resolve every live summons.
    var itemIDsAwaitingApproval: Set<String> {
        Set((backlogFile?.sections.flatMap(\.items) ?? [])
            .filter { $0.status == .awaitingApproval }
            .map(\.id))
    }

    func refresh() {
        guard let path = repoPath else { return }
        loadForProject(repoPath: path)
    }

    /// True when neither a project-local BACKLOG.md nor a vault backlog was
    /// found — the panel offers to create one.
    private(set) var noBacklogFound = false

    /// The vault this backlog may live in, for a caller that has to ask the same
    /// question about the same files — `GroundingCheck` resolves a citation
    /// against the vault as well as the repo, and a `backlog/<id>.md` beside a
    /// vault backlog is a real path. Exposed here rather than threading a second
    /// `GlobalConfigStore` to every caller: this is the layer that already
    /// resolves the backlog against it.
    var vaultURL: URL? { globalConfigStore.vaultURL }

    func loadForProject(repoPath: String) {
        self.repoPath = repoPath
        noBacklogFound = false
        branchProjectRoot = nil

        // A BACKLOG.md in the project root wins: it's self-contained, travels
        // with the repo, and needs no configuration. The shared backlog branch
        // (`kiteloop/backlog`, docs/backlog-branch.md) is the team layer checked
        // second — it came with the clone, so a teammate opening a fresh clone
        // lands here with zero setup. The vault (optional, Settings →
        // General) stays the cross-project personal layer, checked last.
        let localURL = URL(fileURLWithPath: repoPath).appending(path: "BACKLOG.md")
        if FileManager.default.fileExists(atPath: localURL.path(percentEncoded: false)) {
            backlogVMLog.info("Using project-local backlog: \(localURL.path())")
            startWatching(url: localURL)
            return
        }

        let rootURL = URL(fileURLWithPath: repoPath, isDirectory: true)
        if BacklogBranch.availability(projectRoot: rootURL) != .absent,
           let branchURL = BacklogBranch.adopt(projectRoot: rootURL) {
            backlogVMLog.info("Using shared backlog branch: \(branchURL.path())")
            branchProjectRoot = rootURL
            startWatching(url: branchURL)
            // Catch up with the team in the background; the file watcher sees
            // whatever the fast-forward brings in.
            Task.detached { BacklogBranch.sync(projectRoot: rootURL) }
            return
        }

        if let vaultURL = globalConfigStore.vaultURL {
            backlogVMLog.info("Looking for backlog: vault=\(vaultURL.path()), repo=\(repoPath)")
            if let url = BacklogParser.findBacklogPath(vaultURL: vaultURL, repoPath: repoPath) {
                startWatching(url: url)
                return
            }
        }

        noBacklogFound = true
        errorMessage = nil
        parseIssues = []
        backlogFile = nil
        refreshQueueHealth()
    }

    /// Re-judge the `ready` column against the backlog as it now stands.
    ///
    /// Called from the two seams `escapedDefects` observes — the reload and the
    /// write-back — so an approval or a status change moves the line straight
    /// away instead of waiting for the watcher to come back around.
    ///
    /// The detail resolution is `loadDetail`, the same one `GET /v1/backlog` and
    /// `GET /v1/projects` judge with, so the panel and a headless driver read one
    /// answer rather than two derivations that can drift apart.
    private func refreshQueueHealth() {
        guard let file = backlogFile else {
            queueHealth = .empty
            return
        }
        queueHealth = QueueHealth.make(
            items: file.sections.flatMap(\.items),
            detail: { self.loadDetail(for: $0) },
            refusals: QueueHealth.recordedRefusals(groomingLedger?.records ?? [],
                                                   projectPath: repoPath ?? "",
                                                   detailModified: { self.detailModified(itemID: $0) }))
    }

    /// The last-edited date of an item's groomed detail file — what
    /// `recordedRefusals` compares a recorded refusal against, so a regroom
    /// after the fact clears it. Nil when the item has no detail file, or its
    /// modification date can't be read.
    private func detailModified(itemID: String) -> Date? {
        guard let item = item(withID: itemID), let url = detailURL(for: item) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    /// Set when the backlog in use lives on the shared branch's private
    /// checkout — the write path commits there after every save.
    private var branchProjectRoot: URL?

    /// Whether this project could start a shared backlog branch (it is a git
    /// repo and no backlog exists yet anywhere) — drives the empty state's
    /// offer.
    var canCreateBranchBacklog: Bool {
        guard noBacklogFound, let repoPath else { return false }
        return WorktreeManager.isGitRepository(at: URL(fileURLWithPath: repoPath, isDirectory: true))
    }

    /// Create the shared branch and adopt it — the empty state's "team
    /// backlog" path, next to the existing local-file seeding. The git work —
    /// its push included, on a deadline of up to two minutes — runs off the
    /// main actor, as `sync` and `commitChanges` already do.
    func createBranchBacklog() async {
        guard let repoPath else { return }
        let rootURL = URL(fileURLWithPath: repoPath, isDirectory: true)
        let name = rootURL.lastPathComponent
        let created = await Task.detached(priority: .userInitiated) {
            BacklogBranch.createShared(projectRoot: rootURL, projectName: name)
        }.value
        guard let url = created else {
            errorMessage = "Couldn't create the shared backlog branch — see the log"
            return
        }
        noBacklogFound = false
        branchProjectRoot = rootURL
        startWatching(url: url)
    }

    private func startWatching(url: URL) {
        backlogURL = url
        reload()

        let fileWatcher = BacklogFileWatcher { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
        fileWatcher.watch(url: url)
        watcher = fileWatcher
    }

    /// Seeds a starter BACKLOG.md in the project root. The template doubles
    /// as format documentation: frontmatter, sections, and item syntax.
    func createStarterBacklog() {
        guard let repoPath else { return }
        let projectName = URL(fileURLWithPath: repoPath).lastPathComponent
        let template = """
        ---
        project: \(projectName)
        verify_default: echo "replace with your build/test command"
        ---

        # \(projectName) Backlog

        ## Now

        - [ ] task-1 | Describe your first task here
        - [ ] task-2 | Items are `id | title`; agents pick them up from the backlog panel

        ## Later

        - [ ] task-3 | Sections group work; check items off as they land

        ## Done

        """
        let url = URL(fileURLWithPath: repoPath).appending(path: "BACKLOG.md")
        do {
            try AtomicFileWriter.write(Data(template.utf8), to: url)
            noBacklogFound = false
            startWatching(url: url)
        } catch {
            backlogVMLog.error("Failed to create starter backlog: \(error.localizedDescription)")
            errorMessage = "Couldn't create BACKLOG.md: \(error.localizedDescription)"
        }
    }

    func reload() {
        guard let url = backlogURL else { return }
        guard let data = try? Data(contentsOf: url) else {
            backlogVMLog.error("Failed to read backlog file: \(url.path())")
            errorMessage = "Cannot read backlog file"
            return
        }
        // Decoded lossily: one bad byte must not make the whole backlog read as empty.
        let content = String(decoding: data, as: UTF8.self)

        let result = BacklogParser.parseWithIssues(content)
        backlogFile = result.file
        parseIssues = result.issues
        errorMessage = nil
        markNowEpicLanes()
        // Catches status changes made outside the app — a hand edit to
        // BACKLOG.md that reopens a done item counts the same as one made here.
        escapedDefects?.observe(result.file)
        refreshQueueHealth()
        backfillPassedNotices()
        // Fire-and-forget: staleness moves in days, not on every keystroke a
        // watcher wakes up for, and `waitingOnYou` reads whatever the cache
        // held on the redraw right after this returns regardless.
        Task { await self.refreshStaleFlags() }
        for issue in result.issues {
            backlogVMLog.error("Backlog parse issue at line \(issue.line): \(issue.reason) — \(issue.text)")
        }
        backlogVMLog.info("Loaded backlog: \(self.backlogFile?.sections.count ?? 0) sections, \(result.issues.count) parse issues")
    }

    /// Carries a `Now` epic across to the lane it now means, once.
    ///
    /// The marks are written back, so the load after this one finds every item
    /// in that epic already `now` and `BacklogLaneMigration.migrated` answers
    /// nil — nothing is written, and the write-back this does make does not
    /// loop through the watcher that sees it. The items stay in the epic they
    /// were in; only a person moves them home, since nothing in the file says
    /// which area they belong to.
    private func markNowEpicLanes() {
        guard let file = backlogFile, let migrated = BacklogLaneMigration.migrated(file) else { return }
        backlogFile = migrated
        backlogVMLog.info("Marked the Now epic's items as lane:now")
        writeBack()
    }

    func updateItemStatus(itemID: String, newStatus: BacklogItemStatus) {
        guard var file = backlogFile else { return }
        for sIdx in file.sections.indices {
            if let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) {
                file.sections[sIdx].items[iIdx].status = newStatus
                // The serializer writes a reason only for `blocked`, so one left
                // behind fails its round-trip and the old blocked line stays.
                if newStatus != .blocked { file.sections[sIdx].items[iIdx].blockedReason = nil }
                backlogFile = file
                writeBack()
                return
            }
        }
    }

    /// Lifts a blocked item to `draft` or `ready`, keeping the reason it was
    /// blocked for as a Notes line. The one path both the item's page and
    /// `POST /v1/backlog/groom` take, so the note reads the same from either.
    ///
    /// `blocked` was reachable from every stage and left through none: groom
    /// moved draft and ready only, release lifted a retry-ceiling retirement,
    /// and a person cleared a block by editing the backlog file by hand — which
    /// lost the reason. The reason is the one thing the next run and the human
    /// both want, so it goes to the Notes before the status changes.
    ///
    /// False when the item is not blocked or not here; the status is untouched
    /// then.
    @discardableResult
    func unblock(itemID: String, to target: BacklogItemStatus) -> Bool {
        guard let item = item(withID: itemID), item.status == .blocked,
              target == .draft || target == .ready else { return false }
        let was = item.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appendNote(to: item, "unblocked by hand; was: \(was.isEmpty ? "no reason recorded" : was)")
        // The reason goes with the status: the serializer writes `blocked:…`
        // for any item that still carries one, whatever its stage says.
        guard var file = backlogFile else { return false }
        for sIdx in file.sections.indices {
            guard let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) else { continue }
            file.sections[sIdx].items[iIdx].status = target
            file.sections[sIdx].items[iIdx].blockedReason = nil
        }
        backlogFile = file
        writeBack()
        return true
    }

    /// Sends a pickup refusal back to `draft` with the refusal written as the
    /// reason, the same pairing `unblock` keeps for a lifted block:
    /// `GroundingCheck` and `DefinitionOfReady` already say exactly what to
    /// fix, and a status that says nothing left the same wording refused
    /// three ticks running before a human read the retirement note it
    /// eventually earned.
    ///
    /// False when the item is not here; the status is untouched then. The
    /// note is best-effort on top of a successful move, since an item refused
    /// for having no detail file at all has nowhere to write one.
    @discardableResult
    func sendBackToDraft(itemID: String, reason: String) -> Bool {
        guard let item = item(withID: itemID) else { return false }
        appendNote(to: item, "sent back to draft: \(reason)")
        guard var file = backlogFile else { return false }
        for sIdx in file.sections.indices {
            guard let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) else { continue }
            file.sections[sIdx].items[iIdx].status = .draft
        }
        backlogFile = file
        writeBack()
        return true
    }

    func updateItem(itemID: String, title: String?, verify: String?) {
        guard var file = backlogFile else { return }
        for sIdx in file.sections.indices {
            if let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) {
                if let title { file.sections[sIdx].items[iIdx].title = title }
                if let verify { file.sections[sIdx].items[iIdx].verify = verify }
                backlogFile = file
                writeBack()
                return
            }
        }
    }

    /// What renaming an item did, for the row's rename field to decide about —
    /// `EpicEditOutcome` is the precedent: each refusal is named in
    /// `operationMessage` too, so the field stays open over a reason.
    enum ItemTitleOutcome: Sendable, Equatable {
        /// The title changed and was written back, or already was the title.
        case applied
        /// No backlog is loaded, so there is no item to rename.
        case noBacklogOpen
        /// The title was empty, or nothing but whitespace.
        case emptyTitle
        /// The title holds the line's field separator. The line would not
        /// parse back, so the serializer would write the old line instead and
        /// the rename would look saved without landing.
        case holdsFieldSeparator
        /// No item in the backlog carries that id.
        case unknownItem
    }

    @discardableResult
    func renameItem(itemID: String, to newTitle: String) -> ItemTitleOutcome {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard backlogFile != nil else { return .noBacklogOpen }
        guard let current = item(withID: itemID) else {
            operationMessage = "Couldn't rename \(itemID): no item in the backlog has that id"
            return .unknownItem
        }
        guard !trimmed.isEmpty else {
            operationMessage = "Couldn't rename \(itemID): an item needs a title"
            return .emptyTitle
        }
        guard !trimmed.contains(DefinitionOfReady.fieldSeparator) else {
            operationMessage = "Couldn't rename \(itemID): a title can't contain "
                + "“\(DefinitionOfReady.fieldSeparator)”, the backlog line's field separator"
            return .holdsFieldSeparator
        }
        // Renaming to the title it already has changes nothing and is nothing
        // to refuse — the caller closes its field on it.
        guard trimmed != current.title else { return .applied }
        updateItem(itemID: itemID, title: trimmed, verify: nil)
        return .applied
    }

    /// What setting an item's `verify:` did — `ItemTitleOutcome`'s shape, for
    /// the item page's verify field: each refusal is named in
    /// `operationMessage` too, so the field stays open over a reason.
    enum ItemVerifyOutcome: Sendable, Equatable {
        /// The verify changed and was written back, or already was the verify.
        case applied
        /// No backlog is loaded, so there is no item to change.
        case noBacklogOpen
        /// The command was empty, or nothing but whitespace.
        case emptyVerify
        /// The command holds the line's field separator, which
        /// `DefinitionOfReady` refuses and the line would not parse back from.
        case holdsFieldSeparator
        /// No item in the backlog carries that id.
        case unknownItem
    }

    @discardableResult
    func setItemVerify(itemID: String, to newVerify: String) -> ItemVerifyOutcome {
        let trimmed = newVerify.trimmingCharacters(in: .whitespaces)
        guard backlogFile != nil else { return .noBacklogOpen }
        guard let current = item(withID: itemID) else {
            operationMessage = "Couldn't change \(itemID)'s verify: no item in the backlog has that id"
            return .unknownItem
        }
        guard !trimmed.isEmpty else {
            operationMessage = "Couldn't change \(itemID)'s verify: a verify can't be empty"
            return .emptyVerify
        }
        guard !trimmed.contains(DefinitionOfReady.fieldSeparator) else {
            operationMessage = "Couldn't change \(itemID)'s verify: a verify can't contain "
                + "“\(DefinitionOfReady.fieldSeparator)”, the backlog line's field separator — "
                + "write the pipe without spaces"
            return .holdsFieldSeparator
        }
        guard trimmed != current.verify else { return .applied }
        updateItem(itemID: itemID, title: nil, verify: trimmed)
        return .applied
    }

    /// What setting an item's `needs:` did — `ItemVerifyOutcome`'s shape, for
    /// the item page's needs field: each refusal is named in `operationMessage`
    /// too, so the field stays open over a reason. Pickup withholds an item on
    /// an unknown id or a loop, so each is refused here, before it is written,
    /// rather than discovered later as an item that never starts.
    enum ItemNeedsOutcome: Sendable, Equatable {
        /// The needs changed and were written back, or already were the needs.
        case applied
        /// No backlog is loaded, so there is no item to change.
        case noBacklogOpen
        /// No item in the backlog carries the item's own id.
        case unknownItem
        /// An id in the list names no item in the backlog.
        case unknownDependency(String)
        /// The list names the item itself.
        case selfDependency
        /// The list would close this loop, the item first and last.
        case cycle([String])
    }

    /// Sets the item's `needs:` to the ids in `input`, split on commas and
    /// whitespace, empties and repeats dropped, order kept. An empty input
    /// clears them.
    @discardableResult
    func setItemNeeds(itemID: String, to input: String) -> ItemNeedsOutcome {
        guard let file = backlogFile else { return .noBacklogOpen }
        guard let current = item(withID: itemID) else {
            operationMessage = "Couldn't change \(itemID)'s needs: no item in the backlog has that id"
            return .unknownItem
        }
        let needs = Self.neededIDs(in: input)
        if let refusal = needsRefusal(for: itemID, needs: needs, in: file) {
            operationMessage = "Couldn't change \(itemID)'s needs: " + Self.describe(refusal, itemID: itemID)
            return refusal
        }
        guard needs != current.needs else { return .applied }
        updateItemNeeds(itemID: itemID, needs: needs)
        return .applied
    }

    private static func neededIDs(in input: String) -> [String] {
        var seen: Set<String> = []
        return input
            .components(separatedBy: CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The first thing wrong with `needs` as the item's list, nil when nothing is.
    /// The cycle walk runs over the backlog as it would read with the new list.
    private func needsRefusal(for itemID: String, needs: [String], in file: BacklogFile) -> ItemNeedsOutcome? {
        if let unknown = needs.first(where: { item(withID: $0) == nil }) { return .unknownDependency(unknown) }
        if needs.contains(itemID) { return .selfDependency }
        let items = file.sections.flatMap(\.items).map { other -> BacklogItem in
            var edited = other
            if edited.id == itemID { edited.needs = needs }
            return edited
        }
        let dependencies = DefinitionOfReady.Dependencies(items: items)
        return needs.lazy.compactMap { dependencies.cycle(from: itemID, through: $0) }.first.map { .cycle($0) }
    }

    private static func describe(_ refusal: ItemNeedsOutcome, itemID: String) -> String {
        switch refusal {
        case .unknownDependency(let id): return "no item in the backlog has the id \(id)"
        case .selfDependency: return "an item can't need itself (\(itemID))"
        case .cycle(let path): return "that makes a dependency cycle: \(path.joined(separator: " → "))"
        case .applied, .noBacklogOpen, .unknownItem: return ""
        }
    }

    /// Widens an item's verify with `commands` it never ran, in both places a
    /// verify lives: the line, and the detail's frontmatter list when the file
    /// has one (a run executes that list and reads the line only when it is
    /// empty, so widening the line alone would declare a command no run makes).
    /// Returns what the line gained, or nil when it already ran them all.
    @discardableResult
    func widenVerify(itemID: String, adding commands: [String], map: VerifyCoverage.Map) -> String? {
        guard let item = item(withID: itemID),
              let widened = VerifyCoverage.widen(verify: item.verify, adding: commands, map: map)
        else { return nil }
        let gained = String(widened.dropFirst((item.verify ?? "").count))
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^&& ", with: "", options: .regularExpression)
        updateItem(itemID: itemID, title: nil, verify: widened)
        widenDetailVerify(of: item, adding: gained)
        return gained
    }

    private func widenDetailVerify(of item: BacklogItem, adding command: String) {
        // Decoded lossily: one bad byte must not silently drop the widened verify.
        guard let detailURL = detailURL(for: item),
              let data = try? Data(contentsOf: detailURL),
              let widened = BacklogParser.wideningDetailVerify(String(decoding: data, as: UTF8.self), adding: command)
        else { return }
        do {
            try AtomicFileWriter.write(Data(widened.utf8), to: detailURL)
        } catch {
            reporter.report(store: Self.notesStoreName, operation: .write, url: detailURL, error: error)
        }
    }

    func updateItemSize(itemID: String, size: ItemSize) {
        guard var file = backlogFile else { return }
        for sIdx in file.sections.indices {
            if let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) {
                file.sections[sIdx].items[iIdx].size = size
                backlogFile = file
                writeBack()
                return
            }
        }
    }

    /// Marks the item `lane:now` or clears the mark, leaving it where it sits in
    /// its epic — the lane orders the queue, so the item need not move.
    func updateItemLane(itemID: String, lane: BacklogLane) {
        guard var file = backlogFile else { return }
        for sIdx in file.sections.indices {
            if let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) {
                file.sections[sIdx].items[iIdx].lane = lane
                backlogFile = file
                writeBack()
                return
            }
        }
    }

    private func updateItemNeeds(itemID: String, needs: [String]) {
        guard var file = backlogFile else { return }
        for sIdx in file.sections.indices {
            if let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) {
                file.sections[sIdx].items[iIdx].needs = needs
                backlogFile = file
                writeBack()
                return
            }
        }
    }

    /// `size` and `status` are for a caller that groomed the line before adding
    /// it; left nil the item is unsized and lands in the project's configured
    /// new-item stage, as every existing caller expects.
    ///
    /// Refuses an id the file already holds, for the reason `fileGroomedItem`
    /// does: `updateItem`, `updateItemStatus`, `updateItemSize`, `moveItem` and
    /// `removeItem` all resolve an id with `firstIndex(where:)`, so a second
    /// item under a taken id can never be reached — it cannot be edited, moved,
    /// sized or deleted, and the line sits in the file being nothing. The
    /// refusal is named in `operationMessage` as well as returned, since the Add
    /// Item control has no return value to read.
    ///
    /// Refuses a blank title, and one holding the line's field separator for
    /// the reason `renameItem` does: the line would not parse back, and the
    /// serializer has no earlier line to fall back to, so it would be written
    /// cut in half. The title is stored trimmed.
    @discardableResult
    func addItem(sectionName: String, id: String, title: String, verify: String?,
                 size: ItemSize? = nil, status: BacklogItemStatus? = nil) -> FilingOutcome {
        guard var file = backlogFile else { return .noBacklogOpen }
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            operationMessage = "Couldn't add \(id): an item needs a title"
            return .emptyTitle
        }
        guard !title.contains(DefinitionOfReady.fieldSeparator) else {
            operationMessage = "Couldn't add \(id): a title can't contain "
                + "“\(DefinitionOfReady.fieldSeparator)”, the backlog line's field separator"
            return .holdsFieldSeparator
        }
        guard !file.sections.flatMap(\.items).contains(where: { $0.id == id }) else {
            backlogVMLog.error("Refused to add \(id): id already in the backlog")
            operationMessage = "Couldn't add \(id): that id is already in the backlog"
            return .duplicateID
        }

        let item = BacklogItem(
            id: id,
            title: title,
            verify: verify ?? file.verifyDefault,
            status: status ?? workflow.effectiveNewItemStage,
            type: .local,
            size: size
        )

        if let idx = file.sections.firstIndex(where: { $0.name == sectionName }) {
            file.sections[idx].items.append(item)
        } else {
            file.sections.append(BacklogSection(name: sectionName, items: [item]))
        }

        backlogFile = file
        if let failure = writeBack() { return .backlogWriteFailed(failure) }
        return .filed
    }

    // MARK: - Epics

    /// Epics are the backlog's sections. These operate on `backlogFile.sections`
    /// and persist via `writeBack()`, mirroring `addItem`.

    /// What an epic edit did, for a caller that has an open text field to decide
    /// about. `addItem`'s `FilingOutcome` is the precedent: a refusal the caller
    /// can read, named in `operationMessage` too, rather than a silent return.
    enum EpicEditOutcome: Sendable, Equatable {
        /// The section list changed and was written back.
        case applied
        /// No backlog is loaded, so there are no sections to edit.
        case noBacklogOpen
        /// The name was empty, or nothing but whitespace.
        case emptyName
        /// A section already carries that name. A second would be unreachable:
        /// every epic operation here resolves a section by `name`.
        case nameTaken
        /// `renameEpic` was given an old name no section carries.
        case unknownEpic
        /// A description line the backlog file would read back as structure —
        /// an epic heading ("## "), an item line ("- [") or frontmatter ("---")
        /// — so the saved text would split the epic on the next read.
        case descriptionHoldsStructure
    }

    @discardableResult
    func addEpic(name: String) -> EpicEditOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard var file = backlogFile else { return .noBacklogOpen }
        guard !trimmed.isEmpty else {
            operationMessage = "Couldn't add an epic: it needs a name"
            return .emptyName
        }
        guard !file.sections.contains(where: { $0.name == trimmed }) else {
            backlogVMLog.error("Refused to add epic: name already in the backlog")
            operationMessage = "Couldn't add “\(trimmed)”: an epic already has that name"
            return .nameTaken
        }
        file.sections.append(BacklogSection(name: trimmed, items: []))
        backlogFile = file
        writeBack()
        return .applied
    }

    @discardableResult
    func renameEpic(from oldName: String, to newName: String) -> EpicEditOutcome {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard var file = backlogFile else { return .noBacklogOpen }
        guard !trimmed.isEmpty else {
            operationMessage = "Couldn't rename “\(oldName)”: an epic needs a name"
            return .emptyName
        }
        // Renaming an epic to what it is already called changes nothing and is
        // nothing to refuse — the caller closes its field on it.
        guard trimmed != oldName else { return .applied }
        guard !file.sections.contains(where: { $0.name == trimmed }) else {
            backlogVMLog.error("Refused to rename epic: name already in the backlog")
            operationMessage = "Couldn't rename to “\(trimmed)”: an epic already has that name"
            return .nameTaken
        }
        guard let idx = file.sections.firstIndex(where: { $0.name == oldName }) else {
            return .unknownEpic
        }
        file.sections[idx].name = trimmed
        backlogFile = file
        writeBack()
        return .applied
    }

    @discardableResult
    func updateEpicDescription(name: String, text: String?) -> EpicEditOutcome {
        guard var file = backlogFile else { return .noBacklogOpen }
        guard let idx = file.sections.firstIndex(where: { $0.name == name }) else { return .unknownEpic }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        // `BacklogParser` reads these lines as a heading, an item or frontmatter
        // wherever they sit, so written under the epic they would not come back
        // as its description.
        let structural = trimmed?.components(separatedBy: .newlines).first { line in
            let bare = line.trimmingCharacters(in: .whitespaces)
            return bare.hasPrefix("## ") || bare.hasPrefix("- [") || bare == "---"
        }
        if let structural {
            let line = structural.trimmingCharacters(in: .whitespaces)
            backlogVMLog.error("Refused epic description: a line reads as backlog structure")
            operationMessage = "Couldn't save the description of “\(name)”: the line “\(line)” would be read back as a heading, an item or frontmatter"
            return .descriptionHoldsStructure
        }
        file.sections[idx].description = (trimmed?.isEmpty ?? true) ? nil : trimmed
        backlogFile = file
        writeBack()
        return .applied
    }

    func deleteEpic(name: String) {
        guard var file = backlogFile else { return }
        file.sections.removeAll { $0.name == name }
        backlogFile = file
        writeBack()
    }

    func reorderEpics(_ names: [String]) {
        guard var file = backlogFile else { return }
        let ordered = names.compactMap { name in file.sections.first { $0.name == name } }
        // Keep any sections not named in `names` at the end, order preserved.
        let remaining = file.sections.filter { !names.contains($0.name) }
        file.sections = ordered + remaining
        backlogFile = file
        writeBack()
    }

    /// Swap the named epic with its neighbour: `offset` -1 moves it up, +1 down.
    /// At either end, or for a name the file doesn't have, nothing moves and
    /// nothing is written.
    func moveEpic(name: String, by offset: Int) {
        guard canMoveEpic(name: name, by: offset),
              var names = backlogFile?.sections.map(\.name),
              let from = names.firstIndex(of: name) else { return }
        names.swapAt(from, from + offset)
        reorderEpics(names)
    }

    /// Whether `moveEpic(name:by:)` has somewhere to go — false at either end
    /// and for a name the file doesn't have.
    func canMoveEpic(name: String, by offset: Int) -> Bool {
        guard abs(offset) == 1,
              let names = backlogFile?.sections.map(\.name),
              let from = names.firstIndex(of: name) else { return false }
        return names.indices.contains(from + offset)
    }

    func moveItem(itemID: String, toEpic epicName: String) {
        guard var file = backlogFile else { return }
        var moved: BacklogItem?
        for sIdx in file.sections.indices {
            if let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) {
                moved = file.sections[sIdx].items.remove(at: iIdx)
                break
            }
        }
        guard let item = moved else { return }
        if let idx = file.sections.firstIndex(where: { $0.name == epicName }) {
            file.sections[idx].items.append(item)
        } else {
            file.sections.append(BacklogSection(name: epicName, items: [item]))
        }
        backlogFile = file
        writeBack()
    }

    /// Reorder an item: in front of `before` when given (following it into its
    /// epic when that is a different one), else to the top of its own epic. The
    /// queue is document order, so this *is* prioritisation — there is no
    /// priority field, deliberately.
    func moveItem(itemID: String, before beforeID: String?) {
        guard var file = backlogFile, itemID != beforeID else { return }
        var moved: BacklogItem?
        var homeIdx: Int?
        for sIdx in file.sections.indices {
            if let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) {
                moved = file.sections[sIdx].items.remove(at: iIdx)
                homeIdx = sIdx
                break
            }
        }
        guard let item = moved, let homeIdx else { return }
        if let beforeID {
            for sIdx in file.sections.indices where file.sections[sIdx].items.contains(where: { $0.id == beforeID }) {
                let at = file.sections[sIdx].items.firstIndex { $0.id == beforeID }!
                file.sections[sIdx].items.insert(item, at: at)
                backlogFile = file
                writeBack()
                return
            }
            // `before` names nothing: put the item back where it was, write nothing.
            file.sections[homeIdx].items.insert(item, at: 0)
            return
        }
        file.sections[homeIdx].items.insert(item, at: 0)
        backlogFile = file
        writeBack()
    }

    func removeItem(itemID: String) {
        guard var file = backlogFile else { return }
        for sIdx in file.sections.indices {
            file.sections[sIdx].items.removeAll { $0.id == itemID }
        }
        backlogFile = file
        writeBack()
    }

    func markDone(itemID: String, queries: Int?, cost: Double?) {
        guard var file = backlogFile else { return }
        for sIdx in file.sections.indices {
            if let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) {
                file.sections[sIdx].items[iIdx].status = .done
                file.sections[sIdx].items[iIdx].blockedReason = nil
                file.sections[sIdx].items[iIdx].queries = queries
                file.sections[sIdx].items[iIdx].cost = cost
                file.sections[sIdx].items[iIdx].completedDate = DayKey.string(for: Date())
                backlogFile = file
                writeBack()
                return
            }
        }
    }

    // MARK: - Human Gates

    /// Stakeholder approval — the only path to Done when approval is enabled.
    /// Stamps completion date and the run's cost, and keeps the item listed.
    ///
    /// `closure` is what the item's approval notice says as it resolves itself:
    /// a person in the app, a caller on the control API, or the project's own
    /// `approveReviewPassedRuns` clearing the gate with nobody looking. The
    /// default is the app, because that is what every caller that does not know
    /// otherwise is.
    func approve(itemID: String, queries: Int? = nil, cost: Double? = nil,
                 closure: GateClosure = .approved) {
        markDone(itemID: itemID, queries: queries, cost: cost)
        resolveApprovalNotices(itemID: itemID, closure: closure)
    }

    /// Closes the approval notices about an item whose gate has just resolved,
    /// recording how. A no-op without an inbox, and a no-op for an item that
    /// never had a notice — resolving nothing costs nothing.
    private func resolveApprovalNotices(itemID: String, closure: GateClosure) {
        guard let store = notifications else { return }
        Task { await store.resolveApprovals(itemID: itemID, closure: closure) }
    }

    /// The backfill on load: the first time a backlog is actually parsed, the
    /// notices whose state has already passed are resolved with a reason.
    ///
    /// Nothing before this resolved an "Approval needed" row except a click, so
    /// a gate closed over the control API, by `approveReviewPassedRuns` or by a
    /// gate retry left its summons standing for good — 2,138 of them across the
    /// feeds on 2026-08-15, nearly all about items merged days earlier. The
    /// paths above now close a notice with its gate; this clears the ones
    /// already on disk, and catches a gate that closed in a launch this one
    /// knows nothing about.
    ///
    /// Deliberately after the parse rather than at project open: a sweep run
    /// against a backlog that has not loaded sees no item at the gate, and would
    /// resolve every live summons in the feed.
    private func backfillPassedNotices() {
        guard !didBackfillNotices, let store = notifications, backlogFile != nil else { return }
        didBackfillNotices = true
        let atGate = itemIDsAwaitingApproval
        Task {
            let resolved = await store.backfillPassedNotices(itemsAtGate: atGate)
            guard resolved > 0 else { return }
            backlogVMLog.info("""
                Resolved \(resolved, privacy: .public) notification(s) whose state had already passed
                """)
        }
    }

    /// `approve(itemID:)`, plus the ledger row when this approval overrides a
    /// blocking finding — the human gate's three landing points in
    /// `resolveGate`, and only those: `approve(itemID:)` itself is also called
    /// from the setting that clears a gate with nobody looking
    /// (`BacklogAutopilot`'s `approveReviewPassedRuns` path) and from a plain
    /// "mark done" with no gate at all, neither of which is the human decision
    /// this ledger exists to capture.
    private func approveAndRecordOverride(itemID: String, closure: GateClosure) {
        approve(itemID: itemID, closure: closure)
        recordFindingOverrides(itemID: itemID)
    }

    /// What resolving an item's human gate did — enough for a caller to report
    /// it without inferring anything.
    enum GateOutcome: Equatable {
        /// Approved and the work is on the base, as this commit when git
        /// named one.
        case approvedAndMerged(commit: String?)
        /// Approved without a merge, for a stated reason: nothing to merge, or
        /// the project does not auto-merge. The item is Done; the note says
        /// where the work actually is, so nobody reads this as delivery.
        case approvedWithoutMerge(String)
        /// The merge could not be kept. The item stays at the gate — reporting
        /// delivery over work that never landed is the defect this prevents.
        ///
        /// `verifyOutput` is what the failing verify printed, present only when
        /// that is what refused the merge. The refusal rolls the merged tree
        /// back, so this is the only surviving evidence of the failure: without
        /// it the operator's choice between retrying and rejecting is a guess.
        case mergeFailed(String, verifyOutput: String?)
        /// Approval refused because the work is not on a branch and the
        /// project's checkout is dirty — see `WorktreeManager.emptyBranchRefusal`.
        /// The item stays at the gate: "nothing to merge" and "the work never
        /// reached a branch" are different answers, and only the first is done.
        case workNotOnBranch(String)
        case rejected
    }

    /// Resolves an item's human gate: approving merges the item's branch when
    /// the project auto-merges — gated on a clean merge *and* a green verify of
    /// the merged tree — and only then marks the item Done.
    ///
    /// One implementation because the two callers had drifted: the control API's
    /// approval merged nothing while the run-based one merged, and since run
    /// records do not survive a restart, the path that did not deliver was the
    /// only one still reachable. Five items were marked Done on 2026-08-09 with
    /// their commits sitting on branches `main` had never seen.
    ///
    /// `isolationExpected` is the project's `useWorktree`. It is what lets the
    /// empty-branch case be judged: on a project that runs its items in
    /// worktrees, an item at the gate with no branch and a dirty checkout is
    /// work that never reached a branch, and approving it would mark it done
    /// over uncommitted files. With isolation off there is no branch by design
    /// and nothing here applies.
    ///
    /// `closure` names the surface, for the approval notice that resolves itself
    /// when this gate closes. It matters only on the paths that *do* close it —
    /// a refused merge leaves the item at the gate and the notice with it.
    func resolveGate(
        itemID: String,
        approve: Bool,
        reason: String = "",
        autoMerge: Bool,
        verify: MergeVerifyPlan,
        projectRoot: URL,
        isolationExpected: Bool = false,
        base: String? = nil,
        setupCommand: String? = nil,
        timeout: TimeInterval = 900,
        closure: GateClosure = .approved
    ) async -> GateOutcome {
        guard approve else {
            await rejectAtGate(itemID: itemID, reason: reason, projectRoot: projectRoot)
            return .rejected
        }
        let manager = WorktreeManager(projectRoot: projectRoot)
        let branch = WorktreeSession.branchName(for: itemID)

        if await !manager.hasUnmergedCommits(for: itemID, base: base) {
            // "Nothing to merge" covers two opposite states, and one of them is
            // not done: a branch that was merged, and an item whose work never
            // reached a branch at all. Told apart before anything is approved.
            if let refusal = await WorktreeManager.emptyBranchRefusal(
                isolationExpected: isolationExpected,
                branchExists: manager.branchExists(for: itemID),
                modified: manager.modifiedPaths()
            ) {
                recordMergeOutcome(itemID: itemID, merged: false, reason: refusal)
                return .workNotOnBranch(refusal)
            }
            // Already on the checked-out branch, or there never was one. Both
            // resolve — neither may claim a merge that did not happen.
            //
            // Deliberately unrecorded: those are opposite answers to "did the
            // work land", and this path cannot tell them apart. The run keeps a
            // nil `merged`, which is what nobody knowing looks like.
            approveAndRecordOverride(itemID: itemID, closure: closure)
            return .approvedWithoutMerge("nothing to merge — no branch, or already merged")
        }
        guard autoMerge else {
            approveAndRecordOverride(itemID: itemID, closure: closure)
            let note = "autoMergeOnApproval is off — branch \(branch) is waiting for a human merge"
            recordMergeOutcome(itemID: itemID, merged: false, reason: note)
            return .approvedWithoutMerge(note)
        }
        // The gate lands where a run's own merge lands — on the configured base
        // when there is one — so approving from the panel, the item's page or
        // the API cannot land on the checkout while the runs land elsewhere.
        return await mergeAndRecordOutcome(
            itemID: itemID, branch: branch, manager: manager,
            message: "autopilot: merge \(itemID)", verify: verify, projectRoot: projectRoot, base: base,
            setupCommand: setupCommand, timeout: timeout, closure: closure)
    }

    /// The last leg of `resolveGate`: attempts the merge, files a `## Notes`
    /// entry for whatever a retried step printed (a refusal or a recovered
    /// merge, either one — a clean pass writes nothing), and records the
    /// outcome. Split out on its own so that note-writing does not count
    /// against `resolveGate`'s own complexity.
    /// What a done item's Notes say when landing its branch was refused.
    nonisolated static func landRefusedNote(branch: String, reason: String) -> String {
        "Land refused: \(reason). The item is Done but its work is still on branch \(branch), not merged."
    }

    /// What landing a done item's branch came to — see `landDoneItem`.
    enum LandOutcome: Equatable {
        /// The branch is in the base, as this commit when git named one.
        case landed(commit: String?)
        /// No branch, or one the base already holds — nothing to do, and not
        /// a failure.
        case nothingToLand(String)
        /// The gate refused the merge; the branch is untouched.
        case refused(String, verifyOutput: String?)
    }

    /// Lands the branch of an item that is already `done` — the merge half of
    /// an approval, when the approval landed nothing. The same gate as
    /// `resolveGate`'s merge, recorded the same way in the merge ledger and
    /// the item's Notes; the item's status and approval are not touched,
    /// because both already happened.
    func landDoneItem(
        itemID: String, verify: MergeVerifyPlan, projectRoot: URL,
        base: String? = nil, setupCommand: String? = nil, timeout: TimeInterval = 900
    ) async -> LandOutcome {
        let manager = WorktreeManager(projectRoot: projectRoot)
        guard await manager.branchExists(for: itemID) else {
            return .nothingToLand("no branch — the item has no work on a branch to land")
        }
        guard await manager.hasUnmergedCommits(for: itemID, base: base) else {
            return .nothingToLand("nothing to land — the branch is already in \(base ?? "the checkout's branch")")
        }
        let outcome = await mergeAndRecordOutcome(
            itemID: itemID, branch: WorktreeSession.branchName(for: itemID), manager: manager,
            message: "autopilot: merge \(itemID)", verify: verify, projectRoot: projectRoot, base: base,
            setupCommand: setupCommand, timeout: timeout, closure: nil)
        switch outcome {
        case .approvedAndMerged(let commit): return .landed(commit: commit)
        case .mergeFailed(let why, let verifyOutput):
            // The item reads Done either way, so its Notes are the only place
            // a reader of the backlog learns the work is still not in the base.
            appendNote(itemID: itemID, Self.landRefusedNote(branch: WorktreeSession.branchName(for: itemID), reason: why))
            return .refused(why, verifyOutput: verifyOutput)
        case .approvedWithoutMerge, .workNotOnBranch, .rejected:
            return .nothingToLand("nothing to land")
        }
    }

    /// `closure` nil is a merge that is not an approval — `landDoneItem`'s,
    /// on an item already done — so the status and the approval notices are
    /// left alone; the merge itself is recorded the same way either way.
    private func mergeAndRecordOutcome(
        itemID: String, branch: String, manager: WorktreeManager,
        message: String, verify: MergeVerifyPlan, projectRoot: URL, base: String?,
        setupCommand: String? = nil, timeout: TimeInterval = 900,
        closure: GateClosure? = .approved
    ) async -> GateOutcome {
        beginGateVerify(itemID: itemID)
        let result = await manager.mergeAndVerify(branch: branch, message: message, verify: verify,
                                                   timeout: timeout, base: base, setupCommand: setupCommand)
        endGateVerify(itemID: itemID)
        let stepOutputNote = WorktreeManager.verifyStepOutputsNote(result.stepOutputs)
        if let stepOutputNote {
            appendNote(itemID: itemID, stepOutputNote)
        }
        guard result.merged else {
            // The item stays at the gate, so this is not the last word — but the
            // work has not landed, and a later approval that does merge records
            // over it.
            recordMergeOutcome(itemID: itemID, merged: false, reason: result.reason,
                              verifyOutput: stepOutputNote)
            return .mergeFailed(result.reason, verifyOutput: result.verifyOutput)
        }
        if let commit = result.mergeCommit {
            appendNote(itemID: itemID, WorktreeManager.landedNote(commit: commit, base: base))
        }
        if let closure { approveAndRecordOverride(itemID: itemID, closure: closure) }
        recordMergeOutcome(itemID: itemID, merged: true, reason: verify.summary,
                          verifyOutput: stepOutputNote, commit: result.mergeCommit)
        // The branch is inside the base now; the ref was all that was left.
        if let kept = await manager.removeMergedBranch(for: itemID, base: base) {
            backlogVMLog.info("Kept branch \(branch, privacy: .public) after the merge: \(kept, privacy: .public)")
        }
        // This merge just moved the base — exactly what can turn a sibling
        // still sitting at the gate, clean a moment ago, into one that now
        // conflicts. Refresh before anyone else reads the cache.
        await refreshGateFreshness(projectRoot: projectRoot, base: base)
        return .approvedAndMerged(commit: result.mergeCommit)
    }

    /// Files what the gate did to the item's branch against the run that built
    /// it. No `executionID`: the run ended before a human ever saw the gate, so
    /// the event is placed by time (`MergeOutcomeFold`).
    private func recordMergeOutcome(itemID: String, merged: Bool, reason: String?,
                                    verifyOutput: String? = nil, commit: String? = nil) {
        guard let store = mergeOutcomeStore,
              let path = mergeOutcomeProjectPath,
              let name = mergeOutcomeProjectName else { return }
        store.appendMergeEvent(ItemMergeEvent(
            projectPath: path,
            projectName: name,
            itemID: itemID,
            merged: merged,
            at: Date(),
            reason: reason,
            verifyOutput: verifyOutput,
            commit: commit
        ))
    }

    /// Files an override for every blocking-finding class the gate just
    /// approved over — the human saw the review's last, unresolved objection
    /// and approved anyway, which is the strongest signal a project has about
    /// whether that class of finding is worth blocking on. `RunKnowledgeDistiller`
    /// reads this ledger back at the end of a run.
    ///
    /// Reads the item's most recent measured run rather than taking the
    /// findings as a parameter: `resolveGate` is reached from three different
    /// callers (the control API, the item page, the fleet view), none of which
    /// carry the run's findings forward — the metric row already does, and it
    /// is the one thing all three read to reach this gate at all.
    private func recordFindingOverrides(itemID: String) {
        guard let store = mergeOutcomeStore, let path = mergeOutcomeProjectPath else { return }
        guard let classes = store.records
            .filter({ $0.itemID == itemID && KiteloopProject.isSamePath($0.projectPath, path) })
            .max(by: { $0.startedAt < $1.startedAt })?
            .lastReviewBlockingFindingClasses,
            !classes.isEmpty else { return }
        let url = FindingOverrideLedger.url(projectPath: path)
        for findingClass in classes {
            do {
                try FindingOverrideLedger.append(
                    FindingOverrideLedger.Record(itemID: itemID, findingClass: findingClass, at: Date()),
                    to: url)
            } catch {
                backlogVMLog.error("""
                    Failed to record finding override for \(itemID, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    /// Sends an item back for rework with feedback the next worker run reads.
    /// The item returns to Ready rather than vanishing or being marked done.
    func reject(itemID: String, reason: String) {
        guard var file = backlogFile else { return }
        for sIdx in file.sections.indices {
            guard let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == itemID }) else { continue }
            let item = file.sections[sIdx].items[iIdx]
            file.sections[sIdx].items[iIdx].status = .ready
            backlogFile = file
            writeBack()
            appendRejectionNote(to: item, reason: reason)
            return
        }
    }

    /// A person's own rejection at the approval gate — `reject`, plus what
    /// makes the reason reach further than the item's Notes: the branch's tip
    /// is tagged (`WorktreeManager.markRejected`) before the next pickup's
    /// unconditional `git branch -D` takes it (`WorktreeSession
    /// .startRefusal`), and the reason is recorded in `GateRejection` until a
    /// run of the item passes review — see `BacklogAutopilot.buildInitialState`,
    /// which is what reads it back into the next run's worker and reviewer
    /// prompts.
    ///
    /// Distinct from `reject` itself because that call is also how
    /// `CoordinatorBlockedTriage` sends a blocked item's own regroom back to
    /// Ready — an automated disposition on an item nobody rejected by hand,
    /// which must not be recorded, or read back, as though a person had.
    ///
    /// A blank reason (trimmed) records nothing beyond what `reject` already
    /// did, the same leniency `appendRejectionNote` applies to Notes.
    func rejectAtGate(itemID: String, reason: String, projectRoot: URL) async {
        reject(itemID: itemID, reason: reason)
        // The gate is closed either way: an item sent back for rework is no
        // longer waiting on anybody, so its summons goes with it.
        resolveApprovalNotices(itemID: itemID, closure: .rejected)
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let manager = WorktreeManager(projectRoot: projectRoot)
        let ref = await manager.markRejected(for: itemID)
        GateRejection.append(
            GateRejection.Record(itemID: itemID, kind: .rejected, reason: trimmed, ref: ref, at: Date()),
            to: GateRejection.url(projectPath: projectRoot.path(percentEncoded: false)))
    }

    /// Appends rejection feedback to the item's detail file so the next worker
    /// run picks it up as context instead of repeating the same mistake.
    ///
    /// A reason that is only whitespace — a UI rejection with the field left
    /// blank, or `POST /v1/runs/{id}/approve` with `approve: false` and no
    /// `reason` — writes nothing at all. "rejected:" with nothing after it says
    /// no more than the status change already did, and every such line dilutes
    /// the section a human reads to find out why an item keeps bouncing. The
    /// return to Ready is unconditional either way; only the note is skipped.
    private func appendRejectionNote(to item: BacklogItem, reason: String) {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendNote(to: item, "rejected: \(trimmed)")
    }

    /// Records a line in the item's `## Notes` without touching its status, and
    /// says whether it landed.
    ///
    /// The Notes are where a human — and the next worker run, which is handed
    /// the detail file — decides whether an item needs starting from nothing.
    /// A blocked run uses this to say that it left finished work behind, which
    /// is the difference between re-running an item and paying for the same
    /// diff twice.
    ///
    /// False for an item this backlog does not have, as well as for a note that
    /// could not be written; only the latter is reported.
    @discardableResult
    func appendNote(itemID: String, _ note: String) -> Bool {
        guard let item = item(withID: itemID) else { return false }
        return appendNote(to: item, note)
    }

    /// The one writer of `## Notes` — dates the entry, creates the section when
    /// the detail file has none, and does nothing at all without a detail file
    /// to write to. True when the entry reached the file.
    ///
    /// An empty note and an item with no detail file are both legitimate states
    /// and are silent: there is nothing to write in the first case and nowhere
    /// to write it in the second, and neither is a failure of this file.
    /// Everything else here is one — a detail file the item names but that
    /// cannot be read, and a file that cannot be written back — and both are
    /// reported through ``StoreProblemReporter``, naming the detail file. They
    /// were discarded by a `try?` apiece, which is how a rejection reason the
    /// next worker run needed came to vanish without a word.
    ///
    /// The write goes through ``AtomicFileWriter``, as the durable stores do:
    /// this file is read back by the next run, so a truncated one costs the
    /// item its whole history rather than one entry.
    @discardableResult
    private func appendNote(to item: BacklogItem, _ note: String) -> Bool {
        guard !note.trimmingCharacters(in: .whitespaces).isEmpty,
              let detailPath = item.detailPath,
              let backlogURL else { return false }
        let detailURL = backlogURL.deletingLastPathComponent().appending(path: detailPath)
        var content: String
        do {
            // Decoded lossily: one bad byte must not refuse the note.
            content = String(decoding: try Data(contentsOf: detailURL), as: UTF8.self)
        } catch {
            // Deliberately no fresh file in its place: what could not be read is
            // as easily lost by writing over it, and the note is the cheaper of
            // the two things at stake.
            reporter.report(store: Self.notesStoreName, operation: .read, url: detailURL, error: error)
            return false
        }

        let entry = "- \(DayKey.string(for: Date())) — \(Self.indentingContinuation(of: note))"

        if let headingEnd = Self.endOfNotesHeading(in: content) {
            content.insert(contentsOf: "\n\n\(entry)", at: headingEnd)
        } else {
            content += "\n\n## Notes\n\n\(entry)\n"
        }
        do {
            try AtomicFileWriter.write(Data(content.utf8), to: detailURL)
        } catch {
            reporter.report(store: Self.notesStoreName, operation: .write, url: detailURL, error: error)
            return false
        }
        return true
    }

    /// The end of the first line of `content` that is a `## Notes` heading — the
    /// section `BacklogParser` reads back as the item's notes, and where a new
    /// entry goes so it lands under the heading rather than inside it.
    ///
    /// A substring search for `"## Notes"` found three other things and wrote the
    /// entry into all of them: the middle of `## Notes for the reviewer`, which it
    /// split into a heading plus a note with ` for the reviewer` glued to its end;
    /// a `## Notes` mentioned in an earlier section's prose; and the same inside a
    /// fenced block. The parser splits detail files on lines beginning `## ` and
    /// matches the section name exactly, so in every one of those cases it read
    /// back notes that did not contain the line just written — which is how
    /// `RetryCeiling.needsNote(existingNotes:)` came to write the retirement note
    /// again at every pickup.
    ///
    /// The match is the parser's own: a line beginning `## ` whose remainder is
    /// exactly `Notes`. An indented `  ## Notes` is deliberately not a match — the
    /// parser does not treat it as a heading either, so writing there would put
    /// the entry somewhere nothing reads it back from.
    private static func endOfNotesHeading(in content: String) -> String.Index? {
        content.split(separator: "\n", omittingEmptySubsequences: false).first { line in
            line.hasPrefix("## ") && line.dropFirst(3).trimmingCharacters(in: .whitespaces) == "Notes"
        }?.endIndex
    }

    /// Indents every line of `note` after the first by two spaces, so a
    /// multi-line note — a refused approval's verify output, say — stays inside
    /// its markdown list item instead of ending the list at the first newline.
    static func indentingContinuation(of note: String) -> String {
        note.components(separatedBy: "\n")
            .enumerated()
            .map { $0.offset == 0 || $0.element.isEmpty ? $0.element : "  " + $0.element }
            .joined(separator: "\n")
    }

    // MARK: - Reconciliation

    /// Returns every item left in a mid-run stage — `active` or `inReview`, see
    /// `StaleActiveItems.midRunStages` — with no run behind it to `ready`, and
    /// says so in each one's Notes. Returns the ids it moved, so a caller can
    /// report them.
    ///
    /// Run records are in-memory, so a restart leaves any item that was running
    /// marked with the stage its run had reached and nothing executing it —
    /// stranded, because the pickup gate only takes `ready` and nothing else
    /// clears the status. Called when a
    /// project is opened (which is what launch does for every restored project),
    /// the same seam `BacklogAutopilot.reconcileStatus` uses for the autopilot's
    /// own stale busy flag.
    ///
    /// `inFlightItemID` is the item a run is genuinely executing — from
    /// `BacklogAutopilot.inFlightRun()`, the same check the busy guard makes.
    /// Reopening a project mid-run must leave that item exactly as it is.
    ///
    /// Only the status moves: the branch and worktree an interrupted run left
    /// are named in the note and otherwise untouched. A returned item is a
    /// statement about the queue, not a verdict on the work.
    @discardableResult
    func reconcileActiveItems(reason: String, inFlightItemID: String?) async -> [String] {
        let stranded = StaleActiveItems.stranded(in: backlogFile, inFlightItemID: inFlightItemID)
        guard !stranded.isEmpty else { return [] }
        let projectRoot = repoPath.map { URL(fileURLWithPath: $0) }

        var reconciled: [String] = []
        for entry in stranded {
            guard let item = item(withID: entry.id) else { continue }
            let work = await StaleActiveItems.leftBehind(itemID: entry.id, projectRoot: projectRoot)
            updateItemStatus(itemID: entry.id, newStatus: .ready)
            appendNote(to: item, StaleActiveItems.note(reason: reason, work: work))
            reconciled.append(entry.id)
            backlogVMLog.info("Returned \(entry.id, privacy: .public) to ready: \(item.status.rawValue, privacy: .public) with no run behind it (\(reason, privacy: .public))")
        }
        return reconciled
    }

    var selectedItem: BacklogItem? {
        guard let id = selectedItemID, let file = backlogFile else { return nil }
        for section in file.sections {
            if let item = section.items.first(where: { $0.id == id }) {
                return item
            }
        }
        return nil
    }

    /// The item with this id, wherever it sits. `selectedItem` does the same
    /// walk for the selection; this is the same lookup without one.
    func item(withID id: String) -> BacklogItem? {
        backlogFile?.sections.lazy.flatMap(\.items).first { $0.id == id }
    }

    func loadDetail(for item: BacklogItem) -> BacklogItemDetail? {
        guard let detailURL = detailURL(for: item) else { return nil }
        return BacklogParser.parseDetail(at: detailURL)
    }

    /// Where the item's groomed detail lives, resolved the same way `loadDetail`
    /// resolves it — relative to the backlog file, not to the project root.
    /// Nil when the item has no detail file, which is a legitimate state.
    func detailURL(for item: BacklogItem) -> URL? {
        guard let detailPath = item.detailPath, let backlogURL else { return nil }
        return backlogURL.deletingLastPathComponent().appending(path: detailPath)
    }

    /// The id Add Item and the AI editor file a new item under: past every id
    /// the file holds and every id the project has used outside it, so a new
    /// item never opens with a removed one's detail file or run history.
    func nextGeneratedItemID() -> String {
        backlogFile?.nextGeneratedItemID(takenElsewhere: idsTakenOutsideTheFile()) ?? "item-001"
    }

    /// An id for an item filed by its title — `fix-the-login`, then `-2` past
    /// a collision — kept clear of every id the file holds and every id the
    /// project has used outside it, as `nextGeneratedItemID` is. A title that
    /// slugs to nothing gets a generated id instead.
    func itemID(forTitle title: String) -> String {
        let slug = QueueRefill.Draft.slug(title)
        guard !slug.isEmpty else { return nextGeneratedItemID() }
        let inFile = (backlogFile?.sections.flatMap(\.items) ?? []).map(\.id)
        return QueueRefill.Draft.uniqueID(slug, taken: Set(inFile).union(idsTakenOutsideTheFile()))
    }

    /// Writes a grooming proposal onto its item: the detail file, and the
    /// line's `verify:` and size. Never the title, and never the status —
    /// promotion past Draft is its own gated step. A detail file already
    /// linked keeps its `## Notes`, the record of which gate parked the item.
    /// Answers why nothing was written, or nil when it was; a `verify:` the
    /// line cannot hold is refused before anything is written.
    func writeGrooming(_ proposal: BacklogGroomer.Proposal) -> String? {
        guard let item = item(withID: proposal.itemID) else { return "it is no longer in the backlog" }
        if let refusal = BacklogItemDetailViewModel.groomVerifyRefusal(proposal.draft.verify) { return refusal }
        let existingNotes = BacklogParser.plainBullets((loadDetail(for: item)?.notes ?? "").components(separatedBy: "\n"))
        let content = proposal.draft.detailMarkdown(notes: existingNotes)
        let outcome = item.detailPath != nil
            ? overwriteDetail(for: item, content: content)
            : createDetail(for: item, content: content)
        guard outcome.didFile else { return outcome.refusalReason ?? "the detail file couldn't be written" }
        updateItem(itemID: item.id, title: nil, verify: proposal.draft.verify)
        if let size = ItemSize(rawValue: proposal.draft.size.uppercased()) {
            updateItemSize(itemID: item.id, size: size)
        }
        return nil
    }

    /// Detail files under `backlog/` and this project's task-metric records.
    /// Whether the project has used `id` for an item that is no longer in
    /// the backlog file: one with a detail file or a merge on record.
    func hasUsedID(_ id: String) -> Bool {
        idsTakenOutsideTheFile().contains(id)
    }

    private func idsTakenOutsideTheFile() -> Set<String> {
        var ids = Set<String>()
        if let backlogURL {
            let dir = backlogURL.deletingLastPathComponent().appending(path: "backlog")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
            ids.formUnion(names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
        }
        if let store = mergeOutcomeStore, let path = mergeOutcomeProjectPath {
            ids.formUnion(store.records
                .filter { KiteloopProject.isSamePath($0.projectPath, path) }
                .map(\.itemID))
        }
        return ids
    }

    /// Scaffolds a Jira-style detail file for an item (What / How / Validation)
    /// under backlog/<id>.md and links it from the item line.
    ///
    /// `content` writes a body that is already groomed instead of the empty
    /// template — the coordinator files an item and its detail in one step, and
    /// a scaffold it would immediately overwrite helps nobody.
    ///
    /// Answers with what landed, so a caller that reports the write — Apply on
    /// a grooming — can say it did not rather than claim the item groomed.
    @discardableResult
    func createDetail(for item: BacklogItem, content: String? = nil) -> FilingOutcome {
        guard let backlogURL else { return .noBacklogOpen }
        guard item.detailPath == nil else { return .detailWriteFailed("a detail file is already linked") }
        let dir = backlogURL.deletingLastPathComponent().appending(path: "backlog")
        let detailURL = dir.appending(path: "\(item.id).md")
        // Quoted by the writer paired with the reader that resolves it, rather
        // than by hand: an item line's verify may carry a backslash or a quote,
        // and written raw it came back off disk as a different command.
        let verify = BacklogParser.doubleQuotedScalarLiteral(
            item.verify ?? backlogFile?.verifyDefault ?? "echo replace-me")
        let scaffold = """
        ---
        id: \(item.id)
        title: \(item.title)
        verify:
          - name: build
            cmd: \(verify)
        ---

        ## What

        Describe the outcome: what exists (or behaves differently) when this item is done.

        ## How

        Suggested approach — files to touch, patterns to follow, pitfalls to avoid.
        Agents treat this as guidance, not a mandate.

        ## Validation

        - [ ] First observable behavior that proves it works
        - [ ] Second criterion; each becomes a checklist item for the agent and reviewer

        ## Out of Scope

        - Things a well-meaning agent might do but shouldn't
        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try AtomicFileWriter.write(Data((content ?? scaffold).utf8), to: detailURL)
        } catch {
            backlogVMLog.error("Failed to create detail file: \(error.localizedDescription)")
            operationMessage = "Couldn't create detail file: \(error.localizedDescription)"
            return .detailWriteFailed(error.localizedDescription)
        }

        guard var file = backlogFile else { return .noBacklogOpen }
        for sIdx in file.sections.indices {
            if let iIdx = file.sections[sIdx].items.firstIndex(where: { $0.id == item.id }) {
                file.sections[sIdx].items[iIdx].detailPath = "backlog/\(item.id).md"
                backlogFile = file
                return writeBack().map { .backlogWriteFailed($0) } ?? .filed
            }
        }
        return .backlogWriteFailed("\(item.id) is no longer in the backlog")
    }

    /// What a write that appends an item did, and — when it wrote nothing —
    /// which refusal it was. `fileGroomedItem` returns all five; `addItem`,
    /// which writes no detail file and reads no write result, returns the first
    /// three.
    ///
    /// One `Bool` used to answer for all three, so everything downstream had to
    /// guess which had happened and guessed the same way: a human approving a
    /// coordinator proposal was told the backlog write hadn't landed when the
    /// truth was that the id was already there, and a bounded refill pass
    /// counted the proposal it dropped as nothing at all. They are different
    /// facts — one is work that already exists, one is a disk that wouldn't take
    /// the write — and only the caller knows what to do with each.
    enum FilingOutcome: Sendable, Equatable {
        /// The backlog line is written — and, from `fileGroomedItem`, its
        /// `backlog/<id>.md` with it.
        case filed
        /// No backlog is loaded, so there is nothing to append to. Nothing is
        /// created either — this is not the moment to invent a `BACKLOG.md`.
        case noBacklogOpen
        /// An item with this id is already in the file. A second would shadow
        /// it, so nothing is written.
        case duplicateID
        /// The title was empty, or nothing but whitespace.
        case emptyTitle
        /// The title holds the line's field separator. The line would not
        /// parse back: the title would be cut at the separator and the rest
        /// read as an unrecognised field.
        case holdsFieldSeparator
        /// `backlog/<id>.md` couldn't be written, carrying what the filesystem
        /// said. The line isn't appended either: an item whose detail is missing
        /// fails the gate at pickup.
        case detailWriteFailed(String)
        /// `BACKLOG.md` itself couldn't be written, carrying what the filesystem
        /// said. The detail file did land, so what is left behind is an orphan
        /// `backlog/<id>.md` with no line pointing at it — which is why this is
        /// not `.filed`: nothing that reads the backlog can see the item, so a
        /// caller told it was filed has recorded work that does not exist.
        case backlogWriteFailed(String)

        var didFile: Bool { self == .filed }

        /// Why nothing was written, as a phrase that reads after "couldn't file
        /// `<id>`". Nil when it was written.
        var refusalReason: String? {
            switch self {
            case .filed: return nil
            case .noBacklogOpen: return "no backlog is open"
            case .duplicateID: return "that id is already in the backlog"
            case .emptyTitle: return "an item needs a title"
            case .holdsFieldSeparator:
                return "a title can't contain “\(DefinitionOfReady.fieldSeparator)”, the backlog line's field separator"
            case .detailWriteFailed(let message): return "the detail file couldn't be written: \(message)"
            case .backlogWriteFailed(let message): return "the backlog file couldn't be written: \(message)"
            }
        }
    }

    /// Files an already-groomed item: writes `backlog/<id>.md` and appends the
    /// backlog line with its detail linked and its status set.
    ///
    /// `addItem` deliberately can't do this — it creates the empty line a human
    /// then grooms, and takes its status from the project's flow. The coordinator's
    /// refill loop arrives with the whole item already written and already gated,
    /// and the status it asks for is the gate's verdict, not the flow's default.
    ///
    /// Writes nothing unless it returns `.filed`, and names which refusal it was
    /// otherwise — a caller that files by loop has to be able to tell a refusal
    /// from a success, and which refusal, rather than assume.
    @discardableResult
    /// - Parameter from: the item this one was discovered from, when the draft
    ///   came out of breaking one down or regrooming a failed one. Stamped on the
    ///   line as `from:<id>`; nil for work that came from nowhere in particular.
    /// - Parameter needs: the items this one has to wait for. Stamped on the line
    ///   as `needs:<id>`, which is what withholds it at pickup until they are
    ///   `done` — so a pass that splits work into ordered pieces files the order
    ///   along with them rather than leaving both equally runnable.
    func fileGroomedItem(sectionName: String, id: String, title: String, size: ItemSize?,
                         verify: String?, status: BacklogItemStatus,
                         from: String? = nil,
                         needs: [String] = [],
                         detailMarkdown: String) -> FilingOutcome {
        guard var file = backlogFile, let backlogURL else { return .noBacklogOpen }
        guard !file.sections.flatMap(\.items).contains(where: { $0.id == id }) else {
            backlogVMLog.error("Refused to file \(id): id already in the backlog")
            return .duplicateID
        }

        let dir = backlogURL.deletingLastPathComponent().appending(path: "backlog")
        let detailURL = dir.appending(path: "\(id).md")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try AtomicFileWriter.write(Data(detailMarkdown.utf8), to: detailURL)
        } catch {
            backlogVMLog.error("Failed to write detail for \(id): \(error.localizedDescription)")
            operationMessage = "Couldn't write backlog/\(id).md: \(error.localizedDescription)"
            return .detailWriteFailed(error.localizedDescription)
        }

        var item = BacklogItem(id: id, title: title, verify: verify ?? file.verifyDefault,
                               status: status, type: .local)
        item.size = size
        item.detailPath = "backlog/\(id).md"
        item.from = from
        item.needs = needs

        if let idx = file.sections.firstIndex(where: { $0.name == sectionName }) {
            file.sections[idx].items.append(item)
        } else {
            file.sections.append(BacklogSection(name: sectionName, items: [item]))
        }
        backlogFile = file
        // The one caller that reads the write's verdict. A `BACKLOG.md` the
        // filesystem wouldn't take leaves the item nowhere a reader can find it,
        // and reporting that as filed had the coordinator record a filing, tell
        // a human the item existed, and leave the queue without it.
        if let failure = writeBack() { return .backlogWriteFailed(failure) }
        return .filed
    }

    /// Overwrites the detail file an item already has — `applyGroom()`'s write,
    /// for a draft a grooming pass parked with `backlog/<id>.md` already linked.
    /// `createDetail` only ever scaffolds one that doesn't exist yet and guards
    /// on exactly that; this is its mirror image, for the file already there,
    /// and never touches the backlog line since the link needs no change.
    ///
    /// - Returns: `.filed` once the write lands; `.detailWriteFailed` with what
    ///   the filesystem said otherwise — so a caller can tell the two apart
    ///   instead of reporting the item groomed either way.
    @discardableResult
    func overwriteDetail(for item: BacklogItem, content: String) -> FilingOutcome {
        guard let detailURL = detailURL(for: item) else {
            return .detailWriteFailed("no detail file is linked for this item")
        }
        do {
            try AtomicFileWriter.write(Data(content.utf8), to: detailURL)
            return .filed
        } catch {
            backlogVMLog.error("Failed to overwrite detail for \(item.id): \(error.localizedDescription)")
            return .detailWriteFailed(error.localizedDescription)
        }
    }

    func writeBackPublic() {
        writeBack()
    }

    /// Persists `backlogFile` to `backlogURL`, answering with what the write
    /// failed on — nil when it landed.
    ///
    /// A `String` rather than a `Bool` because the one caller that reads it has
    /// to say what went wrong, not only that something did; and a returned value
    /// rather than a thrown one because every other caller here is a UI mutation
    /// with nothing to do about a failure but the `operationMessage` this already sets.
    @discardableResult
    private func writeBack() -> String? {
        // Nothing loaded is nothing to fail at. The one caller that reads the
        // result has already refused that case as `.noBacklogOpen`.
        guard let file = backlogFile, let url = backlogURL else { return nil }
        // Every in-app mutation funnels through here, so this is where an
        // approval or a reopen made in Kiteloop is seen.
        escapedDefects?.observe(file)
        refreshQueueHealth()
        if keptLines?.url != url {
            keptLines = (url, BacklogKeptLineReport(reporter: reporter, url: url))
        }
        let content = BacklogSerializer.$keptLines.withValue(keptLines?.report) {
            BacklogSerializer.serialize(file)
        }
        do {
            try AtomicFileWriter.write(Data(content.utf8), to: url)
            backlogVMLog.info("Wrote backlog file: \(url.path())")
            // An edit that landed answers whatever the last refused one said.
            operationMessage = nil
            // Branch-backed: every write becomes a commit on the shared branch
            // (push is rate-limited inside). Off the main actor — a push can
            // take a network round-trip.
            if let root = branchProjectRoot {
                Task.detached(priority: .utility) {
                    BacklogBranch.commitChanges(projectRoot: root, message: "kiteloop: backlog update")
                }
            }
            return nil
        } catch {
            // `String(describing:)` rather than `localizedDescription`:
            // `AtomicFileWriter.WriteError` is a plain enum, for which
            // Foundation synthesises "The operation couldn't be completed.
            // (Kiteloop.AtomicFileWriter.WriteError error 0.)" — naming neither
            // the syscall nor the errno, while the case itself names both. A
            // bridged `NSError` still carries its localized description inside it.
            let message = String(describing: error)
            backlogVMLog.error("Failed to write backlog: \(message)")
            operationMessage = "Write failed: \(message)"
            return message
        }
    }
}

/// Turns a refused approval into the rejection feedback the next worker run reads.
///
/// The reason on its own — "verify failed on merged tree" — is what the operator
/// was already looking at, and it tells the next run nothing it can act on:
/// the refusal rolled the merged tree back, so the failure is not reproducible
/// from the repository as the worker finds it. Carrying the output across is the
/// difference between a run that starts at the failure and one that starts by
/// hunting for it.
enum GateRefusalEvidence {
    /// Lines of output kept in the note. The captured tail can be hundreds of
    /// lines of xcodebuild; a backlog detail file is read by a human, and the
    /// failure is at the end.
    static let maxOutputLines = 40

    /// `reason`, plus the tail of `verifyOutput` as a fenced block when there is
    /// one. Just the reason when the refusal produced no output — a dirty tree
    /// or a merge conflict never ran a command.
    static func feedback(reason: String, verifyOutput: String?) -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = (verifyOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return reason }
        return "\(reason)\n\n```\n\(lastLines(of: output, limit: maxOutputLines))\n```"
    }

    /// The last `limit` lines of `output`, saying how many were dropped.
    static func lastLines(of output: String, limit: Int) -> String {
        let lines = output.components(separatedBy: "\n")
        guard lines.count > limit else { return output }
        let omitted = lines.count - limit
        return (["… (\(omitted) earlier lines omitted)"] + lines.suffix(limit)).joined(separator: "\n")
    }
}
