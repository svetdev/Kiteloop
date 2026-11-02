import XCTest
@testable import KiteloopCore

final class StringCountedNounTests: XCTestCase {

    /// Exactly one takes the singular noun.
    func testOneIsSingular() {
        XCTAssertEqual(String(count: 1, noun: "turn"), "1 turn")
    }

    /// Zero is plural in English: "0 turns", not "0 turn".
    func testZeroIsPlural() {
        XCTAssertEqual(String(count: 0, noun: "turn"), "0 turns")
    }

    /// Two and more append "s" by default.
    func testTwoAndMoreArePlural() {
        XCTAssertEqual(String(count: 2, noun: "project"), "2 projects")
        XCTAssertEqual(String(count: 12, noun: "epic"), "12 epics")
    }

    /// An irregular plural replaces the default "s", and only when plural.
    func testIrregularPluralIsUsedWhenGiven() {
        XCTAssertEqual(String(count: 3, noun: "branch", plural: "branches"), "3 branches")
        XCTAssertEqual(String(count: 0, noun: "branch", plural: "branches"), "0 branches")
        XCTAssertEqual(String(count: 1, noun: "branch", plural: "branches"), "1 branch")
    }
}
