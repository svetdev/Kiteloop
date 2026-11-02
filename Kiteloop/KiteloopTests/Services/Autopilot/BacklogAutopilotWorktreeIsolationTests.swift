import XCTest
@testable import Kiteloop

/// Worktree isolation is not a setting (ADR-0001): a project whose root is a
/// git repository always runs its items in a worktree, and one that is not runs
/// in the live tree and says why. Nothing stored changes that — a config
/// written while `useWorktree` was still a toggle loads, and its key is ignored.
@MainActor
final class BacklogAutopilotWorktreeIsolationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "autopilot-worktree")
    }

    /// An autopilot wired to `configURL`, the way `MainWindow` wires a project's
    /// `autopilot-config.json`. `projectPath` is what isolation is read off,
    /// and nil where a caller is not testing it.
    private func makeAutopilot(configURL: URL, projectPath: String? = nil) -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(
                    storageURL: tempDir.appendingPathComponent("global-config.json")
                )
            ),
            configURL: configURL,
            projectPath: projectPath
        )
        return autopilot
    }

    /// The same `git init` the worktree tests use — the real thing, since what
    /// isolation reads is what git actually writes at a repository root.
    private func initGitRepo(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = url
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private var projectPath: String { tempDir.path(percentEncoded: false) }
    private var configURL: URL { tempDir.appendingPathComponent("autopilot-config.json") }

    /// A git project isolates with nothing stored: no config file exists, and
    /// the decision the run path takes is a worktree.
    func testAGitProjectIsolatesWithNoSettingStored() {
        initGitRepo(at: tempDir)
        let autopilot = makeAutopilot(configURL: configURL, projectPath: projectPath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertTrue(autopilot.useWorktree)
        XCTAssertEqual(WorktreeSession.decide(projectRoot: autopilot.projectRoot), .isolate)
    }

    /// A root that is not a repository has no worktrees to run in, so it runs
    /// in the live tree — with the note saying why, not silently.
    func testANonGitProjectRunsInTheLiveTreeAndSaysWhy() {
        let autopilot = makeAutopilot(configURL: configURL, projectPath: projectPath)

        XCTAssertFalse(autopilot.useWorktree)
        XCTAssertEqual(
            WorktreeSession.decide(projectRoot: autopilot.projectRoot),
            .liveTree(reason: "Worktree isolation skipped — not a git repository")
        )
    }

    /// A config written while the toggle existed, holding it off, cannot switch
    /// a git project back into the mode ADR-0001 rejected — and the rest of
    /// the file still loads: the stale key is ignored, not an error.
    func testAStoredFalseOnAGitProjectStillIsolates() throws {
        initGitRepo(at: tempDir)
        try #"{"useWorktree": false, "maxRetries": 7}"#
            .write(to: configURL, atomically: true, encoding: .utf8)

        let autopilot = makeAutopilot(configURL: configURL, projectPath: projectPath)

        XCTAssertTrue(autopilot.useWorktree)
        XCTAssertEqual(WorktreeSession.decide(projectRoot: autopilot.projectRoot), .isolate)
        XCTAssertEqual(autopilot.maxRetries, 7, "the rest of the old config still loads")
    }

    /// The next save drops the stale key rather than carrying it forward.
    func testASaveNoLongerWritesTheKey() throws {
        initGitRepo(at: tempDir)
        try #"{"useWorktree": false}"#.write(to: configURL, atomically: true, encoding: .utf8)

        makeAutopilot(configURL: configURL, projectPath: projectPath).maxRetries = 4

        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        XCTAssertNil(saved["useWorktree"])
        XCTAssertEqual(saved["maxRetries"] as? Int, 4)
    }

    /// An autopilot that does not yet know which project it belongs to reads
    /// no checkout, and does not isolate.
    func testIsolationIsOffWithNoProjectYet() {
        let autopilot = makeAutopilot(configURL: configURL)
        XCTAssertFalse(autopilot.useWorktree)
    }
}
