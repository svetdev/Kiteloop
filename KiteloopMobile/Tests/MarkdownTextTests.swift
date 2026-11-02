import XCTest
@testable import KiteloopMobile

/// An agent's reply read as Markdown: its blocks in order, inline styling
/// applied, and text that is not Markdown kept as written.
final class MarkdownTextTests: XCTestCase {

    func testAReplySplitsIntoItsBlocksInOrder() {
        let reply = """
        ## Plan
        Two steps:

        - read the **ledger**
        2. run `npm test`
        > careful with refunds

        ```swift
        let a = 1

        let b = 2
        ```
        Done.
        """

        XCTAssertEqual(MarkdownBlocks.parse(reply), [
            MarkdownBlock(kind: .heading(level: 2), text: "Plan"),
            MarkdownBlock(kind: .paragraph, text: "Two steps:"),
            MarkdownBlock(kind: .bullet, text: "read the **ledger**"),
            MarkdownBlock(kind: .numbered(marker: "2."), text: "run `npm test`"),
            MarkdownBlock(kind: .quote, text: "careful with refunds"),
            MarkdownBlock(kind: .code, text: "let a = 1\n\nlet b = 2"),
            MarkdownBlock(kind: .paragraph, text: "Done.")
        ])
    }

    func testLinesOfOneParagraphStayTogether() {
        XCTAssertEqual(MarkdownBlocks.parse("first line\nsecond line"),
                       [MarkdownBlock(kind: .paragraph, text: "first line\nsecond line")])
    }

    func testAFenceStillOpenWhileTheReplyStreamsIsCodeSoFar() {
        XCTAssertEqual(MarkdownBlocks.parse("Here:\n```\nmake test"), [
            MarkdownBlock(kind: .paragraph, text: "Here:"),
            MarkdownBlock(kind: .code, text: "make test")
        ])
    }

    func testAHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(MarkdownBlocks.parse("#hashtag"), [MarkdownBlock(kind: .paragraph, text: "#hashtag")])
    }

    func testInlineStylingIsAppliedAndTheMarkersDropOut() {
        let styled = MarkdownBlocks.inline("run **all** the `tests`")

        XCTAssertEqual(String(styled.characters), "run all the tests")
        let bold = styled.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(bold.map { String(styled[$0.range].characters) }, "all")
    }

    func testTextThatIsNotInlineMarkdownComesBackAsWritten() {
        XCTAssertEqual(String(MarkdownBlocks.inline("a * b < c").characters), "a * b < c")
    }
}
