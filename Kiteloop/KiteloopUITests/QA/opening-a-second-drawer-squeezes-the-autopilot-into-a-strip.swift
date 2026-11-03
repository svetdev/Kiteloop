import XCTest

/// QA flow for `opening-a-second-drawer-squeezes-the-autopilot-into-a-strip`:
/// the Fleet drawer — which carries the Planner since 2026-11-02 — and the
/// Waiting on you drawer open one at a time: opening one closes the other,
/// the Planner and Fleet rows move within the one drawer, closing it leaves
/// none, it keeps its width, and flags saved as open for two drawers reopen
/// only one.
///
/// The sidebar's own identifier covers everything inside it, so its three
/// buttons are found by label; each drawer's identifier likewise covers its
/// contents, so a drawer is found by its Close button carrying that identifier.
final class OpeningASecondDrawerSqueezesTheAutopilotIntoAStrip: QAStoryboardTestCase {
    private let planner = "fleet-drawer"
    private let fleet = "fleet-drawer"
    private let waiting = "waiting-drawer"

    func testOnlyOneDrawerIsOpenAtATime() {
        var gained: CGFloat = 0
        step("The Autopilot fills the center column with no drawer beside it") {
            launchAndOpenProject()
            enlargeWindow()
            closeAnyOpenDrawer()
            app.descendants(matching: .any)["autopilot-sidebar-entry"].firstMatch.click()
            XCTAssertTrue(app.buttons["autopilot-settings-button"].waitForExistence(timeout: 10))
            assertOpen(nil)
        }
        step("Clicking Fleet opens the Fleet drawer alone beside the Autopilot") {
            toggle(fleet)
            assertOpen(fleet)
        }
        step("Clicking Planner keeps one drawer, the Fleet drawer at its Planner section, beside the Autopilot") {
            toggle(planner)
            assertOpen(planner)
        }
        step("Clicking Waiting on you shows only the Waiting on you drawer") {
            toggle(waiting)
            assertOpen(waiting)
        }
        step("Clicking Fleet again shows only the Fleet drawer") {
            toggle(fleet)
            assertOpen(fleet)
        }
        step("Clicking Fleet once more leaves no drawer open") {
            toggle(fleet)
            assertOpen(nil)
        }
        step("Fleet then Planner leaves one drawer beside the Autopilot, not two") {
            toggle(fleet)
            assertOpen(fleet)
            toggle(planner)
            assertOpen(planner)
        }
        step("The drawer's close button leaves no drawer open") {
            closeButton(planner).click()
            assertOpen(nil)
        }
        step("The Fleet drawer, widened by dragging its edge, stays just as wide moving to the Planner and back") {
            toggle(fleet)
            assertOpen(fleet)
            let before = closeButton(fleet).frame.maxX
            dragDrawerEdge(fleet, by: 60)
            let widened = closeButton(fleet).frame.maxX
            XCTAssertGreaterThan(widened - before, 20, "dragging the Fleet drawer's edge should widen it")
            toggle(planner)
            assertOpen(planner)
            toggle(fleet)
            assertOpen(fleet)
            XCTAssertEqual(closeButton(fleet).frame.maxX, widened, accuracy: 3,
                           "Fleet should reopen at the width it was dragged to")
            gained = widened - before
        }
        step("Relaunched with Fleet open, only the Fleet drawer is shown") {
            // Back to the width it had, so the next run starts where this one did.
            dragDrawerEdge(fleet, by: -gained)
            relaunch()
            assertOpen(fleet)
        }
        step("Relaunched with the retired Planner flag and Fleet both saved as open, only the Fleet drawer is shown") {
            relaunch(arguments: ["-coordinatorDrawerOpen", "YES", "-fleetDrawerOpen", "YES"])
            assertOpen(planner)
        }
        step("With the Inspector open, Planner and Fleet move within one drawer and the Inspector stays open") {
            relaunch()
            toggle(planner)
            assertOpen(planner)
            app.buttons["inspector-toggle"].click()
            let inspector = app.descendants(matching: .any)["inspector-tab-picker"].firstMatch
            XCTAssertTrue(inspector.waitForExistence(timeout: 5), "the Inspector should open")
            toggle(fleet)
            assertOpen(fleet)
            XCTAssertTrue(inspector.exists, "the Inspector should still be open")
        }
    }

