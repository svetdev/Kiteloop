import XCTest
@testable import KiteloopCore

/// Which calls wait on a person: every route of the table against every kind
/// of credential, so a route added later is covered without a line here.
final class ConfigChangeGateTests: XCTestCase {

    private var endpoints: [ControlRouter.Endpoint] { ControlRouter.endpoints }
    /// The credentials handed to something other than the person.
    private let agents: [ControlCredential] = [.operatorToken, .scoped(.configure), .scoped(.operate), .scoped(.read)]
    /// The person's own, and a request with none.
    private let persons: [ControlCredential?] = [.full, .paired, nil]

    /// The calls that change what agents are allowed to do or what Kiteloop
    /// does unattended, as method and path.
    private let held: Set<String> = [
        "POST /v1/agents", "PATCH /v1/agents", "DELETE /v1/agents",
        "PUT /v1/projects/settings",
        "PUT /v1/mcp-servers/:name", "DELETE /v1/mcp-servers/:name",
        "PUT /v1/settings",
        "PUT /v1/autopilot", "POST /v1/autopilot/reset",
        "PUT /v1/coordinator/refill", "PUT /v1/coordinator/scheduling",
        "PUT /v1/routines/:id", "DELETE /v1/routines/:id",
        "POST /v1/devices/push", "POST /v1/devices/activity", "POST /v1/pair"
    ]

    private func isHeld(_ endpoint: ControlRouter.Endpoint, for credential: ControlCredential?) -> Bool {
        ConfigChangeGate.waitsOnAPerson(route: endpoint.route, method: endpoint.method, credential: credential)
    }

    /// Every route of the table, for every credential that is not the
    /// person's: held exactly when it is one of the calls above, so a route
    /// classified as held later fails here until it is named.
    func testExactlyTheConfigurationChangesAreHeldForTheOperatorAndScopedTokens() {
        let table = Set(endpoints.map { "\($0.method) \($0.path)" })
        XCTAssertEqual(held.subtracting(table), [], "every held call is a route of the table")
        for endpoint in endpoints {
            let expected = held.contains("\(endpoint.method) \(endpoint.path)")
            for credential in agents {
                XCTAssertEqual(isHeld(endpoint, for: credential), expected,
                               "\(endpoint.method) \(endpoint.path) for \(credential)")
            }
        }
    }

    /// The hold only ever narrows what the `configure` scope lets through:
    /// nothing below that scope is held, and no route a credential is refused
    /// outright — a human gate, token and webhook management — is held either.
    func testAHeldRouteNeedsConfigureAndIsNeitherAHumanGateNorTokenManagement() {
        for endpoint in endpoints where endpoint.route.changesConfiguration {
            let name = "\(endpoint.method) \(endpoint.path)"
            XCTAssertEqual(endpoint.scope, .configure, name)
            XCTAssertNotEqual(endpoint.method, "GET", name)
            XCTAssertFalse(endpoint.route.isHumanGate, name)
            XCTAssertFalse(endpoint.route.isTokenManagement, name)
        }
    }

    /// Everyday work is not held, though each of these still needs the
    /// `configure` scope of a scoped token.
    func testEverydayWritesAreNotHeld() {
        let everyday: [(String, String)] = [
            ("PATCH", "/v1/backlog/items"), ("DELETE", "/v1/backlog/items"),
            ("POST", "/v1/backlog/templates/stamp"),
            ("POST", "/v1/memory/facts"), ("PUT", "/v1/memory/facts"), ("DELETE", "/v1/memory/facts"),
            ("PUT", "/v1/memory/shared"), ("PUT", "/v1/memory/claude"), ("DELETE", "/v1/memory/claude"),
            ("PUT", "/v1/knowledge/file"), ("DELETE", "/v1/agents/chats"),
            ("POST", "/v1/projects/reorder"), ("POST", "/v1/projects/pin"), ("POST", "/v1/projects/close")
        ]
        for (method, path) in everyday {
            guard let route = ControlRouter.match(method: method, path: path) else {
                XCTFail("\(method) \(path) is not a route")
                continue
            }
            XCTAssertEqual(route.scope, .configure, "\(method) \(path) still needs its scope")
            for credential in agents {
                XCTAssertFalse(ConfigChangeGate.waitsOnAPerson(route: route, method: method, credential: credential),
                               "\(method) \(path) for \(credential)")
            }
            XCTAssertNotNil(ControlAccess.refusal(of: .scoped(.operate), calling: route, as: "\(method) \(path)"),
                            "\(method) \(path) is refused below configure")
            XCTAssertNil(ControlAccess.refusal(of: .scoped(.configure), calling: route, as: "\(method) \(path)"))
        }
    }

