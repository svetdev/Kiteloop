import XCTest
@testable import KiteloopCore

/// `SessionStore` holds the chat history of every agent in a project, and until
/// now nothing asserted any of it.
///
/// The failure these cases exist for: `loadAll()` decoded each agent's
/// `index.json` with `try?` and, when the decoder refused, simply skipped the
/// directory — `sessions[agentID]` was never set, nothing was logged, and the
/// first `createSession` for that agent wrote a one-element list over the file.
/// The history was gone, with no error and no salvage. The unreadable index is
/// now moved aside before the new one is written, so the sessions it held are
/// still on disk.
///
/// Every case drives an injected temporary project directory through the
/// store's own `init(projectDir:)`; nothing here reads or writes a real project.
final class SessionStoreTests: XCTestCase {

    private var projectDir: URL!
    private var sessionsDir: URL!
    /// What the store reported, in the order it reported it.
    private var logged: [String] = []

    override func setUpWithError() throws {
        projectDir = try makeTemporaryDirectory(prefix: "session-store")
        sessionsDir = projectDir.appending(path: ".kiteloop/sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        logged = []
    }

    // MARK: - A readable index

    func testASessionSavedByOneStoreIsLoadedByTheNext() throws {
        let store = makeStore()
        let created = store.createSession(agentID: "builder")

        let reloaded = makeStore()

        XCTAssertEqual(reloaded.sessions(for: "builder").map(\.id), [created.id])
        XCTAssertEqual(logged, [], "a round trip reports nothing")
    }

    func testLoadSortsNewestFirstAndKeepsTitles() throws {
        try writeIndex(for: "builder", [
            session(title: "older", lastMessageAt: .distantPast, messageCount: 3),
            session(title: "newer", lastMessageAt: .distantFuture, messageCount: 7),
        ])

        let store = makeStore()

        XCTAssertEqual(store.sessions(for: "builder").map(\.title), ["newer", "older"])
        XCTAssertEqual(store.unreadableIndexAgentIDs, [])
    }

    func testUpdateAndDeleteReachDisk() throws {
        let store = makeStore()
        var created = store.createSession(agentID: "builder")
        created.title = "named"
        store.updateSession(created)

        XCTAssertEqual(makeStore().sessions(for: "builder").map(\.title), ["named"])

        store.deleteSession(created)

        XCTAssertEqual(makeStore().sessions(for: "builder"), [])
    }

    // MARK: - Order while the app runs

    /// A chat talked in again moves to the top straight away, not only after a
    /// relaunch re-sorts the index.
    func testUpdatingTheOldestSessionWithALaterMessageMovesItFirst() throws {
        let store = try makeStoreWithThreeSessions()
        var oldest = try XCTUnwrap(store.sessions(for: "builder").last)
        oldest.lastMessageAt = Date(timeIntervalSince1970: 4_000)

        store.updateSession(oldest)

        XCTAssertEqual(store.sessions(for: "builder").map(\.title), ["oldest", "newest", "middle"])
    }

    func testTheOrderAfterAnUpdateIsTheOrderARelaunchLoads() throws {
        let store = try makeStoreWithThreeSessions()
        var middle = store.sessions(for: "builder")[1]
        middle.lastMessageAt = Date(timeIntervalSince1970: 4_000)

        store.updateSession(middle)

        XCTAssertEqual(store.sessions(for: "builder").map(\.id), makeStore().sessions(for: "builder").map(\.id))
    }

    func testARenameThatKeepsTheTimeLeavesTheOrderAlone() throws {
        let store = try makeStoreWithThreeSessions()
        let before = store.sessions(for: "builder").map(\.id)
        var oldest = try XCTUnwrap(store.sessions(for: "builder").last)
        oldest.title = "renamed"

        store.updateSession(oldest)

        XCTAssertEqual(store.sessions(for: "builder").map(\.id), before)
        XCTAssertEqual(store.sessions(for: "builder").last?.title, "renamed")
    }

    // MARK: - The durable write

    /// The index goes through `AtomicFileWriter`, which writes a temp sibling,
    /// forces it to the platter and renames it into place — so what a finished
    /// save leaves in the directory is the index and nothing else. A temp file
    /// still sitting there would mean the rename never happened and the bytes on
    /// disk are not the ones the store thinks it wrote.
    func testASaveLeavesTheIndexAloneInTheDirectory() throws {
        let store = makeStore()
        let created = store.createSession(agentID: "builder")

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: sessionsDir.appending(path: "builder").path(percentEncoded: false)
            ),
            ["index.json"],
            "no temp sibling left behind"
        )
        let written = try JSONDecoder()
            .decode([ChatSession].self, from: Data(contentsOf: indexURL(for: "builder")))
        XCTAssertEqual(written.map(\.id), [created.id])
    }

    /// A save into a directory the store may not write to used to go through
    /// `try? data.write(to:)`: the sessions stayed on screen, the file on disk
    /// stayed stale, and nothing anywhere said so.
    func testASaveThatCannotLandIsReportedRatherThanDropped() throws {
        let store = makeStore()
        var created = store.createSession(agentID: "builder")
        let agentDir = sessionsDir.appending(path: "builder").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: agentDir)
        // Restored so the directory can be torn down again.
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agentDir) }
        let before = logged.count

        created.title = "named"
        store.updateSession(created)

        XCTAssertEqual(logged.count, before + 1, "the failed save is reported once: \(logged)")
        let line = try XCTUnwrap(logged.last)
        XCTAssertTrue(line.hasPrefix("builder:"), "the line names the agent: \(line)")
        XCTAssertTrue(
            line.contains(indexURL(for: "builder").path(percentEncoded: false)),
            "the line names the file: \(line)"
        )
        // What the user is looking at is the new title; what is on disk is not,
        // which is exactly the gap the line has to report.
        XCTAssertEqual(store.sessions(for: "builder").map(\.title), ["named"])
        let onDisk = try JSONDecoder()
            .decode([ChatSession].self, from: Data(contentsOf: indexURL(for: "builder")))
        XCTAssertEqual(onDisk.map(\.title), ["New Chat"], "the previous index is intact")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: agentDir), ["index.json"],
            "a failed write cleans up after itself"
        )
    }

    // MARK: - The prune of empty sessions past the first

    /// Every empty session but the newest is dropped at load, along with its
    /// message file, and the pruned list is written back.
    func testLoadPrunesEmptySessionsPastTheFirstAndWritesTheResultBack() throws {
        let newestEmpty = session(title: "newest empty", lastMessageAt: .distantFuture, messageCount: 0)
        let olderEmpty = session(title: "older empty", lastMessageAt: .distantPast, messageCount: 0)
        let withMessages = session(title: "has messages", lastMessageAt: Date(), messageCount: 4)
        try writeIndex(for: "builder", [newestEmpty, olderEmpty, withMessages])
        let olderMessages = sessionsDir
            .appending(path: "builder/\(olderEmpty.id.uuidString).json")
        try Data("[]".utf8).write(to: olderMessages)

        let store = makeStore()

        XCTAssertEqual(store.sessions(for: "builder").map(\.title), ["newest empty", "has messages"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: olderMessages.path(percentEncoded: false)),
            "the pruned session's messages go with it"
        )
        XCTAssertEqual(
            makeStore().sessions(for: "builder").map(\.title), ["newest empty", "has messages"],
            "the prune was written back, not just applied in memory"
        )
        XCTAssertEqual(logged, [], "a prune is ordinary housekeeping and reports nothing")
    }

    /// An older empty session holding an unsent draft is kept, draft and all;
    /// one whose draft is only whitespace is pruned as if it had none.
    func testLoadKeepsAnOlderEmptySessionThatHoldsADraft() throws {
        let newestEmpty = session(title: "newest empty", lastMessageAt: .distantFuture, messageCount: 0)
        var withDraft = session(title: "has draft", lastMessageAt: .distantPast, messageCount: 0)
        withDraft.draft = "fix the build\nand then deploy"
        var blankDraft = session(title: "blank draft", lastMessageAt: .distantPast, messageCount: 0)
        blankDraft.draft = "  \n\t "
        let withMessages = session(title: "has messages", lastMessageAt: Date(), messageCount: 4)
        try writeIndex(for: "builder", [newestEmpty, withDraft, blankDraft, withMessages])
        let blankMessages = sessionsDir
            .appending(path: "builder/\(blankDraft.id.uuidString).json")
        try Data("[]".utf8).write(to: blankMessages)

        let store = makeStore()

        XCTAssertEqual(
            Set(store.sessions(for: "builder").map(\.title)), ["newest empty", "has draft", "has messages"]
        )
        XCTAssertEqual(
            store.sessions(for: "builder").first { $0.id == withDraft.id }?.draft,
            "fix the build\nand then deploy"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: blankMessages.path(percentEncoded: false)),
            "a whitespace-only draft is no draft, so that session is pruned with its messages"
        )
        let reloaded = makeStore().sessions(for: "builder")
        XCTAssertEqual(
            Set(reloaded.map(\.title)), ["newest empty", "has draft", "has messages"],
            "the saved index kept the session holding a draft"
        )
        XCTAssertEqual(reloaded.first { $0.id == withDraft.id }?.draft, "fix the build\nand then deploy")
    }

    // MARK: - An index the decoder refuses

    func testAnUnreadableIndexIsReportedOnceNamingTheAgentAndThePath() throws {
        try writeRawIndex(for: "builder", "this is not JSON at all")

        let store = makeStore()

        XCTAssertEqual(store.unreadableIndexAgentIDs, ["builder"])
        XCTAssertEqual(logged.count, 1, "reported once per load, got \(logged)")
        let line = try XCTUnwrap(logged.first)
        // The path names the agent's directory too, so the agent id is asserted
        // where only the line's own wording can put it.
        XCTAssertTrue(line.hasPrefix("builder:"), "the line names the agent: \(line)")
        XCTAssertTrue(
            line.contains(indexURL(for: "builder").path(percentEncoded: false)),
            "the line names the file: \(line)"
        )
    }

    /// Reading is not repairing: a launch that only looked at the sessions
    /// leaves the file exactly where it was.
    func testLoadAloneMovesTheUnreadableIndexNowhere() throws {
        try writeRawIndex(for: "builder", "this is not JSON at all")

        _ = makeStore()

        XCTAssertEqual(try contents(of: indexURL(for: "builder")), "this is not JSON at all")
        XCTAssertFalse(FileManager.default.fileExists(atPath: asidePath(for: "builder")))
    }

    func testTheFirstSaveMovesTheUnreadableIndexAsideWithItsBytesIntact() throws {
        let original = #"[{"id": "not a uuid"}]"#
        try writeRawIndex(for: "builder", original)
        let store = makeStore()

        let created = store.createSession(agentID: "builder")

        XCTAssertEqual(
            try contents(of: URL(fileURLWithPath: asidePath(for: "builder"))), original,
            "the unreadable index is still on disk, verbatim"
        )
        let written = try JSONDecoder()
            .decode([ChatSession].self, from: Data(contentsOf: indexURL(for: "builder")))
        XCTAssertEqual(written.map(\.id), [created.id], "the new index holds only the new session")
    }

    /// The point of moving it aside rather than refusing forever: the store is
    /// usable again immediately, and the next save is an ordinary one.
    func testTheSecondSaveAfterAMoveMovesNothingAndReportsNothingFurther() throws {
        try writeRawIndex(for: "builder", "not JSON")
        let store = makeStore()
        let first = store.createSession(agentID: "builder")
        let afterFirstSave = logged.count

        let second = store.createSession(agentID: "builder")

        XCTAssertEqual(store.unreadableIndexAgentIDs, [])
        XCTAssertEqual(logged.count, afterFirstSave, "nothing further to report: \(logged)")
        let written = try JSONDecoder()
            .decode([ChatSession].self, from: Data(contentsOf: indexURL(for: "builder")))
        XCTAssertEqual(Set(written.map(\.id)), [first.id, second.id])
        XCTAssertEqual(
            try FileManager.default
                .contentsOfDirectory(atPath: sessionsDir.appending(path: "builder")
                    .path(percentEncoded: false))
                .filter { $0.hasPrefix("index.json.unreadable") },
            ["index.json.unreadable"],
            "one salvage file, named after the index"
        )
    }

    /// One agent's unreadable index is that agent's problem: the others load and
    /// save as they always did.
    func testAnUnreadableIndexCostsOnlyItsOwnAgent() throws {
        try writeRawIndex(for: "builder", "not JSON")
        try writeIndex(for: "reviewer", [
            session(agentID: "reviewer", title: "kept", lastMessageAt: Date(), messageCount: 2),
        ])

        let store = makeStore()

        XCTAssertEqual(store.sessions(for: "reviewer").map(\.title), ["kept"])
        XCTAssertEqual(store.sessions(for: "builder"), [])
        XCTAssertEqual(store.unreadableIndexAgentIDs, ["builder"])
    }

    // MARK: - No index at all

    func testAnAgentDirectoryWithNoIndexIsSilentAndLeavesNoSalvageFile() throws {
        try FileManager.default.createDirectory(
            at: sessionsDir.appending(path: "builder"), withIntermediateDirectories: true
        )

        let store = makeStore()
        _ = store.createSession(agentID: "builder")

        XCTAssertEqual(store.unreadableIndexAgentIDs, [])
        XCTAssertEqual(logged, [], "a first-launch agent is not a failure")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: asidePath(for: "builder")),
            "nothing was moved aside, because there was nothing to move"
        )
    }

    func testAProjectWithNoSessionsDirectoryComesUpEmpty() throws {
        try FileManager.default.removeItem(at: sessionsDir)

        let store = makeStore()

        XCTAssertEqual(store.sessions, [:])
        XCTAssertEqual(store.unreadableIndexAgentIDs, [])
        XCTAssertEqual(logged, [])
    }

    // MARK: - Helpers

    private func makeStore() -> SessionStore {
        SessionStore(projectDir: projectDir) { [weak self] line in self?.logged.append(line) }
    }

    /// A store holding "newest", "middle" and "oldest" for `builder`, each with
    /// messages so a reload prunes none of them.
    private func makeStoreWithThreeSessions() throws -> SessionStore {
        try writeIndex(for: "builder", [
            session(title: "oldest", lastMessageAt: Date(timeIntervalSince1970: 1_000), messageCount: 1),
            session(title: "middle", lastMessageAt: Date(timeIntervalSince1970: 2_000), messageCount: 1),
            session(title: "newest", lastMessageAt: Date(timeIntervalSince1970: 3_000), messageCount: 1),
        ])
        let store = makeStore()
        XCTAssertEqual(store.sessions(for: "builder").map(\.title), ["newest", "middle", "oldest"])
        return store
    }

    private func indexURL(for agentID: String) -> URL {
        sessionsDir.appending(path: "\(agentID)/index.json")
    }

    private func asidePath(for agentID: String) -> String {
        sessionsDir.appending(path: "\(agentID)/index.json.unreadable")
            .path(percentEncoded: false)
    }

    /// A session with the fields the store sorts and prunes on. `ChatSession`'s
    /// memberwise init is private, so this is the only way to build one.
    private func session(agentID: String = "builder",
                         title: String,
                         lastMessageAt: Date,
                         messageCount: Int) -> ChatSession {
        var s = ChatSession(agentID: agentID, title: title)
        s.lastMessageAt = lastMessageAt
        s.messageCount = messageCount
        return s
    }

    private func writeIndex(for agentID: String, _ sessions: [ChatSession]) throws {
        try writeRawIndex(for: agentID, String(decoding: try JSONEncoder().encode(sessions), as: UTF8.self))
    }

    private func writeRawIndex(for agentID: String, _ contents: String) throws {
        let dir = sessionsDir.appending(path: agentID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: dir.appending(path: "index.json"))
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
