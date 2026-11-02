import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers what the Autopilot tab's **Auto-merge on approval** toggle and its
/// merge-verify command field write: both are off/empty by default and survive
/// a reopen of the project, so a project cannot be merging unattended with
/// nothing on disk saying so.
@MainActor
final class BacklogAutopilotAutoMergeToggleTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "autopilot-auto-merge")
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

    /// The toggle starts off — a project cannot merge unattended just by existing.
    func testAutoMergeIsOffByDefault() {
        XCTAssertEqual(BacklogAutopilot.Defaults.approvalGate, .propose)
        let autopilot = makeAutopilot(configURL: tempDir.appendingPathComponent("autopilot-config.json"))
        XCTAssertFalse(autopilot.autoMergeOnApproval)
        XCTAssertNil(autopilot.autoMergeVerifyCommand)
    }

    func testTogglingOnPersistsAcrossReload() {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")

        makeAutopilot(configURL: configURL).approvalGate = .land
        XCTAssertTrue(makeAutopilot(configURL: configURL).autoMergeOnApproval)
    }

    /// Turning it back off must persist too — a stale `true` would keep merging
    /// unattended after the user turned it off.
    func testTogglingBackOffPersistsAcrossReload() {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")

        let first = makeAutopilot(configURL: configURL)
        first.approvalGate = .land
        first.approvalGate = .propose

        XCTAssertFalse(makeAutopilot(configURL: configURL).autoMergeOnApproval)
    }

    /// A config written before the gate was one value carries its two
    /// switches. Both on loads as `land`; every other pair — the half-set
    /// ones included — as `propose`, and absent keys as `propose` too.
    func testAnOldConfigLoadsAsLandOnlyWhenBothSwitchesAreOn() throws {
        let cases: [(json: String, expected: BacklogAutopilot.ApprovalGate)] = [
            (#"{"approveReviewPassedRuns": true, "autoMergeOnApproval": true}"#, .land),
            (#"{"approveReviewPassedRuns": true, "autoMergeOnApproval": false}"#, .propose),
            (#"{"approveReviewPassedRuns": false, "autoMergeOnApproval": true}"#, .propose),
            (#"{"approveReviewPassedRuns": false, "autoMergeOnApproval": false}"#, .propose),
            (#"{"autoMergeOnApproval": true}"#, .propose),
            (#"{"maxRetries": 4}"#, .propose)
        ]
        for (index, row) in cases.enumerated() {
            let configURL = tempDir.appendingPathComponent("old-\(index).json")
            try row.json.write(to: configURL, atomically: true, encoding: .utf8)

            let autopilot = makeAutopilot(configURL: configURL)

            XCTAssertNil(autopilot.configLoadFailure, row.json)
            XCTAssertEqual(autopilot.approvalGate, row.expected, row.json)
            XCTAssertEqual(autopilot.approveReviewPassedRuns, row.expected == .land, row.json)
            XCTAssertEqual(autopilot.autoMergeOnApproval, row.expected == .land, row.json)
        }
    }

    /// A stored `approvalGate` is what loads, whatever an old switch beside it says.
    func testAStoredGateWinsOverTheOldSwitches() throws {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")
        try #"{"approvalGate": "propose", "approveReviewPassedRuns": true, "autoMergeOnApproval": true}"#
            .write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(makeAutopilot(configURL: configURL).approvalGate, .propose)
    }

    /// A merge-verify command set on one instance is read back by the next one
    /// opened against the same config file.
    func testMergeVerifyCommandPersistsAcrossReload() {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")

        makeAutopilot(configURL: configURL).autoMergeVerifyCommand = "cd Kiteloop && xcodebuild build-for-testing"
        XCTAssertEqual(
            makeAutopilot(configURL: configURL).autoMergeVerifyCommand,
            "cd Kiteloop && xcodebuild build-for-testing"
        )
    }

    /// A blank command reads back as nil, not as an empty string — the same
    /// reading the run-settings field's commit gives it, and what keeps
    /// `isConfigAtDefaults` true when every other knob is untouched.
    func testBlankMergeVerifyCommandReadsAsNil() {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")

        let first = makeAutopilot(configURL: configURL)
        first.autoMergeVerifyCommand = "cd Kiteloop && xcodebuild build-for-testing"
        first.autoMergeVerifyCommand = nil

        let reloaded = makeAutopilot(configURL: configURL)
        XCTAssertNil(reloaded.autoMergeVerifyCommand)
        XCTAssertTrue(reloaded.isConfigAtDefaults)
    }

    /// A config reset turns auto-merge back off. A stored merge-verify command
    /// is not a setting, so the reset neither clears it nor counts it.
    func testResetTurnsAutoMergeOffAndLeavesTheStoredCommand() {
        let autopilot = makeAutopilot(configURL: tempDir.appendingPathComponent("autopilot-config.json"))
        autopilot.approvalGate = .land
        autopilot.autoMergeVerifyCommand = "cd Kiteloop && xcodebuild build-for-testing"

        autopilot.resetConfigToDefaults()

        XCTAssertFalse(autopilot.autoMergeOnApproval)
        XCTAssertTrue(autopilot.isConfigAtDefaults)
        XCTAssertEqual(autopilot.autoMergeVerifyCommand, "cd Kiteloop && xcodebuild build-for-testing")
    }

    // MARK: - A stored command, for one release

    /// An autopilot over `root` whose config an earlier release wrote with a
    /// merge-verify command, and a verify map holding `rules`.
    private func makeAutopilotWithStoredCommand(rules: String) throws -> BacklogAutopilot {
        let root = tempDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"rules": \#(rules)}"#.write(
            to: KiteloopProject(rootURL: root).verifyMapURL, atomically: true, encoding: .utf8)
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")
        try #"{"autoMergeVerifyCommand": "make ci"}"#.write(to: configURL, atomically: true, encoding: .utf8)
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(globalConfigStore: GlobalConfigStore(
                storageURL: tempDir.appendingPathComponent("global-config.json"))),
            configURL: configURL,
            projectPath: root.path(percentEncoded: false)
        )
        return autopilot
    }

    /// With no rule matching every path, the stored command still gates the
    /// merge this release, and the log names the rule that replaces it.
    func testAStoredCommandWithNoCatchAllRuleStillRunsAndTheLogNamesTheRule() async throws {
        let autopilot = try makeAutopilotWithStoredCommand(rules: #"[{"glob": "apps/**", "command": "npm test"}]"#)

        let plan = await autopilot.mergeVerifyPlanForTesting(for: BacklogItem(id: "item-1", title: "Item", status: .ready, type: .local))

        XCTAssertEqual(plan.steps.map(\.command), ["make ci", "npm test"])
        let notice = try XCTUnwrap(autopilot.log.last?.message)
        XCTAssertTrue(notice.contains(#"{"command":"make ci","glob":"**"}"#), notice)
        XCTAssertTrue(notice.contains("kiteloop-verify.json"), notice)
    }

    /// Once the map has a rule matching every path, that rule is the gate:
    /// the stored command no longer runs and nothing is logged about it.
    func testAStoredCommandIsDroppedOnceTheMapHasACatchAllRule() async throws {
        let autopilot = try makeAutopilotWithStoredCommand(rules: #"[{"glob": "**", "command": "make verify"}]"#)

        let plan = await autopilot.mergeVerifyPlanForTesting(for: BacklogItem(id: "item-1", title: "Item", status: .ready, type: .local))

        XCTAssertEqual(plan.steps.map(\.command), ["make verify"])
        XCTAssertFalse(autopilot.log.contains { $0.message.contains("make ci") })
    }

    /// Only a glob reaching every path counts as the catch-all — not one
    /// scoped to an extension.
    func testOnlyARuleReachingEveryPathCountsAsTheCatchAll() {
        XCTAssertTrue(BacklogAutopilot.matchesEveryPath(VerifyCoverage.Rule(glob: "**", command: "x")))
        XCTAssertFalse(BacklogAutopilot.matchesEveryPath(VerifyCoverage.Rule(glob: "**/*.swift", command: "x")))
        XCTAssertFalse(BacklogAutopilot.matchesEveryPath(VerifyCoverage.Rule(glob: "apps/**", command: "x")))
    }
}
