import XCTest
import KiteloopCore
@testable import Kiteloop

/// Salvaging a run that ended early (cost cap, stall, retry ceiling) but whose
/// verify still passes: which command decides it, and running that command
/// against the run's worktree. A worker cut short by a turn cap is never
/// salvaged — `BacklogAutopilot.workerCutShortTurns` is what skips it.
@MainActor
final class AutopilotSalvageTests: XCTestCase {

    /// The project root the pre-review gate's verify runs in when a run has no
    /// worktree of its own. Made per test, never under `~/.kiteloop`.
    private var projectRoot: URL!
    /// Retained here: the autopilot holds its view model weakly, and a note
    /// written to a deallocated one is a silent no-op.
    private var backlog: BacklogViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectRoot = try makeTemporaryDirectory(prefix: "autopilot-verify-root")
    }

    override func tearDown() {
        projectRoot = nil
        backlog = nil
        super.tearDown()
    }

    private func item(verify: String?) -> BacklogItem {
        BacklogItem(id: "sync-dedup-guard", title: "Guard sync dedup",
                    verify: verify, status: .active, type: .local)
    }

    private func detail(verify: [BacklogItemDetail.VerifyCommand]) -> BacklogItemDetail {
        BacklogItemDetail(id: "sync-dedup-guard", title: "Guard sync dedup",
                          verifyCommands: verify,
                          acceptanceCriteria: [], outOfScope: [])
    }

    // MARK: - Command selection

    func testGroomedVerifyCommandsAllMustPass() {
        let command = BacklogAutopilot.salvageVerifyCommand(
            item: item(verify: "make build"),
            detail: detail(verify: [.init(name: "build", cmd: "xcodebuild build", expect: nil),
                                    .init(name: "test", cmd: "xcodebuild test", expect: nil)])
        )
        XCTAssertEqual(command, "xcodebuild build && xcodebuild test")
    }

    func testFallsBackToItemVerifyWhenNoDetail() {
        XCTAssertEqual(
            BacklogAutopilot.salvageVerifyCommand(item: item(verify: "make build"), detail: nil),
            "make build"
        )
    }

    func testFallsBackToItemVerifyWhenDetailHasBlankCommands() {
        let command = BacklogAutopilot.salvageVerifyCommand(
            item: item(verify: "make build"),
            detail: detail(verify: [.init(name: "empty", cmd: "  ", expect: nil)])
        )
        XCTAssertEqual(command, "make build")
    }

    func testNilWhenItemDeclaresNoVerify() {
        // No objective bar means nothing to salvage on — the item stays blocked.
        XCTAssertNil(BacklogAutopilot.salvageVerifyCommand(item: item(verify: nil), detail: detail(verify: [])))
        XCTAssertNil(BacklogAutopilot.salvageVerifyCommand(item: item(verify: "   "), detail: nil))
    }

    // MARK: - Running verify in the run's worktree

    func testRunVerifyRunsInsideTheWorktree() async throws {
        let root = try makeGitRepo()
        let manager = WorktreeManager(projectRoot: root)
        let worktree = try await manager.create(for: "capped-item")

        // Uncommitted work — exactly the state a cost-capped run leaves behind.
        try "salvaged".write(to: worktree.appending(path: "artifact.txt"),
                             atomically: true, encoding: .utf8)

        let passed = await manager.runVerify(for: "capped-item", command: "test -f artifact.txt")
        XCTAssertTrue(passed)

        let failed = await manager.runVerify(for: "capped-item", command: "test -f missing.txt")
        XCTAssertFalse(failed)
    }

    func testRunVerifyFalseWhenWorktreeMissing() async throws {
        let root = try makeGitRepo()
        let manager = WorktreeManager(projectRoot: root)

        let passed = await manager.runVerify(for: "never-created", command: "true")
        XCTAssertFalse(passed)
    }

    // MARK: - The verify verdict on the record

    /// The acceptance criterion, at the gate it is decided at: a red verify ends
    /// the run before the reviewer ever reads the diff, and what it answered is
    /// on the record rather than left to the worker's account of it.
    func testARedVerifyShutsTheGateAndIsRecorded() async throws {
        let autopilot = try configuredAutopilot(verify: "echo 'the tab case cannot pass' && exit 3")

        let allowed = await autopilot.verifyAllowsReviewForTesting(worktree: nil)

        XCTAssertFalse(allowed, "a run whose verify is red must never reach the reviewer")
        XCTAssertEqual(autopilot.closedReviewGateSignalForTesting, "verify failed (exit 3)")
        let verdict = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting)
        XCTAssertEqual(verdict.exitStatus, 3)
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.command, "echo 'the tab case cannot pass' && exit 3")
        XCTAssertEqual(verdict.directory, projectRoot.path(percentEncoded: false))
        XCTAssertTrue(verdict.outputTail.contains("the tab case cannot pass"),
                      "the last lines are what makes the verdict auditable")
        XCTAssertFalse(verdict.timedOut)
    }

    /// A green one is recorded just the same. A pass nobody wrote down is the
    /// gap this exists to close: it reads identically to a verify that never ran.
    func testAGreenVerifyOpensTheGateAndIsStillRecorded() async throws {
        let autopilot = try configuredAutopilot(verify: "echo all-green")

        let allowed = await autopilot.verifyAllowsReviewForTesting(worktree: nil)

        XCTAssertTrue(allowed)
        XCTAssertNil(autopilot.closedReviewGateSignalForTesting)
        let verdict = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting)
        XCTAssertEqual(verdict.exitStatus, 0)
        XCTAssertTrue(verdict.passed)
        XCTAssertEqual(verdict.outputTail, "all-green")
    }

    /// An item declaring no `verify:` has nothing to measure. The review runs, as
    /// it always did, and the record stays nil — which is not an exit status of 0.
    func testAnItemWithNoVerifyIsLetThroughWithNoVerdict() async throws {
        let autopilot = try configuredAutopilot(verify: nil)

        let allowed = await autopilot.verifyAllowsReviewForTesting(worktree: nil)

        XCTAssertTrue(allowed)
        XCTAssertNil(autopilot.lastVerifyVerdictForTesting)
        XCTAssertNil(autopilot.closedReviewGateSignalForTesting)
    }

    /// The verify runs in the run's own worktree, not in the project root — the
    /// distinction `directory` is on the record to make checkable afterwards.
    func testTheVerifyRunsInTheRunsWorktree() async throws {
        let autopilot = try configuredAutopilot(verify: "test -f artifact.txt")
        let worktree = try makeTemporaryDirectory(prefix: "autopilot-verify-worktree")
        try "salvaged".write(to: worktree.appending(path: "artifact.txt"),
                             atomically: true, encoding: .utf8)

        let allowed = await autopilot.verifyAllowsReviewForTesting(worktree: worktree)
        XCTAssertTrue(allowed)

        let verdict = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting)
        XCTAssertEqual(verdict.directory, worktree.path(percentEncoded: false))
    }

    /// The note the item keeps, beside what the review and the merge gate write
    /// there — the first place a person looks when a green gate is in doubt.
    func testTheVerdictIsWrittenAsANote() {
        let red = RunVerifyVerdict(exitStatus: 3, command: "make ci", directory: "/tmp/wt",
                                   outputTail: "1 failed", timedOut: false)
        let note = BacklogAutopilot.verifyNote(red)
        XCTAssertTrue(note.hasPrefix("verify failed (exit 3) — `make ci` in `/tmp/wt`"), note)
        XCTAssertTrue(note.contains("1 failed"), "the output tail rides along")

        let green = RunVerifyVerdict(exitStatus: 0, command: "make ci", directory: "/tmp/wt",
                                     outputTail: "", timedOut: false)
        XCTAssertEqual(BacklogAutopilot.verifyNote(green), "verify passed (exit 0) — `make ci` in `/tmp/wt`")
    }

    // MARK: - The rail while the app's own verify runs

    /// The acceptance criterion: for as long as the app is running the item's
    /// `verify:` itself — a build that can take the whole of `verifyTimeout` —
    /// the rail is on `verify`, with the worker behind it. It used to stay on
    /// `worker` with `lastActivityAt` ageing, so a run deliberately building
    /// read as a worker gone quiet, and past half the stall timeout the rail
    /// called it stale.
    func testTheRailIsOnVerifyWhileTheAppRunsTheItemsVerify() async throws {
        let autopilot = try configuredAutopilot(verify: "sleep 1")
        autopilot.stagePhaseRailForTesting(phase: .worker)

        let gate = Task { await autopilot.verifyAllowsReviewForTesting(worktree: nil) }

        try await eventually("the rail to move onto the verify") {
            PortfolioSnapshot.phaseRail(currentRunPhase: autopilot.currentRunPhase, attempt: 1,
                                        lastActivityAt: Date(), stallTimeoutMinutes: 20)?.current == .verify
        }
        let rail = try XCTUnwrap(PortfolioSnapshot.phaseRail(
            currentRunPhase: autopilot.currentRunPhase, attempt: 1,
            lastActivityAt: Date(), stallTimeoutMinutes: 20))
        XCTAssertEqual(rail.stepsDone, [.worker], "the worker is behind it; the review has not begun")

        let allowed = await gate.value
        XCTAssertTrue(allowed, "a green verify still lets the review run")
    }

    // MARK: - Where the pre-review verify builds

    /// The acceptance criterion: a live-tree run (no worktree of its own) built
    /// into the DerivedData the launching Xcode shares, so the verdict on the
    /// record could be a reading of whatever the IDE last built rather than of
    /// the tree the run is sitting in — the same reuse that once had the merge
    /// gate refuse a tree for a call that did exist. The verify now builds into
    /// the project's own gitignored build directory, exactly as the merge
    /// gate's steps already do.
    func testALiveTreeVerifyBuildsIntoTheProjectsOwnDerivedData() async throws {
        let recorded = try installFakeXcodebuild(in: projectRoot)
        let autopilot = try configuredAutopilot(verify: "./xcodebuild build-for-testing")

        let allowed = await autopilot.verifyAllowsReviewForTesting(worktree: nil)

        XCTAssertTrue(allowed)
        let verdict = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting)
        XCTAssertEqual(verdict.command,
                       "./xcodebuild -derivedDataPath '\(gateDerivedDataPath)' build-for-testing")
        XCTAssertFalse(verdict.command.contains("Library/Developer/Xcode/DerivedData"),
                       "never the DerivedData the IDE shares")
        XCTAssertEqual(try recordedArguments(recorded),
                       ["-derivedDataPath \(gateDerivedDataPath) build-for-testing"],
                       "the flag reaches the build, not just the recorded string")
    }

    /// An item that chose its own build directory keeps it — the rewrite is the
    /// same one an isolated run's command has already been through, and applying
    /// it twice must change nothing.
    func testAVerifyThatNamesItsOwnDerivedDataPathIsRecordedUnchanged() async throws {
        let declared = "./xcodebuild -derivedDataPath /tmp/chosen-by-the-item build-for-testing"
        try installFakeXcodebuild(in: projectRoot)
        let autopilot = try configuredAutopilot(verify: declared)

        let allowed = await autopilot.verifyAllowsReviewForTesting(worktree: nil)

        XCTAssertTrue(allowed)
        XCTAssertEqual(try XCTUnwrap(autopilot.lastVerifyVerdictForTesting).command, declared)
    }

    /// One tree, one command: the salvage re-check and the pre-review gate run
    /// the identical rewritten command, so they cannot judge the same tree
    /// differently — which is the whole reason they read it from one place.
    func testTheSalvageRecheckRunsTheSameCommandAsThePreReviewGate() async throws {
        let recorded = try installFakeXcodebuild(in: projectRoot)
        let declared = "./xcodebuild build-for-testing"
        let autopilot = try configuredAutopilot(verify: declared)

        let allowed = await autopilot.verifyAllowsReviewForTesting(worktree: nil)
        XCTAssertTrue(allowed)
        let gateCommand = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting).command

        let salvaged = await autopilot.salvageVerifyPassesForTesting(
            item: item(verify: declared), detail: nil, worktree: nil)

        XCTAssertTrue(salvaged)
        let arguments = try recordedArguments(recorded)
        XCTAssertEqual(arguments.count, 2, "the gate's build and the salvage re-check's")
        XCTAssertEqual(arguments.first, arguments.last)
        XCTAssertTrue(gateCommand.contains("-derivedDataPath '\(gateDerivedDataPath)'"), gateCommand)
    }

    // MARK: - The clock the pre-review verify runs under

    /// The acceptance criterion: the pre-review verify is held to the gate's
    /// own derived merge-verify deadline, not to the shell helper's fixed
    /// fifteen minutes. Ten landed runs whose gate phase took 1200s derive a
    /// 30-minute gate deadline, and that is the deadline the verify the app
    /// runs before the review is given — the number it ran under is on the run
    /// log beside the command, since "timed out before it answered" can only be
    /// read against how long it was allowed.
    func testThePreReviewVerifyRunsUnderTheGatesDerivedDeadline() async throws {
        let store = try makeMetricStore()
        for _ in 0..<10 { store.append(landedRun(gate: 1_200)) }
        let autopilot = try configuredAutopilot(verify: "echo all-green", metricStore: store)

        XCTAssertEqual(autopilot.autoMergeVerifyTimeoutMinutes, 30, "the gate's own derived deadline")
        XCTAssertEqual(autopilot.verifyTimeout, 30 * 60,
                       "and the verify clock is that deadline, not the helper's 900s default")

        let allowed = await autopilot.verifyAllowsReviewForTesting(worktree: nil)

        XCTAssertTrue(allowed)
        XCTAssertTrue(
            autopilot.log.contains { $0.message.contains("before review (deadline 30m)") },
            "the run the app itself timed must say what it timed it against: \(autopilot.log.map(\.message))")
    }

    /// A project that has measured nothing still runs the deadline the gate
    /// runs — the 15 minutes that used to be a coincidence of the shell
    /// helper's default and is now the same number read from the same place.
    func testAProjectWithNoHistoryVerifiesUnderTheDefaultGateDeadline() throws {
        let autopilot = try configuredAutopilot(verify: "echo all-green")
        XCTAssertEqual(autopilot.verifyTimeout,
                       TimeInterval(RunTimeouts.defaultGateMinutes * 60))
    }

    /// The deadline is real: one verify, two clocks. Under a clock it outruns,
    /// the run ends at this gate and the record says the deadline is what ended
    /// it rather than the command answering.
    func testAVerifyThatOutrunsItsDeadlineEndsTheRunAsTimedOut() async throws {
        let autopilot = try configuredAutopilot(verify: "sleep 30 && echo slow-but-green")

        let allowed = await autopilot.verifyAllowsReviewForTesting(worktree: nil, timeout: 0.5)

        XCTAssertFalse(allowed, "a verify nobody waited for is not a verify that passed")
        XCTAssertEqual(autopilot.closedReviewGateSignalForTesting, "verify timed out before it answered")
        let verdict = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting)
        XCTAssertTrue(verdict.timedOut)
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.exitStatus, WorktreeManager.noExitStatus,
                       "a killed command never reached an exit status")
    }

    /// …and the same verify, given a clock long enough for it, answers for
    /// itself and the review runs. This is the run the fixed default was
    /// failing: a project whose verify is its whole CI is slow, not red.
    func testTheSameVerifyPassesUnderALongEnoughDeadline() async throws {
        let autopilot = try configuredAutopilot(verify: "sleep 1 && echo slow-but-green")

        let allowed = await autopilot.verifyAllowsReviewForTesting(worktree: nil, timeout: 120)

        XCTAssertTrue(allowed)
        XCTAssertNil(autopilot.closedReviewGateSignalForTesting)
        let verdict = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting)
        XCTAssertFalse(verdict.timedOut)
        XCTAssertTrue(verdict.passed)
        XCTAssertEqual(verdict.outputTail, "slow-but-green")
    }

    // MARK: - The salvage re-check's own verdict

    /// The acceptance criterion: a run accepted because its own verify still
    /// passes is the one acceptance resting on nothing but a verify, so the
    /// verdict that decided it is on the record — where `recordMetric` copies
    /// it onto the run's metric record — rather than being a true nobody wrote
    /// down.
    func testAGreenSalvageRecheckIsRecordedOnTheRun() async throws {
        let autopilot = try configuredAutopilot(verify: nil)

        let salvaged = await autopilot.salvageVerifyPassesForTesting(
            item: item(verify: "echo salvage-green"), detail: nil, worktree: projectRoot)

        XCTAssertTrue(salvaged)
        let verdict = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting,
                                    "the verdict that accepted the run has to be readable afterwards")
        XCTAssertEqual(verdict.exitStatus, 0)
        XCTAssertTrue(verdict.passed)
        XCTAssertEqual(verdict.command, "echo salvage-green")
        XCTAssertEqual(verdict.directory, projectRoot.path(percentEncoded: false))
        XCTAssertEqual(verdict.outputTail, "salvage-green")
        XCTAssertFalse(verdict.timedOut)
    }

    /// A red one is kept just the same — the item is still blocked, but now
    /// with something to read about why nothing was salvaged.
    func testARedSalvageRecheckIsRecordedAndStillBlocks() async throws {
        let autopilot = try configuredAutopilot(verify: nil)

        let salvaged = await autopilot.salvageVerifyPassesForTesting(
            item: item(verify: "echo 'still red' && exit 4"), detail: nil, worktree: projectRoot)

        XCTAssertFalse(salvaged, "a red re-check salvages nothing, as it always did")
        let verdict = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting)
        XCTAssertEqual(verdict.exitStatus, 4)
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.outputTail.contains("still red"))
    }

    /// The re-check writes the item the same note the pre-review gate writes:
    /// the command, the tree it ran in, and the tail when there is one — read
    /// back off the detail file, which is where a person looks for it.
    func testTheSalvageRecheckWritesTheVerifyNoteOnTheItem() async throws {
        let autopilot = try configuredAutopilot(verify: nil, loadingBacklog: true)

        let salvaged = await autopilot.salvageVerifyPassesForTesting(
            item: item(verify: "echo salvaged-tail"), detail: nil, worktree: projectRoot)
        XCTAssertTrue(salvaged)

        let notes = try String(contentsOf: projectRoot.appending(path: "backlog/sync-dedup-guard.md"),
                               encoding: .utf8)
        XCTAssertTrue(notes.contains("## Notes"), notes)
        XCTAssertTrue(notes.contains("verify passed (exit 0) — `echo salvaged-tail` in "
                                     + "`\(projectRoot.path(percentEncoded: false))`"), notes)
        XCTAssertTrue(notes.contains("salvaged-tail\n"), "the output tail rides along: \(notes)")
    }

    /// And a red one is written down too — the item is blocked with something
    /// to read rather than blocked in silence.
    func testTheRedSalvageRecheckIsWrittenOnTheItemToo() async throws {
        let autopilot = try configuredAutopilot(verify: nil, loadingBacklog: true)

        let salvaged = await autopilot.salvageVerifyPassesForTesting(
            item: item(verify: "echo 'compile error' && exit 1"), detail: nil, worktree: projectRoot)
        XCTAssertFalse(salvaged)

        let notes = try String(contentsOf: projectRoot.appending(path: "backlog/sync-dedup-guard.md"),
                               encoding: .utf8)
        XCTAssertTrue(notes.contains("verify failed (exit 1) — "), notes)
        XCTAssertTrue(notes.contains("compile error"), notes)
    }

    /// The re-check runs under the gate's own derived deadline, not the shell
    /// helper's fixed 900 seconds, and the line announcing it names the
    /// deadline it was given — the same way the pre-review one does.
    func testTheSalvageRecheckRunsUnderTheGatesDerivedDeadline() async throws {
        let store = try makeMetricStore()
        for _ in 0..<10 { store.append(landedRun(gate: 1_200)) }
        let autopilot = try configuredAutopilot(verify: nil, metricStore: store)

        XCTAssertEqual(autopilot.verifyTimeout, 30 * 60, "the gate's deadline, not the helper's 900s")

        let salvaged = await autopilot.salvageVerifyPassesForTesting(
            item: item(verify: "echo all-green"), detail: nil, worktree: projectRoot)

        XCTAssertTrue(salvaged)
        XCTAssertTrue(
            autopilot.log.contains { $0.message.contains("re-checking verify for sync-dedup-guard "
                                                         + "before blocking (deadline 30m)") },
            "the run the app itself timed must say what it timed it against: \(autopilot.log.map(\.message))")
    }

    /// The deadline is real, and a command killed at it is recorded as timed
    /// out rather than as an exit status it never reached — the run whose work
    /// used to be discarded as "nothing to salvage" by a build that outgrew a
    /// fixed fifteen minutes.
    func testASalvageRecheckKilledAtItsDeadlineIsRecordedAsTimedOut() async throws {
        let autopilot = try configuredAutopilot(verify: nil)

        let salvaged = await autopilot.salvageVerifyPassesForTesting(
            item: item(verify: "sleep 30 && echo slow-but-green"), detail: nil,
            worktree: projectRoot, timeout: 0.5)

        XCTAssertFalse(salvaged, "a verify nobody waited for is not a verify that passed")
        let verdict = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting)
        XCTAssertTrue(verdict.timedOut)
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.exitStatus, WorktreeManager.noExitStatus,
                       "a killed command never reached an exit status")
        XCTAssertTrue(autopilot.log.contains { $0.message.contains("verify timed out before it answered") },
                      "and the log says the deadline ended it: \(autopilot.log.map(\.message))")
    }

    // MARK: - Helpers

    /// Where a live-tree run's builds belong: the project root's own gitignored
    /// build directory, the one the merge gate's steps already build into.
    private var gateDerivedDataPath: String {
        projectRoot.appending(path: ".kiteloop/DerivedData").path(percentEncoded: false)
    }

    /// A stand-in `xcodebuild` in the tree the verify runs in, which records the
    /// arguments it was handed and exits clean — so a test reads the flags the
    /// build was really run with, not only the string the verdict quotes, and
    /// no real build is started to find out.
    @discardableResult
    private func installFakeXcodebuild(in directory: URL) throws -> URL {
        let log = directory.appending(path: "xcodebuild-arguments.txt")
        let tool = directory.appending(path: "xcodebuild")
        try "#!/bin/sh\necho \"$@\" >> '\(log.path(percentEncoded: false))'\n"
            .write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: tool.path(percentEncoded: false))
        return log
    }

    /// One entry per time the stand-in ran, in order.
    private func recordedArguments(_ log: URL) throws -> [String] {
        try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    /// An autopilot configured over a throwaway project with one item in its run
    /// queue — the state the pre-review gate is reached in.
    ///
    /// `loadingBacklog` writes a real `BACKLOG.md` and detail file for that
    /// item first and loads them, so a test can read back the note the verdict
    /// is written as — `appendNote` has nowhere to write without a detail file.
    private func configuredAutopilot(verify: String?,
                                     metricStore: TaskMetricStore? = nil,
                                     loadingBacklog: Bool = false) throws -> BacklogAutopilot {
        let root = try XCTUnwrap(projectRoot)
        let backlog = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(
                storageURL: root.appendingPathComponent("global-config.json")
            )
        )
        if loadingBacklog {
            try writeBacklogFiles(in: root)
            backlog.loadForProject(repoPath: root.path(percentEncoded: false))
        }
        self.backlog = backlog
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: backlog,
            configURL: root.appendingPathComponent("autopilot-config.json"),
            metricStore: metricStore,
            projectPath: root.path(percentEncoded: false)
        )
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1),
                                     queue: [item(verify: verify)])
        autopilot.stageQueueIndexForTesting(0)
        return autopilot
    }


    /// A backlog naming the one item these tests run, with a detail file for it
    /// — the only thing the item's Notes can be written into.
    private func writeBacklogFiles(in root: URL) throws {
        try """
        ---
        project: demo
        ---

        # Demo Backlog

        ## Epic: Now

        - [ ] sync-dedup-guard | Guard sync dedup | active → [detail](backlog/sync-dedup-guard.md)
        """.write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let details = root.appending(path: "backlog")
        try FileManager.default.createDirectory(at: details, withIntermediateDirectories: true)
        try "# Guard sync dedup\n\nWhat: test item.\n".write(
            to: details.appending(path: "sync-dedup-guard.md"), atomically: true, encoding: .utf8)
    }

    /// A ledger of this project's own runs, written under the test's temporary
    /// root — the history `runTimeouts` derives the gate's deadline from.
    private func makeMetricStore() throws -> TaskMetricStore {
        let root = try XCTUnwrap(projectRoot)
        return TaskMetricStore(
            metricsURL: root.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: root.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: root.appendingPathComponent("task-approvals.jsonl"),
            mergesURL: root.appendingPathComponent("task-merges.jsonl"))
    }

    /// One landed run of this project. Both phase durations are set, which is
    /// what makes a record a sample `RunTimeouts` can derive from.
    private func landedRun(gate: Double) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: projectRoot.path(percentEncoded: false), projectName: "demo",
            itemID: "sync-dedup-guard", title: "Guard sync dedup",
            epic: nil, declaredSize: nil, startedAt: Date(), completedAt: Date(),
            durationSeconds: 3_600, costUSD: 1, reviewerRetries: 0, outcome: "done",
            workerAgent: nil, reviewerAgent: nil, executionID: nil, toolErrors: nil)
        record.workerPhaseSeconds = 600
        record.gatePhaseSeconds = gate
        return record
    }

    private func makeGitRepo() throws -> URL {
        let root = try makeTemporaryDirectory(prefix: "autopilot-salvage")
        try "init".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        for args in [["init"], ["config", "user.email", "test@test.com"],
                     ["config", "user.name", "Test"], ["add", "."], ["commit", "-m", "init"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = root
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
        return root
    }
}
