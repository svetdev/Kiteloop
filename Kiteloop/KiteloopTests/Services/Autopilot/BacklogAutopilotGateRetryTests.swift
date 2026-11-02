import XCTest
import KiteloopCore
@testable import Kiteloop

/// The observing half of the gate retry loop: `BacklogAutopilot.retryGateMerges`,
/// exercised against a real git repository the way `WorktreeManagerTests`
/// exercises the merge/rebase mechanics it reuses.
///
/// Every scenario here starts from an item already parked at
/// `awaiting-approval` with a recorded failed merge attempt — the state a
/// live run's own auto-merge (or a human's `resolveGate`) would have already
/// left behind — and asks only what the retry loop does *next*, on its own
/// trigger.
@MainActor
final class BacklogAutopilotGateRetryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "gate-retry-autopilot")
    }

    /// The key the retry loop's ledgers file entries under — canonical, since
    /// `retryGateMerges` now canonicalises before it ever touches a ledger.
    /// `tempDir.path(percentEncoded: false)` itself carries a trailing slash
    /// (a directory-flagged `URL`'s own spelling), so asserting against the
    /// raw path would just trade one hardcoded spelling for another.
    private var canonicalProjectPath: String {
        KiteloopProject.canonicalPath(tempDir.path(percentEncoded: false))
    }

    // MARK: - git helpers (mirrors WorktreeManagerTests)

    private func initGitRepo(at url: URL) {
        git(["init"], in: url)
        git(["config", "user.email", "test@test.com"], in: url)
        git(["config", "user.name", "Test"], in: url)
        try? "v0".write(to: url.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["add", "."], in: url)
        git(["commit", "-m", "init"], in: url)
    }

    @discardableResult
    private func git(_ args: [String], in url: URL) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Builds `kiteloop/<itemID>` off the current tip with two commits that
    /// touch `README.md`, then removes the worktree — the shape
    /// `testAConflictTheRebaseCanResolveLandsWithNoOneAsked` builds too, since
    /// this loop leans on the exact same recovery.
    private func makeItemBranch(itemID: String, firstContent: String, secondContent: String) async throws {
        initGitRepo(at: tempDir)
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: itemID)
        try firstContent.write(to: path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: itemID, message: "first change")
        try secondContent.write(to: path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: itemID, message: "second change")
        await manager.removeWorktree(for: itemID, keepBranch: true)
    }

    private func writeBacklog(itemID: String, title: String = "Some item") throws {
        let backlog = """
        ---
        project: demo
        ---

        # Demo Backlog

        ## Epic: Now

        - [ ] \(itemID) | \(title) | awaiting-approval → [detail](backlog/\(itemID).md)
        """
        try backlog.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let detailDir = tempDir.appending(path: "backlog")
        try FileManager.default.createDirectory(at: detailDir, withIntermediateDirectories: true)
        try "# \(title)\n\nWhat: test item.\n".write(
            to: detailDir.appending(path: "\(itemID).md"), atomically: true, encoding: .utf8)
    }

    /// Wires an autopilot and its backlog view model against `tempDir`, with
    /// the gate set to clear itself unattended — the only configuration this
    /// loop ever acts under — and the retry ledger redirected to a temp file.
    /// `autopilotProjectPath` lets a test configure the autopilot itself under
    /// a different spelling of `tempDir` than the one the backlog view model
    /// and merge-event writer use — the mismatch `KiteloopProject.canonicalPath`
    /// exists to paper over.
    private func makeAutopilot(
        itemID: String, metricStore: TaskMetricStore, autopilotProjectPath: String? = nil
    ) throws -> (BacklogAutopilot, BacklogViewModel) {
        let projectPath = tempDir.path(percentEncoded: false)
        let vm = BacklogViewModel(globalConfigStore: GlobalConfigStore(
            storageURL: tempDir.appending(path: "global-config.json")))
        vm.loadForProject(repoPath: projectPath)
        vm.configureMergeOutcomeRecording(store: metricStore, projectPath: projectPath, projectName: "demo")

        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: vm,
            configURL: tempDir.appending(path: "autopilot-config.json"),
            metricStore: metricStore,
            projectPath: autopilotProjectPath ?? projectPath,
            projectName: "demo"
        )
        autopilot.approvalGate = .land
        autopilot.autoMergeVerifyCommand = "true"
        autopilot.stageGateRetryLedgerURLForTesting(
            tempDir.appending(path: "gate-retry.jsonl"))
        return (autopilot, vm)
    }

    private func makeMetricStore() -> TaskMetricStore {
        TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
            mergesURL: tempDir.appending(path: "task-merges.jsonl"))
    }

    private func recordOriginalFailure(
        store: TaskMetricStore, itemID: String, reason: String, projectPath: String? = nil
    ) {
        store.appendMergeEvent(ItemMergeEvent(
            projectPath: projectPath ?? tempDir.path(percentEncoded: false), projectName: "demo",
            itemID: itemID, merged: false, at: Date(), reason: reason))
    }

    // MARK: - A conflict the rebase can resolve lands with no one asked

    /// The item's own scenario: a branch that conflicted with the base a
    /// sibling's landing moved is retried, rebases clean, merges and reaches
    /// Done — with the ledger showing exactly one retry.
    func testAConflictingBranchMergesOnRetryAndTheLedgerShowsOneRetry() async throws {
        try await makeItemBranch(itemID: "item-2", firstContent: "v1", secondContent: "v2")
        // A sibling lands, by hand, exactly the branch's first-commit change —
        // the same shape `testAConflictTheRebaseCanResolveLandsWithNoOneAsked`
        // sets up, so a straight merge conflicts but a rebase does not.
        try "v1".write(to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "sibling lands the same change"], in: tempDir)

        try writeBacklog(itemID: "item-2")
        let store = makeMetricStore()
        recordOriginalFailure(store: store, itemID: "item-2", reason: "merge conflict in: README.md")
        let (autopilot, vm) = try makeAutopilot(itemID: "item-2", metricStore: store)

        await autopilot.retryGateMergesForTesting(backlog: vm, projectRoot: tempDir)

        XCTAssertEqual(vm.item(withID: "item-2")?.status, .done)
        XCTAssertEqual(
            try String(contentsOf: tempDir.appending(path: "README.md"), encoding: .utf8), "v2")

        let ledger = GateRetry.Ledger.load(from: tempDir.appending(path: "gate-retry.jsonl"))
        XCTAssertEqual(ledger.attempts(project: canonicalProjectPath, itemID: "item-2"), 1)
    }

    // MARK: - A red verify is never retried

    /// The merged tree's own verify failing is a verdict about the work, not
    /// about the base it would land on — no retry can fix it, so the loop
    /// must not attempt one, and the item's Notes have to say why.
    func testAVerifyRedItemIsNeverRetriedAndItsNoteExplainsTheExclusion() async throws {
        try await makeItemBranch(itemID: "item-3", firstContent: "v1", secondContent: "v1-plus-more")

        try writeBacklog(itemID: "item-3")
        let store = makeMetricStore()
        recordOriginalFailure(
            store: store, itemID: "item-3",
            reason: "verify failed on merged tree (merge-verify: swift build)")
        let (autopilot, vm) = try makeAutopilot(itemID: "item-3", metricStore: store)
        // A verify that always fails, so a mistaken retry would be caught —
        // this must never even be asked to run.
        autopilot.autoMergeVerifyCommand = "false"

        await autopilot.retryGateMergesForTesting(backlog: vm, projectRoot: tempDir)

        XCTAssertEqual(vm.item(withID: "item-3")?.status, .awaitingApproval,
                       "a red verify must leave the item at the gate, not attempt to land it")
        let detail = try String(
            contentsOf: tempDir.appending(path: "backlog/item-3.md"), encoding: .utf8)
        XCTAssertTrue(detail.contains("## Notes"), detail)
        XCTAssertTrue(detail.contains("verify"), detail)

        // Never attempted, so the ledger has no retry entry for it — only the
        // exclusion.
        let ledger = GateRetry.Ledger.load(from: tempDir.appending(path: "gate-retry.jsonl"))
        XCTAssertEqual(ledger.attempts(project: canonicalProjectPath, itemID: "item-3"), 0)
        XCTAssertTrue(ledger.isExcluded(project: canonicalProjectPath, itemID: "item-3"))
    }

    /// The dedup this loop needs to not spam the same exclusion on every
    /// trigger: a second sweep over an already-excluded item writes nothing
    /// further.
    func testAnAlreadyExcludedItemIsNotNotedAgain() async throws {
        try await makeItemBranch(itemID: "item-4", firstContent: "v1", secondContent: "v1-plus-more")
        try writeBacklog(itemID: "item-4")
        let store = makeMetricStore()
        recordOriginalFailure(
            store: store, itemID: "item-4", reason: "verify failed on merged tree (x)")
        let (autopilot, vm) = try makeAutopilot(itemID: "item-4", metricStore: store)

        await autopilot.retryGateMergesForTesting(backlog: vm, projectRoot: tempDir)
        let afterFirst = try String(
            contentsOf: tempDir.appending(path: "backlog/item-4.md"), encoding: .utf8)

        await autopilot.retryGateMergesForTesting(backlog: vm, projectRoot: tempDir)
        let afterSecond = try String(
            contentsOf: tempDir.appending(path: "backlog/item-4.md"), encoding: .utf8)

        XCTAssertEqual(afterFirst, afterSecond, "a second sweep must not add a second exclusion note")
    }

    // MARK: - An item with no failure on record yet is never locked out

    /// The regression this loop shipped with once: `accept()` fires the same
    /// freshness trigger this loop rides *before* an item's own first merge
    /// is ever attempted, so the very first sweep over a freshly-gated item
    /// finds no merge event at all. Reading that as a permanent exclusion —
    /// as an earlier version of `GateRetry.classify` did — would lock the
    /// item out before it ever had a real failure to retry from. A sweep with
    /// nothing on record must leave the item untouched and unrecorded, so a
    /// later sweep — once a real failure exists — can still retry it.
    func testAnItemWithNoMergeEventYetIsUntouchedAndStillRetriesOnceOneExists() async throws {
        try await makeItemBranch(itemID: "item-6", firstContent: "v1", secondContent: "v2")
        try "v1".write(to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "sibling lands the same change"], in: tempDir)

        try writeBacklog(itemID: "item-6")
        let store = makeMetricStore()
        // No merge event recorded yet — the item just reached the gate.
        let (autopilot, vm) = try makeAutopilot(itemID: "item-6", metricStore: store)

        await autopilot.retryGateMergesForTesting(backlog: vm, projectRoot: tempDir)

        XCTAssertEqual(vm.item(withID: "item-6")?.status, .awaitingApproval,
                       "nothing to retry yet — the item must be left exactly as it was")
        let ledgerURL = tempDir.appending(path: "gate-retry.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path(percentEncoded: false)),
                       "a sweep with nothing on record must write nothing to the ledger")

        // The item's own first attempt now fails, the way a live run's would.
        recordOriginalFailure(store: store, itemID: "item-6", reason: "merge conflict in: README.md")
        await autopilot.retryGateMergesForTesting(backlog: vm, projectRoot: tempDir)

        XCTAssertEqual(vm.item(withID: "item-6")?.status, .done,
                       "now that a real failure is on record, the same loop retries and lands it")
        let ledger = GateRetry.Ledger.load(from: ledgerURL)
        XCTAssertEqual(ledger.attempts(project: canonicalProjectPath, itemID: "item-6"), 1)
    }

    // MARK: - Off is a human gate

    /// With `autoMergeOnApproval` off the loop must do nothing at all — the
    /// same coupling that stops a live run's own first attempt.
    func testWithAutoMergeOffTheLoopDoesNothing() async throws {
        try await makeItemBranch(itemID: "item-5", firstContent: "v1", secondContent: "v2")
        try "v1".write(to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "sibling lands the same change"], in: tempDir)

        try writeBacklog(itemID: "item-5")
        let store = makeMetricStore()
        recordOriginalFailure(store: store, itemID: "item-5", reason: "merge conflict in: README.md")
        let (autopilot, vm) = try makeAutopilot(itemID: "item-5", metricStore: store)
        autopilot.approvalGate = .propose

        await autopilot.retryGateMergesForTesting(backlog: vm, projectRoot: tempDir)

        XCTAssertEqual(vm.item(withID: "item-5")?.status, .awaitingApproval)
        let ledger = GateRetry.Ledger.load(from: tempDir.appending(path: "gate-retry.jsonl"))
        XCTAssertEqual(ledger.attempts(project: canonicalProjectPath, itemID: "item-5"), 0)
    }

    // MARK: - Canonicalisation: one folder is one project however it was spelled

    /// The item's own regression: the writer recorded the failed merge under
    /// a trailing-slash spelling of this project's path — the spelling the
    /// item's own comment traces to NSOpenPanel — while the project is
    /// configured (here, deliberately, for this test) under the canonical
    /// one. A raw string compare would find no attempt on record and leave
    /// the item parked forever; the loop must still find it and retry.
    func testAMergeEventRecordedWithATrailingSlashIsFoundAndRetried() async throws {
        try await makeItemBranch(itemID: "item-7", firstContent: "v1", secondContent: "v2")
        try "v1".write(to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "sibling lands the same change"], in: tempDir)

        try writeBacklog(itemID: "item-7")
        let store = makeMetricStore()
        recordOriginalFailure(
            store: store, itemID: "item-7", reason: "merge conflict in: README.md",
            projectPath: canonicalProjectPath + "/")
        let (autopilot, vm) = try makeAutopilot(
            itemID: "item-7", metricStore: store, autopilotProjectPath: canonicalProjectPath)

        await autopilot.retryGateMergesForTesting(backlog: vm, projectRoot: tempDir)

        XCTAssertEqual(vm.item(withID: "item-7")?.status, .done,
                       "a merge event recorded under the other spelling of this project's path "
                       + "must still be read as this project's own last attempt")
    }

    /// The lifetime ceiling `GateRetry.Ledger.attempts` enforces must not
    /// reset just because a prior sweep wrote its entries under the other
    /// spelling of the same folder — otherwise a relaunch (or a config edit)
    /// that changes which spelling is configured hands an already-exhausted
    /// item a fresh allowance.
    func testAttemptsRecordedUnderTheOtherSpellingStillCountTowardTheCeiling() async throws {
        try await makeItemBranch(itemID: "item-8", firstContent: "v1", secondContent: "v1-plus-more")
        try writeBacklog(itemID: "item-8")
        let store = makeMetricStore()
        recordOriginalFailure(store: store, itemID: "item-8", reason: "merge conflict in: README.md")
        let (autopilot, vm) = try makeAutopilot(
            itemID: "item-8", metricStore: store, autopilotProjectPath: canonicalProjectPath)

        let ledgerURL = tempDir.appending(path: "gate-retry.jsonl")
        let slashSpelling = canonicalProjectPath + "/"
        for _ in 0..<3 {
            GateRetry.Ledger.append(
                GateRetry.Ledger.Entry(at: Date(), project: slashSpelling, itemID: "item-8",
                                       disposition: GateRetry.Ledger.Entry.retryDisposition, reason: "retry"),
                to: ledgerURL)
        }

        await autopilot.retryGateMergesForTesting(backlog: vm, projectRoot: tempDir)

        XCTAssertEqual(vm.item(withID: "item-8")?.status, .awaitingApproval,
                       "three attempts already spent under the other spelling must still trip the ceiling")
        let detail = try String(contentsOf: tempDir.appending(path: "backlog/item-8.md"), encoding: .utf8)
        XCTAssertTrue(detail.contains("ceiling"), detail)
    }

    /// The other side of canonicalisation: a merge event that genuinely
    /// belongs to a different project — not just a different spelling of this
    /// one — must still not be read as this project's own attempt.
    func testAMergeEventForADifferentProjectIsNotReadForThisOne() async throws {
        try await makeItemBranch(itemID: "item-9", firstContent: "v1", secondContent: "v2")
        try "v1".write(to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "sibling lands the same change"], in: tempDir)

        try writeBacklog(itemID: "item-9")
        let store = makeMetricStore()
        let otherProject = tempDir.deletingLastPathComponent()
            .appending(path: "a-different-project").path(percentEncoded: false)
        recordOriginalFailure(
            store: store, itemID: "item-9", reason: "merge conflict in: README.md",
            projectPath: otherProject)
        let (autopilot, vm) = try makeAutopilot(itemID: "item-9", metricStore: store)

        await autopilot.retryGateMergesForTesting(backlog: vm, projectRoot: tempDir)

        XCTAssertEqual(vm.item(withID: "item-9")?.status, .awaitingApproval,
                       "a merge event recorded against a different project must not be read as this "
                       + "project's own last attempt")
    }
}
