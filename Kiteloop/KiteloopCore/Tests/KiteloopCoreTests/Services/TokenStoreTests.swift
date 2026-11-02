import XCTest
@testable import KiteloopCore

/// `TokenStore` holds the provider API keys, and until it took a `fileURL` it
/// could only ever be pointed at the developer's own `~/.kiteloop/tokens.json`
/// — so none of this was asserted anywhere.
///
/// The failure these cases exist for: `load()` decoded the whole file as
/// `[String: String]` and answered `[:]` on any failure, so one value the
/// decoder could not read made every token read as absent, and the next `set`
/// wrote a dictionary holding only the key just saved over the top of it. The
/// unreadable file is now moved aside first, so the old keys are still on disk.
///
/// Every case drives an injected temp directory; nothing here reads or writes
/// the real token file.
final class TokenStoreTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!
    private var store: TokenStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Moving an unreadable tokens file aside is logged, and the line names
        // this test's temp file — it belongs in this test's log, not the app's.
        try redirectSharedLoggerToTemporaryDirectory(prefix: "token-store-log")
        directory = try makeTemporaryDirectory(prefix: "token-store")
        fileURL = directory.appending(path: "tokens.json")
        store = TokenStore(fileURL: fileURL)
    }

    // MARK: - Round trip

    func testSetThenGetReturnsTheValue() throws {
        store.set("anthropic", value: "sk-round")

        XCTAssertEqual(store.get("anthropic"), "sk-round")
    }

    func testGetOfAKeyThatWasNeverSetIsNil() throws {
        store.set("anthropic", value: "sk-round")

        XCTAssertNil(store.get("jira"))
    }

    func testSetKeepsTheKeysAlreadyThere() throws {
        store.set("anthropic", value: "sk-round")
        store.set("jira", value: "j-round")

        XCTAssertEqual(store.get("anthropic"), "sk-round")
        XCTAssertEqual(store.get("jira"), "j-round")
    }

    func testRemoveDropsOneKeyAndLeavesTheOthers() throws {
        store.set("anthropic", value: "sk-round")
        store.set("jira", value: "j-round")

        store.remove("jira")

        XCTAssertNil(store.get("jira"))
        XCTAssertEqual(store.get("anthropic"), "sk-round")
    }

    // MARK: - A file the decoder refuses

    func testGetAgainstAnUnreadableFileIsNil() throws {
        try write("this is not JSON at all")

        XCTAssertNil(store.get("anthropic"))
    }

    /// Reading is not repairing: `get` leaves the file exactly where it is, so a
    /// launch that merely looked for a key does not scatter salvage files.
    func testGetAgainstAnUnreadableFileMovesNothingAside() throws {
        try write("this is not JSON at all")

        _ = store.get("anthropic")

        XCTAssertEqual(try corruptSiblings(), [])
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "this is not JSON at all")
    }

    func testFirstSetMovesTheUnreadableFileAsideWithItsBytesIntact() throws {
        let original = #"{"anthropic": {"nested": "not a string"}}"#
        try write(original)

        store.set("anthropic", value: "sk-after")

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "expected exactly one salvage file, got \(siblings)")
        let salvage = try XCTUnwrap(siblings.first)
        XCTAssertEqual(try String(contentsOf: salvage, encoding: .utf8), original)
    }

    /// A JSON document that is well-formed but is not a `[String: String]` is
    /// just as unreadable as a truncated one, and is worth as much to whoever
    /// has to recover the key out of it.
    func testAnUnreadableFileIsMovedAsideBeforeTheNewOneIsWritten() throws {
        try write(#"{"anthropic": 12}"#)

        store.set("jira", value: "j-after")

        XCTAssertEqual(store.get("jira"), "j-after")
        XCTAssertNil(store.get("anthropic"), "the unreadable file's keys are gone from the new one")
    }

    func testTheSalvageFileIsNamedAfterTheTokenFile() throws {
        try write("not JSON")

        store.set("anthropic", value: "sk-after")

        let name = try XCTUnwrap(corruptSiblings().first?.lastPathComponent)
        XCTAssertTrue(
            name.hasPrefix("tokens.json.corrupt-"),
            "expected a tokens.json.corrupt-<stamp> sibling, got \(name)"
        )
        XCTAssertGreaterThan(
            name.count, "tokens.json.corrupt-".count,
            "expected a stamp after the prefix, got \(name)"
        )
    }

    /// The point of moving it aside rather than refusing forever: the store is
    /// usable again immediately, and the next save is an ordinary one.
    func testTheSecondSetAfterAMoveMovesNothingAndKeepsTheFirstKey() throws {
        try write("not JSON")
        store.set("anthropic", value: "sk-after")
        XCTAssertEqual(try corruptSiblings().count, 1, "precondition: the first set moved it aside")

        store.set("jira", value: "j-after")

        XCTAssertEqual(try corruptSiblings().count, 1, "the second set moved nothing aside")
        XCTAssertEqual(store.get("anthropic"), "sk-after")
        XCTAssertEqual(store.get("jira"), "j-after")
    }

    func testRemoveAgainstAnUnreadableFileMovesItAsideToo() throws {
        try write("not JSON")

        store.remove("anthropic")

        XCTAssertEqual(try corruptSiblings().count, 1)
        XCTAssertEqual(store.load(), .decoded([:]))
    }

    // MARK: - An absent file is not a corrupt one

    func testFirstSetAgainstAFreshDirectoryWritesNormally() throws {
        store.set("anthropic", value: "sk-fresh")

        XCTAssertEqual(try corruptSiblings(), [])
        XCTAssertEqual(store.get("anthropic"), "sk-fresh")
    }

    func testLoadTellsAbsentFromUnreadable() throws {
        XCTAssertEqual(store.load(), .absent)

        try write("not JSON")
        XCTAssertEqual(store.load(), .unreadable)

        store.set("anthropic", value: "sk-load")
        XCTAssertEqual(store.load(), .decoded(["anthropic": "sk-load"]))
    }

    // MARK: - Permissions

    /// The file holds API keys, so the mode it lands with is the whole
    /// protection it has. Asserted on the `set` path — `TokenStorePermissionsTests`
    /// covers the `save(_:to:)` one — so the mode cannot be lost silently.
    func testSetWritesTheFileOwnerOnly() throws {
        store.set("anthropic", value: "sk-mode")

        XCTAssertEqual(try mode(of: fileURL), 0o600)
    }

    func testSetOverAnUnreadableFileAlsoLandsOwnerOnly() throws {
        try write("not JSON")

        store.set("anthropic", value: "sk-mode")

        XCTAssertEqual(try mode(of: fileURL), 0o600)
    }

    // MARK: - Reporting whether the bytes landed

    /// The Backend tab says "API key saved." on the strength of this return, so
    /// a true it did not earn is a key the user believes is on disk.
    func testSetReportsTrueOnTheNormalPath() throws {
        XCTAssertTrue(store.set("anthropic", value: "sk-landed"))

        XCTAssertEqual(store.get("anthropic"), "sk-landed")
    }

    func testSetIntoAnUnwritableDirectoryReportsFalseAndStoresNothing() throws {
        let store = try storeInAnUnwritableDirectory()

        XCTAssertFalse(store.set("anthropic", value: "sk-nowhere"))

        XCTAssertNil(store.get("anthropic"))
    }

    /// The one path that skips the write entirely: the old file could not be
    /// moved aside, so it is left alone — and the save that did not happen must
    /// not read as one that did.
    func testSetOverAnUnreadableFileThatCannotBeMovedAsideReportsFalse() throws {
        let store = try storeInAnUnwritableDirectory(seededWith: "not JSON")

        XCTAssertFalse(store.set("anthropic", value: "sk-nowhere"))
    }

    func testRemoveIntoAnUnwritableDirectoryReportsFalse() throws {
        let store = try storeInAnUnwritableDirectory(seededWith: #"{"anthropic":"sk-kept"}"#)

        XCTAssertFalse(store.remove("anthropic"))

        XCTAssertEqual(store.get("anthropic"), "sk-kept")
    }

    // MARK: - Helpers

    /// A store whose tokens file sits in a directory nothing may write to — so
    /// both the atomic write and the move-aside rename are refused by the
    /// filesystem rather than by a stub.
    private func storeInAnUnwritableDirectory(seededWith contents: String? = nil) throws -> TokenStore {
        let locked = directory.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let url = locked.appending(path: "tokens.json")
        if let contents {
            try Data(contents.utf8).write(to: url)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: locked.path(percentEncoded: false)
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: locked.path(percentEncoded: false)
            )
        }
        return TokenStore(fileURL: url)
    }

    private func write(_ contents: String) throws {
        try Data(contents.utf8).write(to: fileURL)
    }

    private func corruptSiblings() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default
            .attributesOfItem(atPath: url.path(percentEncoded: false))
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
