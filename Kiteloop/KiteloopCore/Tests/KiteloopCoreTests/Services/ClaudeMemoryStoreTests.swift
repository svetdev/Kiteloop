import XCTest
import KiteloopTestSupport
@testable import KiteloopCore

final class ClaudeMemoryStoreTests: XCTestCase {
    private var config: URL!
    private var project: URL!

    override func setUpWithError() throws {
        let base = try makeTemporaryDirectory()
        config = base.appending(path: "claude")
        project = base.appending(path: "work/my.project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    private func makeStore(at root: URL? = nil) -> ClaudeMemoryStore {
        ClaudeMemoryStore(projectRoot: root ?? project, configDirectory: config)
    }

    private func write(_ text: String, as name: String, in store: ClaudeMemoryStore) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try text.write(to: store.directory.appending(path: name), atomically: true, encoding: .utf8)
    }

    func testAPathBecomesTheFolderNameTheCLIGivesIt() {
        XCTAssertEqual(
            ClaudeMemoryStore.slug(for: "/Users/someone/Documents/my.project/.kiteloop/work_1/"),
            "-Users-someone-Documents-my-project--kiteloop-work-1"
        )
    }

    func testTheFolderIsUnderTheCLIsProjectsByTheProjectsResolvedPath() throws {
        let real = try XCTUnwrap(realpath(project.path(percentEncoded: false), nil))
        defer { free(real) }
        XCTAssertEqual(
            makeStore().directory.path(percentEncoded: false),
            config.appending(path: "projects/\(ClaudeMemoryStore.slug(for: String(cString: real)))/memory").path(percentEncoded: false)
        )
    }

    func testAProjectOnASubfolderSharesItsRepositorysMemory() throws {
        try FileManager.default.createDirectory(at: project.appending(path: ".git"), withIntermediateDirectories: true)
        let sub = project.appending(path: "packages/app")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(makeStore(at: sub).directory, makeStore().directory)
    }

    func testALinkedWorktreeSharesItsMainCheckoutsMemory() throws {
        try FileManager.default.createDirectory(at: project.appending(path: ".git/worktrees/side"), withIntermediateDirectories: true)
        let worktree = project.deletingLastPathComponent().appending(path: "side")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(project.path(percentEncoded: false))/.git/worktrees/side\n"
            .write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(makeStore(at: worktree).directory, makeStore().directory)
    }

    func testTheConfigFolderFollowsTheEnvironmentWhenItIsSet() {
        XCTAssertEqual(
            ClaudeMemoryStore.configDirectory(environment: ["CLAUDE_CONFIG_DIR": "/opt/claude"]).path(percentEncoded: false),
            "/opt/claude"
        )
        XCTAssertTrue(ClaudeMemoryStore.configDirectory(environment: [:]).path(percentEncoded: false).hasSuffix("/.claude"))
    }

    func testAProjectNobodyHasChattedInHasNoNotes() {
        XCTAssertEqual(makeStore().notes(), [])
    }

    func testNotesListTheIndexFirstThenByName() throws {
        let store = makeStore()
        try write("- [Zed](zed.md) — z\n", as: "MEMORY.md", in: store)
        try write("---\nname: zed\ndescription: last\nmetadata:\n  type: project\n---\n\nZ body\n", as: "zed.md", in: store)
        try write("---\nname: Alpha\ndescription: first\ntype: feedback\n---\nA body", as: "b-file.md", in: store)
        try write("not a note", as: "notes.txt", in: store)

        let notes = store.notes()
        XCTAssertEqual(notes.map(\.id), ["MEMORY", "b-file", "zed"])
        XCTAssertTrue(notes[0].isIndex)
        XCTAssertEqual(notes[0].name, "MEMORY.md")
        XCTAssertEqual(notes[1].name, "Alpha")
        XCTAssertEqual(notes[1].summary, "first")
        XCTAssertEqual(notes[1].kind, "feedback")
        XCTAssertEqual(notes[1].body, "A body")
        XCTAssertEqual(notes[2].kind, "project")
        XCTAssertEqual(notes[2].body, "Z body")
    }

    func testANoteWithoutFrontMatterIsNamedByItsFileAndIsAllBody() {
        let note = ClaudeMemoryNote(id: "loose", text: "just text")
        XCTAssertEqual(note.name, "loose")
        XCTAssertNil(note.summary)
        XCTAssertNil(note.kind)
        XCTAssertEqual(note.body, "just text")
    }

    func testSavingReplacesOneFilesText() throws {
        let store = makeStore()
        try write("old", as: "a.md", in: store)
        try write("other", as: "b.md", in: store)
        try store.save(id: "a", text: "new")
        XCTAssertEqual(store.text(of: "a"), "new")
        XCTAssertEqual(store.text(of: "b"), "other")
    }

    func testDeletingANoteRemovesItsFileAndItsIndexLine() throws {
        let store = makeStore()
        try write("# Index\n- [A](a.md) — one\n- [B](b.md) — two\n", as: "MEMORY.md", in: store)
        try write("a", as: "a.md", in: store)
        try write("b", as: "b.md", in: store)

        try store.delete(id: "a")

        XCTAssertNil(store.text(of: "a"))
        XCTAssertEqual(store.text(of: "MEMORY"), "# Index\n- [B](b.md) — two\n")
        XCTAssertEqual(store.text(of: "b"), "b")
    }

    func testTheIndexIsNeverDeleted() throws {
        let store = makeStore()
        try write("index", as: "MEMORY.md", in: store)
        try store.delete(id: "MEMORY")
        XCTAssertEqual(store.text(of: "MEMORY"), "index")
    }

    func testDeletingANoteThatIsGoneThrows() {
        XCTAssertThrowsError(try makeStore().delete(id: "missing"))
    }
}
