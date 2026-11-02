import XCTest
@testable import KiteloopCore

/// A collapsed row whose result was an error still counted lines, so a failed
/// `Read` read "1 lines" and a failed `Grep` "1 matches" — the operator had to
/// expand the row to learn anything. The summary says the error now, and these
/// assert it with no view.
final class ToolResultSummaryTests: XCTestCase {

    func testAFailedReadSaysTheErrorRatherThanALineCount() {
        let summary = ToolResultSummary.text(tool: "Read", output: "Error: File does not exist.")

        XCTAssertEqual(summary, "Error: File does not exist.")
    }

    func testAFailedGrepSaysTheErrorRatherThanAMatchCount() {
        let summary = ToolResultSummary.text(tool: "Grep", output: "Error: invalid regex")

        XCTAssertEqual(summary, "Error: invalid regex")
    }

    func testAnErrorLongerThanARowIsCutToOne() {
        let output = "Error: " + String(repeating: "wide ", count: 40)

        let summary = ToolResultSummary.text(tool: "Read", output: output)

        XCTAssertTrue(summary.hasPrefix("Error: wide"))
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertLessThanOrEqual(summary.count, 61)
    }

    func testASuccessfulReadStillCountsItsNonEmptyLines() {
        let output = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n\n   \n"

        XCTAssertEqual(ToolResultSummary.text(tool: "Read", output: output), "12 lines")
    }

    func testASuccessfulGrepStillCountsItsMatches() {
        let output = "a.swift:1:x\nb.swift:2:y\nc.swift:3:z"

        XCTAssertEqual(ToolResultSummary.text(tool: "Grep", output: output), "3 matches")
    }

    func testAGrepThatFoundNothingStillSaysSo() {
        XCTAssertEqual(ToolResultSummary.text(tool: "Glob", output: "No files found"), "No files found")
    }

    func testAnUnnamedToolStillShowsItsFirstLine() {
        XCTAssertEqual(ToolResultSummary.text(tool: "Bash", output: "wrote 3 files\nok"), "wrote 3 files")
        XCTAssertEqual(ToolResultSummary.text(tool: "Bash", output: ""), "done")
    }
}
