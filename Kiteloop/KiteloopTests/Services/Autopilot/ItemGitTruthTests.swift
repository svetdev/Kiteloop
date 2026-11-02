import XCTest
@testable import Kiteloop

/// Against a real repository, because the whole value of this type is that it
/// asks git rather than a ledger — a fake would be testing the mock.
final class ItemGitTruthTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try makeTemporaryDirectory(prefix: "item-git-truth")
        git("init", "-q", "-b", "main")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        try write("README.md", "base\n")
        git("add", "-A")
        git("commit", "-qm", "base")
    }

    /// A branch with commits HEAD cannot reach: present, not merged, and the
    /// diff counted.
    func testABranchAheadOfHeadReadsAsUnmergedWithItsCommitsAndDiff() async throws {
        git("checkout", "-q", "-b", "kiteloop/item-1")
        try write("Feature.swift", "let x = 1\n")
        git("add", "-A")
        git("commit", "-qm", "work")
        git("checkout", "-q", "main")

        let truth = await ItemGitTruth.read(projectRoot: root, itemID: "item-1")

        XCTAssertEqual(truth.presence, .present)
        XCTAssertEqual(truth.merged, false)
        XCTAssertEqual(truth.commitsAhead, 1)
        XCTAssertEqual(truth.changedFiles, 1)
    }

    /// Merged is the tip already being reachable from HEAD — the question the
    /// ledger keeps getting wrong.
    func testAMergedBranchReadsAsMergedWithNothingAhead() async throws {
        git("checkout", "-q", "-b", "kiteloop/item-1")
        try write("Feature.swift", "let x = 1\n")
        git("add", "-A")
        git("commit", "-qm", "work")
        git("checkout", "-q", "main")
        git("merge", "-q", "--no-ff", "-m", "merge", "kiteloop/item-1")

        let truth = await ItemGitTruth.read(projectRoot: root, itemID: "item-1")

        XCTAssertEqual(truth.merged, true)
        XCTAssertEqual(truth.commitsAhead, 0)
    }

    /// git answered, and there is no such ref. Distinct from "could not ask".
    func testAMissingBranchIsAbsentRatherThanUnreadable() async {
        let truth = await ItemGitTruth.read(projectRoot: root, itemID: "never-run")

        XCTAssertEqual(truth.presence, .absent)
        XCTAssertNil(truth.merged)
        XCTAssertNil(truth.commitsAhead)
        // Asked, and nothing of this item's is in the object store — the line an
        // item that genuinely produced nothing gets, unchanged.
        XCTAssertEqual(truth.orphanedCommits, false)
        XCTAssertEqual(truth.summary, "no branch kiteloop/never-run")
    }

    /// Teardown dropped the branch, the commit it wrote is still in the object
    /// store: the missing ref says nothing about whether work was produced, so
    /// the line must not read as "nothing was produced".
    func testADeletedBranchWhoseCommitsSurviveSaysSoRatherThanJustNoBranch() async {
        branchWithWork("kiteloop/item-1", subject: "autopilot: item-1")
        git("branch", "-D", "kiteloop/item-1")

        let truth = await ItemGitTruth.read(projectRoot: root, itemID: "item-1")

        XCTAssertEqual(truth.presence, .absent)
        XCTAssertEqual(truth.orphanedCommits, true)
        XCTAssertEqual(truth.summary,
                       "no branch kiteloop/item-1 · its commits are still in the object store, unreferenced")
    }

    /// Another item's abandoned work sits in the same object store and says
    /// nothing about this one — the subject is what tells them apart.
    func testADanglingCommitFromAnotherItemIsNotThisItemsWork() async {
        branchWithWork("kiteloop/other-item", subject: "autopilot: other-item")
        git("branch", "-D", "kiteloop/other-item")

        let truth = await ItemGitTruth.read(projectRoot: root, itemID: "item-1")

        XCTAssertEqual(truth.orphanedCommits, false)
        XCTAssertEqual(truth.summary, "no branch kiteloop/item-1")
    }

    /// The scan is a full object walk, so a branch that resolves never pays for
    /// it: nobody asked, and nil is what that reads as — set up so a read that
    /// *did* reach the scan would come back true.
    func testAResolvingBranchNeverRunsTheScan() async throws {
        branchWithWork("kiteloop/item-1", subject: "autopilot: item-1")
        branchWithWork("kiteloop/dangling-too", subject: "autopilot: item-1")
        git("branch", "-D", "kiteloop/dangling-too")

        let truth = await ItemGitTruth.read(projectRoot: root, itemID: "item-1")

        XCTAssertEqual(truth.presence, .present)
        XCTAssertNil(truth.orphanedCommits)
    }

    /// Not a repository at all. Every claim stays nil — a zero here would read
    /// as "changes nothing", which is the one thing it must never mean.
    func testANonRepositoryIsUnreadableAndClaimsNothing() async throws {
        let plain = try makeTemporaryDirectory(prefix: "plain")

        let truth = await ItemGitTruth.read(projectRoot: plain, itemID: "item-1")

        XCTAssertTrue(truth.isUnreadable)
        XCTAssertNil(truth.merged)
        XCTAssertNil(truth.commitsAhead)
        XCTAssertNil(truth.changedFiles)
        // A repo nobody could read cannot be scanned either, and a false here
        // would claim the object store had been looked at.
        XCTAssertNil(truth.orphanedCommits)
        XCTAssertEqual(truth.summary, "git could not be read here")
        XCTAssertEqual(truth, .unreadable(branch: "kiteloop/item-1"))
    }

    /// No project root is the same answer as no repository, and reaches it
    /// without running git at all.
    func testNoProjectRootIsUnreadable() async {
        let truth = await ItemGitTruth.read(projectRoot: nil, itemID: "item-1")

        XCTAssertTrue(truth.isUnreadable)
        XCTAssertEqual(truth.branch, "kiteloop/item-1")
    }

    /// A blocked run's worktree is kept for a human to read, so the path is
    /// reported when one is on disk.
    func testAKeptWorktreeIsReported() async throws {
        let worktree = root.appending(path: ".kiteloop/worktrees/item-1")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let truth = await ItemGitTruth.read(projectRoot: root, itemID: "item-1")

        XCTAssertEqual(truth.worktreePath, worktree.path(percentEncoded: false))
    }

    // MARK: - Helpers

    /// A branch carrying one commit, left on `main` afterwards. `subject` is the
    /// line `WorktreeSession.commitWork` writes, which is what a dangling commit
    /// is matched on.
    private func branchWithWork(_ name: String, subject: String) {
        git("checkout", "-q", "-b", name)
        let file = name.replacingOccurrences(of: "/", with: "-") + ".txt"
        try? "worked".write(to: root.appending(path: file), atomically: true, encoding: .utf8)
        git("add", "-A")
        git("commit", "-qm", subject)
        git("checkout", "-q", "main")
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path(percentEncoded: false)] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
