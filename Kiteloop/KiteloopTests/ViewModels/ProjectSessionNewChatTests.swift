// Kiteloop/KiteloopTests/ViewModels/ProjectSessionNewChatTests.swift
import XCTest
import KiteloopCore
@testable import Kiteloop

/// File > New Chat (⌘N) and the sidebar's + both start a new chat through
/// `startNewChatForSelectedAgent()`: a new chat with the selected agent, and
/// nothing at all when no agent is selected.
@MainActor
final class ProjectSessionNewChatTests: XCTestCase {
    private var tempDir: URL!
    private var session: ProjectSession!
    private var store: SessionStore!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "project-session-new-chat-test")
        let rootURL = tempDir.appending(path: "repo")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        try await orchestrator.startAgent("coder", cwd: rootURL)

        store = SessionStore(projectDir: rootURL)
        session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: store,
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
    }

    func testStartsANewChatWithTheSelectedAgent() async throws {
        let vm = session.chatViewModel(for: "coder")
        let before = try XCTUnwrap(vm.currentSession)
        let countBefore = store.sessions(for: "coder").count
        session.selectedAgentID = "coder"

        await session.startNewChatForSelectedAgent()

        XCTAssertEqual(store.sessions(for: "coder").count, countBefore + 1)
        XCTAssertNotEqual(vm.currentSession?.id, before.id)
    }

    func testDoesNothingWithNoAgentSelected() async throws {
        let vm = session.chatViewModel(for: "coder")
        let before = try XCTUnwrap(vm.currentSession)
        let countBefore = store.sessions(for: "coder").count
        session.selectedAgentID = nil

        await session.startNewChatForSelectedAgent()

        XCTAssertEqual(store.sessions(for: "coder").count, countBefore)
        XCTAssertEqual(vm.currentSession?.id, before.id)
    }

    /// All stores are pointed at the temp directory so the test never reads or
    /// writes the developer's real global config.
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appending(path: "catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
