import XCTest
@testable import Kiteloop

/// Rotating the control API's bearer token. Exercised over a real loopback socket
/// because the property that matters is not "a new string was written" but "the
/// running server stopped accepting the old one" — the file and the live server
/// have to move together, or a rotation reads as revoked when it isn't.
///
/// Every case rotates against a temp file, never `~/.kiteloop/control-token`, so
/// running the suite does not invalidate the developer's own credential.
@MainActor
final class KiteloopControlServerTokenRotationTests: XCTestCase {

    private var harness: ControlServerHarness!
    private var server: KiteloopControlServer { harness.server }
    private var tokenURL: URL!
    private let originalToken = "control-rotation-token-" + UUID().uuidString

    override func setUp() async throws {
        let dir = try makeTemporaryDirectory(prefix: "control-token-rotation")
        tokenURL = dir.appending(path: "control-token")
        harness = try await ControlServerHarness.start(token: originalToken) {
            KiteloopControlServer(registry: ControlSessionRegistry(), token: $0, tokenURL: tokenURL)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
    }

    // MARK: - The live server follows the file

    /// The whole point: no restart between the rotation and the new token working.
    func testNewTokenIsAcceptedWithoutRestart() async throws {
        let fresh = try XCTUnwrap(server.regenerateToken())

        let (status, body) = try await harness.get("/v1/projects", bearer: fresh)
        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["projects"] as? [Any])?.count, 0)
    }

    func testOldTokenIsRejectedAfterRotation() async throws {
        let (before, _) = try await harness.get("/v1/projects", bearer: originalToken)
        XCTAssertEqual(before, 200, "the original token should work before rotation")

        XCTAssertNotNil(server.regenerateToken())

        let (after, body) = try await harness.get("/v1/projects", bearer: originalToken)
        XCTAssertEqual(after, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    /// The unauthenticated probe is unaffected — rotating must not take the app
    /// off the air for a client that is only checking liveness.
    func testHealthStillAnswersAfterRotation() async throws {
        XCTAssertNotNil(server.regenerateToken())

        let (status, body) = try await harness.get("/health", bearer: nil)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["status"] as? String, "ok")
    }

    // MARK: - The file

    func testRotationWritesTheNewTokenToTheFile() throws {
        let fresh = try XCTUnwrap(server.regenerateToken())

        let onDisk = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(onDisk, fresh)
        XCTAssertNotEqual(onDisk, originalToken)
        XCTAssertFalse(fresh.isEmpty)
    }

    func testRotatedFileIs0600() throws {
        XCTAssertNotNil(server.regenerateToken())

        let attributes = try FileManager.default
            .attributesOfItem(atPath: tokenURL.path(percentEncoded: false))
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    /// Rotating twice must not hand back the same secret, and the second rotation
    /// must invalidate the first one's token just as it did the original.
    func testSecondRotationSupersedesTheFirst() async throws {
        let first = try XCTUnwrap(server.regenerateToken())
        let second = try XCTUnwrap(server.regenerateToken())
        XCTAssertNotEqual(first, second)

        let (stale, _) = try await harness.get("/v1/projects", bearer: first)
        XCTAssertEqual(stale, 401)
        let (current, _) = try await harness.get("/v1/projects", bearer: second)
        XCTAssertEqual(current, 200)
    }

    // MARK: - First use is unchanged

    /// Rotation is deliberate; birth is not. A server built with no token file
    /// still mints one at 0600 on first use, and reads that same value back on the
    /// next launch instead of minting a second one.
    func testFirstUseStillMintsAndReusesAToken() throws {
        let firstUseURL = tokenURL.deletingLastPathComponent().appending(path: "first-use-token")
        let first = KiteloopControlServer(registry: ControlSessionRegistry(), tokenURL: firstUseURL)
        defer { first.stop() }

        let minted = try String(contentsOf: firstUseURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(minted.isEmpty)
        let attributes = try FileManager.default
            .attributesOfItem(atPath: firstUseURL.path(percentEncoded: false))
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        // A second server over the same file adopts the stored token rather than
        // replacing it — otherwise every launch would be a silent rotation.
        let second = KiteloopControlServer(registry: ControlSessionRegistry(), tokenURL: firstUseURL)
        defer { second.stop() }
        let afterSecondLaunch = try String(contentsOf: firstUseURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(afterSecondLaunch, minted)
    }
}
