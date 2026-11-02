import XCTest
import KiteloopCore
@testable import Kiteloop

/// A single-page app changes route without a page load — `pushState` or a
/// fragment change — and WebKit tells the navigation delegate nothing about it.
/// These pin that the address bar and Back follow such a change anyway, and that
/// it still does not count as a navigation for the agent tools' settle logic.
@MainActor
final class WebPreviewSameDocumentNavigationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "web-preview-same-document-tests")
    }

    private func loadPage(into preview: WebPreviewViewModel) async throws -> URL {
        let page = tempDir.appending(path: "app.html")
        try "<html><body>step one</body></html>".write(to: page, atomically: true, encoding: .utf8)
        try await loadFile(page, into: preview)
        return try XCTUnwrap(preview.currentURL)
    }

    func testAFragmentChangeMovesTheAddressBarAndEnablesBack() async throws {
        let preview = WebPreviewViewModel()
        let loaded = try await loadPage(into: preview)
        XCTAssertFalse(preview.canGoBack, "a first load has no history")
        _ = try await preview.webView.evaluateJavaScript("window.__notReloaded = true; location.hash = 'step2'; 1")

        try await eventually("the address bar follows the fragment change") {
            preview.currentURL?.fragment == "step2" && preview.urlText.hasSuffix("#step2")
        }
        try await eventually("Back is enabled by the in-page entry") { preview.canGoBack }
        let survived = try await preview.webView.evaluateJavaScript("window.__notReloaded === true") as? Bool
        XCTAssertEqual(survived, true, "the fragment change did not reload the page")

        preview.goBack()
        try await eventually("Back returns to the address without the fragment") {
            preview.currentURL == loaded
        }
        XCTAssertNil(preview.currentURL?.fragment)
    }

    func testAnInPageNavigationDoesNotCountAsANavigation() async throws {
        let preview = WebPreviewViewModel()
        _ = try await loadPage(into: preview)
        let startedBefore = preview.navigationsStarted
        _ = try await preview.webView.evaluateJavaScript("location.hash = 'step2'; 1")

        try await eventually("the fragment change is seen") { preview.currentURL?.fragment == "step2" }
        XCTAssertEqual(preview.navigationsStarted, startedBefore,
                       "a same-document change is not a page load")
    }
}
