import XCTest

/// QA flow for `find-bar-says-nothing-when-nothing-matches`: the chat's find
/// bar says "No matches" beside the field when nothing matches, and shows its
/// counter instead once something does. The mock's default reply is
/// "Hello! I'm ready to help with your code.", so "ready" matches and
/// "pineapple" does not.
final class FindBarSaysNothingWhenNothingMatches: QAStoryboardTestCase {
    func testTheFindBarSaysNoMatchesWhenNothingMatches() {
        let searchField = app.textFields["search-field"]
        let counter = app.staticTexts["match-counter"]
        let noMatches = app.staticTexts["search-no-matches"]

        step("Kiteloop opens on its start screen, offering Quick Start") {
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
        step("The chat shows \"Hello\" and the reply \"Hello! I'm ready to help with your code.\"") {
            sendMessage("Hello")
            XCTAssertTrue(waitForResponse(containing: "ready"))
        }
        step("Cmd-F opens an empty find bar with nothing beside the field") {
            app.typeKey("f", modifierFlags: .command)
            XCTAssertTrue(searchField.waitForExistence(timeout: 5))
            XCTAssertFalse(counter.exists)
            XCTAssertFalse(noMatches.exists)
        }
        step("Typing \"pineapple\" shows \"No matches\" beside the field and no counter") {
            searchField.click()
            searchField.typeText("pineapple")
            XCTAssertTrue(noMatches.waitForExistence(timeout: 5))
            // A SwiftUI Text on macOS carries its string as the value; its label is empty.
            XCTAssertEqual((noMatches.value as? String) ?? noMatches.label, "No matches")
            XCTAssertFalse(counter.exists)
        }
        step("Replacing it with \"ready\" shows the counter 1/1 and no \"No matches\"") {
            searchField.typeKey("a", modifierFlags: .command)
            searchField.typeText(XCUIKeyboardKey.delete.rawValue)
            searchField.typeText("ready")
            XCTAssertTrue(counter.waitForExistence(timeout: 5))
            XCTAssertFalse(noMatches.exists)
        }
    }
}
