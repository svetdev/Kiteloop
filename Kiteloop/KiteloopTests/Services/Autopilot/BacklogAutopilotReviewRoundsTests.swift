import XCTest
@testable import Kiteloop

/// Covers `maxRetries` — how many worker/reviewer rounds one item gets in a
/// single run. It is the graph's `maxIterations`, and until it became a setting
/// it was a literal 3 that nothing in the app, the control API or the project's
/// config file could change: a project whose reviewer needed a fourth pass had
/// no way to ask for one, and no way to notice it couldn't.
@MainActor
final class BacklogAutopilotReviewRoundsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "autopilot-review-rounds")
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

    // MARK: - The bounds

    func testRangeOffersTheDefaultAndStartsAtOneRound() {
        XCTAssertEqual(BacklogAutopilot.maxRetriesRange.lowerBound, 1,
                       "zero rounds is a run that cannot reach its own reviewer")
        XCTAssertEqual(BacklogAutopilot.maxRetriesRange.upperBound, 10)
        XCTAssertTrue(
            BacklogAutopilot.maxRetriesRange.contains(BacklogAutopilot.Defaults.maxRetries),
            "the default must be offered by the control"
        )
        XCTAssertEqual(BacklogAutopilot.Defaults.maxRetries, 3, "the built-in stays what it has always been")
    }

    func testClampLeavesInRangeValuesAlone() {
        XCTAssertEqual(BacklogAutopilot.clampMaxRetries(1), 1)
        XCTAssertEqual(BacklogAutopilot.clampMaxRetries(3), 3)
        XCTAssertEqual(BacklogAutopilot.clampMaxRetries(10), 10)
    }

    func testClampPullsOutOfRangeValuesToTheBounds() {
        XCTAssertEqual(BacklogAutopilot.clampMaxRetries(0), 1)
        XCTAssertEqual(BacklogAutopilot.clampMaxRetries(-2), 1)
        XCTAssertEqual(BacklogAutopilot.clampMaxRetries(99), 10)
    }

    /// The property itself clamps, so the control's range holds no matter who
    /// writes it — a hand-edited config file or `PUT /v1/autopilot` — and an
    /// in-range value still lands unchanged.
    func testAssigningOutOfRangeValueIsClamped() {
        let autopilot = BacklogAutopilot()
        XCTAssertEqual(autopilot.maxRetries, BacklogAutopilot.Defaults.maxRetries)

        autopilot.maxRetries = 6
        XCTAssertEqual(autopilot.maxRetries, 6)

        autopilot.maxRetries = 0
        XCTAssertEqual(autopilot.maxRetries, 1)

        autopilot.maxRetries = 9_999
        XCTAssertEqual(autopilot.maxRetries, 10)
    }

    // MARK: - It reaches disk

    /// The whole point of the setting: a value set in the Autopilot tab is still
    /// there when the project is reopened, in both directions.
    func testPersistsAcrossAReopenOfTheProject() {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")

        let first = makeAutopilot(configURL: configURL)
        XCTAssertEqual(first.maxRetries, BacklogAutopilot.Defaults.maxRetries)
        first.maxRetries = 6

        let reloaded = makeAutopilot(configURL: configURL)
        XCTAssertEqual(reloaded.maxRetries, 6)
        reloaded.maxRetries = 2

        XCTAssertEqual(makeAutopilot(configURL: configURL).maxRetries, 2)
    }

    /// A config file somebody edited by hand is clamped on the way in, so an
    /// out-of-range number on disk cannot put the run loop somewhere the control
    /// would not let it go.
    func testAnOutOfRangeValueOnDiskIsClampedWhenItIsRead() throws {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")
        try Data(#"{"maxRetries":40}"#.utf8).write(to: configURL)

        XCTAssertEqual(makeAutopilot(configURL: configURL).maxRetries, 10)
    }

    /// A reset puts it back to the built-in, and while it differs the Reset
    /// control has something to do.
    func testResetRestoresTheBuiltInThreeRounds() {
        let autopilot = makeAutopilot(configURL: tempDir.appendingPathComponent("autopilot-config.json"))
        autopilot.maxRetries = 7

        XCTAssertFalse(autopilot.isConfigAtDefaults)
        autopilot.resetConfigToDefaults()

        XCTAssertEqual(autopilot.maxRetries, BacklogAutopilot.Defaults.maxRetries)
        XCTAssertTrue(autopilot.isConfigAtDefaults)
    }

    /// `RunScheduling.ProjectHold` clears on a configuration change, and it can
    /// only notice one the fingerprint carries — a knob missing from
    /// `currentConfig` is a knob a hold is held across.
    func testChangingItMovesTheConfigFingerprint() {
        let autopilot = makeAutopilot(configURL: tempDir.appendingPathComponent("autopilot-config.json"))
        let before = autopilot.configFingerprint

        autopilot.maxRetries = BacklogAutopilot.Defaults.maxRetries + 1

        XCTAssertNotEqual(autopilot.configFingerprint, before)
    }

    // MARK: - It reaches the run

    /// The property is the only source of the graph's iteration limit, so the
    /// number a project sets is the number the reviewer loop is bounded by.
    func testItIsTheGraphsIterationLimit() {
        for rounds in [1, 3, 10] {
            let graph = BacklogAutopilot.buildWorkflowGraph(
                workerAgentID: "worker-1",
                reviewerAgentID: "reviewer-1",
                maxIterations: rounds
            )
            XCTAssertEqual(graph.maxIterations, rounds)
        }
    }
}
