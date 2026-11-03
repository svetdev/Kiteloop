import XCTest

/// QA flow for `sidebar-spends-four-cards-on-four-status-lines`: the sidebar's
/// foot is one block of four one-line rows — Planner, Fleet, Waiting on you and
/// Daily budget — where it was four bordered cards, each row still opens what
/// its card opened, and a warning state keeps its colour.
///
/// The sidebar's own identifier covers everything inside it, so a row is found
/// by its label, which starts with the row's name; a drawer is found by its
/// Close button carrying the drawer's identifier. The `askHuman` scenario makes
/// the agent's reply a question left unanswered, which is what puts something
/// in Waiting on you.
final class SidebarSpendsFourCardsOnFourStatusLines: QAStoryboardTestCase {
    private let rowNames = ["Planner", "Fleet", "Waiting on you", "Daily budget"]

    override func setUp() async throws {
        try await super.setUp()
        app.launchEnvironment["UI_TEST_SCENARIO"] = "askHuman"
    }

    func testTheSidebarFootIsOneBlockOfFourOneLineRows() {
        step("The sidebar's foot is one block of four one-line rows: Planner, Fleet, Waiting on you, Daily budget") {
            launchAndOpenProject()
            closeAnyOpenDrawer()
            assertFourOneLineRows()
            XCTAssertTrue(row("Waiting on you").label.contains("nothing is waiting on you"),
                          "nothing should be waiting yet, got: \(row("Waiting on you").label)")
        }
        step("With the agent's question unanswered, Waiting on you reads 1 question in orange; no ceiling is orange; Fleet is grey") {
            sendMessage("Deploy it")
            XCTAssertTrue(waitUntil(timeout: 15) { self.row("Waiting on you").label.contains("1 question") },
                          "the agent's question should be waiting on you, got: \(row("Waiting on you").label)")
            XCTAssertTrue(row("Daily budget").label.contains("no ceiling"), "with no ceiling set, the budget row should say so")
            XCTAssertTrue(row("Fleet").label.contains("taking work"), "the fleet should be taking work")
            assertFourOneLineRows()
        }
        step("Clicking the Planner row opens the Planner drawer, and Planner turns blue") {
            // Wide enough for a drawer beside the chat — after the message is
            // sent, since the grown window leaves the chat input unclickable.
            enlargeWindow()
            row("Planner").click()
            XCTAssertTrue(closeButton("coordinator-drawer").waitForExistence(timeout: 5), "the Planner drawer should open")
        }
        step("Clicking the Planner row again closes its drawer, and Planner is grey again") {
            row("Planner").click()
            XCTAssertTrue(waitUntilGone(closeButton("coordinator-drawer")), "the Planner drawer should close")
        }
        step("Clicking the Fleet row opens the Fleet drawer alone, and Fleet turns blue") {
            row("Fleet").click()
            XCTAssertTrue(closeButton("fleet-drawer").waitForExistence(timeout: 5), "the Fleet drawer should open")
        }
        step("Clicking the Waiting on you row swaps the Fleet drawer for the Waiting on you drawer, listing the question") {
            row("Waiting on you").click()
            XCTAssertTrue(closeButton("waiting-drawer").waitForExistence(timeout: 5),
                          "the Waiting on you drawer should open")
            XCTAssertTrue(waitUntilGone(closeButton("fleet-drawer")), "the Fleet drawer should close")
        }
        step("Clicking the Daily budget row opens the Daily autonomy budget editor beside it") {
            row("Daily budget").click()
            XCTAssertTrue(budgetField.waitForExistence(timeout: 5), "the budget editor should open")
            XCTAssertTrue(app.popovers.staticTexts["Daily autonomy budget"].firstMatch.exists,
                          "the editor should be titled Daily autonomy budget")
        }
        step("Saving 25 closes the editor, and the budget row reads $… of $25.00 in grey") {
            saveBudget("25")
            XCTAssertTrue(waitUntil { self.row("Daily budget").label.contains("$25.00") },
                          "the budget row should read the new ceiling, got: \(row("Daily budget").label)")
            assertFourOneLineRows()
        }
        step("Clearing the ceiling and saving turns the budget row back to orange no ceiling") {
            row("Daily budget").click()
            XCTAssertTrue(budgetField.waitForExistence(timeout: 5), "the budget editor should open")
            budgetField.click()
            budgetField.typeKey("a", modifierFlags: .command)
            budgetField.typeKey(.delete, modifierFlags: [])
            saveBudget(nil)
            XCTAssertTrue(waitUntil { self.row("Daily budget").label.contains("no ceiling") },
                          "the budget row should say there is no ceiling, got: \(row("Daily budget").label)")
        }
        step("Pause on the Fleet row pauses the fleet: the row reads paused in green and the button reads Resume") {
            fleetAction("Pause").click()
            XCTAssertTrue(waitUntil(timeout: 10) { self.row("Fleet").label.contains("paus") },
                          "the fleet row should read pausing or paused, got: \(row("Fleet").label)")
            XCTAssertTrue(fleetAction("Resume").waitForExistence(timeout: 10), "the button should read Resume")
            XCTAssertLessThan(row("Fleet").frame.height, 24, "the Fleet row should still be one line high")
        }
        step("Resume on the Fleet row lets it take work again, in grey") {
            fleetAction("Resume").click()
            XCTAssertTrue(waitUntil(timeout: 10) { self.row("Fleet").label.contains("taking work") },
                          "the fleet row should read taking work, got: \(row("Fleet").label)")
            XCTAssertTrue(fleetAction("Pause").waitForExistence(timeout: 10), "the button should read Pause again")
        }
        // The row's tooltip carries its full status, but XCUITest's hover does
        // not raise a tooltip, so the full text is shown the other way a person
        // can read it: with the sidebar dragged wide enough to hold it.
        step("Dragged to its widest, the sidebar's rows read their full status on one line") {
            let before = row("Planner").frame.width
            dragSidebarEdge(by: 300)
            XCTAssertGreaterThan(row("Planner").frame.width, before + 100, "the sidebar should have widened")
            assertFourOneLineRows()
            XCTAssertTrue(row("Fleet").label.contains("taking work — all quiet"), "got: \(row("Fleet").label)")
            XCTAssertTrue(row("Daily budget").label.contains("no ceiling — autonomy can't arm"),
                          "got: \(row("Daily budget").label)")
        }
        step("Dragged to its narrowest, the sidebar still shows four one-line rows, statuses cut off with …") {
            let before = row("Planner").frame.width
            dragSidebarEdge(by: -400)
            XCTAssertLessThan(row("Planner").frame.width, before - 20, "the sidebar should have narrowed")
            assertFourOneLineRows()
        }
    }

