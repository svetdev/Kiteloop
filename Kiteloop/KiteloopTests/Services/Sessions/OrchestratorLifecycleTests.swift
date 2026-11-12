import XCTest
import KiteloopCore
@testable import Kiteloop

/// Lifecycle coverage for `Orchestrator`: `startAgent` / `stopAgent` /
/// `setUnattended` and the state they own (sessions, `Agent.state`,
/// `unattendedAgentIDs`). Driven entirely through a stub runtime so no
/// `claude` process is ever spawned.
@MainActor
final class OrchestratorLifecycleTests: XCTestCase {

    // MARK: - Stub runtime

    /// Records every lifecycle call the orchestrator makes so the tests can
    /// assert on what was forwarded to the runtime (cwd, resume strategy,
    /// which session was stopped) instead of only on orchestrator state.
    private final class RecordingRuntime: AgentRuntime, @unchecked Sendable {
        struct StartCall {
            let agentID: String
            let systemPrompt: String
            let cwd: URL
            let strategy: String
            let options: SessionOptions
        }

        private(set) var startCalls: [StartCall] = []
        private(set) var stoppedSessionIDs: [String] = []
        private(set) var interruptedSessionIDs: [String] = []
        /// Set to make the next `startSession` throw instead of returning a session.
        var startError: Error?
        var events: [StreamEvent] = []

        private var sessionCounter = 0

        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
            try await startSession(agent: agent, cwd: cwd, strategy: strategy, options: SessionOptions())
        }

        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession {
            startCalls.append(StartCall(
                agentID: agent.id,
                systemPrompt: agent.systemPrompt,
                cwd: cwd,
                strategy: Self.label(for: strategy),
                options: options
            ))
            if let startError { throw startError }
            sessionCounter += 1
            return AgentSession(id: "session-\(sessionCounter)", agentID: agent.id, startedAt: .now)
        }

