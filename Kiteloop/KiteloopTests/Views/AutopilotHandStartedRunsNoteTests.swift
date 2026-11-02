import XCTest
@testable import Kiteloop

/// Project Settings › Autopilot's note under the autonomy dial: the one pair the
/// dial reads as Off while a run started by hand still lands itself.
final class AutopilotHandStartedRunsNoteTests: XCTestCase {
    private func note(_ work: Bool, _ gate: BacklogAutopilot.ApprovalGate) -> String? {
        AutopilotRunSettingsForm.handStartedRunsNote(autonomousWorkEnabled: work, approvalGate: gate)
    }

    func testUnattendedRunsOffWithTheGateAtLandSaysAHandStartedRunLands() throws {
        let text = try XCTUnwrap(note(false, .land))
        XCTAssertTrue(text.contains("started by hand"), text)
        XCTAssertTrue(text.contains("merged"), text)
    }

    func testUnattendedRunsOnOrTheGateAtProposeSaysNothing() {
        XCTAssertNil(note(true, .land))
        XCTAssertNil(note(true, .propose))
        XCTAssertNil(note(false, .propose))
    }
}
