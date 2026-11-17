import XCTest
@testable import KiteloopCore

/// Which credential may call which route, read off the routing table itself:
/// the routes that answer for the person are found by method and path, so a
/// row that stops matching fails here.
final class ControlAccessTests: XCTestCase {

    /// The routes that answer something an agent put to the person, or move
    /// an agent's permission mode.
    private let answering: [(method: String, path: String)] = [
        ("POST", "/v1/agents/permission"),
        ("POST", "/v1/agents/plan"),
        ("POST", "/v1/agents/answer"),
        ("POST", "/v1/agents/choices"),
        ("POST", "/v1/agents/mode"),
        ("POST", "/v1/memory/proposals/approve"),
        ("POST", "/v1/memory/proposals/reject"),
    ]

    /// The gates there were before those: approving an item or a run, landing a branch.
    private let approving: [(method: String, path: String)] = [
        ("POST", "/v1/backlog/approve"),
        ("POST", "/v1/backlog/land"),
        ("POST", "/v1/runs/exec-1/approve"),
    ]

    private func refusal(_ credential: ControlCredential, _ method: String, _ path: String) throws -> String? {
        let route = try XCTUnwrap(ControlRouter.match(method: method, path: path), "\(method) \(path)")
        return ControlAccess.refusal(of: credential, calling: route, as: "\(method) \(path)")
    }

    func testTheOperatorTokenIsRefusedEveryHumanGate() throws {
        for (method, path) in answering + approving {
            XCTAssertEqual(try refusal(.operatorToken, method, path),
                           "the human gate takes the operator's own token (scope: approve)", "\(method) \(path)")
        }
    }

    func testEveryScopeIsRefusedEveryHumanGate() throws {
        for scope in ControlScope.allCases {
            for (method, path) in answering + approving {
                XCTAssertEqual(try refusal(.scoped(scope), method, path),
                               "the human gate takes the operator's own token; no scoped token resolves it",
                               "\(scope.rawValue) on \(method) \(path)")
            }
        }
    }

    func testTheControlTokenAndAPairedPhoneAnswerEveryGate() throws {
        for credential in [ControlCredential.full, .paired] {
            for (method, path) in answering + approving {
                XCTAssertNil(try refusal(credential, method, path), "\(credential) on \(method) \(path)")
            }
        }
    }

    func testTheRoutesThatAnswerForThePersonAreExactlyThese() {
        let found = ControlRouter.endpoints.filter(\.route.answersForThePerson).map { "\($0.method) \($0.path)" }
        XCTAssertEqual(Set(found), Set(answering.map { "\($0.method) \($0.path)" }))
        XCTAssertEqual(found.count, answering.count)
        for endpoint in ControlRouter.endpoints where endpoint.route.answersForThePerson {
            XCTAssertTrue(endpoint.route.isHumanGate, "\(endpoint.method) \(endpoint.path)")
        }
    }

    /// What an agent does to its own work or to another agent's turn is not
    /// an answer on the person's behalf, and stays open to the operator token.
    func testDrivingAnAgentStaysOpenToTheOperatorToken() throws {
        let open = [("POST", "/v1/agents/message"), ("POST", "/v1/agents/interrupt"), ("POST", "/v1/agents/tasks/stop"),
                    ("GET", "/v1/memory/proposals"), ("GET", "/v1/attention"), ("GET", "/v1/agents/transcript"),
                    ("POST", "/v1/runs/exec-1/cancel"), ("POST", "/v1/backlog/move")]
        for (method, path) in open {
            XCTAssertNil(try refusal(.operatorToken, method, path), "\(method) \(path)")
            XCTAssertNil(try refusal(.scoped(.operate), method, path), "\(method) \(path)")
        }
    }

    func testAScopedTokenKeepsToItsScope() throws {
        XCTAssertNil(try refusal(.scoped(.read), "GET", "/v1/projects"))
        XCTAssertEqual(try refusal(.scoped(.read), "POST", "/v1/runs"),
                       "this token's scope is read; POST /v1/runs needs operate")
        XCTAssertEqual(try refusal(.scoped(.operate), "PUT", "/v1/autopilot"),
                       "this token's scope is operate; PUT /v1/autopilot needs configure")
        XCTAssertNil(try refusal(.scoped(.configure), "PUT", "/v1/autopilot"))
    }

    func testOnlyTheControlTokenManagesTokens() throws {
        XCTAssertNil(try refusal(.full, "POST", "/v1/tokens"))
        for credential in [ControlCredential.paired, .operatorToken, .scoped(.configure)] {
            XCTAssertEqual(try refusal(credential, "POST", "/v1/tokens"),
                           "managing scoped tokens takes the control token itself", "\(credential)")
        }
    }

    // MARK: - A mode change typed as a message

    func testAMessageThatSwitchesTheModeIsReadAsTheChatReadsIt() {
        for message in ["/mode auto", "/MODE bypassPermissions", "  /mode Accept Edits\n", "/mode   plan"] {
            XCTAssertTrue(ControlAccess.switchesPermissionMode(message), message)
        }
        for message in ["/mode", "/mode ", "/models auto", "set /mode auto", "/model opus", "status?", ""] {
            XCTAssertFalse(ControlAccess.switchesPermissionMode(message), message)
        }
    }

    func testAModeChangeSentAsAMessageIsTheModeRoutesGate() {
        XCTAssertEqual(ControlAccess.messageRefusal(of: .operatorToken, sending: "/mode auto"),
                       "the human gate takes the operator's own token (scope: approve)")
        for scope in ControlScope.allCases {
            XCTAssertEqual(ControlAccess.messageRefusal(of: .scoped(scope), sending: "/mode auto"),
                           "the human gate takes the operator's own token; no scoped token resolves it")
        }
        for credential in [ControlCredential.full, .paired] {
            XCTAssertNil(ControlAccess.messageRefusal(of: credential, sending: "/mode auto"))
        }
        XCTAssertNil(ControlAccess.messageRefusal(of: .operatorToken, sending: "/mode"))
        XCTAssertNil(ControlAccess.messageRefusal(of: .operatorToken, sending: "status?"))
    }
}
