import XCTest
@testable import Kiteloop

/// Project Settings › Autopilot's reviewer picker: its empty choice is "No
/// separate reviewer", a setting rather than an unset slot, and choosing it
/// stores no reviewer.
final class AutopilotReviewerPickerTests: XCTestCase {
    func testTheEmptyChoiceIsNoSeparateReviewer() {
        XCTAssertEqual(AutopilotRunSettingsForm.noReviewerChoice, "No separate reviewer")
    }

    func testChoosingNoSeparateReviewerStoresNoReviewer() {
        XCTAssertNil(AutopilotRunSettingsForm.reviewerAgentID(forSelection: ""))
    }

    func testChoosingAnAgentStoresItsID() {
        XCTAssertEqual(AutopilotRunSettingsForm.reviewerAgentID(forSelection: "reviewer-1"), "reviewer-1")
    }
}
