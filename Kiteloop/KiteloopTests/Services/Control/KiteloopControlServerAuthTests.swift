import XCTest
@testable import Kiteloop

/// Bearer-token auth on the local control API, exercised over a real loopback
/// socket so the whole path (HTTP parse → header lookup → route guard) is covered.
@MainActor
final class KiteloopControlServerAuthTests: XCTestCase {

    private var harness: ControlServerHarness!
    private let token = "control-test-token-" + UUID().uuidString
    private let operatorToken = "operator-test-token-" + UUID().uuidString

    // Only the async setUp/tearDown overloads can carry actor isolation, which is
    // what lets this @MainActor class reach the @MainActor control server.
    override func setUp() async throws {
        harness = try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: ControlSessionRegistry(),
                                  token: $0,
                                  operatorToken: operatorToken)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
    }

    // MARK: - Unauthenticated health

    func testHealthNeedsNoToken() async throws {
        let (status, body) = try await harness.get("/health", bearer: nil)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["status"] as? String, "ok")
    }

    // MARK: - 401: no token

    func testMissingTokenIsRejectedOnV1() async throws {
        for path in ["/v1/projects", "/v1/backlog?project=demo"] {
            let (status, body) = try await harness.get(path, bearer: nil)
            XCTAssertEqual(status, 401, "expected 401 for unauthenticated GET \(path)")
            XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        }

        let (postStatus, _) = try await request(method: "POST", path: "/v1/runs", body: Data(#"{"project":"demo","item":"x"}"#.utf8))
        XCTAssertEqual(postStatus, 401, "expected 401 for unauthenticated POST /v1/runs")
    }

    /// Auth is checked before routing, so even a nonexistent /v1 path must 401
    /// rather than leak which routes exist.
    func testMissingTokenIsRejectedBeforeRouting() async throws {
        let (status, _) = try await harness.get("/v1/does-not-exist", bearer: nil)
        XCTAssertEqual(status, 401)
    }

    // MARK: - 401: wrong token

    func testWrongTokenIsRejected() async throws {
        let (status, body) = try await harness.get("/v1/projects", bearer: "not-the-token")
        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    func testTokenPrefixIsRejected() async throws {
        // A truncated token must not pass — guards against a prefix comparison.
        let (status, _) = try await harness.get("/v1/projects", bearer: String(token.dropLast(4)))
        XCTAssertEqual(status, 401)
    }

    func testMalformedAuthorizationHeaderIsRejected() async throws {
        // Right secret, wrong scheme (or none at all).
        for header in [token, "Token \(token)"] {
            let (status, _) = try await request(method: "GET", path: "/v1/projects", authorization: header)
            XCTAssertEqual(status, 401, "expected 401 for Authorization: \(header)")
        }
    }

    // MARK: - 200: valid token

    func testValidTokenIsAccepted() async throws {
        let (status, body) = try await harness.get("/v1/projects")
        XCTAssertEqual(status, 200)
        // No project is registered in this test, so the list is present but empty.
        XCTAssertEqual((body["projects"] as? [Any])?.count, 0)
    }

    /// With a valid token the request reaches routing — an unknown path 404s
    /// instead of 401, which is what distinguishes "authenticated" from "not".
    func testValidTokenReachesRouting() async throws {
        let (status, _) = try await harness.get("/v1/does-not-exist")
        XCTAssertEqual(status, 404)
    }

    // MARK: - Operator token: authorized for the whole API...

    func testOperatorTokenIsAcceptedOnAnOrdinaryReadRoute() async throws {
        let (status, body) = try await harness.get("/v1/projects", bearer: operatorToken)
        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["projects"] as? [Any])?.count, 0)
    }

    /// The wrong credential entirely — neither token — still 401s the same as it
    /// always did; the operator token is a second accepted value, not a bypass.
    func testWrongTokenIsRejectedEvenThoughAnOperatorTokenExists() async throws {
        let (status, _) = try await harness.get("/v1/projects", bearer: "not-either-token")
        XCTAssertEqual(status, 401)
    }

    /// A write route reaches its handler under the operator token exactly as it
    /// does under the full one — proven by both getting the same (non-auth)
    /// outcome for the same request, here a 400 for a body neither token's scope
    /// affects.
    func testOperatorTokenReachesAWriteRouteHandler() async throws {
        let body = Data(#"{}"#.utf8)
        let (operatorStatus, _) = try await request(method: "POST", path: "/v1/runs",
                                                     authorization: "Bearer \(operatorToken)", body: body)
        let (fullStatus, _) = try await request(method: "POST", path: "/v1/runs",
                                                 authorization: "Bearer \(token)", body: body)
        XCTAssertEqual(operatorStatus, fullStatus)
        XCTAssertEqual(operatorStatus, 400, "missing project/item is a 400 from the handler, not an auth rejection")
    }

    /// A config write — `PUT /v1/autopilot` — is authorized under the operator
    /// token exactly as under the full one, per the acceptance criterion: the
    /// operator token authorizes a config write, a run start, and every read.
    func testOperatorTokenReachesAConfigWriteRouteHandler() async throws {
        let body = Data(#"{}"#.utf8)
        let (operatorStatus, _) = try await request(method: "PUT", path: "/v1/autopilot",
                                                     authorization: "Bearer \(operatorToken)", body: body)
        let (fullStatus, _) = try await request(method: "PUT", path: "/v1/autopilot",
                                                 authorization: "Bearer \(token)", body: body)
        XCTAssertEqual(operatorStatus, fullStatus)
        XCTAssertEqual(operatorStatus, 400, "missing project is a 400 from the handler, not an auth rejection")
    }

    // MARK: - Operator token: 403 on the human gate

    func testOperatorTokenIsRejectedOnBacklogApprove() async throws {
        let (status, body) = try await request(
            method: "POST", path: "/v1/backlog/approve",
            authorization: "Bearer \(operatorToken)",
            body: Data(#"{"project":"demo","item":"x"}"#.utf8)
        )
        XCTAssertEqual(status, 403)
        XCTAssertEqual(body["error"] as? String, "the human gate takes the operator's own token (scope: approve)")
    }

    /// Landing a done item's branch is the merge half of an approval, so it
    /// is the same gate for the operator token.
    func testOperatorTokenIsRejectedOnBacklogLand() async throws {
        let (status, body) = try await request(
            method: "POST", path: "/v1/backlog/land",
            authorization: "Bearer \(operatorToken)",
            body: Data(#"{"project":"demo","item":"x"}"#.utf8)
        )
        XCTAssertEqual(status, 403)
        XCTAssertEqual(body["error"] as? String, "the human gate takes the operator's own token (scope: approve)")
    }

    func testOperatorTokenIsRejectedOnRunApprove() async throws {
        let (status, body) = try await request(
            method: "POST", path: "/v1/runs/exec-1/approve",
            authorization: "Bearer \(operatorToken)", body: Data(#"{}"#.utf8)
        )
        XCTAssertEqual(status, 403)
        XCTAssertEqual(body["error"] as? String, "the human gate takes the operator's own token (scope: approve)")
    }

    /// The full token is unaffected by the operator scope check — it still
    /// reaches the handler (404, no such run) rather than 403.
    func testFullTokenIsNotSubjectToTheOperatorScopeCheck() async throws {
        let (status, _) = try await request(
            method: "POST", path: "/v1/runs/exec-1/approve",
            authorization: "Bearer \(token)", body: Data(#"{}"#.utf8)
        )
        XCTAssertNotEqual(status, 403)
    }

    /// The 403 fires before the route dispatches to a handler at all — a
    /// nonexistent run id still gets scoped out rather than a 404, so the
    /// operator token can never observe whether a given run/item exists through
    /// the endpoints it is denied.
    func testOperatorScope403PrecedesRunExistenceCheck() async throws {
        let (status, _) = try await request(
            method: "POST", path: "/v1/runs/this-run-does-not-exist/approve",
            authorization: "Bearer \(operatorToken)", body: Data(#"{}"#.utf8)
        )
        XCTAssertEqual(status, 403)
    }

    // MARK: - Helpers

    /// Kept local: it sends the `Authorization` value verbatim — a bare secret, a
    /// wrong scheme — and a raw `Data` body, neither of which the harness's
    /// bearer-only helpers can express.
    private func request(
        method: String,
        path: String,
        authorization: String? = nil,
        body: Data? = nil
    ) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: harness.url(path))
        request.httpMethod = method
        request.timeoutInterval = 10
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await harness.send(request)
    }
}
