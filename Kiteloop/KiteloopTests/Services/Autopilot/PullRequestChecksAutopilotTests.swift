import XCTest
import KiteloopCore
@testable import Kiteloop

/// The two cases of `PullRequestChecksTests` that reach the autopilot: the
/// gate notification's body carries the checks' detail, and each terminal
/// state has its own word in the log. The checks themselves
/// are package code, tested beside it.
///
/// Below them, what the autopilot does with a pull request once it has one:
/// following its checks, deciding whether a comment pass may run, and landing
/// what a comment pass did. `gh` is a scripted subprocess; git is real.
final class PullRequestChecksAutopilotTests: XCTestCase {

    func testTheGateNotificationBodyAppendsTheDetailAndSurvivesItsAbsence() {
        XCTAssertEqual(
            BacklogAutopilot.gateNotificationBody("pr-checks-loop — Follow the PR", detail: "PR green"),
            "pr-checks-loop — Follow the PR — PR green"
        )
        XCTAssertEqual(BacklogAutopilot.gateNotificationBody("pr-checks-loop — Follow the PR", detail: nil),
                       "pr-checks-loop — Follow the PR")
        XCTAssertEqual(BacklogAutopilot.gateNotificationBody("x", detail: ""), "x")
    }

    func testEveryTerminalStateHasItsOwnWordInTheLog() {
        XCTAssertEqual(BacklogAutopilot.checksOutcomeName(.green(checks: 1, rounds: 0, duration: 1)), "green")
        XCTAssertEqual(BacklogAutopilot.checksOutcomeName(.gaveUp(check: "b", rounds: 2, reason: "x")), "gave-up")
        XCTAssertEqual(BacklogAutopilot.checksOutcomeName(.timedOut(pending: 1, duration: 1)), "timed-out")
        XCTAssertEqual(BacklogAutopilot.checksOutcomeName(.unavailable(reason: "x")), "unavailable")
    }

    // MARK: - Following the checks

    private let pullRequest = "https://github.com/acme/widgets/pull/7"
    private let item = BacklogItem(id: "pr-item", title: "PR item", verify: "true", status: .awaitingApproval,
                                   type: .local, size: .s)

    /// `gh` found at a fixed path, answering `pr checks` with `checks` and
    /// `api graphql` with `graphql`.
    private func scriptedGH(checks: String = "[]", graphql: String = "{}") -> ScriptedSubprocessRunner {
        ScriptedSubprocessRunner { call in
            if call.executable == "/bin/zsh" { return .init(output: "/opt/test/bin/gh\n") }
            if call.arguments.first == "pr" { return .init(output: checks) }
            if call.arguments.first == "api" { return .init(output: graphql) }
            return .init(status: 1, output: "unscripted: \(call.arguments)")
        }
    }