    /// Asserts the four rows are there, in order, each one line high, and
    /// stacked into one compact block.
    private func assertFourOneLineRows(file: StaticString = #filePath, line: UInt = #line) {
        let rows = rowNames.map(row)
        for (name, row) in zip(rowNames, rows) {
            XCTAssertTrue(row.waitForExistence(timeout: 15), "the \(name) row should appear", file: file, line: line)
            XCTAssertLessThan(row.frame.height, 24, "the \(name) row should be one line high", file: file, line: line)
        }
        let tops = rows.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(), "the rows should read top to bottom in order", file: file, line: line)
        XCTAssertLessThan(rows[3].frame.maxY - rows[0].frame.minY, 110,
                          "the four rows should stack into one compact block", file: file, line: line)
    }

    /// The sidebar row whose label starts with `name`.
    private func row(_ name: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier == 'agent-sidebar' AND label BEGINSWITH %@", name))
            .firstMatch
    }

    /// The Pause or Resume button at the end of the Fleet row.
    private func fleetAction(_ title: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier == 'agent-sidebar' AND label ENDSWITH %@", title))
            .firstMatch
    }

    private var budgetField: XCUIElement { app.popovers.textFields.firstMatch }

    /// Types `value` into the open budget editor, if any, and presses Save.
    private func saveBudget(_ value: String?) {
        if let value {
            budgetField.click()
            budgetField.typeText(value)
        }
        app.popovers.buttons["Save"].firstMatch.click()
        XCTAssertTrue(waitUntilGone(budgetField), "Save should close the editor")
        // Past the popover's fade, so the picture holds the row and not its ghost.
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func closeButton(_ drawer: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == 'Close'", drawer)).firstMatch
    }

    /// Closes whatever drawer an earlier run of the QA copy left open.
    private func closeAnyOpenDrawer() {
        for drawer in ["coordinator-drawer", "fleet-drawer", "waiting-drawer"]
        where closeButton(drawer).waitForExistence(timeout: 1) {
            closeButton(drawer).click()
        }
    }

    /// Drags the resizer on the sidebar's right edge by `dx` points. The status
    /// block is centred in the sidebar, so its right edge is as far past the
    /// Planner row as the row is from the window's left.
    private func dragSidebarEdge(by dx: CGFloat) {
        let window = app.windows.firstMatch
        let planner = row("Planner").frame
        let edgeX = planner.maxX + (planner.minX - window.frame.minX)
        let edge = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: edgeX - window.frame.minX, dy: window.frame.height / 2))
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: dx, dy: 0)),
                   withVelocity: 150, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Moves the window to the screen's top-left and grows it to fill the
    /// screen above the Dock: the test window opens at 900pt, too narrow for the
    /// sidebar, a drawer and the chat side by side.
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

    /// Waits up to `timeout` seconds for `element` to be gone.
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { !element.exists }
    }

    /// Waits up to `timeout` seconds for `condition` to hold.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { Thread.sleep(forTimeInterval: 0.25) }
        return condition()
    }
}
