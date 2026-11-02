import XCTest

// XCUI's APIs are all main-actor isolated; isolation is inherited by subclasses.
@MainActor
class KiteloopUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
    }

    func launchAndOpenProject() {
        app.launch()
        let quickStart = app.buttons["quick-start-button"]
        XCTAssertTrue(quickStart.waitForExistence(timeout: 10))
        quickStart.click()
        // Wait for either textView or textField variant of the input
        let textView = app.textViews["input-text-field"]
        let textField = app.textFields["input-text-field"]
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if textView.exists || textField.exists { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(textView.exists || textField.exists,
                      "Chat input should appear after project opens")
    }

    /// The chat input field — may be NSTextView or NSTextField depending on configuration.
    var chatInput: XCUIElement {
        let textView = app.textViews["input-text-field"]
        if textView.exists { return textView }
        let textField = app.textFields["input-text-field"]
        if textField.exists { return textField }
        return textView
    }

    /// Send a message and wait for the send to register (button click + brief pause).
    func sendMessage(_ text: String) {
        let input = chatInput
        input.click()
        input.typeText(text)
        let sendButton = app.buttons["send-button"]
        if sendButton.waitForExistence(timeout: 3) {
            sendButton.click()
        }
    }

    /// Wait for any assistant response to appear in the message list.
    /// Messages are rendered in NSTextView (markdown) so they appear as textViews, not staticTexts.
    func waitForResponse(containing text: String? = nil, timeout: TimeInterval = 15) -> Bool {
        let messageList = app.scrollViews["message-list"]
        guard messageList.waitForExistence(timeout: timeout) else { return false }
        if let text = text {
            // NSPredicate isn't Sendable — build a fresh one per query rather
            // than sending the same instance into two calls.
            let makePredicate = {
                NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)
            }
            // Check textViews (markdown renderer uses NSTextView)
            let tvResponse = messageList.textViews.containing(makePredicate()).firstMatch
            if tvResponse.waitForExistence(timeout: timeout) { return true }
            // Fallback: check staticTexts
            let stResponse = messageList.staticTexts.containing(makePredicate()).firstMatch
            return stResponse.waitForExistence(timeout: 3)
        } else {
            if messageList.textViews.firstMatch.waitForExistence(timeout: timeout) { return true }
            return messageList.staticTexts.firstMatch.waitForExistence(timeout: 3)
        }
    }
}
