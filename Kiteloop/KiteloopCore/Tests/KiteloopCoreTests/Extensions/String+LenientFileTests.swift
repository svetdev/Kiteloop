import XCTest
@testable import KiteloopCore

final class StringLenientFileTests: XCTestCase {

    /// A byte that is not UTF-8 becomes U+FFFD and the rest of the file reads.
    func testBadByteInTheMiddleIsReplacedAndTheRestReads() throws {
        let url = try makeTemporaryDirectory(prefix: "lenient-file").appending(path: "notes.md")
        try (Data("before ".utf8) + Data([0xFF]) + Data(" after".utf8)).write(to: url)

        XCTAssertEqual(String(lenientContentsOf: url), "before \u{FFFD} after")
    }

    func testEmptyFileReadsAsEmpty() throws {
        let url = try makeTemporaryDirectory(prefix: "lenient-file").appending(path: "empty.md")
        try Data().write(to: url)

        XCTAssertEqual(String(lenientContentsOf: url), "")
    }

    func testMissingFileIsNil() throws {
        let url = try makeTemporaryDirectory(prefix: "lenient-file").appending(path: "missing.md")

        XCTAssertNil(String(lenientContentsOf: url))
    }
}
