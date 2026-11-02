import XCTest
import KiteloopCore
@testable import Kiteloop

/// The pane's Find searches the rendered page. These pin that a word on the
/// page is found, that a miss sets what the find row reads for "Not found",
/// and that an empty search or a new page clears it rather than leaving it up.
@MainActor
final class WebPreviewFindTests: XCTestCase {
    private let page = "<html><body><p>The quick brown kestrel hovers.</p></body></html>"

    func testAWordOnThePageIsFound() async throws {
        let preview = WebPreviewViewModel()
        try await load(page, into: preview)

        let found = await preview.find("kestrel")

        XCTAssertTrue(found)
        XCTAssertFalse(preview.findNotFound)
    }

    func testTextNotOnThePageIsNotFound() async throws {
        let preview = WebPreviewViewModel()
        try await load(page, into: preview)

        let found = await preview.find("albatross")

        XCTAssertFalse(found)
        XCTAssertTrue(preview.findNotFound)
    }

    func testSearchingBackwardsFindsTheWordToo() async throws {
        let preview = WebPreviewViewModel()
        try await load(page, into: preview)

        let found = await preview.find("KESTREL", backwards: true)

        XCTAssertTrue(found, "the search is case-insensitive and wraps from either end")
        XCTAssertFalse(preview.findNotFound)
    }

    func testAnEmptySearchDoesNotReportNotFound() async throws {
        let preview = WebPreviewViewModel()
        try await load(page, into: preview)
        await preview.find("albatross")
        XCTAssertTrue(preview.findNotFound)

        await preview.find("")

        XCTAssertFalse(preview.findNotFound)
    }

    func testANewPageClearsNotFound() async throws {
        let preview = WebPreviewViewModel()
        try await load(page, into: preview)
        await preview.find("albatross")
        XCTAssertTrue(preview.findNotFound)

        try await load("<html><body><p>An osprey dives.</p></body></html>", into: preview)

        XCTAssertFalse(preview.findNotFound)
    }
}
