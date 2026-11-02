import XCTest
@testable import KiteloopCore

/// The worker's premise report, read off its handoff — the shape that lets a
/// refuted premise end a run as an investigation rather than as a run that
/// produced nothing (2026-09-03: four functions asserted, one qualified; the
/// run that measured and refused scored 0.55 for changing no code).
final class PremiseReportTests: XCTestCase {

    // MARK: - Reading

    func testReadsVerdictFirstLinesInEitherShape() throws {
        let report = try XCTUnwrap(PremiseReport.parse("""
        Premise check:
        - held: `RetryCeiling.evaluate` is at CRAP 9.0
        - refuted: `BacklogAIEditor.map` reads 6.2, under the 8 the item asserts
        - unverifiable — the third function no longer exists on this branch
        """))
        XCTAssertEqual(report.lines.map(\.verdict), [.held, .refuted, .unverifiable])
        XCTAssertEqual(report.lines[1].text,
                       "refuted: `BacklogAIEditor.map` reads 6.2, under the 8 the item asserts")
        XCTAssertTrue(report.isRefuted)
        XCTAssertEqual(report.refuted.count, 1)
    }

    func testReadsClaimFirstLines() throws {
        let report = try XCTUnwrap(PremiseReport.parse("""
        1. Four functions are over CRAP 8 — refuted: one is (`evaluate`, 9.0); the other three read 4.1, 3.8 and 2.0
        2. The baseline names all four: held
        3. **The item's verify runs the core suite** — unverifiable: the script is not on this branch
        """))
        XCTAssertEqual(report.lines.map(\.verdict), [.refuted, .held, .unverifiable])
        XCTAssertEqual(report.lines[1].text, "The baseline names all four: held")
        XCTAssertEqual(report.tally, "1 held, 1 refuted, 1 unverifiable")
    }

    func testEmphasisAndBackticksAroundTheVerdictAreIgnored() throws {
        let report = try XCTUnwrap(PremiseReport.parse("- **refuted**: only one qualifies\n- `held`"))
        XCTAssertEqual(report.lines.map(\.verdict), [.refuted, .held])
    }

    func testProseUsingTheWordsInPassingIsNotAReport() {
        XCTAssertNil(PremiseReport.parse("""
        The lock held under load, and the claim that it would be refuted by the
        second reader was unverifiable in the time I had. Done; CI is green.
        """))
    }

    func testNothingAndNilReadAsNoReport() {
        XCTAssertNil(PremiseReport.parse(nil))
        XCTAssertNil(PremiseReport.parse(""))
        XCTAssertNil(PremiseReport.parse("Done. ./scripts/ci-local.sh is green"))
    }

    func testAReportWithEveryClaimHeldIsNotRefuted() throws {
        let report = try XCTUnwrap(PremiseReport.parse("- held: the four functions are over 8\n- held: the baseline lists them"))
        XCTAssertFalse(report.isRefuted)
        XCTAssertEqual(report.refuted, [])
        XCTAssertEqual(report.tally, "2 held")
    }

    // MARK: - What it says

    func testTextIsAMarkdownListOfTheLinesAsWritten() throws {
        let report = try XCTUnwrap(PremiseReport.parse("* refuted: one of four\n* held: the rest"))
        XCTAssertEqual(report.text, "- refuted: one of four\n- held: the rest")
    }

    func testSummaryCountsTheRefutedClaims() throws {
        let report = try XCTUnwrap(PremiseReport.parse("- refuted: a\n- refuted: b\n- held: c"))
        XCTAssertEqual(report.summary, "worker checked the item's premise and refuted 2 of 3 claims")
        let one = try XCTUnwrap(PremiseReport.parse("- refuted: a"))
        XCTAssertEqual(one.summary, "worker checked the item's premise and refuted 1 of 1 claim")
    }

    /// The note is the whole interface at the gate: no files changed, nothing
    /// has checked the measurement, and what the worker reported.
    func testNoteSaysNoFilesChangedThatNothingVerifiedItAndQuotesTheReport() throws {
        let report = try XCTUnwrap(PremiseReport.parse("- refuted: one of four qualifies\n- held: the baseline lists them"))
        XCTAssertTrue(report.note.contains("changed no files"), report.note)
        XCTAssertTrue(report.note.contains("Nothing has verified the measurement"), report.note)
        XCTAssertTrue(report.note.contains("  - refuted: one of four qualifies"), report.note)
        XCTAssertTrue(report.note.contains("  - held: the baseline lists them"), report.note)
    }
}
