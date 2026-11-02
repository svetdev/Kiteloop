import XCTest
@testable import KiteloopCore

/// `RepoStatusStore` holds the repo→path links somebody resolved by hand in the
/// repo-resolution popover, and until it took a `linksURL` it could only ever be
/// pointed at the developer's own `~/.kiteloop/repo-links.json` — so none of
/// this was asserted anywhere.
///
/// The failure these cases exist for: `loadLinks()` returned on any failure and
/// left `linkedRepos` empty, saying nothing, and the next `linkRepo`/`unlinkRepo`
/// wrote that empty-plus-one dictionary over the file with `.atomic`. Every link
/// was gone, every repo read `.missing` again, and nothing had said so. The
/// undecodable file is now named and moved aside first, so its bytes are still
/// on disk.
///
/// Every case drives an injected temp directory; nothing here reads or writes
/// the real links file.
@MainActor
final class RepoStatusStoreTests: XCTestCase {

    private var directory: URL!
    private var linksURL: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory(prefix: "repo-status-store")
        linksURL = directory.appending(path: "repo-links.json")
    }

    private func makeStore() -> RepoStatusStore {
        RepoStatusStore(cloneService: RepoCloneService(), linksURL: linksURL)
    }

    /// The links as they are on disk right now, at `url`.
    private func linksOnDisk(at url: URL? = nil) throws -> [String: String] {
        let data = try Data(contentsOf: url ?? linksURL)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    // MARK: - No file

    func testNoLinksFileLoadsWithNoLinksAndReportsNoProblem() throws {
        let store = makeStore()

        XCTAssertEqual(store.linksFileState, .absent)
        XCTAssertEqual(store.linkedRepos, [:])
    }

    func testLinkRepoWritesTheFileWhenThereWasNone() throws {
        let store = makeStore()

        store.linkRepo("kiteloop", to: URL(filePath: "/code/kiteloop"))

        XCTAssertEqual(try linksOnDisk(), ["kiteloop": "/code/kiteloop"])
    }

    // MARK: - A file that will not decode

    func testUndecodableFileIsReportedThroughStateACallerCanRead() throws {
        try Data("not json at all".utf8).write(to: linksURL)

        let store = makeStore()

        XCTAssertEqual(store.linksFileState, .unusable(movedAsideTo: "repo-links.json.unreadable"))
        XCTAssertEqual(store.linkedRepos, [:])
    }

    func testUndecodableBytesAreStillOnDiskAfterALinkAndAnUnlink() throws {
        let bytes = "not json at all"
        try Data(bytes.utf8).write(to: linksURL)

        let store = makeStore()
        store.linkRepo("kiteloop", to: URL(filePath: "/code/kiteloop"))
        store.unlinkRepo("kiteloop")

        let setAside = directory.appending(path: "repo-links.json.unreadable")
        XCTAssertEqual(try String(contentsOf: setAside, encoding: .utf8), bytes)
    }

    func testTheStoreCarriesOnWithANewFileOfItsOwn() throws {
        try Data("not json at all".utf8).write(to: linksURL)

        let store = makeStore()
        store.linkRepo("kiteloop", to: URL(filePath: "/code/kiteloop"))

        XCTAssertEqual(try linksOnDisk(), ["kiteloop": "/code/kiteloop"])
    }

    func testASecondUndecodableFileIsMovedAsideBesideTheFirst() throws {
        try Data("first".utf8).write(to: linksURL)
        _ = makeStore()
        try Data("second".utf8).write(to: linksURL)

        let store = makeStore()

        XCTAssertEqual(store.linksFileState, .unusable(movedAsideTo: "repo-links.json.unreadable-2"))
        XCTAssertEqual(
            try String(contentsOf: directory.appending(path: "repo-links.json.unreadable"), encoding: .utf8),
            "first"
        )
        XCTAssertEqual(
            try String(contentsOf: directory.appending(path: "repo-links.json.unreadable-2"), encoding: .utf8),
            "second"
        )
    }

    // MARK: - A file that cannot be read at all

    func testAFileThatCannotBeReadAtAllIsLeftWhereItIsAndNothingIsWrittenOverIt() throws {
        // A directory in its place is the readable stand-in for a permission
        // nobody can get past: `Data(contentsOf:)` refuses, and there is nothing
        // a move would rescue.
        try FileManager.default.createDirectory(at: linksURL, withIntermediateDirectories: true)

        let store = makeStore()
        store.linkRepo("kiteloop", to: URL(filePath: "/code/kiteloop"))

        XCTAssertEqual(store.linksFileState, .unusable(movedAsideTo: nil))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: linksURL.path(percentEncoded: false), isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appending(path: "repo-links.json.unreadable").path(percentEncoded: false)
        ))
    }

    // MARK: - A file that decodes

    func testAValidFileLoadsItsLinks() throws {
        try Data(#"{"kiteloop":"/code/kiteloop","design":"/code/design"}"#.utf8).write(to: linksURL)

        let store = makeStore()

        XCTAssertEqual(store.linksFileState, .loaded)
        XCTAssertEqual(store.linkedRepos, ["kiteloop": "/code/kiteloop", "design": "/code/design"])
    }

    func testALaterLinkWritesTheExistingEntriesAndTheNewOne() throws {
        try Data(#"{"kiteloop":"/code/kiteloop","design":"/code/design"}"#.utf8).write(to: linksURL)

        let store = makeStore()
        store.linkRepo("docs", to: URL(filePath: "/code/docs"))

        XCTAssertEqual(try linksOnDisk(), [
            "kiteloop": "/code/kiteloop",
            "design": "/code/design",
            "docs": "/code/docs",
        ])
    }

    func testAnUnlinkLeavesTheOtherLinksOnDisk() throws {
        try Data(#"{"kiteloop":"/code/kiteloop","design":"/code/design"}"#.utf8).write(to: linksURL)

        let store = makeStore()
        store.unlinkRepo("design")

        XCTAssertEqual(try linksOnDisk(), ["kiteloop": "/code/kiteloop"])
    }
}
