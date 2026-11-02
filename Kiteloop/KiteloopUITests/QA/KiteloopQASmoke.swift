import XCTest

/// Kiteloop's QA onboarding check (`smoke` in kiteloop-qa.json): the QA copy
/// launches against a throwaway home, opens a project, and its storyboard is
/// written — what every QA run depends on.
final class KiteloopQASmoke: QAStoryboardTestCase {
    func testTheQACopyOpensAProjectAndIsPhotographed() {
        step("Kiteloop opens on its start screen, offering Quick Start") {
            app.launch()
            XCTAssertTrue(app.buttons["quick-start-button"].waitForExistence(timeout: 15))
            assertNoPrivacyDialog()
            assertNoRecentProjects()
        }
        step("Quick Start opens a project with its chat ready for a message") {
            launchAndOpenProjectAfterLaunch()
            assertNoPrivacyDialog()
        }
    }

    /// `launchAndOpenProject` without its own launch: the app is already up.
    private func launchAndOpenProjectAfterLaunch() {
        app.buttons["quick-start-button"].click()
        // Either variant of the input, as `launchAndOpenProject` waits for it.
        let textView = app.textViews["input-text-field"]
        let textField = app.textFields["input-text-field"]
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, !textView.exists, !textField.exists { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(textView.exists || textField.exists, "Chat input should appear after the project opens")
    }
}
