import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers the reconciliation that frees an item left mid-run — `active`, or
/// `inReview` — by a run the app never finished: which items it picks
/// (everything with no run behind it, and nothing a run is executing, whichever
/// of the two stages it sits on), what it says in the Notes, and — the part that
/// makes it safe — that it leaves the interrupted run's branch and worktree
/// exactly where they are.
///
/// The rules are pure and the git reads run against a real temporary repository,
/// for the same reason `RunWorkEvidenceTests` does: what the interrupted run
/// left behind is a fact about the repo, not about the app's memory of it.
@MainActor
final class StaleActiveItemsTests: XCTestCase {
    private var repo: URL!
    private var backlogURL: URL!

    private let sampleBacklog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] task-1 | First task | active → [detail](backlog/task-1.md)
    - [ ] task-2 | Second task | ready

    ## Epic: Later

    - [ ] task-3 | Third task | active
    - [ ] task-4 | Fourth task | in-review
    - [ ] task-5 | Fifth task | awaiting-approval
    """

    override func setUpWithError() throws {
        repo = try makeTemporaryDirectory(prefix: "stale-active-items")
        backlogURL = repo.appending(path: "BACKLOG.md")
    }

    // MARK: - Which items are stranded

    func testStrandedListsEveryMidRunItemWithNoRunBehindIt() {
        let file = parse(sampleBacklog)

        let stranded = StaleActiveItems.stranded(in: file, inFlightItemID: nil)

        XCTAssertEqual(stranded.map(\.id), ["task-1", "task-3", "task-4"])
        XCTAssertEqual(stranded.first?.title, "First task")
    }

    /// `inReview` strands exactly as `active` does: the reviewer node writes it
    /// while it holds the item, and that verdict dies with the process, so an app
    /// that stopped mid-review left an item in a column no pickup gate reads.
    func testStrandedReturnsAnItemLeftInReview() {
        let file = parse(sampleBacklog)

        let stranded = StaleActiveItems.stranded(in: file, inFlightItemID: "task-1")

        XCTAssertEqual(stranded.map(\.id), ["task-3", "task-4"])
        XCTAssertEqual(stranded.last?.title, "Fourth task")
    }

    /// The one item that may legitimately read mid-run: reopening a project
    /// mid-run must not reach into the run and turn its item back — and which
    /// stage the run has got to is no part of that, since it moves between them
    /// as it goes.
    func testStrandedLeavesTheItemARunIsExecutingAloneOnEitherStage() {
        let file = parse(sampleBacklog)

        XCTAssertFalse(StaleActiveItems.stranded(in: file, inFlightItemID: "task-1")
            .contains { $0.id == "task-1" })
        XCTAssertFalse(StaleActiveItems.stranded(in: file, inFlightItemID: "task-4")
            .contains { $0.id == "task-4" })
    }

    func testStrandedIgnoresEveryOtherStatus() {
        let file = parse("""
        ---
        project: demo
        ---

        ## Epic: Now

        - [ ] a | A | ready
        - [ ] c | C | awaiting-approval
        - [ ] d | D | blocked
        - [ ] e | E | draft
        - [x] f | F | done
        """)

        XCTAssertEqual(StaleActiveItems.stranded(in: file, inFlightItemID: nil), [])
    }

    func testStrandedWithoutABacklogIsEmpty() {
        XCTAssertEqual(StaleActiveItems.stranded(in: nil, inFlightItemID: nil), [])
    }

    // MARK: - What the note says

    func testNoteSaysTheAppStoppedAndWhenItWasNoticed() {
        let note = StaleActiveItems.note(reason: "project opened", work: nil)

        XCTAssertTrue(note.contains("returned to ready"), note)
        XCTAssertTrue(note.contains("the app stopped while this was running"), note)
        XCTAssertTrue(note.contains("project opened"), note)
    }

    func testNoteNamesTheWorkTheInterruptedRunLeft() {
        let work = RunWorkEvidence.LeftBehind(
            verdict: .produced, branch: "kiteloop/task-1", fileCount: 3,
            worktreePath: "/tmp/wt/task-1"
        )

        let note = StaleActiveItems.note(reason: "project opened", work: work)

        XCTAssertTrue(note.contains("3 files of work left behind on branch kiteloop/task-1"), note)
        XCTAssertTrue(note.contains("untouched"), note)
    }

    /// A run that left nothing says nothing — an empty find sends a reader
    /// looking for a branch that was never there.
    func testNoteNamesNoWorkWhenTheRunLeftNone() {
        let work = RunWorkEvidence.LeftBehind(
            verdict: .noChanges, branch: "kiteloop/task-1", fileCount: 0, worktreePath: nil
        )

        XCTAssertFalse(StaleActiveItems.note(reason: "project opened", work: work)
            .contains("left behind"))
    }

    // MARK: - The commit half of the evidence

    func testCommitSignalCountsAnEmptyDiffAsNothingCommitted() {
        XCTAssertEqual(StaleActiveItems.commitSignal(from: .produced), 1)
        XCTAssertEqual(StaleActiveItems.commitSignal(from: .emptyDiff), 0)
        XCTAssertEqual(StaleActiveItems.commitSignal(from: .noCommits), 0)
        XCTAssertEqual(StaleActiveItems.commitSignal(from: .noBranch), 0)
    }

    /// A git read nobody could make leaves the question open rather than
    /// counting against the run.
    func testCommitSignalLeavesAnUnreadableBranchUnanswered() {
        XCTAssertNil(StaleActiveItems.commitSignal(from: .unknown))
    }

    // MARK: - Applying it to the backlog

    func testReconcileReturnsStrandedItemsToReadyAndPersists() async throws {
        let vm = try makeViewModel()

        let returned = await vm.reconcileActiveItems(reason: "project opened", inFlightItemID: nil)

        XCTAssertEqual(returned, ["task-1", "task-3", "task-4"])
        XCTAssertEqual(inMemory(vm, "task-1")?.status, .ready)
        XCTAssertEqual(try onDisk("task-1")?.status, .ready)
        XCTAssertEqual(try onDisk("task-3")?.status, .ready)
        XCTAssertEqual(try onDisk("task-4")?.status, .ready)
    }

    func testReconcileLeavesTheItemARunIsExecutingActive() async throws {
        let vm = try makeViewModel()

        let returned = await vm.reconcileActiveItems(reason: "project reopened",
                                                     inFlightItemID: "task-1")

        XCTAssertEqual(returned, ["task-3", "task-4"])
        XCTAssertEqual(inMemory(vm, "task-1")?.status, .active)
        XCTAssertEqual(try onDisk("task-1")?.status, .active)
    }

    /// The in-flight item is left where it is on the review stage too — the same
    /// rule, read at the other end of the same run.
    func testReconcileLeavesTheItemARunIsReviewingInReview() async throws {
        let vm = try makeViewModel()

        let returned = await vm.reconcileActiveItems(reason: "project reopened",
                                                     inFlightItemID: "task-4")

        XCTAssertEqual(returned, ["task-1", "task-3"])
        XCTAssertEqual(inMemory(vm, "task-4")?.status, .inReview)
        XCTAssertEqual(try onDisk("task-4")?.status, .inReview)
    }

    func testReconcileLeavesEveryOtherItemAsItWas() async throws {
        let vm = try makeViewModel()

        await vm.reconcileActiveItems(reason: "project opened", inFlightItemID: nil)

        XCTAssertEqual(try onDisk("task-2")?.status, .ready)
        XCTAssertEqual(try onDisk("task-5")?.status, .awaitingApproval)
    }

    func testReconcileWithNothingMidRunWritesNothing() async throws {
        let vm = try makeViewModel(backlog: sampleBacklog
            .replacingOccurrences(of: "| active", with: "| ready")
            .replacingOccurrences(of: "| in-review", with: "| ready"))
        let before = try String(contentsOf: backlogURL, encoding: .utf8)

        let returned = await vm.reconcileActiveItems(reason: "project opened", inFlightItemID: nil)

        XCTAssertEqual(returned, [])
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
    }

    func testReconcileRecordsWhyInTheItemNotes() async throws {
        let vm = try makeViewModel()
        let detailURL = try writeDetail(id: "task-1", body: """
        ## What

        Something.
        """)

        await vm.reconcileActiveItems(reason: "project opened", inFlightItemID: nil)

        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(detail.contains("## Notes"), detail)
        XCTAssertTrue(detail.contains("returned to ready"), detail)
        XCTAssertTrue(detail.contains("the app stopped while this was running"), detail)
    }

    /// An item with no detail file has nowhere to record the reason — it still
    /// has to be freed, or the stranding this fixes just moves to ungroomed items.
    func testReconcileFreesAnItemWithNoDetailFile() async throws {
        let vm = try makeViewModel()

        await vm.reconcileActiveItems(reason: "project opened", inFlightItemID: nil)

        XCTAssertEqual(try onDisk("task-3")?.status, .ready)
    }

    // MARK: - Opening a project in the window

    /// What the window does on every open: an autopilot left claiming a run
    /// that ended goes back to idle, and the items that run left mid-flight go
    /// back to ready, with the note saying the project was opened.
    func testOpeningAProjectClearsAStaleBusyAutopilotAndFreesItsItems() async throws {
        let vm = try makeViewModel()
        let detailURL = try writeDetail(id: "task-1", body: "## What\n\nSomething.")
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [])

        let returned = await MainWindow.reconcileAfterOpen(outcome: .opened, autopilot: autopilot, backlog: vm)

        XCTAssertEqual(autopilot.status, .idle, "no run is behind the status, so the project is not busy")
        XCTAssertEqual(returned, ["task-1", "task-3", "task-4"])
        XCTAssertEqual(try onDisk("task-1")?.status, .ready)
        XCTAssertTrue(try String(contentsOf: detailURL, encoding: .utf8).contains("(project opened"))
    }

    /// Reopening a project mid-run leaves the item the run is executing where
    /// it is and frees only the rest; the note says the project was reopened.
    func testReopeningAProjectMidRunLeavesTheRunsItemActive() async throws {
        let vm = try makeViewModel()
        let detailURL = try writeDetail(id: "task-1", body: "## What\n\nSomething.")
        let autopilot = BacklogAutopilot()
        let running = try XCTUnwrap(inMemory(vm, "task-3"))
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [running])
        autopilot.stageExecutingRunForTesting(true)

        let returned = await MainWindow.reconcileAfterOpen(outcome: .reloaded, autopilot: autopilot, backlog: vm)

        XCTAssertEqual(returned, ["task-1", "task-4"])
        XCTAssertEqual(try onDisk("task-3")?.status, .active)
        XCTAssertEqual(autopilot.status, .running(itemIndex: 0, total: 1))
        XCTAssertTrue(try String(contentsOf: detailURL, encoding: .utf8).contains("(project reopened"))
    }

    /// A project with no autopilot registered yet still has its stranded items
    /// freed; one with no backlog has nothing to free.
    func testOpeningAProjectWithoutAnAutopilotOrBacklog() async throws {
        let vm = try makeViewModel()

        let freed = await MainWindow.reconcileAfterOpen(outcome: .opened, autopilot: nil, backlog: vm)
        let none = await MainWindow.reconcileAfterOpen(outcome: .opened, autopilot: BacklogAutopilot(), backlog: nil)

        XCTAssertEqual(freed, ["task-1", "task-3", "task-4"])
        XCTAssertEqual(none, [])
    }

    // MARK: - The interrupted run's work

    /// The criterion that makes this safe to run unattended: the reconciliation
    /// reads the run's leftovers and removes neither.
    func testReconcileLeavesTheBranchAndWorktreeInPlace() async throws {
        let vm = try makeViewModel()
        try initGitRepo()
        let worktree = try makeWorktreeWithUncommittedWork(for: "task-1")

        await vm.reconcileActiveItems(reason: "project opened", inFlightItemID: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path(percentEncoded: false)),
                      "The interrupted run's worktree must survive")
        XCTAssertEqual(git(["rev-parse", "--verify", "--quiet", "refs/heads/kiteloop/task-1"])
            .isEmpty, false, "The interrupted run's branch must survive")
    }

    /// Teardown is what commits a run's work, and an interrupted run never
    /// reached it — so the evidence has to be read off the worktree, not the
    /// branch, or a full implementation reads back as nothing.
    func testNoteNamesUncommittedWorkLeftInTheWorktree() async throws {
        let vm = try makeViewModel()
        try initGitRepo()
        let detailURL = try writeDetail(id: "task-1", body: "## What\n\nSomething.")
        try makeWorktreeWithUncommittedWork(for: "task-1")

        await vm.reconcileActiveItems(reason: "project opened", inFlightItemID: nil)

        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(detail.contains("work left behind"), detail)
        XCTAssertTrue(detail.contains(".kiteloop/worktrees/task-1"), detail)
    }

    /// An item with neither branch nor worktree — a live-tree run, or one that
    /// died before it created either. There is nothing to point a reader at, and
    /// the note says nothing rather than inventing a place to look.
    func testLeftBehindNamesNothingForARunThatIsolatedNothing() async throws {
        try initGitRepo()

        let work = await StaleActiveItems.leftBehind(itemID: "task-2", projectRoot: repo)

        XCTAssertEqual(work?.hasWork, false)
        XCTAssertNil(work?.summary)
    }

    // MARK: - Helpers

    private func makeViewModel(backlog: String? = nil) throws -> BacklogViewModel {
        try (backlog ?? sampleBacklog).write(to: backlogURL, atomically: true, encoding: .utf8)
        let vm = BacklogViewModel(globalConfigStore: GlobalConfigStore(
            storageURL: repo.appending(path: "global-config.json")
        ))
        vm.loadForProject(repoPath: repo.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }

    private func parse(_ markdown: String) -> BacklogFile {
        BacklogParser.parse(markdown)
    }

    @discardableResult
    private func writeDetail(id: String, body: String) throws -> URL {
        let dir = repo.appending(path: "backlog")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(id).md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func inMemory(_ vm: BacklogViewModel, _ id: String) -> BacklogItem? {
        vm.backlogFile?.sections.flatMap(\.items).first { $0.id == id }
    }

    private func onDisk(_ id: String) throws -> BacklogItem? {
        let content = try String(contentsOf: backlogURL, encoding: .utf8)
        return BacklogParser.parse(content).sections.flatMap(\.items).first { $0.id == id }
    }

    private func initGitRepo() throws {
        git(["init"])
        git(["config", "user.email", "test@test.com"])
        git(["config", "user.name", "Test"])
        git(["add", "."])
        git(["commit", "-m", "init"])
    }

    /// What an interrupted isolated run leaves: its worktree on `kiteloop/<id>`
    /// with the work still uncommitted, because teardown never ran.
    @discardableResult
    private func makeWorktreeWithUncommittedWork(for itemID: String) throws -> URL {
        let path = repo.appending(path: ".kiteloop/worktrees/\(itemID)")
        git(["worktree", "add", "-b", "kiteloop/\(itemID)",
             path.path(percentEncoded: false), "HEAD"])
        try "half done".write(to: path.appending(path: "worked.txt"),
                              atomically: true, encoding: .utf8)
        return path
    }

    @discardableResult
    private func git(_ args: [String], in directory: URL? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory ?? repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
