import XCTest
@testable import KiteloopCore

/// `@handle` mentions in a chat line: which handles summon a specialist, that a
/// handle named twice summons it once, what `--here` means, and what the agent
/// reads once the addressing is stripped.
final class MentionParserTests: XCTestCase {

    func testHandlesAreCollectedInOrderAndStrippedFromTheText() {
        let result = MentionParser.parse("@Bob please check @alice this")
        XCTAssertEqual(result.mentions, ["Bob", "alice"])
        XCTAssertFalse(result.isInlineMode)
        XCTAssertEqual(result.cleanText, "please check this")
    }

    func testARepeatedHandleSummonsOnceKeepingTheFirstSpelling() {
        let result = MentionParser.parse("@Bob and @bob and @BOB again")
        XCTAssertEqual(result.mentions, ["Bob"], "both resolvers match case-insensitively, so one specialist")
        XCTAssertEqual(result.cleanText, "and and again")
    }

    func testHereMarksInlineModeAndIsRemoved() {
        let result = MentionParser.parse("@alice --here what does this do")
        XCTAssertTrue(result.isInlineMode)
        XCTAssertEqual(result.cleanText, "what does this do")
    }

    func testAnAtInsideAWordIsNotAMention() {
        let result = MentionParser.parse("mail me@example.com and user@host")
        XCTAssertEqual(result.mentions, [])
        XCTAssertEqual(result.cleanText, "mail me@example.com and user@host")
    }

    func testAHandleMustStartWithALetter() {
        XCTAssertEqual(MentionParser.parse("@42 @-x @ok-1").mentions, ["ok-1"])
    }

    func testNoMentionsLeavesTheTextAsItWas() {
        let result = MentionParser.parse("plain words only")
        XCTAssertEqual(result, MentionParseResult(mentions: [], isInlineMode: false, cleanText: "plain words only"))
    }

    func testWhitespaceCollapsesOnceTheHandlesAreGone() {
        XCTAssertEqual(MentionParser.parse("  @a   spaced    out  ").cleanText, "spaced out")
    }
}
