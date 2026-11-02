import XCTest
@testable import KiteloopCore

/// `EscapedDefectReader` parses the JSONL shape `EscapedDefectTracker` writes —
/// one `ItemApprovalEvent`-shaped object per line.
final class EscapedDefectReaderTests: XCTestCase {

    private func line(project: String = "/repo", item: String, kind: String,
                      at: String, approvedAt: String? = nil, toStatus: String? = nil) -> String {
        var fields = [
            "\"projectPath\":\"\(project)\"", "\"projectName\":\"repo\"",
            "\"itemID\":\"\(item)\"", "\"kind\":\"\(kind)\"", "\"at\":\"\(at)\""
        ]
        if let approvedAt { fields.append("\"approvedAt\":\"\(approvedAt)\"") }
        if let toStatus { fields.append("\"toStatus\":\"\(toStatus)\"") }
        return "{\(fields.joined(separator: ","))}"
    }

    func testReopenYieldsOneFinding() {
        let jsonl = line(item: "old-item", kind: "reopened", at: "2026-08-04T00:00:00Z",
                         approvedAt: "2026-08-01T00:00:00Z", toStatus: "ready")
        let findings = EscapedDefectReader.read(jsonl, projectPath: "/repo")
        XCTAssertEqual(findings.count, 1)
        let finding = findings[0]
        XCTAssertEqual(finding.instrument, .escapedDefect)
        XCTAssertEqual(finding.kind, .bug)
        XCTAssertEqual(finding.key, "old-item")
        XCTAssertEqual(finding.title, "old-item")
        XCTAssertEqual(finding.evidence, ["reopened to ready on 2026-08-04T00:00:00Z — approved 2026-08-01T00:00:00Z"])
    }

    func testApprovedAloneYieldsNoFinding() {
        let jsonl = line(item: "old-item", kind: "approved", at: "2026-08-01T00:00:00Z")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo"), [])
    }

    func testOtherProjectIsExcluded() {
        let jsonl = line(project: "/other", item: "old-item", kind: "reopened",
                         at: "2026-08-10T00:00:00Z", approvedAt: "2026-08-01T00:00:00Z")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo"), [])
    }

    func testTrailingSlashOnProjectPathStillMatches() {
        let jsonl = line(item: "old-item", kind: "reopened", at: "2026-08-04T00:00:00Z",
                         approvedAt: "2026-08-01T00:00:00Z")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo/").count, 1)
    }

