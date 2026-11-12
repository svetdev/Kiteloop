import XCTest
import SwiftUI
import KiteloopCore
import KiteloopTestSupport
@testable import Kiteloop

/// The fleet's two per-project switches on the project's own Autopilot tab.
final class AutopilotFleetControlsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - What the row says

    func testAParkedProjectSaysNothingStartsWhateverItsConsent() {
        for autonomous in [true, false] {
            XCTAssertEqual(AutopilotFleetControls.note(paused: true, autonomous: autonomous),
                           "Paused by hand — no run starts here until it is switched off.")
        }
    }

    func testAnUnparkedProjectSaysWhoStartsItsRuns() {
        XCTAssertEqual(AutopilotFleetControls.note(paused: false, autonomous: true),
                       "The fleet may start runs here when work is run unattended.")
        XCTAssertEqual(AutopilotFleetControls.note(paused: false, autonomous: false),
                       "Runs start here only when you press Run.")
    }

    // MARK: - Parking

    /// Parking from the tab writes the project's own config, keeps the goal
    /// the Portfolio stated, and says so to every surface showing the switch.
    func testParkingWritesTheConfigKeepsTheGoalAndAnnouncesIt() async throws {
        let path = tempDir.path(percentEncoded: false)
        let project = KiteloopProject(rootURL: tempDir)
        try project.setPaused(false, goal: "Ship the thing")
        let announced = expectation(forNotification: .projectParkingChanged, object: nil) { note in
            note.object as? String == path
        }

        let saved = await PortfolioSummaryLoader.park(true, projectPath: path)

        XCTAssertTrue(saved)
        await fulfillment(of: [announced], timeout: 5)
        XCTAssertTrue(project.isPaused)
        XCTAssertEqual(project.goal, "Ship the thing")

        await PortfolioSummaryLoader.park(false, projectPath: path)
        XCTAssertFalse(project.isPaused)
        XCTAssertEqual(project.goal, "Ship the thing")
    }

    // MARK: - Drawn

    /// The row is one line whatever it says: its labels truncate, so a narrow
    /// pane cannot make the title area tall.
    @MainActor
    func testTheRowIsOneLineParkedOrNot() async throws {
        let unparked = try await drawnHeight(of: AutopilotFleetControls(autopilot: BacklogAutopilot()))
        let parked = try await drawnHeight(of: AutopilotFleetControls(autopilot: BacklogAutopilot(), paused: true))

        XCTAssertGreaterThan(unparked, 0)
        XCTAssertEqual(parked, unparked)
        XCTAssertLessThan(unparked, 40, "one line of mini switches")
    }

    @MainActor
    private func drawnHeight(of view: some View) async throws -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 420))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await eventually("the view is laid out") { host.fittingSize.height > 0 }
        return host.fittingSize.height
    }
}
