import XCTest
import KiteloopCore
@testable import Kiteloop

/// `KiteloopControlServer.handle(_:)` — the in-process transport — answers as
/// the socket does. Three readings: the one endpoint that needs no token, a
/// route behind the token refused without it, and the same request over the
/// loopback socket and in process giving one answer, so a drift between the
/// two paths is a red test rather than a surprise.
@MainActor
final class KiteloopControlServerInProcessTests: XCTestCase {

    func testHealthAnswersWithoutASocket() async {
        let server = KiteloopControlServer(registry: ControlSessionRegistry(), token: "in-process-token")
        let response = await server.handle(request("GET", "/health"))
        XCTAssertEqual(response.status, 200)
        XCTAssertFalse(json(response).isEmpty, "a JSON object, as over the wire")
    }

    func testARouteBehindTheTokenIsRefusedWithoutItAndAnsweredWithIt() async {
        let server = KiteloopControlServer(registry: ControlSessionRegistry(), token: "in-process-token")
        let refused = await server.handle(request("GET", "/v1/projects"))
        XCTAssertEqual(refused.status, 401)
        XCTAssertEqual(json(refused)["error"] as? String, "Missing or invalid bearer token")
        let answered = await server.handle(request("GET", "/v1/projects", bearer: "in-process-token"))
        XCTAssertEqual(answered.status, 200)
    }

    func testInProcessAndSocketAnswersAgree() async throws {
        let harness = try await ControlServerHarness.start(token: "in-process-token") {
            KiteloopControlServer(registry: ControlSessionRegistry(), token: $0)
        }
        defer { harness.stop() }
        let (socketStatus, socketBody) = try await harness.get("/v1/projects")
        let direct = await harness.server.handle(request("GET", "/v1/projects", bearer: harness.token))
        XCTAssertEqual(direct.status, socketStatus)
        XCTAssertEqual(json(direct) as NSDictionary, socketBody as NSDictionary)
    }

    // MARK: - Helpers

    private func request(_ method: String, _ path: String, bearer: String? = nil) -> HTTPServer.Request {
        var headers: [String: String] = [:]
        if let bearer { headers["authorization"] = "Bearer \(bearer)" }
        return HTTPServer.Request(method: method, path: path, query: [:], headers: headers, body: Data())
    }

    private func json(_ response: HTTPServer.Response) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }
}
