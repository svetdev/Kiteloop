import XCTest
@testable import KiteloopCore

/// The two halves of a session's history the store computes from its messages:
/// the title a session gets before anything generates a better one, and reading
/// the messages back — JSONL today, the JSON array older stores wrote, a tail of
/// the last N either way. Each case drives its own temporary project directory.
final class SessionStoreMessagesTests: XCTestCase {
    private var projectDir: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        projectDir = try makeTemporaryDirectory(prefix: "session-messages")
        store = SessionStore(projectDir: projectDir) { _ in }
    }

    /// The text of each message; `Message.Content` is not Equatable.
    private func texts(_ messages: [Message]) -> [String] {
        messages.compactMap { if case .text(let t) = $0.content { return t } else { return nil } }
    }

    private func message(_ text: String, from sender: Message.Sender = .human) -> Message {
        Message(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000), sender: sender, content: .text(text))
    }

    // MARK: - The heuristic title

    func testTheTitleIsTheFirstHumanLine() {
        let title = store.generateTitle(from: [message("hello agent", from: .agent("a")), message("fix the build"), message("then deploy")])
        XCTAssertEqual(title, "fix the build")
    }

    func testALeadingBlankLineIsNotTheTitle() {
        XCTAssertEqual(store.generateTitle(from: [message("\n  \nfix the build")]), "fix the build")
    }

    func testInnerNewlinesAreJoinedBySingleSpaces() {
        let title = store.generateTitle(from: [message("```swift\nlet x = 1\n\n\tprint(x)\n```")])
        XCTAssertEqual(title, "```swift let x = 1 print(x) ```")
        XCTAssertFalse(title.contains("\n"))
    }

    func testAWhitespaceOnlyFirstMessageFallsThroughToTheNext() {
        XCTAssertEqual(store.generateTitle(from: [message(" \n\t "), message("then deploy")]), "then deploy")
        XCTAssertEqual(store.generateTitle(from: [message(" \n\t ")]), "New Chat")
    }

    func testALongFirstLineIsCutToFiftyWithAnEllipsis() {
        let long = String(repeating: "x", count: 80)
        let title = store.generateTitle(from: [message(long)])
        XCTAssertEqual(title.count, 50)
        XCTAssertTrue(title.hasSuffix("..."))
        XCTAssertEqual(title, String(repeating: "x", count: 47) + "...")
    }

    func testExactlyFiftyCharactersIsKeptWhole() {
        let fifty = String(repeating: "y", count: 50)
        XCTAssertEqual(store.generateTitle(from: [message(fifty)]), fifty)
    }

    func testNoHumanTextIsANewChat() {
        XCTAssertEqual(store.generateTitle(from: []), "New Chat")
        XCTAssertEqual(store.generateTitle(from: [message("only the agent spoke", from: .agent("a"))]), "New Chat")
    }

    // MARK: - Reading messages back

    private func write(_ text: String, for session: ChatSession) throws {
        let url = store.messagesURL(for: session)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func jsonl(_ messages: [Message]) throws -> String {
        try messages.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }

    func testJSONLLinesAreReadInOrder() throws {
        let session = ChatSession(agentID: "alpha")
        try write(try jsonl([message("one"), message("two"), message("three")]), for: session)
        XCTAssertEqual(texts(store.loadMessages(for: session)), ["one", "two", "three"])
    }

    func testTheLimitKeepsTheNewestLines() throws {
        let session = ChatSession(agentID: "alpha")
        try write(try jsonl((1...5).map { message("m\($0)") }), for: session)
        XCTAssertEqual(texts(store.loadMessages(for: session, limit: 2)), ["m4", "m5"])
        XCTAssertEqual(store.loadAllMessages(for: session).count, 5)
    }

    func testALegacyJSONArrayIsStillRead() throws {
        let session = ChatSession(agentID: "alpha")
        let array = String(decoding: try JSONEncoder().encode([message("old"), message("older")]), as: UTF8.self)
        try write(array, for: session)
        XCTAssertEqual(texts(store.loadMessages(for: session)), ["old", "older"])
        XCTAssertEqual(texts(store.loadMessages(for: session, limit: 1)), ["older"])
    }

    func testAnUndecodableArrayReadsAsNothing() throws {
        let session = ChatSession(agentID: "alpha")
        try write("[{\"not\": \"a message\"}]", for: session)
        XCTAssertEqual(store.loadMessages(for: session).count, 0)
    }

    func testAMissingOrEmptyFileReadsAsNothing() throws {
        let session = ChatSession(agentID: "alpha")
        XCTAssertEqual(store.loadMessages(for: session).count, 0, "no file yet")
        try write("", for: session)
        XCTAssertEqual(store.loadMessages(for: session).count, 0, "an empty file")
    }

    func testAnUndecodableLineIsSkippedNotFatal() throws {
        let session = ChatSession(agentID: "alpha")
        try write(try jsonl([message("good")]) + "{broken\n" + (try jsonl([message("also good")])), for: session)
        XCTAssertEqual(texts(store.loadMessages(for: session)), ["good", "also good"])
    }

    /// Writes `text` with every `marker` replaced by the single byte 0xFF,
    /// which is not valid UTF-8 anywhere.
    private func writeBytes(_ text: String, badByteAt marker: String, for session: ChatSession) throws {
        let url = store.messagesURL(for: session)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let parts = text.components(separatedBy: marker)
        let data = parts.dropFirst().reduce(Data(parts[0].utf8)) { $0 + Data([0xFF]) + Data($1.utf8) }
        try data.write(to: url)
    }

    func testOneInvalidByteInAMessageKeepsEveryMessage() throws {
        let session = ChatSession(agentID: "alpha")
        try writeBytes(try jsonl([message("first"), message("mid@@dle"), message("third")]), badByteAt: "@@", for: session)
        XCTAssertEqual(texts(store.loadMessages(for: session)), ["first", "mid\u{FFFD}dle", "third"])
    }

    func testALineThatIsNeitherUTF8NorJSONIsSkipped() throws {
        let session = ChatSession(agentID: "alpha")
        let text = try jsonl([message("one")]) + "{bro@@ken\n" + (try jsonl([message("two"), message("three")]))
        try writeBytes(text, badByteAt: "@@", for: session)
        XCTAssertEqual(texts(store.loadMessages(for: session)), ["one", "two", "three"])
    }

    // MARK: - Saving what a limited load read

    private func save(_ messages: [Message], for session: ChatSession, keepingLeading leftOut: Int) throws {
        try SessionStore.writeMessages(messages, to: store.messagesURL(for: session), keepingLeading: leftOut)
    }

    private func fileLines(for session: ChatSession) throws -> [Data] {
        let data = try Data(contentsOf: store.messagesURL(for: session))
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
    }

    func testSavingATailPlusOneKeepsTheHeadByteForByte() throws {
        let session = ChatSession(agentID: "alpha")
        try write(try jsonl((1...700).map { message("m\($0)") }), for: session)
        let original = try fileLines(for: session)

        let loaded = store.loadMessageTail(for: session, limit: 500)
        XCTAssertEqual(loaded.messages.count, 500)
        XCTAssertEqual(loaded.leftOut, 200)
        try save(loaded.messages + [message("new")], for: session, keepingLeading: loaded.leftOut)

        let saved = try fileLines(for: session)
        XCTAssertEqual(saved.count, 701)
        XCTAssertEqual(Array(saved.prefix(200)), Array(original.prefix(200)))
        XCTAssertEqual(texts(store.loadAllMessages(for: session)), (1...700).map { "m\($0)" } + ["new"])
    }

    func testSavingTheLoadedTailUnchangedLeavesTheHistoryAsItWas() throws {
        let session = ChatSession(agentID: "alpha")
        let originals = (1...700).map { message("m\($0)") }
        try write(try jsonl(originals), for: session)

        let loaded = store.loadMessageTail(for: session, limit: 500)
        try save(loaded.messages, for: session, keepingLeading: loaded.leftOut)

        let reloaded = store.loadAllMessages(for: session)
        XCTAssertEqual(reloaded.map(\.id), originals.map(\.id))
        XCTAssertEqual(texts(reloaded), texts(originals))
    }

    func testUnderTheLimitASaveWritesExactlyWhatIsInMemory() throws {
        let session = ChatSession(agentID: "alpha")
        try write(try jsonl([message("one"), message("two"), message("three")]), for: session)

        let loaded = store.loadMessageTail(for: session, limit: 500)
        XCTAssertEqual(loaded.leftOut, 0)
        try save(Array(loaded.messages.dropLast()), for: session, keepingLeading: loaded.leftOut)

        XCTAssertEqual(texts(store.loadAllMessages(for: session)), ["one", "two"])
    }

    func testALegacyArrayOverTheLimitKeepsItsHeadWhenSaved() throws {
        let session = ChatSession(agentID: "alpha")
        let originals = (1...7).map { message("m\($0)") }
        try write(String(decoding: try JSONEncoder().encode(originals), as: UTF8.self), for: session)

        let loaded = store.loadMessageTail(for: session, limit: 5)
        XCTAssertEqual(loaded.leftOut, 2)
        try save(loaded.messages + [message("new")], for: session, keepingLeading: loaded.leftOut)

        let reloaded = store.loadAllMessages(for: session)
        XCTAssertEqual(texts(reloaded), (1...7).map { "m\($0)" } + ["new"])
        XCTAssertEqual(Array(reloaded.prefix(7).map(\.id)), originals.map(\.id))
        XCTAssertEqual(try Data(contentsOf: store.messagesURL(for: session)).first, UInt8(ascii: "{"), "converted to JSONL")
    }

    // MARK: - The branch sidecar

    private func branch(_ name: String, _ messages: [Message]) -> ConversationBranch {
        ConversationBranch(id: UUID(), name: name, parentMessageID: UUID(),
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000), messages: messages)
    }

    func testSavedBranchesComeBackThroughAFreshStore() throws {
        let session = store.createSession(agentID: "alpha")
        let first = branch("first", [message("a1")])
        let second = branch("second", [message("b1"), message("b2")])
        let main = [message("m1"), message("m2"), message("m3")]
        try store.saveBranches(ConversationBranchSnapshot(branches: [first, second], activeBranchID: second.id,
                                                          mainMessages: main), for: session)

        let loaded = try XCTUnwrap(SessionStore(projectDir: projectDir) { _ in }.loadBranches(for: session))
        XCTAssertEqual(loaded.branches.map(\.id), [first.id, second.id])
        XCTAssertEqual(loaded.branches.map(\.name), ["first", "second"])
        XCTAssertEqual(loaded.branches.map { texts($0.messages) }, [["a1"], ["b1", "b2"]])
        XCTAssertEqual(loaded.branches.map { $0.messages.map(\.id) }, [first.messages.map(\.id), second.messages.map(\.id)])
        XCTAssertEqual(loaded.activeBranchID, second.id)
        XCTAssertEqual(loaded.mainMessages.map(\.id), main.map(\.id))
        XCTAssertEqual(texts(loaded.mainMessages), ["m1", "m2", "m3"])
    }

    func testASessionThatNeverSavedBranchesLoadsNone() {
        XCTAssertNil(store.loadBranches(for: store.createSession(agentID: "alpha")))
    }

    func testAnUnreadableSidecarLoadsAsNoneAndIsLeftAsItWas() throws {
        var reported: [String] = []
        let store = SessionStore(projectDir: projectDir) { reported.append($0) }
        let session = store.createSession(agentID: "alpha")
        let url = store.branchesURL(for: session)
        let garbage = Data("not json {".utf8)
        try garbage.write(to: url)

        XCTAssertNil(store.loadBranches(for: session))
        XCTAssertEqual(try Data(contentsOf: url), garbage)
        XCTAssertEqual(reported.count, 1)
    }

    func testDeletingASessionRemovesItsTranscriptAndSidecar() throws {
        let session = store.createSession(agentID: "alpha")
        try write(try jsonl([message("one")]), for: session)
        try store.saveBranches(ConversationBranchSnapshot(branches: [branch("b", [])], activeBranchID: nil,
                                                          mainMessages: []), for: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.branchesURL(for: session).path(percentEncoded: false)))

        store.deleteSession(session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.messagesURL(for: session).path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.branchesURL(for: session).path(percentEncoded: false)))
    }

    func testSavingNoBranchesLeavesNoSidecar() throws {
        let session = store.createSession(agentID: "alpha")
        let url = store.branchesURL(for: session)
        try store.saveBranches(ConversationBranchSnapshot(branches: [branch("b", [])], activeBranchID: nil,
                                                          mainMessages: []), for: session)
        try store.saveBranches(ConversationBranchSnapshot(branches: [], activeBranchID: nil,
                                                          mainMessages: [message("m")]), for: session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        let fresh = store.createSession(agentID: "alpha")
        try store.saveBranches(ConversationBranchSnapshot(branches: [], activeBranchID: nil, mainMessages: []), for: fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.branchesURL(for: fresh).path(percentEncoded: false)))
    }

    func testARestoredTreeKeepsItsMainMessages() {
        let main = [message("m1"), message("m2")]
        let tree = ConversationTree(mainMessages: main)
        XCTAssertEqual(tree.mainMessages.map(\.id), main.map(\.id))
    }
}
