import XCTest
import KiteloopCore
@testable import Kiteloop

/// Project Settings → Backlog Flow, and the thing a save there has to reach.
///
/// The tab used to build a `BacklogWorkflowConfigStore` of its own and write
/// straight to `.kiteloop/backlog-workflow.json`. Nothing told the open
/// project's `BacklogViewModel`, whose `workflow` is loaded once at launch and
/// has no watcher — so `BacklogAutopilot`, which asks it `stageAfterAgentReview`
/// every time a review passes, kept using the flow the project started with.
/// Switching "Require human approval before Done" back on changed a file and
/// nothing else: agents went on marking items Done until the project was closed
/// and reopened.
///
/// These drive `BacklogViewModel.updateWorkflow(_:)` — what the tab's `save(_:)`
/// now calls — against a real config file in a temp directory.
@MainActor
final class BacklogFlowSettingsTests: XCTestCase {
    private var tempDir: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-flow")
        configURL = tempDir.appending(path: ".kiteloop/backlog-workflow.json")
    }

    // MARK: - The save reaches the running project

    /// The gate that matters: turned off and back on, the open project's view
    /// model — the one autopilot reads — answers the new value each time, with
    /// no reload in between.
    func testApprovalGateChangeReachesTheOpenProject() throws {
        let backlog = makeBacklog()
        XCTAssertTrue(backlog.workflow.requireHumanApproval, "Precondition: the gate starts on")

        var config = backlog.workflow
        config.requireHumanApproval = false
        try backlog.updateWorkflow(config)

        XCTAssertFalse(backlog.workflow.requireHumanApproval)
        XCTAssertEqual(backlog.workflow.stageAfterAgentReview, .done,
                       "with the gate off a passing review goes straight to Done")

        config.requireHumanApproval = true
        try backlog.updateWorkflow(config)

        XCTAssertTrue(backlog.workflow.requireHumanApproval)
        XCTAssertEqual(backlog.workflow.stageAfterAgentReview, .awaitingApproval,
                       "the gate switched back on has to hold the next handoff, not the next launch")
    }

    /// The other toggles travel the same path, so they are asserted together
    /// rather than one test each.
    func testTheOtherFlowTogglesReachTheOpenProjectToo() throws {
        let backlog = makeBacklog()

        var config = backlog.workflow
        config.useDraftStage = false
        config.useReviewStage = false
        try backlog.updateWorkflow(config)

        XCTAssertFalse(backlog.workflow.useDraftStage)
        XCTAssertFalse(backlog.workflow.useReviewStage)
        XCTAssertEqual(backlog.workflow.activeStages, [.ready, .active, .awaitingApproval, .done])
        XCTAssertEqual(backlog.workflow.effectiveNewItemStage, .ready)
    }

    // MARK: - And still lands on disk

    /// Memory and file move together: what the project reads back on its next
    /// launch is what the running project is already using.
    func testTheSameSaveLandsOnDisk() throws {
        let backlog = makeBacklog()

        var config = backlog.workflow
        config.requireHumanApproval = false
        config.autopilotPickupStages = [.ready, .draft]
        try backlog.updateWorkflow(config)

        XCTAssertEqual(try decodeConfigFile(), backlog.workflow)

        // A second view model over the same file — what reopening the project
        // does — comes up on the saved flow.
        let reopened = makeBacklog()
        XCTAssertEqual(reopened.workflow, backlog.workflow)
    }

    /// A flow the tab can produce but that does not hold together — pickup from
    /// a stage the toggles just removed — is sanitized once, and the file and
    /// the view model carry that same sanitized value.
    func testWhatLandsOnDiskIsSanitized() throws {
        let backlog = makeBacklog()

        var config = backlog.workflow
        config.useReviewStage = false
        config.autopilotPickupStages = [.inReview]
        try backlog.updateWorkflow(config)

        XCTAssertEqual(backlog.workflow.autopilotPickupStages, [.ready],
                       "pickup from a stage that no longer exists falls back to ready")
        XCTAssertEqual(try decodeConfigFile(), config.sanitized())
        XCTAssertEqual(try decodeConfigFile(), backlog.workflow)
    }

    // MARK: - A save that cannot be written

    /// The failure must not read like a success. `updateWorkflow(_:)` throws, and
    /// the tab turns what it threw into the message it shows beside the controls.
    func testASaveThatCannotBeWrittenGivesTheTabAMessage() throws {
        // A regular file where the config's parent directory belongs: nothing
        // can create the directory, so the write cannot land.
        let blocked = tempDir.appending(path: "blocked")
        try "not a directory".write(to: blocked, atomically: true, encoding: .utf8)
        let backlog = makeBacklog(configURL: blocked.appending(path: "backlog-workflow.json"))

        var config = backlog.workflow
        config.requireHumanApproval = false

        XCTAssertThrowsError(try backlog.updateWorkflow(config)) { error in
            let message = BacklogFlowSettingsView.saveErrorMessage(for: error)
            XCTAssertTrue(message.hasPrefix("Couldn't save backlog flow:"),
                          "the tab shows the failure: \(message)")
        }
    }

    // MARK: - Helpers

    private func makeBacklog(configURL: URL? = nil) -> BacklogViewModel {
        let vm = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        )
        vm.configureWorkflow(configURL: configURL ?? self.configURL)
        return vm
    }

    private func decodeConfigFile() throws -> BacklogWorkflowConfig {
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(BacklogWorkflowConfig.self, from: data)
    }
}
