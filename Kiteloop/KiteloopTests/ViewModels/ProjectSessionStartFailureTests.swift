// Kiteloop/KiteloopTests/ViewModels/ProjectSessionStartFailureTests.swift
import XCTest
import KiteloopCore
@testable import Kiteloop

/// A start that throws — a CLI that won't spawn, a model the runtime refuses —
/// used to be swallowed by `try?` when an agent arrived through team.json or was
/// restarted after Edit Agent…, leaving it stopped with nothing on screen. These
/// pin that the failure reaches `onError`, named, and that no chat is made for
/// an agent that never started.
final class ProjectSessionStartFailureTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "project-session-start-failure-test")
    }

    @MainActor
    func testAgentAddedToTeamConfigWhoseStartThrowsIsReportedAndGetsNoChat() async throws {
        let (session, rootURL) = try makeSession()
        let reports = ErrorReports()
        session.onError = { reports.messages.append($0) }

        session.syncTeamFromConfig(
            templates: [AgentTemplate(id: "reviewer-1", name: "Reviewer")],
            projectURL: rootURL
        )

        try await eventually("a start that threw should reach onError") {
            !reports.messages.isEmpty
        }
        XCTAssertEqual(reports.messages.count, 1)
        XCTAssertTrue(reports.messages[0].contains("Reviewer"), reports.messages[0])
        XCTAssertTrue(reports.messages[0].contains(ThrowingStartRuntime.reason), reports.messages[0])
        XCTAssertNil(session.chatViewModels["reviewer-1"], "an agent that never started must not get a chat")
    }

    @MainActor
    func testRestartWhoseStartThrowsIsReportedNamingTheAgent() async throws {
        let (session, _) = try makeSession()
        session.orchestrator.addAgent(
            Agent(
                id: "coder-1",
                name: "Coder",
                model: "sonnet",
                systemPrompt: "",
                tools: [],
                denied: [],
                permissionMode: "default",
                state: .idle
            )
        )
        let reports = ErrorReports()
        session.onError = { reports.messages.append($0) }

        session.restartAgent("coder-1")

        try await eventually("a restart whose start threw should reach onError") {
            !reports.messages.isEmpty
        }
        XCTAssertTrue(reports.messages[0].contains("Coder"), reports.messages[0])
        XCTAssertTrue(reports.messages[0].contains(ThrowingStartRuntime.reason), reports.messages[0])
    }

    @MainActor
    func testStartWhoseStartThrowsIsReportedAndLeavesTheAgentStopped() async throws {
        let (session, _) = try makeSession()
        session.orchestrator.addAgent(
            Agent(
                id: "coder-1",
                name: "Coder",
                model: "sonnet",
                systemPrompt: "",
                tools: [],
                denied: [],
                permissionMode: "default",
                state: .idle
            )
        )
        let reports = ErrorReports()
        session.onError = { reports.messages.append($0) }

        session.startAgent("coder-1")

        try await eventually("a start that threw should reach onError") {
            !reports.messages.isEmpty
        }
        XCTAssertEqual(reports.messages, ["Couldn't start Coder: \(RuntimeError.processSpawnFailed(ThrowingStartRuntime.reason).localizedDescription)"])
        XCTAssertTrue(reports.messages[0].contains(ThrowingStartRuntime.reason), reports.messages[0])
        XCTAssertEqual(session.orchestrator.stoppedAgentIDs, ["coder-1"])
    }

    @MainActor
    func testStartOnARunningAgentDoesNothing() async throws {
        let (session, _) = try makeSession(runtime: MockAgentRuntime())
        session.orchestrator.addAgent(
            Agent(
                id: "coder-1",
                name: "Coder",
                model: "sonnet",
                systemPrompt: "",
                tools: [],
                denied: [],
                permissionMode: "default",
                state: .idle
            )
        )
        session.startAgent("coder-1")
        try await eventually("the stopped agent should start") {
            session.orchestrator.hasSession(for: "coder-1")
        }
        let sessionID = session.orchestrator.sessionID(for: "coder-1")

        session.startAgent("coder-1")

        XCTAssertEqual(session.orchestrator.sessionID(for: "coder-1"), sessionID,
                       "a start on a running agent must not replace its session")
    }

    @MainActor
    func testAgentAddedToTeamConfigLeavesTheSelectedChatAlone() async throws {
        let (session, rootURL) = try makeSession(runtime: MockAgentRuntime())
        session.syncTeamFromConfig(
            templates: [AgentTemplate(id: "coder-1", name: "Coder")],
            projectURL: rootURL
        )
        try await eventually("the first agent should get a chat") {
            session.chatViewModels["coder-1"] != nil
        }
        session.selectedAgentID = "coder-1"

        session.syncTeamFromConfig(
            templates: [
                AgentTemplate(id: "coder-1", name: "Coder"),
                AgentTemplate(id: "reviewer-1", name: "Reviewer")
            ],
            projectURL: rootURL
        )

        try await eventually("the added agent should get a chat") {
            session.chatViewModels["reviewer-1"] != nil
        }
        XCTAssertTrue(session.orchestrator.agents.contains { $0.id == "reviewer-1" })
        XCTAssertEqual(session.selectedAgentID, "coder-1", "a team.json edit must not switch the open chat")
    }

    @MainActor
    func testAgentAddedToTeamConfigIsSelectedWhenNothingIs() async throws {
        let (session, rootURL) = try makeSession(runtime: MockAgentRuntime())
        XCTAssertNil(session.selectedAgentID)

        session.syncTeamFromConfig(
            templates: [AgentTemplate(id: "reviewer-1", name: "Reviewer")],
            projectURL: rootURL
        )

        try await eventually("the added agent should become the selection") {
            session.selectedAgentID == "reviewer-1"
        }
        XCTAssertTrue(session.orchestrator.agents.contains { $0.id == "reviewer-1" })
    }

    // MARK: - Helpers

    @MainActor
    private func makeSession(runtime: any AgentRuntime = ThrowingStartRuntime()) throws -> (ProjectSession, URL) {
        let rootURL = tempDir.appending(path: "repo")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: runtime,
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus) { _, _ in },
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
        return (session, rootURL)
    }

    /// All stores are pointed at the temp directory so the test never reads or
    /// writes the developer's real global config.
    @MainActor
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { ThrowingStartRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appending(path: "catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}

/// Collects what `onError` was handed, in call order.
@MainActor
private final class ErrorReports {
    var messages: [String] = []
}

/// A runtime whose every start fails, as a CLI that won't spawn does.
/// `MockAgentRuntime` always starts, so it cannot stand in here.
private final class ThrowingStartRuntime: AgentRuntime, @unchecked Sendable {
    static let reason = "claude could not be spawned"

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        throw RuntimeError.processSpawnFailed(Self.reason)
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
