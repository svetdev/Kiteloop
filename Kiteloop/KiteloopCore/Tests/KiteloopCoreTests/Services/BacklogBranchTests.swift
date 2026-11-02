import XCTest
@testable import KiteloopCore

/// The shared backlog branch's git choreography — adopting a checkout, committing
/// what changed, syncing with origin — driven with every git call scripted through
/// the subprocess seam, so each case asserts which commands run, in which
/// directory, and what a refusal does, without a repository or a network.
final class BacklogBranchTests: XCTestCase {
    private var projectRoot: URL!

    override func setUpWithError() throws {
        projectRoot = try makeTemporaryDirectory(prefix: "backlog-branch")
    }

    private func subcommands(_ runner: ScriptedSubprocessRunner) -> [String] {
        runner.calls.map { $0.arguments.first ?? "" }
    }

    // MARK: - adopt

    func testAnExistingCheckoutIsAdoptedWithoutTouchingGit() async throws {
        let file = BacklogBranch.backlogFileURL(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Backlog\n".write(to: file, atomically: true, encoding: .utf8)
        let runner = ScriptedSubprocessRunner()
        let adopted = await withScriptedSubprocesses(runner) { BacklogBranch.adopt(projectRoot: projectRoot) }
        XCTAssertEqual(adopted, file)
        XCTAssertEqual(runner.calls.count, 0)
    }

    func testAMissingBranchWithNoRemoteToTrackIsNotAdopted() async {
        let runner = ScriptedSubprocessRunner { call in
            switch call.arguments.first {
            case "show-ref": return .init(status: 1)
            case "branch": return .init(status: 128, output: "fatal: not a valid object name: 'origin/kiteloop/backlog'")
            default: return .init()
            }
        }
        let adopted = await withScriptedSubprocesses(runner) { BacklogBranch.adopt(projectRoot: projectRoot) }
        XCTAssertNil(adopted)
        XCTAssertEqual(subcommands(runner), ["worktree", "show-ref", "branch"], "nothing is checked out after the refusal")
        XCTAssertEqual(runner.calls.map(\.directory), Array(repeating: projectRoot, count: 3))
    }

    func testABranchIsCheckedOutIntoTheWorktreeAndTheFileMustThenExist() async throws {
        let file = BacklogBranch.backlogFileURL(projectRoot: projectRoot)
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.first == "worktree", call.arguments.dropFirst().first == "add" {
                // git would create the checkout; the script stands in for it
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "# Backlog\n".write(to: file, atomically: true, encoding: .utf8)
            }
            return .init()
        }
        let adopted = await withScriptedSubprocesses(runner) { BacklogBranch.adopt(projectRoot: projectRoot) }
        XCTAssertEqual(adopted, file)
        XCTAssertEqual(subcommands(runner), ["worktree", "show-ref", "worktree"])
        let add = runner.calls[2].arguments
        XCTAssertEqual(add.prefix(2), ["worktree", "add"])
        XCTAssertEqual(add.last, BacklogBranch.branchName)
        XCTAssertEqual(add.dropLast().last, BacklogBranch.checkoutURL(projectRoot: projectRoot).path(percentEncoded: false))
    }

    func testAWorktreeAddThatFailsIsNotAdopted() async {
        let runner = ScriptedSubprocessRunner { call in
            call.arguments.first == "worktree" && call.arguments.count > 1 ? .init(status: 128, output: "fatal: already exists") : .init()
        }
        let adopted = await withScriptedSubprocesses(runner) { BacklogBranch.adopt(projectRoot: projectRoot) }
        XCTAssertNil(adopted)
    }

    func testAWorktreeAddThatLeavesNoFileIsNotAdopted() async {
        let runner = ScriptedSubprocessRunner()
        let adopted = await withScriptedSubprocesses(runner) { BacklogBranch.adopt(projectRoot: projectRoot) }
        XCTAssertNil(adopted, "a checkout without BACKLOG.md is no backlog")
    }

