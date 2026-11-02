import XCTest
@testable import KiteloopMobile

/// What a tapped notification opens, read off the fields the Mac sends beside
/// the alert, and the token in the form the Mac takes.
final class PushRegistrationTests: XCTestCase {

    func testAQuestionOpensTheAgentsChat() throws {
        let route = try XCTUnwrap(PushRoute(userInfo: ["kind": "question", "project": "alpha", "agent": "b1"]))

        XCTAssertEqual(route.project, "alpha")
        XCTAssertEqual(route.agent, "b1")
        XCTAssertTrue(route.opensChat)
    }

    func testAGateOpensTheProjectWhereTheGateIs() throws {
        let route = try XCTUnwrap(PushRoute(userInfo: ["kind": "approval", "project": "alpha", "agent": "w1", "item": "i7"]))

        XCTAssertFalse(route.opensChat, "the gate is on the project screen, not in the worker's chat")
    }

    func testAPushWithoutAProjectOpensNothing() {
        XCTAssertNil(PushRoute(userInfo: ["kind": "finished"]))
    }

    func testTheTokenIsSentAsHex() {
        XCTAssertEqual(PushRegistration.hex(Data([0x0a, 0xff, 0x01])), "0aff01")
    }
}
