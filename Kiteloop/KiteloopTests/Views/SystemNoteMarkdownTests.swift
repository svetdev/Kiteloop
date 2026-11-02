import XCTest
@testable import Kiteloop

/// The notes the app writes into a chat are markdown — "Saved branch
/// **branch-1**", "`/clear`" — and both chat looks used to print their
/// asterisks and backticks.
final class SystemNoteMarkdownTests: XCTestCase {

    private func note(_ text: String) -> AttributedString {
        MessageBubble.systemNoteText(text)
    }

    private func intent(of substring: String, in string: AttributedString) -> InlinePresentationIntent? {
        guard let range = string.range(of: substring) else { return nil }
        return string[range].inlinePresentationIntent
    }

    func testBoldIsFormattedWithoutAsterisks() {
        let result = note("Saved branch **branch-1** here")
        XCTAssertEqual(String(result.characters), "Saved branch branch-1 here")
        XCTAssertFalse(String(result.characters).contains("*"))
        XCTAssertEqual(intent(of: "branch-1", in: result), .stronglyEmphasized)
    }

    func testCodeSpanIsFormattedWithoutBackticks() {
        let result = note("Use `/clear` to start over")
        XCTAssertEqual(String(result.characters), "Use /clear to start over")
        XCTAssertEqual(intent(of: "/clear", in: result), .code)
    }

    func testLineBreaksAreKept() {
        let result = note("**Branches:**\n• main (3 msgs)")
        XCTAssertEqual(String(result.characters), "Branches:\n• main (3 msgs)")
    }

    func testTextWithoutMarkupComesBackUnchanged() {
        let text = "Goal cleared.\n  Nothing else to say"
        XCTAssertEqual(String(note(text).characters), text)
    }

    func testUnbalancedMarkupComesBackAsTyped() {
        let text = "a ** b and a stray ` tick"
        XCTAssertEqual(String(note(text).characters), text)
    }
}
