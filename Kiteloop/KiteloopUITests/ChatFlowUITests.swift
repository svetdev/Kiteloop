import XCTest

final class ChatFlowUITests: KiteloopUITestCase {
    func testSendMessageAndReceiveResponse() {
        launchAndOpenProject()
        sendMessage("Hello")
        XCTAssertTrue(waitForResponse(containing: "ready to help"))
    }

    func testCodeBlockRendersInMessage() {
        app.launchEnvironment["UI_TEST_SCENARIO"] = "codeBlock"
        launchAndOpenProject()
        sendMessage("show code")

        // Code block content is rendered in an NSTextView — verify it appears
        XCTAssertTrue(waitForResponse(containing: "hello"))
    }

    func testPermissionDenialDisplayed() {
        app.launchEnvironment["UI_TEST_SCENARIO"] = "permissionDenial"
        launchAndOpenProject()
        sendMessage("do something")

        let messageList = app.scrollViews["message-list"]
        let errorMessage = messageList.staticTexts.containing(
            NSPredicate(format: "value CONTAINS 'Permission'")
        ).firstMatch
        XCTAssertTrue(errorMessage.waitForExistence(timeout: 10))
    }

    func testStopButtonAppearsDuringStreaming() {
        app.launchEnvironment["UI_TEST_SCENARIO"] = "slow"
        launchAndOpenProject()
        sendMessage("slow task")

        let stopButton = app.buttons["stop-button"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
    }

    func testReverseHistorySearchTakesTheCursorAndEnterPicksTheMatch() {
        launchAndOpenProject()
        sendMessage("Hello")
        XCTAssertTrue(waitForResponse(containing: "ready to help"))

        let input = chatInput
        input.click()
        input.typeKey("r", modifierFlags: .control)
        let searchField = app.textFields["history-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        app.typeText("ell")
        XCTAssertEqual(searchField.value as? String, "ell")
        XCTAssertEqual(input.value as? String, "")

        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(searchField.waitForExistence(timeout: 1))
        XCTAssertEqual(input.value as? String, "Hello")

        app.typeText("!")
        XCTAssertEqual(input.value as? String, "Hello!")
    }
}
