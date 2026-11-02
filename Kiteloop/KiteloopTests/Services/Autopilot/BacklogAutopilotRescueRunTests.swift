import XCTest
import KiteloopCore
@testable import Kiteloop

/// The rescue extension's observing half, driven the way `GateRefreshTests`
/// drives a bounded worker round: a real git repository stands in for the
/// project, and a scripted `AgentRuntime` — not the generic `MockAgentRuntime`,
/// which touches no files — stands in for the agent, resolving the conflict
/// its worktree was actually left holding, the way a real worker's Bash tool
/// would carry out the rescue's prompt.
@MainActor
final class BacklogAutopilotRescueRunTests: XCTestCase {

    /// `BacklogAutopilot` holds its orchestrator weakly; the fixture must keep
    /// it alive for the round, and its `ChatViewModel`s are what deliver a
    /// workflow node's prompt to the runtime at all — see `GateRefreshTests`.
    private var retainedOrchestrators: [Orchestrator] = []
    private var retainedChatVMs: [ChatViewModel] = []

    // MARK: - Fixture

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
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A repo whose item branch and base both change `README.md`'s one line,
    /// differently — a real content conflict, not one a mechanical rebase
    /// (`GateRetry`'s own recovery) could ever clear on its own.
    private func makeConflictedRepo(itemID: String) throws -> URL {
        let repo = try makeTemporaryDirectory(prefix: "rescue-run-repo")
        git(["init"], in: repo)
        git(["config", "user.email", "test@test.com"], in: repo)
        git(["config", "user.name", "Test"], in: repo)
        try "v1".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repo)
        git(["commit", "-m", "init"], in: repo)

