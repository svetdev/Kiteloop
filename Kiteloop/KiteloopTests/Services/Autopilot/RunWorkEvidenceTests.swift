import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers the check that stands between a finished run and the human gate: did
/// the run actually produce anything? The rules are pure and the git reads run
/// against a real temporary repository, because the whole point of this check is
/// that it believes git rather than the workflow's summary of itself.
final class RunWorkEvidenceTests: XCTestCase {
    private var repo: URL!
    /// Worktrees `makeWorktree` created, removed with the repo.
    private var worktrees: [URL] = []

    override func setUpWithError() throws {
        repo = try makeTemporaryDirectory(prefix: "run-work-evidence")
        git(["init"])
        git(["config", "user.email", "test@test.com"])
        git(["config", "user.name", "Test"])
        try "init".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-m", "init"])
    }

    override func tearDownWithError() throws {
        for worktree in worktrees { try? FileManager.default.removeItem(at: worktree) }
        worktrees = []
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

    /// A branch off `HEAD` carrying one commit that changes a file — what a run
    /// that did its job leaves behind. `subject` is the commit message, which
    /// matters where the work is looked for by what teardown wrote on it; the
    /// file is named after the branch so two branches never produce the same
    /// commit object and quietly share it.
    private func branchWithWork(_ name: String, subject: String = "work") {
        git(["checkout", "-q", "-b", name])
        let file = name.replacingOccurrences(of: "/", with: "-") + ".txt"
        try? "worked".write(to: repo.appending(path: file), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-m", subject])
        git(["checkout", "-q", "-"])
    }

    // MARK: - Rules

    func testProducedNeedsAllThreeSignals() {
        XCTAssertEqual(RunWorkEvidence.verdict(branchResolves: true, commits: 1, hasDiff: true),
                       .produced)
    }

    func testMissingBranchIsEvidence() {
        XCTAssertEqual(RunWorkEvidence.verdict(branchResolves: false, commits: nil, hasDiff: nil),
                       .noBranch)
    }

    func testBranchWithoutCommitsIsEvidence() {
        XCTAssertEqual(RunWorkEvidence.verdict(branchResolves: true, commits: 0, hasDiff: nil),
                       .noCommits)
    }

    func testCommitsThatChangeNothingAreEvidence() {
        XCTAssertEqual(RunWorkEvidence.verdict(branchResolves: true, commits: 1, hasDiff: false),
                       .emptyDiff)
    }

    /// A git read that failed is not evidence — nobody could tell, and a run is
    /// never turned back on a question that couldn't be asked.
    func testUnreadableSignalsAreNotEvidence() {
        XCTAssertEqual(RunWorkEvidence.verdict(branchResolves: nil, commits: nil, hasDiff: nil),
                       .unknown)
        XCTAssertEqual(RunWorkEvidence.verdict(branchResolves: true, commits: nil, hasDiff: nil),
                       .unknown)
        XCTAssertEqual(RunWorkEvidence.verdict(branchResolves: true, commits: 1, hasDiff: nil),
                       .unknown)
    }

    /// Only the three evidence verdicts name a signal; those two names are what
    /// stops a run at the gate, and what answers "why" afterwards.
    func testOnlyEvidenceNamesASignal() {
        XCTAssertNil(RunWorkEvidence.Verdict.produced.missingSignal)
        XCTAssertNil(RunWorkEvidence.Verdict.unknown.missingSignal)
        XCTAssertNil(RunWorkEvidence.Verdict.orphanedCommits.missingSignal)
        XCTAssertEqual(RunWorkEvidence.Verdict.noBranch.missingSignal,
                       "run produced no work — no branch")
        XCTAssertEqual(RunWorkEvidence.Verdict.noCommits.missingSignal,
                       "run produced no work — branch has no commits")
        XCTAssertEqual(RunWorkEvidence.Verdict.emptyDiff.missingSignal,
                       "run produced no work — empty diff against base")
    }

    /// The same line the day's ledger reads before charging a run nothing —
    /// `.unknown` must stay outside it, or an unreadable run would be free.
    func testOnlyEvidenceSaysTheRunProducedNothing() {
        XCTAssertFalse(RunWorkEvidence.Verdict.produced.producedNothing)
        XCTAssertFalse(RunWorkEvidence.Verdict.unknown.producedNothing)
        // The commits are still in the object store — charging that run nothing
        // is what this case exists to stop.
        XCTAssertFalse(RunWorkEvidence.Verdict.orphanedCommits.producedNothing)
        for verdict: RunWorkEvidence.Verdict in [.noBranch, .noCommits, .emptyDiff, .noChanges] {
            XCTAssertTrue(verdict.producedNothing, "\(verdict) is evidence of an empty run")
        }
    }

    // MARK: - Reading a real repository

    func testRealBranchWithWorkReadsAsProduced() async {
        branchWithWork("kiteloop/did-the-work")
        let verdict = await RunWorkEvidence.inspect(
            projectRoot: repo, branch: "kiteloop/did-the-work", isolated: true)
        XCTAssertEqual(verdict, .produced)
        XCTAssertNil(verdict.missingSignal)
    }

    /// Teardown returns no branch when there was nothing to commit — the case
    /// that reached the approval gate on 2026-08-08.
    func testNoBranchFromTeardownReadsAsNoBranch() async {
        let verdict = await RunWorkEvidence.inspect(projectRoot: repo, branch: nil, isolated: true)
        XCTAssertEqual(verdict, .noBranch)
    }

    func testBranchThatWasNeverCommittedToReadsAsNoCommits() async {
        git(["branch", "kiteloop/empty", "HEAD"])
        let verdict = await RunWorkEvidence.inspect(
            projectRoot: repo, branch: "kiteloop/empty", isolated: true)
        XCTAssertEqual(verdict, .noCommits)
    }

    func testBranchWithOnlyAnEmptyCommitReadsAsEmptyDiff() async {
        git(["checkout", "-q", "-b", "kiteloop/empty-commit"])
        git(["commit", "--allow-empty", "-m", "nothing"])
        git(["checkout", "-q", "-"])
        let verdict = await RunWorkEvidence.inspect(
            projectRoot: repo, branch: "kiteloop/empty-commit", isolated: true)
        XCTAssertEqual(verdict, .emptyDiff)
    }

    func testBranchNamedButAbsentReadsAsNoBranch() async {
        let verdict = await RunWorkEvidence.inspect(
            projectRoot: repo, branch: "kiteloop/never-existed", isolated: true)
        XCTAssertEqual(verdict, .noBranch)
        XCTAssertTrue(verdict.producedNothing)
    }

    /// The reading a missing branch used to be given wrongly: teardown dropped
    /// the branch, the run's commits are still in the object store, and the run
    /// was filed as having produced nothing over real work. A missing branch is
    /// only evidence once nothing of the run's survives.
    func testDeletedBranchWhoseCommitsSurviveReadsAsOrphanedCommits() async {
        branchWithWork("kiteloop/orphaned", subject: "autopilot: orphaned")
        git(["branch", "-D", "kiteloop/orphaned"])

        let verdict = await RunWorkEvidence.inspect(
            projectRoot: repo, branch: "kiteloop/orphaned", isolated: true)
        XCTAssertEqual(verdict, .orphanedCommits)
        XCTAssertFalse(verdict.producedNothing)
        XCTAssertNil(verdict.missingSignal)
    }

    /// The dangling commit has to be *this* item's. Another item's abandoned
    /// work is in the same object store and says nothing about this run.
    func testDanglingCommitFromAnotherItemIsNotThisRunsWork() async {
        branchWithWork("kiteloop/some-other-item", subject: "autopilot: some-other-item")
        git(["branch", "-D", "kiteloop/some-other-item"])

        let verdict = await RunWorkEvidence.inspect(
            projectRoot: repo, branch: "kiteloop/never-existed", isolated: true)
        XCTAssertEqual(verdict, .noBranch)
    }

    /// Nothing is asked of `git fsck` until a named branch has already failed to
    /// resolve: a run that wasn't isolated, or that names no branch at all,
    /// returns on the early guards, and one whose branch is there is answered by
    /// the commit count. Each case is set up so a read that *did* reach the
    /// probe would come back with `.orphanedCommits` instead.
    func testTheProbeIsOnlyReachedForANamedButMissingBranch() async throws {
        branchWithWork("kiteloop/orphaned", subject: "autopilot: orphaned")
        git(["branch", "-D", "kiteloop/orphaned"])

        // Un-isolated: the same branch that reads as `.orphanedCommits` above.
        let live = await RunWorkEvidence.inspect(
            projectRoot: repo, branch: "kiteloop/orphaned", isolated: false)
        XCTAssertEqual(live, .unknown)

        // No branch named: nothing to derive an item id from, so the answer is
        // the guard's, not the probe's.
        let unnamed = await RunWorkEvidence.inspect(
            projectRoot: repo, branch: "   ", isolated: true)
        XCTAssertEqual(unnamed, .noBranch)

        // A branch that resolves is answered by the commit count, not by fsck —
        // even with this item's work also sitting dangling in the same repo.
        branchWithWork("kiteloop/resolves", subject: "autopilot: resolves")
        branchWithWork("kiteloop/dangling-too", subject: "autopilot: resolves")
        git(["branch", "-D", "kiteloop/dangling-too"])
        let resolved = await RunWorkEvidence.inspect(
            projectRoot: repo, branch: "kiteloop/resolves", isolated: true)
        XCTAssertEqual(resolved, .produced)
    }

    /// Work git can see but nothing can name is not work a reader can pick up:
    /// `hasWork` stays false, and `LeftBehind` names no branch for it.
    func testOrphanedCommitsAreNotWorkToPickUp() async {
        branchWithWork("kiteloop/orphaned", subject: "autopilot: orphaned")
        git(["branch", "-D", "kiteloop/orphaned"])

        let left = await RunWorkEvidence.leftBehind(
            projectRoot: repo, branch: "kiteloop/orphaned", isolated: true)
        XCTAssertEqual(left.verdict, .orphanedCommits)
        XCTAssertFalse(left.hasWork)
        XCTAssertNil(left.summary)
    }

    /// A live-tree run has no branch to read and its edits are indistinguishable
    /// from a human's, so the check abstains rather than turning every
    /// un-isolated run back.
    func testLiveTreeRunIsNotJudged() async {
        let verdict = await RunWorkEvidence.inspect(projectRoot: repo, branch: nil, isolated: false)
        XCTAssertEqual(verdict, .unknown)
        XCTAssertNil(verdict.missingSignal)
    }

    func testMissingProjectRootIsNotJudged() async {
        let verdict = await RunWorkEvidence.inspect(
            projectRoot: nil, branch: "kiteloop/x", isolated: true)
        XCTAssertEqual(verdict, .unknown)
    }

    /// A directory that isn't a repository can't answer the question — and an
    /// unanswerable question must not read as "produced nothing".
    func testNonRepositoryIsNotJudged() async throws {
        let plain = try makeTemporaryDirectory(prefix: "plain")
        let verdict = await RunWorkEvidence.inspect(
            projectRoot: plain, branch: "kiteloop/x", isolated: true)
        XCTAssertEqual(verdict, .unknown)
        XCTAssertNil(verdict.missingSignal)
    }

    // MARK: - A blocked run's rules

    func testEitherSignalOnItsOwnMeansTheRunProduced() {
        // Work the reviewer rejected is sitting uncommitted in the worktree.
        XCTAssertEqual(RunWorkEvidence.blockedVerdict(worktreeDirty: true, commits: 0), .produced)
        // A worker that committed its own work before being blocked.
        XCTAssertEqual(RunWorkEvidence.blockedVerdict(worktreeDirty: false, commits: 2), .produced)
    }

    func testBothSignalsEmptyIsEvidence() {
        XCTAssertEqual(RunWorkEvidence.blockedVerdict(worktreeDirty: false, commits: 0), .noChanges)
        XCTAssertEqual(RunWorkEvidence.Verdict.noChanges.missingSignal,
                       "run produced no work — no commits and an unchanged worktree")
    }

    /// A signal nobody could read leaves the question open — the same rule the
    /// gate's read follows, and for the same reason.
    func testUnreadableBlockedSignalsAreNotEvidence() {
        XCTAssertEqual(RunWorkEvidence.blockedVerdict(worktreeDirty: nil, commits: 0), .unknown)
        XCTAssertEqual(RunWorkEvidence.blockedVerdict(worktreeDirty: false, commits: nil), .unknown)
        XCTAssertEqual(RunWorkEvidence.blockedVerdict(worktreeDirty: nil, commits: nil), .unknown)
        // …unless the readable half already said the run produced something.
        XCTAssertEqual(RunWorkEvidence.blockedVerdict(worktreeDirty: true, commits: nil), .produced)
        XCTAssertEqual(RunWorkEvidence.blockedVerdict(worktreeDirty: nil, commits: 3), .produced)
    }

    // MARK: - Reading a real blocked run

    /// A blocked run's worktree, as teardown leaves it: on its branch, kept on
    /// disk, nothing committed.
    private func makeWorktree(branch: String) -> URL {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        git(["worktree", "add", "-b", branch, path.path(percentEncoded: false), "HEAD"])
        worktrees.append(path)
        return path
    }

    /// The rejected-but-real run: blocked teardown commits nothing, so the
    /// work is uncommitted in the worktree. Reading that as an empty run is
    /// what would turn every review rejection into a dead-session diagnosis.
    func testBlockedRunWithUncommittedWorkReadsAsProduced() async throws {
        let worktree = makeWorktree(branch: "kiteloop/rejected")
        try "worked".write(to: worktree.appending(path: "worked.txt"),
                           atomically: true, encoding: .utf8)
        let verdict = await RunWorkEvidence.inspectBlocked(
            projectRoot: repo, branch: "kiteloop/rejected", worktree: worktree, isolated: true)
        XCTAssertEqual(verdict, .produced)
        XCTAssertNil(verdict.missingSignal)
    }

    /// The dead session: the workflow ran, blocked, and left nothing behind.
    func testBlockedRunThatLeftNothingReadsAsNoChanges() async {
        let worktree = makeWorktree(branch: "kiteloop/dead-session")
        let verdict = await RunWorkEvidence.inspectBlocked(
            projectRoot: repo, branch: "kiteloop/dead-session", worktree: worktree, isolated: true)
        XCTAssertEqual(verdict, .noChanges)
        XCTAssertNotNil(verdict.missingSignal)
    }

    func testBlockedRunThatCommittedItsOwnWorkReadsAsProduced() async throws {
        let worktree = makeWorktree(branch: "kiteloop/self-committed")
        try "worked".write(to: worktree.appending(path: "worked.txt"),
                           atomically: true, encoding: .utf8)
        git(["add", "."], in: worktree)
        git(["commit", "-m", "work"], in: worktree)
        let verdict = await RunWorkEvidence.inspectBlocked(
            projectRoot: repo, branch: "kiteloop/self-committed", worktree: worktree, isolated: true)
        XCTAssertEqual(verdict, .produced)
    }

    /// Build output is ignored, so a verify that ran in the worktree doesn't
    /// dress a dead session up as a productive one.
    func testIgnoredBuildOutputIsNotWork() async throws {
        try ".build/\n".write(to: repo.appending(path: ".gitignore"),
                              atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-m", "ignore build output"])
        let worktree = makeWorktree(branch: "kiteloop/built-only")
        try FileManager.default.createDirectory(at: worktree.appending(path: ".build"),
                                                withIntermediateDirectories: true)
        try "artifact".write(to: worktree.appending(path: ".build/out.o"),
                             atomically: true, encoding: .utf8)
        let verdict = await RunWorkEvidence.inspectBlocked(
            projectRoot: repo, branch: "kiteloop/built-only", worktree: worktree, isolated: true)
        XCTAssertEqual(verdict, .noChanges)
    }

    /// No worktree to read — a live-tree run, or one whose tree is gone — is
    /// not judged, exactly as the gate's read abstains.
    func testBlockedRunWithNoWorktreeIsNotJudged() async {
        let worktree = makeWorktree(branch: "kiteloop/live-tree")
        let unisolated = await RunWorkEvidence.inspectBlocked(
            projectRoot: repo, branch: nil, worktree: worktree, isolated: false)
        XCTAssertEqual(unisolated, .unknown)
        let gone = await RunWorkEvidence.inspectBlocked(
            projectRoot: repo, branch: "kiteloop/live-tree", worktree: nil, isolated: true)
        XCTAssertEqual(gone, .unknown)
        XCTAssertNil(gone.missingSignal)
    }

    // MARK: - Reading a run still in flight

    /// The read the pre-review gate takes: the worker has stopped, nothing has
    /// been committed (teardown is what commits), so real work is sitting
    /// uncommitted in the worktree and the reviewer has a diff to read.
    func testInFlightRunWithUncommittedWorkReadsAsProduced() async throws {
        let worktree = makeWorktree(branch: "kiteloop/in-flight")
        try "worked".write(to: worktree.appending(path: "worked.txt"),
                           atomically: true, encoding: .utf8)
        let verdict = await RunWorkEvidence.inspectInFlight(
            projectRoot: repo, branch: "kiteloop/in-flight", worktree: worktree, isolated: true)
        XCTAssertEqual(verdict, .produced)
        XCTAssertNil(verdict.missingSignal)
    }

    /// The 2026-08-09 run: six and a half minutes of worker, nothing written.
    /// This is the answer that stops it before the reviewer is asked to review
    /// nothing at all.
    func testInFlightRunThatWroteNothingReadsAsNoChanges() async {
        let worktree = makeWorktree(branch: "kiteloop/wrote-nothing")
        let verdict = await RunWorkEvidence.inspectInFlight(
            projectRoot: repo, branch: "kiteloop/wrote-nothing", worktree: worktree, isolated: true)
        XCTAssertEqual(verdict, .noChanges)
        XCTAssertEqual(verdict.missingSignal,
                       "run produced no work — no commits and an unchanged worktree")
    }

    /// A live-tree run is not judged here either — its edits are
    /// indistinguishable from a human's, so the reviewer runs exactly as before.
    func testInFlightLiveTreeRunIsNotJudged() async {
        let verdict = await RunWorkEvidence.inspectInFlight(
            projectRoot: repo, branch: nil, worktree: nil, isolated: false)
        XCTAssertEqual(verdict, .unknown)
        XCTAssertNil(verdict.missingSignal)
    }

    // MARK: - Counting what a run left

    /// The two halves of the count a metric record keeps. Nil only when
    /// *neither* could be read — a live-tree run — because "nobody could tell"
    /// and "changed nothing" are different facts and only the second one counts
    /// against the item's retry ceiling.
    func testTheFileCountIsNilOnlyWhenNeitherHalfCouldBeRead() {
        XCTAssertNil(RunWorkEvidence.totalChangedFiles(committed: nil, uncommitted: nil))
        XCTAssertEqual(RunWorkEvidence.totalChangedFiles(committed: 0, uncommitted: nil), 0)
        XCTAssertEqual(RunWorkEvidence.totalChangedFiles(committed: nil, uncommitted: 4), 4)
        XCTAssertEqual(RunWorkEvidence.totalChangedFiles(committed: 3, uncommitted: 2), 5)
    }

    /// A run that stalled or was capped keeps its worktree, and whatever
    /// teardown could not commit is sitting in it. Counting only its branch
    /// would record it as having changed nothing — and a run recorded as empty
    /// now costs the item an attempt against `RetryCeiling`.
    func testUncommittedWorkInAKeptWorktreeIsCounted() async throws {
        let worktree = makeWorktree(branch: "kiteloop/stalled")
        try "worked".write(to: worktree.appending(path: "worked.txt"),
                           atomically: true, encoding: .utf8)
        try "notes".write(to: worktree.appending(path: "notes.md"),
                          atomically: true, encoding: .utf8)

        let count = await RunWorkEvidence.uncommittedFileCount(worktree: worktree)
        XCTAssertEqual(count, 2)
    }

    /// A worktree the dead session never touched counts zero; one git can't be
    /// asked about counts nothing at all, so an unreadable tree is never
    /// mistaken for a clean one.
    func testACleanWorktreeCountsZeroAndAnUnreadableOneCountsNothing() async throws {
        let worktree = makeWorktree(branch: "kiteloop/dead")
        let clean = await RunWorkEvidence.uncommittedFileCount(worktree: worktree)
        XCTAssertEqual(clean, 0)

        let notARepo = try makeTemporaryDirectory(prefix: "not-a-repo")
        let unreadable = await RunWorkEvidence.uncommittedFileCount(worktree: notARepo)
        XCTAssertNil(unreadable)
    }

    /// The count reads the same `git status --porcelain` as `inspectBlocked`,
    /// so the two cannot disagree about whether a run produced anything: build
    /// output left by a verify is work to neither.
    func testIgnoredBuildOutputIsNotCountedEither() async throws {
        try ".build/\n".write(to: repo.appending(path: ".gitignore"),
                              atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-m", "ignore build output"])
        let worktree = makeWorktree(branch: "kiteloop/built-only")
        try FileManager.default.createDirectory(at: worktree.appending(path: ".build"),
                                                withIntermediateDirectories: true)
        try "artifact".write(to: worktree.appending(path: ".build/out.o"),
                             atomically: true, encoding: .utf8)

        let count = await RunWorkEvidence.uncommittedFileCount(worktree: worktree)
        XCTAssertEqual(count, 0)
    }

    // MARK: - The paths a run changed

    /// The list the coverage gate compares against a mapped glob, and the one
    /// `leftBehind` counts — git's own order, repo-relative.
    func testChangedFilesListsTheBranchDiff() async {
        branchWithWork("kiteloop/listed")
        let files = await RunWorkEvidence.changedFiles(projectRoot: repo,
                                                       branch: "kiteloop/listed")
        XCTAssertEqual(files, ["kiteloop-listed.txt"])
    }

    /// The distinction the whole type is built on, at the one place that was
    /// missing it: a diff with nothing in it is `[]`, a diff nobody could read is
    /// nil. Reading the second as the first is what let the coverage gate pass a
    /// run having compared no files at all.
    func testAGenuinelyEmptyDiffIsEmptyAndAnUnreadableOneIsNil() async throws {
        git(["checkout", "-q", "-b", "kiteloop/empty-commit"])
        git(["commit", "--allow-empty", "-m", "nothing"])
        git(["checkout", "-q", "-"])
        let empty = await RunWorkEvidence.changedFiles(projectRoot: repo,
                                                       branch: "kiteloop/empty-commit")
        XCTAssertEqual(empty, [])

        // A branch git can't resolve, and a directory that isn't a repository:
        // both are questions that couldn't be asked, not answers.
        let gone = await RunWorkEvidence.changedFiles(projectRoot: repo,
                                                      branch: "kiteloop/never-existed")
        XCTAssertNil(gone)

        let plain = try makeTemporaryDirectory(prefix: "plain")
        let notARepo = await RunWorkEvidence.changedFiles(projectRoot: plain,
                                                          branch: "kiteloop/x")
        XCTAssertNil(notARepo)
    }

    /// `LeftBehind` keeps counting: nil paths are zero files there, because a
    /// count is never invented and the verdict already carries "nobody could
    /// tell". Nothing about a run that produced work changes either.
    func testTheFileCountIsUnaffectedByAnUnreadableDiff() async throws {
        branchWithWork("kiteloop/counted")
        let produced = await RunWorkEvidence.leftBehind(
            projectRoot: repo, branch: "kiteloop/counted", isolated: true)
        XCTAssertEqual(produced.verdict, .produced)
        XCTAssertEqual(produced.fileCount, 1)

        let plain = try makeTemporaryDirectory(prefix: "plain")
        let unreadable = await RunWorkEvidence.leftBehind(
            projectRoot: plain, branch: "kiteloop/counted", isolated: true)
        XCTAssertEqual(unreadable.verdict, .unknown)
        XCTAssertEqual(unreadable.fileCount, 0)
        XCTAssertNil(unreadable.summary)
    }

    // MARK: - Work that landed outside the run's worktree

    /// The 2026-08-11 shape, read off a real repository: an isolated run whose
    /// worker edited the project's own checkout instead of its worktree. The
    /// branch signals cannot see it — there is no branch and nothing on it —
    /// so this is what names the paths. The worker's own tool calls named
    /// both of them, so both are attributed and block the run.
    ///
    /// This is the whole of what refuses a write outside the item's scope: the
    /// workflow file-scope check in the permission funnel is gone, and nothing
    /// stops such a write at request time.
    func testStrayWorkNamesWhatAppearedInTheCheckoutDuringTheRun() async throws {
        let before = await RunWorkEvidence.snapshotProjectRoot(repo)

        try "edited by the worker".write(to: repo.appending(path: "README.md"),
                                         atomically: true, encoding: .utf8)
        try "new".write(to: repo.appending(path: "CLIResolver.swift"),
                        atomically: true, encoding: .utf8)

        let written: Set<String> = [
            repo.appending(path: "README.md").path,
            repo.appending(path: "CLIResolver.swift").path,
        ]
        let report = await RunWorkEvidence.strayWork(
            projectRoot: repo, since: before, isolated: true, writtenBySession: written)
        XCTAssertEqual(report.attributed, ["CLIResolver.swift", "README.md"])
        XCTAssertEqual(report.foreign, [])
        XCTAssertEqual(
            RunWorkEvidence.strayWorkRefusal(paths: report.attributed),
            "\(RunWorkEvidence.strayWorkPrefix) — 2 paths changed in the project's "
            + "checkout instead of the branch: CLIResolver.swift, README.md")
    }

    /// The 2026-08-28 shape: a path dirtied in the checkout while the run was up
    /// that nothing says the run's own session wrote — a human editing, a
    /// second Claude Code session, the gate's own verify appending a row.
    /// Not blocked; recorded as an observation instead.
    func testStrayWorkDoesNotBlameTheRunForDirtItDidNotWrite() async throws {
        let before = await RunWorkEvidence.snapshotProjectRoot(repo)

        try "written by something else".write(to: repo.appending(path: "STATUS.md"),
                                              atomically: true, encoding: .utf8)

        let report = await RunWorkEvidence.strayWork(
            projectRoot: repo, since: before, isolated: true, writtenBySession: [])
        XCTAssertEqual(report.attributed, [])
        XCTAssertEqual(report.foreign, ["STATUS.md"])
        XCTAssertNil(RunWorkEvidence.strayWorkRefusal(paths: report.attributed))
        XCTAssertEqual(
            RunWorkEvidence.foreignDirtNote(paths: report.foreign),
            "the checkout changed during this run — STATUS.md — not by the run")
    }

    /// A run that left the checkout alone reports nothing — including when the
    /// checkout was already dirty before it started. A human's own edits are not
    /// the run's work, and blaming them on it would make this fire everywhere.
    func testStrayWorkIgnoresDirtThatWasAlreadyThere() async throws {
        try "a human's edit".write(to: repo.appending(path: "README.md"),
                                   atomically: true, encoding: .utf8)
        let before = await RunWorkEvidence.snapshotProjectRoot(repo)

        let report = await RunWorkEvidence.strayWork(projectRoot: repo, since: before, isolated: true)
        XCTAssertEqual(report, .clean)
        XCTAssertNil(RunWorkEvidence.strayWorkRefusal(paths: report.attributed))
    }

    /// With isolation off the live tree is exactly where the work goes, so
    /// nothing here applies — the check must not report a run for doing its job.
    func testStrayWorkSaysNothingAboutALiveTreeRun() async throws {
        let before = await RunWorkEvidence.snapshotProjectRoot(repo)
        try "worker output".write(to: repo.appending(path: "README.md"),
                                  atomically: true, encoding: .utf8)

        let report = await RunWorkEvidence.strayWork(projectRoot: repo, since: before, isolated: false)
        XCTAssertEqual(report, .clean)
    }

    /// A baseline nobody could take is not evidence. This signal blocks an item,
    /// so an unreadable repository must fail towards letting the run through.
    func testStrayWorkAnswersEmptyWhenEitherReadFailed() async throws {
        let plain = try makeTemporaryDirectory(prefix: "plain")

        let unreadable = await RunWorkEvidence.snapshotProjectRoot(plain)
        XCTAssertNil(unreadable.paths)
        XCTAssertEqual(unreadable, .unreadable)

        // A real "after" against an unreadable "before" still says nothing.
        try "x".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let report = await RunWorkEvidence.strayWork(
            projectRoot: repo, since: .unreadable, isolated: true)
        XCTAssertEqual(report, .clean)
    }

    /// The attribution rule itself, without a repository: a path resolves
    /// against `projectRoot` before it is checked against what the session
    /// wrote, so the comparison is absolute-to-absolute either way.
    func testAttributeStrayPathsSplitsByWhoWroteIt() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let report = RunWorkEvidence.attributeStrayPaths(
            ["Written.swift", "NotWritten.swift"],
            projectRoot: root,
            writtenBySession: ["/tmp/project/Written.swift"])
        XCTAssertEqual(report.attributed, ["Written.swift"])
        XCTAssertEqual(report.foreign, ["NotWritten.swift"])
    }

    // MARK: - What counts as the session's own write

    func testWritingToolsYieldTheFileTheyWrite() {
        let cwd = URL(fileURLWithPath: "/tmp/worktree")
        XCTAssertEqual(RunWorkEvidence.writtenPath(
            toolName: "Write", input: #"{"file_path": "/tmp/project/A.swift", "content": "x"}"#, relativeTo: cwd),
            "/tmp/project/A.swift")
        XCTAssertEqual(RunWorkEvidence.writtenPath(
            toolName: "Edit", input: #"{"file_path": "/tmp/project/B.swift", "old_string": "a", "new_string": "b"}"#,
            relativeTo: cwd),
            "/tmp/project/B.swift")
        XCTAssertEqual(RunWorkEvidence.writtenPath(
            toolName: "MultiEdit", input: #"{"file_path": "/tmp/project/C.swift", "edits": []}"#, relativeTo: cwd),
            "/tmp/project/C.swift")
        XCTAssertEqual(RunWorkEvidence.writtenPath(
            toolName: "NotebookEdit", input: #"{"notebook_path": "/tmp/project/D.ipynb", "new_source": ""}"#,
            relativeTo: cwd),
            "/tmp/project/D.ipynb")
    }

    /// A relative path lands where the session runs, so it resolves against
    /// the session's working directory — never the project root by default.
    func testARelativeWriteResolvesAgainstTheSessionsDirectory() {
        XCTAssertEqual(RunWorkEvidence.writtenPath(
            toolName: "Write", input: #"{"file_path": "Sources/../A.swift"}"#,
            relativeTo: URL(fileURLWithPath: "/tmp/worktree")),
            "/tmp/worktree/A.swift")
    }

    func testToolsThatWriteNoFileYieldNothing() {
        let cwd = URL(fileURLWithPath: "/tmp/worktree")
        XCTAssertNil(RunWorkEvidence.writtenPath(
            toolName: "Read", input: #"{"file_path": "/tmp/project/A.swift"}"#, relativeTo: cwd))
        XCTAssertNil(RunWorkEvidence.writtenPath(
            toolName: "Bash", input: #"{"command": "echo x > /tmp/project/A.swift"}"#, relativeTo: cwd))
        XCTAssertNil(RunWorkEvidence.writtenPath(
            toolName: "Grep", input: #"{"pattern": "x", "path": "/tmp/project"}"#, relativeTo: cwd))
    }

    func testMalformedOrPathlessInputYieldsNothing() {
        let cwd = URL(fileURLWithPath: "/tmp/worktree")
        XCTAssertNil(RunWorkEvidence.writtenPath(toolName: "Write", input: "{not json", relativeTo: cwd))
        XCTAssertNil(RunWorkEvidence.writtenPath(toolName: "Write", input: #"["/tmp/a"]"#, relativeTo: cwd))
        XCTAssertNil(RunWorkEvidence.writtenPath(toolName: "Edit", input: #"{"content": "x"}"#, relativeTo: cwd))
        XCTAssertNil(RunWorkEvidence.writtenPath(toolName: "Write", input: #"{"file_path": ""}"#, relativeTo: cwd))
        XCTAssertNil(RunWorkEvidence.writtenPath(
            toolName: "NotebookEdit", input: #"{"file_path": "/tmp/a.ipynb"}"#, relativeTo: cwd))
    }

    /// The whole path, from the stream to the verdict: a worker whose `Write`
    /// landed in the project's checkout has that write recorded against it as
    /// the call streams past, so `strayWork` attributes the path to the run
    /// instead of calling it foreign — and an agent that wrote nothing still
    /// has nothing recorded against it.
    @MainActor
    func testAWorkersOwnWriteIsAttributedToTheRun() async throws {
        let before = await RunWorkEvidence.snapshotProjectRoot(repo)
        let target = repo.appending(path: "Stray.swift")
        try "written by the worker".write(to: target, atomically: true, encoding: .utf8)

        let mock = MockAgentRuntime()
        mock.events = [
            .toolUse(id: "w1", name: "Write", input: #"{"file_path": "\#(target.path)", "content": "x"}"#),
            .result(.init(text: "done", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "s1", permissionDenials: [])),
        ]
        let orchestrator = Orchestrator(runtime: mock)
        for id in ["worker", "bystander"] {
            orchestrator.addAgent(Agent(id: id, name: id, model: "sonnet", systemPrompt: "", tools: [],
                                        denied: [], permissionMode: "auto", state: .idle))
        }
        let cwd = try makeTemporaryDirectory(prefix: "worker-cwd")
        let vm = ChatViewModel(agentID: "worker", projectURL: cwd, orchestrator: orchestrator)
        try await orchestrator.startAgent("worker", cwd: cwd)
        vm.inputText = "do the item"
        await vm.send()

        XCTAssertTrue(orchestrator.writtenPaths(for: "bystander").isEmpty)
        let report = await RunWorkEvidence.strayWork(
            projectRoot: repo, since: before, isolated: true,
            writtenBySession: orchestrator.writtenPaths(for: "worker"))
        XCTAssertEqual(report.attributed, ["Stray.swift"])
        XCTAssertEqual(report.foreign, [])
    }

    /// The rule itself, without a repository: only paths that were clean before
    /// and are dirty now, sorted, with the run's own bookkeeping left out.
    func testStrayPathsCountsOnlyWhatTheRunDirtied() {
        XCTAssertEqual(
            RunWorkEvidence.strayPaths(before: ["old.txt"], after: ["old.txt", "b.swift", "a.swift"]),
            ["a.swift", "b.swift"])
        // A path that stopped being dirty is not stray work either.
        XCTAssertEqual(RunWorkEvidence.strayPaths(before: ["old.txt"], after: []), [])
        XCTAssertEqual(RunWorkEvidence.strayPaths(before: nil, after: ["a.swift"]), [])
        XCTAssertEqual(RunWorkEvidence.strayPaths(before: [], after: nil), [])
    }

    /// The run moves the backlog through its statuses and appends to the item's
    /// detail file, both in the project root. Those are its own bookkeeping, not
    /// the worker's edits — counting them would fire on every single item of a
    /// project whose backlog lives in the repository.
    func testStrayPathsExcludesTheRunsOwnBookkeeping() {
        let stray = RunWorkEvidence.strayPaths(
            before: [],
            after: ["BACKLOG.md", "backlog/an-item.md", ".kiteloop/traces/x.jsonl", "Real.swift"],
            ignoring: [".kiteloop/", "BACKLOG.md", "backlog/an-item.md"])

        XCTAssertEqual(stray, ["Real.swift"])
    }

    /// Which paths those are, derived from where the backlog actually is. A
    /// vault backlog dirties nothing in the repository, so it contributes none.
    func testBacklogPathsCoverTheFilesARunWritesInTheProjectRoot() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let local = BacklogAutopilot.backlogPaths(
            projectRoot: root,
            backlogURL: root.appending(path: "BACKLOG.md"),
            detailPath: "backlog/an-item.md")
        XCTAssertEqual(local, [".kiteloop/", "BACKLOG.md", "backlog/an-item.md"])

        let vault = BacklogAutopilot.backlogPaths(
            projectRoot: root,
            backlogURL: URL(fileURLWithPath: "/tmp/vault/Projects/p/BACKLOG.md"),
            detailPath: "backlog/an-item.md")
        XCTAssertEqual(vault, [".kiteloop/"])

        XCTAssertEqual(
            BacklogAutopilot.backlogPaths(projectRoot: root, backlogURL: nil, detailPath: nil),
            [".kiteloop/"])
    }

    // MARK: - The run that changed nothing because there was nothing to change

    /// The claim CLAUDE.md asks a worker to make when there is nothing left to
    /// build, in the shape the prompt spells out. Until it had a shape it had no
    /// ending: three workers made it in prose on
    /// `wizard-hands-off-to-a-first-project`, and all three were filed as runs
    /// that achieved nothing.
    func testAWellFormedClaimWithEvidenceIsRead() {
        let claim = RunWorkEvidence.AlreadyImplementedClaim.parse("""
            I believe this item is already implemented and am not manufacturing a diff.

            {"outcome": "already-implemented",
             "evidence": ["Views/Setup/SetupWizard.swift — `finish()` opens the home workspace",
                          "MainWindow.swift — focuses the input bar on open"]}
            """)
        XCTAssertEqual(claim?.evidence, [
            "Views/Setup/SetupWizard.swift — `finish()` opens the home workspace",
            "MainWindow.swift — focuses the input bar on open",
        ])
    }

    /// The evidence list is the whole guard. A claim that names nothing has said
    /// no more than a worker that said nothing, and reading it as a claim would
    /// hand every struggling run a way out of the retry ceiling.
    func testAClaimWithNoEvidenceIsNotAClaim() {
        XCTAssertNil(RunWorkEvidence.AlreadyImplementedClaim.parse(
            #"{"outcome": "already-implemented", "evidence": []}"#))
        XCTAssertNil(RunWorkEvidence.AlreadyImplementedClaim.parse(
            #"{"outcome": "already-implemented"}"#))
        // A list of blanks is a list of nothing.
        XCTAssertNil(RunWorkEvidence.AlreadyImplementedClaim.parse(
            #"{"outcome": "already-implemented", "evidence": ["", "   "]}"#))
        // And a list that is not a list.
        XCTAssertNil(RunWorkEvidence.AlreadyImplementedClaim.parse(
            #"{"outcome": "already-implemented", "evidence": "Foo.swift"}"#))
    }

    /// Prose is not a claim, however plainly it says the same thing. That is the
    /// state the three retired runs were in, and giving it an ending would mean
    /// reading a category out of free text — which `RunClosingMessage` exists to
    /// avoid doing.
    func testProseAloneIsNotAClaim() {
        XCTAssertNil(RunWorkEvidence.AlreadyImplementedClaim.parse(
            "I believe this item is already implemented. The setup wizard already "
            + "lands the user in the home workspace with an agent hired."))
        XCTAssertNil(RunWorkEvidence.AlreadyImplementedClaim.parse(nil))
        XCTAssertNil(RunWorkEvidence.AlreadyImplementedClaim.parse(""))
    }

    /// A different outcome is a different answer. Only this one has an ending.
    func testAnotherOutcomeIsNotThisClaim() {
        XCTAssertNil(RunWorkEvidence.AlreadyImplementedClaim.parse(
            #"{"outcome": "done", "evidence": ["Foo.swift — `bar()`"]}"#))
        XCTAssertNil(RunWorkEvidence.AlreadyImplementedClaim.parse(
            #"{"passed": true, "reason": "looks good"}"#))
    }

    /// `already_implemented` and `Already Implemented` are the same word. Sending
    /// a worker that did the right thing back to the ceiling over an underscore
    /// is the failure this whole ending exists to stop.
    func testTheOutcomeTokenIsReadPastItsSpelling() {
        for spelling in ["already_implemented", "Already-Implemented", " already implemented "] {
            let claim = RunWorkEvidence.AlreadyImplementedClaim.parse(
                #"{"outcome": "\#(spelling)", "evidence": ["Foo.swift — `bar()`"]}"#)
            XCTAssertEqual(claim?.evidence, ["Foo.swift — `bar()`"], "\(spelling) is the same word")
        }
    }

    /// The claim is found even when the worker quoted some other JSON ahead of
    /// it — which a worker explaining what it read very often does.
    func testTheClaimIsFoundBehindAnotherObject() {
        let claim = RunWorkEvidence.AlreadyImplementedClaim.parse("""
            The config already carries it: {"autopilotReady": true, "worker": "Builder"}

            {"outcome": "already-implemented", "evidence": ["Services/Foo.swift — `Foo.bar()`"]}
            """)
        XCTAssertEqual(claim?.evidence, ["Services/Foo.swift — `Foo.bar()`"])
    }

    /// Parsed off the raw closing message rather than the condensed one. The
    /// 300-character bound is what keeps a note readable and is exactly the
    /// wrong thing to hand a parser — a claim naming four files clears it
    /// easily, and JSON cut off mid-string is not JSON.
    func testAClaimLongerThanTheCondensedBoundIsStillRead() {
        let evidence = (1...6).map { "Kiteloop/Services/AVeryLongServiceName\($0).swift — `TypeName\($0).method()`" }
        let body = evidence.map { "\"\($0)\"" }.joined(separator: ", ")
        let message = #"{"outcome": "already-implemented", "evidence": [\#(body)]}"#
        XCTAssertGreaterThan(message.count, RunClosingMessage.characterLimit)

        XCTAssertEqual(RunWorkEvidence.AlreadyImplementedClaim.parse(message)?.evidence, evidence)
        // The condensed form is what a human is shown, and it genuinely cannot
        // be parsed — which is the whole reason capture stopped applying it.
        XCTAssertNil(RunWorkEvidence.AlreadyImplementedClaim.parse(
            RunClosingMessage.condensed(message)))
    }

    /// End to end through the path the run actually takes: the worker's text is
    /// captured onto its node's step, the run loop reads it back, and the claim
    /// is still there. This is what broke first — the message was condensed at
    /// *capture*, so a claim over 300 characters arrived as JSON with no closing
    /// brace and read as no claim at all.
    func testAClaimSurvivesCaptureOntoTheStepAndIsReadBack() {
        let evidence = (1...6).map { "Kiteloop/Services/AVeryLongServiceName\($0).swift — `TypeName\($0).method()`" }
        let body = evidence.map { "\"\($0)\"" }.joined(separator: ", ")
        let finalText = """
            I believe this item is already implemented.

            {"outcome": "already-implemented", "evidence": [\(body)]}
            """
        XCTAssertGreaterThan(finalText.count, RunClosingMessage.characterLimit)

        // Exactly what `ChatViewModel.completeActiveWorkflowNode` writes.
        let captured = RunClosingMessage.captured(finalText)
        let steps = [ExecutionStep(nodeID: "worker", agentID: "w", spanID: nil,
                                   startedAt: Date(), completedAt: Date(),
                                   output: [RunClosingMessage.outputKey: .string(captured ?? "")])]

        let raw = RunClosingMessage.rawLastMessage(in: steps, node: "worker")
        XCTAssertEqual(RunWorkEvidence.AlreadyImplementedClaim.parse(raw)?.evidence, evidence)
        // And a human still gets one bounded line off the same step.
        let shown = RunClosingMessage.lastMessage(in: steps, node: "worker")
        XCTAssertEqual(shown?.count, RunClosingMessage.characterLimit + 1)  // the ellipsis
        XCTAssertFalse(shown?.contains("\n") ?? true)
        XCTAssertNil(RunClosingMessage.rawLastMessage(in: steps, node: "reviewer"))
    }

    /// Each entry is one line: the item's Notes render them as a markdown list,
    /// and an entry carrying its own newlines would break out of it.
    func testEvidenceEntriesAreCollapsedToOneLine() {
        let claim = RunWorkEvidence.AlreadyImplementedClaim.parse(
            #"{"outcome": "already-implemented", "evidence": ["Foo.swift\n  — `bar()`\n  does it"]}"#)
        XCTAssertEqual(claim?.evidence, ["Foo.swift — `bar()` does it"])
    }

    /// What the human at the gate reads. An item waiting there with no diff
    /// behind it has to say why — and above all that *nothing has checked the
    /// claim*, because approving it accepts an agent's say-so.
    func testTheNoteSaysNothingHasVerifiedTheClaim() {
        let claim = RunWorkEvidence.AlreadyImplementedClaim(
            evidence: ["Services/Foo.swift — `Foo.bar()`", "Views/Baz.swift — calls it"])
        let note = claim.note
        XCTAssertTrue(note.contains("changed no files"), note)
        XCTAssertTrue(note.contains("Nothing has verified that"), note)
        for line in claim.evidence {
            XCTAssertTrue(note.contains(line), "the note names \(line)")
        }
        XCTAssertTrue(claim.summary.contains("2 pieces of evidence"), claim.summary)
    }

    /// The worker is told the shape it has to write, and told what happens
    /// without the evidence. It could not have written this claim otherwise —
    /// the prompt is the only place the shape is ever stated to an agent.
    func testTheEmptyDiffPromptAsksForTheClaimItCanRoute() {
        XCTAssertTrue(EmptyDiffHandoff.prompt.contains(
            RunWorkEvidence.AlreadyImplementedClaim.outcome), EmptyDiffHandoff.prompt)
        XCTAssertTrue(EmptyDiffHandoff.prompt.contains("evidence"), EmptyDiffHandoff.prompt)
    }

    /// And the example the prompt shows is one the parser actually reads — a
    /// prompt that demonstrates a shape nothing routes is worse than no prompt.
    func testThePromptsOwnExampleParses() {
        let claim = RunWorkEvidence.AlreadyImplementedClaim.parse(EmptyDiffHandoff.prompt)
        XCTAssertEqual(claim?.evidence, ["Services/Foo.swift — `Foo.bar()` already does X",
                                         "Views/Baz.swift — calls it on save"])
    }

    /// Recorded under its own outcome, and specifically **not** as the no-work
    /// signal — which is the string `RetryCeiling` counts on and the reason the
    /// three retired runs were indistinguishable from dead sessions.
    func testAClaimIsRecordedUnderItsOwnOutcome() {
        let recorded = BacklogAutopilot.outcomeString(.alreadyImplemented)
        XCTAssertEqual(recorded, "already-implemented")
        XCTAssertFalse(recorded.contains(RunWorkEvidence.noWorkPrefix))
        XCTAssertNotEqual(recorded, BacklogAutopilot.outcomeString(.awaitingApproval))
    }

    /// No path from a claim reaches `done` without a person. Nothing has checked
    /// the claim, so the run must not clear its own gate and must not merge —
    /// even in a project that approves review-passed runs and auto-merges, which
    /// is the configuration where this could otherwise slip through.
    func testAClaimCannotClearItsOwnGateOrMerge() {
        XCTAssertEqual(
            BacklogAutopilot.gateResolution(outcome: .alreadyImplemented,
                                            reviewPassed: true,
                                            autoApproveReviewPassed: true,
                                            mergeRefusal: nil),
            .human)
        XCTAssertFalse(
            BacklogAutopilot.shouldAutoMerge(outcome: .alreadyImplemented,
                                             hasBranch: true,
                                             autoMergeOnApproval: true,
                                             reviewPassed: true,
                                             autoApproveReviewPassed: true))
    }

    /// An agent that followed CLAUDE.md's own instruction is not a failure, on
    /// any surface that counts one. The history box and the autonomous-run
    /// breaker both read a pass/fail off the ending, and filing this as red
    /// would be the original defect one screen further along.
    @MainActor
    func testAClaimIsNotCountedAsAFailedRun() {
        XCTAssertTrue(AutopilotHistorySummary.isPass(BacklogAutopilot.ItemResult.Outcome.alreadyImplemented))
        XCTAssertTrue(AutopilotHistorySummary.isPass(BacklogAutopilot.outcomeString(.alreadyImplemented)))
        XCTAssertTrue(CoordinatorRunScheduler.outcome(
            itemID: "an-item",
            results: [BacklogAutopilot.ItemResult(id: "an-item", title: "An item",
                                                  outcome: .alreadyImplemented, duration: 1)]
        ).succeeded)
    }

    // MARK: - The triage caller reads the same answer

    /// `CoordinatorBlockedTriage` asks the same question of an already-blocked
    /// item; it must not grow a second answer that can disagree with the gate's.
    func testTriageReadsTheSharedCheck() async {
        branchWithWork("kiteloop/triage-item")
        let has = await CoordinatorBlockedTriage.branchHasCommits(root: repo, itemID: "triage-item")
        XCTAssertEqual(has, true)

        git(["branch", "kiteloop/triage-empty", "HEAD"])
        let empty = await CoordinatorBlockedTriage.branchHasCommits(root: repo, itemID: "triage-empty")
        XCTAssertEqual(empty, false)

        // Nobody looked isn't evidence: a blocked run keeps its branch, so a
        // missing one means the run was never isolated.
        let absent = await CoordinatorBlockedTriage.branchHasCommits(root: repo, itemID: "never-ran")
        XCTAssertNil(absent)
    }
}
