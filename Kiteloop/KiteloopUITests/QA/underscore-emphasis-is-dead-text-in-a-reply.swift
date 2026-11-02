import XCTest

/// QA flow for `underscore-emphasis-is-dead-text-in-a-reply`: a reply written with
/// underscore emphasis is drawn italic and bold with the underscores gone, while
/// an identifier keeps its own. The `underscoreEmphasis` mock replies
/// "Be _careful_ here: __never__ rename snake_case_name."
final class UnderscoreEmphasisIsDeadTextInAReply: QAStoryboardTestCase {
    func testUnderscoreEmphasisIsDrawnAndIdentifiersKeepTheirUnderscores() {
        step("Kiteloop opens on its start screen, offering Quick Start") {
            app.launchEnvironment["UI_TEST_SCENARIO"] = "underscoreEmphasis"
            app.launch()
            XCTAssertTrue(app.buttons["quick-start-button"].waitForExistence(timeout: 15))
        }
        step("Quick Start opens a project with its chat ready for a message") {
            app.buttons["quick-start-button"].click()
            let textView = app.textViews["input-text-field"]
            let textField = app.textFields["input-text-field"]
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, !textView.exists, !textField.exists { Thread.sleep(forTimeInterval: 0.5) }
            XCTAssertTrue(textView.exists || textField.exists, "Chat input should appear after the project opens")
        }
        step("The reply reads \"Be careful here: never rename snake_case_name.\" — careful in italics, never in bold, no underscores around either, snake_case_name with both underscores") {
            sendMessage("Hello")
            XCTAssertTrue(waitForResponse(containing: "Be careful here: never rename snake_case_name."))
            XCTAssertFalse(waitForResponse(containing: "_careful_", timeout: 2))
            XCTAssertFalse(waitForResponse(containing: "__never__", timeout: 2))
        }
    }
}
