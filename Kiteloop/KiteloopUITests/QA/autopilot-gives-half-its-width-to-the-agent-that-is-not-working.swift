import XCTest

/// QA flow for `autopilot-gives-half-its-width-to-the-agent-that-is-not-working`:
/// the Autopilot's right column is one transcript pane with Worker and Reviewer
/// tabs instead of two stacked panes, and a tab switches the transcript and
/// the agent the pane names.
final class AutopilotGivesHalfItsWidthToTheAgentThatIsNotWorking: QAStoryboardTestCase {
    private var pane: XCUIElement { app.descendants(matching: .any)["autopilot-transcript-pane"].firstMatch }
    private var workerTab: XCUIElement { app.buttons["autopilot-transcript-tab-worker"].firstMatch }
    private var reviewerTab: XCUIElement { app.buttons["autopilot-transcript-tab-reviewer"].firstMatch }
    private var agentLabel: XCUIElement {
        app.descendants(matching: .any)["autopilot-transcript-agent"].firstMatch
    }
    private var rolesButton: XCUIElement { app.buttons["autopilot-roles-button"] }

    func testTheRightColumnIsOnePaneWithWorkerAndReviewerTabs() {
        step("The Autopilot's right column is one full-height pane with Worker | Reviewer tabs, Worker selected, no dots") {
            launchAndOpenProject()
            app.descendants(matching: .any)["autopilot-sidebar-entry"].firstMatch.click()
            XCTAssertTrue(pane.waitForExistence(timeout: 10), "the right column should be one transcript pane")
            XCTAssertTrue(workerTab.exists, "the pane should have a Worker tab")
            XCTAssertTrue(reviewerTab.exists, "the pane should have a Reviewer tab")
            assertShown(workerTab, hidden: reviewerTab)
            XCTAssertFalse(tabValue(workerTab).contains("new output"), "the Worker tab should carry no dot")
            XCTAssertFalse(tabValue(reviewerTab).contains("new output"), "the Reviewer tab should carry no dot")
            assertOnePaneAtFullHeight()
        }
        step("The header names the worker agent, in capitals, beside the hammer") {
            XCTAssertEqual(text(of: agentLabel), workerName().uppercased(), "the header should name the worker")
        }
        step("Clicking Reviewer selects it and the header names the reviewer agent; the pane is still full height") {
            reviewerTab.click()
            assertShown(reviewerTab, hidden: workerTab)
            XCTAssertEqual(text(of: agentLabel), reviewerName().uppercased(), "the header should name the reviewer")
            assertOnePaneAtFullHeight()
        }
        step("Clicking Worker brings back the worker's transcript and name") {
            workerTab.click()
            assertShown(workerTab, hidden: reviewerTab)
            XCTAssertEqual(text(of: agentLabel), workerName().uppercased(), "the header should name the worker again")
        }
    }

    private func tabValue(_ tab: XCUIElement) -> String { tab.value as? String ?? "" }

    /// A macOS text element carries its text in `value`, a few in `label`.
    private func text(of element: XCUIElement) -> String {
        element.label.isEmpty ? element.value as? String ?? "" : element.label
    }

    /// The pane's own accessibility frame does not report its drawn height, so
    /// this reads what is drawn: a transcript with nothing in it centres its
    /// empty state between spacers. Two stacked panes showed two of those, the
    /// upper one far nearer the tabs than the window's bottom edge; one pane at
    /// full height shows one, about as far below the tabs as above the bottom.
    private func assertOnePaneAtFullHeight(file: StaticString = #filePath, line: UInt = #line) {
        let emptyStateTexts = ["No agent selected", "Waiting for activity..."]
        let emptyStates = app.staticTexts.matching(
            NSPredicate(format: "label IN %@ OR value IN %@", emptyStateTexts, emptyStateTexts))
        XCTAssertEqual(emptyStates.count, 1, "the right column should hold one transcript, not two",
                       file: file, line: line)
        let middle = emptyStates.firstMatch.frame.midY
        let below = app.windows.firstMatch.frame.maxY - middle
        let above = middle - workerTab.frame.maxY
        XCTAssertLessThan(below, above * 1.5,
                          "the transcript should reach the bottom of the column: \(above) pt below the tabs, \(below) pt above the bottom",
                          file: file, line: line)
    }

    private func assertShown(_ shown: XCUIElement, hidden: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !tabValue(shown).hasPrefix("shown") { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(tabValue(shown).hasPrefix("shown"), "\(shown.identifier) should be selected: \(tabValue(shown))",
                      file: file, line: line)
        XCTAssertTrue(tabValue(hidden).hasPrefix("hidden"), "\(hidden.identifier) should not be selected: \(tabValue(hidden))",
                      file: file, line: line)
    }

    /// The roles button reads `Worker: <name> · Reviewer: <name>`; the pane
    /// names the same agents. A role with nobody chosen is named by its role.
    private func workerName() -> String {
        role(named: "Worker", in: rolesButton.label.components(separatedBy: " · ").first ?? "")
    }

    private func reviewerName() -> String {
        role(named: "Reviewer", in: rolesButton.label.components(separatedBy: " · ").last ?? "")
    }

    private func role(named role: String, in part: String) -> String {
        let name = part.replacingOccurrences(of: "\(role): ", with: "")
        return name == "Choose…" ? role : name
    }
}
