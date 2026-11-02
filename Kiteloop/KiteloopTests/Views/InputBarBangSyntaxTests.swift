import XCTest
@testable import Kiteloop

/// Coverage for the `!!` / `!$` shortcuts applied to a chat message on send —
/// only a standalone token expands, so a regex, a path or a line of code
/// reaches the agent exactly as typed.
final class InputBarBangSyntaxTests: XCTestCase {

    private let last = "run the build"

    private func expand(_ text: String, lastMessage: String? = "run the build") -> String {
        InputBar.expandingBangSyntax(in: text, lastMessage: lastMessage)
    }

    // MARK: - `!$` inside other text is sent as typed

    func testBangDollarInsideAWordIsUnchanged() {
        XCTAssertEqual(expand("^done!$"), "^done!$")
        XCTAssertEqual(expand("works!$5"), "works!$5")
        XCTAssertEqual(expand("works!$5 cheaper"), "works!$5 cheaper")
    }

    func testBangDollarInsideBackticksIsUnchanged() {
        XCTAssertEqual(expand("`!$`"), "`!$`")
        XCTAssertEqual(expand("try `echo !$ now`"), "try `echo !$ now`")
    }

    // MARK: - A standalone `!$` expands

    func testStandaloneBangDollarBecomesLastWord() {
        XCTAssertEqual(expand("echo !$"), "echo build")
        XCTAssertEqual(expand("!$"), "build")
        XCTAssertEqual(expand("!$ and !$"), "build and build")
    }

    func testBangDollarAfterAClosedBacktickSpanExpands() {
        XCTAssertEqual(expand("`code` !$"), "`code` build")
    }

    // MARK: - `!!`

    func testWholeMessageBangBangBecomesLastMessage() {
        XCTAssertEqual(expand("!!"), last)
    }

    func testBangBangWithOtherTextIsUnchanged() {
        XCTAssertEqual(expand("!! again"), "!! again")
    }

    // MARK: - No last message

    func testNoLastMessageLeavesEveryInputUnchanged() {
        for input in ["!!", "!$", "echo !$", "^done!$", "!! again", ""] {
            XCTAssertEqual(expand(input, lastMessage: nil), input)
        }
    }
}
