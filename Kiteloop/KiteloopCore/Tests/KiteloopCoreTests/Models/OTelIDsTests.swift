import XCTest
@testable import KiteloopCore

final class OTelIDsTests: XCTestCase {
    func testTraceIDIs32HexChars() {
        let id = OTelIDs.newTraceID()
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit })
    }

    func testSpanIDIs16HexChars() {
        let id = OTelIDs.newSpanID()
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit })
    }

    func testTraceIDIsNonZero() {
        for _ in 0..<100 {
            let id = OTelIDs.newTraceID()
            XCTAssertNotEqual(id, String(repeating: "0", count: 32))
        }
    }

    func testSpanIDIsNonZero() {
        for _ in 0..<100 {
            let id = OTelIDs.newSpanID()
            XCTAssertNotEqual(id, String(repeating: "0", count: 16))
        }
    }

    func testTraceIDsAreUnique() {
        let ids = (0..<100).map { _ in OTelIDs.newTraceID() }
        XCTAssertEqual(Set(ids).count, 100)
    }

    func testSpanIDsAreUnique() {
        let ids = (0..<100).map { _ in OTelIDs.newSpanID() }
        XCTAssertEqual(Set(ids).count, 100)
    }

    /// The all-zero fallback rewrites the *invalid* ID and nothing else. An ID
    /// whose bytes came out non-zero is sent as drawn: its last byte is as
    /// random as the rest, not a fixed `01`. A fallback applied to every
    /// ordinary ID would stamp `01` onto about 94% of trace IDs (the share
    /// whose sixteen bytes are all non-zero); a random last byte hits `01` one
    /// time in 256.
    func testTraceIDLastByteIsNotForcedWhenTheIDIsNotAllZero() {
        let draws = 512
        let endingInOne = (0..<draws).filter { _ in OTelIDs.newTraceID().hasSuffix("01") }.count
        XCTAssertLessThan(
            endingInOne, draws / 8,
            "\(endingInOne) of \(draws) trace IDs end in 01 — the all-zero fallback is being applied to IDs that were not all zero"
        )
    }

    /// The same for span IDs, whose fallback byte is the eighth.
    func testSpanIDLastByteIsNotForcedWhenTheIDIsNotAllZero() {
        let draws = 512
        let endingInOne = (0..<draws).filter { _ in OTelIDs.newSpanID().hasSuffix("01") }.count
        XCTAssertLessThan(
            endingInOne, draws / 8,
            "\(endingInOne) of \(draws) span IDs end in 01 — the all-zero fallback is being applied to IDs that were not all zero"
        )
    }
}
