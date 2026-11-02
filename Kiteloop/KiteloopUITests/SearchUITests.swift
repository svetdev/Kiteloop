import XCTest

final class SearchUITests: KiteloopUITestCase {
    func testCmdFOpensSearchBar() {
        launchAndOpenProject()
        sendMessage("Hello")
        sleep(2)

        app.typeKey("f", modifierFlags: .command)
        let searchField = app.textFields["search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
    }

    func testSearchFindsMatches() {
        launchAndOpenProject()
        sendMessage("Hello")
        sleep(2)

        app.typeKey("f", modifierFlags: .command)
        let searchField = app.textFields["search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.click()
        searchField.typeText("ready")

        let counter = app.staticTexts["match-counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 3))
    }

    func testSearchCloseButton() {
        launchAndOpenProject()
        app.typeKey("f", modifierFlags: .command)
        let searchField = app.textFields["search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        app.buttons["search-close"].click()
        XCTAssertFalse(searchField.waitForExistence(timeout: 1))
    }
}
