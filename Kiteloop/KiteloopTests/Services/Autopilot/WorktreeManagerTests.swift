import XCTest
import KiteloopCore
@testable import Kiteloop

/// The fixture every `WorktreeManager` test class shares: a git repository in a
/// temporary directory, and the helpers that drive it. The tests are split into
/// four classes because parallel testing hands out whole classes — one class of
/// 129 git-driving tests held a clone for four minutes while the others idled.
class WorktreeManagerTestCase: XCTestCase {
    fileprivate var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "worktree-manager")
        initGitRepo(at: tempDir)
    }

    fileprivate func initGitRepo(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = url
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()

        let configName = Process()
        configName.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        configName.arguments = ["config", "user.email", "test@test.com"]
        configName.currentDirectoryURL = url
        configName.standardOutput = Pipe()
        try? configName.run()
        configName.waitUntilExit()

        let configEmail = Process()
        configEmail.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        configEmail.arguments = ["config", "user.name", "Test"]
        configEmail.currentDirectoryURL = url
        configEmail.standardOutput = Pipe()
        try? configEmail.run()
        configEmail.waitUntilExit()

        let readmeURL = url.appending(path: "README.md")
        try? "init".write(to: readmeURL, atomically: true, encoding: .utf8)

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        add.arguments = ["add", "."]
        add.currentDirectoryURL = url
        add.standardOutput = Pipe()
        try? add.run()
        add.waitUntilExit()

        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commit.arguments = ["commit", "-m", "init"]
        commit.currentDirectoryURL = url
        commit.standardOutput = Pipe()
        commit.standardError = Pipe()
        try? commit.run()
        commit.waitUntilExit()
    }

    fileprivate func git(_ args: [String], in url: URL) -> (status: Int32, output: String) {
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

    fileprivate func branchExists(_ name: String) -> Bool {
        git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: tempDir).status == 0
    }

    /// True while some process anywhere on the machine has `pattern` in its
    /// command line — used to check a forked child is actually gone, not just
    /// the shell that forked it.
    fileprivate func isProcessRunning(matching pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// A manager that didn't create the worktrees it is sweeping — which is the
    /// real shape of the open-time sweep: the instance that ran the item belongs
    /// to a `WorktreeSession` that is long gone, so the sweeper knows only what
    /// is on disk and what the caller declares active.
    fileprivate func sweeper() -> WorktreeManager {
        WorktreeManager(projectRoot: tempDir)
    }

    /// The checkout's branch — `main` or `master`, whichever this machine's
    /// git names a fresh repository's first branch.
    fileprivate func checkoutBranch() -> String {
        git(["rev-parse", "--abbrev-ref", "HEAD"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate func sha(_ ref: String) -> String {
        git(["rev-parse", ref], in: tempDir).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A branch `name` at the current tip, with the checkout left where it is —
    /// the shape of a base nothing has checked out.
    fileprivate func makeBranch(_ name: String) {
        XCTAssertEqual(git(["branch", name], in: tempDir).status, 0)
    }

    /// An item branch with one commit adding `file` (`feature.txt` unless a
    /// caller needs two branches to add different files), forked from `base`
    /// and torn down to the branch alone, the way a finished run leaves it.
    fileprivate func makeItemBranch(
        _ key: String, base: String?, manager: WorktreeManager, file: String = "feature.txt"
    ) async throws -> String {
        let path = try await manager.create(for: key, baseBranch: base)
        try "work".write(to: path.appending(path: file), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: key, message: "add \(file)")
        await manager.removeWorktree(for: key, keepBranch: true)
        return "kiteloop/\(key)"
    }

    /// Paths of every worktree the repo has registered, the project root included.
    fileprivate func registeredWorktrees() -> [String] {
        git(["worktree", "list", "--porcelain"], in: tempDir).output
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
    }
}

/// The worktree lifecycle, the merge gate's basics, and the sweep's hygiene.
final class WorktreeManagerTests: WorktreeManagerTestCase {
    /// Runs git in `url` and returns its exit status plus combined output.
    @discardableResult

    func testCreateWorktree() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "test-agent")

        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
        let exists = await manager.exists(for: "test-agent")
        XCTAssertTrue(exists)
    }

    func testDestroyWorktree() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        _ = try await manager.create(for: "to-destroy")
        try await manager.destroy(for: "to-destroy")

        let exists = await manager.exists(for: "to-destroy")
        XCTAssertFalse(exists)
    }

    func testWorktreePath() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let created = try await manager.create(for: "path-agent")
        let retrieved = await manager.worktreePath(for: "path-agent")

        XCTAssertEqual(created, retrieved)
    }

    func testExistsReturnsFalseForUnknown() async {
        let manager = WorktreeManager(projectRoot: tempDir)
        let exists = await manager.exists(for: "nonexistent")
        XCTAssertFalse(exists)
    }

    func testCreateMakesDirectoryUnderWorktreesDirAndBranch() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "branch-agent")

        let expected = tempDir.appending(path: ".kiteloop/worktrees/branch-agent")
        XCTAssertEqual(path.path(percentEncoded: false), expected.path(percentEncoded: false))

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path(percentEncoded: false), isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        XCTAssertTrue(branchExists("kiteloop/branch-agent"))
        // The new worktree has the branch checked out.
        let head = git(["rev-parse", "--abbrev-ref", "HEAD"], in: path).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, "kiteloop/branch-agent")
    }

    func testCreateFailsWhenBranchAlreadyExists() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        _ = try await manager.create(for: "dup-agent")

        do {
            _ = try await manager.create(for: "dup-agent")
            XCTFail("expected creation to fail for an existing branch")
        } catch WorktreeError.creationFailed(let id, _) {
            XCTAssertEqual(id, "dup-agent")
        }
    }

    /// The run log line `WorktreeSession.begin` writes is `error
    /// .localizedDescription`, so whatever git said while refusing has to reach
    /// it — "could not create a worktree for dup-agent" alone leaves an
    /// operator with nothing to act on, and git's own sentence is the reason.
    func testCreateFailureCarriesGitsOwnMessage() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        _ = try await manager.create(for: "dup-agent")

        do {
            _ = try await manager.create(for: "dup-agent")
            XCTFail("expected creation to fail for an existing branch")
        } catch let error as WorktreeError {
            let described = error.localizedDescription
            XCTAssertTrue(described.contains("dup-agent"), "no item id: \(described)")
            XCTAssertTrue(described.lowercased().contains("already exists"),
                          "git's reason is missing: \(described)")
            // One line: it goes inside `Worktree setup failed (…)`.
            XCTAssertFalse(described.contains("\n"), "multi-line message: \(described)")
        }
    }

    /// A creation that says nothing keeps the sentence it always had, rather
    /// than trailing an empty colon.
    func testCreateFailureWithoutAMessageReadsAsItAlwaysDid() {
        XCTAssertEqual(WorktreeError.creationFailed("quiet-agent", git: "").localizedDescription,
                       "could not create a worktree for quiet-agent")
        XCTAssertEqual(WorktreeError.creationFailed("quiet-agent", git: "  \n \n").localizedDescription,
                       "could not create a worktree for quiet-agent")
    }

    /// A finished item's teardown keeps the branch and removes the checkout.
    /// `reopen` is how the work is picked back up — a CI fix round on the branch
    /// a pull request is built from — and it must find the commits that were
    /// there, not a fresh branch off HEAD.
    func testReopenChecksTheExistingBranchBackOutWithItsWork() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let created = try await manager.create(for: "reopen-agent")
        try "fix".write(to: created.appending(path: "fix.txt"), atomically: true, encoding: .utf8)
        let committed = await manager.commitAll(for: "reopen-agent", message: "work")
        XCTAssertTrue(committed)
        await manager.removeWorktree(for: "reopen-agent", keepBranch: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path(percentEncoded: false)))

        let reopened = try await manager.reopen(for: "reopen-agent", branch: "kiteloop/reopen-agent")

        XCTAssertEqual(reopened.path(percentEncoded: false), created.path(percentEncoded: false))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: reopened.appending(path: "fix.txt").path(percentEncoded: false)))
        let head = git(["rev-parse", "--abbrev-ref", "HEAD"], in: reopened).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, "kiteloop/reopen-agent")
    }

    /// Called twice — a second fix round on the same item — it takes over the
    /// directory the first round left rather than refusing.
    func testReopenReplacesAWorktreeLeftByAnEarlierRound() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        _ = try await manager.create(for: "twice-agent")

        let again = try await manager.reopen(for: "twice-agent", branch: "kiteloop/twice-agent")

        XCTAssertTrue(FileManager.default.fileExists(atPath: again.path(percentEncoded: false)))
        XCTAssertTrue(branchExists("kiteloop/twice-agent"))
    }

    /// A branch that isn't there fails rather than being created: a fresh branch
    /// off HEAD carries none of the run's work, and pushing it to the pull
    /// request would replace the diff under review with nothing.
    func testReopenFailsForABranchThatDoesNotExist() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)

        do {
            _ = try await manager.reopen(for: "missing-agent", branch: "kiteloop/missing-agent")
            XCTFail("expected reopen to fail for a branch that does not exist")
        } catch WorktreeError.creationFailed(let id, let git) {
            XCTAssertEqual(id, "missing-agent")
            // Same as `create`: git's refusal is what says why.
            XCTAssertFalse(git.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "reopen discarded git's message")
        }
        XCTAssertFalse(branchExists("kiteloop/missing-agent"))
    }

    func testCommitAllReturnsTrueWhenThereAreChanges() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "commit-agent")
        try "hello".write(to: path.appending(path: "new-file.txt"), atomically: true, encoding: .utf8)

        let committed = await manager.commitAll(for: "commit-agent", message: "add new file")
        XCTAssertTrue(committed)

        XCTAssertTrue(git(["status", "--porcelain"], in: path).output
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let subject = git(["log", "-1", "--pretty=%s"], in: path).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(subject, "add new file")
    }

    func testCommitAllReturnsFalseWhenNothingToCommit() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "clean-agent")
        let before = git(["rev-parse", "HEAD"], in: path).output

        let committed = await manager.commitAll(for: "clean-agent", message: "no-op")
        XCTAssertFalse(committed)

        let after = git(["rev-parse", "HEAD"], in: path).output
        XCTAssertEqual(before, after)
    }

    /// A hook that never returns must not wedge the actor for ever: `runGit`
    /// reaches git only through `SubprocessOutput.runWithDeadline`, which kills
    /// a git still running past the deadline — and the hook it spawned along
    /// with it, since TERM on git alone leaves that child running and
    /// reparented.
    func testCommitAllTimesOutWhenAPreCommitHookHangs() async throws {
        let hooksDir = tempDir.appending(path: ".git/hooks")
        let hook = hooksDir.appending(path: "pre-commit")
        try "#!/bin/sh\nsleep 810004\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path(percentEncoded: false))

        let manager = WorktreeManager(projectRoot: tempDir, gitTimeout: 2)
        let path = try await manager.create(for: "hook-agent")
        try "hello".write(to: path.appending(path: "new-file.txt"), atomically: true, encoding: .utf8)

        let start = Date()
        let committed = await manager.commitAll(for: "hook-agent", message: "should hang")
        XCTAssertFalse(committed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10,
                           "the deadline, not the hook, must be what ends the commit")
        XCTAssertFalse(isProcessRunning(matching: "sleep 810004"),
                        "the hook's sleeping child must not survive the call returning")
    }

    func testRemoveWorktreeKeepingBranch() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "keep-agent")

        await manager.removeWorktree(for: "keep-agent", keepBranch: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
        let exists = await manager.exists(for: "keep-agent")
        XCTAssertFalse(exists)
        let tracked = await manager.worktreePath(for: "keep-agent")
        XCTAssertNil(tracked)
        XCTAssertTrue(branchExists("kiteloop/keep-agent"))
    }

    func testRemoveWorktreeDeletingBranch() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "drop-agent")

        let deletion = await manager.removeWorktree(for: "drop-agent", keepBranch: false)

        XCTAssertEqual(deletion, WorktreeManager.BranchDeletion(),
                       "the run's own worktree held the branch, so nothing stray was taken")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
        let exists = await manager.exists(for: "drop-agent")
        XCTAssertFalse(exists)
        let tracked = await manager.worktreePath(for: "drop-agent")
        XCTAssertNil(tracked)
        XCTAssertFalse(branchExists("kiteloop/drop-agent"))
    }

    /// A branch carrying commits `HEAD` cannot reach is not simply deleted: its
    /// tip is kept at `refs/kiteloop/backup/<key>/<sha>` first, and the
    /// deletion says so. A branch with nothing unmerged on it keeps nothing.
    func testRemovingABranchAheadOfHeadKeepsItsTipUnderABackupRef() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "ahead-agent")
        try "work".write(to: path.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        let committed = await manager.commitAll(for: "ahead-agent", message: "the work")
        XCTAssertTrue(committed)
        let tip = git(["rev-parse", "refs/heads/kiteloop/ahead-agent"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let deletion = await manager.removeWorktree(for: "ahead-agent", keepBranch: false)

        XCTAssertFalse(branchExists("kiteloop/ahead-agent"))
        XCTAssertEqual(deletion.backupRef, "refs/kiteloop/backup/ahead-agent/\(tip)")
        XCTAssertFalse(deletion.recoveredLooseWork)
        let kept = git(["rev-parse", "--verify", "--quiet", "refs/kiteloop/backup/ahead-agent/\(tip)"], in: tempDir)
        XCTAssertEqual(kept.status, 0)
        XCTAssertEqual(kept.output.trimmingCharacters(in: .whitespacesAndNewlines), tip)
    }

    /// Loose changes in a worktree about to be force-removed are committed
    /// first — and, the branch going too, kept under the backup ref. This is
    /// the restart case: an interrupted run's uncommitted files used to go with
    /// the directory on the next pickup.
    func testRemovingAWorktreeCommitsLooseWorkBeforeTheDirectoryGoes() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "loose-agent")
        try "ninety tests".write(to: path.appending(path: "tests.txt"), atomically: true, encoding: .utf8)

        let deletion = await manager.removeWorktree(for: "loose-agent", keepBranch: false)

        XCTAssertTrue(deletion.recoveredLooseWork)
        let backup = try XCTUnwrap(deletion.backupRef)
        XCTAssertTrue(backup.hasPrefix("refs/kiteloop/backup/loose-agent/"))
        XCTAssertEqual(git(["show", "\(backup):tests.txt"], in: tempDir).output
                           .trimmingCharacters(in: .whitespacesAndNewlines), "ninety tests")
        XCTAssertEqual(git(["log", "-1", "--format=%s", backup], in: tempDir).output
                           .trimmingCharacters(in: .whitespacesAndNewlines),
                       "autopilot (recovered before removal): loose-agent")
    }

    /// The tip a fix round started from must still be on the branch afterwards.
    /// A reset that drops it reads as rewritten; a commit on top does not.
    func testHistoryRewrittenTellsAResetFromAnAddedCommit() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "rewrite-agent")
        let base = git(["rev-parse", "HEAD"], in: path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        try "a".write(to: path.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let committed = await manager.commitAll(for: "rewrite-agent", message: "a")
        XCTAssertTrue(committed)
        let first = git(["rev-parse", "HEAD"], in: path).output.trimmingCharacters(in: .whitespacesAndNewlines)

        let baseIntact = await manager.historyRewritten(for: "rewrite-agent", since: base)
        let firstIntact = await manager.historyRewritten(for: "rewrite-agent", since: first)
        XCTAssertFalse(baseIntact)
        XCTAssertFalse(firstIntact)

        XCTAssertEqual(git(["reset", "--hard", base], in: path).status, 0)
        let firstAfterReset = await manager.historyRewritten(for: "rewrite-agent", since: first)
        let baseAfterReset = await manager.historyRewritten(for: "rewrite-agent", since: base)
        let noBranch = await manager.historyRewritten(for: "no-such-agent", since: base)
        XCTAssertTrue(firstAfterReset)
        XCTAssertFalse(baseAfterReset)
        XCTAssertTrue(noBranch)
    }

    /// A rejected item's branch tip is tagged outside `refs/heads/` before the
    /// next pickup's `removeWorktree(keepBranch: false)` deletes the branch —
    /// the tag is what survives that deletion (`GateRejection.ref`).
    func testMarkRejectedTagsTheBranchTipAndSurvivesItsDeletion() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        _ = try await manager.create(for: "rejected-agent")
        let tip = git(["rev-parse", "refs/heads/kiteloop/rejected-agent"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let ref = await manager.markRejected(for: "rejected-agent")

        XCTAssertEqual(ref, "refs/kiteloop/rejected/rejected-agent")
        let tagged = git(["rev-parse", "--verify", "--quiet", "refs/kiteloop/rejected/rejected-agent"], in: tempDir)
        XCTAssertEqual(tagged.status, 0)
        XCTAssertEqual(tagged.output.trimmingCharacters(in: .whitespacesAndNewlines), tip)

        await manager.removeWorktree(for: "rejected-agent", keepBranch: false)

        XCTAssertFalse(branchExists("kiteloop/rejected-agent"))
        let stillThere = git(["rev-parse", "--verify", "--quiet", "refs/kiteloop/rejected/rejected-agent"], in: tempDir)
        XCTAssertEqual(stillThere.status, 0, "the tag must outlive the branch it was cut from")
    }

    /// An item that never ran isolated has no branch to tag — nil, not a
    /// refusal, since there is nothing wrong here to report.
    func testMarkRejectedIsNilWithoutABranch() async {
        let manager = WorktreeManager(projectRoot: tempDir)
        let ref = await manager.markRejected(for: "never-ran")
        XCTAssertNil(ref)
    }

    /// A crashed run leaves its checkout directory behind after git has pruned
    /// the registration for it — `worktree list` no longer names the path, but
    /// the directory is there with its `.git` file, and `worktree add` refuses
    /// it with "already exists". The next run of the item has to be able to
    /// start; the stale directory is the manager's own and goes.
    func testCreateClearsAStaleCheckoutGitNoLongerRegisters() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "crashed")
        // Take the admin entry out from under the checkout, as a prune after a
        // crash does, leaving the directory and its .git file in place.
        let admin = tempDir.appending(path: ".git/worktrees/crashed")
        try FileManager.default.removeItem(at: admin)
        _ = git(["worktree", "prune"], in: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appending(path: ".git").path(percentEncoded: false)))
        // What a rerun does first: drop worktree and branch, then create anew.
        let deletion = await manager.removeWorktree(for: "crashed", keepBranch: false)
        XCTAssertNil(deletion.refusal)

        let recreated = try await manager.create(for: "crashed")

        XCTAssertEqual(recreated, path)
        XCTAssertTrue(branchExists("kiteloop/crashed"))
        // git prints real paths and Foundation strips /private when resolving,
        // so the comparison resolves both sides the way the manager does.
        let listed = git(["worktree", "list", "--porcelain"], in: tempDir).output
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("worktree ") }
            .map { URL(fileURLWithPath: String($0.dropFirst("worktree ".count))).resolvingSymlinksInPath() }
        XCTAssertTrue(listed.contains(path.resolvingSymlinksInPath()), "\(listed)")
    }

    /// A plain file at the worktree path is not a checkout this manager made,
    /// and is left alone: creation fails on it the way it always did.
    func testCreateLeavesAForeignFileAtThePathAlone() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let worktrees = WorktreeSession.worktreesRoot(projectRoot: tempDir)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        let blocker = worktrees.appending(path: "in-the-way")
        try "not a worktree".write(to: blocker, atomically: true, encoding: .utf8)

        do {
            _ = try await manager.create(for: "in-the-way")
            XCTFail("expected creation to fail on a foreign file")
        } catch WorktreeError.creationFailed { }
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "not a worktree")
    }

    /// The branch a rejected item's teardown kept is checked out somewhere no
    /// run owns — a person's review checkout, a directory a merge left. That
    /// registration is not allowed to pin the item's branch: it is taken away
    /// and the deletion goes through, so the next run starts.
    func testRemoveWorktreeTakesAwayAStrayCheckoutHoldingTheBranch() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        _ = try await manager.create(for: "held")
        await manager.removeWorktree(for: "held", keepBranch: true)
        let review = try makeTemporaryDirectory(prefix: "review-checkout")
        try FileManager.default.removeItem(at: review)
        let reviewPath = review.path(percentEncoded: false)
        XCTAssertEqual(git(["worktree", "add", reviewPath, "kiteloop/held"], in: tempDir).status, 0)

        let deletion = await manager.removeWorktree(for: "held", keepBranch: false)

        XCTAssertNil(deletion.refusal, "the stray checkout was removable, so nothing should be refused")
        let removed = try XCTUnwrap(deletion.removedStrayWorktree)
        XCTAssertTrue(removed.hasSuffix(review.lastPathComponent), "the checkout's path is missing: \(removed)")
        XCTAssertFalse(branchExists("kiteloop/held"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reviewPath))
        let registered = git(["worktree", "list", "--porcelain"], in: tempDir).output
        XCTAssertFalse(registered.contains(review.lastPathComponent), registered)
    }

    /// A worktree under the project's own `.kiteloop/worktrees` belongs to a
    /// run, not to this deletion: the refusal stands, in git's words with the
    /// path in them, and the checkout is left exactly where it was.
    func testRemoveWorktreeLeavesTheRunsOwnWorktreeHoldingTheBranch() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        _ = try await manager.create(for: "held")
        await manager.removeWorktree(for: "held", keepBranch: true)
        let sibling = WorktreeSession.worktreesRoot(projectRoot: tempDir).appending(path: "sibling")
        let siblingPath = sibling.path(percentEncoded: false)
        XCTAssertEqual(git(["worktree", "add", siblingPath, "kiteloop/held"], in: tempDir).status, 0)

        let deletion = await manager.removeWorktree(for: "held", keepBranch: false)

        let reason = try XCTUnwrap(deletion.refusal)
        XCTAssertTrue(reason.contains("sibling"), "the checkout's path is missing: \(reason)")
        XCTAssertNil(deletion.removedStrayWorktree, "a run's own worktree is not this deletion's to take")
        XCTAssertTrue(branchExists("kiteloop/held"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingPath))
        _ = git(["worktree", "remove", "--force", siblingPath], in: tempDir)
    }

    /// The checkout holding the branch is the project's own, which git never
    /// removes. The removal is attempted and refused, and what comes back is
    /// still git's reason for refusing the deletion, naming that path.
    func testRemoveWorktreeReportsARefusalThatSurvivesTheStrayRemoval() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        _ = try await manager.create(for: "held")
        await manager.removeWorktree(for: "held", keepBranch: true)
        XCTAssertEqual(git(["checkout", "kiteloop/held"], in: tempDir).status, 0)

        let deletion = await manager.removeWorktree(for: "held", keepBranch: false)

        let reason = try XCTUnwrap(deletion.refusal)
        XCTAssertTrue(reason.contains(tempDir.lastPathComponent), "the checkout's path is missing: \(reason)")
        XCTAssertNil(deletion.removedStrayWorktree, "nothing was removed, so nothing may be reported as removed")
        XCTAssertTrue(branchExists("kiteloop/held"))
        XCTAssertTrue(WorktreeManager.isGitRepository(at: tempDir), "the project's own checkout must survive")
    }

    /// A branch that is not there is not a refusal.
    func testRemoveWorktreeOfAnItemThatNeverRanReportsNothing() async {
        let manager = WorktreeManager(projectRoot: tempDir)
        let deletion = await manager.removeWorktree(for: "never-ran", keepBranch: false)
        XCTAssertEqual(deletion, WorktreeManager.BranchDeletion())
    }

    func testIsGitRepositoryTrueForRepoAndWorktree() async throws {
        XCTAssertTrue(WorktreeManager.isGitRepository(at: tempDir))

        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "repo-check")
        XCTAssertTrue(WorktreeManager.isGitRepository(at: path))
    }

    func testIsGitRepositoryFalseForPlainDirectory() throws {
        let plain = try makeTemporaryDirectory(prefix: "plain")

        XCTAssertFalse(WorktreeManager.isGitRepository(at: plain))
    }

    func testIsGitRepositoryFalseForMissingPath() {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        XCTAssertFalse(WorktreeManager.isGitRepository(at: missing))
    }

    func testCreateFailsCleanlyOutsideAGitRepository() async throws {
        let plain = try makeTemporaryDirectory(prefix: "plain")

        let manager = WorktreeManager(projectRoot: plain)
        do {
            _ = try await manager.create(for: "no-repo")
            XCTFail("expected creation to fail outside a git repository")
        } catch let error as WorktreeError {
            XCTAssertEqual(error, .notAGitRepository(plain.path(percentEncoded: false)))
            // The run log shows this verbatim, so it has to read as a sentence.
            XCTAssertTrue(error.localizedDescription.hasSuffix("is not a git repository"),
                          "unhelpful message: \(error.localizedDescription)")
        }
        // Nothing half-made left behind for the live-tree run that follows.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: plain.appending(path: ".kiteloop/worktrees/no-repo").path(percentEncoded: false)))
    }

    // MARK: - Hygiene

    func testOrphanVerdictProtectsWorkAndReapsNothingElse() {
        XCTAssertEqual(
            WorktreeManager.orphanVerdict(isActive: false, hasUnmergedCommits: false, hasUncommittedChanges: false),
            .reap)
        XCTAssertEqual(
            WorktreeManager.orphanVerdict(isActive: false, hasUnmergedCommits: true, hasUncommittedChanges: false),
            .keep(reason: "branch has unmerged commits"))
        XCTAssertEqual(
            WorktreeManager.orphanVerdict(isActive: false, hasUnmergedCommits: false, hasUncommittedChanges: true),
            .keep(reason: "uncommitted changes"))
        // A live run outranks everything — including a worktree that looks
        // reapable mid-item, before its work is committed.
        XCTAssertEqual(
            WorktreeManager.orphanVerdict(isActive: true, hasUnmergedCommits: false, hasUncommittedChanges: false),
            .active)
    }

    func testPruneDropsRegistrationWhoseDirectoryIsGone() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "vanished")
        try FileManager.default.removeItem(at: path)

        XCTAssertTrue(registeredWorktrees().contains { $0.hasSuffix("/vanished") })
        await manager.prune()
        XCTAssertFalse(registeredWorktrees().contains { $0.hasSuffix("/vanished") })
        // Prune drops the registration, never the work: the branch survives.
        XCTAssertTrue(branchExists("kiteloop/vanished"))
    }

    /// A clean orphan whose branch the base already holds loses both: the
    /// worktree is reaped and the branch, which the base contains in full,
    /// goes with the landed-branch pass.
    func testSweepReapsCleanMergedOrphanAndRemovesItsLandedBranch() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "finished")

        let report = await sweeper().sweep()

        XCTAssertEqual(report.reaped, ["finished"])
        XCTAssertTrue(report.kept.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
        XCTAssertEqual(report.landedBranchesRemoved, ["finished"])
        XCTAssertFalse(branchExists("kiteloop/finished"))
        XCTAssertFalse(registeredWorktrees().contains { $0.hasSuffix("/finished") })
    }

    func testSweepLeavesOrphanWhoseBranchHasUnmergedCommits() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "has-work")
        try "result".write(to: path.appending(path: "result.txt"), atomically: true, encoding: .utf8)
        let committed = await manager.commitAll(for: "has-work", message: "the run's output")
        XCTAssertTrue(committed)

        let report = await sweeper().sweep()

        XCTAssertTrue(report.reaped.isEmpty)
        XCTAssertEqual(report.kept, [.init(key: "has-work", reason: "branch has unmerged commits")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
        // And the reader is told, rather than left to notice the directory.
        XCTAssertTrue(report.logLines.contains("kept orphaned worktree has-work — branch has unmerged commits"))
    }

    func testSweepLeavesOrphanWithUncommittedChanges() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "blocked-item")
        // What `keepForInspection` leaves behind for a blocked item: real work,
        // deliberately uncommitted.
        try "half done".write(to: path.appending(path: "wip.txt"), atomically: true, encoding: .utf8)

        let report = await sweeper().sweep()

        XCTAssertTrue(report.reaped.isEmpty)
        XCTAssertEqual(report.kept, [.init(key: "blocked-item", reason: "uncommitted changes")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appending(path: "wip.txt").path(percentEncoded: false)))
    }

    /// A sweep that keeps an orphan (uncommitted work — a blocked item's
    /// worktree) leaves the checkout exactly as it is but reclaims its
    /// disposable build output, and reports how many kept worktrees it freed.
    func testSweepFreesBuildOutputForAKeptOrphanAndReportsIt() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "blocked-item")
        try "half done".write(to: path.appending(path: "wip.txt"), atomically: true, encoding: .utf8)
        let derivedData = WorktreeBuildOutput.derivedDataDirectory(for: path)
        try FileManager.default.createDirectory(
            at: derivedData.appending(path: "Build/Products/Debug"), withIntermediateDirectories: true)

        let report = await sweeper().sweep()

        XCTAssertEqual(report.kept, [.init(key: "blocked-item", reason: "uncommitted changes")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path(percentEncoded: false)),
                      "the checkout stays — a kept verdict never touches it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivedData.path(percentEncoded: false)),
                       "its disposable build output must be reclaimed")
        XCTAssertEqual(report.buildOutputFreed, 1)
        XCTAssertTrue(report.logLines.contains("freed build output for 1 kept worktree(s)"))
    }

    /// A kept orphan that never built has nothing to reclaim: the sweep still
    /// succeeds and reports nothing freed rather than a false count.
    func testSweepReportsNothingFreedForAKeptOrphanThatNeverBuilt() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "blocked-item")
        try "half done".write(to: path.appending(path: "wip.txt"), atomically: true, encoding: .utf8)

        let report = await sweeper().sweep()

        XCTAssertEqual(report.kept, [.init(key: "blocked-item", reason: "uncommitted changes")])
        XCTAssertEqual(report.buildOutputFreed, 0)
        XCTAssertFalse(report.logLines.contains { $0.contains("freed build output") })
    }

    func testSweepNeverTouchesAnActiveRunsWorktree() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "in-flight")

        let report = await sweeper().sweep(activeKeys: ["in-flight"])

        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
    }

    func testSweepPrunesStaleRegistrationsAndReportsIt() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "deleted-by-hand")
        try FileManager.default.removeItem(at: path)

        let report = await sweeper().sweep()

        XCTAssertEqual(report.prunedRegistrations, 1)
        XCTAssertTrue(report.reaped.isEmpty, "there is no directory left to reap")
        XCTAssertEqual(report.logLines.first, "pruned 1 stale worktree registration(s)")
    }

    func testSweepIgnoresNonDirectoryEntries() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let worktreesDir = tempDir.appending(path: ".kiteloop/worktrees")
        try FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        let stray = worktreesDir.appending(path: ".DS_Store")
        try Data().write(to: stray)

        let report = await sweeper().sweep()

        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path(percentEncoded: false)))
    }

    func testSweepIsANoOpOutsideAGitRepository() async throws {
        let plain = try makeTemporaryDirectory(prefix: "plain")
        let worktrees = plain.appending(path: ".kiteloop/worktrees/leftover")
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)

        let report = await WorktreeManager(projectRoot: plain).sweep()

        XCTAssertTrue(report.isEmpty)
        // Nothing is deleted where git can't be asked what would be lost.
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktrees.path(percentEncoded: false)))
    }
}