        git(["checkout", "-b", WorktreeSession.branchName(for: itemID)], in: repo)
        try "item-version".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "the item's own change"], in: repo)

        git(["checkout", "-"], in: repo)
        try "main-version".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "a sibling's conflicting change"], in: repo)
        return repo
    }

    // MARK: - Scripted runtime

    /// One worker/reviewer turn: resolves whatever `README.md` the rescue
    /// worktree was left holding — the stand-in for a real agent's Bash tool
    /// carrying out the rescue's own instruction to integrate both sides —
    /// and always answers with a passing, machine-readable verdict, which is
    /// all the reviewer node needs to route the graph to `done`. Harmless
    /// noise on the worker's own turn, which has no output schema to satisfy.
    private final class ConflictResolvingAgentRuntime: AgentRuntime, @unchecked Sendable {
        private(set) var lastCwd: URL?
        private(set) var lastMessage: String?
        private(set) var turnCount = 0

        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
            try await startSession(agent: agent, cwd: cwd, strategy: strategy, options: SessionOptions())
        }
        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession {
            lastCwd = cwd
            return AgentSession(id: "mock-session-\(agent.id)", agentID: agent.id, startedAt: .now)
        }
        func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
            lastMessage = message
            turnCount += 1
            let cwd = lastCwd
            return AsyncStream { continuation in
                Task {
                    if let cwd {
                        try? "integrated: both sides kept".write(
                            to: cwd.appending(path: "README.md"), atomically: true, encoding: .utf8)
                        let add = Process()
                        add.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                        add.arguments = ["add", "-A"]
                        add.currentDirectoryURL = cwd
                        add.standardOutput = Pipe()
                        add.standardError = Pipe()
                        try? add.run()
                        add.waitUntilExit()
                    }
                    continuation.yield(.assistantText(
                        "{\"passed\": true, \"reason\": \"resolved cleanly, keeping both sides\"}"))
                    continuation.yield(.result(StreamEvent.ResultPayload(
                        text: "resolved cleanly", costUSD: 0.01, durationMs: 10,
                        inputTokens: 10, outputTokens: 10,
                        cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                        sessionID: session.id, permissionDenials: [])))
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

    // MARK: - Wiring

    private func makeAutopilot(
        runtime: AgentRuntime, projectRoot: URL, backlogViewModel: BacklogViewModel,
        metricStore: TaskMetricStore, autonomousWorkEnabled: Bool
    ) -> BacklogAutopilot {
        let orchestrator = Orchestrator(runtime: runtime)
        retainedOrchestrators.append(orchestrator)
        // The rescue's spend is read off turn spans, which exist only with a trace store.
        orchestrator.configureTracing(tracesURL: projectRoot.appending(path: ".kiteloop/traces"))
        for id in ["worker", "reviewer"] {
            orchestrator.addAgent(Agent(id: id, name: id, model: "sonnet",
                                        systemPrompt: "", tools: [], denied: [],
                                        permissionMode: "default", state: .idle))
            retainedChatVMs.append(ChatViewModel(agentID: id, projectURL: projectRoot, orchestrator: orchestrator))
        }

        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: orchestrator,
            backlogViewModel: backlogViewModel,
            metricStore: metricStore,
            projectPath: projectRoot.path(percentEncoded: false),
            projectName: "rescue-run-test"
        )
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        autopilot.approvalGate = .land
        autopilot.autoMergeVerifyCommand = "true"
        autopilot.autonomousWorkEnabled = autonomousWorkEnabled
        return autopilot
    }

    /// Writes a real `BACKLOG.md` and detail file into the repo itself — the
    /// same repo `projectRoot` names — and loads the view model from it, the
    /// way `BacklogAutopilotGateRetryTests` does. `appendNote`/`loadDetail`
    /// both write through to that detail file, which only exists once the
    /// project has been loaded from a real path; the simpler in-memory
    /// `backlogFile` assignment `GateRefreshTests` uses is not enough here,
    /// since these tests read a note back off disk.
    private func makeBacklogViewModel(
        itemID: String, in repo: URL, tempDir: URL, metricStore: TaskMetricStore
    ) throws -> BacklogViewModel {
        let backlog = """
        ---
        project: rescue-run-test
        ---

        # Backlog

        ## Epic: Now

        - [ ] \(itemID) | Some item | awaiting-approval → [detail](backlog/\(itemID).md)
        """
        try backlog.write(to: repo.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let detailDir = repo.appending(path: "backlog")
        try FileManager.default.createDirectory(at: detailDir, withIntermediateDirectories: true)
        try "# Some item\n\nWhat: test item.\n".write(
            to: detailDir.appending(path: "\(itemID).md"), atomically: true, encoding: .utf8)

        let backlogViewModel = BacklogViewModel(globalConfigStore: GlobalConfigStore(
            storageURL: tempDir.appendingPathComponent("global-config.json")))
        backlogViewModel.loadForProject(repoPath: repo.path(percentEncoded: false))
        backlogViewModel.configureMergeOutcomeRecording(
            store: metricStore, projectPath: repo.path(percentEncoded: false), projectName: "rescue-run-test")
        return backlogViewModel
    }

    private func makeMetricStore(tempDir: URL) -> TaskMetricStore {
        TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
            mergesURL: tempDir.appending(path: "task-merges.jsonl"))
    }

    // MARK: - AC: a conflicted branch is rescued to done

    /// The item's own fixture: a rebase-proof content conflict spawns a
    /// rescue with the conflicted path in its prompt, the scripted agent
    /// resolves it, the reviewer passes, the merged tree's own verify runs,
    /// and the item reaches `done` with the outcome recorded as a machine
    /// rescue — distinct from an ordinary `done`.
    func testAConflictedBranchIsRescuedToDoneWithTheConflictedPathInThePrompt() async throws {
        let repo = try makeConflictedRepo(itemID: "item-1")
        let tempDir = try makeTemporaryDirectory(prefix: "rescue-run-vm")
        let metricStore = makeMetricStore(tempDir: tempDir)
        let backlogViewModel = try makeBacklogViewModel(itemID: "item-1", in: repo, tempDir: tempDir, metricStore: metricStore)
        let runtime = ConflictResolvingAgentRuntime()
        let autopilot = makeAutopilot(runtime: runtime, projectRoot: repo, backlogViewModel: backlogViewModel,
                                      metricStore: metricStore, autonomousWorkEnabled: true)
        autopilot.stageRescueLedgerURLForTesting(tempDir.appending(path: "rescue-run.jsonl"))

        await autopilot.handleGateExclusionForTesting(
            item: backlogViewModel.item(withID: "item-1")!,
            reason: "merge conflict in: README.md — a rebase onto the current base also conflicted",
            backlog: backlogViewModel, projectRoot: repo)

        XCTAssertEqual(backlogViewModel.item(withID: "item-1")?.status, .done,
                       "a resolved rescue must land the item exactly as an ordinary merge would")
        XCTAssertTrue(runtime.turnCount > 0, "the scripted agent must actually have been asked")
        XCTAssertTrue((runtime.lastMessage ?? "").contains("README.md"),
                      "the conflicted path must reach the agent's own prompt")

        let record = try XCTUnwrap(metricStore.records.last)
        XCTAssertEqual(record.outcome, RescueRun.rescuedOutcome)
        XCTAssertNotEqual(record.outcome, "done", "a machine rescue must never share a bucket with an ordinary run")
        XCTAssertGreaterThan(record.costUSD, 0, "the rescue's own spend must be on the run record")

        let ledger = RescueRun.Ledger.load(from: tempDir.appending(path: "rescue-run.jsonl"))
        XCTAssertTrue(ledger.hasRescued(project: repo.path(percentEncoded: false), itemID: "item-1"))
    }

    // MARK: - AC: one rescue per item, ever

    /// An item that has already spent its one rescue does not get a second
    /// one on a later qualifying exclusion — no agent is ever asked, and the
    /// item parks with a note explaining why, alongside the exclusion itself.
    func testAnItemAlreadyRescuedIsNotRescuedAgain() async throws {
        let repo = try makeConflictedRepo(itemID: "item-1")
        let tempDir = try makeTemporaryDirectory(prefix: "rescue-run-vm")
        let metricStore = makeMetricStore(tempDir: tempDir)
        let backlogViewModel = try makeBacklogViewModel(itemID: "item-1", in: repo, tempDir: tempDir, metricStore: metricStore)
        let runtime = ConflictResolvingAgentRuntime()
        let autopilot = makeAutopilot(runtime: runtime, projectRoot: repo, backlogViewModel: backlogViewModel,
                                      metricStore: metricStore, autonomousWorkEnabled: true)
        let ledgerURL = tempDir.appending(path: "rescue-run.jsonl")
        autopilot.stageRescueLedgerURLForTesting(ledgerURL)
        RescueRun.Ledger.append(
            RescueRun.Ledger.Entry(at: Date(), project: repo.path(percentEncoded: false), itemID: "item-1",
                                   outcome: "failed", reason: "the review did not pass"),
            to: ledgerURL)

        await autopilot.handleGateExclusionForTesting(
            item: backlogViewModel.item(withID: "item-1")!,
            reason: "merge conflict in: README.md", backlog: backlogViewModel, projectRoot: repo)

        XCTAssertEqual(runtime.turnCount, 0, "a second rescue on the same item must never ask an agent")
        XCTAssertEqual(backlogViewModel.item(withID: "item-1")?.status, .awaitingApproval,
                       "the item stays parked for a human rather than landing on its own")
        let detail = backlogViewModel.loadDetail(for: backlogViewModel.item(withID: "item-1")!)
        XCTAssertTrue((detail?.notes ?? "").contains("already spent"), detail?.notes ?? "")
    }

    // MARK: - AC: no consent, no rescue

    /// With the project's own consent to unattended work off, no rescue is
    /// ever spawned — a rescue is itself unattended work, and this is the one
    /// switch that governs whether the app may start any of it.
    func testWithAutonomousWorkDisabledNoRescueEverSpawns() async throws {
        let repo = try makeConflictedRepo(itemID: "item-1")
        let tempDir = try makeTemporaryDirectory(prefix: "rescue-run-vm")
        let metricStore = makeMetricStore(tempDir: tempDir)
        let backlogViewModel = try makeBacklogViewModel(itemID: "item-1", in: repo, tempDir: tempDir, metricStore: metricStore)
        let runtime = ConflictResolvingAgentRuntime()
        let autopilot = makeAutopilot(runtime: runtime, projectRoot: repo, backlogViewModel: backlogViewModel,
                                      metricStore: metricStore, autonomousWorkEnabled: false)
        autopilot.stageRescueLedgerURLForTesting(tempDir.appending(path: "rescue-run.jsonl"))

        await autopilot.handleGateExclusionForTesting(
            item: backlogViewModel.item(withID: "item-1")!,
            reason: "merge conflict in: README.md", backlog: backlogViewModel, projectRoot: repo)

        XCTAssertEqual(runtime.turnCount, 0, "no agent may be asked without the project's own consent")
        XCTAssertEqual(backlogViewModel.item(withID: "item-1")?.status, .awaitingApproval)
        XCTAssertTrue(metricStore.records.isEmpty, "an un-consented exclusion measures nothing")
        let ledgerURL = tempDir.appending(path: "rescue-run.jsonl")
        XCTAssertFalse(RescueRun.Ledger.load(from: ledgerURL).hasRescued(
            project: repo.path(percentEncoded: false), itemID: "item-1"))
        let detail = backlogViewModel.loadDetail(for: backlogViewModel.item(withID: "item-1")!)
        XCTAssertTrue((detail?.notes ?? "").contains("autonomous work is off"), detail?.notes ?? "")
    }
}
