import XCTest
@testable import Kiteloop

/// Minting the control API's bearer token for the first time — the path a stock
/// install takes on first launch, as opposed to the rotation covered by
/// `KiteloopControlServerTokenRotationTests`.
///
/// The token authenticates every write endpoint, so the mode the file lands with
/// is the whole protection it has. It used to be written at whatever the umask
/// gave — 0644 on a stock install — and chmod'd afterwards, with both steps
/// `try?`, so a failed chmod left the credential world-readable and said nothing.
///
/// Every case works in a temp directory, never `~/.kiteloop/control-token`, so
/// running the suite does not disturb the developer's own credential.
@MainActor
final class KiteloopControlServerTokenCreationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory(prefix: "control-token-creation")
    }

    override func tearDownWithError() throws {
        if let directory {
            // Restore write access first: a case that made the directory
            // read-only cannot otherwise be cleaned up.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false)
            )
        }
    }

    func testTokenCreatedAtAFreshPathIsOwnerOnly() throws {
        let url = directory.appending(path: "control-token")

        let token = KiteloopControlServer.loadOrCreateToken(at: url)

        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(try mode(of: url), 0o600)
    }

    /// First launch has no `~/.kiteloop` at all, so the containing directory has
    /// to be created on the way — and the file still lands owner-only.
    func testTokenCreatedInADirectoryThatDoesNotExistYetIsOwnerOnly() throws {
        let url = directory.appending(path: "never-created/control-token")

        let token = KiteloopControlServer.loadOrCreateToken(at: url)

        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            token
        )
        XCTAssertEqual(try mode(of: url), 0o600)
    }

    /// An existing token is adopted, not replaced — otherwise every launch would
    /// be a silent rotation — and its mode is left as it was found.
    func testExistingTokenIsReadBackRatherThanReminted() throws {
        let url = directory.appending(path: "control-token")
        let first = KiteloopControlServer.loadOrCreateToken(at: url)

        let second = KiteloopControlServer.loadOrCreateToken(at: url)

        XCTAssertEqual(second, first)
        XCTAssertEqual(try mode(of: url), 0o600)
    }

    /// The token is read exactly: trimmed, and never decoded lossily — a byte
    /// that is not UTF-8 answers nil rather than a wrong credential.
    func testExactTokenReaderTrimsAndRefusesBytesThatAreNotUTF8() throws {
        let url = directory.appending(path: "control-token")
        try Data("  abc123\n".utf8).write(to: url)
        XCTAssertEqual(KiteloopControlServer.readExactToken(at: url), "abc123")

        try (Data("abc".utf8) + Data([0xFF])).write(to: url)
        XCTAssertNil(KiteloopControlServer.readExactToken(at: url))
    }

    /// An empty token file is not a credential, so one is minted in its place.
    func testTokenIsMintedForAnEmptyFile() throws {
        let url = directory.appending(path: "control-token")
        try Data().write(to: url)

        let token = KiteloopControlServer.loadOrCreateToken(at: url)

        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(KiteloopControlServer.readExactToken(at: url), token)
    }

    /// The write can fail — a read-only directory, a full disk — and there is
    /// nothing the server can do about it, since the caller has no other
    /// credential to start with. So the token is still returned and the server
    /// still starts; what changed is that the failure is now logged through
    /// `controlLog` instead of being swallowed by `try?`.
    func testTokenIsStillMintedWhenTheFileCannotBeWritten() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path(percentEncoded: false)
        )
        let url = directory.appending(path: "control-token")

        let token = KiteloopControlServer.loadOrCreateToken(at: url)

        XCTAssertFalse(token.isEmpty, "the server has to start with some credential")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default
            .attributesOfItem(atPath: url.path(percentEncoded: false))
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
