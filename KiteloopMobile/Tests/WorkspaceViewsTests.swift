import XCTest
@testable import KiteloopMobile

/// The phone's read-only view of a project: a file tool's line opens its file,
/// git's letters read as words, a file shows with its line numbers.
final class WorkspaceViewsTests: XCTestCase {

    func testAFileToolLineCarriesThePathItOpens() throws {
        let line = #"{"id":"t1","sender":"b1","kind":"tool","text":"Edit — ledger/refund.ts","path":"/p/src/ledger/refund.ts"}"#
        let message = try JSONDecoder().decode(TranscriptMessage.self, from: Data(line.utf8))

        guard case .tools(let lines) = try XCTUnwrap(TranscriptRow.rows(from: [message]).first).kind else {
            return XCTFail("a tools row")
        }
        XCTAssertEqual(lines, [ToolLine(text: "Edit — ledger/refund.ts", path: "/p/src/ledger/refund.ts")])
    }

    func testABashLineOpensNothing() throws {
        let line = #"{"id":"t1","sender":"b1","kind":"tool","text":"Bash — npm test"}"#
        let message = try JSONDecoder().decode(TranscriptMessage.self, from: Data(line.utf8))

        guard case .tools(let lines) = try XCTUnwrap(TranscriptRow.rows(from: [message]).first).kind else {
            return XCTFail("a tools row")
        }
        XCTAssertNil(lines.first?.path)
    }

    func testGitsLettersReadAsWords() {
        XCTAssertEqual(ChangesView.label(" M"), "modified")
        XCTAssertEqual(ChangesView.label("??"), "new")
        XCTAssertEqual(ChangesView.label("D "), "deleted")
    }

    func testAFileIsNumberedWithoutATrailingEmptyLine() {
        let lines = FileView.numbered("a\nb\n")

        XCTAssertEqual(lines.map(\.number), ["1", "2"])
        XCTAssertEqual(lines.map(\.text), ["a", "b"])
    }

    func testAFolderEntryJoinsOntoItsFolder() {
        XCTAssertEqual(FileView.join("", "src"), "src")
        XCTAssertEqual(FileView.join("src", "refund.ts"), "src/refund.ts")
    }
}
