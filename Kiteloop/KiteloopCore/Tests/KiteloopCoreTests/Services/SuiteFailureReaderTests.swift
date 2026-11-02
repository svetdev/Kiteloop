import XCTest
@testable import KiteloopCore

/// `SuiteFailureReader` parses exactly what `show_last` in
/// `scripts/run-unit-suite.sh` prints — see that function for the format.
final class SuiteFailureReaderTests: XCTestCase {

    /// The whole readout of a red run, with every line `show_last` can print
    /// around the failing one, so what the reader ignores is ignored in the
    /// company it actually appears in.
    private func readout(failingLine: String) -> String {
        """
        run-unit-suite: last recorded run
          when    2026-09-10T07:57:43Z
          commit  445afbbd (dirty tree)
          tally   ✘ 4194 tests, 2 failing (2 failures)
          package 2022 tests total (1983 XCTest, 39 swift-testing)
          exit    65
          bundle  Test-Kiteloop-2026.09.09_21-57-44--1000.xcresult
        \(failingLine)
          elapsed 231s
          flaky   1 test recorded ✘ at an earlier commit and ✔ since — OtherTests.testC
          drift   56 commits on HEAD since that measurement, 42 of them touching Kiteloop/.
        """
    }

    func testTwoNamedTestsYieldOneFindingEach() {
        let findings = SuiteFailureReader.read(
            readout(failingLine: "  failing KiteloopTests.FooTests.testA, KiteloopTests.BarTests.testB"))

        XCTAssertEqual(findings.map(\.key), ["KiteloopTests.FooTests.testA", "KiteloopTests.BarTests.testB"])
        XCTAssertEqual(findings.map(\.title), findings.map(\.key))
        for finding in findings {
            XCTAssertEqual(finding.instrument, .redSuite)
            XCTAssertEqual(finding.kind, .bug)
        }
    }

    /// The row's own tree is quoted rather than judged: `when`, `commit` with
    /// whatever its tree cell said, and `tally` ride along so a worker reads
    /// the tree the measurement was taken against.
    func testTheWhenCommitAndTallyLinesAreTheEvidence() throws {
        let findings = SuiteFailureReader.read(readout(failingLine: "  failing FooTests.testA"))

        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.evidence, [
            "named in the failing cell of the newest row of docs/suite-status.md",
            "when 2026-09-10T07:57:43Z",
            "commit 445afbbd (dirty tree)",
            "tally ✘ 4194 tests, 2 failing (2 failures)"
        ])
    }

    /// A clean tree is carried the same way a dirty one is — the newest row is
    /// read whatever its tree cell says.
    func testACleanTreesRowIsReadAndItsCommitCellCarried() {
        let output = """
        run-unit-suite: last recorded run
          when    2026-09-10T07:57:43Z
          commit  445afbbd (clean tree)
          tally   ✘ 4194 tests, 1 failing (1 failure)
          failing FooTests.testA
        """
        let findings = SuiteFailureReader.read(output)

        XCTAssertEqual(findings.map(\.key), ["FooTests.testA"])
        XCTAssertTrue(findings[0].evidence.contains("commit 445afbbd (clean tree)"))
    }

    /// Nothing else in the readout names a test, and the flaky line — which is
    /// a comma-separated list of test names, at the same indent — is the one
    /// that would most easily be mistaken for one.
    func testNoOtherLineOfTheReadoutYieldsAFinding() {
        XCTAssertEqual(SuiteFailureReader.read(readout(failingLine: "  failing —")), [])
    }

    func testAGreenRowWithNoFailingLineYieldsNoFindings() {
        let output = """
        run-unit-suite: last recorded run
          when    2026-09-10T07:57:43Z
          commit  445afbbd (clean tree)
          tally   ✔ 4194 tests passed — 4194 XCTest, 0 swift-testing
          exit    0
          elapsed 231s
        """
        XCTAssertEqual(SuiteFailureReader.read(output), [])
    }

    /// A ceiling row names cases that never came back, which is a different
    /// fact about them than having been reported as failures — `show_last`
    /// prints them under `hung`, and the finding's evidence says so.
    func testAHungLineYieldsAFindingSayingTheRunWasEndedAtItsCeiling() {
        let output = """
        run-unit-suite: last recorded run
          when    2026-09-10T07:57:43Z
          commit  445afbbd (clean tree)
          tally   no tally — xcodebuild ran past its 1800s time limit and was ended
          exit    143
          hung    HookEngineTests.testTimeout
        """
        let findings = SuiteFailureReader.read(output)

        XCTAssertEqual(findings.map(\.key), ["HookEngineTests.testTimeout"])
        let evidence = findings[0].evidence
        XCTAssertEqual(evidence.first,
                       "named in the newest row of docs/suite-status.md as a case that never came back — "
                           + "the run was ended at its ceiling rather than this test reporting a failure")
        XCTAssertTrue(evidence.contains("tally no tally — xcodebuild ran past its 1800s time limit and was ended"))
    }

    func testNoRecordedRunsYieldsNoFindings() {
        let output = """
        run-unit-suite: no suite run has been recorded yet in docs/suite-status.md.
        Run the suite once — every finished run appends its own record.
        """
        XCTAssertEqual(SuiteFailureReader.read(output), [])
    }

    func testEmptyInputYieldsNoFindings() {
        XCTAssertEqual(SuiteFailureReader.read(""), [])
    }
}