/// Where the work is, and the merges the gate refuses: a dirty tree, a conflict, a failing setup command.
final class WorktreeManagerMergeRefusalTests: WorktreeManagerTestCase {
    // MARK: - The work is not where it should be

    /// The state that would have marked two items done over uncommitted work on
    /// 2026-08-11: isolation on, no branch, and the project's checkout dirty.
    func testEmptyBranchRefusalNamesTheLooseChanges() {
        let refusal = WorktreeManager.emptyBranchRefusal(
            isolationExpected: true, branchExists: false,
            modified: ["Kiteloop/Kiteloop/Services/CLIResolver.swift"])

        XCTAssertEqual(refusal, "the work is not where it should be — this item has no branch, "
                       + "and the project's checkout has uncommitted changes (modified): "
                       + "Kiteloop/Kiteloop/Services/CLIResolver.swift")
    }

    func testEmptyBranchRefusalCapsThePathsAndCountsTheRest() {
        let refusal = WorktreeManager.emptyBranchRefusal(
            isolationExpected: true, branchExists: false,
            modified: ["one.swift", "two.swift", "three.swift", "four.swift"])

        XCTAssertEqual(refusal?.hasSuffix("one.swift, two.swift, three.swift (+1 more)"), true)
    }

    /// Every clause has to hold. Each of these is an ordinary approval, and a
    /// refusal on any of them would be this guard refusing work that did land.
    func testEmptyBranchRefusalLetsOrdinaryApprovalsThrough() {
        // A branch that exists and is merged: the work landed.
        XCTAssertNil(WorktreeManager.emptyBranchRefusal(
            isolationExpected: true, branchExists: true, modified: ["a.swift"]))
        // A clean checkout holds nothing to be wrong about.
        XCTAssertNil(WorktreeManager.emptyBranchRefusal(
            isolationExpected: true, branchExists: false, modified: []))
        // Isolation off — the live tree is where the work is *meant* to be, so
        // a dirty checkout with no branch is the normal ending, not a finding.
        XCTAssertNil(WorktreeManager.emptyBranchRefusal(
            isolationExpected: false, branchExists: false, modified: ["a.swift"]))
    }

