import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/backlog` — specifically the `strandedWork` half of the response.
///
/// Kiteloop could already tell that an item marked done had its work on an
/// unmerged branch, one item at a time, in a view a person has to open. Two
/// items were eventually found by walking the branch list by hand, one of them
/// too late to merge. These tests hold the API to giving that answer without
/// anyone opening anything — over a real loopback socket, a real backlog file
/// and a real repository.
@MainActor
final class KiteloopControlServerStrandedWorkTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private let token = "control-stranded-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-stranded")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - The finding reaches a driver

    /// The whole point: done in the ledger, unmerged in git, and the response
    /// says so without anyone opening the item.
    func testADoneItemWhoseBranchIsUnmergedIsReportedWithItsIDAndCommitCount() async throws {
        let root = try registerProject(named: "alpha", items: [
            "- [x] shipped-item | Genuinely merged | done",
            "- [x] stranded-item | Reads done, never merged | done"
        ])
        try initRepository(at: root)
        try branchWithWork(at: root, branch: "kiteloop/shipped-item", file: "One.swift")
        git(at: root, "merge", "-q", "--no-ff", "-m", "merge", "kiteloop/shipped-item")
        try branchWithWork(at: root, branch: "kiteloop/stranded-item", file: "Two.swift")

        let (status, body) = try await harness.get("/v1/backlog?project=alpha")

        XCTAssertEqual(status, 200)
        let stranded = try XCTUnwrap(body["strandedWork"] as? [String: Any])
        XCTAssertEqual(stranded["count"] as? Int, 1)
        XCTAssertEqual(stranded["unreadable"] as? Bool, false)
        XCTAssertEqual(stranded["doneItemsConsidered"] as? Int, 2)
        let items = try XCTUnwrap(stranded["items"] as? [[String: Any]])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item["id"] as? String, "stranded-item")
        XCTAssertEqual(item["branch"] as? String, "kiteloop/stranded-item")
        XCTAssertEqual(item["commitsAhead"] as? Int, 1)
        XCTAssertEqual(item["ledgerSays"] as? String, "the item is Done")
        XCTAssertEqual(item["gitSays"] as? String,
                       "kiteloop/stranded-item is not merged — 1 commit exists only there")
    }

    /// The same answer for work whose branch teardown deleted: no branch for the
    /// listing to name, the commits still in the object store, and a driver told
    /// so without walking anything by hand.
    func testADoneItemWhoseBranchWasDroppedOverRealWorkIsReported() async throws {
        let root = try registerProject(named: "alpha", items: [
            "- [x] shipped-item | Genuinely merged | done",
            "- [x] dropped-item | Branch deleted, work never merged | done"
        ])
        try initRepository(at: root)
        try branchWithWork(at: root, branch: "kiteloop/shipped-item", file: "One.swift")
        git(at: root, "merge", "-q", "--no-ff", "-m", "merge", "kiteloop/shipped-item")
        git(at: root, "branch", "-D", "kiteloop/shipped-item")
        try branchWithWork(at: root, branch: "kiteloop/dropped-item", file: "Two.swift",
                           message: RunWorkEvidence.teardownSubject(for: "dropped-item"))
        git(at: root, "branch", "-D", "kiteloop/dropped-item")

        let (status, body) = try await harness.get("/v1/backlog?project=alpha")

        XCTAssertEqual(status, 200)
        let stranded = try XCTUnwrap(body["strandedWork"] as? [String: Any])
        XCTAssertEqual(stranded["count"] as? Int, 1)
        XCTAssertEqual(stranded["danglingCandidatesExamined"] as? Int, 2)
        XCTAssertNil(stranded["danglingCandidatesNotExamined"], "the sweep finished")
        let items = try XCTUnwrap(stranded["items"] as? [[String: Any]])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item["id"] as? String, "dropped-item")
        XCTAssertEqual(item["branch"] as? String, "kiteloop/dropped-item")
        XCTAssertEqual(item["ledgerSays"] as? String, "the item is Done")
        XCTAssertEqual(item["gitSays"] as? String, "there is no branch kiteloop/dropped-item "
                       + "— its commits are still in the object store, unreferenced")
    }

    /// The item's own status is untouched by being reported. The sweep says
    /// what it found; deciding what to do about a branch this old is a person's
    /// job, and nothing here merges it.
    func testReportingAnItemChangesNeitherItsStatusNorItsBranch() async throws {
        let root = try registerProject(named: "alpha", items: [
            "- [x] stranded-item | Reads done, never merged | done"
        ])
        try initRepository(at: root)
        try branchWithWork(at: root, branch: "kiteloop/stranded-item", file: "Two.swift")

        _ = try await harness.get("/v1/backlog?project=alpha")
        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        // Still stranded on the second read: nothing merged it in between.
        let stranded = try XCTUnwrap(body["strandedWork"] as? [String: Any])
        XCTAssertEqual(stranded["count"] as? Int, 1)
        let statuses = (body["items"] as? [[String: Any]] ?? []).compactMap { $0["status"] as? String }
        XCTAssertEqual(statuses, ["done"])
        XCTAssertTrue(git(at: root, "branch", "--list", "kiteloop/stranded-item")
            .contains("kiteloop/stranded-item"), "the branch is left exactly where it was")
        XCTAssertFalse(git(at: root, "log", "--oneline", "main").contains("work on"),
                       "main must not have grown a merge as a result of being asked")
    }

    /// A clean project answers too. An omitted key would read the same as a
    /// build too old to sweep at all.
    func testAProjectWithNothingStrandedReportsAZeroCountRatherThanOmittingTheKey() async throws {
        let root = try registerProject(named: "alpha", items: [
            "- [x] shipped-item | Genuinely merged | done"
        ])
        try initRepository(at: root)
        try branchWithWork(at: root, branch: "kiteloop/shipped-item", file: "One.swift")
        git(at: root, "merge", "-q", "--no-ff", "-m", "merge", "kiteloop/shipped-item")

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let stranded = try XCTUnwrap(body["strandedWork"] as? [String: Any])
        XCTAssertEqual(stranded["count"] as? Int, 0)
        XCTAssertEqual(stranded["unreadable"] as? Bool, false)
        XCTAssertEqual((stranded["items"] as? [[String: Any]])?.isEmpty, true)
        XCTAssertNil(stranded["reason"], "nothing failed, so there is nothing to explain")
        XCTAssertNil(stranded["branchesNotExamined"], "the sweep finished")
    }

    /// A project with no repository behind it: no false strandings, and it says
    /// why rather than passing an unasked question off as a clean sweep.
    func testAProjectWhoseGitCannotBeReadReportsUnreadableAndNoStrandings() async throws {
        try registerProject(named: "alpha", items: [
            "- [x] item-1 | Done | done",
            "- [x] item-2 | Done | done"
        ])

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let stranded = try XCTUnwrap(body["strandedWork"] as? [String: Any])
        XCTAssertEqual(stranded["unreadable"] as? Bool, true)
        XCTAssertEqual(stranded["count"] as? Int, 0)
        XCTAssertEqual((stranded["items"] as? [[String: Any]])?.isEmpty, true)
        XCTAssertEqual(stranded["reason"] as? String, "git could not be read here")
    }

    /// An unauthenticated caller learns nothing about the repository either.
    func testRequiresBearerToken() async throws {
        try registerProject(named: "alpha", items: ["- [x] item-1 | Done | done"])

        let (status, body) = try await harness.get("/v1/backlog?project=alpha", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertNil(body["strandedWork"])
    }

    // MARK: - Helpers

    /// Builds a real `ProjectSession` over a throwaway directory and returns its
    /// root. The layout matches `KiteloopControlServerBacklogListTests`.
    @discardableResult
    private func registerProject(named name: String, items: [String]) throws -> URL {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        try "# \(name) Backlog\n\n## Now\n\n\(items.joined(separator: "\n"))\n"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
        return root
    }

    /// All stores are pointed at the temp directory so the tests never read or
    /// write the developer's real global config.
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }

    private func initRepository(at root: URL) throws {
        git(at: root, "init", "-q", "-b", "main")
        git(at: root, "config", "user.email", "test@example.com")
        git(at: root, "config", "user.name", "Test")
        try "base\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(at: root, "add", "-A")
        git(at: root, "commit", "-qm", "base")
    }

    /// `message` is the commit subject — it matters once the branch is deleted,
    /// since the subject is all that ties a dangling commit to its item.
    private func branchWithWork(at root: URL, branch: String, file: String,
                                message: String? = nil) throws {
        git(at: root, "checkout", "-q", "main")
        git(at: root, "checkout", "-q", "-b", branch)
        try "let x = 1\n".write(to: root.appending(path: file), atomically: true, encoding: .utf8)
        git(at: root, "add", "-A")
        git(at: root, "commit", "-qm", message ?? "work on \(branch)")
        git(at: root, "checkout", "-q", "main")
    }

    @discardableResult
    private func git(at root: URL, _ args: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path(percentEncoded: false)] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
