import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/openapi.json` — the API describing itself. `ControlAPISpecTests`
/// covers what the document says; this covers that the server serves it, behind
/// the token like everything else under `/v1`, with the port it is actually
/// listening on rather than the default.
@MainActor
final class KiteloopControlServerOpenAPITests: XCTestCase {

    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var port: UInt16 { harness.port }
    private let token = "control-openapi-token-" + UUID().uuidString

    override func setUp() async throws {
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Serving

    func testServesAnOpenAPI31Document() async throws {
        let (status, body) = try await harness.get("/v1/openapi.json")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["openapi"] as? String, "3.1.0")
        XCTAssertNotNil(body["paths"] as? [String: Any])
        XCTAssertFalse(((body["info"] as? [String: Any])?["version"] as? String ?? "").isEmpty)
    }

    /// The document is generated from the routing table, so what it lists is what
    /// this build answers — including the endpoint that served it.
    func testDocumentCoversEveryRoutedEndpoint() async throws {
        let (_, body) = try await harness.get("/v1/openapi.json")
        let paths = try XCTUnwrap(body["paths"] as? [String: [String: Any]])

        for endpoint in ControlRouter.endpoints {
            XCTAssertNotNil(paths[endpoint.templatedPath]?[endpoint.method.lowercased()],
                            "\(endpoint.method) \(endpoint.templatedPath) is served but undocumented")
        }
        XCTAssertNotNil(paths["/v1/openapi.json"]?["get"])
    }

    /// `servers[0].url` has to be reachable by whoever just fetched the document,
    /// which means the port this server bound — not the default one.
    func testServerURLUsesTheBoundPort() async throws {
        let (_, body) = try await harness.get("/v1/openapi.json")
        let servers = try XCTUnwrap(body["servers"] as? [[String: Any]])

        XCTAssertEqual(servers.first?["url"] as? String, "http://127.0.0.1:\(port)")
    }

    // MARK: - Auth

    /// The description of the API is behind the token like the rest of `/v1`:
    /// only `/health` is reachable without one.
    func testRequiresTheBearerToken() async throws {
        let (status, body) = try await harness.get("/v1/openapi.json", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }
}