    // MARK: - commitChanges

    func testACleanCheckoutCommitsNothing() async {
        let runner = ScriptedSubprocessRunner { _ in .init(status: 0, output: "\n") }
        await withScriptedSubprocesses(runner) { BacklogBranch.commitChanges(projectRoot: projectRoot, message: "m") }
        XCTAssertEqual(subcommands(runner), ["status"])
        XCTAssertEqual(runner.calls.first?.directory, BacklogBranch.checkoutURL(projectRoot: projectRoot))
    }

    func testADirtyCheckoutIsAddedCommittedAndPushed() async {
        let runner = ScriptedSubprocessRunner { call in
            call.arguments.first == "status" ? .init(output: " M BACKLOG.md\n") : .init()
        }
        await withScriptedSubprocesses(runner) { BacklogBranch.commitChanges(projectRoot: projectRoot, message: "groomed") }
        XCTAssertEqual(subcommands(runner), ["status", "add", "commit", "push"], "the first commit for a project pushes at once")
        XCTAssertEqual(runner.calls[2].arguments, ["commit", "-m", "groomed"])
        XCTAssertEqual(runner.calls[3].arguments, ["push", "origin", BacklogBranch.branchName])
        for call in runner.calls {
            XCTAssertEqual(call.environment?["GIT_TERMINAL_PROMPT"], "0", "no git call may wait on a terminal")
        }
    }

    func testASecondCommitWithinThePushIntervalDoesNotPush() async {
        let runner = ScriptedSubprocessRunner { call in
            call.arguments.first == "status" ? .init(output: " M BACKLOG.md\n") : .init()
        }
        await withScriptedSubprocesses(runner) {
            BacklogBranch.commitChanges(projectRoot: projectRoot, message: "one")
            BacklogBranch.commitChanges(projectRoot: projectRoot, message: "two")
        }
        XCTAssertEqual(subcommands(runner), ["status", "add", "commit", "push", "status", "add", "commit"])
    }

    func testACommitThatFailsDoesNotPush() async {
        let runner = ScriptedSubprocessRunner { call in
            switch call.arguments.first {
            case "status": return .init(output: " M BACKLOG.md\n")
            case "commit": return .init(status: 1, output: "nothing to commit")
            default: return .init()
            }
        }
        await withScriptedSubprocesses(runner) { BacklogBranch.commitChanges(projectRoot: projectRoot, message: "m") }
        XCTAssertEqual(subcommands(runner), ["status", "add", "commit"])
    }

    // MARK: - sync

    func testSyncWithoutACheckoutDoesNothing() async {
        let runner = ScriptedSubprocessRunner()
        await withScriptedSubprocesses(runner) { BacklogBranch.sync(projectRoot: projectRoot) }
        XCTAssertEqual(runner.calls.count, 0)
    }

    func testSyncFetchesFastForwardsAndPushesWhatIsAhead() async throws {
        try FileManager.default.createDirectory(at: BacklogBranch.checkoutURL(projectRoot: projectRoot), withIntermediateDirectories: true)
        let runner = ScriptedSubprocessRunner { call in
            call.arguments.first == "rev-list" ? .init(output: "2\n") : .init()
        }
        await withScriptedSubprocesses(runner) { BacklogBranch.sync(projectRoot: projectRoot) }
        XCTAssertEqual(subcommands(runner), ["fetch", "merge", "rev-list", "push"])
        XCTAssertEqual(runner.calls[1].arguments, ["merge", "--ff-only", "origin/\(BacklogBranch.branchName)"])
        XCTAssertEqual(runner.calls[2].arguments, ["rev-list", "--count", "origin/\(BacklogBranch.branchName)..HEAD"])
        for call in runner.calls {
            XCTAssertEqual(call.directory, BacklogBranch.checkoutURL(projectRoot: projectRoot), "sync works in the checkout, not the project")
        }
    }