    func testSeveralReopensOfTheSameItemFoldIntoOneFinding() {
        let jsonl = [
            line(item: "old-item", kind: "reopened", at: "2026-08-05T00:00:00Z", approvedAt: "2026-08-01T00:00:00Z"),
            line(item: "old-item", kind: "reopened", at: "2026-08-12T00:00:00Z", approvedAt: "2026-08-10T00:00:00Z")
        ].joined(separator: "\n")
        let findings = EscapedDefectReader.read(jsonl, projectPath: "/repo")
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].evidence.count, 2)
        XCTAssertTrue(findings[0].evidence[0].contains("2026-08-05"))
        XCTAssertTrue(findings[0].evidence[1].contains("2026-08-12"))
    }

    func testUndecodableLineIsSkipped() {
        let jsonl = "not json\n" + line(item: "old-item", kind: "reopened", at: "2026-08-05T00:00:00Z",
                                       approvedAt: "2026-08-01T00:00:00Z")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo").count, 1)
    }

    func testEmptyInputYieldsNoFindings() {
        XCTAssertEqual(EscapedDefectReader.read("", projectPath: "/repo"), [])
    }

    // MARK: - The ledger's own bytes (a kill mid-write cuts the last line)

    /// The truncation `AtomicFileWriter.append` is written to survive, read
    /// back: a kill part-way through a multi-byte character leaves a last line
    /// whose bytes are not valid UTF-8. Decoding the file as one string threw
    /// on that byte and lost every complete reopen before it, so a pass over a
    /// ledger the app had been killed while writing filed no escaped defect at
    /// all.
    func testATruncatedLastLineCostsOnlyItselfAndEarlierReopensStillFile() {
        let complete = line(item: "old-item", kind: "reopened", at: "2026-08-04T00:00:00Z",
                            approvedAt: "2026-08-01T00:00:00Z", toStatus: "ready")
        let cut = Data(#"{"projectPath":"/repo","itemID":"half-written","kind":"reopened — "#.utf8).dropLast(2)
        XCTAssertNil(String(data: cut, encoding: .utf8), "the em dash is genuinely cut in half")
        var jsonl = Data(complete.utf8)
        jsonl.append(UInt8(ascii: "\n"))
        jsonl.append(contentsOf: cut)

        let findings = EscapedDefectReader.read(jsonl, projectPath: "/repo")

        XCTAssertEqual(findings.map(\.key), ["old-item"])
        XCTAssertEqual(findings.first?.evidence,
                       ["reopened to ready on 2026-08-04T00:00:00Z — approved 2026-08-01T00:00:00Z"])
    }

    /// A blank line — what `AtomicFileWriter.append`'s repair leaves when it
    /// prepends a newline nobody needed — contributes no line and is not an
    /// error.
    func testABlankLineContributesNoFinding() {
        let jsonl = Data(("\n\n" + line(item: "old-item", kind: "reopened", at: "2026-08-04T00:00:00Z",
                                        approvedAt: "2026-08-01T00:00:00Z") + "\n").utf8)
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo").count, 1)
    }

    /// The bytes and the string entry points are the one read: whatever the
    /// caller holds, a wholly valid ledger yields the same findings.
    func testTheBytesReadAgreesWithTheStringReadOnAValidLedger() {
        let jsonl = [
            line(item: "old-item", kind: "reopened", at: "2026-08-05T00:00:00Z", approvedAt: "2026-08-01T00:00:00Z"),
            line(project: "/other", item: "elsewhere", kind: "reopened",
                 at: "2026-08-05T00:00:00Z", approvedAt: "2026-08-01T00:00:00Z")
        ].joined(separator: "\n")

        XCTAssertEqual(EscapedDefectReader.read(Data(jsonl.utf8), projectPath: "/repo"),
                       EscapedDefectReader.read(jsonl, projectPath: "/repo"))
    }

    // MARK: - The gate-retry loop's own churn (an auto-merge retry is not an escaped defect)

    /// The shape the retry loop takes: a reopen it re-approves seconds later.
    /// Nothing here escaped review — the approval before the bounce still
    /// stands — so the refill must file nothing for it.
    func testReopenImmediatelyReapprovedYieldsNoFinding() {
        let jsonl = [
            line(item: "flappy-item", kind: "approved", at: "2026-09-05T05:20:36Z"),
            line(item: "flappy-item", kind: "reopened", at: "2026-09-05T05:21:03Z",
                approvedAt: "2026-09-05T05:20:36Z", toStatus: "active"),
            line(item: "flappy-item", kind: "approved", at: "2026-09-05T05:21:05Z"),
        ].joined(separator: "\n")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo"), [],
                       "a reopen the loop re-approved seconds later is its own retry, not an escape")
    }

    /// The real 2026-09-05 cascade: `signal-drafts-push-a-pass-past-its-own-cap`
    /// bounced `done` → `active` → `done` four times in thirteen minutes, each
    /// bounce re-approved within minutes. None of it escaped review.
    func testTheRealAutoMergeRetryCascadeYieldsNoFinding() {
        let itemID = "signal-drafts-push-a-pass-past-its-own-cap"
        let jsonl = [
            line(item: itemID, kind: "approved", at: "2026-09-05T05:20:36Z"),
            line(item: itemID, kind: "reopened", at: "2026-09-05T05:21:03Z",
                approvedAt: "2026-09-05T05:20:36Z", toStatus: "active"),
            line(item: itemID, kind: "approved", at: "2026-09-05T05:21:05Z"),
            line(item: itemID, kind: "reopened", at: "2026-09-05T05:25:10Z",
                approvedAt: "2026-09-05T05:21:05Z", toStatus: "active"),
            line(item: itemID, kind: "approved", at: "2026-09-05T05:25:12Z"),
            line(item: itemID, kind: "reopened", at: "2026-09-05T05:28:54Z",
                approvedAt: "2026-09-05T05:25:12Z", toStatus: "active"),
            line(item: itemID, kind: "approved", at: "2026-09-05T05:28:55Z"),
            line(item: itemID, kind: "reopened", at: "2026-09-05T05:32:42Z",
                approvedAt: "2026-09-05T05:28:55Z", toStatus: "active"),
            line(item: itemID, kind: "approved", at: "2026-09-05T05:32:43Z"),
        ].joined(separator: "\n")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo"), [])
    }

    /// The window is short next to the escaped-defect measure: a reopen the
    /// loop takes an hour to clear is not a retry finishing, and still files.
    func testReopenReapprovedPastTheRetryWindowStillYieldsAFinding() {
        let jsonl = [
            line(item: "old-item", kind: "approved", at: "2026-08-01T00:00:00Z"),
            line(item: "old-item", kind: "reopened", at: "2026-08-01T01:00:00Z",
                approvedAt: "2026-08-01T00:00:00Z", toStatus: "ready"),
            line(item: "old-item", kind: "approved", at: "2026-08-01T02:00:00Z"),
        ].joined(separator: "\n")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo").count, 1)
    }

    // MARK: - The escaped-defect window (a late return is not an escape)

    /// A reopen more than seven days after its own approval is what
    /// `TaskMetricStore.escapedDefectRate` reports as `lateReopened`, not
    /// `reopened` — the refill must not file it as an escape either.
    func testReopenMoreThanSevenDaysAfterApprovalYieldsNoFinding() {
        let jsonl = line(item: "old-item", kind: "reopened", at: "2026-08-10T00:00:00Z",
                         approvedAt: "2026-08-01T00:00:00Z")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo"), [])
    }

    /// The boundary is inclusive on the same side the metric is: exactly
    /// seven days after approval still counts.
    func testReopenExactlySevenDaysAfterApprovalStillYieldsAFinding() {
        let jsonl = line(item: "old-item", kind: "reopened", at: "2026-08-08T00:00:00Z",
                         approvedAt: "2026-08-01T00:00:00Z")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo").count, 1)
    }

    /// One second past the boundary falls outside the window.
    func testReopenOneSecondPastSevenDaysYieldsNoFinding() {
        let jsonl = line(item: "old-item", kind: "reopened", at: "2026-08-08T00:00:01Z",
                         approvedAt: "2026-08-01T00:00:00Z")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo"), [])
    }

    /// A ledger line with no `approvedAt` at all has nothing to measure the
    /// window against, so it yields no finding rather than an unbounded one.
    func testReopenWithNoApprovedAtYieldsNoFinding() {
        let jsonl = line(item: "old-item", kind: "reopened", at: "2026-08-10T00:00:00Z")
        XCTAssertEqual(EscapedDefectReader.read(jsonl, projectPath: "/repo"), [])
    }
}