    /// `branchExists` is the question `hasUnmergedCommits` cannot answer: both a
    /// merged branch and a missing one leave it false, and only one of them is
    /// work that landed.
    func testBranchExistsSeparatesAMergedBranchFromAMissingOne() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        _ = try await manager.create(for: "real-branch")

        var exists = await manager.branchExists(for: "real-branch")
        XCTAssertTrue(exists)
        exists = await manager.branchExists(for: "never-ran")
        XCTAssertFalse(exists)

        // And it says nothing about whether the branch is ahead — that is what
        // `hasUnmergedCommits` is for, and the gate reads both.
        let unmerged = await manager.hasUnmergedCommits(for: "real-branch")
        XCTAssertFalse(unmerged)
    }

    /// The gate's "nothing to merge" is judged against the base, never against
    /// whatever happens to be checked out: with the item branch itself checked
    /// out, every commit on it is reachable from HEAD, and that reading once
    /// approved an item to Done without a merge.
    func testHasUnmergedCommitsIsJudgedAgainstTheBaseNotTheCheckout() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let branch = try await makeItemBranch("checked-out-agent", base: base, manager: manager)

        var unmerged = await manager.hasUnmergedCommits(for: "checked-out-agent")
        XCTAssertTrue(unmerged, "one commit ahead of the base")
        unmerged = await manager.hasUnmergedCommits(for: "checked-out-agent", base: base)
        XCTAssertTrue(unmerged)

        XCTAssertEqual(git(["checkout", "-q", branch], in: tempDir).status, 0)
        unmerged = await manager.hasUnmergedCommits(for: "checked-out-agent")
        XCTAssertTrue(unmerged, "the checkout sitting on the item branch is not a merge")
        unmerged = await manager.hasUnmergedCommits(for: "checked-out-agent", base: base)
        XCTAssertTrue(unmerged, "against the base the commit is still unmerged")
    }

    /// The base is verified on its own tip, in a scratch worktree, under the
    /// gate's own rules: a green command is ok, a red one carries the gate's
    /// refusal, and the scratch checkout is gone either way.
    func testVerifyBaseRunsTheCommandOnTheBaseTipAlone() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()

        let green = await manager.verifyBase(command: "test -f README.md", base: base, timeout: 30, setupCommand: nil)
        XCTAssertEqual(green, WorktreeManager.BaseVerdict(sha: sha(base), ok: true, reason: nil))

        let red = await manager.verifyBase(command: "echo '  FAIL  escapes'; exit 1", base: base, timeout: 30, setupCommand: nil)
        XCTAssertEqual(red?.sha, sha(base))
        XCTAssertEqual(red?.ok, false)
        // The label collapses runs of whitespace in the command (`MergeVerifyPlan`).
        XCTAssertEqual(red?.reason, "verify failed on merged tree (merge-verify: echo ' FAIL escapes'; exit 1)")

        let missing = await manager.verifyBase(command: "true", base: "no-such-branch", timeout: 30, setupCommand: nil)
        XCTAssertNil(missing, "a base that does not resolve is nobody's verdict")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appending(path: ".kiteloop/merge-gate-scratch/base-health-merge-gate").path(percentEncoded: false)))
    }

    /// A command whose scratch checkout disappears while it runs has said
    /// nothing about the base — the verdict is unknown, never red.
    func testVerifyBaseAnswersNothingWhenTheScratchVanishedUnderTheCommand() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()

        let verdict = await manager.verifyBase(command: "cd / && rm -rf \"$OLDPWD\"; exit 1",
                                               base: base, timeout: 30, setupCommand: nil)

        XCTAssertNil(verdict, "\(String(describing: verdict))")
    }

    func testBaseRedDetailNamesTheBaseAndSaysWhoseFaultItIs() {
        let detail = BacklogAutopilot.baseRedDetail(base: "main", sha: "0123456789ab", reason: "escapes failed")
        XCTAssertEqual(detail, "the base main at 0123456 fails the project's merge-verify with no item's diff on it "
                       + "— escapes failed. Merges will be refused for it until it is green, or until the verify is "
                       + "made runnable in a cold worktree; the items are not at fault")
    }

    func testLandedNoteNamesTheCommitAndTheBase() {
        XCTAssertEqual(WorktreeManager.landedNote(commit: "0123456789abcdef0123", base: "main"),
                       "Landed: merged as 0123456789ab into main")
        XCTAssertEqual(WorktreeManager.landedNote(commit: "0123456789abcdef0123", base: nil),
                       "Landed: merged as 0123456789ab into the checkout's branch")
    }

    /// Tracked modifications only, for the same reason `mergeRefusal` reaches
    /// for them: an untracked `settings.local.json` is the ordinary state of a
    /// checkout somebody works in, and refusing on it refuses everything.
    func testModifiedPathsReadsTrackedChangesAndIgnoresUntrackedOnes() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        var paths = await manager.modifiedPaths()
        XCTAssertEqual(paths, [])

        try "stray".write(to: tempDir.appending(path: "untracked.txt"),
                          atomically: true, encoding: .utf8)
        paths = await manager.modifiedPaths()
        XCTAssertEqual(paths, [], "an untracked file is not a tracked modification")

        try "changed".write(to: tempDir.appending(path: "README.md"),
                            atomically: true, encoding: .utf8)
        paths = await manager.modifiedPaths()
        XCTAssertEqual(paths, ["README.md"])
    }

    // MARK: - Dirty-tree merge refusal

    /// A tracked modification only refuses when it overlaps `incoming` — the
    /// files the merge would bring in.
    func testMergeRefusalNamesASingleModifiedPath() {
        let reason = WorktreeManager.mergeRefusal(
            porcelain: " M Kiteloop/Kiteloop/App.swift\n",
            incoming: ["Kiteloop/Kiteloop/App.swift"])

        XCTAssertEqual(reason, "working tree not clean (modified): Kiteloop/Kiteloop/App.swift")
    }

    /// An edit to a file the merge never touches has nothing to lose, so it
    /// must not be why an approval is refused.
    func testMergeRefusalLetsANonCollidingModifiedFileThrough() {
        XCTAssertNil(WorktreeManager.mergeRefusal(
            porcelain: " M README.md\n", incoming: ["src/App.swift"]))
    }

    func testMergeRefusalCapsThePathsAndCountsTheRest() {
        let porcelain = """
         M one.swift
        M  two.swift
        ?? three.txt
         M four.swift
         D five.swift
        """

        let reason = WorktreeManager.mergeRefusal(
            porcelain: porcelain, incoming: ["one.swift", "two.swift", "four.swift", "five.swift"])

        // Only the tracked paths are named: the untracked one isn't why this refused.
        XCTAssertEqual(
            reason, "working tree not clean (modified): one.swift, two.swift, four.swift (+1 more)")
    }

    func testMergeRefusalReadsRenamesAndQuotedPaths() {
        let porcelain = """
        R  old/name.swift -> new/name.swift
        ?? "a file with spaces.txt"
        """

        let reason = WorktreeManager.mergeRefusal(
            porcelain: porcelain, incoming: ["new/name.swift", "a file with spaces.txt"])

        // The rename reports where the file landed, not where it came from. It is
        // tracked, so it refuses first — the colliding untracked file never gets a say.
        XCTAssertEqual(reason, "working tree not clean (modified): new/name.swift")
    }

    func testMergeRefusalFallsBackToTheBareReasonWithoutPaths() {
        XCTAssertEqual(
            WorktreeManager.mergeRefusal(porcelain: "xx\n", incoming: []),
            "working tree not clean")
    }

    func testMergeRefusalLetsNonCollidingUntrackedFilesThrough() {
        let porcelain = """
        ?? .claude/settings.local.json
        ?? build/output.o
        """

        XCTAssertNil(WorktreeManager.mergeRefusal(porcelain: porcelain, incoming: ["src/App.swift"]))
    }

    func testMergeRefusalNamesOnlyTheCollidingUntrackedPaths() {
        let porcelain = """
        ?? .claude/settings.local.json
        ?? docs/new-page.md
        """

        let reason = WorktreeManager.mergeRefusal(
            porcelain: porcelain, incoming: ["docs/new-page.md", "src/App.swift"])

        XCTAssertEqual(reason, "working tree not clean (untracked, colliding): docs/new-page.md")
    }

    func testMergeRefusalTreatsAnUntrackedDirectoryAsCollidingWithWhatLandsInIt() {
        // git collapses a wholly-untracked directory into one `dir/` entry, so the
        // collision has to be read as a prefix — the merge writes *inside* it.
        let reason = WorktreeManager.mergeRefusal(
            porcelain: "?? docs/\n", incoming: ["docs/new-page.md"])

        XCTAssertEqual(reason, "working tree not clean (untracked, colliding): docs/")
    }

    func testMergeRefusalTreatsAnUnknownIncomingDiffAsColliding() {
        let reason = WorktreeManager.mergeRefusal(porcelain: "?? stray.txt\n", incoming: nil)

        XCTAssertEqual(reason, "working tree not clean (untracked, colliding): stray.txt")
    }

    // MARK: - Conflict merge refusal

    /// The gate builds in its own DerivedData, not the one the IDE launched the
    /// app from: a merged tree verified against Xcode's stale package products
    /// was refused for a call that existed in the tree it had just merged.
    func testGateBuildsGoToTheProjectsOwnDerivedData() {
        let root = URL(fileURLWithPath: "/repo", isDirectory: true)
        let command = WorktreeManager.gateCommand(
            "cd Kiteloop && xcodebuild -scheme Kiteloop build-for-testing", projectRoot: root)
        XCTAssertEqual(
            command,
            "cd Kiteloop && xcodebuild -derivedDataPath '/repo/.kiteloop/DerivedData' "
                + "-scheme Kiteloop build-for-testing")
        XCTAssertEqual(WorktreeManager.gateCommand("swift test", projectRoot: root), "swift test",
                       "a command that builds nothing with xcodebuild is left alone")
    }

    func testConflictRefusalNamesASinglePath() {
        XCTAssertEqual(
            WorktreeManager.conflictRefusal(paths: ["CHANGELOG.md"]),
            "merge conflict in: CHANGELOG.md")
    }

    func testConflictRefusalCapsThePathsAndCountsTheRest() {
        let reason = WorktreeManager.conflictRefusal(
            paths: ["one.swift", "two.swift", "three.swift", "four.swift", "five.swift"])

        XCTAssertEqual(reason, "merge conflict in: one.swift, two.swift, three.swift (+2 more)")
    }

    func testConflictRefusalFallsBackToTheBareReasonWithoutPaths() {
        XCTAssertEqual(WorktreeManager.conflictRefusal(paths: []), "merge conflict")
    }

    func testConflictRefusalNamesTheRebaseAttemptWhenItAlsoConflicted() {
        XCTAssertEqual(
            WorktreeManager.conflictRefusal(paths: ["CHANGELOG.md"], rebaseAlsoConflicted: true),
            "merge conflict in: CHANGELOG.md — a rebase onto the current base also conflicted")
    }

    func testConflictRefusalNamesTheRebaseAttemptEvenWithoutPaths() {
        XCTAssertEqual(
            WorktreeManager.conflictRefusal(paths: [], rebaseAlsoConflicted: true),
            "merge conflict — a rebase onto the current base also conflicted")
    }

    /// The item's own scenario: two branches both editing the same lines of
    /// `README.md` (standing in for `CHANGELOG.md`'s `— unreleased` section).
    /// The merge conflicts, and — since the branch is a single commit whose
    /// own edit genuinely disagrees with main's, the same content clash a
    /// rebase would face — the one automatic recovery also conflicts, so the
    /// item parks with both facts named and the branch exactly as it was.
    func testConflictingMergeNamesTheConflictingFileAndRollsBack() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "conflict-agent")
        try "branch change".write(
            to: path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "conflict-agent", message: "edit readme")
        await manager.removeWorktree(for: "conflict-agent", keepBranch: true)
        let preRebaseBranchTip = git(["rev-parse", "refs/heads/kiteloop/conflict-agent"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try "main change".write(
            to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "conflicting main edit"], in: tempDir)
        let preSHA = git(["rev-parse", "HEAD"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/conflict-agent", message: "merge", verify: .none)

        XCTAssertFalse(result.merged)
        XCTAssertEqual(
            result.reason,
            "merge conflict in: README.md — a rebase onto the current base also conflicted")
        // The checkout's HEAD never moved — the conflict happened, and was
        // aborted, in the scratch worktree.
        let postSHA = git(["rev-parse", "HEAD"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(postSHA, preSHA)
        XCTAssertEqual(
            try String(contentsOf: tempDir.appending(path: "README.md"), encoding: .utf8),
            "main change")
        // The rebase attempt never touched the branch either.
        let postRebaseBranchTip = git(["rev-parse", "refs/heads/kiteloop/conflict-agent"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(postRebaseBranchTip, preRebaseBranchTip)
    }

    /// The case the rebase recovery is for: a straight two-tree `--no-ff`
    /// merge only ever compares the branch's *final* content against main's,
    /// so it conflicts whenever those two final values disagree — even when
    /// they disagree only because the branch's own two commits *agree with
    /// main up to a point neither side shares a commit for* and then go
    /// further. Here the branch's first commit lands on exactly the text a
    /// sibling separately committed straight to main (a plausible real
    /// coincidence: both are the same obvious one-line fix), and its second
    /// commit refines that further. A plain merge sees only "main says X,
    /// branch says Y" and conflicts; replaying the branch's own commits one
    /// at a time recognizes the first as already applied, skips it, and
    /// applies the second cleanly — which is exactly "same line, different
    /// text" (`testConflictingMergeNamesTheConflictingFileAndRollsBack`)
    /// would *not* do, since that clash is real on both sides. The retried
    /// merge then lands with no one asked, the branch ref sits at the
    /// rebased tip, and the merged tree still runs through `verify`.
    func testAConflictTheRebaseCanResolveLandsWithNoOneAsked() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "rebase-agent")
        try "line4-v1".write(to: path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "rebase-agent", message: "the fix a sibling also makes")
        try "line4-v2".write(to: path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "rebase-agent", message: "refine it further")
        await manager.removeWorktree(for: "rebase-agent", keepBranch: true)
        let preRebaseBranchTip = git(["rev-parse", "refs/heads/kiteloop/rebase-agent"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A sibling lands, by hand, exactly the branch's first-commit fix.
        try "line4-v1".write(to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "sibling lands the same one-line fix"], in: tempDir)
        let mainTip = git(["rev-parse", "HEAD"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/rebase-agent", message: "merge",
            verify: .resolve(projectCommand: "true", itemVerify: nil))

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertEqual(result.verifyRan, ["merge-verify: true"])
        XCTAssertEqual(
            try String(contentsOf: tempDir.appending(path: "README.md"), encoding: .utf8), "line4-v2")
        let postRebaseBranchTip = git(["rev-parse", "refs/heads/kiteloop/rebase-agent"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(
            postRebaseBranchTip, preRebaseBranchTip,
            "the branch ref should be fast-forwarded to the rebased tip")
        XCTAssertTrue(
            git(["merge-base", "--is-ancestor", mainTip, "refs/heads/kiteloop/rebase-agent"], in: tempDir).status == 0,
            "the rebased branch should now be a descendant of main")
    }

    // MARK: - The project's worktreeSetupCommand

    /// Setup runs in the scratch worktree the merge itself uses, and before
    /// the verify plan does — so a project that needs `npm ci` or `xcodegen
    /// generate` to make the tree buildable at all gets it before anything
    /// tries to build. Order is read off a log file outside the scratch tree,
    /// since the scratch worktree is gone by the time the call returns.
    func testWorktreeSetupCommandRunsInTheScratchTreeBeforeVerify() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "setup-order-agent")
        try "change".write(to: path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "setup-order-agent", message: "add change")
        await manager.removeWorktree(for: "setup-order-agent", keepBranch: true)

        let log = tempDir.appendingPathComponent("setup-order.log").path(percentEncoded: false)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/setup-order-agent", message: "merge",
            verify: .resolve(projectCommand: "echo verify >> \(log)", itemVerify: nil),
            setupCommand: "echo setup >> \(log)")

        XCTAssertTrue(result.merged, result.reason)
        let lines = (try? String(contentsOfFile: log, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines) ?? []
        XCTAssertEqual(lines, ["setup", "verify"])
    }

    /// A setup command that fails refuses the merge outright — the merge
    /// never lands, and the verify plan never runs against a tree the project
    /// itself said wasn't fit to build.
    func testAFailingWorktreeSetupCommandRefusesTheMergeAndSkipsVerify() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "setup-fail-agent")
        try "change".write(to: path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "setup-fail-agent", message: "add change")
        await manager.removeWorktree(for: "setup-fail-agent", keepBranch: true)

        let log = tempDir.appendingPathComponent("setup-fail.log").path(percentEncoded: false)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/setup-fail-agent", message: "merge",
            verify: .resolve(projectCommand: "echo verify >> \(log)", itemVerify: nil),
            setupCommand: "exit 1")

        XCTAssertFalse(result.merged)
        XCTAssertEqual(result.reason, "setup failed in merged tree (exit 1)")
        XCTAssertEqual(result.verifyRan, [], "verify must not run against an unfit tree")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log), "the verify step must never have run")
    }

    /// The item's own scenario: a sibling's merge has landed on the base since
    /// this branch was cut, and both touch the same file — `checkFreshness`
    /// reads that as `clean: false`, naming the file, without ever checking
    /// anything out or touching the real branch.
    func testCheckFreshnessNamesTheConflictingFileWithoutTouchingTheCheckout() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "stale-agent")
        try "branch change".write(
            to: path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "stale-agent", message: "edit readme")
        await manager.removeWorktree(for: "stale-agent", keepBranch: true)

        // The sibling merge: a second commit lands on the base, on the same file.
        try "main change".write(
            to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "sibling merge"], in: tempDir)
        let preSHA = git(["rev-parse", "HEAD"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let freshness = await manager.checkFreshness(branch: "kiteloop/stale-agent")

        XCTAssertFalse(freshness.clean)
        XCTAssertEqual(freshness.conflicts, ["README.md"])
        // Read-only: the checkout never moved and the file it started with is
        // still there — nothing was checked out, merged or rolled back.
        let postSHA = git(["rev-parse", "HEAD"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(postSHA, preSHA)
        XCTAssertEqual(
            try String(contentsOf: tempDir.appending(path: "README.md"), encoding: .utf8),
            "main change")
    }

    /// A branch that touches a different file from every sibling merge still
    /// merges cleanly, and reports so with no conflicts named.
    func testCheckFreshnessReadsCleanWhenTheBranchStillMerges() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "clean-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "clean-agent", message: "add feature")
        await manager.removeWorktree(for: "clean-agent", keepBranch: true)

        // A sibling merge on the base, touching an unrelated file.
        try "main change".write(
            to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "sibling merge"], in: tempDir)

        let freshness = await manager.checkFreshness(branch: "kiteloop/clean-agent")

        XCTAssertTrue(freshness.clean)
        XCTAssertEqual(freshness.conflicts, [])
    }

    /// The tip a verdict was computed against, so a caller holding an older
    /// verdict can tell the branch has since moved without re-running the
    /// merge probe: `branchTip(for:)` is the cheap live read, `checkFreshness`'s
    /// `branchTip` the one recorded at verdict time — a commit to the branch
    /// between the two calls must move the second past the first.
    func testCheckFreshnessRecordsTheBranchTipAndBranchTipReadsItLive() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "tip-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "tip-agent", message: "add feature")

        let freshness = await manager.checkFreshness(branch: "kiteloop/tip-agent")
        let liveTip = await manager.branchTip(for: "tip-agent")

        XCTAssertFalse(freshness.branchTip.isEmpty)
        XCTAssertEqual(freshness.branchTip, liveTip)

        // A further commit to the branch moves the live tip past the verdict
        // recorded above, without that verdict knowing.
        try "more work".write(to: path.appending(path: "feature2.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "tip-agent", message: "add more")

        let laterTip = await manager.branchTip(for: "tip-agent")
        XCTAssertNotEqual(laterTip, freshness.branchTip)
    }

    func testClassifySkipsIgnoredEntries() {
        let tree = WorktreeManager.classify(porcelain: "!! .build/\n M a.swift\n?? b.txt\n")

        XCTAssertEqual(tree, WorktreeManager.DirtyTree(
            modified: ["a.swift"], untracked: ["b.txt"], unreadable: false))
    }

    /// The defect this item exists to fix: an uncommitted edit to a file the
    /// merge never touches used to refuse every approval regardless. Now the
    /// merge goes through and the unrelated dirt is left exactly as it was.
    func testMergeProceedsWithAnUnrelatedModifiedFileInTheCheckout() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "merge-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "merge-agent", message: "add feature")
        await manager.removeWorktree(for: "merge-agent", keepBranch: true)

        try "dirt".write(to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/merge-agent", message: "merge", verify: .none)

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
        XCTAssertEqual(
            try String(contentsOf: tempDir.appending(path: "README.md"), encoding: .utf8), "dirt")
    }

    /// The other half: an uncommitted edit to a file the merge *does* touch is
    /// still refused, naming the path — the merge would otherwise throw it away.
    func testMergeRefusesATrackedFileTheBranchAlsoTouches() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "overlap-agent")
        try "branch change".write(
            to: path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "overlap-agent", message: "edit readme")
        await manager.removeWorktree(for: "overlap-agent", keepBranch: true)

        try "local edit".write(
            to: tempDir.appending(path: "README.md"), atomically: true, encoding: .utf8)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/overlap-agent", message: "merge", verify: .none)

        XCTAssertFalse(result.merged)
        XCTAssertEqual(result.reason, "working tree not clean (modified): README.md")
        XCTAssertEqual(
            try String(contentsOf: tempDir.appending(path: "README.md"), encoding: .utf8), "local edit")
    }

    /// The defect this split exists for: an untracked `.claude/settings.local.json`
    /// — which tooling drops in routinely and no merge touches — used to refuse
    /// every approval in the project.
    func testMergeProceedsWithANonCollidingUntrackedFileInTheLiveTree() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "untracked-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "untracked-agent", message: "add feature")
        await manager.removeWorktree(for: "untracked-agent", keepBranch: true)

        let stray = tempDir.appending(path: "settings.local.json")
        try "{}".write(to: stray, atomically: true, encoding: .utf8)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/untracked-agent", message: "merge", verify: .none)

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
        // The merge left the stray file exactly where it was.
        XCTAssertEqual(try String(contentsOf: stray, encoding: .utf8), "{}")
    }

    func testMergeRefusesAnUntrackedFileTheBranchAlsoIntroduces() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "collide-agent")
        try "branch".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "collide-agent", message: "add feature")
        await manager.removeWorktree(for: "collide-agent", keepBranch: true)

        // Same path, untracked in the live tree — `git merge` would have to
        // overwrite it, so this one is a real refusal.
        try "local".write(to: tempDir.appending(path: "feature.txt"), atomically: true, encoding: .utf8)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/collide-agent", message: "merge", verify: .none)

        XCTAssertFalse(result.merged)
        XCTAssertEqual(result.reason, "working tree not clean (untracked, colliding): feature.txt")
        XCTAssertEqual(
            try String(contentsOf: tempDir.appending(path: "feature.txt"), encoding: .utf8), "local")
    }

    /// Validation bullet 4: a clean first merge is untouched by the rebase
    /// recovery — no rebase runs, and the branch's own ref, and every other
    /// ref, is exactly what it was before.
    func testMergeStillSucceedsOnACleanTree() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "clean-merge-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "clean-merge-agent", message: "add feature")
        await manager.removeWorktree(for: "clean-merge-agent", keepBranch: true)
        let preBranchTip = git(["rev-parse", "refs/heads/kiteloop/clean-merge-agent"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preRefs = git(["for-each-ref", "--format=%(refname)"], in: tempDir).output

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/clean-merge-agent", message: "merge", verify: .none)

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertEqual(result.reason, "merged")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
        let postBranchTip = git(["rev-parse", "refs/heads/kiteloop/clean-merge-agent"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(postBranchTip, preBranchTip, "no rebase ran, so the branch's own tip never moved")
        let postRefs = git(["for-each-ref", "--format=%(refname)"], in: tempDir).output
        XCTAssertEqual(postRefs, preRefs, "no temporary ref was left behind")
    }
}

/// The gate's verify: where it runs, what it captures, how it ends, what its shell carries, and retries.
final class WorktreeManagerGateVerifyTests: WorktreeManagerTestCase {
    // MARK: - The gate's verify runs in a scratch worktree

    /// The item this covers: a merge-verify that rewrites a tracked file (a
    /// status file, a `.pyc`, a build artifact) must not leave that rewrite in
    /// the checkout. It runs in a scratch worktree instead, which is gone once
    /// the merge is done — the checkout only ever gains what the merge itself
    /// brought.
    func testVerifysWritesLandInTheScratchWorktreeNotTheCheckout() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "verify-writes-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "verify-writes-agent", message: "add feature")
        await manager.removeWorktree(for: "verify-writes-agent", keepBranch: true)

        let beforeReadme = try String(contentsOf: tempDir.appending(path: "README.md"), encoding: .utf8)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/verify-writes-agent", message: "merge",
            verify: .resolve(projectCommand: nil, itemVerify: "echo verify-ran >> README.md"))

        XCTAssertTrue(result.merged, result.reason)
        // The verify step wrote to a tracked file — that write must not have
        // reached the checkout.
        XCTAssertEqual(
            try String(contentsOf: tempDir.appending(path: "README.md"), encoding: .utf8), beforeReadme)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
        let scratchDir = tempDir.appending(
            path: ".kiteloop/worktrees/verify-writes-agent-merge-gate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDir.path(percentEncoded: false)))
    }

    /// A red verify must not move the base ref, and must not leave the scratch
    /// worktree it ran in behind — the same "torn down whatever the outcome"
    /// as a green one, just with nothing to fast-forward to.
    func testARedVerifyLeavesTheBaseRefUnmovedAndTheScratchWorktreeGone() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "red-verify-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "red-verify-agent", message: "add feature")
        await manager.removeWorktree(for: "red-verify-agent", keepBranch: true)

        let preSHA = git(["rev-parse", "HEAD"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/red-verify-agent", message: "merge",
            verify: .resolve(projectCommand: nil, itemVerify: "exit 1"))

        XCTAssertFalse(result.merged)
        let postSHA = git(["rev-parse", "HEAD"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(postSHA, preSHA)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
        let scratchDir = tempDir.appending(path: ".kiteloop/worktrees/red-verify-agent-merge-gate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDir.path(percentEncoded: false)))
    }

    // MARK: - Both gates run (the 2026-08-10 travel incident)

    /// The defect itself, reproduced: a project merge-verify command that passes
    /// on a diff it knows nothing about (a web test suite against a Rust change),
    /// beside an item `verify:` that fails (the CI script that compiles the
    /// Rust). The project command used to *replace* the item's, so this merged.
    /// Now the item's verify still runs, the merge is refused, and the reason
    /// names which command refused it.
    func testAPassingProjectCommandCannotCarryAFailingItemVerify() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "rust-agent")
        try "work".write(to: path.appending(path: "route.rs"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "rust-agent", message: "add route")
        await manager.removeWorktree(for: "rust-agent", keepBranch: true)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/rust-agent", message: "merge",
            verify: .resolve(projectCommand: "true",           // the web suite: green, and irrelevant
                             itemVerify: "exit 1"))            // the item's own CI: red

        XCTAssertFalse(result.merged, "a green unrelated suite must not stand in for the item's verify")
        XCTAssertEqual(result.reason, "verify failed on merged tree (item verify: exit 1)")
        XCTAssertEqual(result.verifyRan, ["item verify: exit 1"],
                       "the item's verify runs first, so the project command never got the chance")
        // main never advanced — the merge only ran in the scratch worktree.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "route.rs").path(percentEncoded: false)))
    }

    /// The other half of "both must pass": a failing project command still
    /// refuses a merge whose item verify was green, and the reason says so.
    func testAFailingProjectCommandRefusesAGreenItemVerify() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "project-gate-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "project-gate-agent", message: "add feature")
        await manager.removeWorktree(for: "project-gate-agent", keepBranch: true)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/project-gate-agent", message: "merge",
            verify: .resolve(projectCommand: "exit 1", itemVerify: "true"))

        XCTAssertFalse(result.merged)
        XCTAssertEqual(result.reason, "verify failed on merged tree (merge-verify: exit 1)")
        XCTAssertEqual(result.verifyRan, ["item verify: true", "merge-verify: exit 1"],
                       "both ran — the failure was the second one")
    }

    /// A kept merge names everything that gated it, so a merge validated by a
    /// suite unrelated to the diff is visible afterwards without pairing the
    /// diff with whatever the project config said that night.
    func testAKeptMergeNamesEveryCommandThatGatedIt() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "both-green-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "both-green-agent", message: "add feature")
        await manager.removeWorktree(for: "both-green-agent", keepBranch: true)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/both-green-agent", message: "merge",
            verify: .resolve(projectCommand: "true", itemVerify: "echo item-ran"))

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertEqual(result.verifyRan, ["item verify: echo item-ran", "merge-verify: true"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
    }

    /// Nothing configured: the merge is kept, and `verifyRan` says plainly that
    /// nothing checked it rather than reading like a passed gate.
    func testAnUnverifiedMergeRecordsThatNothingRan() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "unverified-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "unverified-agent", message: "add feature")
        await manager.removeWorktree(for: "unverified-agent", keepBranch: true)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/unverified-agent", message: "merge", verify: .none)

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertTrue(result.verifyRan.isEmpty)
    }

    // MARK: - Verify output capture

    /// The merge and its verify both happen in a scratch worktree that's
    /// discarded either way, so the failing tree is gone by the time anyone
    /// reads the reason. Without the command's output the operator at the
    /// gate has nothing to decide on — that is the dead end this capture ends.
    func testAFailedMergeVerifyCarriesTheCommandsOutput() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "verify-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "verify-agent", message: "add feature")
        await manager.removeWorktree(for: "verify-agent", keepBranch: true)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/verify-agent", message: "merge",
            verify: .resolve(projectCommand: nil,
                             itemVerify: "echo 'error: cannot find foo' >&2 && exit 3"))

        XCTAssertFalse(result.merged)
        XCTAssertEqual(
            result.reason,
            "verify failed on merged tree (item verify: echo 'error: cannot find foo' >&2 && exit 3)")
        XCTAssertTrue(result.verifyOutput?.contains("error: cannot find foo") == true,
                      "stderr not captured: \(result.verifyOutput ?? "nil")")
        // A single unretried attempt still leaves the ledger/Notes-facing
        // record: attempt 1 of 1, not recovered — so a red merge that was
        // never even retried is just as readable afterwards as one that was.
        XCTAssertEqual(result.stepOutputs.count, 1)
        XCTAssertEqual(result.stepOutputs.first?.attempt, 1)
        XCTAssertEqual(result.stepOutputs.first?.totalAttempts, 1)
        XCTAssertFalse(result.stepOutputs.first?.recovered ?? true)
        XCTAssertTrue(result.stepOutputs.first?.output.contains("error: cannot find foo") == true)
        // Capturing the evidence must not have let a red merge onto the
        // checked-out branch.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
    }

    /// A refusal that never ran a command has nothing to show, and must not
    /// invent an empty capture the UI would offer to display.
    func testARefusalWithNoVerifyCarriesNoOutput() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "no-verify-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "no-verify-agent", message: "add feature")
        await manager.removeWorktree(for: "no-verify-agent", keepBranch: true)
        // A refusal that never runs the verify: the merge itself conflicts —
        // main commits its own feature.txt after the branch's. A merely dirty
        // checkout no longer refuses; merge and verify run in a scratch tree.
        try "conflicting".write(to: tempDir.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        git(["add", "feature.txt"], in: tempDir)
        git(["commit", "-m", "conflicting feature"], in: tempDir)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/no-verify-agent", message: "merge",
            verify: .resolve(projectCommand: "true", itemVerify: nil))

        XCTAssertFalse(result.merged)
        XCTAssertNil(result.verifyOutput)
        XCTAssertTrue(result.stepOutputs.isEmpty)
    }

    /// The reason output goes to a file rather than a `Pipe()`: an xcodebuild
    /// writes far more than a pipe buffer holds, and an undrained one deadlocks.
    /// Well past that buffer, the command still finishes and the end is kept.
    func testAVerboseVerifyNeitherHangsNorReturnsItsWholeLog() {
        let result = WorktreeManager.runShellCapturingOutput(
            "for i in $(seq 1 60000); do echo \"line $i padding padding padding\"; done && exit 1",
            in: tempDir, timeout: 120)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.output.contains("line 60000"), "the end of the log is what matters")
        XCTAssertLessThanOrEqual(result.output.utf8.count,
                                 WorktreeManager.verifyOutputTailBytes + 200,
                                 "the whole log was kept")
        XCTAssertTrue(result.output.hasPrefix("… (earlier output omitted"), result.output.prefix(120).description)
    }

    func testCapturedOutputOfAShortCommandIsKeptWhole() {
        let result = WorktreeManager.runShellCapturingOutput("echo hello && exit 0", in: tempDir)

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.output, "hello\n")
        XCTAssertFalse(result.timedOut)
    }

    // MARK: - The exit status itself

    /// `ok` collapses every non-zero answer into one bit, and an audit needs the
    /// number: `exit 1` and `exit 3` are different verdicts, and neither is a
    /// command that could not be spawned at all.
    func testCapturedStatusIsTheChildsOwnExitStatus() {
        XCTAssertEqual(WorktreeManager.runShellCapturingStatus("exit 0", in: tempDir).status, 0)
        XCTAssertEqual(WorktreeManager.runShellCapturingStatus("exit 1", in: tempDir).status, 1)

        let three = WorktreeManager.runShellCapturingStatus("echo nope >&2; exit 3", in: tempDir)
        XCTAssertEqual(three.status, 3)
        XCTAssertEqual(three.output, "nope\n", "stderr is captured beside stdout")
        XCTAssertFalse(three.timedOut)
    }

    /// A command killed at the deadline never returned a status, so none is
    /// invented for it: `noExitStatus` is negative, which no command can exit
    /// with, and `timedOut` says which of the two no-answer cases it was.
    func testAKilledCommandCarriesNoExitStatus() {
        let result = WorktreeManager.runShellCapturingStatus("sleep 30", in: tempDir, timeout: 1)

        XCTAssertEqual(result.status, WorktreeManager.noExitStatus)
        XCTAssertLessThan(WorktreeManager.noExitStatus, 0, "no exit code can collide with it")
        XCTAssertTrue(result.timedOut)
    }

    // MARK: - A killed command says it was killed

    /// A command still running at the deadline is killed, and comes back saying
    /// so. The exit status it leaves behind is a termination signal that looks
    /// like any other failure, so the poll loop is the only thing that ever knew
    /// the difference — this is where it stops being thrown away.
    func testACommandKilledAtItsDeadlineReportsThatItTimedOut() {
        let result = WorktreeManager.runShellCapturingOutput("sleep 30", in: tempDir, timeout: 1)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.timedOut)
    }

    /// The other half: a command that reached its own exit code did finish, and
    /// must not be reported as an overrun however loudly it failed.
    func testACommandThatFailsOnItsOwnDoesNotReportATimeout() {
        let result = WorktreeManager.runShellCapturingOutput(
            "echo 'error: cannot find foo' >&2 && exit 3", in: tempDir, timeout: 60)

        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.output.contains("error: cannot find foo"))
    }

    /// The pid `wait(for:timeout:)` signals is the shell, or whatever it exec'd
    /// into — never what that process forked. A `sleep … & wait` shell leaves
    /// the backgrounded sleep as a child neither TERM nor KILL on the shell
    /// itself reaches; this is the sweep that collects and kills it too.
    func testATimedOutCommandsForkedChildIsAlsoKilled() {
        let result = WorktreeManager.runShellCapturingOutput(
            "sleep 810001 & wait", in: tempDir, timeout: 1)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(isProcessRunning(matching: "sleep 810001"),
                        "the forked child must not survive the call returning")
    }

    /// The sweep only reaches pids collected as descendants of the process
    /// this call started — never anything merely matching the killed
    /// command's text. A bystander process sharing that text must survive.
    func testASweepLeavesAProcessThatOnlySharesTheKilledCommandsTextAlone() {
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["810002"]
        try? bystander.run()
        defer {
            bystander.terminate()
            bystander.waitUntilExit()
        }

        let result = WorktreeManager.runShellCapturingOutput(
            "sleep 810002 & wait", in: tempDir, timeout: 1)

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(bystander.isRunning,
                       "a process outside this call's own tree must not be touched")
    }

    // MARK: - The verify shell's PATH is the app's composed one

    /// The child's `PATH` is exported explicitly rather than left to `-l`: a
    /// login shell reads `~/.zprofile` and not `~/.zshrc`, which is how a
    /// pip-installed `lizard` was invisible at the merge verify on 2026-09-03.
    /// Proved from inside the shell — it prints what it was given — with the
    /// project's own `extraExecutablePaths` at the end and the fixed extras
    /// before them.
    func testTheVerifyShellRunsWithTheComposedPathIncludingTheProjectsExtras() throws {
        let project = KiteloopProject(rootURL: tempDir)
        try project.ensureKiteloopDirectory()
        var config = ProjectConfig.default
        config.extraExecutablePaths = ["~/kiteloop-test-tools/bin", "/srv/project-only/bin"]
        try project.saveConfig(config)

        let result = WorktreeManager.runShellCapturingOutput(
            "printf '%s' \"$PATH\" > out.txt", in: tempDir, timeout: 60, projectRoot: tempDir)

        XCTAssertTrue(result.ok)
        let path = try String(contentsOf: tempDir.appending(path: "out.txt"), encoding: .utf8)
        let directories = path.split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        XCTAssertEqual(directories.suffix(2), ["\(home)/kiteloop-test-tools/bin", "/srv/project-only/bin"], path)
        XCTAssertTrue(directories.contains("/opt/homebrew/bin"), path)
        XCTAssertTrue(directories.contains("\(home)/.cargo/bin"), path)
    }

    // MARK: - The verify shell carries the project's build exports

    /// Beside `PATH` the shell gets the project's build exports: a `Cargo.toml`
    /// at the root shares one cargo target directory under the project's own
    /// `.kiteloop/build`, so an item does not pay the cold `cargo build` its
    /// predecessor already paid — 18 to 27 minutes a run for a Rust project's
    /// items on 2026-09-03. Proved from inside the shell, the way the `PATH`
    /// test above is.
    func testTheVerifyShellExportsTheProjectsSharedCargoTargetDirectory() throws {
        try "[package]\n".write(to: tempDir.appending(path: "Cargo.toml"), atomically: true, encoding: .utf8)

        let result = WorktreeManager.runShellCapturingOutput(
            "printf '%s' \"$CARGO_TARGET_DIR\" > out.txt", in: tempDir, timeout: 60, projectRoot: tempDir)

        XCTAssertTrue(result.ok)
        let exported = try String(contentsOf: tempDir.appending(path: "out.txt"), encoding: .utf8)
        XCTAssertEqual(exported, tempDir.appending(path: ".kiteloop/build/cargo").path(percentEncoded: false))
    }

    /// The merge scratch worktree is where a verify that needs a build artifact
    /// used to be certain to fail — its `target/` never existed. The scratch
    /// verify runs on the project's behalf, so it gets the same shared target
    /// directory the item's own run built into.
    func testTheMergeScratchVerifyReceivesTheSharedBuildExports() async throws {
        try "[package]\n".write(to: tempDir.appending(path: "Cargo.toml"), atomically: true, encoding: .utf8)
        git(["add", "Cargo.toml"], in: tempDir)
        git(["commit", "-m", "rust project"], in: tempDir)
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "cargo-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "cargo-agent", message: "add feature")
        await manager.removeWorktree(for: "cargo-agent", keepBranch: true)
        // `.kiteloop/` is untracked and never collides with the branch, so the
        // record survives the fast-forward without dirtying the merge.
        let record = tempDir.appending(path: ".kiteloop/cargo-target.txt")

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/cargo-agent", message: "merge",
            verify: .resolve(projectCommand: nil,
                             itemVerify: "printf '%s' \"$CARGO_TARGET_DIR\" > '\(record.path(percentEncoded: false))'"))

        XCTAssertTrue(result.merged, result.reason)
        let exported = try String(contentsOf: record, encoding: .utf8)
        XCTAssertEqual(exported, tempDir.appending(path: ".kiteloop/build/cargo").path(percentEncoded: false))
    }

    /// The flag rides on the capturing call only. `runShell` is the salvage
    /// re-check's plain yes/no and stays one — the annotation is the assertion,
    /// so widening it would stop this compiling rather than quietly change what
    /// every call site of it reads.
    func testRunShellStillAnswersAPlainBool() {
        let passed: Bool = WorktreeManager.runShell("exit 0", in: tempDir, timeout: 60)
        let failed: Bool = WorktreeManager.runShell("exit 1", in: tempDir, timeout: 60)

        XCTAssertTrue(passed)
        XCTAssertFalse(failed)
    }

    /// The refusal an operator actually reads. A verify killed at the deadline
    /// judged nothing about the merged tree, and one that printed nothing before
    /// it was killed leaves an empty `verifyOutput` the payload then omits — so
    /// the reason is the only place "never finished" can be told from "failed".
    func testAMergeVerifyKilledAtItsDeadlineSaysSoInTheReason() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "slow-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "slow-agent", message: "add feature")
        await manager.removeWorktree(for: "slow-agent", keepBranch: true)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/slow-agent", message: "merge",
            verify: .resolve(projectCommand: nil, itemVerify: "sleep 30"),
            timeout: 1)

        XCTAssertFalse(result.merged)
        XCTAssertEqual(result.reason, "verify timed out after 1s on merged tree (item verify: sleep 30)")
        XCTAssertEqual(result.verifyRan, ["item verify: sleep 30"])
        // The checkout never advanced: an unfinished gate is still not a
        // passed one.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
    }

    /// A step that failed on its own keeps the wording it has always had, timeout
    /// or no timeout — the new sentence is for overruns only.
    func testAMergeVerifyThatFailedOnItsOwnKeepsTheOriginalReason() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "quick-fail-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "quick-fail-agent", message: "add feature")
        await manager.removeWorktree(for: "quick-fail-agent", keepBranch: true)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/quick-fail-agent", message: "merge",
            verify: .resolve(projectCommand: nil, itemVerify: "exit 1"),
            timeout: 30)

        XCTAssertFalse(result.merged)
        XCTAssertEqual(result.reason, "verify failed on merged tree (item verify: exit 1)")
    }

    // MARK: - Retried failures (2026-08-28 travel gate incident)

    /// The recovery case: a crash signature on the first attempt, a clean pass
    /// on the retry. The merge lands, and the reason says a retry is why.
    func testACrashedVerifyRecoversOnRetryAndMerges() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "crash-retry-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "crash-retry-agent", message: "add feature")
        await manager.removeWorktree(for: "crash-retry-agent", keepBranch: true)

        // Crashes once (a marker file that isn't there yet), then passes once
        // the marker exists — standing in for a test binary rewritten under a
        // concurrent run that crashes once and is fine the second time.
        let marker = FileManager.default.temporaryDirectory
            .appending(path: "kiteloop-crash-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let markerPath = marker.path(percentEncoded: false)
        let command = "test -f \(markerPath) && exit 0 || " +
            "(touch \(markerPath); echo 'child process crashed: SIGSEGV' >&2; exit 139)"

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/crash-retry-agent", message: "merge",
            verify: .resolve(projectCommand: nil, itemVerify: command))

        XCTAssertTrue(result.merged, result.reason)
        let label = MergeVerifyPlan.Step(source: .item, command: command).label
        XCTAssertEqual(result.reason,
                       "verify failed on merged tree (\(label)) — crashed (SIGSEGV) then passed")
        XCTAssertEqual(result.verifyRan, [label])
        // A merge that landed still keeps what its first, failing attempt
        // printed — a passing merge with nothing retried writes none of this,
        // but a recovered one is not the same as a clean pass.
        XCTAssertEqual(result.stepOutputs.count, 1)
        XCTAssertEqual(result.stepOutputs.first?.attempt, 1)
        XCTAssertEqual(result.stepOutputs.first?.totalAttempts, 2)
        XCTAssertTrue(result.stepOutputs.first?.recovered ?? false)
        XCTAssertTrue(result.stepOutputs.first?.output.contains("crashed: SIGSEGV") == true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
    }

    /// The other half: a crash on both attempts is refused, naming the class
    /// and that a retry was already spent — not the plain "verify failed"
    /// wording a first-attempt refusal gets.
    func testACrashedVerifyThatFailsTwiceIsRefusedNamingTheClassAndTwice() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "crash-twice-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "crash-twice-agent", message: "add feature")
        await manager.removeWorktree(for: "crash-twice-agent", keepBranch: true)

        let command = "echo 'child process crashed: SIGSEGV' >&2; exit 139"

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/crash-twice-agent", message: "merge",
            verify: .resolve(projectCommand: nil, itemVerify: command))

        XCTAssertFalse(result.merged)
        let label = MergeVerifyPlan.Step(source: .item, command: command).label
        XCTAssertEqual(result.reason, "verify failed on merged tree (\(label)) — crashed twice (SIGSEGV)")
        // The second, still-failing attempt is what is kept — attempt 2 of 2,
        // not recovered.
        XCTAssertEqual(result.stepOutputs.count, 1)
        XCTAssertEqual(result.stepOutputs.first?.attempt, 2)
        XCTAssertEqual(result.stepOutputs.first?.totalAttempts, 2)
        XCTAssertFalse(result.stepOutputs.first?.recovered ?? true)
        XCTAssertTrue(result.stepOutputs.first?.output.contains("crashed: SIGSEGV") == true)
        // The checkout still never advanced — a retried failure is refused
        // exactly as a first-attempt one is.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
    }

    /// A merge whose steps all passed outright has nothing to retry and
    /// writes no step output — the counterpart to the two tests above, which
    /// both need a retry to have anything to keep.
    func testAPassingMergeWithNoRetriesWritesNoStepOutput() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "clean-pass-agent")
        try "work".write(to: path.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = await manager.commitAll(for: "clean-pass-agent", message: "add feature")
        await manager.removeWorktree(for: "clean-pass-agent", keepBranch: true)

        let result = await manager.mergeAndVerify(
            branch: "kiteloop/clean-pass-agent", message: "merge",
            verify: .resolve(projectCommand: "true", itemVerify: nil))

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertTrue(result.stepOutputs.isEmpty)
        XCTAssertNil(WorktreeManager.verifyStepOutputsNote(result.stepOutputs))
    }

    /// The one place the ledger row and a `## Notes` entry's shape is decided:
    /// which step, which attempt, whether it recovered, and the output —
    /// joined, when there is more than one, by a blank line.
    func testVerifyStepOutputsNoteJoinsEveryKeptStepAndOmitsNothingKept() {
        XCTAssertNil(WorktreeManager.verifyStepOutputsNote([]))

        let step = MergeVerifyPlan.Step(source: .item, command: "swift test")
        let recovered = WorktreeManager.VerifyStepOutput(
            stepLabel: step.label, attempt: 1, totalAttempts: 2, recovered: true, output: "flaked once")
        let failed = WorktreeManager.VerifyStepOutput(
            stepLabel: "merge-verify: xcodebuild build-for-testing", attempt: 2, totalAttempts: 2,
            recovered: false, output: "still red")

        let note = WorktreeManager.verifyStepOutputsNote([recovered, failed])
        XCTAssertEqual(note, """
            \(step.label) (attempt 1 of 2 — recovered):
            flaked once

            merge-verify: xcodebuild build-for-testing (attempt 2 of 2):
            still red
            """)
    }

    func testClassifyVerifyFailureRecognizesACrashSignature() {
        XCTAssertEqual(
            WorktreeManager.classifyVerifyFailure("Fatal error: SIGSEGV in child process"),
            .crash(signal: "SIGSEGV"))
    }

    func testClassifyVerifyFailureRecognizesALockTimeout() {
        XCTAssertEqual(
            WorktreeManager.classifyVerifyFailure(
                "error: waiting for lock on ci-local held by process 4212"),
            .lockTimeout)
    }

    func testClassifyVerifyFailureRecognizesANamedTestFailure() {
        XCTAssertEqual(
            WorktreeManager.classifyVerifyFailure("PASS src/a.test.tsx\nFAIL src/b.test.tsx\n"),
            .testFailure(name: "src/b.test.tsx"))
    }

    /// A jest row names a file; anything else after `FAIL` is not a test.
    func testClassifyVerifyFailureKeepsOnlyThePathOfAJestRow() {
        XCTAssertEqual(
            WorktreeManager.classifyVerifyFailure("FAIL src/b.test.tsx (5.2 s)\n"),
            .testFailure(name: "src/b.test.tsx"))
    }

    /// `quality/bin/gate.py` prints `  FAIL  escapes` for a red gate — two
    /// spaces and a gate name. That is a deterministic verdict, not a flaky
    /// test, and it must not earn a retry.
    func testClassifyVerifyFailureDoesNotReadAGateRowAsATest() {
        XCTAssertNil(WorktreeManager.classifyVerifyFailure(
            "  ok    complexity\n  FAIL  escapes\n        FAIL: baseline records 3, code has 2\n"))
        XCTAssertNil(WorktreeManager.classifyVerifyFailure("FAIL escapes\n"))
    }

    /// A failure that reproduced on the retry is the work being red, and the
    /// refusal must not call it flaky.
    func testRefusedTwiceNoteDoesNotCallAReproducedFailureFlaky() {
        let note = VerifyFailureClass.testFailure(name: "src/b.test.tsx").refusedTwiceNote
        XCTAssertEqual(note, "src/b.test.tsx failed on both attempts")
        XCTAssertFalse(note.lowercased().contains("flaky"))
    }

    /// The "as today" case: a failure that names none of the three classes is
    /// left alone, unclassified, so the caller refuses it on the first attempt.
    func testClassifyVerifyFailureReturnsNilForAnUnrecognizedFailure() {
        XCTAssertNil(WorktreeManager.classifyVerifyFailure("error: cannot find foo\nexit status 1\n"))
    }
}

