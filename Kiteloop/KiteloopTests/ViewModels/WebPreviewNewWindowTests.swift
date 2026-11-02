import XCTest
import KiteloopCore
import WebKit
@testable import Kiteloop

/// A link with `target="_blank"`, or a script calling `window.open`, asks WebKit
/// for a new web view. The pane had no UI delegate to ask, so WebKit dropped the
/// request and the click did nothing — no page, no banner. These pin that the
/// request now opens in the pane itself, through the same gate as any other
/// in-page navigation.
///
/// The request is handed to the delegate WebKit would call rather than raised by
/// a real click: WebKit's popup blocking refuses a scripted click, so a page
/// cannot stage one in-process. What runs is the delegate the web view actually
/// holds, reached through the selector WebKit calls it by.
@MainActor
final class WebPreviewNewWindowTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "web-preview-new-window-tests")
    }

    /// Every `WKUIDelegate` method is optional, so a near-miss on the signature
    /// compiles and exports nothing — the bug this item fixes, back again.
    func testTheNewWindowRequestIsWiredIntoWebKitAtAll() throws {
        let preview = WebPreviewViewModel()
        let delegate = try XCTUnwrap(preview.webView.uiDelegate, "no UI delegate — WebKit has nobody to ask")

        XCTAssertTrue(
            delegate.responds(to: Selector("webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:")),
            "WebKit has no new-window method to call — a target=_blank link does nothing"
        )
    }

    func testAnAllowedNewWindowLoadsInThePaneItself() async throws {
        let preview = WebPreviewViewModel()
        preview.mode = .trusted
        let page = tempDir.appending(path: "opened.html")
        try "<p>opened</p>".write(to: page, atomically: true, encoding: .utf8)
        let startedBefore = preview.navigationsStarted

        let created = try requestNewWindow(for: page, in: preview)

        XCTAssertNil(created, "a second web view would be a window the pane never shows")
        // Both, not the address alone: the address follows the web view's `url`,
        // which moves when the load is asked for, before the navigation starts.
        try await eventually("the requested page to land in the pane as a navigation") {
            preview.currentURL?.standardizedFileURL == page.standardizedFileURL
                && preview.navigationsStarted != startedBefore
        }
        XCTAssertNil(preview.blockedMessage)
        XCTAssertNil(preview.pendingExternalURL)
    }

    func testTrustedModeRefusesANewWindowToAnExternalHost() throws {
        let preview = WebPreviewViewModel()
        preview.mode = .trusted
        let startedBefore = preview.navigationsStarted

        let created = try requestNewWindow(for: Self.externalURL, in: preview)

        XCTAssertNil(created)
        XCTAssertTrue(preview.blockedMessage?.contains("example.invalid") == true,
                      "the refusal banner has to name the host — got: \(String(describing: preview.blockedMessage))")
        XCTAssertNil(preview.pendingExternalURL, "Trusted mode refuses; it does not offer to approve")
        XCTAssertEqual(preview.navigationsStarted, startedBefore, "a refused request must load nothing")
        XCTAssertNil(preview.webView.url)
    }

    /// External mode asks the human before an agent's click reaches a host it has
    /// not been approved for, and a new-window link is no way around that. Load
    /// then navigates the same pane.
    func testExternalModeParksAnAgentsNewWindowForTheHuman() async throws {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        preview.allowlist = []
        let startedBefore = preview.navigationsStarted

        let created = await preview.withAgentAttribution {
            try? requestNewWindow(for: Self.externalURL, in: preview)
        }

        XCTAssertNil(created)
        XCTAssertEqual(preview.pendingExternalURL, Self.externalURL,
                       "the confirm strip is what the human has to be shown")
        XCTAssertNil(preview.blockedMessage)
        XCTAssertEqual(preview.navigationsStarted, startedBefore, "nothing loads before the human says so")

        preview.confirmPendingExternal()

        XCTAssertNil(preview.pendingExternalURL)
        XCTAssertEqual(preview.urlText, Self.externalURL.absoluteString)
        try await eventually("Load to navigate the pane") { preview.navigationsStarted != startedBefore }
    }

    // MARK: - Helpers

    /// Under `.invalid`, reserved never to resolve: the gate decides before
    /// anything is fetched.
    private static let externalURL = URL(string: "https://example.invalid/popup")!

    /// Calls the web view's own UI delegate the way WebKit does for a
    /// `target="_blank"` link.
    private func requestNewWindow(for url: URL, in preview: WebPreviewViewModel) throws -> WKWebView? {
        let delegate = try XCTUnwrap(preview.webView.uiDelegate)
        let create = try XCTUnwrap(delegate.webView(_:createWebViewWith:for:windowFeatures:))
        return create(preview.webView, WKWebViewConfiguration(), NewWindowAction(url: url), WKWindowFeatures())
    }
}

/// A navigation action carrying only the request, which is all the pane reads.
private final class NewWindowAction: WKNavigationAction {
    private let stubbedRequest: URLRequest

    init(url: URL) {
        stubbedRequest = URLRequest(url: url)
        super.init()
    }

    override var request: URLRequest { stubbedRequest }
}
