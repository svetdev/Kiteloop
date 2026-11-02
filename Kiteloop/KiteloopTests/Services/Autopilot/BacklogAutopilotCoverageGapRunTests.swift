import XCTest
import KiteloopCore
@testable import Kiteloop

/// A finished run whose diff reaches a verify-map rule its `verify:` never
/// named: the coverage gate runs that rule's command in the run's worktree and
/// blocks only when it fails, rather than throwing the run away over a check
/// nobody ran.
@MainActor
final class BacklogAutopilotCoverageGapRunTests: XCTestCase {

    /// The project root, holding the backlog the item's notes are written into.
    private var projectRoot: URL!
    /// The run's kept worktree the gap commands run in.
    private var worktree: URL!
    /// Retained here: the autopilot holds its view model weakly, and a note
    /// written to a deallocated one is a silent no-op.
    private var backlog: BacklogViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectRoot = try makeTemporaryDirectory(prefix: "coverage-gap-root")
        worktree = try makeTemporaryDirectory(prefix: "coverage-gap-worktree")
    }

    override func tearDown() {
        projectRoot = nil
        worktree = nil
        backlog = nil
        super.tearDown()
    }

    private let item = BacklogItem(id: "sync-dedup-guard", title: "Guard sync dedup",
                                   verify: "echo item-verify", status: .active, type: .local)

    private func gapVerdict(command: String) -> VerifyCoverage.Verdict {
        VerifyCoverage.Verdict(
            gaps: [.init(glob: "Kiteloop/KiteloopTests/**", command: command,
                         paths: ["Kiteloop/KiteloopTests/FooTests.swift"])],
            covered: [])
    }

    /// An executable script in the worktree that prints `output` and exits with `status`.
    private func writeScript(_ name: String, output: String, status: Int32, sleeping: Int = 0) throws {
        let url = worktree.appending(path: name)
        let sleep = sleeping > 0 ? "sleep \(sleeping)\n" : ""
        try "#!/bin/sh\n\(sleep)echo '\(output)'\nexit \(status)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func notes() throws -> String {
        try String(contentsOf: projectRoot.appending(path: "backlog/sync-dedup-guard.md"), encoding: .utf8)
    }

    // MARK: - A passing command clears the gap

    func testAGapWhoseCommandPassesIsClearedAndNoted() async throws {
        try writeScript("check.sh", output: "all clean", status: 0)
        let autopilot = try configuredAutopilot()
        let map = VerifyCoverage.Map(rules: [.init(glob: "Kiteloop/KiteloopTests/**", command: "./check.sh")])

        let reason = await autopilot.runCoverageGapCommandsForTesting(
            verdict: gapVerdict(command: "./check.sh"), map: map, item: item, worktree: worktree)

        XCTAssertNil(reason, "a gap whose command passes must not block the run")
        let notes = try notes()
        XCTAssertTrue(notes.contains("`./check.sh`"), notes)
        XCTAssertTrue(notes.contains("passed"), notes)
    }

    // MARK: - A failing command still blocks, and says why

    func testAGapWhoseCommandFailsBlocksWithItsExitAndOutput() async throws {
        try writeScript("check.sh", output: "FooTests.swift:12 uses sleep", status: 2)
        let autopilot = try configuredAutopilot()
        let map = VerifyCoverage.Map(rules: [.init(glob: "Kiteloop/KiteloopTests/**", command: "./check.sh")])
        let verdict = gapVerdict(command: "./check.sh")

        let blocked = await autopilot.runCoverageGapCommandsForTesting(
            verdict: verdict, map: map, item: item, worktree: worktree)
        let reason = try XCTUnwrap(blocked)

        XCTAssertTrue(reason.hasPrefix(verdict.summary), reason)
        XCTAssertTrue(reason.contains("but verify never runs `./check.sh`"), reason)
        XCTAssertTrue(reason.contains("exit 2"), reason)
        XCTAssertTrue(reason.contains("FooTests.swift:12 uses sleep"), reason)
    }

    func testACommandKilledAtTheDeadlineSaysItTimedOut() async throws {
        try writeScript("slow.sh", output: "never printed", status: 0, sleeping: 30)
        let autopilot = try configuredAutopilot()
        let map = VerifyCoverage.Map(rules: [.init(glob: "Kiteloop/KiteloopTests/**", command: "./slow.sh")])

        let blocked = await autopilot.runCoverageGapCommandsForTesting(
            verdict: gapVerdict(command: "./slow.sh"), map: map, item: item, worktree: worktree,
            timeout: 0.5)
        let reason = try XCTUnwrap(blocked)

        XCTAssertTrue(reason.contains("timed out"), reason)
        XCTAssertFalse(reason.contains("exit "), "a killed command reached no exit status: \(reason)")
    }

    // MARK: - What runs, and where

    /// The rule's `run` spelling is what runs: its `command` is only the prefix
    /// a verify is matched against, and here it would fail on its own.
    func testARuleWithARunFieldRunsItsRunSpelling() async throws {
        try writeScript("check.sh", output: "needs its flag", status: 1)
        try writeScript("check-full.sh", output: "full check clean", status: 0)
        let autopilot = try configuredAutopilot()
        let map = VerifyCoverage.Map(rules: [.init(glob: "Kiteloop/KiteloopTests/**",
                                                   command: "./check.sh", run: "./check-full.sh")])

        let reason = await autopilot.runCoverageGapCommandsForTesting(
            verdict: gapVerdict(command: "./check.sh"), map: map, item: item, worktree: worktree)

        XCTAssertNil(reason, "the run spelling passes; only the bare command would have failed")
    }

    func testWithNoWorktreeTheGapBlocksAsTodayAndRunsNothing() async throws {
        let marker = worktree.appending(path: "ran")
        let autopilot = try configuredAutopilot()
        let command = "touch '\(marker.path(percentEncoded: false))'"
        let map = VerifyCoverage.Map(rules: [.init(glob: "Kiteloop/KiteloopTests/**", command: command)])
        let verdict = gapVerdict(command: command)

        let reason = await autopilot.runCoverageGapCommandsForTesting(
            verdict: verdict, map: map, item: item, worktree: nil)

        XCTAssertEqual(reason, verdict.summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)),
                       "with no worktree nothing may run")
    }

    /// The item's own verify verdict is what the run's metric record files;
    /// a gap command is not the item's verify and must not overwrite it.
    func testRunningGapCommandsLeavesTheItemsVerifyVerdictAlone() async throws {
        try writeScript("check.sh", output: "gap check", status: 3)
        let autopilot = try configuredAutopilot()
        _ = await autopilot.verifyAllowsReviewForTesting(worktree: nil)
        let before = try XCTUnwrap(autopilot.lastVerifyVerdictForTesting)
        let map = VerifyCoverage.Map(rules: [.init(glob: "Kiteloop/KiteloopTests/**", command: "./check.sh")])

        _ = await autopilot.runCoverageGapCommandsForTesting(
            verdict: gapVerdict(command: "./check.sh"), map: map, item: item, worktree: worktree)

        XCTAssertEqual(autopilot.lastVerifyVerdictForTesting, before)
    }

    // MARK: - When the gate asks at all

    /// No verify map is the default, and it must not gate anything — nor say
    /// anything about a map nobody wrote.
    func testAProjectWithNoVerifyMapIsNeverGated() async throws {
        let autopilot = try configuredAutopilot()

        let reason = await autopilot.verifyCoverageGapForTesting(
            item: item, branch: "kiteloop/sync-dedup-guard", isolated: true, worktree: worktree)

        XCTAssertNil(reason)
        XCTAssertFalse(autopilot.log.contains { $0.message.contains("verify map") })
    }

    /// A map that cannot be read is said out loud and treated as absent: a typo
    /// in config must not block a finished run.
    func testAnUnreadableVerifyMapIsLoggedAndTreatedAsAbsent() async throws {
        let autopilot = try configuredAutopilot()
        try writeVerifyMap("{ not json")

        let reason = await autopilot.verifyCoverageGapForTesting(
            item: item, branch: "kiteloop/sync-dedup-guard", isolated: true, worktree: worktree)

        XCTAssertNil(reason)
        XCTAssertTrue(autopilot.log.contains {
            $0.message == "verify map at kiteloop-verify.json could not be read — coverage not checked"
        }, "\(autopilot.log.map(\.message))")
    }

    /// A live-tree run, or one that left no branch, has no diff to compare.
    func testARunWithNoBranchToCompareIsNotGated() async throws {
        let autopilot = try configuredAutopilot()
        try writeVerifyMap(rules: [.init(glob: "Sources/**", command: "./check.sh")])

        let liveTree = await autopilot.verifyCoverageGapForTesting(
            item: item, branch: "kiteloop/sync-dedup-guard", isolated: false, worktree: worktree)
        let noBranch = await autopilot.verifyCoverageGapForTesting(
            item: item, branch: nil, isolated: true, worktree: worktree)

        XCTAssertNil(liveTree)
        XCTAssertNil(noBranch)
    }

    /// A diff git cannot be asked for still fails open — but a run that passed
    /// the gate having compared nothing says so rather than reading as covered.
    func testADiffGitCannotReadFailsOpenAndSaysSo() async throws {
        let autopilot = try configuredAutopilot()
        try writeVerifyMap(rules: [.init(glob: "Sources/**", command: "./check.sh")])

        let reason = await autopilot.verifyCoverageGapForTesting(
            item: item, branch: "kiteloop/sync-dedup-guard", isolated: true, worktree: worktree)

        XCTAssertNil(reason)
        XCTAssertTrue(autopilot.log.contains {
            $0.message == VerifyCoverage.unreadableDiff(branch: "kiteloop/sync-dedup-guard")
        }, "\(autopilot.log.map(\.message))")
    }

    // MARK: - Against a real branch

    /// The run's diff reaches a mapped glob the item's verify never names, and
    /// the rule's command fails in the run's worktree: the run is blocked, and
    /// the reason carries the command's exit.
    func testABranchReachingAnUncoveredRuleWhoseCommandFailsIsBlocked() async throws {
        let autopilot = try configuredAutopilot()
        let branch = try branchChanging("Sources/App.swift")
        try writeVerifyMap(rules: [.init(glob: "Sources/**", command: "./check.sh")])
        try writeScript("check.sh", output: "App.swift is not covered", status: 3)

        let blocked = await autopilot.verifyCoverageGapForTesting(
            item: item, branch: branch, isolated: true, worktree: worktree)
        let reason = try XCTUnwrap(blocked)

        XCTAssertTrue(reason.contains("but verify never runs `./check.sh`"), reason)
        XCTAssertTrue(reason.contains("exit 3"), reason)
    }

    /// The same diff, with an item whose own verify runs that command: covered,
    /// and nothing extra is run for it.
    func testABranchTheItemsVerifyCoversPassesWithoutRunningAnything() async throws {
        let covering = BacklogItem(id: "sync-dedup-guard", title: "Guard sync dedup",
                                   verify: "./check.sh", status: .active, type: .local)
        let autopilot = try configuredAutopilot()
        let branch = try branchChanging("Sources/App.swift")
        let marker = worktree.appending(path: "gap-command-ran")
        try writeVerifyMap(rules: [.init(glob: "Sources/**", command: "./check.sh",
                                         run: "touch '\(marker.path(percentEncoded: false))'")])

        let reason = await autopilot.verifyCoverageGapForTesting(
            item: covering, branch: branch, isolated: true, worktree: worktree)

        XCTAssertNil(reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)),
                       "a covered diff has no gap command to run")
    }

    // MARK: - After teardown removed the run's worktree

    /// A run that finished for approval or merge has had its worktree removed
    /// by teardown before the gate asks, so the gate is handed no tree. The
    /// branch is still the run's tree: it is checked out to run the missing
    /// check on, and a pass lets the run carry on with a note naming the check
    /// and the rule it ran for. The check exists only on the branch, so its
    /// pass proves it ran on the branch's tree.
    func testAGapAfterTeardownRunsTheCheckOnTheBranchAndPasses() async throws {
        let autopilot = try configuredAutopilot()
        let branch = try branchChanging("Sources/App.swift")
        try writeVerifyMap(rules: [.init(glob: "Sources/**", command: "./check.sh")])
        try commitScriptOnBranch("check.sh", output: "all clean", status: 0)
        try removeRunWorktree()

        let reason = await autopilot.verifyCoverageGapForTesting(
            item: item, branch: branch, isolated: true, worktree: nil)

        XCTAssertNil(reason, "a gap whose check passes on the branch must not block the run")
        let notes = try notes()
        XCTAssertTrue(notes.contains("ran `./check.sh` for `Sources/**`"), notes)
        XCTAssertTrue(notes.contains("passed (exit 0)"), notes)
        XCTAssertEqual(try scratchCheckouts(), [], "the scratch checkout must not outlive the check")
    }

    func testAGapAfterTeardownWhoseCheckFailsBlocksWithItsExitStatus() async throws {
        let autopilot = try configuredAutopilot()
        let branch = try branchChanging("Sources/App.swift")
        try writeVerifyMap(rules: [.init(glob: "Sources/**", command: "./check.sh")])
        try commitScriptOnBranch("check.sh", output: "App.swift uses sleep", status: 4)
        try removeRunWorktree()

        let blocked = await autopilot.verifyCoverageGapForTesting(
            item: item, branch: branch, isolated: true, worktree: nil)
        let reason = try XCTUnwrap(blocked)

        XCTAssertTrue(reason.contains("but verify never runs `./check.sh`"), reason)
        XCTAssertTrue(reason.contains("`./check.sh` failed (exit 4)"), reason)
        XCTAssertTrue(reason.contains("App.swift uses sleep"), reason)
        XCTAssertFalse(try notes().contains("passed (exit 0)"))
        XCTAssertEqual(try scratchCheckouts(), [], "the scratch checkout must not outlive the check")
    }

    /// A verify that already names the mapped check leaves nothing to run —
    /// no checkout, no note.
    func testAfterTeardownAVerifyNamingTheCheckChecksNothingOut() async throws {
        let covering = BacklogItem(id: "sync-dedup-guard", title: "Guard sync dedup",
                                   verify: "./check.sh", status: .active, type: .local)
        let autopilot = try configuredAutopilot()
        let branch = try branchChanging("Sources/App.swift")
        try writeVerifyMap(rules: [.init(glob: "Sources/**", command: "./check.sh")])
        try commitScriptOnBranch("check.sh", output: "all clean", status: 0)
        try removeRunWorktree()

        let reason = await autopilot.verifyCoverageGapForTesting(
            item: covering, branch: branch, isolated: true, worktree: nil)

        XCTAssertNil(reason)
        XCTAssertFalse(autopilot.log.contains { $0.message.contains("Coverage gap") },
                       "\(autopilot.log.map(\.message))")
        XCTAssertFalse(try notes().contains("ran `./check.sh`"))
    }

    /// Commits an executable script to the branch checked out in `worktree`.
    private func commitScriptOnBranch(_ name: String, output: String, status: Int32) throws {
        try writeScript(name, output: output, status: status)
        try runGit(["add", "."], in: worktree)
        try runGit(["commit", "-m", "add \(name)"], in: worktree)
    }

    /// What teardown does to a run that finished for approval or merge: the
    /// worktree goes, the branch stays.
    private func removeRunWorktree() throws {
        try runGit(["worktree", "remove", "--force", worktree.path(percentEncoded: false)], in: projectRoot)
    }

    /// The scratch checkouts left under the project, by name.
    private func scratchCheckouts() throws -> [String] {
        let scratch = projectRoot.appending(path: ".kiteloop/merge-gate-scratch")
        guard FileManager.default.fileExists(atPath: scratch.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: scratch.path(percentEncoded: false))
    }

    private func writeVerifyMap(rules: [VerifyCoverage.Rule]) throws {
        let data = try JSONEncoder().encode(VerifyCoverage.Map(rules: rules))
        try writeVerifyMap(String(decoding: data, as: UTF8.self))
    }

    private func writeVerifyMap(_ contents: String) throws {
        let url = KiteloopProject(rootURL: projectRoot).verifyMapURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Makes the project a git repository and gives the item a branch, checked
    /// out in `worktree`, whose one commit adds `path`.
    private func branchChanging(_ path: String) throws -> String {
        let branch = "kiteloop/sync-dedup-guard"
        for args in [["init"], ["config", "user.email", "test@test.com"], ["config", "user.name", "Test"],
                     ["add", "."], ["commit", "-m", "init"],
                     ["worktree", "add", "-b", branch, worktree.path(percentEncoded: false), "HEAD"]] {
            try runGit(args, in: projectRoot)
        }
        let file = worktree.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "struct App {}\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: worktree)
        try runGit(["commit", "-m", "add \(path)"], in: worktree)
        return branch
    }

    private func runGit(_ args: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }

    // MARK: - Fixture

    private func configuredAutopilot() throws -> BacklogAutopilot {
        let root = try XCTUnwrap(projectRoot)
        try writeBacklogFiles(in: root)
        let backlog = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: root.appendingPathComponent("global-config.json")))
        backlog.loadForProject(repoPath: root.path(percentEncoded: false))
        self.backlog = backlog
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: backlog,
            configURL: root.appendingPathComponent("autopilot-config.json"),
            metricStore: nil,
            projectPath: root.path(percentEncoded: false)
        )
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item])
        autopilot.stageQueueIndexForTesting(0)
        return autopilot
    }

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
}
