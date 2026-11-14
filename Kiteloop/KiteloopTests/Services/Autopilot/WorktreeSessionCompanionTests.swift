import XCTest
import KiteloopCore
@testable import Kiteloop

/// One item across two repositories (ADR-0005), on real git: the project and
/// a companion get the same branch, one verify sees both merged trees, and
/// the landing is both or neither.
final class WorktreeSessionCompanionTests: XCTestCase {
    private var project: URL!
    private var library: URL!
    private var companion: CompanionRepo!

    override func setUpWithError() throws {
        project = try makeRepository("companion-project", files: [".gitignore": ".kiteloop/\n", "app.txt": "app\n"])
        library = try makeRepository("companion-library", files: ["lib.txt": "one\n"])
        companion = CompanionRepo(name: "library", path: library.path(percentEncoded: false))
    }

    // MARK: - Fixtures

    private func makeRepository(_ prefix: String, files: [String: String]) throws -> URL {
        let repo = try makeTemporaryDirectory(prefix: prefix)
        git(["init", "-b", "main"], in: repo)
        git(["config", "user.email", "test@test.com"], in: repo)
        git(["config", "user.name", "Test"], in: repo)
        for (path, text) in files {
            try text.write(to: repo.appending(path: path), atomically: true, encoding: .utf8)
        }
        git(["add", "-A"], in: repo)
        git(["commit", "-m", "init"], in: repo)
        return repo
    }

    @discardableResult
    private func git(_ args: [String], in url: URL) -> String {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/usr/bin/git", arguments: ["-C", url.path(percentEncoded: false)] + args, timeout: 60)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func beginSession(log: @escaping @MainActor (String) -> Void = { _ in }) async throws -> WorktreeSession {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))
        let setup = await WorktreeSession.begin(
            itemID: "item-1", projectRoot: project, agentIDs: ["worker"],
            orchestrator: orchestrator, companions: [companion], log: log)
        guard case .isolated(let session) = setup else {
            XCTFail("expected an isolated setup, got \(setup)")
            throw WorktreeError.creationFailed("item-1")
        }
        return session
    }

    /// A finished run that changed one file in each repository.
    @MainActor
    private func finishedRun(project changesProject: Bool = true) async throws -> WorktreeSession {
        let session = try await beginSession()
        if changesProject {
            try "app v2\n".write(to: session.path.appending(path: "app.txt"), atomically: true, encoding: .utf8)
        }
        try "two\n".write(to: companion.checkout(in: session.path).appending(path: "lib.txt"),
                          atomically: true, encoding: .utf8)
        await session.end(outcome: .awaitingApproval)
        return session
    }

    private func verify(_ command: String) -> MergeVerifyPlan {
        MergeVerifyPlan(steps: [MergeVerifyPlan.Step(source: .item, command: command)])
    }

    // MARK: - The run

    @MainActor
    func testBeginChecksTheCompanionOutUnderTheRunsWorktree() async throws {
        var logged: [String] = []
        let session = try await beginSession { logged.append($0) }

        let nested = session.path.appending(path: ".kiteloop/repos/library")
        XCTAssertEqual(git(["symbolic-ref", "--short", "HEAD"], in: nested), "kiteloop/item-1")
        XCTAssertTrue(logged.contains("Isolated run in worktree kiteloop/item-1, "
                                      + "with companion library at .kiteloop/repos/library"), "\(logged)")
        await session.end(outcome: .cancelled)
    }

