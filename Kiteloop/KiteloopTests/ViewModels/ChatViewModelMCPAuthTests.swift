import XCTest
import KiteloopCore
@testable import Kiteloop

/// A credential typed into the MCP authorization card reaches the MCP config
/// and nowhere else — it is never kept on the message that `saveMessages`
/// writes to the project's session JSON in clear text.
@MainActor
final class ChatViewModelMCPAuthTests: XCTestCase {
    private let serverName = "sentry"
    private let authKey = "SENTRY_API_KEY"
    private let secret = "sk-the-key-a-human-typed"
    private let mcpRequestID = "mcp-1"

    private var vm: ChatViewModel!
    private var projectURL: URL!
    private var mock: MockAgentRuntime!

    override func setUp() async throws {
        let mock = MockAgentRuntime()
        self.mock = mock
        // The turn reaches `request_mcp_server`, which is what appends the
        // auth request and sets `pendingMCPAuthRequestID` — the property is
        // `private(set)`, so the stream is the only way into that state.
        mock.events = [
            .mcpToolCall(.init(
                requestID: mcpRequestID,
                toolName: "request_mcp_server",
                input: "{\"server\": \"\(serverName)\", \"reason\": \"read the issue list\"}"
            )),
            .result(.init(
                text: "done",
                costUSD: 0.001, durationMs: 100,
                inputTokens: 10, outputTokens: 5,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            )),
        ]

        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(Agent(
            id: "test", name: "Test", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))

        projectURL = try makeTemporaryDirectory(prefix: "kiteloop-test")
        try writeCatalog()

        vm = ChatViewModel(agentID: "test", projectURL: projectURL, orchestrator: orchestrator)
        try await orchestrator.startAgent("test", cwd: projectURL)

        vm.inputText = "set up \(serverName)"
        await vm.send()

        XCTAssertEqual(vm.pendingMCPAuthRequestID, mcpRequestID)
    }

