import XCTest

/// QA flow for `a-stopped-agent-looks-like-a-running-one-and-cannot-be-started`:
/// Stop Agent from the sidebar's context menu leaves the row reading
/// "Stopped · <model>" and the menu offering Start Agent in its place; Start
/// Agent brings the agent back and the row reads its model alone again.
final class AStoppedAgentLooksLikeARunningOneAndCannotBeStarted: QAStoryboardTestCase {
    func testAStoppedAgentSaysSoAndCanBeStartedAgain() {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'agent-' AND identifier != 'agent-sidebar'"))
            .firstMatch
        let stoppedSubtitle = app.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH 'Stopped · ' OR label BEGINSWITH 'Stopped · '"))
            .firstMatch
        let stopItem = app.menuItems
            .matching(NSPredicate(format: "identifier BEGINSWITH 'stop-agent-' OR title == 'Stop Agent'"))
            .firstMatch
        let startItem = app.menuItems
            .matching(NSPredicate(format: "identifier BEGINSWITH 'start-agent-' OR title == 'Start Agent'"))
            .firstMatch

        step("A project is open; its agent's row reads its model alone, with no \"Stopped\"") {
            launchAndOpenProject()
            XCTAssertTrue(row.waitForExistence(timeout: 15), "the agent's sidebar row should appear")
            XCTAssertTrue(waitUntilGone(stoppedSubtitle), "a running agent's row should not read \"Stopped · \"")
        }
        step("Right-clicking the agent's row shows Stop Agent and no Start Agent") {
            row.rightClick()
            XCTAssertTrue(stopItem.waitForExistence(timeout: 5))
            XCTAssertFalse(startItem.exists)
        }
        step("After Stop Agent the row reads \"Stopped · \" followed by the model") {
            stopItem.click()
            XCTAssertTrue(stoppedSubtitle.waitForExistence(timeout: 5))
            let text = (stoppedSubtitle.value as? String) ?? stoppedSubtitle.label
            XCTAssertGreaterThan(text.count, "Stopped · ".count, "the subtitle should still name the model: \(text)")
        }
        step("Right-clicking the stopped row shows Start Agent and no Stop Agent") {
            row.rightClick()
            XCTAssertTrue(startItem.waitForExistence(timeout: 5))
            XCTAssertFalse(stopItem.exists)
        }
        step("After Start Agent no error alert appears") {
            startItem.click()
            XCTAssertTrue(waitUntilGone(stoppedSubtitle), "the row should drop \"Stopped · \" once the agent is up")
            XCTAssertFalse(app.staticTexts["Something Went Wrong"].exists)
        }
        step("Right-clicking the row offers Stop Agent again and no Start Agent") {
            row.rightClick()
            XCTAssertTrue(stopItem.waitForExistence(timeout: 5))
            XCTAssertFalse(startItem.exists)
            app.typeKey(.escape, modifierFlags: [])
        }
        step("The row reads its model alone again, with no \"Stopped · \"") {
            XCTAssertTrue(waitUntilGone(stopItem), "the menu should be closed")
            XCTAssertFalse(stoppedSubtitle.exists)
        }
    }

    /// Waits up to `timeout` seconds for `element` to be gone.
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, element.exists { Thread.sleep(forTimeInterval: 0.25) }
        return !element.exists
    }
}
