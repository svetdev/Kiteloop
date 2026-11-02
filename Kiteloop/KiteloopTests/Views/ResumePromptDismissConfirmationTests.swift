import XCTest
@testable import Kiteloop

/// Dismiss and Dismiss All on the Interrupted Runs sheet ask before they act,
/// and the question names what is lost: the run's title, or how many runs,
/// and that they can no longer be resumed.
final class ResumePromptDismissConfirmationTests: XCTestCase {

    func testOneRunMessageNamesTheRun() {
        let message = ResumePromptSheet.dismissRunMessage(displayName: "Fix the login flow")
        XCTAssertTrue(message.contains("Fix the login flow"))
    }

    func testOneRunMessageSaysTheRunCanNoLongerBeResumed() {
        let message = ResumePromptSheet.dismissRunMessage(displayName: "Fix the login flow")
        XCTAssertTrue(message.contains("deletes its checkpoints"))
        XCTAssertTrue(message.contains("can no longer be resumed"))
    }

    func testAllRunsMessageStatesTheCount() {
        let message = ResumePromptSheet.dismissAllMessage(count: 7)
        XCTAssertTrue(message.contains("7 interrupted runs"))
    }

    func testAllRunsMessageSaysTheRunsCanNoLongerBeResumed() {
        let message = ResumePromptSheet.dismissAllMessage(count: 3)
        XCTAssertTrue(message.contains("deletes their checkpoints"))
        XCTAssertTrue(message.contains("can no longer be resumed"))
    }

    func testAllRunsMessageSaysOneRunInTheSingular() {
        let message = ResumePromptSheet.dismissAllMessage(count: 1)
        XCTAssertTrue(message.contains("1 interrupted run "))
    }
}
