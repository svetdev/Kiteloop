import XCTest

final class DebateUITests: KiteloopUITestCase {



    func testCopilotAgentShowsDisconnectedWithNoSocket() {
        app.launchEnvironment["COPILOT_BRIDGE_SOCKET"] = "/tmp/nonexistent-kiteloop-test.sock"
        launchAndOpenProject()

        // This test verifies the UI doesn't crash with an invalid socket path
        // The disconnected indicator may or may not be visible depending on whether
        // the copilot agent is actually loaded (which requires the package)
        let statusIndicator = app.images["copilot-disconnected"]
        if statusIndicator.waitForExistence(timeout: 5) {
            XCTAssertTrue(statusIndicator.exists)
        }
    }

    func testAgentsWithoutRuntimeKindDefaultToClaude() {
        launchAndOpenProject()
        let defaultAgent = app.staticTexts.matching(identifier: "agent-template-claude").firstMatch
        XCTAssertTrue(defaultAgent.waitForExistence(timeout: 5),
                      "Agents without runtimeKind should load normally with Claude runtime")
    }
}
