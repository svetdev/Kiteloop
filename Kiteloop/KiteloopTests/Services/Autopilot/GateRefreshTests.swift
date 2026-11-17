import XCTest
import KiteloopCore
@testable import Kiteloop

/// `BacklogAutopilot.refreshGateItem` — the bounded worker round that rebases
/// a stale item at the approval gate. A real git repo stands in for the
/// project (the staleness question is a `merge-base` question, not one a mock
/// can answer), and a scripted `AgentRuntime` stands in for the worker: its
/// `send` actually runs `git merge` in the worktree it was started in, the
/// same way a real worker's Bash tool would carry out the prompt
/// `GateRefresh.prompt` hands it.
@MainActor
final class GateRefreshTests: XCTestCase {

    /// `BacklogAutopilot` holds its orchestrator weakly; the fixture must keep
    /// it alive for the round or the guard reads "there is no worker".
    private var retainedOrchestrators: [Orchestrator] = []

    /// The delivery half of a workflow round: a node's agent turn reaches the
    /// runtime through the agent's `ChatViewModel` observing `.agentTriggered`
    /// — the wiring `ProjectSession` gives every agent in the app. Without one
    /// the worker node never runs and the round dies of the stall clock.
    private var retainedChatVMs: [ChatViewModel] = []


    // MARK: - Fixture

