import XCTest
import KiteloopTestSupport
@testable import KiteloopCore

/// A refused merge keeps the lines that say what failed, not only the end of
/// the log — which, after a long test run, is passing tests.
final class VerifyFailureDigestTests: XCTestCase {

    private var log: URL!

    override func setUpWithError() throws {
        log = try makeTemporaryDirectory(prefix: "verify-failure-digest").appending(path: "verify.log")
    }

    private func write(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
    }

    private func size() throws -> UInt64 {
        UInt64(try Data(contentsOf: log).count)
    }

    func testTheLinesToolsPrintForAFailureAreRecognised() {
        for line in ["test ledger::settles ... FAILED",
                     "thread 'ledger::settles' panicked at src/ledger.rs:41:9:",
                     "error[E0063]: missing field `currency` in initializer",
                     "Banner.swift:12:5: error: cannot find 'foo' in scope",
                     "test result: FAILED. 211 passed; 5 failed; 0 ignored",
                     "Test Case '-[AppTests.BannerTests testShows]' failed (0.012 seconds).",
                     "--- FAIL: TestSettle (0.00s)",
                     "ERROR tests/test_api.py - ImportError"] {
            XCTAssertTrue(VerifyFailureDigest.isFailureLine(line), line)
        }
    }

    func testAPassingLineIsNotAFailure() {
        for line in ["test ledger::opens ... ok",
                     "Test Case '-[AppTests.BannerTests testShows]' passed (0.012 seconds).",
                     "   Compiling ledger v0.1.0",
                     "retrying after the last attempt failed to connect"] {
            XCTAssertFalse(VerifyFailureDigest.isFailureLine(line), line)
        }
    }

    func testFailureLinesAreKeptInOrderFromTheOmittedPartOnly() throws {
        var lines = (1...4000).map { "test case_\($0) ... ok" }
        lines[10] = "test early_one ... FAILED"
        lines[2500] = "thread 'early_two' panicked at src/lib.rs:7:5:"
        lines[3999] = "test in_the_tail ... FAILED"
        try write(lines)
        let tailBytes = 1_000

        let kept = VerifyFailureDigest.failureLines(inFileAt: log, upTo: try size() - UInt64(tailBytes),
                                                    maxBytes: tailBytes)

        XCTAssertEqual(kept, ["test early_one ... FAILED", "thread 'early_two' panicked at src/lib.rs:7:5:"])
    }

    func testALineSplitAcrossTwoReadsIsStillOneLine() throws {
        let filler = String(repeating: "x", count: VerifyFailureDigest.chunkBytes - 10)
        try write([filler, "test straddles_the_chunk ... FAILED", "test after ... ok"])

        let kept = VerifyFailureDigest.failureLines(inFileAt: log, upTo: try size(), maxBytes: 1_000)

        XCTAssertEqual(kept, ["test straddles_the_chunk ... FAILED"])
    }

    func testTheDigestStopsAtItsByteBudget() throws {
        try write((1...500).map { "test failing_\($0) ... FAILED" })

        let kept = VerifyFailureDigest.failureLines(inFileAt: log, upTo: try size(), maxBytes: 200)

        XCTAssertLessThanOrEqual(kept.joined(separator: "\n").utf8.count, 200)
        XCTAssertEqual(kept.first, "test failing_1 ... FAILED")
        XCTAssertLessThan(kept.count, 500)
    }

    func testTheTailIsAnnotatedUnderItsOmittedLine() throws {
        var lines = (1...4000).map { "test case_\($0) ... ok" }
        lines[10] = "test early_one ... FAILED"
        try write(lines)
        let tail = "… (earlier output omitted — showing the last 1000 of 99999 bytes)\ntest case_4000 ... ok\n"

        let annotated = VerifyFailureDigest.annotating(tail: tail, ofFileAt: log, tailBytes: 1_000)

        XCTAssertTrue(annotated.hasPrefix("… (earlier output omitted"), annotated)
        XCTAssertTrue(annotated.contains("Failure lines in the omitted output (1):\ntest early_one ... FAILED\n"))
        XCTAssertTrue(annotated.hasSuffix("test case_4000 ... ok\n"), "the tail is still the end")
    }

    func testAWholeLogOrAnOmittedPartWithNoFailureIsLeftAlone() throws {
        try write(["test only ... FAILED"])
        XCTAssertEqual(VerifyFailureDigest.annotating(tail: "whole", ofFileAt: log, tailBytes: 16_384), "whole")

        try write((1...4000).map { "test case_\($0) ... ok" })
        XCTAssertEqual(VerifyFailureDigest.annotating(tail: "tail", ofFileAt: log, tailBytes: 1_000), "tail")
    }
}