    /// An autopilot for the project at `projectRoot`, or for no project at all;
    /// its own settings live in a scratch directory either way.
    @MainActor
    private func autopilot(projectRoot: URL?, metricStore: TaskMetricStore? = nil) throws -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        let settings = try makeTemporaryDirectory(prefix: "pr-follow-settings")
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(globalConfigStore: GlobalConfigStore(
                storageURL: settings.appendingPathComponent("global-config.json"))),
            configURL: settings.appendingPathComponent("autopilot-config.json"),
            metricStore: metricStore,
            projectPath: projectRoot?.path(percentEncoded: false))
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        return autopilot
    }

    /// A ledger holding one earlier run of `item` at `costUSD` — the prediction
    /// that, before the project has five landed runs, caps the item at that
    /// cost plus half again.
    @MainActor
    private func ledger(root: URL, costUSD: Double) throws -> TaskMetricStore {
        let dir = try makeTemporaryDirectory(prefix: "pr-follow-ledger")
        let store = TaskMetricStore(metricsURL: dir.appendingPathComponent("task-metrics.jsonl"),
                                    estimatesURL: dir.appendingPathComponent("task-estimates.jsonl"))
        let start = Date()
        store.append(TaskMetricRecord(
            projectPath: root.path(percentEncoded: false), projectName: "proj", itemID: item.id,
            title: item.title, epic: nil, declaredSize: nil, startedAt: start,
            completedAt: start.addingTimeInterval(300), durationSeconds: 300,
            costUSD: costUSD, reviewerRetries: 0, outcome: "done",
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "e-1"))
        return store
    }

    /// A pull request whose checks all passed settles at once, green, with no
    /// fix round spent — and `gh` was asked about that pull request, from the
    /// project it belongs to.
    @MainActor
    func testGreenChecksSettleTheFollowAtOnce() async throws {
        let root = try makeTemporaryDirectory(prefix: "pr-follow-green")
        let runner = scriptedGH(checks: #"[{"name":"build","bucket":"pass","state":"SUCCESS","link":""}]"#)
        let autopilot = try autopilot(projectRoot: root)

        let outcome = await withScriptedSubprocesses(runner) {
            await autopilot.followPullRequestChecksForTesting(item: item, branch: "kiteloop/pr-item",
                                                              url: pullRequest)
        }

        guard case .green(let checks, let rounds, _) = outcome else {
            return XCTFail("expected green, got \(outcome)")
        }
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(rounds, 0)
        let asked = try XCTUnwrap(runner.calls.first { $0.arguments.first == "pr" })
        XCTAssertEqual(asked.arguments.prefix(3), ["pr", "checks", pullRequest])
        XCTAssertEqual(asked.directory?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertTrue(autopilot.log.contains { $0.message == "Following pr-item's pull request checks — \(pullRequest)" })
    }

    /// No `gh` on the machine is a terminal answer, not a wait: the follow ends
    /// saying so rather than polling a tool that is not there.
    @MainActor
    func testAMachineWithoutGHEndsTheFollowAsUnavailable() async throws {
        let root = try makeTemporaryDirectory(prefix: "pr-follow-no-gh")
        let runner = ScriptedSubprocessRunner { _ in .init(status: 1) }
        let autopilot = try autopilot(projectRoot: root)

        let outcome = await withScriptedSubprocesses(runner) {
            await autopilot.followPullRequestChecksForTesting(item: item, branch: "kiteloop/pr-item",
                                                              url: pullRequest)
        }

        XCTAssertEqual(outcome, .unavailable(reason: "the GitHub CLI (gh) is not installed"))
    }

    /// A stopped run stops following before it asks GitHub anything — the queue
    /// is being torn down and nobody is left to spend a round for.
    @MainActor
    func testAStoppedRunStopsFollowingBeforeAskingGitHub() async throws {
        let root = try makeTemporaryDirectory(prefix: "pr-follow-stopped")
        let runner = scriptedGH()
        let autopilot = try autopilot(projectRoot: root)
        autopilot.stop()

        let outcome = await withScriptedSubprocesses(runner) {
            await autopilot.followPullRequestChecksForTesting(item: item, branch: "kiteloop/pr-item",
                                                              url: pullRequest)
        }

        XCTAssertEqual(outcome, .unavailable(reason: "the run was stopped before the checks settled"))
        XCTAssertTrue(runner.calls.isEmpty, "a stopped run must not poll: \(runner.calls)")
    }

    // MARK: - Whether a comment pass may run

    /// No project root, nothing to read the threads from.
    @MainActor
    func testACommentPassWithNoProjectIsSkipped() async throws {
        let runner = scriptedGH()
        let autopilot = try autopilot(projectRoot: nil)

        let outcome = await withScriptedSubprocesses(runner) {
            await autopilot.addressPullRequestCommentsForTesting(item: item, url: pullRequest, alreadySpentUSD: 0)
        }

        XCTAssertEqual(outcome, .skipped(reason: "the project has no root to read the pull request from"))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    @MainActor
    func testACommentPassAfterAStopIsSkippedUnread() async throws {
        let root = try makeTemporaryDirectory(prefix: "pr-comments-stopped")
        let runner = scriptedGH()
        let autopilot = try autopilot(projectRoot: root)
        autopilot.stop()

        let outcome = await withScriptedSubprocesses(runner) {
            await autopilot.addressPullRequestCommentsForTesting(item: item, url: pullRequest, alreadySpentUSD: 0)
        }

        XCTAssertEqual(outcome, .skipped(reason: "the run was stopped before the comments were read"))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    /// The cap is asked before the threads are: what the fix rounds already
    /// spent counts against it, and a pass that would breach it never starts.
    @MainActor
    func testACommentPassOverTheItemsCapIsSkippedUnread() async throws {
        let root = try makeTemporaryDirectory(prefix: "pr-comments-capped")
        let runner = scriptedGH()
        // An earlier run at $2.00 caps this item at $3.00.
        let autopilot = try autopilot(projectRoot: root, metricStore: ledger(root: root, costUSD: 2.0))

        let outcome = await withScriptedSubprocesses(runner) {
            await autopilot.addressPullRequestCommentsForTesting(item: item, url: pullRequest, alreadySpentUSD: 5)
        }

        XCTAssertEqual(outcome, .skipped(reason: "the item's cost cap is spent"))
        XCTAssertTrue(runner.calls.isEmpty, "a capped item must not read the threads: \(runner.calls)")
    }

    /// Under the cap the threads are read — and a pull request with none open
    /// is the ordinary ending, not a skip.
    @MainActor
    func testAnEligiblePassReadsTheThreadsAndFindsNothingOpen() async throws {
        let root = try makeTemporaryDirectory(prefix: "pr-comments-eligible")
        let empty = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#
        let runner = scriptedGH(graphql: empty)
        // An earlier run at $2.00 caps this item at $3.00.
        let autopilot = try autopilot(projectRoot: root, metricStore: ledger(root: root, costUSD: 2.0))

        let outcome = await withScriptedSubprocesses(runner) {
            await autopilot.addressPullRequestCommentsForTesting(item: item, url: pullRequest, alreadySpentUSD: 1)
        }

        XCTAssertEqual(outcome, .nothingToAddress)
        XCTAssertEqual(runner.calls.filter { $0.arguments.first == "api" }.count, 1)
    }

    // MARK: - Landing a comment pass

    /// A pass that changed nothing lands nothing: no commit, no push, and so no
    /// `fixed` claim is honoured.
    @MainActor
    func testAPassThatChangedNothingLandsNothing() async throws {
        let fixture = try await CommentPassFixture(test: self)
        let before = fixture.head()

        let landing = await fixture.autopilot.landCommentPassForTesting(
            item: fixture.item, branch: fixture.branch, worktree: fixture.worktree, before: before, backup: nil)

        XCTAssertFalse(landing.committed)
        XCTAssertNil(landing.failure)
        XCTAssertEqual(fixture.head(), before)
    }

    /// The work is committed even when the push cannot happen — the checkout is
    /// about to go — and the failure is reported rather than a thread resolved.
    @MainActor
    func testAPassWithNowhereToPushKeepsItsCommitAndSaysWhy() async throws {
        let fixture = try await CommentPassFixture(test: self)
        let before = fixture.head()
        try fixture.writeFix()

        let landing = await fixture.autopilot.landCommentPassForTesting(
            item: fixture.item, branch: fixture.branch, worktree: fixture.worktree, before: before, backup: nil)

        XCTAssertFalse(landing.committed)
        XCTAssertEqual(landing.failure, "the project has no git remote")
        XCTAssertNotEqual(fixture.head(), before, "the pass's work must be committed whatever the push did")
    }

    /// The ordinary landing: committed, pushed to the branch the pull request is
    /// built from, and said in the log.
    @MainActor
    func testAPassThatChangedSomethingIsCommittedAndPushed() async throws {
        let fixture = try await CommentPassFixture(test: self)
        let remote = fixture.addBareRemote()
        let before = fixture.head()
        try fixture.writeFix()

        let landing = await fixture.autopilot.landCommentPassForTesting(
            item: fixture.item, branch: fixture.branch, worktree: fixture.worktree, before: before, backup: nil)

        XCTAssertTrue(landing.committed)
        XCTAssertNil(landing.failure)
        XCTAssertEqual(fixture.git(["rev-parse", "refs/heads/\(fixture.branch)"], in: remote), fixture.head())
        XCTAssertTrue(fixture.autopilot.log.contains {
            $0.message == "\(fixture.item.id): pushed the comment pass's fixes to \(fixture.branch)"
        })
    }

    /// A pass that rewrote the branch's history is never pushed: that push would
    /// orphan the commits the pull request was built from. The refusal names
    /// where the old tip was kept.
    @MainActor
    func testAPassThatRewroteHistoryIsNotPushed() async throws {
        let fixture = try await CommentPassFixture(test: self)
        let remote = fixture.addBareRemote()
        try fixture.writeFix(named: "first.txt")
        fixture.git(["add", "-A"], in: fixture.worktree)
        fixture.git(["commit", "-m", "first"], in: fixture.worktree)
        let before = fixture.head()
        fixture.git(["reset", "--hard", "HEAD~1"], in: fixture.worktree)
        try fixture.writeFix(named: "second.txt")

        let landing = await fixture.autopilot.landCommentPassForTesting(
            item: fixture.item, branch: fixture.branch, worktree: fixture.worktree, before: before,
            backup: "refs/kiteloop/backup/x")

        XCTAssertFalse(landing.committed)
        let refusal = try XCTUnwrap(landing.failure)
        XCTAssertTrue(refusal.hasPrefix("the round rewrote \(fixture.branch)'s history — \(before.prefix(7))"), refusal)
        XCTAssertTrue(refusal.hasSuffix("(the previous tip is kept at refs/kiteloop/backup/x)"), refusal)
        XCTAssertEqual(fixture.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(fixture.branch)"], in: remote), "",
                       "nothing may be pushed over a rewritten history")
    }
}

/// A project with an item branch checked out in the worktree
/// `WorktreeManager` keeps for it — where a comment pass leaves its work.
@MainActor
private struct CommentPassFixture {
    let root: URL
    let worktree: URL
    /// Where `addBareRemote` puts the project's `origin`, when a test wants one.
    private let origin: URL
    let autopilot: BacklogAutopilot
    let item = BacklogItem(id: "comment-pass", title: "Comment pass", verify: "true",
                           status: .awaitingApproval, type: .local, size: .s)
    var branch: String { "kiteloop/\(item.id)" }

    init(test: XCTestCase) async throws {
        root = try test.makeTemporaryDirectory(prefix: "comment-pass-landing")
        origin = try test.makeTemporaryDirectory(prefix: "comment-pass-origin")
        try "init".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        for args in [["init"], ["config", "user.email", "test@test.com"], ["config", "user.name", "Test"],
                     ["add", "."], ["commit", "-m", "init"]] {
            Self.run(args, in: root)
        }
        worktree = try await WorktreeManager(projectRoot: root).create(for: item.id)
        autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(globalConfigStore: GlobalConfigStore(
                storageURL: root.appendingPathComponent("global-config.json"))),
            configURL: root.appendingPathComponent("autopilot-config.json"),
            projectPath: root.path(percentEncoded: false))
    }

    func writeFix(named name: String = "fix.txt") throws {
        try "addressed".write(to: worktree.appending(path: name), atomically: true, encoding: .utf8)
    }

    func head() -> String { git(["rev-parse", "HEAD"], in: worktree) }

    /// A bare repository registered as the project's `origin`.
    func addBareRemote() -> URL {
        Self.run(["init", "--bare"], in: origin)
        Self.run(["remote", "add", "origin", origin.path(percentEncoded: false)], in: root)
        return origin
    }

    @discardableResult
    func git(_ args: [String], in directory: URL) -> String {
        Self.run(args, in: directory)
    }

    @discardableResult
    private static func run(_ args: [String], in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
