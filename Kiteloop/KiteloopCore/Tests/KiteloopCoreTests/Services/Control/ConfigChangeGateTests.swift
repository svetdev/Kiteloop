import XCTest
@testable import KiteloopCore

/// Which calls wait on a person: every route of the table against every kind
/// of credential, so a route added later is covered without a line here.
final class ConfigChangeGateTests: XCTestCase {

    private var endpoints: [ControlRouter.Endpoint] { ControlRouter.endpoints }

    /// Nothing an agent's token can change about the setup gets through
    /// unheld: every configure route that is not a read.
    func testEveryMutatingConfigureRouteIsHeldForTheOperatorAndScopedTokens() {
        let mutating = endpoints.filter { $0.method != "GET" && $0.scope == .configure }
        XCTAssertFalse(mutating.isEmpty)
        for endpoint in mutating {
            for credential in [ControlCredentialKind.operatorToken, .scoped] {
                XCTAssertTrue(
                    ConfigChangeGate.waitsOnAPerson(route: endpoint.route, method: endpoint.method, credential: credential),
                    "\(endpoint.method) \(endpoint.path) must wait on a person for \(credential)")
            }
        }
    }

    /// The person's own token and a paired phone are never held, whatever the route.
    func testNothingIsHeldForThePersonsOwnCredentials() {
        for endpoint in endpoints {
            for credential in [ControlCredentialKind.full, .paired, .none] {
                XCTAssertFalse(
                    ConfigChangeGate.waitsOnAPerson(route: endpoint.route, method: endpoint.method, credential: credential),
                    "\(endpoint.method) \(endpoint.path) must not be held for \(credential)")
            }
        }
    }

    func testNoReadIsHeldForAnyCredential() {
        for endpoint in endpoints where endpoint.method == "GET" {
            for credential in ControlCredentialKind.allCases {
                XCTAssertFalse(
                    ConfigChangeGate.waitsOnAPerson(route: endpoint.route, method: endpoint.method, credential: credential),
                    "GET \(endpoint.path) must not be held for \(credential)")
            }
        }
    }

    /// Driving the work is not configuring it: a route below `configure` is
    /// let through for an agent's token.
    func testRoutesBelowConfigureAreNotHeld() {
        for endpoint in endpoints where endpoint.scope != .configure {
            XCTAssertFalse(
                ConfigChangeGate.waitsOnAPerson(route: endpoint.route, method: endpoint.method, credential: .operatorToken),
                "\(endpoint.method) \(endpoint.path) is not a configuration change")
        }
    }

    /// The decision keys on the credential: one route, both answers.
    func testTheSameRouteIsHeldOrNotByWhoCalls() {
        let route = ControlRoute.manage(.setSettings)
        XCTAssertTrue(ConfigChangeGate.waitsOnAPerson(route: route, method: "PUT", credential: .operatorToken))
        XCTAssertTrue(ConfigChangeGate.waitsOnAPerson(route: route, method: "PUT", credential: .scoped))
        XCTAssertFalse(ConfigChangeGate.waitsOnAPerson(route: route, method: "PUT", credential: .full))
        XCTAssertFalse(ConfigChangeGate.waitsOnAPerson(route: route, method: "PUT", credential: .paired))
    }

    /// The changes the gap named, by path — each one held.
    func testTheNamedChangesAreAllHeld() {
        let named: [(String, String)] = [
            ("POST", "/v1/agents"), ("PATCH", "/v1/agents"), ("DELETE", "/v1/agents"),
            ("PUT", "/v1/mcp-servers/github"), ("DELETE", "/v1/mcp-servers/github"),
            ("PUT", "/v1/settings"), ("PUT", "/v1/projects/settings"),
            ("PUT", "/v1/routines/nightly"), ("DELETE", "/v1/routines/nightly"),
            ("POST", "/v1/hooks"), ("DELETE", "/v1/hooks/deploy"),
            ("PUT", "/v1/autopilot"), ("POST", "/v1/autopilot/reset"),
            ("PUT", "/v1/coordinator/refill"), ("PUT", "/v1/coordinator/scheduling"),
            ("POST", "/v1/memory/facts"), ("PUT", "/v1/memory/facts"), ("DELETE", "/v1/memory/facts"),
            ("PUT", "/v1/memory/shared"), ("PUT", "/v1/memory/claude"), ("DELETE", "/v1/memory/claude"),
            ("PUT", "/v1/knowledge/file")
        ]
        for (method, path) in named {
            guard let route = ControlRouter.match(method: method, path: path) else {
                XCTFail("\(method) \(path) is not a route")
                continue
            }
            XCTAssertTrue(ConfigChangeGate.waitsOnAPerson(route: route, method: method, credential: .operatorToken),
                          "\(method) \(path)")
        }
    }

    /// The route that answers a held change is a human gate, so the token
    /// that asked can never answer for itself.
    func testAnsweringAHeldChangeIsAHumanGate() {
        XCTAssertTrue(ControlRoute.answerConfigChange(id: "c1").isHumanGate)
        XCTAssertFalse(ConfigChangeGate.waitsOnAPerson(route: .answerConfigChange(id: "c1"), method: "POST",
                                                      credential: .operatorToken))
    }

    func testOnlyTheFullAndPairedCredentialsAreAPersons() {
        XCTAssertEqual(ControlCredentialKind.allCases.filter(\.isAPersons), [.full, .paired])
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
        XCTAssertTrue(text.contains("https://mcp.example.com/sse"))
        XCTAssertTrue(text.contains("Authorization"))
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
