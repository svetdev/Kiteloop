import XCTest
@testable import Kiteloop

/// The pane follows the title of the page it shows, so a popped-out window can
/// be named after it rather than every preview reading "Web Preview".
@MainActor
final class WebPreviewPageTitleTests: XCTestCase {
    func testALoadedPageNamesTheWindow() async throws {
        let preview = WebPreviewViewModel()
        try await load("<html><head><title>Kestrel</title></head><body>k</body></html>", into: preview)

        try await eventually("the page title is picked up") { preview.pageTitle == "Kestrel" }
        XCTAssertEqual(preview.windowTitle, "Web Preview — Kestrel")
    }

    func testASecondPageReplacesTheTitle() async throws {
        let preview = WebPreviewViewModel()
        try await load("<html><head><title>Kestrel</title></head><body>k</body></html>", into: preview)
        try await eventually("the first title is picked up") { preview.pageTitle == "Kestrel" }

        try await load("<html><head><title>Merlin</title></head><body>m</body></html>", into: preview)
        try await eventually("the second title replaces the first") { preview.pageTitle == "Merlin" }
        XCTAssertEqual(preview.windowTitle, "Web Preview — Merlin")
    }

    func testAScriptChangingTheTitleIsFollowed() async throws {
        let preview = WebPreviewViewModel()
        try await load("<html><head><title>Kestrel</title></head><body>k</body></html>", into: preview)
        try await eventually("the first title is picked up") { preview.pageTitle == "Kestrel" }
        let startedBefore = preview.navigationsStarted

        _ = try await preview.webView.evaluateJavaScript("document.title = 'Hobby'; 1")
        try await eventually("the scripted title is picked up") { preview.pageTitle == "Hobby" }
        XCTAssertEqual(preview.navigationsStarted, startedBefore, "the title changed without a navigation")
    }

    func testAPageWithNoTitleLeavesTheWindowPlain() async throws {
        let preview = WebPreviewViewModel()
        try await load("<html><head><title>Kestrel</title></head><body>k</body></html>", into: preview)
        try await eventually("the first title is picked up") { preview.pageTitle == "Kestrel" }

        try await load("<html><body>untitled</body></html>", into: preview)
        try await eventually("the old title is dropped") { preview.pageTitle.isEmpty }
        XCTAssertEqual(preview.windowTitle, "Web Preview")
    }

    func testAWhitespaceTitleLeavesTheWindowPlain() async throws {
        let preview = WebPreviewViewModel()
        try await load("<html><head><title>Kestrel</title></head><body>k</body></html>", into: preview)
        try await eventually("the first title is picked up") { preview.pageTitle == "Kestrel" }

        try await load("<html><head><title>   </title></head><body>blank</body></html>", into: preview)
        try await eventually("the old title is dropped") { preview.pageTitle != "Kestrel" }
        XCTAssertEqual(preview.windowTitle, "Web Preview")
    }

    func testNoPageLeavesTheWindowPlain() {
        XCTAssertEqual(WebPreviewViewModel().windowTitle, "Web Preview")
    }
}
