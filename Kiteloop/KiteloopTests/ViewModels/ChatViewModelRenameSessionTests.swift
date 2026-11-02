import XCTest
import KiteloopCore
@testable import Kiteloop

/// Renaming a chat from the sidebar saves the trimmed name, refuses a blank
/// one, survives the next message and is not overwritten by an auto-title that
/// arrives late.
@MainActor
final class ChatViewModelRenameSessionTests: XCTestCase {
    private var vm: ChatViewModel!
    private var store: SessionStore!
    private var runtime: MockAgentRuntime!
    private var tmpDir: URL!

    override func setUp() async throws {
        runtime = MockAgentRuntime()
        runtime.events = [.result(.init(
            text: "Done", costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: []
        ))]
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(Agent(
            id: "test", name: "Test", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        tmpDir = try makeTemporaryDirectory(prefix: "kiteloop-rename-session")
        vm = ChatViewModel(agentID: "test", projectURL: tmpDir, orchestrator: orchestrator)
        try await orchestrator.startAgent("test", cwd: tmpDir)
        store = SessionStore(projectDir: tmpDir)
    }

    /// A chat with a message in it: a fresh store prunes an empty chat that is
    /// not the newest, so an empty one would not survive the reload at all.
    private func makeSession(_ title: String) -> ChatSession {
        var session = store.createSession(agentID: "test")
        session.title = title
        session.messageCount = 1
        store.updateSession(session)
        return session
    }

    /// The title a fresh store over the same directory loads — what a relaunch shows.
    private func reloadedTitle(of session: ChatSession) -> String? {
        SessionStore(projectDir: tmpDir).sessions(for: "test").first { $0.id == session.id }?.title
    }

    func testRenamingTheOpenChatIsSavedAndReloaded() {
        let open = makeSession("Open")
        vm.setupSessionStore(store)

        vm.renameSession(open, to: "Release plan")

        XCTAssertEqual(vm.currentSession?.title, "Release plan")
        XCTAssertEqual(store.sessions(for: "test").first { $0.id == open.id }?.title, "Release plan")
        XCTAssertEqual(reloadedTitle(of: open), "Release plan")
    }

    func testRenamingAnotherChatLeavesTheOpenOneAlone() {
        let other = makeSession("Other")
        let open = makeSession("Open")
        vm.setupSessionStore(store)

        vm.renameSession(other, to: "Renamed")

        XCTAssertEqual(vm.currentSession?.id, open.id)
        XCTAssertEqual(vm.currentSession?.title, "Open")
        XCTAssertEqual(reloadedTitle(of: other), "Renamed")
        XCTAssertEqual(reloadedTitle(of: open), "Open")
    }

    func testABlankNameChangesNothing() {
        let open = makeSession("Open")
        vm.setupSessionStore(store)

        vm.renameSession(open, to: "")
        vm.renameSession(open, to: "   \n\t")

        XCTAssertEqual(vm.currentSession?.title, "Open")
        XCTAssertEqual(reloadedTitle(of: open), "Open")
    }

    func testANameWithSurroundingSpacesIsSavedTrimmed() {
        let open = makeSession("Open")
        vm.setupSessionStore(store)

        vm.renameSession(open, to: "  Trimmed  ")

        XCTAssertEqual(reloadedTitle(of: open), "Trimmed")
    }

    func testSendingAfterRenamingTheOpenChatKeepsTheName() async {
        let open = makeSession("Open")
        vm.setupSessionStore(store)

        vm.renameSession(open, to: "Kept")
        vm.inputText = "hello"
        await vm.send()

        XCTAssertEqual(runtime.lastSentMessage, "hello")
        XCTAssertEqual(vm.currentSession?.title, "Kept")
        XCTAssertEqual(reloadedTitle(of: open), "Kept")
    }

    func testALateGeneratedTitleDoesNotReplaceARename() {
        let open = makeSession("hello there")
        vm.setupSessionStore(store)

        vm.renameSession(open, to: "Mine")
        vm.applyGeneratedTitle("Generated", to: open.id, replacing: "hello there")

        XCTAssertEqual(vm.currentSession?.title, "Mine")
        XCTAssertEqual(reloadedTitle(of: open), "Mine")
    }

    func testAGeneratedTitleReplacesTheStillUnchangedPlaceholder() {
        let open = makeSession("hello there")
        vm.setupSessionStore(store)

        vm.applyGeneratedTitle("Generated", to: open.id, replacing: "hello there")

        XCTAssertEqual(vm.currentSession?.title, "Generated")
        XCTAssertEqual(reloadedTitle(of: open), "Generated")
    }

    func testAGeneratedTitleForAChatNoLongerOpenReplacesItsPlaceholder() {
        let left = makeSession("hello there")
        let open = makeSession("Open")
        vm.setupSessionStore(store)

        vm.applyGeneratedTitle("Generated", to: left.id, replacing: "hello there")

        XCTAssertEqual(vm.currentSession?.id, open.id)
        XCTAssertEqual(vm.currentSession?.title, "Open")
        XCTAssertEqual(reloadedTitle(of: left), "Generated")
        XCTAssertEqual(reloadedTitle(of: open), "Open")
    }

    func testAGeneratedTitleForAChatNoLongerOpenDoesNotReplaceARename() {
        let left = makeSession("hello there")
        _ = makeSession("Open")
        vm.setupSessionStore(store)

        vm.renameSession(left, to: "Mine")
        vm.applyGeneratedTitle("Generated", to: left.id, replacing: "hello there")

        XCTAssertEqual(reloadedTitle(of: left), "Mine")
    }

    func testAGeneratedTitleForADeletedChatSavesNothing() {
        let left = makeSession("hello there")
        let open = makeSession("Open")
        vm.setupSessionStore(store)

        store.deleteSession(left)
        vm.applyGeneratedTitle("Generated", to: left.id, replacing: "hello there")

        XCTAssertNil(store.sessions(for: "test").first { $0.id == left.id })
        XCTAssertNil(reloadedTitle(of: left))
        XCTAssertEqual(vm.currentSession?.id, open.id)
        XCTAssertEqual(vm.currentSession?.title, "Open")
    }

    func testRenameChatSaveIsRefusedForABlankName() {
        XCTAssertFalse(KiteloopSidebar.isValidChatName(""))
        XCTAssertFalse(KiteloopSidebar.isValidChatName("  \t"))
        XCTAssertTrue(KiteloopSidebar.isValidChatName(" A "))
    }

    func testRenameChatStartsFromTheTitleTheRowShows() {
        XCTAssertEqual(KiteloopSidebar.renameChatInitialText(for: ChatSession(agentID: "test", title: "Plan")), "Plan")
        XCTAssertEqual(KiteloopSidebar.renameChatInitialText(for: ChatSession(agentID: "test")), "New Chat")
    }
}
