import XCTest
@testable import Kiteloop

/// Copy Token copies the token file's contents, trimmed, and treats a file it
/// could not read — or one with nothing in it — as a failure, never an empty copy.
final class ControlTokenCopyTests: XCTestCase {

    func testATokenIsCopiedTrimmed() {
        XCTAssertEqual(AppPreferencesView.controlTokenCopy(read: "abc123"), .copy("abc123"))
        XCTAssertEqual(AppPreferencesView.controlTokenCopy(read: "  abc123\n"), .copy("abc123"))
    }

    func testANilReadIsUnreadable() {
        XCTAssertEqual(AppPreferencesView.controlTokenCopy(read: nil), .unreadable)
    }

    func testAnEmptyOrBlankReadIsUnreadable() {
        XCTAssertEqual(AppPreferencesView.controlTokenCopy(read: ""), .unreadable)
        XCTAssertEqual(AppPreferencesView.controlTokenCopy(read: " \n\t"), .unreadable)
    }
}
