import XCTest
@testable import Kiteloop

final class PendingAgentLaunchTests: XCTestCase {

    // MARK: - isLaunchAcknowledgement

    func testRecognizesTheLaunchSentenceFromTheAgentTool() {
        XCTAssertTrue(PendingAgentLaunch.isLaunchAcknowledgement(
            toolName: "Agent", output: "Async agent launched successfully. Running in the background."
        ))
    }

    func testRecognizesTheLaunchSentenceFromTheTaskAlias() {
        XCTAssertTrue(PendingAgentLaunch.isLaunchAcknowledgement(
            toolName: "Task", output: "Async agent launched successfully."
        ))
    }

    func testIgnoresTheSameTextFromAnUnrelatedTool() {
        XCTAssertFalse(PendingAgentLaunch.isLaunchAcknowledgement(
            toolName: "Bash", output: "Async agent launched successfully."
        ))
    }

    func testIgnoresAnAgentToolResultThatIsNotTheLaunchAcknowledgement() {
        XCTAssertFalse(PendingAgentLaunch.isLaunchAcknowledgement(
            toolName: "Agent", output: "The agent finished: added the fix."
        ))
    }

    func testIgnoresANilToolName() {
        XCTAssertFalse(PendingAgentLaunch.isLaunchAcknowledgement(
            toolName: nil, output: "Async agent launched successfully."
        ))
    }
}
