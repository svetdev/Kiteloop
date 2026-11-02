import XCTest
@testable import KiteloopCore

final class ChatSessionTests: XCTestCase {

    /// A session is untitled on either spelling of "no title yet": the default
    /// placeholder, or nothing at all.
    func testDefaultTitleIsUntitled() {
        XCTAssertTrue(ChatSession(agentID: "a").isUntitled)
        XCTAssertTrue(ChatSession(agentID: "a", title: "New Chat").isUntitled)
    }

    func testEmptyTitleIsUntitled() {
        XCTAssertTrue(ChatSession(agentID: "a", title: "").isUntitled)
    }

    /// Once someone — or the first message — has named it, it is titled, even
    /// when the name is close to the placeholder.
    func testRealTitleIsNotUntitled() {
        XCTAssertFalse(ChatSession(agentID: "a", title: "Fix the build").isUntitled)
        XCTAssertFalse(ChatSession(agentID: "a", title: "New Chat 2").isUntitled)
        XCTAssertFalse(ChatSession(agentID: "a", title: "new chat").isUntitled)
    }

    /// Renaming moves the session across the line in both directions.
    func testRetitlingChangesUntitled() {
        var session = ChatSession(agentID: "a")
        XCTAssertTrue(session.isUntitled)
        session.title = "Wave data sources"
        XCTAssertFalse(session.isUntitled)
        session.title = ""
        XCTAssertTrue(session.isUntitled)
    }

    /// An unsent draft is part of what the index keeps for a chat.
    func testDraftSurvivesARoundTrip() throws {
        var session = ChatSession(agentID: "a")
        session.draft = "half a message"
        let decoded = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.draft, "half a message")
        XCTAssertEqual(decoded, session)
    }

    /// An index written before drafts were kept has no draft key.
    func testIndexWithoutADraftDecodesWithNone() throws {
        let json = """
        {"id":"\(UUID().uuidString)","agentID":"a","createdAt":0,"title":"Old chat",
         "lastMessageAt":0,"messageCount":2,"claudeSessionID":"s-1"}
        """
        let decoded = try JSONDecoder().decode(ChatSession.self, from: Data(json.utf8))
        XCTAssertNil(decoded.draft)
        XCTAssertEqual(decoded.title, "Old chat")
    }
}
