import XCTest
@testable import KiteloopCore

final class ItemSizeTests: XCTestCase {
    func testLargeSizesAreTooLargeForAutopilot() {
        XCTAssertTrue(ItemSize.l.isTooLargeForAutopilot)
        XCTAssertTrue(ItemSize.xl.isTooLargeForAutopilot)
    }

    func testSmallSizesAreNotTooLargeForAutopilot() {
        XCTAssertFalse(ItemSize.xs.isTooLargeForAutopilot)
        XCTAssertFalse(ItemSize.s.isTooLargeForAutopilot)
        XCTAssertFalse(ItemSize.m.isTooLargeForAutopilot)
    }

    /// The ODD cutoff is "size ≤ M": every case must be classified, and exactly
    /// L and XL are excluded. Guards against a new case silently defaulting.
    func testEveryCaseIsClassifiedAndOnlyLAndXLAreExcluded() {
        let tooLarge = ItemSize.allCases.filter { $0.isTooLargeForAutopilot }
        XCTAssertEqual(tooLarge, [.l, .xl])

        let runnable = ItemSize.allCases.filter { !$0.isTooLargeForAutopilot }
        XCTAssertEqual(runnable, [.xs, .s, .m])
        XCTAssertEqual(tooLarge.count + runnable.count, ItemSize.allCases.count)
    }

    func testRawValuesRoundTripToExpectedClassification() throws {
        let expected: [String: Bool] = [
            "XS": false,
            "S": false,
            "M": false,
            "L": true,
            "XL": true
        ]
        for (raw, isTooLarge) in expected {
            let size = try XCTUnwrap(ItemSize(rawValue: raw), "Unknown raw value \(raw)")
            XCTAssertEqual(size.isTooLargeForAutopilot, isTooLarge, "\(raw) misclassified")
        }
    }
}
