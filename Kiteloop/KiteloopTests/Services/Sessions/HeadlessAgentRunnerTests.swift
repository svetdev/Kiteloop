import XCTest
import KiteloopCore
@testable import Kiteloop

/// Stub runtime for `HeadlessAgentRunner` — records what it was asked to do and
/// replays a fixed script, so the one-shot path can be tested without spawning a
/// `claude` process. All recording happens on the main actor (the runner is
/// `@MainActor` and calls every method synchronously from there).
final class StubHeadlessRuntime: AgentRuntime, @unchecked Sendable {

    enum Behavior {
        /// Yield these events, then finish the stream.
        case events([StreamEvent])
        /// A different scripted stream per `send`, in order — the last one
        /// repeats once the script runs out. For a caller that makes more than
        /// one call for one request, so each call can answer differently.
        case scripted([[StreamEvent]])
        /// Fail `startSession` with this error.
        case startFailure(any Error)
        /// Start a session, then never finish the stream — models a hung CLI.
        case stall
        /// Hang the first `count` sends, then answer every later one with
        /// `then` — a CLI that wedged once and works again afterwards. For a
        /// caller that has to be shown recovering from a hang rather than only
        /// surviving one.
        case stallingFirst(Int, then: [StreamEvent])
    }

    let behavior: Behavior
    private(set) var startedAgents: [Agent] = []
    /// The directory each session was rooted at. Recorded because a read grant's
    /// whole scope is its root — "it reads only the named project" is a claim
    /// about this value and about nothing else the runtime is told.
    private(set) var startedCwds: [URL] = []
    private(set) var sentPrompts: [String] = []
    private(set) var stoppedSessionIDs: [String] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        if case .startFailure(let error) = behavior { throw error }
        startedAgents.append(agent)
        startedCwds.append(cwd)
        return AgentSession(id: "stub-\(agent.id)", agentID: agent.id, startedAt: .now)
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        sentPrompts.append(message)
        var scripted: [StreamEvent] = []
        var finishes = true
        switch behavior {
        case .events(let events): scripted = events
        case .scripted(let script):
            // `sentPrompts` was just appended to, so this call is its last index.
            scripted = script.isEmpty ? [] : script[min(sentPrompts.count - 1, script.count - 1)]
        case .stall: finishes = false
        case .stallingFirst(let count, let then):
            // `sentPrompts` was just appended to, so the first send is 1.
            if sentPrompts.count <= count { finishes = false } else { scripted = then }
        case .startFailure: break
        }
        return AsyncStream { continuation in
            for event in scripted { continuation.yield(event) }
            if finishes { continuation.finish() }
        }
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }

    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
    func interrupt(session: AgentSession) {}

    func stop(session: AgentSession) {
        stoppedSessionIDs.append(session.id)
    }
}