    /// Token and webhook management is refused for an agent's credential
    /// ahead of the hold, so no card is ever filed for it.
    func testTokenAndHookManagementIsRefusedNotHeld() {
        let managed = endpoints.filter(\.route.isTokenManagement)
        XCTAssertFalse(managed.isEmpty)
        for endpoint in managed {
            for credential in agents {
                XCTAssertNotNil(ControlAccess.refusal(of: credential, calling: endpoint.route, as: endpoint.path))
                XCTAssertFalse(isHeld(endpoint, for: credential), "\(endpoint.method) \(endpoint.path)")
            }
        }
    }

    /// The person's own token and a paired phone are never held, whatever the route.
    func testNothingIsHeldForThePersonsOwnCredentials() {
        for endpoint in endpoints {
            for credential in persons {
                XCTAssertFalse(
                    ConfigChangeGate.waitsOnAPerson(route: endpoint.route, method: endpoint.method, credential: credential),
                    "\(endpoint.method) \(endpoint.path) must not be held for \(String(describing: credential))")
            }
        }
    }

    func testNoReadIsHeldForAnyCredential() {
        for endpoint in endpoints where endpoint.method == "GET" {
            for credential in agents + persons {
                XCTAssertFalse(
                    ConfigChangeGate.waitsOnAPerson(route: endpoint.route, method: endpoint.method, credential: credential),
                    "GET \(endpoint.path) must not be held for \(String(describing: credential))")
            }
        }
    }

    /// Driving the work is not configuring it: a route below `configure` is
    /// let through for an agent's token.
    func testRoutesBelowConfigureAreNotHeld() {
        for endpoint in endpoints where endpoint.scope != .configure {
            XCTAssertFalse(isHeld(endpoint, for: .operatorToken),
                           "\(endpoint.method) \(endpoint.path) is not a configuration change")
        }
    }

    /// The decision keys on the credential: one route, both answers.
    func testTheSameRouteIsHeldOrNotByWhoCalls() {
        let route = ControlRoute.manage(.setSettings)
        XCTAssertTrue(ConfigChangeGate.waitsOnAPerson(route: route, method: "PUT", credential: .operatorToken))
        XCTAssertTrue(ConfigChangeGate.waitsOnAPerson(route: route, method: "PUT", credential: .scoped(.configure)))
        XCTAssertFalse(ConfigChangeGate.waitsOnAPerson(route: route, method: "PUT", credential: .full))
        XCTAssertFalse(ConfigChangeGate.waitsOnAPerson(route: route, method: "PUT", credential: .paired))
    }

    /// The route that answers a held change is a human gate, so the token
    /// that asked can never answer for itself.
    func testAnsweringAHeldChangeIsAHumanGate() {
        XCTAssertTrue(ControlRoute.answerConfigChange(id: "c1").isHumanGate)
        XCTAssertFalse(ConfigChangeGate.waitsOnAPerson(route: .answerConfigChange(id: "c1"), method: "POST",
                                                      credential: .operatorToken))
    }

    /// The configure routes through which an agent's token could loosen
    /// approvals — an agent's permission mode or always-ask rules, a project's
    /// mode, a routine whose prompt is `/mode <name>`, autopilot's
    /// `approveReviewPassedRuns` and autonomy dial — are all held, so none of
    /// those changes is made without a person reading it on a card.
    func testTheRoutesThatCouldLoosenApprovalsAreHeld() {
        let loosening: [(String, String)] = [
            ("POST", "/v1/agents"), ("PATCH", "/v1/agents"), ("PUT", "/v1/projects/settings"),
            ("PUT", "/v1/routines/loosen"), ("PUT", "/v1/autopilot"), ("POST", "/v1/autopilot/reset")
        ]
        for (method, path) in loosening {
            for credential in [ControlCredential.operatorToken, .scoped(.configure)] {
                let route = ControlRouter.match(method: method, path: path)
                XCTAssertEqual(route.map { ConfigChangeGate.waitsOnAPerson(route: $0, method: method, credential: credential) },
                               true, "\(method) \(path) for \(credential)")
            }
        }
    }
}

