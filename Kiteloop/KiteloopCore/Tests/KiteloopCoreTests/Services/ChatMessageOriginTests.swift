import XCTest
@testable import KiteloopCore

/// Which chat commands run for whom: a permission-mode change for the person
/// and nobody else, everything else for anyone.
final class ChatMessageOriginTests: XCTestCase {

    private let notThePerson: [ChatMessageOrigin] = [.routine, .automation]

    func testThePersonIsRefusedNothing() {
        for text in ["/mode bypassPermissions", "/mode plan", "/mode", "/clear", "hello"] {
            XCTAssertNil(ChatMessageOrigin.person.commandRefusal(of: text), text)
        }
    }

    func testAModeChangeIsRefusedToEveryOtherOrigin() {
        for origin in notThePerson {
            for text in ["/mode bypassPermissions", "/MODE plan", "  /mode Accept Edits\n", "/mode auto\n\nOutput of this routine's check"] {
                let refusal = origin.commandRefusal(of: text)
                XCTAssertEqual(refusal?.hasPrefix("A permission-mode change needs you"), true, "\(origin) \(text)")
            }
        }
    }

    func testTheRefusalNamesWhoSentIt() {
        XCTAssertEqual(ChatMessageOrigin.routine.commandRefusal(of: "/mode auto")?.contains("came from a routine"), true)
        XCTAssertEqual(ChatMessageOrigin.automation.commandRefusal(of: "/mode auto")?
            .contains("came from a workflow or an event"), true)
    }

    /// Bare `/mode` only reports the mode, and no other command loosens a
    /// guard, so each runs for a routine or a workflow as it does for you.
    func testNothingElseIsRefused() {
        let others = ["/mode", "/mode ", "/model opus", "/effort high", "/thinking off", "/fast", "/clear", "/compact",
                      "/recap", "/fork", "/fork aside", "/cost", "/context", "/doctor", "/history", "/loop keep going",
                      "/goal tests pass", "/undo", "/branch try", "/modes plan", "say /mode plan", "Write the brief."]
        for origin in notThePerson {
            for text in others {
                XCTAssertNil(origin.commandRefusal(of: text), "\(origin) \(text)")
            }
        }
    }
}
