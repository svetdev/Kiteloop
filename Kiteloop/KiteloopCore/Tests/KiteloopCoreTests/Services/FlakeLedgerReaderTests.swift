import XCTest
@testable import KiteloopCore

/// `FlakeLedgerReader` parses exactly what `show_flakes` in
/// `scripts/run-unit-suite.sh` prints — see that function for the format.
final class FlakeLedgerReaderTests: XCTestCase {

    func testOneFlakyTestYieldsOneFinding() {
        let output = """
        run-unit-suite: flake ledger
          ChatViewModelTests.testForwardsToolCallEvent
            3 flips at abc123, def456 — 2026-08-01T00:00:00Z .. 2026-08-10T00:00:00Z
        """
        let findings = FlakeLedgerReader.read(output)
        XCTAssertEqual(findings.count, 1)
        let finding = findings[0]
        XCTAssertEqual(finding.instrument, .flake)
        XCTAssertEqual(finding.kind, .bug)
        XCTAssertEqual(finding.key, "ChatViewModelTests.testForwardsToolCallEvent")
        XCTAssertEqual(finding.title, "ChatViewModelTests.testForwardsToolCallEvent")
        XCTAssertEqual(finding.evidence, ["3 flips at abc123, def456 — 2026-08-01T00:00:00Z .. 2026-08-10T00:00:00Z"])
    }

    func testSeveralFlakyTestsYieldOneFindingEach() {
        let output = """
        run-unit-suite: flake ledger
          FooTests.testA
            1 flip at abc123 — 2026-08-01T00:00:00Z .. 2026-08-01T00:00:00Z
          BarTests.testB
            5 flips at abc123, def456, ghi789 — 2026-07-01T00:00:00Z .. 2026-08-10T00:00:00Z
        """
        let findings = FlakeLedgerReader.read(output)
        XCTAssertEqual(findings.map(\.key), ["FooTests.testA", "BarTests.testB"])
        XCTAssertEqual(findings[0].evidence, ["1 flip at abc123 — 2026-08-01T00:00:00Z .. 2026-08-01T00:00:00Z"])
    }

    func testEmptyLedgerYieldsNoFindings() {
        let output = """
        run-unit-suite: flake ledger
          none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.
        """
        XCTAssertEqual(FlakeLedgerReader.read(output), [])
    }

    func testNoRecordedRunsYieldsNoFindings() {
        let output = """
        run-unit-suite: no suite run has been recorded yet in docs/suite-status.md.
        Run the suite once — every finished run appends its own record.
        """
        XCTAssertEqual(FlakeLedgerReader.read(output), [])
    }

    /// `show_flakes` prints one line after its header saying how many rows of
    /// the record it skipped and why. It sits at the header's own indent, not at
    /// the two- or four-space indents this reader parses, so it says nothing
    /// about any test — the same ledger reads the same either way.
    func testTheSkippedRowsLineIsNotAFinding() {
        let body = """
          FooTests.testA
            1 flip at abc123 — 2026-09-10T09:00:00Z .. 2026-09-10T10:00:00Z
        """
        let withoutLine = """
        run-unit-suite: flake ledger
        \(body)
        """
        let withLine = """
        run-unit-suite: flake ledger
        run-unit-suite: read 2 of 5 rows in docs/suite-status.md — skipped 1 with a dirty tree, \
        1 with no verdict to read, 1 red naming no test.
        \(body)
        """
        XCTAssertEqual(FlakeLedgerReader.read(withLine), FlakeLedgerReader.read(withoutLine))
        XCTAssertEqual(FlakeLedgerReader.read(withLine).map(\.key), ["FooTests.testA"])
    }

    /// A record every row of which was skipped prints that line over the same
    /// "none —" line a fully read record with no flips gets: no findings either
    /// way, and this reader does not start inventing one from the difference.
    func testTheSkippedRowsLineOverAnEmptyLedgerYieldsNoFindings() {
        let output = """
        run-unit-suite: flake ledger
        run-unit-suite: read 0 of 3 rows in docs/suite-status.md — skipped 3 with a dirty tree.
          none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.
        """
        XCTAssertEqual(FlakeLedgerReader.read(output), [])
    }

    func testEmptyInputYieldsNoFindings() {
        XCTAssertEqual(FlakeLedgerReader.read(""), [])
    }
}
