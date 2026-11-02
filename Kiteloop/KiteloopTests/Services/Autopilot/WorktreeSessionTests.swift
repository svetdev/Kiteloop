import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers the two pure decisions `WorktreeSession` makes around a run: whether
/// to isolate the item at all (ADR-0001's live-tree fallback) and what becomes
/// of the worktree once the item finishes. Both are static so the rules can be
/// checked without a git repo, an orchestrator or live agents.
final class WorktreeSessionTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/kiteloop-worktree-session-tests")

    // MARK: - Isolation decision

    /// A project that isn't a git repository must run in the live tree instead
    /// of failing the item.
    func testNonGitProjectFallsBackToLiveTree() {
        let decision = WorktreeSession.decide(
            projectRoot: root,
            isGitRepository: { _ in false }
        )
        XCTAssertEqual(
            decision,
            .liveTree(reason: "Worktree isolation skipped — not a git repository")
        )
    }

    func testGitProjectIsolates() {
        let decision = WorktreeSession.decide(
            projectRoot: root,
            isGitRepository: { _ in true }
        )
        XCTAssertEqual(decision, .isolate)
    }

    func testMissingProjectRootFallsBackToLiveTree() {
        let decision = WorktreeSession.decide(
            projectRoot: nil,
            isGitRepository: { _ in true }
        )
        XCTAssertEqual(decision, .liveTree(reason: "Worktree isolation skipped — no project root"))
    }

    /// The default `isGitRepository` is the real check, so a plain directory on
    /// disk resolves to the live tree without any injection.
    func testDefaultCheckResolvesPlainDirectoryToLiveTree() throws {
        let plain = try makeTemporaryDirectory(prefix: "plain")

        let decision = WorktreeSession.decide(projectRoot: plain)
        XCTAssertEqual(
            decision,
            .liveTree(reason: "Worktree isolation skipped — not a git repository")
        )
    }

    // MARK: - Isolation is not optional once it is asked for

    /// Isolation that was asked for and could not be had **fails the item**. It
    /// used to fall back to the live tree, which reads as the forgiving choice
    /// and is the opposite: a git project always isolates, which says where work may
    /// land, and a run that cannot honour it has nothing to offer but writing
    /// into the checkout the caller asked to be left alone.
    @MainActor
    func testSetupThatCannotIsolateFailsRatherThanUsingTheLiveTree() async throws {
        let repo = try makeRepository()
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))
        // A file where the worktree directory has to go: `git worktree add`
        // cannot make a checkout there, so setup throws.
        let worktrees = repo.appending(path: ".kiteloop/worktrees")
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        try "in the way".write(to: worktrees.appending(path: "blocked-item"),
                               atomically: true, encoding: .utf8)

        var logged: [String] = []
        let setup = await WorktreeSession.begin(
            itemID: "blocked-item", projectRoot: repo, agentIDs: ["worker"],
            orchestrator: orchestrator, log: { logged.append($0) })

        guard case .failed = setup else {
            return XCTFail("expected a failed setup, got \(setup)")
        }
        XCTAssertTrue(logged.contains { $0.contains("Worktree setup failed") })
        // And the agent is left free rather than pinned to a worktree that was
        // rolled back — the next item has to be able to take it.
        XCTAssertNil(orchestrator.pinnedWorkingDirectory(for: "worker"))
    }

    /// The rerun of a rejected item whose branch a person has checked out to
    /// review: the leftover checkout is reclaimed rather than refusing the
    /// start, and the log names it — no run of this project made it, and it
    /// was keeping the branch from being reused.
    @MainActor
    func testAnItemBranchCheckedOutElsewhereIsReclaimedNamingTheCheckout() async throws {
        let repo = try makeRepository()
        let first = try await beginSession(itemID: "reviewed-item", in: repo)
        try "work".write(to: first.path.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        await first.end(outcome: .awaitingApproval)
        let review = try makeTemporaryDirectory(prefix: "review-checkout")
        try FileManager.default.removeItem(at: review)
        _ = git(["worktree", "add", review.path(percentEncoded: false), "kiteloop/reviewed-item"], in: repo)
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))

        var logged: [String] = []
        let setup = await WorktreeSession.begin(
            itemID: "reviewed-item", projectRoot: repo, agentIDs: ["worker"],
            orchestrator: orchestrator, log: { logged.append($0) })

        guard case .isolated(let session) = setup else {
            return XCTFail("expected the start to reclaim the checkout, got \(setup)")
        }
        let reclaimed = logged.first { $0.contains("Removed a leftover worktree") }
        XCTAssertTrue(reclaimed?.contains("kiteloop/reviewed-item") == true, "\(logged)")
        XCTAssertTrue(reclaimed?.contains(review.lastPathComponent) == true, "the checkout's path is missing: \(logged)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: review.path(percentEncoded: false)))
        await session.end(outcome: .cancelled)
    }

    /// An agent another item's session still holds is not this run's to take.
    /// Restarting it would move a live run's worker out from under it and put
    /// two items' edits in one tree.
    @MainActor
    func testBeginRefusesAnAgentAnotherRunStillHolds() async throws {
        let repo = try makeRepository()
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))

        let first = await WorktreeSession.begin(
            itemID: "item-one", projectRoot: repo, agentIDs: ["worker"],
            orchestrator: orchestrator, log: { _ in })
        guard case .isolated(let one) = first else {
            return XCTFail("expected the first item to isolate, got \(first)")
        }
        XCTAssertEqual(orchestrator.pinnedWorkingDirectory(for: "worker"), one.path)

        let second = await WorktreeSession.begin(
            itemID: "item-two", projectRoot: repo, agentIDs: ["worker"],
            orchestrator: orchestrator, log: { _ in })
        guard case .failed(let reason) = second else {
            return XCTFail("expected the second item to be refused, got \(second)")
        }
        XCTAssertTrue(reason.contains("still pinned"), reason)
        // The live run keeps its worker exactly where it was.
        XCTAssertEqual(orchestrator.pinnedWorkingDirectory(for: "worker"), one.path)

        await one.end(outcome: .cancelled)
    }

    // MARK: - The project's base branch

    /// A base naming no local branch refuses the start, with the branch in the
    /// reason — the item is blocked rather than forked from `HEAD` and called
    /// that branch. Nothing of the item's is torn down for a run that never
    /// starts, and the agent is left free for the next item.
    @MainActor
    func testABaseNamingNoBranchFailsTheSetupNamingIt() async throws {
        let repo = try makeRepository()
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))
        var logged: [String] = []

        let setup = await WorktreeSession.begin(
            baseBranch: "quality/rebased", itemID: "based-item", projectRoot: repo,
            agentIDs: ["worker"], orchestrator: orchestrator, log: { logged.append($0) })

        guard case .failed(let reason) = setup else {
            return XCTFail("expected a failed setup, got \(setup)")
        }
        XCTAssertEqual(reason, "base branch quality/rebased does not exist in this repository")
        XCTAssertTrue(logged.contains { $0.contains("Worktree setup failed (base branch quality/rebased") }, "\(logged)")
        XCTAssertNil(orchestrator.pinnedWorkingDirectory(for: "worker"))
        XCTAssertEqual(git(["rev-parse", "--verify", "--quiet", "refs/heads/kiteloop/based-item"], in: repo), "",
                       "no item branch is made for a run that was refused")
    }

    /// With a base that exists, the worktree forks from it — here a branch one
    /// commit behind the checkout — rather than from the checkout's `HEAD`.
    @MainActor
    func testABaseThatExistsIsWhereTheWorktreeForksFrom() async throws {
        let repo = try makeRepository()
        git(["branch", "feature"], in: repo)
        try "more".write(to: repo.appending(path: "more.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repo)
        git(["commit", "-m", "advance the checkout"], in: repo)
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))

        let setup = await WorktreeSession.begin(
            baseBranch: "feature", itemID: "forked-item", projectRoot: repo,
            agentIDs: ["worker"], orchestrator: orchestrator, log: { _ in })

        guard case .isolated(let session) = setup else {
            return XCTFail("expected an isolated setup, got \(setup)")
        }
        XCTAssertEqual(git(["rev-parse", "HEAD"], in: session.path), git(["rev-parse", "feature"], in: repo))
        XCTAssertNotEqual(git(["rev-parse", "HEAD"], in: session.path), git(["rev-parse", "HEAD"], in: repo))
        await session.end(outcome: .cancelled)
    }

    // MARK: - The project's worktreeSetupCommand

    /// Nothing configured (blank counts as nothing) runs no command at all —
    /// the worktree is exactly what `git worktree add` produced, and setup
    /// neither succeeds nor fails on its own.
    @MainActor
    func testNoWorktreeSetupCommandIsANoOp() async throws {
        let repo = try makeRepository()
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))

        let setup = await WorktreeSession.begin(
            itemID: "no-setup-item", projectRoot: repo, agentIDs: ["worker"],
            orchestrator: orchestrator, setupCommand: "   ", log: { _ in })

        guard case .isolated(let session) = setup else {
            return XCTFail("expected an isolated setup, got \(setup)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path.path(percentEncoded: false)))
        await session.end(outcome: .cancelled)
    }

    /// A runtime that records whether a marker file existed the moment an
    /// agent was (re)started — the only way to see, from outside `begin`,
    /// that setup finished before any agent was ever pointed at the fresh
    /// worktree.
    private final class SetupOrderRecordingRuntime: AgentRuntime, @unchecked Sendable {
        private(set) var markerExistedAtStart = false
        let markerPath: String
        init(markerPath: String) { self.markerPath = markerPath }
        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
            markerExistedAtStart = FileManager.default.fileExists(atPath: markerPath)
            return AgentSession(id: "recording-session", agentID: agent.id, startedAt: .now)
        }
        func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
        func interrupt(session: AgentSession) {}
        func stop(session: AgentSession) {}
    }

    /// The order that matters for a real install command: it has to be done
    /// before an agent is ever restarted into the fresh worktree, or the
    /// agent could start working against a tree the project itself hasn't
    /// finished preparing (`npm ci` not yet run, a generated file not yet
    /// there).
    @MainActor
    func testWorktreeSetupCommandRunsInTheWorkersWorktreeBeforeTheAgentIsPinned() async throws {
        let repo = try makeRepository()
        let markerPath = WorktreeSession.worktreeDirectory(for: "pin-order-item", projectRoot: repo)
            .appending(path: "setup-ran").path(percentEncoded: false)
        let runtime = SetupOrderRecordingRuntime(markerPath: markerPath)
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))

        let setup = await WorktreeSession.begin(
            itemID: "pin-order-item", projectRoot: repo, agentIDs: ["worker"],
            orchestrator: orchestrator, setupCommand: "touch \(markerPath)", log: { _ in })

        guard case .isolated(let session) = setup else {
            return XCTFail("expected an isolated setup, got \(setup)")
        }
        XCTAssertTrue(runtime.markerExistedAtStart,
                      "setup must finish before the agent is restarted into the worktree")
        await session.end(outcome: .cancelled)
    }

    /// A setup command that fails refuses the item outright, naming the
    /// command in the reason the same way every other refusal in `begin`
    /// does — and leaves nothing behind for the next attempt to trip over.
    @MainActor
    func testAFailingWorktreeSetupCommandFailsTheItemNamingTheCommand() async throws {
        let repo = try makeRepository()
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))
        var logged: [String] = []

        let setup = await WorktreeSession.begin(
            itemID: "failing-setup-item", projectRoot: repo, agentIDs: ["worker"],
            orchestrator: orchestrator, setupCommand: "exit 1", log: { logged.append($0) })

        guard case .failed(let reason) = setup else {
            return XCTFail("expected a failed setup, got \(setup)")
        }
        XCTAssertEqual(reason, "exit 1 failed")
        XCTAssertTrue(logged.contains { $0.contains("Worktree setup failed (exit 1 failed)") }, "\(logged)")
        XCTAssertNil(orchestrator.pinnedWorkingDirectory(for: "worker"))
        XCTAssertEqual(
            git(["rev-parse", "--verify", "--quiet", "refs/heads/kiteloop/failing-setup-item"], in: repo), "",
            "no item branch survives a worktree the setup command never made usable")
    }

    /// A setup command still running past its deadline is killed and refused
    /// as a timeout, the same shape a merge-verify overrun gets — never
    /// retried, since a killed command answered nothing about whether it
    /// would ever have passed. The timeout is injected short so the test
    /// proves the deadline, not the default 900s, is what ends it.
    @MainActor
    func testAWorktreeSetupCommandThatOverrunsItsDeadlineIsRefusedAsTimedOutNotRetried() async throws {
        let repo = try makeRepository()
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))

        let start = Date()
        let setup = await WorktreeSession.begin(
            itemID: "timeout-setup-item", projectRoot: repo, agentIDs: ["worker"],
            orchestrator: orchestrator, setupCommand: "sleep 30", setupTimeout: 1, log: { _ in })
        let elapsed = Date().timeIntervalSince(start)

        guard case .failed(let reason) = setup else {
            return XCTFail("expected a failed setup, got \(setup)")
        }
        XCTAssertEqual(reason, "sleep 30 timed out after 1s")
        XCTAssertLessThan(elapsed, 10, "the 1s deadline, not the 30s sleep, must be what ends setup")
        XCTAssertNil(orchestrator.pinnedWorkingDirectory(for: "worker"))
    }

    /// The bug this item exists to fix: a setup command used to run
    /// synchronously on `@MainActor`, so the app — every view, the control
    /// server, everything else the main actor serves — froze for its whole
    /// duration. `begin`'s own `Task` now has to yield the main actor while
    /// the command is still asleep, which this proves by racing it against
    /// unrelated main-actor work started after it: a setup command that still
    /// blocked the actor would starve that work until its own 3s sleep ended,
    /// instead of letting it run within `eventually`'s much shorter 1s
    /// deadline.
    @MainActor
    func testBeginReturnsWhileASlowSetupCommandIsStillRunning() async throws {
        let repo = try makeRepository()
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))

        let beginTask = Task { @MainActor in
            await WorktreeSession.begin(
                itemID: "slow-setup-item", projectRoot: repo, agentIDs: ["worker"],
                orchestrator: orchestrator, setupCommand: "sleep 3", log: { _ in })
        }

        var otherWorkRan = false
        Task { @MainActor in otherWorkRan = true }
        try await eventually(timeout: .seconds(1),
                              "unrelated main-actor work to run while setup is still asleep") {
            otherWorkRan
        }

        let setup = await beginTask.value
        guard case .isolated(let session) = setup else {
            return XCTFail("expected an isolated setup, got \(setup)")
        }
        await session.end(outcome: .cancelled)
    }

    /// The pin is what makes "writes only inside its worktree" hold across the
    /// dozen paths that restart an agent at the project root — a slash command,
    /// the team-config watcher, the no-work restart. Every one of them passes a
    /// cwd, and while an item is isolated none of them may be honoured.
    @MainActor
    func testAnIsolatedAgentCannotBeRestartedIntoTheProjectRoot() async throws {
        let repo = try makeRepository()
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))
        let setup = await WorktreeSession.begin(
            itemID: "pinned-item", projectRoot: repo, agentIDs: ["worker"],
            orchestrator: orchestrator, log: { _ in })
        guard case .isolated(let session) = setup else {
            return XCTFail("expected the item to isolate, got \(setup)")
        }

        // Whoever asks, and whatever they pass, while the item is in flight.
        try await orchestrator.startAgent("worker", cwd: repo)
        XCTAssertEqual(orchestrator.pinnedWorkingDirectory(for: "worker"), session.path)

        // Teardown releases it, so the agent goes back to the project root for
        // whatever comes next.
        await session.end(outcome: .cancelled)
        XCTAssertNil(orchestrator.pinnedWorkingDirectory(for: "worker"))
    }

    /// A pin whose directory has gone — a run that crashed between creating a
    /// worktree and tearing it down — is dropped rather than honoured. Nothing
    /// can start in a path that isn't there, and stranding an agent is worse
    /// than letting the caller's cwd through.
    func testAPinWhoseDirectoryIsGoneIsNotHonoured() {
        let worktree = URL(fileURLWithPath: "/tmp/kiteloop-gone-worktree")
        let root = URL(fileURLWithPath: "/tmp/kiteloop-project")

        XCTAssertEqual(
            Orchestrator.resolveWorkingDirectory(requested: root, pinned: worktree, pinExists: true),
            worktree)
        XCTAssertEqual(
            Orchestrator.resolveWorkingDirectory(requested: root, pinned: worktree, pinExists: false),
            root)
        XCTAssertEqual(
            Orchestrator.resolveWorkingDirectory(requested: root, pinned: nil, pinExists: false),
            root)
    }

    // MARK: - Teardown decision

    /// Work the reviewer let through is committed — including the
    /// awaiting-approval case, whose whole point is that there's a branch for a
    /// human (or auto-merge) to act on afterwards.
    @MainActor
    func testAcceptedOutcomesCommit() {
        XCTAssertEqual(WorktreeSession.teardownAction(for: .done), .commit)
        XCTAssertEqual(WorktreeSession.teardownAction(for: .awaitingApproval), .commit)
    }

    /// A blocked item keeps its worktree on disk: the half-finished tree is the
    /// evidence someone needs to see why it blocked.
    @MainActor
    func testBlockedKeepsTheWorktreeForInspection() {
        XCTAssertEqual(
            WorktreeSession.teardownAction(for: .blocked("review did not pass")),
            .keepForInspection
        )
    }

    /// A refuted premise changed no files, and the tree it was measured on is
    /// what a person at the gate may want to look at — kept, like a claim.
    @MainActor
    func testInvestigationKeepsTheWorktreeForInspection() {
        XCTAssertEqual(WorktreeSession.teardownAction(for: .investigation("- refuted: one of four")),
                       .keepForInspection)
        XCTAssertEqual(WorktreeSession.teardownAction(for: .alreadyImplemented), .keepForInspection)
    }

    /// Cancelling is not a verdict on the work: whatever the run had done is
    /// committed and the branch kept, exactly like a passing run. An empty
    /// branch is still dropped by the commit path itself.
    @MainActor
    func testCancelledCommitsLikeAnyOtherEnding() {
        XCTAssertEqual(WorktreeSession.teardownAction(for: .cancelled), .commit)
    }

    // MARK: - Teardown against a real repository

    /// A blocked run's work is **committed**, not left as loose files in a
    /// directory nobody is told about. That state is what let one item be run
    /// three times on 2026-08-08 while a finished implementation of it sat in
    /// its worktree, so the branch has to carry the diff afterwards.
    @MainActor
    func testBlockedRunCommitsItsWorkAndKeepsTheWorktree() async throws {
        let repo = try makeRepository()
        let session = try await beginSession(itemID: "left-behind", in: repo)

        try "one".write(to: session.path.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: session.path.appending(path: "b.txt"), atomically: true, encoding: .utf8)

        let teardown = await session.end(outcome: .blocked("review did not pass"))

        XCTAssertEqual(teardown.branch, "kiteloop/left-behind")
        XCTAssertEqual(teardown.worktreePath, session.path)
        // Still there to look at — inspection is not traded away for the commit.
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path.path(percentEncoded: false)))
        XCTAssertTrue(git(["status", "--porcelain"], in: session.path).isEmpty,
                      "the run's files should be committed, not loose")

        // And the shared evidence check can now see it — a file count and a
        // branch anyone can `git diff`.
        let evidence = await RunWorkEvidence.leftBehind(
            projectRoot: repo, branch: teardown.branch, isolated: true,
            worktreePath: teardown.worktreePath)
        XCTAssertTrue(evidence.hasWork)
        XCTAssertEqual(evidence.fileCount, 2)
        XCTAssertEqual(evidence.summary,
                       "2 files of work left behind on branch kiteloop/left-behind "
                       + "(worktree \(session.path.path(percentEncoded: false)))")
    }

    /// A blocked run's worktree is kept for inspection, but its disposable Xcode
    /// build output is not: left behind it never gets cleaned up, and the item's
    /// checkout, branch and diff are exactly what a human came to inspect — not
    /// the DerivedData tree sitting beside them.
    @MainActor
    func testBlockedRunReleasesItsBuildOutputButKeepsTheWorktree() async throws {
        let repo = try makeRepository()
        let session = try await beginSession(itemID: "blocked-with-build", in: repo)
        try "wip".write(to: session.path.appending(path: "wip.txt"), atomically: true, encoding: .utf8)
        let derivedData = WorktreeBuildOutput.derivedDataDirectory(for: session.path)
        try FileManager.default.createDirectory(
            at: derivedData.appending(path: "Build/Products/Debug"), withIntermediateDirectories: true)

        let teardown = await session.end(outcome: .blocked("review did not pass"))

        XCTAssertEqual(teardown.branch, "kiteloop/blocked-with-build")
        XCTAssertEqual(teardown.worktreePath, session.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path.path(percentEncoded: false)),
                      "the checkout is what a human came to inspect")
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivedData.path(percentEncoded: false)),
                       "its disposable build output must not outlive the run")
    }

    /// A blocked worktree that never built has nothing to release — teardown
    /// still succeeds and keeps the worktree exactly as the plain case does.
    @MainActor
    func testBlockedRunThatNeverBuiltIsUnaffected() async throws {
        let repo = try makeRepository()
        let session = try await beginSession(itemID: "blocked-no-build", in: repo)
        try "wip".write(to: session.path.appending(path: "wip.txt"), atomically: true, encoding: .utf8)

        let teardown = await session.end(outcome: .blocked("review did not pass"))

        XCTAssertEqual(teardown.branch, "kiteloop/blocked-no-build")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path.path(percentEncoded: false)))
    }

    /// A blocked run that produced nothing must keep reporting nothing: no
    /// commit invented, and no evidence of work that isn't there.
    @MainActor
    func testBlockedRunWithNothingToShowReportsNothing() async throws {
        let repo = try makeRepository()
        let session = try await beginSession(itemID: "did-nothing", in: repo)

        let teardown = await session.end(outcome: .blocked("review did not pass"))

        // The branch survives because the kept worktree is checked out on it;
        // it just has nothing on it, which is what the evidence has to say.
        XCTAssertEqual(teardown.branch, "kiteloop/did-nothing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path.path(percentEncoded: false)))
        let evidence = await RunWorkEvidence.leftBehind(
            projectRoot: repo, branch: teardown.branch, isolated: true,
            worktreePath: teardown.worktreePath)
        XCTAssertEqual(evidence.verdict, .noCommits)
        XCTAssertFalse(evidence.hasWork)
        XCTAssertNil(evidence.summary)
    }

    /// A cancelled run with uncommitted work keeps it: committed to the branch,
    /// the worktree removed. On 2026-09-12 a cancel discarded 90 uncommitted
    /// tests; nothing a run wrote may be thrown away by an ending.
    @MainActor
    func testCancelledRunCommitsItsWorkAndKeepsTheBranch() async throws {
        let repo = try makeRepository()
        let session = try await beginSession(itemID: "abandoned", in: repo)
        try "wip".write(to: session.path.appending(path: "wip.txt"), atomically: true, encoding: .utf8)

        let teardown = await session.end(outcome: .cancelled)

        XCTAssertEqual(teardown.branch, "kiteloop/abandoned")
        XCTAssertNil(teardown.worktreePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path.path(percentEncoded: false)))
        XCTAssertFalse(git(["rev-parse", "--verify", "--quiet", "refs/heads/kiteloop/abandoned"],
                           in: repo).isEmpty)
        XCTAssertEqual(git(["show", "kiteloop/abandoned:wip.txt"], in: repo)
                           .trimmingCharacters(in: .whitespacesAndNewlines), "wip")
    }

    /// A cancelled run that wrote nothing leaves no ref behind — the empty
    /// branch is dropped, as it is for any other ending through the commit path.
    @MainActor
    func testCancelledRunWithNoWorkDropsTheEmptyBranch() async throws {
        let repo = try makeRepository()
        let session = try await beginSession(itemID: "abandoned-empty", in: repo)

        let teardown = await session.end(outcome: .cancelled)

        XCTAssertNil(teardown.branch)
        XCTAssertTrue(git(["rev-parse", "--verify", "--quiet", "refs/heads/kiteloop/abandoned-empty"],
                          in: repo).isEmpty)
    }

    /// A passing run is unchanged too: committed, and the worktree removed —
    /// so nothing here says there is a directory to inspect.
    @MainActor
    func testAcceptedRunCommitsAndRemovesTheWorktree() async throws {
        let repo = try makeRepository()
        let session = try await beginSession(itemID: "shipped", in: repo)
        try "done".write(to: session.path.appending(path: "done.txt"), atomically: true, encoding: .utf8)

        let teardown = await session.end(outcome: .awaitingApproval)

        XCTAssertEqual(teardown.branch, "kiteloop/shipped")
        XCTAssertNil(teardown.worktreePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path.path(percentEncoded: false)))
    }

    // MARK: - The worker committed its own work

    /// The case that cost 26 commits: a worker that commits its own work leaves
    /// a clean tree, so teardown's `commitAll` has nothing to do — and the
    /// branch carrying the run's entire output used to be deleted as empty.
    /// The branch is ahead of base, so it must survive, and the run must read
    /// as having produced work.
    @MainActor
    func testSelfCommittedRunKeepsItsBranch() async throws {
        let repo = try makeRepository()
        var lines: [String] = []
        let session = try await beginSession(itemID: "self-committed", in: repo,
                                             log: { lines.append($0) })

        // The worker does the work *and* commits it, exactly as it is allowed to.
        try "the run's output".write(to: session.path.appending(path: "feature.txt"),
                                     atomically: true, encoding: .utf8)
        git(["add", "-A"], in: session.path)
        git(["commit", "-m", "worker's own commit"], in: session.path)
        XCTAssertTrue(git(["status", "--porcelain"], in: session.path).isEmpty,
                      "precondition: the worker left a clean tree")

        let teardown = await session.end(outcome: .done)
        XCTAssertNil(teardown.committedByTeardown, "the worker committed its own work")

        XCTAssertEqual(teardown.branch, "kiteloop/self-committed")
        XCTAssertFalse(git(["rev-parse", "--verify", "--quiet", "refs/heads/kiteloop/self-committed"],
                           in: repo).isEmpty,
                       "the branch holding the worker's commit must not be deleted")
        // And the evidence check now sees the work instead of "no branch".
        let evidence = await RunWorkEvidence.leftBehind(
            projectRoot: repo, branch: teardown.branch, isolated: true,
            worktreePath: teardown.worktreePath)
        XCTAssertEqual(evidence.verdict, .produced)
        XCTAssertTrue(evidence.hasWork)
        // The log says which of the three cases this was, and no longer claims
        // there were no changes.
        XCTAssertEqual(lines.last, "Worker had already committed — kept branch kiteloop/self-committed")
    }

    /// The unchanged case: work left uncommitted is still committed by teardown,
    /// and still says so.
    @MainActor
    func testUncommittedRunIsStillCommittedByTeardown() async throws {
        let repo = try makeRepository()
        var lines: [String] = []
        let session = try await beginSession(itemID: "left-loose", in: repo,
                                             log: { lines.append($0) })
        try "loose".write(to: session.path.appending(path: "feature.txt"),
                          atomically: true, encoding: .utf8)

        let teardown = await session.end(outcome: .done)

        XCTAssertEqual(teardown.branch, "kiteloop/left-loose")
        XCTAssertFalse(git(["rev-parse", "--verify", "--quiet", "refs/heads/kiteloop/left-loose"],
                           in: repo).isEmpty)
        XCTAssertEqual(lines.last, "Committed changes to branch kiteloop/left-loose")
        XCTAssertEqual(teardown.committedByTeardown, 1, "the one file the worker left loose")
    }

    /// A run that genuinely changed nothing still drops its branch — the fix
    /// must not turn every empty run into a ref nobody can use.
    @MainActor
    func testRunThatProducedNothingStillDropsItsBranch() async throws {
        let repo = try makeRepository()
        var lines: [String] = []
        let session = try await beginSession(itemID: "empty-run", in: repo,
                                             log: { lines.append($0) })

        let teardown = await session.end(outcome: .done)

        XCTAssertNil(teardown.branch)
        XCTAssertTrue(git(["rev-parse", "--verify", "--quiet", "refs/heads/kiteloop/empty-run"],
                          in: repo).isEmpty)
        XCTAssertEqual(lines.last,
                       "Nothing to commit and no commits on it — dropped branch kiteloop/empty-run")
    }

    /// The deletion criterion itself: only a branch with nothing on it is
    /// dropped, and `commitAll`'s "did I commit" never decides it.
    func testOnlyABranchWithoutCommitsIsDropped() {
        XCTAssertEqual(
            WorktreeSession.commitOutcome(teardownCommitted: true, branchHasCommits: true),
            .committedByTeardown)
        XCTAssertEqual(
            WorktreeSession.commitOutcome(teardownCommitted: false, branchHasCommits: true),
            .committedByWorker)
        XCTAssertEqual(
            WorktreeSession.commitOutcome(teardownCommitted: false, branchHasCommits: false),
            .nothingProduced)

        XCTAssertTrue(WorktreeSession.CommitOutcome.committedByTeardown.keepsBranch)
        XCTAssertTrue(WorktreeSession.CommitOutcome.committedByWorker.keepsBranch,
                      "a branch ahead of its base is never deleted")
        XCTAssertFalse(WorktreeSession.CommitOutcome.nothingProduced.keepsBranch)
    }

    /// A blocked run whose worker committed is told apart from one that produced
    /// nothing, rather than both reading as "No changes".
    @MainActor
    func testBlockedSelfCommittedRunIsNotLoggedAsNoChanges() async throws {
        let repo = try makeRepository()
        var lines: [String] = []
        let session = try await beginSession(itemID: "blocked-committed", in: repo,
                                             log: { lines.append($0) })
        try "half".write(to: session.path.appending(path: "wip.txt"), atomically: true, encoding: .utf8)
        git(["add", "-A"], in: session.path)
        git(["commit", "-m", "worker's own commit"], in: session.path)

        let teardown = await session.end(outcome: .blocked("review did not pass"))

        XCTAssertEqual(teardown.branch, "kiteloop/blocked-committed")
        XCTAssertEqual(teardown.worktreePath, session.path)
        let location = session.path.path(percentEncoded: false)
        XCTAssertEqual(lines.last,
                       "Worker had already committed to branch kiteloop/blocked-committed "
                       + "— worktree kept at \(location) for inspection")
    }

    // MARK: - Real-repository helpers

    private func makeRepository() throws -> URL {
        let repo = try makeTemporaryDirectory(prefix: "worktree-session")
        git(["init"], in: repo)
        git(["config", "user.email", "test@test.com"], in: repo)
        git(["config", "user.name", "Test"], in: repo)
        try "init".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repo)
        git(["commit", "-m", "init"], in: repo)
        return repo
    }

    /// A real session over a real worktree. The orchestrator is live but its
    /// runtime is a mock: `begin`/`end` only need agents they can restart, and
    /// what is under test is what happens to the git worktree around them.
    @MainActor
    private func beginSession(
        itemID: String,
        in repo: URL,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> WorktreeSession {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))
        let setup = await WorktreeSession.begin(
            itemID: itemID, projectRoot: repo, agentIDs: ["worker"],
            orchestrator: orchestrator, log: log)
        guard case .isolated(let session) = setup else {
            // Not a skip: a setup that stopped isolating is the regression these
            // cases exist to catch, so it has to fail rather than go quiet.
            XCTFail("expected an isolated setup, got \(setup)")
            throw WorktreeError.creationFailed(itemID)
        }
        return session
    }

    @discardableResult
    private func git(_ args: [String], in url: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Branch naming

    /// Teardown, the merge and the run result all have to name the same ref, so
    /// the prefix lives in one place.
    func testBranchNameCarriesTheKiteloopPrefix() {
        XCTAssertEqual(WorktreeSession.branchName(for: "ui-branch-link"), "kiteloop/ui-branch-link")
    }

    /// The name `branchName` produces is the one the history UI knows how to
    /// strip back down for display.
    func testBranchNameRoundTripsThroughBranchLink() {
        let branch = WorktreeSession.branchName(for: "refactor-worktree-lifecycle")
        let link = BacklogAutopilot.branchLink(
            branch: branch, projectRoot: nil, worktreeExists: { _ in false }
        )
        XCTAssertEqual(link?.shortName, "refactor-worktree-lifecycle")
    }

    // MARK: - Worktree directory naming

    /// The one place an item's worktree directory lives, same shape as
    /// `branchName(for:)`.
    func testWorktreeDirectoryIsUnderDotKiteloopWorktrees() {
        let directory = WorktreeSession.worktreeDirectory(for: "path-item", projectRoot: root)
        XCTAssertEqual(directory, root.appending(path: ".kiteloop/worktrees/path-item"))
    }

    /// `WorktreeManager` is the only thing that actually creates an item's
    /// worktree on disk. This pins `worktreeDirectory(for:projectRoot:)` to the
    /// path the manager creates for the same key, so the two cannot drift apart
    /// silently — see `WorktreeManagerTests.testWorktreePath`.
    func testWorktreeDirectoryMatchesWhatWorktreeManagerCreates() async throws {
        let repo = try makeRepository()
        let manager = WorktreeManager(projectRoot: repo)
        let created = try await manager.create(for: "matches-manager")

        XCTAssertEqual(created, WorktreeSession.worktreeDirectory(for: "matches-manager", projectRoot: repo))
    }
}
