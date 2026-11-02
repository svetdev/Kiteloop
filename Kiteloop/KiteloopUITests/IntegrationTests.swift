import XCTest

/// Integration tests for the multi-runtime UI flows.
///
/// Socket-level bridge tests live in KiteloopTests (unit test target)
/// since XCUITest runner is sandboxed and can't connect to unix sockets.
final class IntegrationTests: KiteloopUITestCase {



    func testDefaultAgentUsesClaudeRuntime() {
        launchAndOpenProject()
        let defaultAgent = app.staticTexts.matching(identifier: "agent-template-claude").firstMatch
        XCTAssertTrue(defaultAgent.waitForExistence(timeout: 5),
                      "Default Claude agent should appear using Claude runtime")
    }

    func testChatInputAcceptsMessage() {
        launchAndOpenProject()
        sendMessage("Hello from integration test")
        XCTAssertTrue(waitForResponse(containing: "ready to help"))
    }
}