/// A project that names its base branch.
final class WorktreeManagerBaseBranchTests: WorktreeManagerTestCase {
    // MARK: - A project names its base branch

    /// The fork: with a base named, the worktree starts at that branch's tip,
    /// not at the checkout's `HEAD` — here `feature` is one commit behind it.
    func testCreateForksFromTheNamedBaseBranch() async throws {
        makeBranch("feature")
        try "more".write(to: tempDir.appending(path: "more.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: tempDir)
        git(["commit", "-m", "advance the checkout"], in: tempDir)
        XCTAssertNotEqual(sha("feature"), sha("HEAD"), "the fixture needs the base behind the checkout")

        let manager = WorktreeManager(projectRoot: tempDir)
        let path = try await manager.create(for: "fork-agent", baseBranch: "feature")

        XCTAssertEqual(git(["rev-parse", "HEAD"], in: path).output.trimmingCharacters(in: .whitespacesAndNewlines),
                       sha("feature"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appending(path: "more.txt").path(percentEncoded: false)))
    }

    /// Case (a): the checkout is on the base, so the merge lands the way it
    /// always has — the checkout is fast-forwarded onto the merge commit.
    func testMergeLandsByFastForwardWhenTheCheckoutIsOnTheBase() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let branch = try await makeItemBranch("ff-agent", base: base, manager: manager)

        let result = await manager.mergeAndVerify(branch: branch, message: "merge", verify: .none, base: base)

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertEqual(sha("HEAD"), sha(base))
        XCTAssertEqual(result.mergeCommit, sha(base), "a landed merge names the commit the base now points at")
        XCTAssertEqual(sha("HEAD^2"), sha(branch), "the checkout's tip is the merge of the item branch")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)))
    }

    /// After a landed merge the branch is inside the base and the ref is all
    /// that is left; 345 of them had piled up on one project by 2026-09-20.
    func testAMergedBranchIsRemovedAndAnUnmergedOneIsKept() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let branch = try await makeItemBranch("tidy-agent", base: base, manager: manager)
        let kept = await manager.removeMergedBranch(for: "tidy-agent", base: base)
        XCTAssertEqual(kept, "\(branch) holds commits \(base) does not")
        XCTAssertEqual(sha(branch).isEmpty, false, "an unmerged branch is never deleted")

        let result = await manager.mergeAndVerify(branch: branch, message: "merge", verify: .none, base: base)
        XCTAssertTrue(result.merged, result.reason)

        let removed = await manager.removeMergedBranch(for: "tidy-agent", base: base)
        XCTAssertNil(removed)
        XCTAssertNotEqual(git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: tempDir).status, 0,
                          "the ref is gone")
        let again = await manager.removeMergedBranch(for: "tidy-agent", base: base)
        XCTAssertNil(again, "and asking again is not an error")
    }

    /// The sweep at project open takes the landed branches from before
    /// landing removed its own — and leaves an unmerged one alone.
    func testTheSweepRemovesLandedItemBranchesAndKeepsUnmergedOnes() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let landed = try await makeItemBranch("landed-agent", base: base, manager: manager, file: "landed.txt")
        let pending = try await makeItemBranch("pending-agent", base: base, manager: manager, file: "pending.txt")
        let result = await manager.mergeAndVerify(branch: landed, message: "merge", verify: .none, base: base)
        XCTAssertTrue(result.merged, result.reason)
        _ = await manager.removeMergedBranch(for: "landed-agent", base: base)
        XCTAssertEqual(git(["branch", "kiteloop/landed-agent", base], in: tempDir).status, 0, "put the landed ref back")

        let report = await manager.sweep(base: base)

        XCTAssertEqual(report.landedBranchesRemoved, ["landed-agent"])
        XCTAssertNotEqual(git(["rev-parse", "--verify", "--quiet", "refs/heads/\(landed)"], in: tempDir).status, 0)
        XCTAssertEqual(git(["rev-parse", "--verify", "--quiet", "refs/heads/\(pending)"], in: tempDir).status, 0,
                       "the unmerged branch is kept")
        XCTAssertTrue(report.logLines.contains { $0.contains("removed 1 landed item branch(es): landed-agent") }, "\(report.logLines)")
    }

    /// Case (c): the base is a branch nothing has checked out. The ref moves to
    /// the merge commit and the checkout — on another branch — is left exactly
    /// where it was: the app never switches a checkout.
    func testMergeLandsByRefUpdateWhenTheCheckoutIsOnAnotherBranch() async throws {
        makeBranch("release")
        let manager = WorktreeManager(projectRoot: tempDir)
        let branch = try await makeItemBranch("ref-agent", base: "release", manager: manager)
        let checkoutBefore = sha("HEAD")
        let releaseBefore = sha("release")

        let result = await manager.mergeAndVerify(branch: branch, message: "merge", verify: .none, base: "release")

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertNotEqual(sha("release"), releaseBefore, "the base ref did not move")
        XCTAssertEqual(sha("release^1"), releaseBefore)
        XCTAssertEqual(sha("release^2"), sha(branch), "the base's tip is the merge of the item branch")
        XCTAssertEqual(sha("HEAD"), checkoutBefore, "the checkout must not move")
        XCTAssertEqual(checkoutBranch(), checkoutBranch(), "still on its own branch")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "feature.txt").path(percentEncoded: false)),
            "the merge landed on the ref, not in the checkout's tree")
    }

    /// Case (b), the 2026-09-03 shape: the base is checked out in another
    /// worktree of the repository — a stale scratch, a review checkout. The
    /// merge is refused naming that worktree's path, and the ref is not moved
    /// under it, which `git update-ref` alone would happily have done.
    func testMergeRefusesWhenAnotherWorktreeHasTheBaseCheckedOut() async throws {
        makeBranch("release")
        let manager = WorktreeManager(projectRoot: tempDir)
        let branch = try await makeItemBranch("held-agent", base: "release", manager: manager)
        let elsewhere = tempDir.appending(path: ".kiteloop/worktrees/stale-merge-gate")
        XCTAssertEqual(git(["worktree", "add", elsewhere.path(percentEncoded: false), "release"], in: tempDir).status, 0)
        defer { git(["worktree", "remove", "--force", elsewhere.path(percentEncoded: false)], in: tempDir) }
        let releaseBefore = sha("release")

        let result = await manager.mergeAndVerify(branch: branch, message: "merge", verify: .none, base: "release")

        XCTAssertFalse(result.merged)
        XCTAssertTrue(result.reason.contains("base branch release is checked out at"), result.reason)
        XCTAssertTrue(result.reason.contains("stale-merge-gate"), "the worktree's path is missing: \(result.reason)")
        XCTAssertTrue(result.reason.hasSuffix("merge there or remove that worktree"), result.reason)
        XCTAssertEqual(sha("release"), releaseBefore, "the base ref must not move under a live checkout")
    }

    /// The compare-and-swap, and the one retry `mergeAndVerify` now gives it:
    /// the base advances once while the merged tree is being verified (here,
    /// by the verify itself, via an empty commit written straight onto a
    /// marker-guarded ref update that only fires the first time it runs) —
    /// the exact shape of the 2026-09-05 travel race, where a sibling's gate
    /// landed while this one's verify was still running. `mergeOnceWithRetry`
    /// rebuilds the scratch merge on the base's new tip and verifies again;
    /// since nothing moves the base a second time, that retry lands, and the
    /// reason says a retry happened rather than reading as an ordinary merge.
    func testABaseThatMovesOnceDuringVerifyLandsAfterOneRetry() async throws {
        makeBranch("release")
        let manager = WorktreeManager(projectRoot: tempDir)
        let branch = try await makeItemBranch("raced-agent", base: "release", manager: manager)
        let root = tempDir.path(percentEncoded: false)
        let marker = tempDir.appending(path: "advance-once-marker").path(percentEncoded: false)
        let advanceOnce = "test -f '\(marker)' || (git -C '\(root)' update-ref refs/heads/release "
            + "\"$(git -C '\(root)' commit-tree -p refs/heads/release -m advance 'refs/heads/release^{tree}')\""
            + " && touch '\(marker)')"
        let releaseBefore = sha("release")

        let result = await manager.mergeAndVerify(
            branch: branch, message: "merge",
            verify: .resolve(projectCommand: nil, itemVerify: advanceOnce), base: "release")

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertTrue(result.reason.hasPrefix("base moved during verify from "), result.reason)
        XCTAssertTrue(result.reason.hasSuffix("and verified again"), result.reason)
        XCTAssertTrue(result.reason.contains(releaseBefore.prefix(7)),
                      "the tip the scratch merge was built on is missing: \(result.reason)")
        XCTAssertTrue(result.reason.contains(sha("release^1").prefix(7)),
                      "the tip it moved to is missing: \(result.reason)")
        XCTAssertEqual(sha("release^2"), sha(branch), "the final merge carries the item branch")
        XCTAssertEqual(git(["log", "-1", "--format=%s", "release^1"], in: tempDir).output
                        .trimmingCharacters(in: .whitespacesAndNewlines), "advance",
                       "the retry merged onto the commit that moved the base during the first verify")
        XCTAssertEqual(sha("release^1^1"), releaseBefore,
                       "the advance is the only commit ahead of where the base started")
    }

    /// A base that keeps moving — here, moved by the verify step itself on
    /// every attempt it makes, so the retry's own verify moves it again just
    /// as the first attempt's did — is refused once the one retry is spent,
    /// naming the base that moved rather than relaying git's raw
    /// fast-forward/compare-and-swap hint text.
    func testABaseThatMovesTwiceIsRefusedNamingItNotGitsHintText() async throws {
        makeBranch("release")
        let manager = WorktreeManager(projectRoot: tempDir)
        let branch = try await makeItemBranch("raced-agent", base: "release", manager: manager)
        let root = tempDir.path(percentEncoded: false)
        let advance = "git -C '\(root)' update-ref refs/heads/release "
            + "\"$(git -C '\(root)' commit-tree -p refs/heads/release -m advance 'refs/heads/release^{tree}')\""

        let result = await manager.mergeAndVerify(
            branch: branch, message: "merge",
            verify: .resolve(projectCommand: nil, itemVerify: advance), base: "release")

        XCTAssertFalse(result.merged)
        XCTAssertTrue(result.reason.contains("release moved again during the retry"), result.reason)
        XCTAssertTrue(result.reason.contains("refused rather than merging a third time"), result.reason)
        XCTAssertFalse(result.reason.contains("hint:"), "git's raw hint text must not leak into the reason")
        XCTAssertEqual(git(["rev-list", "--count", "release"], in: tempDir).output
                        .trimmingCharacters(in: .whitespacesAndNewlines), "3",
                       "release advanced once per attempt — the retry made its own second attempt")
        XCTAssertFalse(git(["merge-base", "--is-ancestor", branch, "release"], in: tempDir).status == 0,
                       "the item branch must not have landed")
    }

    /// Two gates on the same project must never race: while one is still
    /// verifying, the other's `mergeAndVerify` call waits, so its scratch
    /// merge is only ever built once the first has already landed — never
    /// against the stale tip the first started from. Proved by *both* landing
    /// on their first attempt (`reason == "merged"`, not the "base moved
    /// during verify" retry phrasing) even though one spends a full second
    /// inside its own verify, which is ample time for a race to show.
    ///
    /// The two merges go through two `WorktreeManager` instances, which is the
    /// shape the app actually has — the autopilot's auto-merge, the approval
    /// endpoint's merge and the item detail view's each build their own — and
    /// the only shape that exercises the lock at all: one instance is an actor
    /// and serializes its own calls, so a single-manager version of this test
    /// passes with `MergeGateLock` deleted.
    /// `testTwoMergesFromTwoManagersRaceWithoutTheMergeGate` is the other half
    /// of that proof: the same race with each manager given a gate of its own.
    func testTwoMergesFromTwoManagersRunOneAfterTheOther() async throws {
        let setup = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let slowBranch = try await makeItemBranch("slow-agent", base: base, manager: setup, file: "slow.txt")
        let fastBranch = try await makeItemBranch("fast-agent", base: base, manager: setup, file: "fast.txt")
        let slowGate = WorktreeManager(projectRoot: tempDir)
        let fastGate = WorktreeManager(projectRoot: tempDir)

        async let slow = slowGate.mergeAndVerify(
            branch: slowBranch, message: "merge slow",
            verify: .resolve(projectCommand: nil, itemVerify: "sleep 1"), base: base)
        async let fast = fastGate.mergeAndVerify(
            branch: fastBranch, message: "merge fast", verify: .none, base: base)
        let (slowResult, fastResult) = await (slow, fast)

        XCTAssertTrue(slowResult.merged, slowResult.reason)
        XCTAssertTrue(fastResult.merged, fastResult.reason)
        XCTAssertEqual(slowResult.reason, "merged", "run alone against whatever tip it started from")
        XCTAssertEqual(fastResult.reason, "merged",
                       "the second gate's scratch merge starts from the first's already-landed result")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "slow.txt").path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "fast.txt").path(percentEncoded: false)))
        let secondParents = Set([sha("HEAD^2"), sha("HEAD^1^2")])
        XCTAssertEqual(secondParents, Set([sha(slowBranch), sha(fastBranch)]),
                       "both item branches landed, one merge stacked on the other")
    }

    /// The same race with the gate taken away — each manager given a lock of
    /// its own (`MergeGateSharing.unshared`), which serializes nothing. The
    /// assertion the test above rests on, that neither merge had to recover
    /// from a moved base, does not hold here: one gate builds its scratch on a
    /// tip the other lands out from under it, and lands only by spending the
    /// base-moved retry. This is what makes the test above a test *of the
    /// lock* rather than of the actor isolation underneath it.
    func testTwoMergesFromTwoManagersRaceWithoutTheMergeGate() async throws {
        let setup = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let slowBranch = try await makeItemBranch("slow-agent", base: base, manager: setup, file: "slow.txt")
        let fastBranch = try await makeItemBranch("fast-agent", base: base, manager: setup, file: "fast.txt")
        let slowGate = WorktreeManager(projectRoot: tempDir, mergeGate: .unshared)
        let fastGate = WorktreeManager(projectRoot: tempDir, mergeGate: .unshared)

        async let slow = slowGate.mergeAndVerify(
            branch: slowBranch, message: "merge slow",
            verify: .resolve(projectCommand: nil, itemVerify: "sleep 1"), base: base)
        async let fast = fastGate.mergeAndVerify(
            branch: fastBranch, message: "merge fast", verify: .none, base: base)
        let (slowResult, fastResult) = await (slow, fast)

        XCTAssertFalse(slowResult.reason == "merged" && fastResult.reason == "merged",
                       "ungated, the two merges overlap: one of them must have met a base that moved "
                       + "under it — slow: \(slowResult.reason); fast: \(fastResult.reason)")
    }

    /// A merge that has to queue behind another on the same project says so,
    /// and only then: the second gate reports `.waiting` before it blocks and
    /// `.acquired` once it holds the lock, while the gate that never waited
    /// reports nothing at all. This is what the phase rail's `waitingForGate`
    /// step and the `autopilot-merge-waiting` event are drawn from.
    func testAQueuedMergeReportsWaitingThenAcquiredAndAnUncontendedOneReportsNothing() async throws {
        let setup = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let firstBranch = try await makeItemBranch("first-agent", base: base, manager: setup, file: "first.txt")
        let secondBranch = try await makeItemBranch("second-agent", base: base, manager: setup, file: "second.txt")
        let waits = GateWaitLog()
        let slowVerify = MergeVerifyPlan.resolve(projectCommand: nil, itemVerify: "sleep 1")
        let firstGate = WorktreeManager(projectRoot: tempDir)
        let secondGate = WorktreeManager(projectRoot: tempDir)

        async let first = firstGate.mergeAndVerify(
            branch: firstBranch, message: "merge first", verify: slowVerify, base: base,
            onGateWait: { await waits.record("first", $0) })
        async let second = secondGate.mergeAndVerify(
            branch: secondBranch, message: "merge second", verify: slowVerify, base: base,
            onGateWait: { await waits.record("second", $0) })
        let (firstResult, secondResult) = await (first, second)

        XCTAssertTrue(firstResult.merged, firstResult.reason)
        XCTAssertTrue(secondResult.merged, secondResult.reason)
        let recorded = await waits.recorded
        XCTAssertEqual(recorded.count, 1,
                       "exactly one of the two had to queue; the other never says a word: \(recorded)")
        XCTAssertEqual(recorded.values.first, [.waiting, .acquired],
                       "the queued merge says it is waiting before it blocks, and again once it holds "
                       + "the gate: \(recorded)")
    }

    /// A landing refused for something that is not the base moving — here a
    /// checkout gone dirty over exactly the file the merge brings in, after
    /// the up-front overlap precheck has already passed — is refused once,
    /// with git's own reason, and never pays for a second verify. The retry
    /// used to fire on any landing failure at all, so a dirty checkout cost a
    /// second full run of the merge-verify command and then reported "base
    /// moved" for a base that had not.
    func testALandingRefusedForADirtyCheckoutIsRefusedOnceWithGitsReason() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let branch = try await makeItemBranch("dirty-agent", base: base, manager: manager)
        let root = tempDir.path(percentEncoded: false)
        let tally = tempDir.appending(path: "verify-runs").path(percentEncoded: false)
        // Runs inside the scratch worktree: counts itself, then plants an
        // untracked `feature.txt` in the checkout — the very path the merge
        // would write — so the fast-forward below refuses.
        let dirtyTheCheckout = "echo run >> '\(tally)' && echo loose > '\(root)/feature.txt'"
        let headBefore = sha("HEAD")

        let result = await manager.mergeAndVerify(
            branch: branch, message: "merge",
            verify: .resolve(projectCommand: nil, itemVerify: dirtyTheCheckout), base: base)

        XCTAssertFalse(result.merged)
        XCTAssertTrue(result.reason.hasPrefix("could not fast-forward the checkout onto the merge: "),
                      "git's own reason, not a base-moved one: \(result.reason)")
        XCTAssertFalse(result.reason.contains("base moved") || result.reason.contains("moved again"),
                       "the base did not move: \(result.reason)")
        XCTAssertEqual(sha("HEAD"), headBefore, "nothing landed")
        let runs = try String(contentsOfFile: tally, encoding: .utf8)
            .split(separator: "\n").count
        XCTAssertEqual(runs, 1, "the verify ran once — a refusal the base did not cause buys no retry")
    }

    /// **The reproduction**: which of the things the app runs periodically over a
    /// project removes a merge gate's scratch worktree while its verify is still
    /// running — measured against a real gate in flight, not argued from the
    /// sources. A gate is parked mid-verify on a sentinel file, each pass is
    /// driven against the project one at a time, and the scratch directory is
    /// checked after every one.
    ///
    /// The answer is `sweep`, and the measurement below says why. The instant
    /// the merge is committed into it a live scratch worktree is *detached* —
    /// so no branch of its own can carry unmerged commits — and *clean*, the
    /// merge being committed and build output gitignored. Read by `sweep`'s own
    /// `hasUnmergedCommits` / `hasUncommittedChanges`, that pair is exactly the
    /// `.reap` case of `orphanVerdict`. The scratch used to live in
    /// `.kiteloop/worktrees/`, the one directory `sweep` walks, so any sweep
    /// landing during a gate deleted the directory the verify was running in —
    /// which is what the second worktree here shows, given the live scratch's
    /// own commit and its own shape, at the path the scratch used to occupy.
    ///
    /// The other three passes read and never remove, and the assertions after
    /// each of them say so: the blocked-triage pass's only contact with git is
    /// `CoordinatorBlockedTriage.branchHasCommits`, `StrandedWorkSweep.read`
    /// lists `.kiteloop/worktrees/` without deleting out of it, and
    /// `StaleItemSweep` reads one `git log` per open item.
    func testASweepIsWhatRemovesALiveGatesScratchWorktreeMidVerify() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let key = "removal-repro-agent"
        let branch = try await makeItemBranch(key, base: base, manager: manager)
        let scratchPath = tempDir
            .appending(path: ".kiteloop/merge-gate-scratch/\(key)-merge-gate")
            .path(percentEncoded: false)
        // Where the scratch used to live — the directory `sweep` walks.
        let sweptPath = tempDir
            .appending(path: ".kiteloop/worktrees/\(key)-merge-gate")
            .path(percentEncoded: false)
        let release = tempDir.appending(path: ".kiteloop/gate-release").path(percentEncoded: false)
        let fm = FileManager.default

        // Verify parks until the test releases it, so every pass below runs
        // against a gate that is genuinely mid-verify rather than against a
        // race with a fixed sleep. Bounded, so a broken run cannot hang.
        async let gate = manager.mergeAndVerify(
            branch: branch, message: "merge",
            verify: .resolve(projectCommand: nil,
                             itemVerify: "for i in $(seq 1 600); do "
                                       + "[ -f '\(release)' ] && exit 0; sleep 0.05; done; exit 0"),
            base: base)

        // `feature.txt` is the branch's own commit: it is in the scratch only
        // once the merge has been committed into it, which is the state the
        // sweep reads as an orphan.
        let mergedFile = scratchPath + "/feature.txt"
        try await eventually("the gate's scratch worktree to exist, with the merge committed in it") {
            FileManager.default.fileExists(atPath: mergedFile)
        }

        // Pass 1 — the blocked-triage pass, whose only git contact this is.
        _ = await CoordinatorBlockedTriage.branchHasCommits(root: tempDir, itemID: key)
        XCTAssertTrue(fm.fileExists(atPath: scratchPath), "blocked triage removed the scratch worktree")

        // Pass 2 — the stranded-work sweep, which walks `.kiteloop/worktrees/`.
        _ = await StrandedWorkSweep.read(projectRoot: tempDir, doneItemIDs: [key])
        XCTAssertTrue(fm.fileExists(atPath: scratchPath), "the stranded-work sweep removed the scratch worktree")

        // Pass 3 — the stale-item sweep.
        _ = StaleItemSweep.lastTouched(
            items: [BacklogItem(id: key, title: "Title", status: .awaitingApproval,
                                type: .local, detailPath: "\(key).md")],
            checkout: tempDir)
        XCTAssertTrue(fm.fileExists(atPath: scratchPath), "the stale-item sweep removed the scratch worktree")

        // Pass 4 — the worktree sweep. First, the shape of the live scratch, put
        // where the scratch used to be so `sweep`'s own readers can be asked
        // about it: same commit, same detached HEAD, same clean tree.
        let scratchHead = git(["-C", scratchPath, "rev-parse", "HEAD"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(git(["-C", scratchPath, "symbolic-ref", "--quiet", "HEAD"], in: tempDir).status, 0,
                          "a live scratch worktree is detached — that is half of why it reads as an orphan")
        XCTAssertEqual(git(["-C", scratchPath, "status", "--porcelain"], in: tempDir).output
            .trimmingCharacters(in: .whitespacesAndNewlines), "",
                       "a live scratch worktree is clean once the merge is committed — the other half")
        XCTAssertEqual(git(["-C", tempDir.path(percentEncoded: false), "worktree", "add", "--detach",
                            sweptPath, scratchHead], in: tempDir).status, 0)

        let sweeper = WorktreeManager(projectRoot: tempDir)
        let unmerged = await sweeper.hasUnmergedCommits(for: "\(key)-merge-gate")
        let dirty = await sweeper.hasUncommittedChanges(for: "\(key)-merge-gate")
        XCTAssertEqual(
            WorktreeManager.orphanVerdict(isActive: false, hasUnmergedCommits: unmerged,
                                          hasUncommittedChanges: dirty),
            .reap,
            "the sweep reads a live gate's scratch worktree as an orphan to reap — this is the removal")
        let report = await sweeper.sweep()
        XCTAssertEqual(report.reaped, ["\(key)-merge-gate"],
                       "reproduced: a sweep reaps a scratch worktree that sits in `.kiteloop/worktrees/`")
        XCTAssertFalse(fm.fileExists(atPath: sweptPath))

        // And the fix: the live scratch is not in that directory, so the same
        // real sweep never saw it, and the gate lands when its verify finishes.
        XCTAssertTrue(fm.fileExists(atPath: scratchPath),
                      "the sweep must not reach the gate's own scratch worktree")
        try Data().write(to: URL(fileURLWithPath: release))

        let result = await gate
        XCTAssertTrue(result.merged, result.reason)
        XCTAssertEqual(result.reason, "merged")
    }

    /// A scratch merge-gate worktree now lives under `.kiteloop/merge-gate-scratch/`,
    /// never `.kiteloop/worktrees/` — the directory `sweep` walks. A sweep built
    /// fresh (a new `WorktreeManager` instance, the way
    /// `ProjectSession.sweepWorktrees` makes one — the shape the coordinator's
    /// periodic passes take too) landing while the gate's own verify is still
    /// running must never see, let alone reap, that directory: the gate is the
    /// only thing that may ever remove it, and it lands normally once its
    /// (otherwise slow) verify finishes.
    func testSweepLeavesAScratchWorktreeAloneMidVerifyAndTheGateLands() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let branch = try await makeItemBranch("mid-verify-agent", base: base, manager: manager)
        let scratchPath = tempDir
            .appending(path: ".kiteloop/merge-gate-scratch/mid-verify-agent-merge-gate")
            .path(percentEncoded: false)

        async let gate = manager.mergeAndVerify(
            branch: branch, message: "merge",
            verify: .resolve(projectCommand: nil, itemVerify: "sleep 1"), base: base)

        try await eventually("the scratch worktree to exist while verify is still running") {
            FileManager.default.fileExists(atPath: scratchPath)
        }
        let sweepReport = await WorktreeManager(projectRoot: tempDir).sweep()

        let result = await gate
        XCTAssertTrue(sweepReport.reaped.isEmpty,
                      "a sweep must never reap a gate's scratch worktree: \(sweepReport.logLines)")
        XCTAssertTrue(sweepReport.kept.isEmpty,
                      "a sweep must never even list a gate's scratch worktree: \(sweepReport.logLines)")
        XCTAssertTrue(result.merged, result.reason)
        XCTAssertEqual(result.reason, "merged")
    }

    /// Defense in depth for whatever else might remove a scratch worktree out
    /// from under a running verify: the failing step's own output is a `cd: No
    /// such file or directory` or similar, which reads exactly like the diff
    /// broke something. The gate must say the worktree vanished instead of
    /// relaying that garbled failure as an ordinary verify refusal.
    func testMergeResultNamesTheMissingWorktreeWhenTheScratchVanishesMidVerify() async throws {
        let manager = WorktreeManager(projectRoot: tempDir)
        let base = checkoutBranch()
        let branch = try await makeItemBranch("vanishing-agent", base: base, manager: manager)
        let scratch = tempDir.appending(path: ".kiteloop/merge-gate-scratch/vanishing-agent-merge-gate")

        // Wait for the verify itself, not for the directory: the scratch exists
        // the instant `git worktree add` creates it, while git is still
        // populating it, and a removal that races that is git's refusal, not
        // a worktree pulled out from under a running verify.
        let started = tempDir.appending(path: "verify-started")
        async let gate = manager.mergeAndVerify(
            branch: branch, message: "merge",
            verify: .resolve(projectCommand: nil,
                             itemVerify: "touch '\(started.path(percentEncoded: false))' && sleep 1 && exit 1"),
            base: base)

        try await eventually("the verify to be running before its worktree is removed") {
            FileManager.default.fileExists(atPath: started.path(percentEncoded: false))
        }
        try FileManager.default.removeItem(at: scratch)

        let result = await gate
        XCTAssertFalse(result.merged)
        XCTAssertTrue(result.reason.contains("removed while verify was still running"), result.reason)
        XCTAssertFalse(result.reason.contains("exit 1"),
                       "must not read like the item's own verify command failed")
    }

    /// The porcelain reader behind case (b): the block whose `branch` line
    /// names the base, and its `worktree` path — a detached block (the merge
    /// scratch) has no `branch` line and never matches.
    func testWorktreePathHoldingReadsTheBranchsBlock() {
        let porcelain = """
            worktree /repo
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main

            worktree /repo/.kiteloop/worktrees/x-merge-gate
            HEAD 2222222222222222222222222222222222222222
            detached

            worktree /repo/.kiteloop/worktrees/stale
            HEAD 3333333333333333333333333333333333333333
            branch refs/heads/release

            """
        XCTAssertEqual(WorktreeManager.worktreePath(holding: "release", in: porcelain),
                       "/repo/.kiteloop/worktrees/stale")
        XCTAssertEqual(WorktreeManager.worktreePath(holding: "main", in: porcelain), "/repo")
        XCTAssertNil(WorktreeManager.worktreePath(holding: "feature", in: porcelain))
        XCTAssertNil(WorktreeManager.worktreePath(holding: "rel", in: porcelain), "a prefix is not a match")
    }
}

/// What each racing merge told its `onGateWait` callback, in order. An actor
/// because the two callbacks fire from two merges running at once, and the
/// order within one merge is exactly what the test is checking.
private actor GateWaitLog {
    private(set) var recorded: [String: [WorktreeManager.MergeGateWait]] = [:]

    func record(_ gate: String, _ wait: WorktreeManager.MergeGateWait) {
        recorded[gate, default: []].append(wait)
    }
}