    /// The catalog `handleMCPServerRequest` reads, holding the one server the
    /// agent asks for and the one key the card will ask a human to type.
    private func writeCatalog() throws {
        let catalog = MCPCatalog(servers: [serverName: MCPCatalogEntry(
            command: "npx", args: ["-y", "@sentry/mcp"], env: nil,
            description: "Sentry issues", requiresAuth: true,
            authType: "env", authKeys: [authKey]
        )])
        let dir = projectURL.appendingPathComponent(".kiteloop")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: dir.appendingPathComponent("mcp-catalog.json"))
    }

    /// The auth request as it stands now, read back off the transcript.
    private var authRequest: Message.MCPAuthRequest? {
        for message in vm.messages.reversed() {
            if case .mcpAuthRequest(let req) = message.content { return req }
        }
        return nil
    }

    private func authorize() async throws {
        let req = try XCTUnwrap(authRequest)
        await vm.authorizeMCPServer(requestID: req.id, envValues: [authKey: secret])
    }

    func testTheTypedSecretIsNotKeptOnTheMessage() async throws {
        try await authorize()

        XCTAssertTrue(try XCTUnwrap(authRequest).envValues.isEmpty)
    }

    func testTheRequestIsStillMarkedAuthorized() async throws {
        try await authorize()

        XCTAssertEqual(try XCTUnwrap(authRequest).status, .authorized)
    }

    func testTheSecretStillReachesTheMCPConfig() async throws {
        try await authorize()

        let mcpPath = projectURL
            .appendingPathComponent("knowledge/agents/test/mcp.json").path
        let config = try XCTUnwrap(ClaudeMCPConfig.load(from: mcpPath))
        XCTAssertEqual(config.mcpServers[serverName]?.env?[authKey], secret)
    }

    // MARK: - The card is on disk before it is answered

    /// A store to save into, on a session that already carries a title: an
    /// untitled one would send `saveMessages` off to generate one.
    private func attachTitledSessionStore() throws -> (store: SessionStore, session: ChatSession) {
        let dir = try makeTemporaryDirectory(prefix: "kiteloop-mcp-auth-persist")
        let store = SessionStore(projectDir: dir)
        var session = store.createSession(agentID: "test")
        session.title = "Named"
        store.updateSession(session)
        vm.setupSessionStore(store)
        return (store, session)
    }

    /// Reaches the authorization request again with a store attached, on a
    /// stream that runs on past the card the way the CLI does while it blocks
    /// on the answer. The turn is still in flight when this returns.
    private func requestAuthorizationWithStore() async throws
    -> (store: SessionStore, session: ChatSession, turn: Task<Void, Never>) {
        await vm.clear()
        let (store, session) = try attachTitledSessionStore()
        mock.events = [.mcpToolCall(.init(
            requestID: mcpRequestID,
            toolName: "request_mcp_server",
            input: "{\"server\": \"\(serverName)\", \"reason\": \"read the issue list\"}"
        ))]
            + Array(repeating: StreamEvent.assistantText("."), count: 20)
            + [.result(.init(
                text: "done",
                costUSD: 0.001, durationMs: 100,
                inputTokens: 10, outputTokens: 5,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            ))]

        vm.inputText = "set up \(serverName)"
        return (store, session, Task { await self.vm.send() })
    }

    /// The card as the store has it on disk, whatever its status.
    private func persistedCard(_ store: SessionStore, _ session: ChatSession) -> Message.MCPAuthRequest? {
        for message in store.loadMessages(for: session).reversed() {
            if case .mcpAuthRequest(let req) = message.content { return req }
        }
        return nil
    }

    func testThePendingCardIsOnDiskBeforeItIsAnswered() async throws {
        let (store, session, turn) = try await requestAuthorizationWithStore()

        // The write is a detached task, and `isStreaming` is what says the turn
        // has not reached the boundary that would have saved anyway.
        try await eventually("the card on disk while the turn still waits") {
            vm.isStreaming && self.persistedCard(store, session)?.status == .pending
        }

        await turn.value
    }

    func testAuthorizingPersistsTheMovedStatus() async throws {
        let (store, session, turn) = try await requestAuthorizationWithStore()
        await turn.value

        try await authorize()

        try await eventually("the authorized card on disk") {
            self.persistedCard(store, session)?.status == .authorized
        }
    }

    func testDenyingPersistsTheMovedStatus() async throws {
        let (store, session, turn) = try await requestAuthorizationWithStore()
        await turn.value

        vm.denyMCPServer(requestID: try XCTUnwrap(authRequest).id)

        try await eventually("the denied card on disk") {
            self.persistedCard(store, session)?.status == .denied
        }
    }
    // MARK: - Only the card the agent is waiting on answers

    /// Every auth card on the transcript, oldest first.
    private var authRequests: [Message.MCPAuthRequest] {
        vm.messages.compactMap {
            if case .mcpAuthRequest(let req) = $0.content { return req }
            return nil
        }
    }

    /// Runs a second turn that asks again under a new request id, so the first
    /// card is left on the transcript still marked pending.
    private func requestAgain(as requestID: String) async {
        mock.events = [.mcpToolCall(.init(
            requestID: requestID,
            toolName: "request_mcp_server",
            input: "{\"server\": \"\(serverName)\", \"reason\": \"again\"}"
        ))]
        vm.inputText = "set up \(serverName) again"
        await vm.send()
    }

    func testAuthorizingAnOlderCardAnswersNothingWhileANewerOneIsPending() async throws {
        await requestAgain(as: "mcp-2")
        XCTAssertEqual(vm.pendingMCPAuthRequestID, "mcp-2")
        let old = try XCTUnwrap(authRequests.first { $0.toolCallID == mcpRequestID })

        await vm.authorizeMCPServer(requestID: old.id, envValues: [authKey: secret])

        XCTAssertEqual(vm.pendingMCPAuthRequestID, "mcp-2")
        XCTAssertTrue(mock.mcpToolResults.isEmpty)
        XCTAssertEqual(authRequests.map(\.status), [.pending, .pending])
    }

    func testDenyingAnOlderCardAnswersNothingWhileANewerOneIsPending() async throws {
        await requestAgain(as: "mcp-2")
        let old = try XCTUnwrap(authRequests.first { $0.toolCallID == mcpRequestID })

        vm.denyMCPServer(requestID: old.id)

        XCTAssertEqual(vm.pendingMCPAuthRequestID, "mcp-2")
        XCTAssertTrue(mock.mcpToolResults.isEmpty)
        XCTAssertEqual(authRequests.map(\.status), [.pending, .pending])
    }

    func testAfterRestartTheCardLeftFromBeforeAnswersNothing() async throws {
        let card = try XCTUnwrap(authRequest)

        await vm.restart()
        XCTAssertNil(vm.pendingMCPAuthRequestID)

        await vm.authorizeMCPServer(requestID: card.id, envValues: [authKey: secret])

        XCTAssertTrue(mock.mcpToolResults.isEmpty)
        XCTAssertEqual(try XCTUnwrap(authRequest).status, .pending)
        let mcpPath = projectURL.appendingPathComponent("knowledge/agents/test/mcp.json").path
        XCTAssertNil(ClaudeMCPConfig.load(from: mcpPath))
    }

    func testAfterClearTheCardLeftFromBeforeAnswersNothing() async throws {
        let card = try XCTUnwrap(authRequest)

        await vm.clear()
        XCTAssertNil(vm.pendingMCPAuthRequestID)

        await vm.authorizeMCPServer(requestID: card.id, envValues: [authKey: secret])

        XCTAssertTrue(mock.mcpToolResults.isEmpty)
        let mcpPath = projectURL.appendingPathComponent("knowledge/agents/test/mcp.json").path
        XCTAssertNil(ClaudeMCPConfig.load(from: mcpPath))
    }

    func testAuthorizingTheCardThatIsWaitingAnswersIt() async throws {
        try await authorize()

        XCTAssertNil(vm.pendingMCPAuthRequestID)
        XCTAssertEqual(mock.mcpToolResults.count, 1)
    }

    // MARK: - A server that was never saved is not authorized

    /// Puts a file where the agent's package directory would go, so the MCP
    /// config has nowhere to be written.
    private func makeTheConfigUnwritable() throws {
        let agents = projectURL.appendingPathComponent("knowledge/agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data().write(to: agents.appendingPathComponent("test"))
    }

    /// The last thing in the chat, if it is an error.
    private var trailingError: String? {
        if case .error(let text) = vm.messages.last?.content { return text }
        return nil
    }

    private func assertNothingWasAuthorized(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try XCTUnwrap(authRequest).status, .pending, file: file, line: line)
        let error = try XCTUnwrap(trailingError, "the chat ends with an error", file: file, line: line)
        XCTAssertTrue(error.contains(serverName), "\(error) names the server", file: file, line: line)
        XCTAssertEqual(mock.mcpToolResults.count, 1, "the agent still hears the failure", file: file, line: line)
        XCTAssertFalse(mock.mcpToolResults[0].contains("authorized and configured"), file: file, line: line)
        XCTAssertNil(mock.lastSessionOptions, "no restart was attempted", file: file, line: line)
    }

    func testAConfigThatCannotBeWrittenLeavesTheCardUnauthorized() async throws {
        try makeTheConfigUnwritable()
        mock.lastSessionOptions = nil

        try await authorize()

        try assertNothingWasAuthorized()
        XCTAssertTrue(try XCTUnwrap(trailingError).contains("failed to save MCP config"))
    }

    func testAServerGoneFromTheCatalogLeavesTheCardUnauthorized() async throws {
        let catalog = MCPCatalog(servers: [:])
        try JSONEncoder().encode(catalog)
            .write(to: projectURL.appendingPathComponent(".kiteloop/mcp-catalog.json"))
        mock.lastSessionOptions = nil

        try await authorize()

        try assertNothingWasAuthorized()
        XCTAssertTrue(try XCTUnwrap(trailingError).contains("server not found in catalog"))
    }

    func testAMissingCatalogLeavesTheCardUnauthorized() async throws {
        try FileManager.default.removeItem(at: projectURL.appendingPathComponent(".kiteloop/mcp-catalog.json"))
        mock.lastSessionOptions = nil

        try await authorize()

        try assertNothingWasAuthorized()
    }

    func testAFailedAuthorizationPersistsThePendingCardAndTheError() async throws {
        let (store, session, turn) = try await requestAuthorizationWithStore()
        await turn.value
        try makeTheConfigUnwritable()

        try await authorize()

        try await eventually("the error on disk after the still-pending card") {
            let saved = store.loadMessages(for: session)
            guard case .error(let text) = saved.last?.content else { return false }
            return text.contains(self.serverName) && self.persistedCard(store, session)?.status == .pending
        }
    }

    func testASuccessfulAuthorizationRestartsTheSession() async throws {
        mock.lastSessionOptions = nil

        try await authorize()

        XCTAssertNotNil(mock.lastSessionOptions)
        XCTAssertNil(trailingError)
    }

    // MARK: - The card draws answer controls only when it can answer

    private func card(status: Message.MCPAuthRequest.AuthStatus, isAnswerable: Bool) -> MCPAuthorizationCard {
        MCPAuthorizationCard(
            request: Message.MCPAuthRequest(
                id: "card", toolCallID: mcpRequestID, serverName: serverName,
                reason: "", description: "", authKeys: [authKey], status: status
            ),
            isAnswerable: isAnswerable,
            onAuthorize: { _ in }, onDeny: {}
        )
    }

    func testOnlyAnAnswerablePendingCardShowsFieldsAndButtons() {
        XCTAssertTrue(card(status: .pending, isAnswerable: true).showsAnswerControls)
        XCTAssertFalse(card(status: .pending, isAnswerable: false).showsAnswerControls)
        XCTAssertFalse(card(status: .authorized, isAnswerable: true).showsAnswerControls)
    }
}
