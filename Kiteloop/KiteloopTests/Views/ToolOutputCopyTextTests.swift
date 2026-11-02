import KiteloopCore
import XCTest
@testable import Kiteloop

/// What an unfolded tool output's copy button copies, which the bubble and
/// the terminal look ask the same helper: the call's whole output, lines
/// below the scroll box's fold included, and nothing for an empty output.
final class ToolOutputCopyTextTests: XCTestCase {

    private func result(_ output: String) -> Message.ToolResult {
        Message.ToolResult(id: "result-1", toolCallID: "call-1", output: output)
    }

    func testAMultiLineOutputCopiesVerbatim() {
        let output = (1...80).map { "line \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(MessageBubble.copyableOutput(of: result(output)), output)
    }

    func testAnEmptyOutputOffersNoCopy() {
        XCTAssertNil(MessageBubble.copyableOutput(of: result("")))
    }

    func testAWhitespaceOnlyOutputOffersNoCopy() {
        XCTAssertNil(MessageBubble.copyableOutput(of: result("  \n\t\n")))
    }
}
