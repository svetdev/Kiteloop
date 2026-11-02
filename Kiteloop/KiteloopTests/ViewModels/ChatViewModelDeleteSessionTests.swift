import XCTest
import KiteloopCore
@testable import Kiteloop

/// Deleting a chat from the sidebar removes it and its messages file; deleting
/// the open one opens the next chat, or a fresh one when none is left, and
/// never writes the deleted chat back.
@MainActor
final class ChatViewModelDeleteSessionTests: XCTestCase {
    private var vm: ChatViewModel!
    private var store: SessionStore!

    override func setUp() async throws {
        let mock = MockAgentRuntime()
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(Agent(
            id: "test", name: "Test", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        let tmpDir = try makeTemporaryDirectory(prefix: "kiteloop-delete-session")
        vm = ChatViewModel(agentID: "test", projectURL: tmpDir, orchestrator: orchestrator)
        try await orchestrator.startAgent("test", cwd: tmpDir)
        store = SessionStore(projectDir: tmpDir)
    }

    /// A chat with a title and a messages file on disk.
    private func makeSession(_ title: String) throws -> ChatSession {
        var session = store.createSession(agentID: "test")
        session.title = title
        store.updateSession(session)
        try SessionStore.writeMessages([Message(
            id: UUID(), timestamp: .now, sender: .human, content: .text(title)
        )], to: store.messagesURL(for: session), keepingLeading: 0)
        return session
    }

    private func fileExists(_ session: ChatSession) -> Bool {
        FileManager.default.fileExists(atPath: store.messagesURL(for: session).path)
    }

    func testDeletingAChatThatIsNotOpenLeavesTheOpenOneAlone() async throws {
        let other = try makeSession("Other")
        let open = try makeSession("Open")
        vm.setupSessionStore(store)

        await vm.deleteSession(other)

        XCTAssertEqual(vm.currentSession?.id, open.id)
        XCTAssertEqual(store.sessions(for: "test").map(\.id), [open.id])
        XCTAssertFalse(fileExists(other))
        XCTAssertTrue(fileExists(open))
    }

    func testDeletingTheOpenChatOpensTheNextOne() async throws {
        let next = try makeSession("Next")
        let open = try makeSession("Open")
        vm.setupSessionStore(store)

        await vm.deleteSession(open)

        XCTAssertEqual(vm.currentSession?.id, next.id)
        XCTAssertEqual(store.sessions(for: "test").map(\.id), [next.id])
        XCTAssertEqual(vm.messages.count, 1)
    }

    func testDeletingTheOnlyChatOpensAFreshOne() async throws {
        let only = try makeSession("Only")
        vm.setupSessionStore(store)

        await vm.deleteSession(only)

        let fresh = try XCTUnwrap(vm.currentSession)
        XCTAssertNotEqual(fresh.id, only.id)
        XCTAssertTrue(fresh.isUntitled)
        XCTAssertEqual(store.sessions(for: "test").map(\.id), [fresh.id])
        XCTAssertTrue(vm.messages.isEmpty)
    }

    func testTheDeletedOpenChatIsNotWrittenBack() async throws {
        let next = try makeSession("Next")
        let open = try makeSession("Open")
        vm.setupSessionStore(store)
        // Opened through a switch, so its messages are loaded and would be
        // what a save wrote back.
        await vm.switchToSession(next)
        await vm.switchToSession(open)
        XCTAssertEqual(vm.messages.count, 1)

        await vm.deleteSession(open)

        XCTAssertFalse(fileExists(open))
        XCTAssertFalse(store.sessions(for: "test").contains { $0.id == open.id })
    }
}
