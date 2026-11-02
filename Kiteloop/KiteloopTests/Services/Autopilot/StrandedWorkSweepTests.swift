import XCTest
@testable import Kiteloop

/// The done-and-unmerged sweep, against a real repository — the value of the
/// type is that it asks git, so a fake repository would be testing the fake.
///
/// What it must get right is what let two items sit marked done with their work
/// on branches `main` had never seen: a stranded item is reported, a merged or
/// missing one is not, an unreadable repository invents nothing, and the whole
/// thing is cheap enough to run on every request.
final class StrandedWorkSweepTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try makeTemporaryDirectory(prefix: "stranded-sweep")
        git("init", "-q", "-b", "main")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        try write("README.md", "base\n")
        git("add", "-A")
        git("commit", "-qm", "base")
    }

    // MARK: - What is reported

    /// The case itself: done, with commits only on the branch.
    func testADoneItemWhoseBranchIsAheadOfHeadIsReported() async throws {
        try branchWithWork("kiteloop/item-1")

        let report = await StrandedWorkSweep.read(projectRoot: root, doneItemIDs: ["item-1"])

        XCTAssertFalse(report.unreadable)
        XCTAssertEqual(report.count, 1)
        let stranded = try XCTUnwrap(report.stranded.first)
        XCTAssertEqual(stranded.itemID, "item-1")
        XCTAssertEqual(stranded.branch, "kiteloop/item-1")
        XCTAssertEqual(stranded.commitsAhead, 1)
    }

    /// The wording is the disagreement rule's, not this type's — one finding
    /// must not read differently in the sweep and in the item detail view.
    func testTheFindingCarriesTheDisagreementRulesOwnWords() async throws {
        try branchWithWork("kiteloop/item-1")
        try branchWithWork("kiteloop/item-1", file: "More.swift", from: "kiteloop/item-1")

        let report = await StrandedWorkSweep.read(projectRoot: root, doneItemIDs: ["item-1"])

        let stranded = try XCTUnwrap(report.stranded.first)
        let truth = await ItemGitTruth.read(projectRoot: root, itemID: "item-1")
        let expected = try XCTUnwrap(
            ItemDisagreements.detect(status: .done, latestRun: nil, git: truth).first)
        XCTAssertEqual(stranded.ledgerSays, expected.ledgerSays)
        XCTAssertEqual(stranded.gitSays, expected.gitSays)
        XCTAssertEqual(stranded.gitSays, "kiteloop/item-1 is not merged — 2 commits exist only there")
    }

    /// Every stranded item, in backlog order, not just the first one found.
    func testEveryStrandedItemIsReportedInTheOrderItWasGiven() async throws {
        try branchWithWork("kiteloop/item-1")
        try branchWithWork("kiteloop/item-2", file: "Two.swift")
        try branchWithWork("kiteloop/item-3", file: "Three.swift")
        git("merge", "-q", "--no-ff", "-m", "merge", "kiteloop/item-2")

        let report = await StrandedWorkSweep.read(
            projectRoot: root, doneItemIDs: ["item-3", "item-2", "item-1"])

        XCTAssertEqual(report.stranded.map(\.itemID), ["item-3", "item-1"])
    }

    // MARK: - A branch teardown dropped

    /// The other way work strands: teardown deleted the branch while its commits
    /// were never merged, so the branch listing has nothing to name and the item
    /// used to be counted clean. The commits are still in the object store.
    func testADoneItemWhoseDroppedBranchLeftDanglingCommitsIsReported() async throws {
        try droppedBranchWithWork(itemID: "dropped-item")

        let report = await StrandedWorkSweep.read(projectRoot: root, doneItemIDs: ["dropped-item"])

        XCTAssertFalse(report.unreadable)
        let stranded = try XCTUnwrap(report.stranded.first)
        XCTAssertEqual(stranded.itemID, "dropped-item")
        XCTAssertEqual(stranded.branch, "kiteloop/dropped-item")
        XCTAssertEqual(stranded.commitsAhead, 0, "there is no branch left to count commits on")
    }

    /// And in the disagreement rule's words, not this type's — the same
    /// requirement the unmerged-branch finding carries.
    func testTheDroppedBranchFindingCarriesTheDisagreementRulesOwnWords() async throws {
        try droppedBranchWithWork(itemID: "dropped-item")

        let report = await StrandedWorkSweep.read(projectRoot: root, doneItemIDs: ["dropped-item"])

        let stranded = try XCTUnwrap(report.stranded.first)
        let truth = await ItemGitTruth.read(projectRoot: root, itemID: "dropped-item")
        let expected = try XCTUnwrap(
            ItemDisagreements.detect(status: .done, latestRun: nil, git: truth).first)
        XCTAssertEqual(stranded.ledgerSays, expected.ledgerSays)
        XCTAssertEqual(stranded.gitSays, expected.gitSays)
        XCTAssertEqual(stranded.gitSays, "there is no branch kiteloop/dropped-item — its "
                       + "commits are still in the object store, unreferenced")
    }

    /// A branch the manager deleted over unmerged commits is not dangling — its
    /// tip is under a backup ref — and the sweep says where, without paying for
    /// the object walk.
    func testADoneItemWhoseDroppedBranchWasBackedUpIsReportedWithTheRef() async throws {
        let branch = WorktreeSession.branchName(for: "kept-item")
        git("checkout", "-q", "-b", branch)
        try write("kept.swift", "let x = 1\n")
        git("add", "-A")
        git("commit", "-qm", "work")
        let tip = git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        git("checkout", "-q", "main")
        git("update-ref", WorktreeManager.backupRef(for: "kept-item", tip: tip), tip)
        git("branch", "-D", branch)

        let report = await StrandedWorkSweep.read(projectRoot: root, doneItemIDs: ["kept-item"])

        let stranded = try XCTUnwrap(report.stranded.first)
        XCTAssertEqual(stranded.itemID, "kept-item")
        XCTAssertEqual(stranded.gitSays,
                       "there is no branch kiteloop/kept-item — its tip is kept at refs/kiteloop/backup/kept-item/\(tip)")
    }

    /// A done item that never had a branch and left nothing behind is exactly
    /// what most of a backlog looks like. The missing ref is not the finding —
    /// surviving commits are — so this stays silent.
    func testADoneItemWithNoBranchAndNoDanglingCommitIsNotReported() async throws {
        try droppedBranchWithWork(itemID: "dropped-item")

        let report = await StrandedWorkSweep.read(
            projectRoot: root, doneItemIDs: ["never-run", "dropped-item"])

        XCTAssertEqual(report.stranded.map(\.itemID), ["dropped-item"])
    }

    /// A dangling commit belongs to whoever wrote it. Another item's teardown
    /// subject, and a human's message, are both somebody else's work.
    func testADanglingCommitFromAnotherItemOrAHumanIsNotAttributed() async throws {
        try droppedBranchWithWork(itemID: "other-item")
        try droppedBranchWithWork(itemID: "hand-written", subject: "wip: trying something")

        let report = await StrandedWorkSweep.read(
            projectRoot: root, doneItemIDs: ["item-1", "hand-written"])

        XCTAssertEqual(report.stranded, [], "\(report.stranded)")
    }

    // MARK: - What is not

    /// A branch already reachable from HEAD is what done is supposed to mean.
    func testAMergedBranchIsNotReported() async throws {
        try branchWithWork("kiteloop/item-1")
        git("merge", "-q", "--no-ff", "-m", "merge", "kiteloop/item-1")

        let report = await StrandedWorkSweep.read(projectRoot: root, doneItemIDs: ["item-1"])

        XCTAssertEqual(report.stranded, [])
        XCTAssertFalse(report.unreadable)
        XCTAssertEqual(report.doneItemsConsidered, 1)
    }

    /// No branch, and nothing of the item's left in the object store either. The
    /// ref is asked about — that is the dangling pass — and the answer is that
    /// there was never any work to strand.
    func testAnItemWithNoBranchIsNotReported() async {
        let report = await StrandedWorkSweep.read(projectRoot: root, doneItemIDs: ["never-run"])

        XCTAssertEqual(report.stranded, [])
        XCTAssertEqual(report.branchesExamined, 0)
        XCTAssertEqual(report.danglingCandidatesExamined, 1)
        XCTAssertEqual(report.danglingCandidatesNotExamined, 0)
    }

    /// An unmerged branch under an item nobody marked done is not this sweep's
    /// business — work in flight looks exactly like this.
    func testAnUnmergedBranchForAnItemThatIsNotDoneIsNotReported() async throws {
        try branchWithWork("kiteloop/item-1")

        // The item is `ready`, so it is simply not among the done ids.
        let report = await StrandedWorkSweep.read(projectRoot: root, doneItemIDs: [])

        XCTAssertEqual(report.stranded, [])
        XCTAssertEqual(report.doneItemsConsidered, 0)
    }

    // MARK: - Unreadable git

    /// A directory that is not a repository. The one reading that must never be
    /// mistaken for a finding: reported as unreadable, with nothing stranded.
    func testADirectoryThatIsNotARepositoryReportsUnreadableRatherThanStrandings() async throws {
        let plain = try makeTemporaryDirectory(prefix: "stranded-not-a-repo")

        let report = await StrandedWorkSweep.read(projectRoot: plain, doneItemIDs: ["item-1", "item-2"])

        XCTAssertTrue(report.unreadable)
        XCTAssertEqual(report.stranded, [])
        XCTAssertEqual(report.doneItemsConsidered, 2)
    }

    /// No project root at all — same reading, and not a crash.
    func testNoProjectRootReportsUnreadable() async {
        let report = await StrandedWorkSweep.read(projectRoot: nil, doneItemIDs: ["item-1"])

        XCTAssertTrue(report.unreadable)
        XCTAssertEqual(report.stranded, [])
    }

    /// The listing answered, the per-branch count did not. An unanswered
    /// question is not a finding, so the item is left alone rather than reported
    /// with a made-up count.
    func testABranchWhoseCountCannotBeReadIsNotReported() {
        let report = StrandedWorkSweep.sweep(doneItemIDs: ["item-1"]) { args in
            args.first == "branch" ? (0, "kiteloop/item-1\n") : (128, "")
        }

        XCTAssertEqual(report.stranded, [])
        XCTAssertFalse(report.unreadable, "the listing was readable; only the count failed")
    }

    // MARK: - What it costs

    /// The reason this can run on every request: a project with 300 done items
    /// and nothing stranded costs one listing and a bounded ref read, never one
    /// call per done item — and no object walk at all, since every branch is
    /// still there.
    func testAProjectFullOfDoneItemsCostsABoundedNumberOfGitCallsWhenNothingIsUnmerged() {
        let done = (1...300).map { "item-\($0)" }
        var calls: [[String]] = []

        let report = StrandedWorkSweep.sweep(doneItemIDs: done) { args in
            calls.append(args)
            // git answered: no branch is unmerged, and every ref resolves.
            return (0, "")
        }

        XCTAssertEqual(calls.first?.first, "branch", "one listing for the whole project")
        XCTAssertEqual(calls.count, 1 + StrandedWorkSweep.danglingBudget,
                       "the listing plus the bounded ref read — \(calls.count)")
        XCTAssertTrue(calls.dropFirst().allSatisfy { $0.first == "rev-parse" },
                      "nothing else is asked when every ref resolves — \(calls)")
        XCTAssertEqual(report.doneItemsConsidered, 300)
        XCTAssertEqual(report.branchesExamined, 0)
        XCTAssertEqual(report.stranded, [])
    }

    /// Only the done items the listing named cost a commit count — the other 298
    /// are answered by the listing itself, and pay at most a ref read each.
    func testOnlyTheBranchesTheListingNamedCostACommitCount() {
        let done = (1...300).map { "item-\($0)" }
        var calls: [[String]] = []

        let report = StrandedWorkSweep.sweep(doneItemIDs: done) { args in
            calls.append(args)
            if args.first == "branch" { return (0, "kiteloop/item-7\nkiteloop/item-42\n") }
            return (0, "3\n")
        }

        XCTAssertEqual(calls.filter { $0.first == "rev-list" }.count, 2,
                       "one count per named branch — \(calls.count)")
        XCTAssertEqual(report.stranded.map(\.itemID), ["item-7", "item-42"])
        XCTAssertEqual(report.stranded.map(\.commitsAhead), [3, 3])
        XCTAssertEqual(report.branchesExamined, 2)
        XCTAssertEqual(report.branchesNotExamined, 0)
    }

    /// The object walk is paid once for the whole sweep, however many done items
    /// turn out to have no branch — it is a question about the repository, and
    /// its answer is the same for every item asking.
    func testHoweverManyItemsHaveNoBranchTheObjectWalkIsAskedOnce() {
        let done = (1...40).map { "item-\($0)" }
        var fsckCalls = 0

        let report = StrandedWorkSweep.sweep(doneItemIDs: done) { args in
            switch args.first {
            case "branch": return (0, "")
            case "rev-parse": return (1, "")   // git answered: no such ref
            case "for-each-ref": return (0, "")   // and no backup ref either
            case "fsck":
                fsckCalls += 1
                return (0, "dangling commit abc123\n")
            default: return (0, "autopilot: item-9\n")
            }
        }

        XCTAssertEqual(fsckCalls, 1)
        XCTAssertEqual(report.stranded.map(\.itemID), ["item-9"])
    }

    /// And not at all when every done item still has a branch: the walk is the
    /// expensive half, and a project with nothing missing must not pay for it.
    func testNoObjectWalkWhenEveryDoneItemStillHasItsBranch() {
        var calls: [[String]] = []

        let report = StrandedWorkSweep.sweep(doneItemIDs: ["item-1", "item-2"]) { args in
            calls.append(args)
            if args.first == "branch" { return (0, "kiteloop/item-1\n") }
            if args.first == "rev-parse" { return (0, "deadbeef\n") }
            return (0, "1\n")
        }

        XCTAssertTrue(calls.allSatisfy { $0.first != "fsck" }, "\(calls)")
        XCTAssertEqual(report.stranded.map(\.itemID), ["item-1"])
    }

    // MARK: - The cache

    /// The backlog endpoint paid the whole sweep on every poll — 15 seconds
    /// on a project with 345 item branches. Refs that have not moved give the
    /// same answer, and are not walked again; refs that moved are.
    func testASweepOverUnchangedRefsIsAnsweredFromTheCache() async {
        var refs = "aaa refs/heads/main\nbbb refs/heads/kiteloop/item-1\n"
        var listings = 0
        let git: StrandedWorkSweep.Git = { args in
            switch args.first {
            case "for-each-ref": return (0, refs)
            case "rev-parse": return (0, "aaa\n")
            case "branch": listings += 1; return (0, "kiteloop/item-1\n")
            default: return (0, "2\n")
            }
        }
        let project = "/tmp/cache-\(UUID().uuidString)"

        let first = await StrandedWorkSweep.cachedSweep(project: project, doneItemIDs: ["item-1"], git: git)
        let second = await StrandedWorkSweep.cachedSweep(project: project, doneItemIDs: ["item-1"], git: git)
        XCTAssertEqual(first, second)
        XCTAssertEqual(listings, 1, "the same refs are not walked twice")

        _ = await StrandedWorkSweep.cachedSweep(project: project, doneItemIDs: ["item-1", "item-2"], git: git)
        XCTAssertEqual(listings, 2, "a different set of done items is a different question")

        refs = "ccc refs/heads/main\nbbb refs/heads/kiteloop/item-1\n"
        _ = await StrandedWorkSweep.cachedSweep(project: project, doneItemIDs: ["item-1", "item-2"], git: git)
        XCTAssertEqual(listings, 3, "a ref that moved is walked again")
        await StrandedWorkSweep.forgetCachedSweep(project: project)
    }

    /// A listing git could not give is never kept: the next poll asks again.
    func testAnUnreadableSweepIsNotCached() async {
        var listings = 0
        let git: StrandedWorkSweep.Git = { args in
            switch args.first {
            case "for-each-ref": return (0, "aaa refs/heads/main\n")
            case "rev-parse": return (0, "aaa\n")
            case "branch": listings += 1; return (128, "")
            default: return (0, "")
            }
        }
        let project = "/tmp/cache-\(UUID().uuidString)"
        _ = await StrandedWorkSweep.cachedSweep(project: project, doneItemIDs: ["item-1"], git: git)
        _ = await StrandedWorkSweep.cachedSweep(project: project, doneItemIDs: ["item-1"], git: git)
        XCTAssertEqual(listings, 2)
    }

    /// An `fsck` nobody could read adds no finding and takes none away. The one
    /// reading it must never produce is "every done item is stranded".
    func testAnFsckThatFailsLeavesTheBranchPassFindingsIntact() {
        let report = StrandedWorkSweep.sweep(doneItemIDs: ["item-1", "item-2"]) { args in
            switch args.first {
            case "branch": return (0, "kiteloop/item-1\n")
            case "rev-parse": return (1, "")
            case "for-each-ref": return (0, "")   // no backup ref kept for it
            case "fsck": return (128, "")
            default: return (0, "2\n")
            }
        }

        XCTAssertEqual(report.stranded.map(\.itemID), ["item-1"])
        XCTAssertFalse(report.unreadable, "the listing was readable; only the walk failed")
    }

    /// The dangling pass is bounded the way the branch pass is, and says what it
    /// left unasked — a sweep that stopped early must not read as a clean one.
    func testTheDanglingBudgetBoundsTheRefReadsAndTheShortfallIsReported() {
        let budget = StrandedWorkSweep.danglingBudget
        let done = (1...(budget + 7)).map { "item-\($0)" }
        var refReads = 0

        let report = StrandedWorkSweep.sweep(doneItemIDs: done) { args in
            if args.first == "branch" { return (0, "") }
            if args.first == "rev-parse" {
                refReads += 1
                return (0, "deadbeef\n")
            }
            return (0, "")
        }

        XCTAssertEqual(refReads, budget)
        XCTAssertEqual(report.danglingCandidatesExamined, budget)
        XCTAssertEqual(report.danglingCandidatesNotExamined, 7)
    }

    /// A ref read that failed outright is not an answer. It says nothing about
    /// whether the branch is there, so the item is left alone rather than walked
    /// for dangling commits.
    func testARefReadThatCouldNotBeAnsweredIsNotTreatedAsAMissingBranch() {
        var calls: [[String]] = []

        let report = StrandedWorkSweep.sweep(doneItemIDs: ["item-1"]) { args in
            calls.append(args)
            if args.first == "branch" { return (0, "") }
            return (128, "")   // not a repository, mid-sweep
        }

        XCTAssertTrue(calls.allSatisfy { $0.first != "fsck" }, "\(calls)")
        XCTAssertEqual(report.stranded, [])
    }

    /// A backlog with nothing done does not spawn git at all.
    func testAnEmptyDoneListAsksGitNothing() {
        var calls = 0

        let report = StrandedWorkSweep.sweep(doneItemIDs: []) { _ in
            calls += 1
            return (0, "")
        }

        XCTAssertEqual(calls, 0)
        XCTAssertFalse(report.unreadable, "nothing to ask about is not an unreadable repository")
    }

    /// A project that accumulates unmerged branches on purpose must not make a
    /// poller pay for all of them — and the sweep has to say it stopped early,
    /// since a truncated sweep that reads like a complete one is no sweep.
    func testTheBranchBudgetBoundsTheSweepAndTheShortfallIsReported() {
        let budget = StrandedWorkSweep.branchBudget
        let done = (1...(budget + 10)).map { "item-\($0)" }
        let allUnmerged = done.map { "kiteloop/\($0)" }.joined(separator: "\n")
        var counts = 0

        let report = StrandedWorkSweep.sweep(doneItemIDs: done) { args in
            if args.first == "branch" { return (0, allUnmerged) }
            counts += 1
            return (0, "1\n")
        }

        XCTAssertEqual(counts, budget)
        XCTAssertEqual(report.branchesExamined, budget)
        XCTAssertEqual(report.branchesNotExamined, 10)
        XCTAssertEqual(report.count, budget)
    }

    // MARK: - A dirty worktree for an item nothing is coming back for

    /// The case itself: uncommitted changes sitting in a worktree for an item
    /// that is neither running nor kept for inspection — the case a done-only
    /// sweep cannot see at all, found by hand on 2026-08-21.
    func testADirtyWorktreeForAnOpenItemIsReported() async throws {
        let path = try dirtyWorktree(itemID: "open-item")

        let report = await StrandedWorkSweep.read(
            projectRoot: root, doneItemIDs: [],
            statusByItemID: ["open-item": .ready])

        XCTAssertEqual(report.count, 1)
        let stranded = try XCTUnwrap(report.stranded.first)
        XCTAssertEqual(stranded.itemID, "open-item")
        XCTAssertEqual(stranded.branch, "kiteloop/open-item")
        XCTAssertEqual(stranded.worktreePath, path)
        XCTAssertEqual(stranded.uncommittedFiles, 1)
    }

    /// The count reported is files, and the item and the worktree path are
    /// both named, so the finding can be acted on without a search.
    func testTheDirtyWorktreeFindingNamesFileCountItemAndPath() async throws {
        let path = try dirtyWorktree(itemID: "open-item", fileCount: 3)

        let report = await StrandedWorkSweep.read(
            projectRoot: root, doneItemIDs: [],
            statusByItemID: ["open-item": .active])

        let stranded = try XCTUnwrap(report.stranded.first)
        XCTAssertEqual(stranded.itemID, "open-item")
        XCTAssertEqual(stranded.worktreePath, path)
        XCTAssertEqual(stranded.uncommittedFiles, 3)
        XCTAssertTrue(stranded.gitSays.contains("3"), stranded.gitSays)
    }

    /// A run in flight is dirty for the whole of the run — that is what a run
    /// looks like from outside, and it must not be reported.
    func testADirtyWorktreeForTheInFlightItemIsNotReported() async throws {
        try dirtyWorktree(itemID: "running-item")

        let report = await StrandedWorkSweep.read(
            projectRoot: root, doneItemIDs: [],
            statusByItemID: ["running-item": .active],
            inFlightItemID: "running-item")

        XCTAssertEqual(report.stranded, [])
    }

    /// Kept on purpose for a person to inspect after a blocked run — the app
    /// already keeps this on purpose and says so in the run log, so the sweep
    /// must not say it again.
    func testADirtyWorktreeForABlockedItemIsNotReported() async throws {
        try dirtyWorktree(itemID: "blocked-item")

        let report = await StrandedWorkSweep.read(
            projectRoot: root, doneItemIDs: [],
            statusByItemID: ["blocked-item": .blocked])

        XCTAssertEqual(report.stranded, [])
    }

    /// A clean worktree is not reported, whatever its item's state.
    func testACleanWorktreeIsNotReportedWhateverItsStatus() async throws {
        let branch = WorktreeSession.branchName(for: "clean-item")
        let worktreePath = root.appending(path: ".kiteloop/worktrees/clean-item")
        git("worktree", "add", "-q", "-b", branch, worktreePath.path(percentEncoded: false), "main")

        let report = await StrandedWorkSweep.read(
            projectRoot: root, doneItemIDs: [],
            statusByItemID: ["clean-item": .ready])

        XCTAssertEqual(report.stranded, [])
    }

    /// What the sweep already finds — a done item whose work never reached
    /// `HEAD` — is unchanged, and still found alongside the new pass.
    func testTheExistingDoneItemSweepStillRunsAlongsideADirtyWorktree() async throws {
        try branchWithWork("kiteloop/done-item")
        let path = try dirtyWorktree(itemID: "open-item")

        let report = await StrandedWorkSweep.read(
            projectRoot: root, doneItemIDs: ["done-item"],
            statusByItemID: ["done-item": .done, "open-item": .ready])

        XCTAssertEqual(report.stranded.map(\.itemID).sorted(), ["done-item", "open-item"])
        let dirty = try XCTUnwrap(report.stranded.first { $0.itemID == "open-item" })
        XCTAssertEqual(dirty.worktreePath, path)
        let done = try XCTUnwrap(report.stranded.first { $0.itemID == "done-item" })
        XCTAssertNil(done.worktreePath, "the branch finding names no directory on disk")
    }

    /// An item the backlog no longer names at all — the status map has
    /// nothing for it — is still a worktree nothing is coming back for.
    func testADirtyWorktreeForAnItemTheBacklogNoLongerNamesIsReported() async throws {
        try dirtyWorktree(itemID: "vanished-item")

        let report = await StrandedWorkSweep.read(projectRoot: root, doneItemIDs: [])

        XCTAssertEqual(report.stranded.map(\.itemID), ["vanished-item"])
    }

    /// Nothing here commits, deletes or moves what it finds — the worktree
    /// and its uncommitted file are still there, untouched, afterwards.
    func testTheDirtyWorktreeIsLeftExactlyAsFound() async throws {
        let path = try dirtyWorktree(itemID: "open-item")

        _ = await StrandedWorkSweep.read(
            projectRoot: root, doneItemIDs: [], statusByItemID: ["open-item": .ready])

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let status = git("-C", path, "status", "--porcelain")
        XCTAssertFalse(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "the uncommitted file must still be uncommitted")
    }

    /// A `git status` that could not be answered is not treated as either
    /// dirty or clean — the same "unanswered question is not a finding" rule
    /// the branch and dangling passes follow.
    func testAWorktreeWhoseStatusCannotBeReadIsNotReported() {
        let stranded = StrandedWorkSweep.dirtyOpenWorktrees(
            worktrees: [(itemID: "item-1", path: "/tmp/nowhere-in-particular")],
            statusByItemID: [:], inFlightItemID: nil
        ) { _, _ in (128, "") }

        XCTAssertEqual(stranded, [])
    }

    // MARK: - Helpers

    /// A worktree checked out under `.kiteloop/worktrees/<itemID>` — the same
    /// place `WorktreeManager` puts one — left with `fileCount` uncommitted
    /// files. Returns the worktree's path.
    @discardableResult
    private func dirtyWorktree(itemID: String, fileCount: Int = 1) throws -> String {
        let branch = WorktreeSession.branchName(for: itemID)
        let worktreePath = root.appending(path: ".kiteloop/worktrees/\(itemID)")
        git("worktree", "add", "-q", "-b", branch, worktreePath.path(percentEncoded: false), "main")
        for index in 0..<fileCount {
            try write(into: worktreePath, "Scratch\(index).swift", "let x = \(index)\n")
        }
        return worktreePath.path(percentEncoded: false)
    }

    private func write(into directory: URL, _ name: String, _ contents: String) throws {
        try contents.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
    }

    /// A branch off `main` carrying one commit, left unmerged. `from` continues
    /// an existing branch instead of starting a new one.
    private func branchWithWork(_ branch: String, file: String = "Feature.swift",
                                from: String? = nil) throws {
        if let from {
            git("checkout", "-q", from)
        } else {
            git("checkout", "-q", "main")
            git("checkout", "-q", "-b", branch)
        }
        try write(file, "let x = 1\n")
        git("add", "-A")
        git("commit", "-qm", "work on \(branch)")
        git("checkout", "-q", "main")
    }

    /// A branch that carried one commit and was then deleted, the way teardown
    /// deletes it — the commit stays in the object store with nothing pointing
    /// at it. `subject` defaults to the message teardown writes for the item.
    private func droppedBranchWithWork(itemID: String, subject: String? = nil) throws {
        let branch = WorktreeSession.branchName(for: itemID)
        git("checkout", "-q", "main")
        git("checkout", "-q", "-b", branch)
        try write("\(itemID).swift", "let x = 1\n")
        git("add", "-A")
        git("commit", "-qm", subject ?? RunWorkEvidence.teardownSubject(for: itemID))
        git("checkout", "-q", "main")
        git("branch", "-D", branch)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path(percentEncoded: false)] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
