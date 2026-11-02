import XCTest
import KiteloopCore
@testable import Kiteloop

/// The action row's Open in Browser button hands the page the pane shows to the
/// user's own browser. These pin what reaches the opener, that an empty pane
/// hands over nothing, and that opening is not a navigation of the pane.
@MainActor
final class WebPreviewOpenInBrowserTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "web-preview-open-in-browser-tests")
    }

    func testOpeningALoadedPageHandsTheOpenerExactlyThatPageOnce() async throws {
        let preview = WebPreviewViewModel()
        var opened: [URL] = []
        preview.openURLInBrowser = { opened.append($0) }
        let page = tempDir.appending(path: "page.html")
        try "<html><body>hello</body></html>".write(to: page, atomically: true, encoding: .utf8)
        try await loadFile(page, into: preview)
        let shown = try XCTUnwrap(preview.currentURL)

        XCTAssertTrue(preview.canOpenInBrowser, "a loaded file page enables the button")
        preview.openInBrowser()

        XCTAssertEqual(opened, [shown])
    }

    func testAFreshPreviewOpensNothing() {
        let preview = WebPreviewViewModel()
        var opened: [URL] = []
        preview.openURLInBrowser = { opened.append($0) }

        XCTAssertFalse(preview.canOpenInBrowser, "no page, so the button is disabled")
        preview.openInBrowser()

        XCTAssertTrue(opened.isEmpty)
    }

    func testABlankPageIsNotHandedToTheBrowser() async throws {
        let preview = WebPreviewViewModel()
        var opened: [URL] = []
        preview.openURLInBrowser = { opened.append($0) }
        try await load("<p>inline</p>", into: preview)

        XCTAssertFalse(preview.canOpenInBrowser, "about:blank means nothing in another browser")
        preview.openInBrowser()

        XCTAssertTrue(opened.isEmpty)
    }

    func testOpeningLeavesModeAllowlistAndBannersAlone() async throws {
        let preview = WebPreviewViewModel()
        preview.openURLInBrowser = { _ in }
        let page = tempDir.appending(path: "page.html")
        try "<html><body>hello</body></html>".write(to: page, atomically: true, encoding: .utf8)
        try await loadFile(page, into: preview)
        preview.mode = .external
        preview.allowlist = ["example.com"]
        let failure = preview.loadFailure
        let blocked = preview.blockedMessage

        preview.openInBrowser()

        XCTAssertEqual(preview.mode, .external)
        XCTAssertEqual(preview.allowlist, ["example.com"])
        XCTAssertEqual(preview.loadFailure, failure)
        XCTAssertEqual(preview.blockedMessage, blocked)
    }
}
