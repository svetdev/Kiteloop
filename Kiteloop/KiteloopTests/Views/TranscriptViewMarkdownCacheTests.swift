import AppKit
import XCTest
@testable import Kiteloop

/// Transcript mode rebuilds the whole conversation on every streaming chunk, so
/// the markdown of a message that did not change comes back from the cache.
///
/// A render is told apart from a cache hit by identity: `MarkdownRenderer.render`
/// builds a fresh string every call, so the same instance coming back twice is
/// the one proof that it was not called again.
@MainActor
final class TranscriptViewMarkdownCacheTests: XCTestCase {

    private let first = UUID()
    private let second = UUID()

    func testASecondPassOverAnUnchangedMessageRendersItsMarkdownNoFurtherTimes() {
        let cache = TranscriptView.MarkdownCache()

        let rendered = cache.rendered("# Hello\n\nworld", forMessage: first, isDark: true)
        let again = cache.rendered("# Hello\n\nworld", forMessage: first, isDark: true)

        XCTAssertTrue(rendered === again, "the message's markdown was rendered a second time")
    }

    func testAMessageGrowingAsAChunkArrivesIsTheOnlyOneRenderedAgain() {
        let cache = TranscriptView.MarkdownCache()
        let settled = cache.rendered("the earlier message", forMessage: first, isDark: false)
        _ = cache.rendered("half a rep", forMessage: second, isDark: false)

        let grown = cache.rendered("half a reply", forMessage: second, isDark: false)

        XCTAssertTrue(cache.rendered("the earlier message", forMessage: first, isDark: false) === settled,
                      "the earlier message was rendered again for a chunk of the last one")
        XCTAssertEqual(grown.string, MarkdownRenderer.render("half a reply", isDark: false).string)
    }

    func testAMessageAppendedToTheConversationLeavesTheEarlierOnesCached() {
        let cache = TranscriptView.MarkdownCache()
        let settled = cache.rendered("the earlier message", forMessage: first, isDark: false)

        let appended = cache.rendered("a new message", forMessage: second, isDark: false)

        XCTAssertTrue(cache.rendered("the earlier message", forMessage: first, isDark: false) === settled,
                      "appending a message re-rendered the one before it")
        XCTAssertEqual(appended.string, MarkdownRenderer.render("a new message", isDark: false).string)
    }

    func testFlippingBetweenDarkAndLightRendersEveryMessageAgain() {
        let cache = TranscriptView.MarkdownCache()
        let firstInLight = cache.rendered("```swift\nlet a = 1\n```", forMessage: first, isDark: false)
        let secondInLight = cache.rendered("plain enough", forMessage: second, isDark: false)

        let firstInDark = cache.rendered("```swift\nlet a = 1\n```", forMessage: first, isDark: true)
        let secondInDark = cache.rendered("plain enough", forMessage: second, isDark: true)

        XCTAssertFalse(firstInLight === firstInDark, "a dark transcript served the light colours")
        XCTAssertFalse(secondInLight === secondInDark, "a dark transcript served the light colours")
    }

    func testAMessageNoLongerInTheConversationLeavesNoEntryBehind() {
        let cache = TranscriptView.MarkdownCache()
        _ = cache.rendered("the earlier message", forMessage: first, isDark: false)
        let kept = cache.rendered("the last message", forMessage: second, isDark: false)

        cache.prune(keeping: [second])

        XCTAssertEqual(Array(cache.entries.keys), [second])
        XCTAssertTrue(cache.rendered("the last message", forMessage: second, isDark: false) === kept,
                      "pruning dropped a message the conversation still holds")
    }

    func testPruningToAnEmptyConversationEmptiesTheCache() {
        let cache = TranscriptView.MarkdownCache()
        _ = cache.rendered("the only message", forMessage: first, isDark: false)

        cache.prune(keeping: [])

        XCTAssertTrue(cache.entries.isEmpty)
    }
}
