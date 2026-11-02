import XCTest
@testable import KiteloopCore

/// `tokens.json` holds provider API keys, so the mode it lands with is the whole
/// protection it has. It used to be written at whatever the umask gave — 0644 on
/// a stock install — and chmod'd afterwards, and because an atomic write renames
/// a fresh file into place, that window reopened on *every* save rather than only
/// the first.
///
/// Every case writes to a temp file, never `~/.kiteloop/tokens.json`, so running
/// the suite does not touch the developer's own keys.
final class TokenStorePermissionsTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try redirectSharedLoggerToTemporaryDirectory(prefix: "token-store-permissions-log")
        directory = try makeTemporaryDirectory(prefix: "token-store-permissions")
        fileURL = directory.appending(path: "tokens.json")
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

    func testFirstSaveCreatesTheFileOwnerOnly() throws {
        TokenStore.save(["anthropic": "sk-first"], to: fileURL)

        XCTAssertEqual(try mode(), 0o600)
    }

    /// The regression this file exists for: the second save replaces the file, so
    /// its mode is decided again from scratch. A write-then-chmod pair leaves that
    /// replacement world-readable for the instant in between, every time.
    func testSecondSaveAlsoLeavesTheFileOwnerOnly() throws {
        TokenStore.save(["anthropic": "sk-first"], to: fileURL)
        XCTAssertEqual(try mode(), 0o600, "precondition: the first save is owner-only")

        TokenStore.save(["anthropic": "sk-second", "jira": "j"], to: fileURL)

        XCTAssertEqual(try mode(), 0o600)
    }

    /// A file someone had already loosened is tightened rather than inherited:
    /// `AtomicFileWriter` only inherits the existing mode when none is requested.
    func testSaveOverALooseFileTightensIt() throws {
        FileManager.default.createFile(
            atPath: fileURL.path(percentEncoded: false),
            contents: Data("{}".utf8),
            attributes: [.posixPermissions: 0o644]
        )

        TokenStore.save(["anthropic": "sk-tight"], to: fileURL)

        XCTAssertEqual(try mode(), 0o600)
    }

    /// The mode is the point, but it is worth nothing if the contents stopped
    /// round-tripping.
    func testSavedTokensAreReadableBack() throws {
        TokenStore.save(["anthropic": "sk-round", "jira": "j-round"], to: fileURL)

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(decoded, ["anthropic": "sk-round", "jira": "j-round"])
    }

    /// A directory that cannot be written to must not take the app down — the
    /// failure is logged and the caller carries on.
    func testSaveIntoAnUnwritableDirectoryDoesNotCrash() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path(percentEncoded: false)
        )

        TokenStore.save(["anthropic": "sk-nowhere"], to: fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    private func mode() throws -> Int {
        let attributes = try FileManager.default
            .attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