/// What the card and the log say a change asks for — with nothing in it that
/// could be used as a credential.
final class ConfigChangeSummaryTests: XCTestCase {

    private func summary(_ query: [String: String] = [:], _ body: String = "") -> String {
        ConfigChangeSummary.text(query: query, body: Data(body.utf8))
    }

    func testAnMCPServersEnvironmentKeepsItsNamesAndLosesItsValues() {
        let text = summary([:], #"{"command":"npx","args":["-y","server"],"env":{"GITHUB_PAT":"ghp_abc123","REGION":"eu"}}"#)

        XCTAssertFalse(text.contains("ghp_abc123"))
        XCTAssertFalse(text.contains("\"eu\""), "every value under env goes, whatever its name")
        XCTAssertTrue(text.contains("GITHUB_PAT"))
        XCTAssertTrue(text.contains("npx"))
        XCTAssertTrue(text.contains(ConfigChangeSummary.redacted))
    }

    func testHeaderValuesAndURLCredentialsAreLeftOut() {
        let text = summary([:], #"{"type":"http","url":"https://user:pw@mcp.example.com/sse?api_key=k-999","headers":{"Authorization":"Bearer sk-live"}}"#)

        XCTAssertFalse(text.contains("sk-live"))
        XCTAssertFalse(text.contains("k-999"))
        XCTAssertFalse(text.contains("pw@"))
        XCTAssertFalse(text.contains("user"))
        XCTAssertTrue(text.contains("https://<redacted>@mcp.example.com/sse?api_key=<redacted>"), text)
        XCTAssertTrue(text.contains("Authorization"))
    }

    func testASecretWrittenIntoAnMCPServersCommandLineIsLeftOut() {
        let text = summary([:], #"{"command":"npx tracker --api-key k-111","args":["--token=t-222","--password","p-333","-H","Authorization: Bearer b-444","--dir","/opt/token-store"]}"#)

        for secret in ["k-111", "t-222", "p-333", "b-444"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains(#""command":"npx tracker --api-key <redacted>""#), text)
        XCTAssertTrue(text.contains(#""--token=<redacted>","--password","<redacted>","-H","Authorization: Bearer <redacted>","--dir","/opt/token-store""#), text)
    }

    func testAURLKeepsTheQueryValuesThatAreNotNamedLikeSecrets() {
        XCTAssertEqual(summary(["feed": "https://example.com/items?page=2&access_token=abc"]),
                       "feed=https://example.com/items?page=2&access_token=<redacted>")
    }

    func testSecretNamedFieldsAreRedactedAtAnyDepth() {
        let text = summary([:], #"{"hook":{"secret":"s3cr3t","name":"deploy"},"list":[{"apiKey":"k1","accessToken":"t1","password":"p1"}]}"#)

        for secret in ["s3cr3t", "k1", "t1", "p1"] {
            XCTAssertFalse(text.contains("\"\(secret)\""), secret)
        }
        XCTAssertTrue(text.contains("deploy"))
    }

    func testOrdinaryFieldsAreKeptAsSent() {
        let text = summary(["project": "/tmp/alpha", "agent": "Ada"], #"{"maxTokens":5000,"model":"opus"}"#)

        XCTAssertEqual(text, #"agent=Ada project=/tmp/alpha {"maxTokens":5000,"model":"opus"}"#)
    }

    func testASecretInTheQueryIsRedacted() {
        XCTAssertEqual(summary(["token": "abc", "project": "p"]), "project=p token=\(ConfigChangeSummary.redacted)")
    }

    func testABodyThatIsNotJSONIsDescribedNotQuoted() {
        let text = summary([:], "password=hunter2")

        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertEqual(text, "a body of 16 bytes that is not JSON")
    }

    func testNoParametersIsAnEmptySummary() {
        XCTAssertEqual(summary(), "")
    }
}