    private func makeRepository() throws -> URL {
        let repo = try makeTemporaryDirectory(prefix: "gate-refresh")
        git(["init"], in: repo)
        git(["config", "user.email", "test@test.com"], in: repo)
        git(["config", "user.name", "Test"], in: repo)
        try "init".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repo)
        git(["commit", "-m", "init"], in: repo)
        return repo
    }

    @discardableResult
    private func git(_ args: [String], in url: URL) -> String {
        Self.runGit(args, in: url)
    }

    /// Off the main actor and off the instance, so a scripted runtime's turn
    /// can commit from its own task.
    @discardableResult
    private nonisolated static func runGit(_ args: [String], in url: URL) -> String {
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
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Makes the item's branch stale: `kiteloop/<id>` forks off the initial
    /// commit, then the repo's own branch moves on without it.
    @discardableResult
    private func makeStaleBranch(itemID: String, in repo: URL) -> String {
        let base = git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
        git(["checkout", "-b", WorktreeSession.branchName(for: itemID)], in: repo)
        try? "feature".write(to: repo.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repo)
        git(["commit", "-m", "the item's own work"], in: repo)
        git(["checkout", base], in: repo)
        try? "advanced".write(to: repo.appending(path: "advanced.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repo)
        git(["commit", "-m", "the base moved on"], in: repo)
        return base
    }

    /// One more commit on the base, in the repository root — the base moving
    /// on. Names the one file it writes: the item's worktree lives under the
    /// root, and `git add .` there would stage the checkout itself.
    private nonisolated static func commitOnBase(_ file: String, content: String, in repo: URL) {
        try? content.write(to: repo.appending(path: file), atomically: true, encoding: .utf8)
        runGit(["add", file], in: repo)
        runGit(["commit", "-m", "the base moved again"], in: repo)
    }

    /// Makes the base move on every merge into any branch of `repo`: a
    /// `post-merge` hook that commits on the root's checkout. Hooks are shared
    /// by a repository's worktrees, so it fires for the worker's merge and for
    /// each catch-up merge alike — a base that never stands still.
    private func makeBaseMoveOnEveryMerge(in repo: URL) throws {
        let root = repo.path(percentEncoded: false)
        let hook = repo.appending(path: ".git/hooks/post-merge")
        try FileManager.default.createDirectory(
            at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A hook inherits the merging worktree's GIT_DIR and index; dropped so
        // the commit lands in the root's checkout, not the item's.
        try """
        #!/bin/sh
        unset $(git rev-parse --local-env-vars)
        git -C "\(root)" commit -q --allow-empty -m "the base moved again"

        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hook.path(percentEncoded: false))
    }

    // MARK: - Scripted runtimes

    /// A worker whose turn merges `base` into whatever branch its worktree has
    /// checked out — the scripted stand-in for a real worker's Bash tool
    /// carrying out the merge instruction. `afterMerge` runs once the merge is
    /// in, still inside the turn: where a test moves the base during the round.
    private final class MergingAgentRuntime: AgentRuntime, @unchecked Sendable {
        private(set) var lastCwd: URL?
        let base: String
        let afterMerge: (@Sendable () -> Void)?
        init(base: String, afterMerge: (@Sendable () -> Void)? = nil) {
            self.base = base
            self.afterMerge = afterMerge
        }

        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
            try await startSession(agent: agent, cwd: cwd, strategy: strategy, options: SessionOptions())
        }
        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession {
            lastCwd = cwd
            return AgentSession(id: "mock-session", agentID: agent.id, startedAt: .now)
        }
        func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
            let cwd = lastCwd
            let base = self.base
            let afterMerge = self.afterMerge
            return AsyncStream { continuation in
                Task {
                    if let cwd {
                        let merge = Process()
                        merge.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                        merge.arguments = ["merge", "--no-ff", "-m", "merge \(base)", base]
                        merge.currentDirectoryURL = cwd
                        merge.standardOutput = Pipe()
                        merge.standardError = Pipe()
                        try? merge.run()
                        merge.waitUntilExit()
                    }
                    afterMerge?()
                    continuation.yield(.assistantText("merged and resolved"))
                    continuation.yield(.result(StreamEvent.ResultPayload(
                        text: "merged and resolved", costUSD: 0, durationMs: 0,
                        inputTokens: 0, outputTokens: 0,
                        cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                        sessionID: "mock-session", permissionDenials: [])))
                    continuation.finish()
                }
            }
        }
        func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
        func interrupt(session: AgentSession) {}
        func stop(session: AgentSession) {}
    }

    /// A worker that answers but never touches the tree — stands in for a
    /// round that fails to resolve anything, whatever the reason.
    private final class NoOpAgentRuntime: AgentRuntime, @unchecked Sendable {
        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
            AgentSession(id: "mock-session", agentID: agent.id, startedAt: .now)
        }
        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession {
            AgentSession(id: "mock-session", agentID: agent.id, startedAt: .now)
        }
        func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { continuation in
                continuation.yield(.result(StreamEvent.ResultPayload(
                    text: "nothing to do", costUSD: 0, durationMs: 0,
                    inputTokens: 0, outputTokens: 0,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "mock-session", permissionDenials: [])))
                continuation.finish()
            }
        }
        func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
        func interrupt(session: AgentSession) {}
        func stop(session: AgentSession) {}
    }

    // MARK: - Wiring

    private func makeAutopilot(
        runtime: AgentRuntime, projectRoot: URL, backlogViewModel: BacklogViewModel,
        metricStore: TaskMetricStore? = nil
    ) throws -> BacklogAutopilot {
        let orchestrator = Orchestrator(runtime: runtime)
        retainedOrchestrators.append(orchestrator)
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: orchestrator,
            backlogViewModel: backlogViewModel,
            metricStore: metricStore,
            projectPath: projectRoot.path(percentEncoded: false),
            projectName: "gate-refresh-test"
        )
        autopilot.workerAgentID = "worker"
        retainedChatVMs.append(ChatViewModel(
            agentID: "worker", projectURL: projectRoot, orchestrator: orchestrator))
        return autopilot
    }

    private func makeBacklogViewModel(itemID: String, verify: String?, tempDir: URL) throws -> BacklogViewModel {
        let backlogViewModel = BacklogViewModel(globalConfigStore: GlobalConfigStore(
            storageURL: tempDir.appendingPathComponent("global-config.json")))
        let item = BacklogItem(id: itemID, title: "Gate item", verify: verify,
                               status: .awaitingApproval, type: .local)
        backlogViewModel.backlogFile = BacklogFile(
            project: "gate-refresh-test",
            sections: [BacklogSection(name: "Epic", items: [item])])
        return backlogViewModel
    }

    // MARK: - The happy path

    /// A stale item at the gate is refreshed by one worker round: the branch
    /// reads clean afterwards, the item never leaves `awaitingApproval`, and
    /// both sides' work survive the merge.
    func testStaleItemIsRefreshedByOneWorkerRound() async throws {
        let repo = try makeRepository()
        let base = makeStaleBranch(itemID: "gate-item", in: repo)
        let manager = WorktreeManager(projectRoot: repo)
        let isStaleBefore = await manager.isStale(for: "gate-item")
        XCTAssertTrue(isStaleBefore, "the fixture must start stale")

        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-vm")
        let backlogViewModel = try makeBacklogViewModel(
            itemID: "gate-item", verify: "test -f feature.txt && test -f advanced.txt", tempDir: tempDir)
        let autopilot = try makeAutopilot(
            runtime: MergingAgentRuntime(base: base), projectRoot: repo, backlogViewModel: backlogViewModel)

        let outcome = await autopilot.refreshGateItem(itemID: "gate-item")
        XCTAssertEqual(outcome, .refreshed)

        let isStaleAfter = await manager.isStale(for: "gate-item")
        XCTAssertFalse(isStaleAfter, "the round must have merged the base in")
        XCTAssertEqual(backlogViewModel.item(withID: "gate-item")?.status, .awaitingApproval,
                       "a refresh never moves the item off the gate")
    }

    /// The round's own result — fresh, here — lands as a dated line in the
    /// item's `## Notes`, never as a status change: `refreshGateItem`'s
    /// contract is that the item is exactly where the round found it, and the
    /// note is where a human reads what the round actually did.
    func testFreshRoundLeavesADatedNoteOnTheItemsDetailFile() async throws {
        let repo = try makeRepository()
        let base = makeStaleBranch(itemID: "gate-item", in: repo)

        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-notes")
        let backlogURL = tempDir.appending(path: "BACKLOG.md")
        try """
        ---
        project: gate-refresh-test
        ---

        # Backlog

        ## Epic

        - [ ] gate-item | Gate item | verify: test -f feature.txt && test -f advanced.txt | awaiting-approval → [detail](backlog/gate-item.md)
        """.write(to: backlogURL, atomically: true, encoding: .utf8)
        let detailDir = tempDir.appending(path: "backlog")
        try FileManager.default.createDirectory(at: detailDir, withIntermediateDirectories: true)
        let detailURL = detailDir.appending(path: "gate-item.md")
        try "## Notes\n".write(to: detailURL, atomically: true, encoding: .utf8)

        let backlogViewModel = BacklogViewModel(globalConfigStore: GlobalConfigStore(
            storageURL: tempDir.appendingPathComponent("global-config.json")))
        backlogViewModel.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        XCTAssertEqual(backlogViewModel.item(withID: "gate-item")?.status, .awaitingApproval,
                       "the fixture must parse the item at the gate")

        let autopilot = try makeAutopilot(
            runtime: MergingAgentRuntime(base: base), projectRoot: repo, backlogViewModel: backlogViewModel)

        let outcome = await autopilot.refreshGateItem(itemID: "gate-item")
        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(backlogViewModel.item(withID: "gate-item")?.status, .awaitingApproval,
                       "a refresh never moves the item off the gate")

        let noteContent = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(noteContent.contains("gate refresh"), "expected a dated note, got: \(noteContent)")
    }

    /// The round's workflow polls through `awaitWorkflowCompletion` — the same
    /// poller an item's own run uses, and normally, the instant its one node
    /// (`worker`) activates, that poller writes `.active` onto whatever item
    /// the outer run loop was last positioned on and flips the autopilot's own
    /// `status` to `.running`. A refresh round reuses that poller but is not
    /// that run: staged here with a *different* item at the run loop's current
    /// index (as a finished run leaves it) and the autopilot already read back
    /// to idle, neither must move — the refresh is answered on its own item
    /// only, through a dated note, and the autopilot is left exactly as busy
    /// as it was found.
    func testRefreshRoundDoesNotStompTheBoardOrTheAutopilotsStatus() async throws {
        let repo = try makeRepository()
        let base = makeStaleBranch(itemID: "gate-item", in: repo)

        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-vm")
        let backlogViewModel = try makeBacklogViewModel(
            itemID: "gate-item", verify: "test -f feature.txt && test -f advanced.txt", tempDir: tempDir)
        let bystander = BacklogItem(id: "other-item", title: "Bystander", status: .ready, type: .local)
        backlogViewModel.backlogFile?.sections[0].items.append(bystander)

        let autopilot = try makeAutopilot(
            runtime: MergingAgentRuntime(base: base), projectRoot: repo, backlogViewModel: backlogViewModel)
        // The shape a finished run leaves behind: the autopilot back at idle,
        // but `runQueue`/`currentIndex` still pointing at the last item it ran
        // — here, deliberately, not the item about to be refreshed.
        autopilot.stageRunForTesting(status: .idle, queue: [bystander])
        autopilot.stageQueueIndexForTesting(0)

        let outcome = await autopilot.refreshGateItem(itemID: "gate-item")
        XCTAssertEqual(outcome, .refreshed)

        XCTAssertEqual(backlogViewModel.item(withID: "gate-item")?.status, .awaitingApproval,
                       "the refreshed item never leaves the gate")
        XCTAssertEqual(backlogViewModel.item(withID: "other-item")?.status, .ready,
                       "an unrelated item the run loop was last on must not be touched")
        XCTAssertEqual(autopilot.status, .idle,
                       "the autopilot must read exactly as idle as it was found")
    }

    /// The item's own defect: `runGateRefreshRound` used to rebase the branch
    /// and leave the approval gate's freshness cache exactly as it found it —
    /// so an approval right after a `.fresh` round could still read a verdict
    /// computed against the tip from before the rebase. The round now
    /// recomputes the cache itself before returning.
    func testFreshRoundRefreshesTheApprovalGatesCache() async throws {
        let repo = try makeRepository()
        let base = makeStaleBranch(itemID: "gate-item", in: repo)

        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-cache")
        let backlogViewModel = try makeBacklogViewModel(
            itemID: "gate-item", verify: "test -f feature.txt && test -f advanced.txt", tempDir: tempDir)
        // Seeds the cache against the branch's tip before the round rebases it
        // — the same refresh a run performs once an item reaches the gate.
        await backlogViewModel.refreshGateFreshness(projectRoot: repo, base: base)
        let tipBeforeRound = try XCTUnwrap(backlogViewModel.freshnessByItemID["gate-item"]?.branchTip)

        let autopilot = try makeAutopilot(
            runtime: MergingAgentRuntime(base: base), projectRoot: repo, backlogViewModel: backlogViewModel)

        let outcome = await autopilot.refreshGateItem(itemID: "gate-item")
        XCTAssertEqual(outcome, .refreshed)

        let freshness = try XCTUnwrap(backlogViewModel.freshnessByItemID["gate-item"])
        XCTAssertTrue(freshness.clean, "the round just merged the base in — the cache must read clean")
        XCTAssertNotEqual(freshness.branchTip, tipBeforeRound,
                          "the round moved the branch's tip by merging — a cache still naming the tip "
                          + "from before the round was never recomputed")
    }

    // MARK: - The base moves during the round

    /// (a) The worker merged the base, and the base took one more commit
    /// before the round was judged. Nothing was refused: the app merges the
    /// base in once more, the verify runs on that tree, and the round comes
    /// out refreshed — the verify names the file only the late commit carries.
    func testBaseMovingOnceDuringTheRoundIsCaughtUpAndRefreshed() async throws {
        let repo = try makeRepository()
        let base = makeStaleBranch(itemID: "gate-item", in: repo)
        let manager = WorktreeManager(projectRoot: repo)

        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-vm")
        let backlogViewModel = try makeBacklogViewModel(
            itemID: "gate-item", verify: "test -f feature.txt && test -f late.txt", tempDir: tempDir)
        let runtime = MergingAgentRuntime(base: base) {
            Self.commitOnBase("late.txt", content: "late", in: repo)
        }
        let autopilot = try makeAutopilot(
            runtime: runtime, projectRoot: repo, backlogViewModel: backlogViewModel)

        let outcome = await autopilot.refreshGateItem(itemID: "gate-item")
        XCTAssertEqual(outcome, .refreshed)

        let isStaleAfter = await manager.isStale(for: "gate-item")
        XCTAssertFalse(isStaleAfter, "the catch-up merge must have brought the late commit in")
        XCTAssertEqual(backlogViewModel.item(withID: "gate-item")?.status, .awaitingApproval,
                       "a refresh never moves the item off the gate")
    }

    /// (b) The commit the base took during the round collides with the
    /// branch's own work. The catch-up merge is abandoned, the round fails
    /// naming the conflict, and the branch is left where the worker's turn put
    /// it — no half-made merge on it.
    func testBaseMovingIntoAConflictFailsTheRoundAndAbortsTheMerge() async throws {
        let repo = try makeRepository()
        let base = makeStaleBranch(itemID: "gate-item", in: repo)
        let branch = WorktreeSession.branchName(for: "gate-item")

        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-vm")
        let backlogViewModel = try makeBacklogViewModel(itemID: "gate-item", verify: nil, tempDir: tempDir)
        let runtime = MergingAgentRuntime(base: base) {
            Self.commitOnBase("feature.txt", content: "the base's own idea of it", in: repo)
        }
        let autopilot = try makeAutopilot(
            runtime: runtime, projectRoot: repo, backlogViewModel: backlogViewModel)

        let outcome = await autopilot.refreshGateItem(itemID: "gate-item")
        guard case .failed(let detail) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("conflicted"), detail)
        XCTAssertEqual(backlogViewModel.item(withID: "gate-item")?.status, .awaitingApproval,
                       "a failed refresh leaves the item at the gate")
        XCTAssertEqual(git(["show", "\(branch):feature.txt"], in: repo), "feature",
                       "the branch must keep its own side — the conflicting merge was abandoned")
        XCTAssertEqual(git(["log", "--merges", "--oneline", branch], in: repo)
                           .split(separator: "\n").count, 1,
                       "only the worker's merge is on the branch")
    }

    /// The catch-up merge itself, on a checkout that outlives the call: a
    /// conflicting base answers false and leaves no merge in progress; a base
    /// that merges answers true. The project root's checkout is not touched
    /// either way.
    func testMergeBaseCleanlyAbortsAConflictAndMergesACleanBase() async throws {
        let repo = try makeRepository()
        let base = makeStaleBranch(itemID: "gate-item", in: repo)
        let manager = WorktreeManager(projectRoot: repo)
        let worktree = try await manager.reopen(
            for: "gate-item", branch: WorktreeSession.branchName(for: "gate-item"))
        let rootHeadBefore = git(["rev-parse", "HEAD"], in: repo)

        let cleanMerge = await manager.mergeBaseCleanly(for: "gate-item", base: base)
        XCTAssertTrue(cleanMerge, "a base that does not collide merges")
        let isStaleAfter = await manager.isStale(for: "gate-item")
        XCTAssertFalse(isStaleAfter)

        Self.commitOnBase("feature.txt", content: "the base's own idea of it", in: repo)
        let rootHeadMoved = git(["rev-parse", "HEAD"], in: repo)
        let tipBefore = git(["rev-parse", "HEAD"], in: worktree)
        let conflictingMerge = await manager.mergeBaseCleanly(for: "gate-item", base: base)
        XCTAssertFalse(conflictingMerge, "a colliding base does not merge cleanly")
        XCTAssertEqual(git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: worktree), "",
                       "the conflicting merge must have been aborted")
        XCTAssertEqual(git(["status", "--porcelain"], in: worktree), "",
                       "an aborted merge leaves nothing behind in the checkout")
        XCTAssertEqual(git(["rev-parse", "HEAD"], in: worktree), tipBefore)
        XCTAssertNotEqual(rootHeadBefore, rootHeadMoved, "the fixture must have moved the base")
        XCTAssertEqual(git(["rev-parse", "HEAD"], in: repo), rootHeadMoved,
                       "the project root's checkout is never merged into")

        let missing = await manager.mergeBaseCleanly(for: "no-such-item", base: base)
        XCTAssertFalse(missing, "no worktree, nothing to merge into")
    }

    /// (c) A base that takes a commit on every merge is never caught up with:
    /// the app stops after `maxRetries` catch-up merges and fails the round
    /// saying so, rather than chase it.
    func testBaseThatKeepsMovingFailsTheRoundAfterTheBound() async throws {
        let repo = try makeRepository()
        let base = makeStaleBranch(itemID: "gate-item", in: repo)
        try makeBaseMoveOnEveryMerge(in: repo)
        let branch = WorktreeSession.branchName(for: "gate-item")

        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-vm")
        let backlogViewModel = try makeBacklogViewModel(itemID: "gate-item", verify: nil, tempDir: tempDir)
        let autopilot = try makeAutopilot(
            runtime: MergingAgentRuntime(base: base), projectRoot: repo, backlogViewModel: backlogViewModel)

        let outcome = await autopilot.refreshGateItem(itemID: "gate-item")
        guard case .failed(let detail) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("after \(autopilot.maxRetries) catch-up merges"), detail)
        // The worker's merge, then one per catch-up — and not one more.
        XCTAssertEqual(git(["log", "--merges", "--oneline", branch], in: repo)
                           .split(separator: "\n").count, 1 + autopilot.maxRetries)
        XCTAssertEqual(backlogViewModel.item(withID: "gate-item")?.status, .awaitingApproval)
    }

    /// (d) The catch-up merge is clean, but the tree it makes does not pass the
    /// item's `verify:` — the round fails as any round with a failing verify
    /// does, and the verify was asked of the final tree.
    func testCleanCatchUpWithAFailingVerifyStillFailsTheRound() async throws {
        let repo = try makeRepository()
        let base = makeStaleBranch(itemID: "gate-item", in: repo)
        let manager = WorktreeManager(projectRoot: repo)

        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-vm")
        // Passes on what the worker's own merge left, fails once the late
        // commit is in: only a verify run after the catch-up can fail.
        let backlogViewModel = try makeBacklogViewModel(
            itemID: "gate-item", verify: "test ! -f late.txt", tempDir: tempDir)
        let runtime = MergingAgentRuntime(base: base) {
            Self.commitOnBase("late.txt", content: "late", in: repo)
        }
        let autopilot = try makeAutopilot(
            runtime: runtime, projectRoot: repo, backlogViewModel: backlogViewModel)

        let outcome = await autopilot.refreshGateItem(itemID: "gate-item")
        XCTAssertEqual(outcome, .failed(detail: "verify failed on the rebased branch"))
        let isStaleAfter = await manager.isStale(for: "gate-item")
        XCTAssertFalse(isStaleAfter, "the catch-up merge itself went in")
    }

    // MARK: - The gate's own preconditions

    func testNotAtTheGateAnswersNothingToRefresh() async throws {
        let repo = try makeRepository()
        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-vm")
        let backlogViewModel = BacklogViewModel(globalConfigStore: GlobalConfigStore(
            storageURL: tempDir.appendingPathComponent("global-config.json")))
        let item = BacklogItem(id: "ready-item", title: "Ready item", status: .ready, type: .local)
        backlogViewModel.backlogFile = BacklogFile(
            project: "gate-refresh-test", sections: [BacklogSection(name: "Epic", items: [item])])
        let autopilot = try makeAutopilot(
            runtime: NoOpAgentRuntime(), projectRoot: repo, backlogViewModel: backlogViewModel)

        let outcome = await autopilot.refreshGateItem(itemID: "ready-item")
        guard case .nothingToRefresh = outcome else {
            return XCTFail("expected nothingToRefresh, got \(outcome)")
        }
    }

    func testAlreadyFreshAnswersNothingToRefresh() async throws {
        let repo = try makeRepository()
        // A branch that forked off the tip is fresh by construction.
        git(["checkout", "-b", WorktreeSession.branchName(for: "gate-item")], in: repo)
        git(["checkout", "-"], in: repo)

        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-vm")
        let backlogViewModel = try makeBacklogViewModel(itemID: "gate-item", verify: nil, tempDir: tempDir)
        let autopilot = try makeAutopilot(
            runtime: NoOpAgentRuntime(), projectRoot: repo, backlogViewModel: backlogViewModel)

        let outcome = await autopilot.refreshGateItem(itemID: "gate-item")
        guard case .nothingToRefresh(let detail) = outcome else {
            return XCTFail("expected nothingToRefresh, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("fresh"), detail)
    }

    // MARK: - The bounded retry

    /// Three rounds that leave the branch stale retire the item — a fourth
    /// round is refused before it starts, without ever leaving the gate. The
    /// base collides with the branch's own work, so the app's catch-up merge
    /// cannot stand in for the worker that resolved nothing.
    func testThreeFailedRoundsRetireTheItem() async throws {
        let repo = try makeRepository()
        _ = makeStaleBranch(itemID: "gate-item", in: repo)
        Self.commitOnBase("feature.txt", content: "the base's own idea of it", in: repo)

        let tempDir = try makeTemporaryDirectory(prefix: "gate-refresh-vm")
        let backlogViewModel = try makeBacklogViewModel(itemID: "gate-item", verify: nil, tempDir: tempDir)
        let metricStore = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl"),
            mergesURL: tempDir.appendingPathComponent("task-merges.jsonl"))
        let autopilot = try makeAutopilot(
            runtime: NoOpAgentRuntime(), projectRoot: repo, backlogViewModel: backlogViewModel,
            metricStore: metricStore)

        let first = await autopilot.refreshGateItem(itemID: "gate-item")
        guard case .failed = first else { return XCTFail("expected failed, got \(first)") }
        let second = await autopilot.refreshGateItem(itemID: "gate-item")
        guard case .failed = second else { return XCTFail("expected failed, got \(second)") }
        let third = await autopilot.refreshGateItem(itemID: "gate-item")
        XCTAssertEqual(third, .retired, "the third failed round must retire the item")

        // Retired means autopilot refuses to spend a fourth round — the same
        // ceiling `RetryCeiling` enforces at pickup, read the same way.
        let verdict = autopilot.retryCeilingVerdict(
            item: backlogViewModel.item(withID: "gate-item")!, detail: nil)
        XCTAssertTrue(verdict.isRetired)
        XCTAssertEqual(metricStore.records.count, 3, "each failed round is one ledger row")
        XCTAssertTrue(metricStore.records.allSatisfy { $0.outcome == GateRefresh.failedOutcome })

        let fourth = await autopilot.refreshGateItem(itemID: "gate-item")
        guard case .nothingToRefresh = fourth else {
            return XCTFail("expected nothingToRefresh once retired, got \(fourth)")
        }
    }

    // MARK: - The prompt

    func testPromptNamesTheBaseTheBranchAndTheVerifyCommand() {
        let prompt = GateRefresh.prompt(base: "main", branch: "kiteloop/gate-item", verify: "npm test")
        XCTAssertTrue(prompt.contains("merge main into this branch"))
        XCTAssertTrue(prompt.contains("npm test"))
        XCTAssertTrue(prompt.contains("change nothing else"))
    }

    func testPromptWithNoVerifyStillAsksForAResolution() {
        let prompt = GateRefresh.prompt(base: "main", branch: "kiteloop/gate-item", verify: "")
        XCTAssertFalse(prompt.contains("verify"))
        XCTAssertTrue(prompt.contains("re-run the item's checks"))
    }
}
