import XCTest
@testable import Kiteloop

/// The three `/v1/coordinator/proposals*` routes, over a real loopback socket —
/// all retired with advisory mode. Each answers **410 Gone** with a note naming
/// the retirement and where to read grooming instead, rather than vanishing
/// into a 404 a driver would read as its own typo. Auth still comes first: an
/// unauthenticated caller learns nothing, not even that a route is gone.
@MainActor
final class KiteloopControlServerProposalsTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private let token = "control-proposals-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-proposals")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - 410 on every retired route

    func testListingProposalsAnswers410WithTheRetirementNote() async throws {
        let (status, body) = try await harness.get("/v1/coordinator/proposals")

        XCTAssertEqual(status, 410)
        XCTAssertEqual(body["error"] as? String, KiteloopControlServer.proposalsRetiredNote)
    }

    func testApprovingAProposalAnswers410WithTheRetirementNote() async throws {
        let (status, body) = try await harness.post("/v1/coordinator/proposals/approve",
                                                    ["project": "alpha", "item": "summary-line"])

        XCTAssertEqual(status, 410)
        XCTAssertEqual(body["error"] as? String, KiteloopControlServer.proposalsRetiredNote)
    }

    func testDismissingAProposalAnswers410WithTheRetirementNote() async throws {
        let (status, body) = try await harness.post("/v1/coordinator/proposals/dismiss",
                                                    ["project": "alpha", "item": "summary-line"])

        XCTAssertEqual(status, 410)
        XCTAssertEqual(body["error"] as? String, KiteloopControlServer.proposalsRetiredNote)
    }

    /// The note has to send the reader somewhere that still answers — the
    /// refill GET is where grooming's output reads back now.
    func testTheRetirementNoteNamesWhereGroomingReadsBackFrom() {
        XCTAssertTrue(KiteloopControlServer.proposalsRetiredNote
            .contains("GET /v1/coordinator/refill"))
    }

    // MARK: - Auth still gates the tombstone

    func testARetiredRouteStillRequiresBearerToken() async throws {
        let (status, body) = try await harness.get("/v1/coordinator/proposals", bearer: nil)
        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }
}