    func testSyncWithNothingAheadDoesNotPush() async throws {
        try FileManager.default.createDirectory(at: BacklogBranch.checkoutURL(projectRoot: projectRoot), withIntermediateDirectories: true)
        let runner = ScriptedSubprocessRunner { call in
            call.arguments.first == "rev-list" ? .init(output: "0\n") : .init()
        }
        await withScriptedSubprocesses(runner) { BacklogBranch.sync(projectRoot: projectRoot) }
        XCTAssertEqual(subcommands(runner), ["fetch", "merge", "rev-list"])
    }

    func testADivergedBranchIsReportedAndTheLocalCopyKept() async throws {
        try FileManager.default.createDirectory(at: BacklogBranch.checkoutURL(projectRoot: projectRoot), withIntermediateDirectories: true)
        let runner = ScriptedSubprocessRunner { call in
            switch call.arguments.first {
            case "merge": return .init(status: 128, output: "fatal: Not possible to fast-forward, aborting.")
            case "rev-list": return .init(output: call.arguments.last == "HEAD..origin/\(BacklogBranch.branchName)" ? "3\n" : "0\n")
            default: return .init()
            }
        }
        await withScriptedSubprocesses(runner) { BacklogBranch.sync(projectRoot: projectRoot) }
        XCTAssertEqual(subcommands(runner), ["fetch", "merge", "rev-list", "rev-list"], "the divergence is measured, nothing is forced")
    }

