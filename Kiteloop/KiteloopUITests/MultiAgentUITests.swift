import XCTest

final class MultiAgentUITests: KiteloopUITestCase {
    func testAgentSidebarShowsAfterProjectOpen() {
        launchAndOpenProject()
        let defaultAgent = app.staticTexts.matching(identifier: "agent-template-claude").firstMatch
        XCTAssertTrue(defaultAgent.waitForExistence(timeout: 5),
                      "Default Claude agent should appear in sidebar")
    }



}
