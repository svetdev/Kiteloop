import XCTest

/// QA flow for `planner-and-fleet-drawers-each-carry-a-projects-table`: the
/// Planner and the Fleet share one drawer — the Fleet row opens it at the top,
/// the Planner row at the Planner section — with one Projects table carrying a
/// last-24h column, beside the Autopilot.
///
/// The sidebar's own identifier covers everything inside it, so a row is found
/// by its label; the drawer is found by its Close button carrying the drawer's
/// identifier, and its sections by theirs.
final class PlannerAndFleetDrawersEachCarryAProjectsTable: QAStoryboardTestCase {
    func testThePlannerAndTheFleetShareOneDrawer() {
        step("The Fleet row opens the one drawer at the top, beside the Autopilot") {
            launchAndOpenProject()
            enlargeWindow()
            closeAnyOpenDrawer()
            app.descendants(matching: .any)["autopilot-sidebar-entry"].firstMatch.click()
            row("Fleet").click()
            XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "the drawer should open")
            XCTAssertTrue(app.descendants(matching: .any)["fleet-board"].firstMatch.exists,
                          "one Projects table should be in the drawer")
        }
        step("The Planner row moves the same drawer to its Planner section") {
            row("Planner").click()
            XCTAssertTrue(app.descendants(matching: .any)["fleet-drawer-planner"].firstMatch
                .waitForExistence(timeout: 5), "the Planner section should be in the drawer")
            XCTAssertTrue(closeButton.exists, "still one drawer, the same one")
        }
        step("The Planner row again closes the drawer") {
            row("Planner").click()
            XCTAssertTrue(waitUntil { !self.closeButton.exists }, "the drawer should close")
        }
    }

    private var closeButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'fleet-drawer' AND label == 'Close'")).firstMatch
    }

    private func row(_ name: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier == 'agent-sidebar' AND label BEGINSWITH %@", name))
            .firstMatch
    }

    private func closeAnyOpenDrawer() {
        for drawer in ["fleet-drawer", "waiting-drawer"] {
            let close = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == 'Close'", drawer)).firstMatch
            if close.waitForExistence(timeout: 1) { close.click() }
        }
    }

    /// Wide enough for the sidebar, the drawer and the Autopilot side by side.
    private func enlargeWindow() {
        let window = app.windows.firstMatch
        let screen = XCUIScreen.main.screenshot().image.size
        guard window.frame.width < screen.width - 100 else { return }
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(
            CGVector(dx: screen.width - 40 - window.frame.maxX, dy: screen.height - 110 - window.frame.maxY)))
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { Thread.sleep(forTimeInterval: 0.25) }
        return condition()
    }
}
