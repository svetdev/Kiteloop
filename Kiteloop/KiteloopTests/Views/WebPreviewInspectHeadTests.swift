import XCTest
@testable import Kiteloop

/// The Inspect head sheet tells a head with markup, an empty head and a read
/// that failed apart, instead of showing "(empty)" for all three.
final class WebPreviewInspectHeadTests: XCTestCase {

    private let page = URL(string: "http://localhost:3000/about")!

    func testMarkupIsShownUnchanged() {
        let markup = "<title>About</title>\n<meta property=\"og:title\" content=\"About\">"
        XCTAssertEqual(WebPreviewPanel.headSheetText(.success(markup), pageURL: page), markup)
    }

    func testEmptyHeadIsSaidInWords() {
        let text = WebPreviewPanel.headSheetText(.success("  \n"), pageURL: page)
        XCTAssertTrue(text.contains("is empty"))
        XCTAssertTrue(text.contains(page.absoluteString))
        XCTAssertNotEqual(text, "(empty)")
    }

    func testFailedReadNamesThePageAndTheReason() {
        let error = NSError(domain: "WKErrorDomain", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "A JavaScript exception occurred"])
        let text = WebPreviewPanel.headSheetText(.failure(error), pageURL: page)
        XCTAssertTrue(text.contains(page.absoluteString))
        XCTAssertTrue(text.contains("A JavaScript exception occurred"))
        XCTAssertNotEqual(text, WebPreviewPanel.headSheetText(.success(""), pageURL: page))
        XCTAssertFalse(text.contains("is empty"))
    }
}