    func testNetworkCommandsGetTheLongerDeadline() async throws {
        try FileManager.default.createDirectory(at: BacklogBranch.checkoutURL(projectRoot: projectRoot), withIntermediateDirectories: true)
        let runner = ScriptedSubprocessRunner { call in
            call.arguments.first == "rev-list" ? .init(output: "1\n") : .init()
        }
        await withScriptedSubprocesses(runner) { BacklogBranch.sync(projectRoot: projectRoot) }
        let byCommand = Dictionary(runner.calls.map { ($0.arguments.first ?? "", $0.timeout ?? 0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertGreaterThan(byCommand["fetch"] ?? 0, byCommand["merge"] ?? 0, "fetch and push may wait on the network; merge may not")
        XCTAssertEqual(byCommand["push"], byCommand["fetch"])
    }

    // MARK: - availability

    func testACheckoutWithABacklogIsCheckedOutWithoutAskingGit() async throws {
        let spacedRoot = try makeTemporaryDirectory(prefix: "backlog branch")
        let file = BacklogBranch.backlogFileURL(projectRoot: spacedRoot)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Backlog\n".write(to: file, atomically: true, encoding: .utf8)
        let runner = ScriptedSubprocessRunner()
        let availability = await withScriptedSubprocesses(runner) { BacklogBranch.availability(projectRoot: spacedRoot) }
        XCTAssertEqual(availability, .checkedOut)
        XCTAssertEqual(runner.calls.count, 0, "the file on disk answers; git is not consulted — even with a space in the path")
    }

    func testALocalBranchWithoutACheckoutIsAdoptable() async {
        let runner = ScriptedSubprocessRunner { call in
            .init(status: call.arguments.last?.hasPrefix("refs/heads/") == true ? 0 : 1)
        }
        let availability = await withScriptedSubprocesses(runner) { BacklogBranch.availability(projectRoot: projectRoot) }
        XCTAssertEqual(availability, .adoptable)
    }

    func testARemoteOnlyBranchIsAdoptable() async {
        let runner = ScriptedSubprocessRunner { call in
            .init(status: call.arguments.last?.hasPrefix("refs/remotes/origin/") == true ? 0 : 1)
        }
        let availability = await withScriptedSubprocesses(runner) { BacklogBranch.availability(projectRoot: projectRoot) }
        XCTAssertEqual(availability, .adoptable, "a remote-tracking ref is enough — the answer must work offline")
    }

    func testNoBranchAnywhereIsAbsent() async {
        let runner = ScriptedSubprocessRunner { _ in .init(status: 1) }
        let availability = await withScriptedSubprocesses(runner) { BacklogBranch.availability(projectRoot: projectRoot) }
        XCTAssertEqual(availability, .absent)
    }

    // MARK: - Paths with a space in them

    /// `~/Documents/My Project` is an ordinary place for a repo: every path
    /// handed to the filesystem or to git must be the literal path, never a
    /// percent-encoded one.
    func testAProjectPathWithASpaceAdoptsIntoTheLiteralCheckoutPath() async throws {
        let spacedRoot = try makeTemporaryDirectory(prefix: "backlog branch")
        let file = BacklogBranch.backlogFileURL(projectRoot: spacedRoot)
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.first == "worktree", call.arguments.dropFirst().first == "add" {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "# Backlog\n".write(to: file, atomically: true, encoding: .utf8)
            }
            return .init()
        }
        let adopted = await withScriptedSubprocesses(runner) { BacklogBranch.adopt(projectRoot: spacedRoot) }
        XCTAssertEqual(adopted, file)
        let add = runner.calls[2].arguments
        XCTAssertEqual(add.dropLast().last, BacklogBranch.checkoutURL(projectRoot: spacedRoot).path(percentEncoded: false),
                       "git gets the literal path, spaces and all")
    }

    /// The push rate limit is one budget shared by `sync` and `commitChanges`:
    /// a sync that just pushed means the commit right after it does not.
    func testASyncedPushCountsTowardTheCommitRateLimit() async throws {
        let spacedRoot = try makeTemporaryDirectory(prefix: "backlog branch")
        try FileManager.default.createDirectory(at: BacklogBranch.checkoutURL(projectRoot: spacedRoot), withIntermediateDirectories: true)
        let runner = ScriptedSubprocessRunner { call in
            switch call.arguments.first {
            case "rev-list": return .init(output: "1\n")
            case "status": return .init(output: " M BACKLOG.md\n")
            default: return .init()
            }
        }
        await withScriptedSubprocesses(runner) {
            BacklogBranch.sync(projectRoot: spacedRoot)
            BacklogBranch.commitChanges(projectRoot: spacedRoot, message: "m")
        }
        XCTAssertEqual(subcommands(runner), ["fetch", "merge", "rev-list", "push", "status", "add", "commit"],
                       "the sync just pushed, so the commit that follows must not push again")
    }

    // MARK: - createShared

    func testCreateSharedMakesTheOrphanBranchWritesTheStarterAndPushes() async throws {
        let spacedRoot = try makeTemporaryDirectory(prefix: "backlog branch")
        let checkout = BacklogBranch.checkoutURL(projectRoot: spacedRoot)
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.first == "worktree" {
                try? FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            }
            return .init()
        }
        let created = await withScriptedSubprocesses(runner) {
            BacklogBranch.createShared(projectRoot: spacedRoot, projectName: "MyProj")
        }
        XCTAssertEqual(created, BacklogBranch.backlogFileURL(projectRoot: spacedRoot))
        XCTAssertEqual(subcommands(runner), ["worktree", "add", "commit", "push"])
        XCTAssertEqual(runner.calls.first?.arguments,
                       ["worktree", "add", "--orphan", "-b", BacklogBranch.branchName, checkout.path(percentEncoded: false)])
        let starter = try String(contentsOf: BacklogBranch.backlogFileURL(projectRoot: spacedRoot), encoding: .utf8)
        XCTAssertTrue(starter.hasPrefix("# MyProj Backlog"), starter)
    }

    func testAFailedOrphanWorktreeCreatesNothing() async {
        let runner = ScriptedSubprocessRunner { call in
            call.arguments.first == "worktree" ? .init(status: 128, output: "fatal: exists") : .init()
        }
        let created = await withScriptedSubprocesses(runner) {
            BacklogBranch.createShared(projectRoot: projectRoot, projectName: "P")
        }
        XCTAssertNil(created)
        XCTAssertEqual(subcommands(runner), ["worktree"], "nothing is committed or pushed after the refusal")
    }
}
