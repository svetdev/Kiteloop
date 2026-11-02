import XCTest
import KiteloopCore
@testable import Kiteloop

/// A Traces session names the chat it was recorded in: its CLI session id is
/// matched against the chats' `claudeSessionID`, and one no chat carries reads
/// as it always did.
@MainActor
final class TraceViewModelChatTitleTests: XCTestCase {

    // MARK: - The view model

    func testASessionAChatCarriesIsLabelledWithThatChatsTitle() {
        let viewModel = TraceViewModel(store: EmptyTraceStore(), chatTitle: { $0 == "cli-1" ? "Fix the login bug" : nil })

        XCTAssertEqual(viewModel.chatTitle(forSessionID: "cli-1"), "Fix the login bug")
    }

    func testASessionNoChatCarriesHasNoTitle() {
        let viewModel = TraceViewModel(store: EmptyTraceStore(), chatTitle: { $0 == "cli-1" ? "Fix the login bug" : nil })

        XCTAssertNil(viewModel.chatTitle(forSessionID: "cli-old"))
    }

    func testABlankTitleCountsAsNoTitle() {
        let viewModel = TraceViewModel(store: EmptyTraceStore(), chatTitle: { _ in "  " })

        XCTAssertNil(viewModel.chatTitle(forSessionID: "cli-1"))
    }

    func testTheDefaultLookupNamesNoChat() {
        let viewModel = TraceViewModel(store: EmptyTraceStore())

        XCTAssertNil(viewModel.chatTitle(forSessionID: "cli-1"))
    }

    // MARK: - The session store lookup

    func testTheLookupReadsTheStoreWhenAskedNotWhenBuilt() throws {
        let dir = try makeTemporaryDirectory(prefix: "trace-chat-title")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(projectDir: dir, log: { _ in })
        let viewModel = TraceViewModel(store: EmptyTraceStore(), chatTitle: ProjectSession.traceChatTitle(store))
        XCTAssertNil(viewModel.chatTitle(forSessionID: "cli-1"), "No chat carries the id yet")

        var chat = store.createSession(agentID: "dev")
        chat.claudeSessionID = "cli-1"
        chat.title = "First title"
        store.updateSession(chat)
        XCTAssertEqual(viewModel.chatTitle(forSessionID: "cli-1"), "First title", "A chat added after construction is named")

        chat.title = "Renamed"
        store.updateSession(chat)
        XCTAssertEqual(viewModel.chatTitle(forSessionID: "cli-1"), "Renamed", "A rename after construction is seen")
    }

    func testAChatWithoutACLISessionIDMatchesNothing() throws {
        let dir = try makeTemporaryDirectory(prefix: "trace-chat-title")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(projectDir: dir, log: { _ in })
        var chat = store.createSession(agentID: "dev")
        chat.title = "Never sent"
        store.updateSession(chat)

        let lookup = ProjectSession.traceChatTitle(store)

        XCTAssertNil(lookup(""))
        XCTAssertNil(lookup("unknown"))
    }
}

/// A `TraceStoring` with nothing in it: these tests ask only about titles.
private actor EmptyTraceStore: TraceStoring {
    func loadSpans(for date: Date) async -> [TraceSpan] { [] }
    func loadSpans(for agentID: String) async -> [TraceSpan] { [] }
    func allSessions() async -> [TraceSession] { [] }
}