        func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
            let events = self.events
            return AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }

        func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }

        func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}

        func interrupt(session: AgentSession) {
            interruptedSessionIDs.append(session.id)
        }

        func stop(session: AgentSession) {
            stoppedSessionIDs.append(session.id)
        }

        /// `ResumeStrategy` isn't `Equatable`, so flatten it to a comparable label.
        static func label(for strategy: ResumeStrategy) -> String {
            switch strategy {
            case .fresh: return "fresh"
            case .resume(let id): return "resume:\(id)"
            case .fork(let id): return "fork:\(id)"
            case .compact(let id): return "compact:\(id)"
            }
        }
    }

    private struct StubStartFailure: Error {}

    // MARK: - Fixtures

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-lifecycle")
    }

    private func makeAgent(
        id: String,
        name: String = "Agent",
        state: Agent.AgentState = .idle
    ) -> Agent {
        Agent(
            id: id, name: name, model: "sonnet",
            systemPrompt: "You are \(name).",
            tools: [], denied: [],
            permissionMode: "default", state: state
        )
    }

    private func state(of agentID: String, in orchestrator: Orchestrator) -> Agent.AgentState? {
        orchestrator.agents.first { $0.id == agentID }?.state
    }

    private func doneResult(sessionID: String) -> StreamEvent {
        .result(.init(
            text: "Done.", costUSD: 0.001, durationMs: 10,
            inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            sessionID: sessionID, permissionDenials: []
        ))
    }

    // MARK: - startAgent

    /// A successful start registers a session for the agent and parks it in `.idle`,
    /// even if the agent was previously `.crashed`.
    func testStartAgentCreatesSessionAndMarksIdle() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker", state: .crashed))

        XCTAssertFalse(orchestrator.hasSession(for: "worker"), "No session before startAgent")

        try await orchestrator.startAgent("worker", cwd: tempDir)

        XCTAssertTrue(orchestrator.hasSession(for: "worker"), "startAgent should register a session")
        XCTAssertEqual(orchestrator.sessionID(for: "worker"), "session-1",
                       "sessionID(for:) should expose the runtime's session id")
        XCTAssertEqual(state(of: "worker", in: orchestrator), .idle,
                       "startAgent should reset the agent to .idle")
    }

    /// The cwd is forwarded verbatim, and with no resume id the orchestrator asks
    /// the context engine — which yields `.fresh` for a session-less agent.
    func testStartAgentForwardsCWDAndUsesFreshStrategy() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))

        try await orchestrator.startAgent("worker", cwd: tempDir)

        XCTAssertEqual(runtime.startCalls.count, 1)
        XCTAssertEqual(runtime.startCalls.first?.cwd, tempDir)
        XCTAssertEqual(runtime.startCalls.first?.strategy, "fresh",
                       "A start with no resume id should use .fresh")
        XCTAssertTrue(runtime.startCalls.first?.systemPrompt.contains("You are Worker.") == true,
                      "The composed prompt handed to the runtime should include the agent's own prompt")
    }

    /// An explicit resume id maps to `.resume`; adding `forkSession` maps to `.fork`.
    func testStartAgentMapsResumeAndForkStrategies() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "resumer", name: "Resumer"))
        orchestrator.addAgent(makeAgent(id: "forker", name: "Forker"))

        try await orchestrator.startAgent("resumer", cwd: tempDir, resumeSessionID: "prior-abc")
        try await orchestrator.startAgent("forker", cwd: tempDir, resumeSessionID: "prior-xyz", forkSession: true)

        XCTAssertEqual(runtime.startCalls.map(\.strategy), ["resume:prior-abc", "fork:prior-xyz"])
    }

    /// An empty resume id is treated as "no resume id" and falls back to `.fresh`.
    func testStartAgentIgnoresEmptyResumeSessionID() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))

        try await orchestrator.startAgent("worker", cwd: tempDir, resumeSessionID: "", forkSession: true)

        XCTAssertEqual(runtime.startCalls.first?.strategy, "fresh",
                       "An empty resume id should not produce a .fork/.resume strategy")
    }

    /// Starting an id that was never added is a silent no-op — the runtime is never touched.
    func testStartAgentForUnknownAgentIsNoOp() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)

        try await orchestrator.startAgent("nobody", cwd: tempDir)

        XCTAssertTrue(runtime.startCalls.isEmpty, "Unknown agent should not reach the runtime")
        XCTAssertFalse(orchestrator.hasSession(for: "nobody"))
    }

    /// If the runtime fails to spawn, the error propagates and no session is registered;
    /// the agent keeps whatever state it had (it was never successfully started).
    func testStartAgentPropagatesRuntimeFailureAndLeavesNoSession() async throws {
        let runtime = RecordingRuntime()
        runtime.startError = StubStartFailure()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "doomed", name: "Doomed", state: .crashed))

        do {
            try await orchestrator.startAgent("doomed", cwd: tempDir)
            XCTFail("startAgent should rethrow the runtime's error")
        } catch is StubStartFailure {
            // expected
        }

        XCTAssertFalse(orchestrator.hasSession(for: "doomed"), "A failed start must not register a session")
        XCTAssertNil(orchestrator.sessionID(for: "doomed"))
        XCTAssertEqual(state(of: "doomed", in: orchestrator), .crashed,
                       "A failed start should not flip the agent to .idle")
    }

    /// Starting an already-started agent replaces the managed session with a new one.
    func testStartAgentTwiceReplacesSession() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))

        try await orchestrator.startAgent("worker", cwd: tempDir)
        XCTAssertEqual(orchestrator.sessionID(for: "worker"), "session-1")

        try await orchestrator.startAgent("worker", cwd: tempDir)

        XCTAssertEqual(runtime.startCalls.count, 2)
        XCTAssertEqual(orchestrator.sessionID(for: "worker"), "session-2",
                       "The second start should replace the tracked session")
    }

    // MARK: - stopAgent

    /// Stopping tears down the session, tells the runtime to stop it, and leaves
    /// the agent `.idle`.
    func testStopAgentStopsRuntimeSessionAndClearsIt() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))
        try await orchestrator.startAgent("worker", cwd: tempDir)

        orchestrator.stopAgent("worker")

        XCTAssertEqual(runtime.stoppedSessionIDs, ["session-1"],
                       "stopAgent should stop exactly the agent's session")
        XCTAssertFalse(orchestrator.hasSession(for: "worker"), "The session should be dropped")
        XCTAssertNil(orchestrator.sessionID(for: "worker"))
        XCTAssertEqual(state(of: "worker", in: orchestrator), .idle)
    }

    /// A stop mid-turn returns a `.working` agent to `.idle`.
    func testStopAgentResetsWorkingAgentToIdle() async throws {
        let runtime = RecordingRuntime()
        runtime.events = [.assistantText("Thinking…"), doneResult(sessionID: "session-1")]
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))
        try await orchestrator.startAgent("worker", cwd: tempDir)

        let stream = orchestrator.send("Go", to: "worker")
        XCTAssertEqual(state(of: "worker", in: orchestrator), .working)
        for await _ in stream {}

        orchestrator.stopAgent("worker")

        XCTAssertEqual(state(of: "worker", in: orchestrator), .idle,
                       "stopAgent should clear the .working state left by send()")
    }

    /// Stopping twice is safe: the second call finds no session and stops nothing again.
    func testStopAgentIsIdempotent() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))
        try await orchestrator.startAgent("worker", cwd: tempDir)

        orchestrator.stopAgent("worker")
        orchestrator.stopAgent("worker")

        XCTAssertEqual(runtime.stoppedSessionIDs, ["session-1"],
                       "A repeated stop should not stop the session twice")
    }

    /// Stopping an agent that was never started (or never added) touches nothing.
    func testStopAgentWithoutSessionIsNoOp() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "idle-one", name: "Idler"))

        orchestrator.stopAgent("idle-one")
        orchestrator.stopAgent("never-added")

        XCTAssertTrue(runtime.stoppedSessionIDs.isEmpty)
        XCTAssertEqual(state(of: "idle-one", in: orchestrator), .idle)
        XCTAssertEqual(orchestrator.agents.count, 1, "stopAgent should not remove the agent")
    }

    /// `stoppedAgentIDs` follows the session: a started agent is not in it, a
    /// stopped one is, and starting it again takes it out — without stopping
    /// anything on the way, so a Start never reads as a Stop.
    func testStoppedAgentIDsFollowsStopAndStart() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))
        orchestrator.addAgent(makeAgent(id: "other", name: "Other"))
        try await orchestrator.startAgent("worker", cwd: tempDir)
        try await orchestrator.startAgent("other", cwd: tempDir)
        XCTAssertTrue(orchestrator.stoppedAgentIDs.isEmpty)

        orchestrator.stopAgent("worker")
        XCTAssertEqual(orchestrator.stoppedAgentIDs, ["worker"])

        try await orchestrator.startAgent("worker", cwd: tempDir)
        XCTAssertTrue(orchestrator.hasSession(for: "worker"))
        XCTAssertTrue(orchestrator.stoppedAgentIDs.isEmpty)
        XCTAssertEqual(runtime.stoppedSessionIDs, ["session-1"],
                       "starting a stopped agent should stop nothing")
    }

    /// After a stop the agent is un-addressable: `send` finds no session and finishes empty.
    func testSendAfterStopYieldsNoEvents() async throws {
        let runtime = RecordingRuntime()
        runtime.events = [.assistantText("Should not appear")]
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))
        try await orchestrator.startAgent("worker", cwd: tempDir)
        orchestrator.stopAgent("worker")

        var events: [StreamEvent] = []
        for await event in orchestrator.send("Still there?", to: "worker") { events.append(event) }

        XCTAssertTrue(events.isEmpty, "Sending to a stopped agent should yield no events")
    }

    /// `restartAgent` is stop-then-start: the old session is stopped and a new one
    /// is opened, resuming the id that was handed in.
    func testRestartAgentStopsOldSessionAndResumesNewOne() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))
        try await orchestrator.startAgent("worker", cwd: tempDir)

        let priorSessionID = try XCTUnwrap(orchestrator.sessionID(for: "worker"))
        try await orchestrator.restartAgent("worker", cwd: tempDir, resumeSessionID: priorSessionID)

        XCTAssertEqual(runtime.stoppedSessionIDs, [priorSessionID])
        XCTAssertEqual(runtime.startCalls.map(\.strategy), ["fresh", "resume:\(priorSessionID)"])
        XCTAssertEqual(orchestrator.sessionID(for: "worker"), "session-2")
        XCTAssertEqual(state(of: "worker", in: orchestrator), .idle)
    }

    /// `removeAgent` also stops the live session, and additionally drops the agent.
    func testRemoveAgentStopsSessionAndDropsAgent() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))
        orchestrator.addAgent(makeAgent(id: "keeper", name: "Keeper"))
        try await orchestrator.startAgent("worker", cwd: tempDir)

        orchestrator.removeAgent("worker")

        XCTAssertEqual(runtime.stoppedSessionIDs, ["session-1"])
        XCTAssertFalse(orchestrator.hasSession(for: "worker"))
        XCTAssertEqual(orchestrator.agents.map(\.id), ["keeper"])
    }

    // MARK: - setUnattended

    /// The unattended set is empty by default and toggles per call.
    func testSetUnattendedTogglesMembership() {
        let orchestrator = Orchestrator(runtime: RecordingRuntime())
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))

        XCTAssertTrue(orchestrator.unattendedAgentIDs.isEmpty, "Agents are attended by default")

        orchestrator.setUnattended("worker", true)
        XCTAssertTrue(orchestrator.unattendedAgentIDs.contains("worker"))

        orchestrator.setUnattended("worker", false)
        XCTAssertFalse(orchestrator.unattendedAgentIDs.contains("worker"))
    }

    /// Repeated sets are idempotent — the set never accumulates duplicates, and
    /// clearing an id that isn't marked is harmless.
    func testSetUnattendedIsIdempotent() {
        let orchestrator = Orchestrator(runtime: RecordingRuntime())
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))

        orchestrator.setUnattended("worker", true)
        orchestrator.setUnattended("worker", true)
        XCTAssertEqual(orchestrator.unattendedAgentIDs, ["worker"])

        orchestrator.setUnattended("worker", false)
        orchestrator.setUnattended("worker", false)
        XCTAssertTrue(orchestrator.unattendedAgentIDs.isEmpty)
    }

    /// Autopilot marks worker and reviewer independently; clearing one must not
    /// clear the other.
    func testSetUnattendedIsPerAgent() {
        let orchestrator = Orchestrator(runtime: RecordingRuntime())
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))
        orchestrator.addAgent(makeAgent(id: "reviewer", name: "Reviewer"))

        orchestrator.setUnattended("worker", true)
        orchestrator.setUnattended("reviewer", true)
        XCTAssertEqual(orchestrator.unattendedAgentIDs, ["worker", "reviewer"])

        orchestrator.setUnattended("worker", false)
        XCTAssertEqual(orchestrator.unattendedAgentIDs, ["reviewer"],
                       "Clearing one agent must not clear the other")
    }

    /// The flag is session-independent: autopilot sets it around a whole run, which
    /// may restart the agent's session part-way through.
    func testSetUnattendedSurvivesSessionRestart() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))
        try await orchestrator.startAgent("worker", cwd: tempDir)
        orchestrator.setUnattended("worker", true)

        orchestrator.stopAgent("worker")
        XCTAssertTrue(orchestrator.unattendedAgentIDs.contains("worker"),
                      "stopAgent should not silently drop the unattended flag")

        try await orchestrator.startAgent("worker", cwd: tempDir)
        XCTAssertTrue(orchestrator.unattendedAgentIDs.contains("worker"),
                      "startAgent should not silently drop the unattended flag")
    }

    // MARK: - Session options

    /// The one thing that decides the terms of a spawn: an agent a run has taken
    /// over is spawned unattended, and one it hasn't — the same agent, between
    /// runs — is not. Assigned autopilot roles deliberately don't come into it,
    /// so chatting with the worker stays an ordinary chat.
    func testSessionOptionsFollowTheUnattendedFlagOnly() async throws {
        let orchestrator = Orchestrator(runtime: RecordingRuntime())
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))

        XCTAssertFalse(orchestrator.sessionOptions(for: "worker").unattended,
                       "An agent no run has taken over is spawned as a chat session")

        orchestrator.setUnattended("worker", true)
        XCTAssertTrue(orchestrator.sessionOptions(for: "worker").unattended)

        orchestrator.setUnattended("worker", false)
        XCTAssertFalse(orchestrator.sessionOptions(for: "worker").unattended,
                       "The run ended — the next session is a chat one again")
    }

    /// The options reach the runtime, which is where they turn into the spawned
    /// process's environment.
    func testStartAgentForwardsSessionOptionsToRuntime() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))

        try await orchestrator.startAgent("worker", cwd: tempDir)
        XCTAssertEqual(runtime.startCalls.last?.options, SessionOptions(unattended: false, asksBeforeListedTools: true),
                       "A chat agent's spawn in the Ask mode must be asked for as attended, and to ask")

        orchestrator.setUnattended("worker", true)
        orchestrator.stopAgent("worker")
        try await orchestrator.startAgent("worker", cwd: tempDir)
        XCTAssertEqual(runtime.startCalls.last?.options, SessionOptions(unattended: true),
                       "A session started for a run must be asked for as unattended")
    }

    /// A chat session in a mode that promises to ask is spawned to ask; the
    /// same agent taken over by a run is not — nobody is there to answer.
    func testAChatSessionInAModeThatAsksIsSpawnedToAsk() async throws {
        let runtime = RecordingRuntime()
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))
        orchestrator.updateAgent(id: "worker") { $0.permissionMode = "acceptEdits" }

        try await orchestrator.startAgent("worker", cwd: tempDir)
        XCTAssertEqual(runtime.startCalls.last?.options,
                       SessionOptions(unattended: false, asksBeforeListedTools: true))
        XCTAssertTrue(orchestrator.liveSessionTakes(mode: "plan", for: "worker"), "another mode that asks, as it runs")
        XCTAssertFalse(orchestrator.liveSessionTakes(mode: "auto", for: "worker"), "Auto approves the tools: a new process")

        orchestrator.setUnattended("worker", true)
        orchestrator.stopAgent("worker")
        XCTAssertFalse(orchestrator.liveSessionTakes(mode: "plan", for: "worker"), "no session")
        try await orchestrator.startAgent("worker", cwd: tempDir)
        XCTAssertEqual(runtime.startCalls.last?.options, SessionOptions(unattended: true))
        XCTAssertFalse(orchestrator.liveSessionTakes(mode: "auto", for: "worker"), "a run's session is not a chat's to move")
    }

    /// What a live session was started with, which autopilot reads to find the
    /// worker sitting on a process spawned for a human. Nil means no session —
    /// distinct from a session that exists and is attended.
    func testLiveSessionIsUnattendedReportsHowTheSessionWasStarted() async throws {
        let orchestrator = Orchestrator(runtime: RecordingRuntime())
        orchestrator.addAgent(makeAgent(id: "worker", name: "Worker"))

        XCTAssertNil(orchestrator.liveSessionIsUnattended(for: "worker"), "No session yet")

        try await orchestrator.startAgent("worker", cwd: tempDir)
        XCTAssertEqual(orchestrator.liveSessionIsUnattended(for: "worker"), false)

        orchestrator.setUnattended("worker", true)
        XCTAssertEqual(orchestrator.liveSessionIsUnattended(for: "worker"), false,
                       "Marking the agent cannot change the process already running")

        orchestrator.stopAgent("worker")
        try await orchestrator.startAgent("worker", cwd: tempDir)
        XCTAssertEqual(orchestrator.liveSessionIsUnattended(for: "worker"), true,
                       "Only a restart puts the agent on an unattended process")
    }

    // MARK: - renameInCrossAgentAccess

    private func team(accessOfA access: [String], builderAccess: [String] = []) -> Orchestrator {
        let orchestrator = Orchestrator(runtime: RecordingRuntime())
        orchestrator.addAgent(makeAgent(id: "a", name: "A"))
        orchestrator.addAgent(makeAgent(id: "builder", name: "Builder"))
        orchestrator.addAgent(makeAgent(id: "tester", name: "Tester"))
        orchestrator.updateAgent(id: "a") { $0.crossAgentAccess = access }
        orchestrator.updateAgent(id: "builder") { $0.crossAgentAccess = builderAccess }
        return orchestrator
    }

    private func access(of agentID: String, in orchestrator: Orchestrator) -> [String]? {
        orchestrator.agents.first { $0.id == agentID }?.crossAgentAccess
    }

    /// A teammate allowed to message the old name keeps that access under the
    /// new one; the match ignores case, as the messaging gate does.
    func testRenameRewritesTheOldNameInTeammatesAccess() {
        let orchestrator = team(accessOfA: ["builder", "Tester"])

        orchestrator.renameInCrossAgentAccess(of: "builder", to: "Engineer")

        XCTAssertEqual(access(of: "a", in: orchestrator), ["Engineer", "Tester"])
    }

    /// Wildcards and names that belong to no agent are not the renamed agent.
    func testRenameLeavesWildcardsAndOtherNamesAlone() {
        let orchestrator = team(accessOfA: ["*", "all", "Ghost", "Builder"])

        orchestrator.renameInCrossAgentAccess(of: "builder", to: "Engineer")

        XCTAssertEqual(access(of: "a", in: orchestrator), ["*", "all", "Ghost", "Engineer"])
    }

    /// An unchanged name, or the same name in other capitals, rewrites nothing.
    func testRenameToTheSameNameChangesNoList() {
        let orchestrator = team(accessOfA: ["builder", "Tester"])

        orchestrator.renameInCrossAgentAccess(of: "builder", to: "Builder")
        orchestrator.renameInCrossAgentAccess(of: "builder", to: " BUILDER ")

        XCTAssertEqual(access(of: "a", in: orchestrator), ["builder", "Tester"])
    }

    /// The renamed agent's own list names its teammates, not itself, and is
    /// left as the editor wrote it.
    func testRenameDoesNotRewriteTheRenamedAgentsOwnList() {
        let orchestrator = team(accessOfA: [], builderAccess: ["Builder", "Tester"])

        orchestrator.renameInCrossAgentAccess(of: "builder", to: "Engineer")

        XCTAssertEqual(access(of: "builder", in: orchestrator), ["Builder", "Tester"])
    }
}
