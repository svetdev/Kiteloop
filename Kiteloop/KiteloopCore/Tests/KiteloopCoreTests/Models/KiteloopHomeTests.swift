import XCTest
@testable import KiteloopCore

/// Where Kiteloop keeps its state: the user's home, unless `KITELOOP_HOME`
/// names another absolute folder — what a QA copy of the app is launched with
/// so it never reads or writes the user's real `~/.kiteloop`.
final class KiteloopHomeTests: XCTestCase {
    private let real = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    func testWithNoOverrideTheHomeIsTheUsersOwn() {
        XCTAssertEqual(KiteloopHome.url(environment: [:], fallback: real), real)
    }

    func testAnAbsoluteOverrideIsTheHome() {
        let home = KiteloopHome.url(environment: [KiteloopHome.variable: "/tmp/qa-home"], fallback: real)
        XCTAssertEqual(home.path(percentEncoded: false), "/tmp/qa-home/")
        XCTAssertEqual(home.appending(path: ".kiteloop").path(percentEncoded: false), "/tmp/qa-home/.kiteloop")
    }

    /// A relative or blank value would put the state somewhere that depends on
    /// the working directory, so it is ignored rather than guessed at.
    func testABlankOrRelativeOverrideIsIgnored() {
        for value in ["", "  ", "qa-home", "./qa-home"] {
            XCTAssertEqual(KiteloopHome.url(environment: [KiteloopHome.variable: value], fallback: real), real, value)
        }
    }
}
