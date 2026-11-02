import XCTest
@testable import Kiteloop

/// Coverage for the "there is more" ellipsis under an expanded Edit or Write row.
/// `DiffView` cuts each side at `EditDiff.maxPreviewLines` on its own, so the only
/// honest question is whether *either* side was cut — a sum of the two says there is
/// more over a diff the row drew in full.
final class EditDiffTruncationTests: XCTestCase {

    private func lines(_ count: Int, prefix: String) -> String {
        (0..<count).map { "\(prefix) line \($0)" }.joined(separator: "\n")
    }

    private func editDiff(removed: Int, added: Int) throws -> EditDiff {
        try XCTUnwrap(EditDiff(tool: "Edit", input: [
            "old_string": lines(removed, prefix: "old"),
            "new_string": lines(added, prefix: "new")
        ]))
    }

    /// 30 and 30 is 60 lines, over a 40-line cap when summed — and yet every line is
    /// drawn, because neither side reaches the cap.
    func testThirtyRemovedAndThirtyAddedIsNotTruncated() throws {
        let diff = try editDiff(removed: 30, added: 30)

        XCTAssertEqual(diff.removedLines, 30)
        XCTAssertEqual(diff.addedLines, 30)
        XCTAssertFalse(diff.isTruncated)
    }

    /// One side over the cap is a real cut, even with nothing on the other side.
    func testSixtyAddedLinesIsTruncated() throws {
        let diff = try editDiff(removed: 0, added: 60)

        XCTAssertEqual(diff.removedLines, 0)
        XCTAssertTrue(diff.isTruncated)
    }

    /// The boundary: the cap itself is fully drawn, one line past it is not.
    func testTruncationBoundaryIsTheCapItself() throws {
        XCTAssertFalse(try editDiff(removed: 40, added: 0).isTruncated)
        XCTAssertTrue(try editDiff(removed: 41, added: 0).isTruncated)
    }
}
