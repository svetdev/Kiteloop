import XCTest
import KiteloopCore
@testable import Kiteloop

/// The workspace and the `CLAUDE.md` describing it are built in one pass, and the
/// two halves used to disagree: the symlink functions skipped a source that was
/// not there, while the listing printed every `knowledge.files` and every
/// `knowledge.imports` entry unconditionally. The agent was told to read paths
/// its own workspace did not contain and burned a turn finding out. These tests
/// hold the listing to what actually linked.
final class WorkspaceGeneratorTests: XCTestCase {
    private var tempDir: URL!
    private var packageURL: URL!
    private var sharedDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "workspace-generator-test")
        packageURL = tempDir.appending(path: "agents/reviewer")
        sharedDir = tempDir.appending(path: "shared")
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL.appending(path: "knowledge"), withIntermediateDirectories: true)
        try fm.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        try "You review.".write(
            to: packageURL.appending(path: "prompt.md"), atomically: true, encoding: .utf8
        )
    }

    // MARK: - What the listing names

    /// The reported bug: a `files` entry with no source behind it. It must leave
    /// the listing, and must not take the files that did link with it.
    func testAKnowledgeFileWithNoSourceIsNotListedWhileTheLinkedOnesAre() throws {
        try writeKnowledge("style.md", "Style.")
        try writeKnowledge("testing.md", "Testing.")
        let agent = resolved(files: ["style.md", "gone.md", "testing.md"])

        let claudeMD = try generateClaudeMD(for: agent)

        XCTAssertTrue(claudeMD.contains("- `./knowledge/style.md`"))
        XCTAssertTrue(claudeMD.contains("- `./knowledge/testing.md`"))
        XCTAssertFalse(
            claudeMD.contains("gone.md"),
            "a file the workspace does not contain must not be advertised as one it does"
        )
        XCTAssertTrue(claudeMD.contains("Important files:"), "the files that linked are still listed")
    }

    /// Every named file missing leaves nothing to list, so the heading goes too —
    /// an `Important files:` with no files under it is not a listing.
    func testAPackageWhoseKnowledgeFilesAllMissDropsTheHeading() throws {
        let claudeMD = try generateClaudeMD(for: resolved(files: ["gone.md"]))

        XCTAssertFalse(claudeMD.contains("Important files:"))
        XCTAssertFalse(claudeMD.contains("gone.md"))
    }

    /// The `- ./shared/` line advertises the directory, so it is gated on an
    /// import having linked rather than on `imports` being non-empty: an empty
    /// `shared/` is one more path the agent reads for nothing.
    func testAnUnresolvedImportRemovesBothItsEntryAndTheSharedDirectoryLine() throws {
        let claudeMD = try generateClaudeMD(for: resolved(imports: ["shared:conventions"]))

        XCTAssertFalse(claudeMD.contains("Shared references:"))
        XCTAssertFalse(claudeMD.contains("conventions"))
        XCTAssertFalse(
            claudeMD.contains("- `./shared/`"),
            "with no import linked there is nothing under shared/ to point at"
        )
    }

    /// One import resolving and one not: the directory line stays, and only the
    /// resolved name is named.
    func testOnlyTheImportsThatLinkedAreListed() throws {
        try writeShared("style", "Shared style.")
        let agent = resolved(imports: ["shared:style", "shared:conventions"])

        let claudeMD = try generateClaudeMD(for: agent)

        XCTAssertTrue(claudeMD.contains("- `./shared/`"))
        XCTAssertTrue(claudeMD.contains("- `./shared/style.md`"))
        XCTAssertFalse(claudeMD.contains("conventions"))
    }

    /// The other half of the contract: nothing changes for a package that
    /// resolves. This is the document the generator produced before the fix.
    func testAPackageWhoseFilesAllResolveIsListedInFull() throws {
        try writeKnowledge("style.md", "Style.")
        try writeKnowledge("facts.md", "The port is 4517.")
        try writeShared("conventions", "Shared conventions.")
        let agent = resolved(
            critical: ["facts.md"],
            files: ["style.md", "facts.md"],
            imports: ["shared:conventions"]
        )

        let claudeMD = try generateClaudeMD(for: agent)

        XCTAssertEqual(claudeMD, """
        # Agent: Reviewer (reviewer)

        You review.

        ## Knowledge

        Your knowledge base is available at:

        - `./knowledge/`
        - `./shared/`

        Use these files when relevant. Do not assume all knowledge is loaded into context.

        Important files:
        - `./knowledge/style.md`
        - `./knowledge/facts.md`

        Shared references:
        - `./shared/conventions.md`

        ## Critical Facts

        The port is 4517.
        """)
    }

    /// A package that names no files at all links whatever the source directory
    /// holds — that shape has never carried an `Important files:` listing, and
    /// the links it makes are still made.
    func testAPackageNamingNoFilesStillLinksTheWholeKnowledgeDirectory() throws {
        try writeKnowledge("style.md", "Style.")
        let agent = resolved()

        let workspace = try generate(agent)

        XCTAssertFalse(try claudeMD(in: workspace).contains("Important files:"))
        XCTAssertEqual(
            try String(contentsOf: workspace.appending(path: "knowledge/style.md"), encoding: .utf8),
            "Style."
        )
    }

    // MARK: - A file with a byte that is not UTF-8

    /// A strict decode used to turn one bad byte into an empty prompt, so the
    /// agent ran with no system prompt at all and nothing said why.
    func testAPromptFileWithOneBadByteStillReachesClaudeMD() throws {
        try (Data("You review.".utf8) + [0xFF] + Data(" Carefully.".utf8))
            .write(to: packageURL.appending(path: "prompt.md"))

        let claudeMD = try generateClaudeMD(for: resolved())

        XCTAssertTrue(claudeMD.contains("You review."))
        XCTAssertTrue(claudeMD.contains("Carefully."))
    }

    /// The file is there and reads; one bad byte is not "could not be read".
    func testACriticalFileWithOneBadByteIsStillACriticalFact() throws {
        try (Data("The port".utf8) + [0xFF] + Data(" is 4517.".utf8))
            .write(to: packageURL.appending(path: "knowledge").appending(path: "facts.md"))
        let logged = LogRecorder()

        let workspace = try generate(resolved(critical: ["facts.md"]), log: logged)

        let claudeMD = try claudeMD(in: workspace)
        let facts = try XCTUnwrap(claudeMD.components(separatedBy: "## Critical Facts").last)
        XCTAssertTrue(claudeMD.contains("## Critical Facts"))
        XCTAssertTrue(facts.contains("The port"))
        XCTAssertTrue(facts.contains(" is 4517."))
        XCTAssertFalse(logged.lines.contains { $0.contains("facts.md") && $0.contains("could not be read") })
    }

    // MARK: - What the listing points at

    /// A listed path is only worth listing if it reads back — the whole point of
    /// the fix is that `CLAUDE.md` describes a workspace the agent can use.
    func testEveryListedKnowledgeFileReadsBackThroughTheWorkspace() throws {
        try writeKnowledge("style.md", "Style.")
        try writeShared("conventions", "Shared conventions.")
        let agent = resolved(files: ["style.md", "gone.md"], imports: ["shared:conventions"])

        let workspace = try generate(agent)

        XCTAssertEqual(
            try String(contentsOf: workspace.appending(path: "knowledge/style.md"), encoding: .utf8),
            "Style."
        )
        XCTAssertEqual(
            try String(contentsOf: workspace.appending(path: "shared/conventions.md"), encoding: .utf8),
            "Shared conventions."
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appending(path: "knowledge/gone.md").path(percentEncoded: false)
        ))
    }

    // MARK: - What is said about a file left out

    /// Silently dropping a file trades one puzzle for another, so each one is
    /// reported once, naming the agent it belongs to and the file itself.
    func testEachSkippedFileIsLoggedOnceNamingTheHandleAndTheFile() throws {
        try writeKnowledge("style.md", "Style.")
        let agent = resolved(
            critical: ["missing-fact.md"],
            files: ["style.md", "gone.md"],
            imports: ["shared:conventions"]
        )
        let logged = LogRecorder()

        _ = try generate(agent, log: logged)

        XCTAssertEqual(logged.lines.filter { $0.contains("gone.md") }.count, 1)
        XCTAssertEqual(logged.lines.filter { $0.contains("conventions.md") }.count, 1)
        XCTAssertEqual(logged.lines.filter { $0.contains("missing-fact.md") }.count, 1)
        XCTAssertFalse(
            logged.lines.contains { $0.contains("style.md") },
            "a file that linked is not a file that was skipped"
        )
        for line in logged.lines {
            XCTAssertTrue(line.contains("reviewer"), "\(line) names no agent")
        }
    }

    /// The source directory missing entirely is the same failure as one file
    /// missing, and is reported the same way rather than in silence.
    func testAPackageWithNoKnowledgeDirectoryReportsEveryNamedFile() throws {
        try FileManager.default.removeItem(at: packageURL.appending(path: "knowledge"))
        let logged = LogRecorder()

        let workspace = try generate(resolved(files: ["style.md", "testing.md"]), log: logged)

        XCTAssertFalse(try claudeMD(in: workspace).contains("Important files:"))
        XCTAssertEqual(logged.lines.filter { $0.contains("style.md") }.count, 1)
        XCTAssertEqual(logged.lines.filter { $0.contains("testing.md") }.count, 1)
    }

    /// Nothing to report on a package that resolves — a log line per generated
    /// workspace would drown the ones that mean something.
    func testAPackageWhoseFilesAllResolveLogsNothing() throws {
        try writeKnowledge("style.md", "Style.")
        try writeShared("conventions", "Shared conventions.")
        let logged = LogRecorder()

        _ = try generate(
            resolved(critical: ["style.md"], files: ["style.md"], imports: ["shared:conventions"]),
            log: logged
        )

        XCTAssertEqual(logged.lines, [])
    }

    /// A file that cannot be linked must not fail the open: `ProjectSession`
    /// takes whatever `generate` returns and runs the agent in it.
    func testAWorkspaceIsStillReturnedWhenNothingCouldBeLinked() throws {
        let workspace = try generate(resolved(files: ["gone.md"], imports: ["shared:conventions"]))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspace.appending(path: "CLAUDE.md").path(percentEncoded: false)
        ))
    }

    // MARK: - Sweeping earlier boots' workspaces

    /// The kept session, and everything under it, survives the sweep.
    func testSweepRemovesEveryOtherSessionDirectoryButKeepsTheCurrentOne() throws {
        let workspacesURL = tempDir.appending(path: "workspaces")
        let keptDir = workspacesURL.appending(path: "current")
        let oldDir = workspacesURL.appending(path: "old")
        let fm = FileManager.default
        try fm.createDirectory(at: keptDir.appending(path: "reviewer"), withIntermediateDirectories: true)
        try "kept".write(to: keptDir.appending(path: "reviewer/CLAUDE.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: oldDir.appending(path: "reviewer"), withIntermediateDirectories: true)

        WorkspaceGenerator.sweep(workspacesURL: workspacesURL, keeping: "current")

        XCTAssertTrue(fm.fileExists(atPath: keptDir.appending(path: "reviewer/CLAUDE.md").path(percentEncoded: false)))
        XCTAssertFalse(fm.fileExists(atPath: oldDir.path(percentEncoded: false)))
    }

    /// Opening a project twice leaves one session directory, not two.
    func testSweepingTwiceInARowLeavesOnlyTheLatestSession() throws {
        let workspacesURL = tempDir.appending(path: "workspaces")
        let fm = FileManager.default
        try fm.createDirectory(at: workspacesURL.appending(path: "first"), withIntermediateDirectories: true)

        WorkspaceGenerator.sweep(workspacesURL: workspacesURL, keeping: "first")
        try fm.createDirectory(at: workspacesURL.appending(path: "second"), withIntermediateDirectories: true)
        WorkspaceGenerator.sweep(workspacesURL: workspacesURL, keeping: "second")

        let remaining = try fm.contentsOfDirectory(atPath: workspacesURL.path(percentEncoded: false))
        XCTAssertEqual(remaining, ["second"])
    }

    /// A workspaces directory that does not exist yet — the first boot of a
    /// project — raises nothing.
    func testSweepOfAMissingWorkspacesDirectoryDoesNothing() {
        let workspacesURL = tempDir.appending(path: "never-created")

        WorkspaceGenerator.sweep(workspacesURL: workspacesURL, keeping: "current")
    }

    /// A non-directory entry sitting in `workspaces/` — not a shape the app
    /// writes, but not the sweep's business either — is left alone.
    func testSweepLeavesNonDirectoryEntriesAlone() throws {
        let workspacesURL = tempDir.appending(path: "workspaces")
        let fm = FileManager.default
        try fm.createDirectory(at: workspacesURL, withIntermediateDirectories: true)
        let strayFile = workspacesURL.appending(path: "stray.txt")
        try "not a session".write(to: strayFile, atomically: true, encoding: .utf8)

        WorkspaceGenerator.sweep(workspacesURL: workspacesURL, keeping: "current")

        XCTAssertTrue(fm.fileExists(atPath: strayFile.path(percentEncoded: false)))
    }

    // MARK: - Helpers

    private func generate(
        _ agent: ResolvedAgent,
        log: LogRecorder? = nil,
        sessionID: String = "session"
    ) throws -> URL {
        var generator = WorkspaceGenerator(
            project: KiteloopProject(rootURL: tempDir.appending(path: "project")),
            sharedImportsURL: sharedDir
        )
        if let log { generator.log = { log.record($0) } }
        return try generator.generate(agent: agent, sessionID: sessionID)
    }

    private func generateClaudeMD(for agent: ResolvedAgent) throws -> String {
        try claudeMD(in: generate(agent))
    }

    private func claudeMD(in workspace: URL) throws -> String {
        try String(contentsOf: workspace.appending(path: "CLAUDE.md"), encoding: .utf8)
    }

    private func writeKnowledge(_ name: String, _ content: String) throws {
        try content.write(
            to: packageURL.appending(path: "knowledge").appending(path: name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeShared(_ name: String, _ content: String) throws {
        try content.write(
            to: sharedDir.appending(path: "\(name).md"), atomically: true, encoding: .utf8
        )
    }

    private func resolved(
        critical: [String] = [],
        files: [String] = [],
        imports: [String] = []
    ) -> ResolvedAgent {
        ResolvedAgent(
            package: AgentPackage(
                handle: "reviewer",
                version: "1.0.0",
                repos: nil,
                template: PackageTemplate(
                    name: "Reviewer",
                    model: "sonnet",
                    systemPrompt: "prompt.md",
                    avatar: nil,
                    group: nil,
                    description: nil,
                    tools: nil,
                    mcpServers: nil,
                    skills: nil,
                    denied: nil,
                    permissionMode: nil,
                    effort: nil,
                    thinkingEnabled: nil,
                    runtimeKind: nil
                ),
                knowledge: KnowledgeConfig(critical: critical, files: files, imports: imports)
            ),
            overrides: nil,
            source: .shared,
            packageURL: packageURL,
            refID: "reviewer"
        )
    }
}

/// Collects what the generator reported instead of the shared ring buffer, which
/// a whole suite writes to and which evicts.
private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ line: String) {
        lock.lock()
        recorded.append(line)
        lock.unlock()
    }
}
