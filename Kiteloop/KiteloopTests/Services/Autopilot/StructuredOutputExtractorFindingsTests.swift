import XCTest
import KiteloopCore
@testable import Kiteloop

/// The findings-list cases of `StructuredOutputExtractorTests`, kept app-hosted
/// beside the package's own because they extract against the reviewer schema
/// the autopilot actually declares — `BacklogAutopilot.reviewerOutputSchema` —
/// rather than a copy that can drift from it. The extractor is package code; the
/// schema is the app's, so the cases that join the two live here.
final class StructuredOutputExtractorFindingsTests: XCTestCase {


    /// The reviewer's real schema, so these run against the field list the
    /// autopilot actually declares rather than a copy that can drift from it.
    private func passed(_ text: String) -> String? {
        StructuredOutputExtractor.extract(
            from: text, schema: BacklogAutopilot.reviewerOutputSchema)?["passed"]?.stringValue
    }

    private func findings(_ text: String) -> String? {
        let out = StructuredOutputExtractor.extract(
            from: text, schema: BacklogAutopilot.reviewerOutputSchema)
        return out?[ReviewFindings.outputKey]?.stringValue
    }

    func testFindingsListSurvivesAsJSON() throws {
        let raw = findings(#"{"passed": false, "findings": [{"severity":"blocking","text":"AC 3 unmet"}]}"#)
        XCTAssertEqual(ReviewFindings.parse(raw),
                       [.init(severity: .blocking, text: "AC 3 unmet")])
    }

    /// The case every reviewer wrote before findings existed, and the one that
    /// must never stop working.
    func testFindingsAbsentStillRoutesOnPassed() {
        let out = StructuredOutputExtractor.extract(
            from: #"{"passed": true, "reason": "ok"}"#, schema: BacklogAutopilot.reviewerOutputSchema)
        XCTAssertEqual(out?["passed"]?.stringValue, "true")
        XCTAssertNil(out?[ReviewFindings.outputKey])
    }

    /// A findings value that isn't a list is carried through as whatever it was
    /// — the extractor doesn't judge it, and `ReviewFindings` reads it as absent
    /// so the run routes on `passed` alone.
    func testMalformedFindingsDoNotCostTheVerdict() {
        let text = #"{"passed": true, "reason": "ok", "findings": "one blocker, two nits"}"#
        XCTAssertEqual(passed(text), "true")
        XCTAssertNil(ReviewFindings.parse(findings(text)))
    }

    func testFindingsObjectsDoNotShadowTheOuterVerdict() {
        // Each finding is itself a `{...}`; the balanced-brace scan must still
        // match the enclosing object that carries `passed`.
        let text = #"{"passed": false, "reason": "no", "findings": [{"severity":"blocking","text":"x"}]}"#
        let out = StructuredOutputExtractor.extract(
            from: text, schema: BacklogAutopilot.reviewerOutputSchema)
        XCTAssertEqual(out?["passed"]?.stringValue, "false")
    }
}
