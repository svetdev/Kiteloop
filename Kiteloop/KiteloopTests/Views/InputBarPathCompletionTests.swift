import XCTest
@testable import Kiteloop

/// Tab on a path in the input bar lists the entries its last component starts
/// and completes to the one match — a directory with its trailing `/` — or to
/// the longest prefix several matches share.
final class InputBarPathCompletionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTemporaryDirectory(prefix: "input-bar-path-completion")
        for file in ["report-2026.md", "report-2027.md", "notes.txt"] {
            try Data().write(to: dir.appending(path: file))
        }
        try FileManager.default.createDirectory(at: dir.appending(path: "sources"), withIntermediateDirectories: true)
    }

    private var root: String { dir.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    private func listing(_ word: String) -> InputBar.PathListing? {
        InputBar.pathListing(for: word)
    }

    func testAPrefixListsOnlyTheEntriesItStarts() throws {
        let found = try XCTUnwrap(listing("/\(root)/rep"))
        XCTAssertEqual(found.prefix, "rep")
        XCTAssertEqual(found.matches.sorted(), ["report-2026.md", "report-2027.md"])
    }

    func testATrailingSlashListsTheWholeDirectory() throws {
        let found = try XCTUnwrap(listing("/\(root)/"))
        XCTAssertEqual(found.prefix, "")
        XCTAssertEqual(found.matches.sorted(), ["notes.txt", "report-2026.md", "report-2027.md", "sources"])
    }

    func testNothingMatchingOrAnUnreadableDirectoryListsNothing() {
        XCTAssertNil(listing("/\(root)/zzz"))
        XCTAssertNil(listing("/\(root)/no-such-dir/x"))
    }

    func testOneMatchCompletesToItsPathAndADirectoryGetsItsSlash() throws {
        XCTAssertEqual(InputBar.completion(in: try XCTUnwrap(listing("/\(root)/no"))), "/\(root)/notes.txt")
        XCTAssertEqual(InputBar.completion(in: try XCTUnwrap(listing("/\(root)/so"))), "/\(root)/sources/")
    }

    func testSeveralMatchesCompleteToTheirLongestSharedPrefix() throws {
        XCTAssertEqual(InputBar.completion(in: try XCTUnwrap(listing("/\(root)/r"))), "/\(root)/report-202")
    }

    func testSeveralMatchesSharingNothingBeyondThePrefixCompleteNothing() throws {
        XCTAssertNil(InputBar.completion(in: try XCTUnwrap(listing("/\(root)/report-202"))))
    }

    // MARK: - Relative to the project folder

    private func complete(_ word: String) -> String? { InputBar.completingFilePath(word, relativeTo: dir) }

    func testARelativeWordCompletesFromTheProjectAndStaysRelative() throws {
        try FileManager.default.createDirectory(at: dir.appending(path: "docs"), withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "docs/guide.md"))
        XCTAssertEqual(complete("docs/gu"), "docs/guide.md")
        XCTAssertEqual(complete("./docs/gu"), "./docs/guide.md")
    }

    func testARelativeDirectoryGetsItsSlashAndSeveralMatchesTheirCommonPrefix() {
        XCTAssertEqual(complete("./sou"), "./sources/")
        XCTAssertEqual(complete("./rep"), "./report-202")
    }

    func testAnAbsoluteWordIgnoresTheProjectFolder() {
        XCTAssertEqual(complete("/\(root)/not"), "/\(root)/notes.txt")
    }

    func testARelativeWordWithNoMatchUnderTheProjectFallsThrough() {
        XCTAssertNil(complete("./zzz"))
        XCTAssertNil(complete("plainword"), "not path-like")
    }
}