    @MainActor
    func testBeginRefusesWhenACompanionCannotBeMade() async throws {
        companion = CompanionRepo(name: "ghost", path: "/nonexistent/ghost")
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))

        let setup = await WorktreeSession.begin(
            itemID: "item-1", projectRoot: project, agentIDs: ["worker"],
            orchestrator: orchestrator, companions: [companion], log: { _ in })

        guard case .failed(let reason) = setup else { return XCTFail("expected a refusal, got \(setup)") }
        XCTAssertTrue(reason.contains("companion ghost"), reason)
        XCTAssertNil(orchestrator.pinnedWorkingDirectory(for: "worker"))
    }

    @MainActor
    func testEndCommitsEachRepositoryToItsOwnBranch() async throws {
        let session = try await beginSession()
        try "app v2\n".write(to: session.path.appending(path: "app.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: companion.checkout(in: session.path).appending(path: "lib.txt"),
                          atomically: true, encoding: .utf8)

        let teardown = await session.end(outcome: .awaitingApproval)

        XCTAssertEqual(teardown.branch, "kiteloop/item-1")
        XCTAssertEqual(teardown.companionsWithWork, ["library"])
        XCTAssertEqual(git(["show", "kiteloop/item-1:app.txt"], in: project), "app v2")
        XCTAssertEqual(git(["show", "kiteloop/item-1:lib.txt"], in: library), "two")
        XCTAssertEqual(git(["show", "main:lib.txt"], in: library), "one", "nothing lands at teardown")
        XCTAssertFalse(git(["worktree", "list"], in: library).contains(".kiteloop/repos"))
    }

    @MainActor
    func testARunThatOnlyChangedTheCompanionKeepsTheProjectsBranch() async throws {
        let session = try await beginSession()
        try "two\n".write(to: companion.checkout(in: session.path).appending(path: "lib.txt"),
                          atomically: true, encoding: .utf8)

        let teardown = await session.end(outcome: .awaitingApproval)

        XCTAssertEqual(teardown.branch, "kiteloop/item-1")
        XCTAssertEqual(teardown.companionsWithWork, ["library"])
        let evidence = await RunWorkEvidence.inspect(projectRoot: project, branch: teardown.branch, isolated: true)
        XCTAssertTrue(evidence.producedNothing, "the project's own branch is empty")
        XCTAssertEqual(evidence.counting(companionWork: true), .produced)
    }

    @MainActor
    func testRestartingAnItemKeepsTheLooseWorkItsCompanionHeld() async throws {
        let first = try await beginSession()
        try "loose\n".write(to: companion.checkout(in: first.path).appending(path: "lib.txt"),
                            atomically: true, encoding: .utf8)
        let abandoned = git(["rev-parse", "main"], in: library)

        // The app quit mid-run; the item is picked up again.
        let manager = WorktreeManager(projectRoot: project)
        await manager.removeWorktree(for: "item-1", keepBranch: false)

        let recovered = git(["rev-parse", "kiteloop/item-1"], in: library)
        XCTAssertNotEqual(recovered, abandoned)
        XCTAssertEqual(git(["show", "kiteloop/item-1:lib.txt"], in: library), "loose")
    }

    // MARK: - The gate

    @MainActor
    func testTheGateLandsBothRepositoriesAfterOneVerifySeesBothMerged() async throws {
        let session = try await finishedRun()

        let result = await session.merge(
            message: "autopilot: merge item-1",
            verify: verify("grep -q 'app v2' app.txt && grep -q two .kiteloop/repos/library/lib.txt"))

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertEqual(result.companionsLanded.map(\.name), ["library"])
        XCTAssertEqual(git(["show", "main:app.txt"], in: project), "app v2")
        XCTAssertEqual(git(["show", "main:lib.txt"], in: library), "two")
        XCTAssertEqual(try String(contentsOf: library.appending(path: "lib.txt"), encoding: .utf8), "two\n")
        XCTAssertEqual(git(["branch", "--list", "kiteloop/item-1"], in: library), "")
        XCTAssertFalse(git(["worktree", "list"], in: library).contains("merge-gate"))
    }

    @MainActor
    func testARedVerifyMovesNeitherRepository() async throws {
        let session = try await finishedRun()
        let projectBefore = git(["rev-parse", "main"], in: project)
        let libraryBefore = git(["rev-parse", "main"], in: library)

        let result = await session.merge(message: "autopilot: merge item-1", verify: verify("false"))

        XCTAssertFalse(result.merged)
        XCTAssertEqual(git(["rev-parse", "main"], in: project), projectBefore)
        XCTAssertEqual(git(["rev-parse", "main"], in: library), libraryBefore)
        XCTAssertFalse(git(["branch", "--list", "kiteloop/item-1"], in: library).isEmpty, "the work is kept")
    }

    @MainActor
    func testACompanionThatNoLongerMergesRefusesTheWholeGate() async throws {
        let session = try await finishedRun()
        try "someone else\n".write(to: library.appending(path: "lib.txt"), atomically: true, encoding: .utf8)
        git(["commit", "-am", "the library moved"], in: library)
        let projectBefore = git(["rev-parse", "main"], in: project)

        let result = await session.merge(message: "autopilot: merge item-1", verify: verify("true"))

        XCTAssertFalse(result.merged)
        XCTAssertTrue(result.reason.hasPrefix("companion library: kiteloop/item-1 no longer merges"), result.reason)
        XCTAssertEqual(git(["rev-parse", "main"], in: project), projectBefore)
    }

    /// The verify itself commits to the project's checkout, so the project —
    /// landed last — can never fast-forward: the companion, already landed,
    /// has to be put back, on the first attempt and on the retry.
    @MainActor
    func testAProjectThatWillNotLandPutsTheCompanionBack() async throws {
        let session = try await finishedRun()
        let libraryBefore = git(["rev-parse", "main"], in: library)
        let root = project.path(percentEncoded: false)

        let result = await session.merge(
            message: "autopilot: merge item-1",
            verify: verify("git -C '\(root)' commit -q --allow-empty -m 'the base moves'"))

        XCTAssertFalse(result.merged, result.reason)
        XCTAssertEqual(git(["rev-parse", "main"], in: library), libraryBefore)
        XCTAssertEqual(try String(contentsOf: library.appending(path: "lib.txt"), encoding: .utf8), "one\n")
        XCTAssertEqual(git(["show", "main:app.txt"], in: project), "app")
    }

    @MainActor
    func testAnItemWithWorkOnlyInItsCompanionStillLandsIt() async throws {
        let session = try await finishedRun(project: false)

        let result = await session.merge(
            message: "autopilot: merge item-1", verify: verify("grep -q two .kiteloop/repos/library/lib.txt"))

        XCTAssertTrue(result.merged, result.reason)
        XCTAssertEqual(git(["show", "main:lib.txt"], in: library), "two")
    }

    // MARK: - Review fixes

    /// A base tree has no companions under it, so a project-wide command
    /// that reaches into one fails there whatever the base's state. The
    /// refusal must be the verify's own, not "the base fails it too".
    @MainActor
    func testARedProjectWideVerifyIsNotBlamedOnABaseThatHasNoCompanions() async throws {
        let session = try await finishedRun()
        let plan = MergeVerifyPlan(steps: [MergeVerifyPlan.Step(
            source: .project, command: "test -f .kiteloop/repos/library/lib.txt && false")])

        let result = await session.merge(message: "autopilot: merge item-1", verify: plan)

        XCTAssertFalse(result.merged)
        XCTAssertFalse(result.reason.contains("also fails on"), result.reason)
    }

    func testARunThatChangedOnlyACompanionIsNotCountedAsChangingNothing() {
        XCTAssertEqual(BacklogAutopilot.countingCompanionFiles(0, companions: [".kiteloop/repos/library/lib.txt"]), 1)
        XCTAssertEqual(BacklogAutopilot.countingCompanionFiles(2, companions: ["a", "b"]), 4)
        XCTAssertEqual(BacklogAutopilot.countingCompanionFiles(2, companions: nil), 2)
        XCTAssertNil(BacklogAutopilot.countingCompanionFiles(nil, companions: []),
                     "a run nobody could measure stays unmeasured")
    }
}
