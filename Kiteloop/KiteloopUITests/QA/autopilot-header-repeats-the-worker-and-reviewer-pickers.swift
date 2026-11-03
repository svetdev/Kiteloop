import XCTest

/// QA flow for `autopilot-header-repeats-the-worker-and-reviewer-pickers`: the
/// Autopilot header names the worker and reviewer in one button instead of two
/// pickers, the button opens the project settings sheet on its Autopilot page
/// where the pickers are, and a choice made there shows in the header.
final class AutopilotHeaderRepeatsTheWorkerAndReviewerPickers: QAStoryboardTestCase {
    private var rolesButton: XCUIElement { app.buttons["autopilot-roles-button"] }
    private var settingsPage: XCUIElement {
        app.descendants(matching: .any)["project-settings-autopilot-page"].firstMatch
    }
    private var workerPicker: XCUIElement {
        app.popUpButtons["project-settings-autopilot-worker-picker"].firstMatch
    }
    private var reviewerPicker: XCUIElement {
        app.popUpButtons["project-settings-autopilot-reviewer-picker"].firstMatch
    }
    private var runBlockedHint: XCUIElement {
        app.descendants(matching: .any)["autopilot-run-blocked-hint"].firstMatch
    }

    func testTheHeaderNamesTheRolesAndOpensSettings() {
        var agent = ""
        step("The Autopilot header names the worker and reviewer in one button, with no pickers") {
            launchAndOpenProject()
            app.descendants(matching: .any)["autopilot-sidebar-entry"].firstMatch.click()
            XCTAssertTrue(rolesButton.waitForExistence(timeout: 10), "the header should show the roles button")
            XCTAssertTrue(rolesButton.label.hasPrefix("Worker: "), "the button should name the worker: \(rolesButton.label)")
            XCTAssertTrue(rolesButton.label.contains(" · Reviewer: "), "the button should name the reviewer: \(rolesButton.label)")
            XCTAssertFalse(app.descendants(matching: .any)["autopilot-worker-picker"].exists,
                           "the header should have no Worker picker")
            XCTAssertFalse(app.descendants(matching: .any)["autopilot-reviewer-picker"].exists,
                           "the header should have no Reviewer picker")
        }
        step("Hovering the roles button shows a tooltip saying it opens Autopilot settings") {
            // A tooltip is no element XCUITest can query; it is drawn over the
            // window, so the step's photograph is where it shows.
            rolesButton.hover()
            Thread.sleep(forTimeInterval: 3)
            XCTAssertTrue(rolesButton.isHittable, "the roles button should still be under the pointer")
        }
        step("Clicking the roles button opens settings on the Autopilot page, with the Worker and Reviewer pickers") {
            rolesButton.click()
            assertSettingsOpen()
            XCTAssertFalse(app.descendants(matching: .any)["autopilot-settings-popover"].exists,
                           "the gear's popover should not open")
        }
        step("With the worker set to Choose… in settings, the header says Worker: Choose… and Run says why it is off") {
            agent = choose(in: reviewerPicker, item: nil)
            _ = choose(in: workerPicker, item: "Choose…")
            app.buttons["project-settings-done-button"].click()
            XCTAssertTrue(waitForLabel("Worker: Choose… · Reviewer: \(agent)"),
                          "the header should read Choose… for the worker: \(rolesButton.label)")
            XCTAssertTrue(runBlockedHint.waitForExistence(timeout: 5), "the action bar should say a worker is missing")
            XCTAssertTrue(app.staticTexts["Pick a worker"].firstMatch.exists, "the warning should read Pick a worker")
        }
        step("With the worker set back in settings, the header names it and the warning is gone") {
            rolesButton.click()
            assertSettingsOpen()
            _ = choose(in: workerPicker, item: agent)
            app.buttons["project-settings-done-button"].click()
            XCTAssertTrue(waitForLabel("Worker: \(agent) · Reviewer: \(agent)"),
                          "the header should name \(agent): \(rolesButton.label)")
            XCTAssertTrue(waitUntilGone(runBlockedHint), "the Run warning should be gone")
        }
        step("The gear still opens its popover, which holds no Worker or Reviewer picker") {
            app.buttons["autopilot-settings-button"].click()
            XCTAssertTrue(app.descendants(matching: .any)["autopilot-settings-popover"].firstMatch
                .waitForExistence(timeout: 5), "the gear should open its popover")
            XCTAssertFalse(workerPicker.exists, "the popover should hold no Worker picker")
            XCTAssertFalse(app.descendants(matching: .any)["autopilot-worker-picker"].exists,
                           "the popover should hold no Worker picker")
        }
        step("With the Planner drawer open in a narrow window, the header stays one row and the status shows") {
            app.typeKey(.escape, modifierFlags: [])
            let planner = app.buttons
                .matching(NSPredicate(format: "identifier == 'agent-sidebar' AND label BEGINSWITH 'Planner'"))
                .firstMatch
            XCTAssertTrue(planner.waitForExistence(timeout: 10), "the sidebar's Planner button should appear")
            if !closeButton("fleet-drawer").exists { planner.click() }
            XCTAssertTrue(closeButton("fleet-drawer").waitForExistence(timeout: 5), "the drawer should open at the Planner")
            XCTAssertLessThan(rolesButton.frame.height, 30, "the roles button should stay one line high")
            let status = app.staticTexts["Idle"].firstMatch
            XCTAssertTrue(status.exists, "the status should still be in the header")
            XCTAssertEqual(status.frame.midY, rolesButton.frame.midY, accuracy: 10,
                           "the status and the roles button should sit in one row")
        }
    }

    /// Picks `item` — or, when nil, the first agent — from `picker`'s menu, and returns what it picked.
    private func choose(in picker: XCUIElement, item: String?) -> String {
        picker.click()
        // The picker's own items, never the menu bar's: an app-wide menu query
        // reaches the Apple menu.
        let items = picker.descendants(matching: .menuItem)
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5), "the picker's menu should open")
        let title = item ?? items.allElementsBoundByIndex
            .map(\.title)
            .first { $0 != "Choose…" && $0 != "No separate reviewer" && !$0.isEmpty } ?? ""
        XCTAssertFalse(title.isEmpty, "the picker should list at least one agent")
        let menuItem = items.matching(NSPredicate(format: "title == %@", title)).firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "the menu should offer \(title)")
        menuItem.click()
        XCTAssertTrue(waitUntilGone(menuItem), "the picker's menu should close")
        return title
    }

    private func closeButton(_ drawer: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == 'Close'", drawer)).firstMatch
    }

    private func assertSettingsOpen(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(settingsPage.waitForExistence(timeout: 10), "Autopilot settings should open",
                      file: file, line: line)
        XCTAssertTrue(workerPicker.waitForExistence(timeout: 5), "settings should show the Worker picker",
                      file: file, line: line)
        XCTAssertTrue(reviewerPicker.exists, "settings should show the Reviewer picker", file: file, line: line)
    }

    /// Waits up to `timeout` seconds for the roles button to read `label`.
    private func waitForLabel(_ label: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, rolesButton.label != label { Thread.sleep(forTimeInterval: 0.25) }
        return rolesButton.label == label
    }

    /// Waits up to `timeout` seconds for `element` to be gone.
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, element.exists { Thread.sleep(forTimeInterval: 0.25) }
        return !element.exists
    }
}