@MainActor
final class HeadlessAgentRunnerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-headless")
    }

    // MARK: - Helpers

    private func makeConfigStore(defaultModel: String? = nil) -> GlobalConfigStore {
        let store = GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        store.setDefaultModel(defaultModel)
        return store
    }

    private func resultEvent(text: String) -> StreamEvent {
        .result(.init(
            text: text, costUSD: 0, durationMs: 0,
            inputTokens: 0, outputTokens: 0,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            sessionID: "stub-session", permissionDenials: []
        ))
    }

    // MARK: - Happy path

    func testConcatenatesAssistantTextAndStopsSession() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events([
            .assistantText("Hello, "),
            .thinking("(reasoning that must not leak into the reply)"),
            .assistantText("world"),
            .toolUse(id: "t1", name: "Read", input: "{}"),
            resultEvent(text: "")            // empty result text keeps the streamed chunks
        ]))

        let text = try await HeadlessAgentRunner.run(
            prompt: "say hi",
            cwd: tempDir,
            systemPrompt: "You are terse.",
            runtimeFactory: { runtime },
            globalConfigStore: makeConfigStore()
        )

        XCTAssertEqual(text, "Hello, world")
        XCTAssertEqual(runtime.sentPrompts, ["say hi"])
        XCTAssertEqual(runtime.stoppedSessionIDs.count, 1, "session must be torn down")
    }

    /// A subagent's forwarded prose (`--forward-subagent-text`) carries the id
    /// of the call that started it and is not part of the reply.
    func testASubagentsTextIsLeftOutOfTheReply() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events([
            .assistantText("I found two files.", parentToolUseID: "toolu_agent"),
            .thinking("", parentToolUseID: "toolu_agent"),
            .assistantText("The answer."),
            resultEvent(text: "")
        ]))

        let text = try await HeadlessAgentRunner.run(
            prompt: "summarise",
            cwd: tempDir,
            systemPrompt: "Be brief.",
            runtimeFactory: { runtime },
            globalConfigStore: makeConfigStore()
        )

        XCTAssertEqual(text, "The answer.")
    }

    func testResultTextOverridesStreamedChunks() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events([
            .assistantText("partial "),
            .assistantText("draft"),
            resultEvent(text: "{\"verb\":\"proceed\"}")
        ]))

        let text = try await HeadlessAgentRunner.run(
            prompt: "judge",
            cwd: tempDir,
            systemPrompt: "JSON only.",
            runtimeFactory: { runtime },
            globalConfigStore: makeConfigStore()
        )

        XCTAssertEqual(text, "{\"verb\":\"proceed\"}")
    }

    func testEmptyStreamReturnsEmptyString() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events([]))

        let text = try await HeadlessAgentRunner.run(
            prompt: "nothing",
            cwd: tempDir,
            systemPrompt: "sp",
            runtimeFactory: { runtime },
            globalConfigStore: makeConfigStore()
        )

        XCTAssertEqual(text, "")
        XCTAssertEqual(runtime.stoppedSessionIDs.count, 1)
    }

    func testBuildsToollessPlanModeAgentWithConfiguredModel() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events([resultEvent(text: "ok")]))

        _ = try await HeadlessAgentRunner.run(
            prompt: "p",
            cwd: tempDir,
            systemPrompt: "You judge run quality.",
            agentName: "Quality Judge",
            runtimeFactory: { runtime },
            globalConfigStore: makeConfigStore(defaultModel: "sonnet")
        )

        let agent = try XCTUnwrap(runtime.startedAgents.first)
        XCTAssertEqual(agent.name, "Quality Judge")
        XCTAssertEqual(agent.model, "sonnet")
        XCTAssertEqual(agent.systemPrompt, "You judge run quality.")
        XCTAssertEqual(agent.permissionMode, "plan", "one-shot replies must not act on the repo")
        XCTAssertTrue(agent.tools.isEmpty)
        XCTAssertTrue(agent.denied.isEmpty)
    }

    // MARK: - Read-only source access (a `RepoRead.Grant`)

    /// The grant *is* the scope. A caller passing one project's root and another
    /// project's grant gets the grant's — otherwise "it reads only the named
    /// project" would be a rule every caller had to remember rather than a
    /// property of this function.
    func testAGrantRootsTheSessionAtTheGrantedProjectNotTheCallersCwd() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events([resultEvent(text: "ok")]))
        let granted = tempDir.appending(path: "granted")
        let elsewhere = tempDir.appending(path: "elsewhere")

        _ = try await HeadlessAgentRunner.run(
            prompt: "does Foo.swift exist?",
            cwd: elsewhere,
            systemPrompt: "sp",
            access: RepoRead.Grant(projectName: "granted",
                                   projectPath: granted.path(percentEncoded: false)),
            runtimeFactory: { runtime },
            globalConfigStore: makeConfigStore()
        )

        XCTAssertEqual(runtime.startedCwds.first?.path(percentEncoded: false),
                       KiteloopProject.canonicalPath(granted.path(percentEncoded: false)),
                       "the grant's root, never the cwd the caller happened to pass")
    }

    /// The three read verbs, and everything else refused by name. The allow-list
    /// alone already bounds the scope; the denials are what survive a later layer
    /// trying to add one back, since `ToolScopeResolver` gives deny precedence.
    func testAGrantCarriesOnlyTheReadToolsAndDeniesTheRest() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events([resultEvent(text: "ok")]))

        _ = try await HeadlessAgentRunner.run(
            prompt: "p",
            cwd: tempDir,
            systemPrompt: "sp",
            access: RepoRead.Grant(projectName: "alpha",
                                   projectPath: tempDir.path(percentEncoded: false)),
            runtimeFactory: { runtime },
            globalConfigStore: makeConfigStore()
        )

        let agent = try XCTUnwrap(runtime.startedAgents.first)
        XCTAssertEqual(agent.tools, RepoRead.allowedTools)
        XCTAssertEqual(Set(agent.denied), Set(RepoRead.deniedTools))
        XCTAssertTrue(Set(agent.tools).isDisjoint(with: RepoRead.forbiddenTools),
                      "nothing granted may write, run a command, or reach the network")
        XCTAssertTrue(RepoRead.forbiddenTools.isSubset(of: Set(agent.denied)),
                      "and each of them is refused by name as well")
        XCTAssertEqual(agent.permissionMode, "plan", "a read grant is still not a licence to act")
    }

    /// An empty `tools` list does **not** mean "no tools" —
    /// `ClaudeCodeCLIRuntime.buildProfileScope` reads it as "unconfigured" and
    /// falls back to the whole base set. So the grant has to *name* its three,
    /// and this is the assertion that says the two paths differ.
    func testTheGrantNarrowsWhatAnUngrantedCallWouldHaveBeenAllowed() async throws {
        let ungrantedScope = ClaudeCodeCLIRuntime.buildProfileScope(
            from: Agent(name: "n", model: "m", systemPrompt: "", tools: [],
                        denied: [], permissionMode: "plan"))
        let grantedScope = ClaudeCodeCLIRuntime.buildProfileScope(
            from: Agent(name: "n", model: "m", systemPrompt: "",
                        tools: RepoRead.allowedTools,
                        denied: RepoRead.deniedTools, permissionMode: "plan"))

        let ungranted = ToolScopeResolver.resolve(profile: ungrantedScope, layers: []).effective
        let effective = ToolScopeResolver.resolve(profile: grantedScope, layers: []).effective

        XCTAssertFalse(ungranted.isDisjoint(with: RepoRead.forbiddenTools),
                       "precondition: an empty tools list falls back to the base set, which can act")
        XCTAssertEqual(effective, Set(RepoRead.allowedTools))
    }

    func testFallsBackToCatalogDefaultModelWhenUnset() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events([resultEvent(text: "ok")]))

        _ = try await HeadlessAgentRunner.run(
            prompt: "p",
            cwd: tempDir,
            systemPrompt: "sp",
            runtimeFactory: { runtime },
            globalConfigStore: makeConfigStore(defaultModel: nil)
        )

        XCTAssertEqual(runtime.startedAgents.first?.model, ModelCatalog.defaultModelID)
    }

    // MARK: - Timeout (caller cancels a stream that never finishes)

    func testCallerTimeoutUnwindsRunAndStopsSession() async throws {
        let runtime = StubHeadlessRuntime(behavior: .stall)
        let store = makeConfigStore()
        let cwd = tempDir!

        let task = Task { @MainActor in
            try await HeadlessAgentRunner.run(
                prompt: "hang",
                cwd: cwd,
                systemPrompt: "sp",
                runtimeFactory: { runtime },
                globalConfigStore: store
            )
        }

        // The stub has opened a stream that will never finish; this is where a
        // caller's deadline would fire.
        try await eventually("the stub to have been sent the prompt") { @MainActor in runtime.sentPrompts.count == 1 }
        task.cancel()

        let text = try? await task.value
        XCTAssertEqual(text, "", "cancelled run unwinds with the text it had")
        XCTAssertEqual(runtime.stoppedSessionIDs.count, 1,
                       "a timed-out run must still stop the session — no leaked process")
    }

    // MARK: - Surfaced error

    /// A runtime that fails before it replies — provisioning, a bridge that is
    /// not running — says so in a `system` error event. That reason is what the
    /// caller shows, not "the assistant returned an empty reply".
    func testAnErrorEventWithNoReplyThrowsTheRuntimesMessage() async {
        let runtime = StubHeadlessRuntime(behavior: .events([
            .system(subtype: "error", payload: ["message": "Failed to provision agent: boom"])
        ]))

        do {
            _ = try await HeadlessAgentRunner.run(
                prompt: "p",
                cwd: tempDir,
                systemPrompt: "sp",
                runtimeFactory: { runtime },
                globalConfigStore: makeConfigStore()
            )
            XCTFail("expected the runtime's error to be thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Failed to provision agent: boom"),
                          "got: \(error.localizedDescription)")
        }

        XCTAssertEqual(runtime.stoppedSessionIDs.count, 1, "the session is stopped even when the run throws")
    }

    func testAnErrorEventFollowedByTextStillReturnsTheText() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events([
            .system(subtype: "error", payload: ["message": "transient"]),
            .assistantText("the answer")
        ]))

        let text = try await HeadlessAgentRunner.run(
            prompt: "p",
            cwd: tempDir,
            systemPrompt: "sp",
            runtimeFactory: { runtime },
            globalConfigStore: makeConfigStore()
        )

        XCTAssertEqual(text, "the answer", "a partial answer is never thrown away")
    }

    func testAnErrorEventFollowedByAResultReturnsNormally() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events([
            .system(subtype: "error", payload: ["message": "transient"]),
            resultEvent(text: "{\"ok\":true}")
        ]))

        let text = try await HeadlessAgentRunner.run(
            prompt: "p",
            cwd: tempDir,
            systemPrompt: "sp",
            runtimeFactory: { runtime },
            globalConfigStore: makeConfigStore()
        )

        XCTAssertEqual(text, "{\"ok\":true}")
    }

    func testStartSessionFailureIsSurfaced() async {
        let runtime = StubHeadlessRuntime(
            behavior: .startFailure(RuntimeError.processSpawnFailed("claude not found"))
        )

        do {
            _ = try await HeadlessAgentRunner.run(
                prompt: "p",
                cwd: tempDir,
                systemPrompt: "sp",
                runtimeFactory: { runtime },
                globalConfigStore: makeConfigStore()
            )
            XCTFail("expected the runtime failure to propagate")
        } catch {
            guard case RuntimeError.processSpawnFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "claude not found")
        }

        XCTAssertTrue(runtime.sentPrompts.isEmpty, "no prompt is sent when the session never starts")
        XCTAssertTrue(runtime.stoppedSessionIDs.isEmpty, "nothing to stop when the session never started")
    }
}
