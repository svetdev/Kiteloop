import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers what happens when `.kiteloop/autopilot-config.json` exists but its
/// bytes cannot be turned back into an `AutopilotConfig` — a hand-edited file
/// with a cap written as a string, say. `loadConfig()` used to fall through to
/// every setting at its default with nothing recorded anywhere, and the very
/// next setting change would rewrite the file from that empty state. This
/// covers that a failure is now named, logged, and the original bytes are
/// preserved before anything can write over them.
@MainActor
final class BacklogAutopilotConfigLoadTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "autopilot-config-load")
    }

    override func tearDownWithError() throws {
        // The refused-copy case drops write permission on `tempDir` itself;
        // restore it so the harness can remove the directory afterwards.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try super.tearDownWithError()
    }

    /// An autopilot wired to `configURL`, the way `MainWindow` wires a project's
    /// `autopilot-config.json`.
    private func makeAutopilot(configURL: URL) -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(
                    storageURL: tempDir.appendingPathComponent("global-config.json")
                )
            ),
            configURL: configURL
        )
        return autopilot
    }

    private var configURL: URL { tempDir.appendingPathComponent("autopilot-config.json") }
    private var siblingURL: URL { tempDir.appendingPathComponent("autopilot-config.json.unreadable") }

    func testInvalidJSONNamesTheFailureLogsItAndPreservesTheOriginalBytes() throws {
        let original = Data("{ this is not valid json".utf8)
        try original.write(to: configURL)

        let autopilot = makeAutopilot(configURL: configURL)

        let failure = try XCTUnwrap(autopilot.configLoadFailure)
        XCTAssertTrue(failure.contains(configURL.path(percentEncoded: false)))
        XCTAssertTrue(autopilot.log.contains { $0.message == failure })
        XCTAssertEqual(try Data(contentsOf: siblingURL), original)
    }

    /// The old message named only the config path and claimed it "will not be
    /// saved over" — false, since `saveConfig()` rewrites it from defaults on
    /// the very next setting change, and it never named the sibling that
    /// actually holds the bytes.
    func testTheFailureMessageNamesBothPathsAndSaysTheConfigIsRewrittenFromDefaults() throws {
        let original = Data("{ this is not valid json".utf8)
        try original.write(to: configURL)

        let autopilot = makeAutopilot(configURL: configURL)

        let failure = try XCTUnwrap(autopilot.configLoadFailure)
        XCTAssertTrue(failure.contains(configURL.path(percentEncoded: false)))
        XCTAssertTrue(failure.contains(siblingURL.path(percentEncoded: false)))
        XCTAssertTrue(failure.contains("rewritten from defaults"))
        XCTAssertFalse(failure.contains("will not be saved over"))
    }

    /// When the sibling write itself is refused, the reassuring "preserved"
    /// message must not be reported — a preservation that never landed reads
    /// exactly like a failure, with the filesystem's own reason attached.
    func testARefusedSiblingWriteSaysTheBytesCouldNotBePreserved() throws {
        let original = Data("{ this is not valid json".utf8)
        try original.write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDir.path)

        let autopilot = makeAutopilot(configURL: configURL)

        let failure = try XCTUnwrap(autopilot.configLoadFailure)
        XCTAssertTrue(failure.contains("could not be preserved"))
        XCTAssertFalse(failure.contains("are preserved at"))
        XCTAssertTrue(autopilot.log.contains { $0.message == failure })
        XCTAssertFalse(FileManager.default.fileExists(atPath: siblingURL.path))
    }

    func testASettingChangeAfterAFailedLoadRewritesTheConfigWithoutTouchingThePreservedCopy() throws {
        let original = Data("{ this is not valid json".utf8)
        try original.write(to: configURL)

        let autopilot = makeAutopilot(configURL: configURL)
        XCTAssertNotNil(autopilot.configLoadFailure)

        autopilot.workerAgentID = "writer"

        XCTAssertNotEqual(try Data(contentsOf: configURL), original)
        XCTAssertEqual(try Data(contentsOf: siblingURL), original)
    }

    func testASecondFailedLoadOverAnExistingSiblingLeavesItUntouched() throws {
        let firstOriginal = Data("{ this is not valid json".utf8)
        try firstOriginal.write(to: configURL)
        let autopilot = makeAutopilot(configURL: configURL)
        XCTAssertEqual(try Data(contentsOf: siblingURL), firstOriginal)

        // A settings change rewrites `autopilot-config.json` from defaults —
        // the "newer, already-rewritten file" a second failed load must not
        // mistake for the original.
        autopilot.workerAgentID = "writer"
        XCTAssertNotEqual(try Data(contentsOf: configURL), firstOriginal)

        let handEditedAgain = Data("{ also not valid".utf8)
        try handEditedAgain.write(to: configURL)
        _ = makeAutopilot(configURL: configURL)

        XCTAssertEqual(try Data(contentsOf: siblingURL), firstOriginal)
    }

    func testAnAbsentConfigFileLoadsAsBeforeWithNoFailureNoSiblingAndNoLogLine() {
        let autopilot = makeAutopilot(configURL: configURL)

        XCTAssertNil(autopilot.configLoadFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: siblingURL.path))
        XCTAssertTrue(autopilot.log.isEmpty)
    }

    /// A project with no autopilot config yet has no separate reviewer: a run
    /// goes from the worker straight to the gates.
    func testAProjectWithNoConfigYetStartsWithNoReviewer() {
        let autopilot = makeAutopilot(configURL: configURL)

        XCTAssertNil(autopilot.reviewerAgentID)
    }

    /// The new default is for new projects only: a config that names a
    /// reviewer keeps it.
    func testAConfigNamingAReviewerKeepsIt() throws {
        try Data(#"{"workerAgentID": "worker-1", "reviewerAgentID": "reviewer-1"}"#.utf8).write(to: configURL)

        let autopilot = makeAutopilot(configURL: configURL)

        XCTAssertEqual(autopilot.reviewerAgentID, "reviewer-1")
    }

    func testAValidConfigFileRoundTripsAndLeavesNoFailure() throws {
        let json = """
        {
          "workerAgentID": "worker-1",
          "reviewerAgentID": "reviewer-1",
          "maxRetries": 5,
          "dailyBudgetUSD": 3.5,
          "autonomousWorkEnabled": true
        }
        """
        try Data(json.utf8).write(to: configURL)

        let autopilot = makeAutopilot(configURL: configURL)

        XCTAssertNil(autopilot.configLoadFailure)
        XCTAssertEqual(autopilot.workerAgentID, "worker-1")
        XCTAssertEqual(autopilot.reviewerAgentID, "reviewer-1")
        XCTAssertEqual(autopilot.maxRetries, 5)
        XCTAssertEqual(autopilot.budgetUSD, 3.5)
        XCTAssertTrue(autopilot.autonomousWorkEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: siblingURL.path))
    }
}
