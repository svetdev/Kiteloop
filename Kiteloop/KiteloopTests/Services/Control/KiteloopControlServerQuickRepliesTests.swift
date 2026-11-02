import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/quick-replies`: the list Settings keeps, and the starters from a
/// server nothing pointed at Settings.
@MainActor
final class KiteloopControlServerQuickRepliesTests: XCTestCase {
    private var harness: ControlServerHarness!

    override func setUp() async throws {
        harness = try await ControlServerHarness.start { token in
            KiteloopControlServer(registry: ControlSessionRegistry(), token: token)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
    }

    func testTheSavedListIsServedInOrder() async throws {
        harness.server.quickReplies = { ["Ship it", "Continue"] }

        let (status, body) = try await harness.get("/v1/quick-replies")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["replies"] as? [String], ["Ship it", "Continue"])
    }

    func testAServerNothingConfiguredOffersTheStarters() async throws {
        let (_, body) = try await harness.get("/v1/quick-replies")

        XCTAssertEqual(body["replies"] as? [String], QuickReplies.starters)
    }
}
