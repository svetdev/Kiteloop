import XCTest
@testable import Kiteloop

/// The fleet board's paused cell: "by hand" only for a project parked with the
/// board's paused switch, never for a run its own autopilot paused.
final class FleetBoardPausedWordingTests: XCTestCase {

    /// A project parked on the board reads as it always has.
    func testParkedProjectReadsPausedByHand() {
        XCTAssertEqual(FleetBoard.pausedWording(parked: true, atGate: 2).text, "paused by hand · 2 at gate")
    }

    /// A run paused with the switch off claims no hand and keeps the gate count.
    func testRunPausedWithSwitchOffDoesNotSayByHand() {
        let text = FleetBoard.pausedWording(parked: false, atGate: 3).text
        XCTAssertFalse(text.contains("by hand"), text)
        XCTAssertTrue(text.contains("3 at gate"), text)
    }

    /// Its tooltip sends the operator to the Autopilot tab for the reason.
    func testRunPausedHelpNamesTheAutopilotTab() {
        XCTAssertTrue(FleetBoard.pausedWording(parked: false, atGate: 0).help.contains("Autopilot tab"))
    }
}
