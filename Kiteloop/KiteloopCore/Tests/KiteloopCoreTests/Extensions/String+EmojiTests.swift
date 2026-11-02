import XCTest
@testable import KiteloopCore

final class StringEmojiTests: XCTestCase {

    // MARK: - containsOnlyEmoji

    /// An empty string is not "only emoji": there is nothing in it to be one.
    /// `allSatisfy` on nothing is vacuously true, so this is the case the
    /// `!isEmpty` clause exists for.
    func testEmptyStringIsNotOnlyEmoji() {
        XCTAssertFalse("".containsOnlyEmoji)
        XCTAssertTrue("🙂".containsOnlyEmoji)
    }

    /// Plain text is not emoji, however short it is.
    func testLettersAreNotOnlyEmoji() {
        XCTAssertFalse("abc".containsOnlyEmoji)
        XCTAssertFalse("a".containsOnlyEmoji)
    }

    /// Four is the most an avatar may carry; five is a sentence, not a glyph.
    func testFourEmojiIsTheInclusiveLimit() {
        XCTAssertTrue("🙂🙂🙂🙂".containsOnlyEmoji)
        XCTAssertFalse("🙂🙂🙂🙂🙂".containsOnlyEmoji)
    }

    /// Length alone does not qualify a string: a short one still has to be
    /// emoji all the way through.
    func testShortMixedTextIsNotOnlyEmoji() {
        XCTAssertFalse("🙂a".containsOnlyEmoji)
    }

    // MARK: - Character.isEmoji

    /// Unicode gives `0`–`9`, `#` and `*` the Emoji property — they can start a
    /// keycap sequence — but on their own they are text, and a title of "123"
    /// must not be taken for an emoji avatar.
    func testBareDigitsAndKeycapBasesAreNotEmoji() {
        XCTAssertFalse(Character("1").isEmoji)
        XCTAssertFalse(Character("#").isEmoji)
        XCTAssertFalse(Character("*").isEmoji)
        XCTAssertFalse("123".containsOnlyEmoji)
    }

    /// The same digit inside a keycap sequence is an emoji: the extra scalars
    /// (VS16 + combining keycap) are what make it one.
    func testKeycapSequenceIsEmoji() {
        XCTAssertTrue(Character("1\u{FE0F}\u{20E3}").isEmoji)
        XCTAssertTrue("1\u{FE0F}\u{20E3}".containsOnlyEmoji)
    }

    /// A single-scalar emoji from the pictographic range is an emoji on its
    /// own — it needs no presentation selector to qualify.
    func testSingleScalarPictographIsEmoji() {
        XCTAssertTrue(Character("🙂").isEmoji)
        XCTAssertTrue(Character("\u{23CF}").isEmoji) // ⏏, just above the cutoff
    }

    /// A character whose scalar sits above the cutoff, or which is built from
    /// several scalars, is still not an emoji unless Unicode says it is.
    func testNonEmojiCharactersAreNotEmojiWhateverTheirCodePoint() {
        XCTAssertFalse(Character("я").isEmoji)          // U+044F, above the cutoff
        XCTAssertFalse(Character("中").isEmoji)         // U+4E2D, above the cutoff
        XCTAssertFalse(Character("e\u{0301}").isEmoji)  // two scalars, no emoji
        XCTAssertFalse("яя".containsOnlyEmoji)
    }
}