    /// The sidebar button that opens `drawer`, by the label it reads.
    private func sidebarButton(_ drawer: String) -> XCUIElement {
        let name = [planner: "Planner", fleet: "Fleet", waiting: "Waiting on you"][drawer] ?? drawer
        return app.buttons
            .matching(NSPredicate(format: "identifier == 'agent-sidebar' AND label BEGINSWITH %@", name))
            .firstMatch
    }

    private func closeButton(_ drawer: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == 'Close'", drawer)).firstMatch
    }

    private func toggle(_ drawer: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = sidebarButton(drawer)
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the sidebar's \(drawer) button should appear",
                      file: file, line: line)
        button.click()
    }

    /// Closes whatever drawer an earlier run of the QA copy left open.
    private func closeAnyOpenDrawer() {
        for drawer in [planner, fleet, waiting] where closeButton(drawer).waitForExistence(timeout: 1) {
            closeButton(drawer).click()
        }
    }

    /// Drags the resizer on `drawer`'s right edge — just past its header's
    /// trailing padding — by `dx` points.
    private func dragDrawerEdge(_ drawer: String, by dx: CGFloat) {
        let close = closeButton(drawer).frame
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let edge = origin.withOffset(CGVector(dx: close.maxX + 8.5 - window.frame.minX,
                                              dy: close.midY + 200 - window.frame.minY))
        // Slowly, and held at the end, so the drag gesture follows all of it.
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: dx, dy: 0)),
                   withVelocity: 150, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Relaunches the app on the same throwaway home, with `arguments`, and
    /// waits for the project's sidebar.
    private func relaunch(arguments: [String] = []) {
        app.terminate()
        app.launchArguments = arguments
        app.launch()
        let quickStart = app.buttons["quick-start-button"]
        if quickStart.waitForExistence(timeout: 8) { quickStart.click() }
        XCTAssertTrue(sidebarButton(planner).waitForExistence(timeout: 25), "the project should reopen")
        enlargeWindow()
        app.descendants(matching: .any)["autopilot-sidebar-entry"].firstMatch.click()
    }

    /// Moves the window to the screen's top-left and grows it to fill the
    /// screen above the Dock: the test window opens at 900pt, too narrow for the sidebar,
    /// a drawer, the Autopilot and the Inspector side by side.
    private func enlargeWindow() {
        let window = app.windows.firstMatch
        let screen = XCUIScreen.main.screenshot().image.size
        guard window.frame.width < screen.width - 100 else { return }
        let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 20))
        title.press(forDuration: 0.2, thenDragTo: title.withOffset(
            CGVector(dx: 20 - window.frame.minX, dy: 40 - window.frame.minY)))
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(
            CGVector(dx: screen.width - 40 - window.frame.maxX, dy: screen.height - 110 - window.frame.maxY)))
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Asserts `drawer` is the one drawer shown, or none when nil.
    private func assertOpen(_ drawer: String?, file: StaticString = #filePath, line: UInt = #line) {
        if let drawer {
            XCTAssertTrue(closeButton(drawer).waitForExistence(timeout: 5), "\(drawer) should be open",
                          file: file, line: line)
        }
        for other in [planner, fleet, waiting] where other != drawer {
            XCTAssertTrue(waitUntilGone(closeButton(other)), "\(other) should be closed", file: file, line: line)
        }
    }

    /// Waits up to `timeout` seconds for `element` to be gone.
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, element.exists { Thread.sleep(forTimeInterval: 0.25) }
        return !element.exists
    }
}
