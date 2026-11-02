import XCTest
import KiteloopCore
@testable import Kiteloop

/// `AgentKnowledgeStore` read `profile.md` and every knowledge file with a strict
/// UTF-8 decode, so one byte that is not UTF-8 dropped the whole trained agent
/// from `agents`, or the whole file from the agent's domain knowledge, silently.
/// Both reads now keep every valid character around a bad byte.
final class AgentKnowledgeStoreLossyReadTests: XCTestCase {
    private var tempDir: URL!
    private var store: AgentKnowledgeStore?

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "agent-knowledge-store-lossy-read-test")
    }

    override func tearDown() async throws {
        store?.stop()
        store = nil
    }

    private func agentDir(_ id: String) throws -> URL {
        let dir = tempDir.appending(path: "agents/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ parts: [Data], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try parts.reduce(Data(), +).write(to: url)
    }

    private func makeStore() -> AgentKnowledgeStore {
        let made = AgentKnowledgeStore(baseURL: tempDir)
        store = made
        return made
    }

    private let badByte = Data([0xFF])

    // MARK: - profile.md

    func testProfileWithABadByteStillLoadsTheAgentByName() throws {
        let dir = try agentDir("reviewer")
        try write([Data("---\nname: Reviewer\nmodel: opus\n---\nYou review ".utf8), badByte, Data(" code.\n".utf8)],
                  to: dir.appending(path: "profile.md"))

        let agents = makeStore().agents

        XCTAssertEqual(agents.map(\.id), ["reviewer"])
        XCTAssertEqual(agents.first?.name, "Reviewer")
        XCTAssertEqual(agents.first?.model, "opus")
        XCTAssertTrue(agents.first?.systemPrompt.contains("code.") == true)
    }

    func testDirectoryWithoutAProfileIsStillLeftOut() throws {
        let dir = try agentDir("no-profile")
        try write([Data("# notes\n".utf8)], to: dir.appending(path: "knowledge/general/notes.md"))

        XCTAssertTrue(makeStore().agents.isEmpty)
    }

    // MARK: - knowledge files

    func testKnowledgeFileWithABadByteKeepsBothLinesUnderItsHeading() throws {
        let dir = try agentDir("reviewer")
        try write([Data("---\nname: Reviewer\n---\nbody\n".utf8)], to: dir.appending(path: "profile.md"))
        try write([Data("first line\n".utf8), badByte, Data("\nsecond line\n".utf8)],
                  to: dir.appending(path: "knowledge/swift/style.md"))

        let content = try XCTUnwrap(makeStore().knowledgeContent(for: "reviewer"))

        let heading = try XCTUnwrap(content.range(of: "## style.md"))
        let after = content[heading.upperBound...]
        XCTAssertTrue(after.contains("first line"))
        XCTAssertTrue(after.contains("second line"))
    }

    func testWhitespaceOnlyKnowledgeFileIsStillLeftOut() throws {
        let dir = try agentDir("reviewer")
        try write([Data("---\nname: Reviewer\n---\nbody\n".utf8)], to: dir.appending(path: "profile.md"))
        try write([Data("  \n\t\n".utf8)], to: dir.appending(path: "knowledge/swift/blank.md"))
        try write([Data("kept\n".utf8)], to: dir.appending(path: "knowledge/swift/kept.md"))

        let content = try XCTUnwrap(makeStore().knowledgeContent(for: "reviewer"))

        XCTAssertFalse(content.contains("## blank.md"))
        XCTAssertTrue(content.contains("## kept.md"))
    }
}
