import XCTest
import WebKit
@testable import Kiteloop

/// The load-and-wait every web tool test shares.
///
/// The obvious spelling — and the one that shipped, copied into four test files —
/// was `while preview.isLoading || preview.currentURL == nil`. It only works for
/// the *first* load. `isLoading` is false before a load starts as well as after it
/// finishes, and on a second load `currentURL` is already non-nil from the page
/// before, so both conditions read false on the very first sample and the helper
/// returns while the old document is still on screen. Everything asserted after it
/// then describes the previous page. Two `loadHTMLString(baseURL: nil)` pages are
/// both `about:blank`, so no assertion downstream could notice.
///
/// So the wait keys off the document rather than sampling a flag: the document
/// about to be replaced is marked, and the wait runs until the pane is idle on a
/// document that does not carry that mark. A mark can only disappear by the
/// document being replaced, which is what these tests mean by "loaded".
@MainActor
extension XCTestCase {
    /// Renders `html` in the pane and waits for it to land. `loadHTMLString`
    /// navigates to `about:blank`, which the gate allows in any mode.
    func load(
        _ html: String, into preview: WebPreviewViewModel,
        viewport: NSSize = WebTestLoad.viewport
    ) async throws {
        try await loadPage(into: preview, viewport: viewport) {
            $0.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Renders `html` as if served from `baseURL` — an http origin, which is
    /// what a dev server gives the pane. `about:blank` and `file://` documents
    /// have opaque origins, and WebKit reports an uncaught error in one only as
    /// "Script error.", with no message, script, line or column.
    func load(
        _ html: String, servedFrom baseURL: URL, into preview: WebPreviewViewModel,
        viewport: NSSize = WebTestLoad.viewport
    ) async throws {
        try await loadPage(into: preview, viewport: viewport) {
            $0.loadHTMLString(html, baseURL: baseURL)
        }
    }

    /// Loads a real `file://` page, which is what it takes for a click or a handler
    /// to produce an actual navigation — `loadHTMLString` leaves the document at
    /// `about:blank`, whose opaque origin navigates nowhere.
    func loadFile(
        _ page: URL, into preview: WebPreviewViewModel,
        viewport: NSSize = WebTestLoad.viewport
    ) async throws {
        try await loadPage(into: preview, viewport: viewport) {
            $0.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    private func loadPage(
        into preview: WebPreviewViewModel, viewport: NSSize, start: (WKWebView) -> Void
    ) async throws {
        preview.webView.frame = NSRect(origin: .zero, size: viewport)
        let mark = try await markDocument(preview)
        start(preview.webView)

        let deadline = Date().addingTimeInterval(WebTestLoad.timeout)
        while true {
            if !preview.isLoading, preview.currentURL != nil,
               let current = await documentMark(preview), current != mark {
                await assertFixtureDidNotShadowWindowName(preview)
                return
            }
            if Date() > deadline { throw XCTSkip("the preview pane did not finish loading in time") }
            try await Task.sleep(nanoseconds: WebTestLoad.pollInterval)
        }
    }

    /// `window.name` is a native `DOMString` property every browsing context
    /// carries, empty unless something sets it, and none of these fixtures ever
    /// need to. A fixture's inline script that declares a bare top-level `var
    /// name = …` does not create a new binding — it assigns straight through
    /// this setter, stringifying whatever it held (`"[object HTMLInputElement]"`
    /// for an element). Every later reference to that identifier then reads the
    /// stringified value back, typically throwing on the very next property
    /// access, and the rest of the script silently never runs.
    ///
    /// That is what escaped review in `web-type-fixture-window-name`: three
    /// `WebTypeToolTests` cases asserted against a page whose script had died
    /// this way, three screens of code away from the line that killed it, and
    /// the fix that landed patched only that one fixture. Checking here instead
    /// catches the same collision the moment any fixture loads — this one,
    /// every sibling fixture across the other web tool tests, and any fixture
    /// written after this one — rather than trusting a one-off manual audit of
    /// today's fixtures to have found every instance and to hold for tomorrow's.
    private func assertFixtureDidNotShadowWindowName(
        _ preview: WebPreviewViewModel, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let name = try? await preview.webView.evaluateJavaScript("window.name") as? String
        XCTAssertEqual(name, "",
                       "a fixture's global `var name` shadowed `window.name` and swallowed the rest of its script — use `const`/`let`, or a name that isn't a Window property",
                       file: file, line: line)
    }

    /// Marks the document that is about to be navigated away from, and hands back
    /// the mark whose disappearance means the new page has arrived.
    ///
    /// The write is read back rather than assumed: a mark that never landed would
    /// look exactly like a document that had already been replaced, which is the
    /// bug this helper exists to close. There is nothing to mark before the pane's
    /// first load, and nothing to confuse either — `currentURL` is still nil then.
    private func markDocument(_ preview: WebPreviewViewModel) async throws -> String {
        WebTestLoad.count += 1
        let mark = "kiteloop-load-\(WebTestLoad.count)"
        let echoed = try? await preview.webView.evaluateJavaScript(
            "window.__kiteloopLoadMark = '\(mark)'; window.__kiteloopLoadMark"
        ) as? String
        if echoed != mark, preview.currentURL != nil {
            throw XCTSkip("the page in the pane could not be marked, so the next load cannot be waited for")
        }
        return mark
    }

    /// The mark the pane's current document carries, or `nil` if it could not be
    /// asked. A document that cannot answer is treated as "still the old one", so
    /// an unresponsive pane times out into a skip rather than passing early.
    private func documentMark(_ preview: WebPreviewViewModel) async -> String? {
        try? await preview.webView.evaluateJavaScript(
            "String(window.__kiteloopLoadMark || '')"
        ) as? String
    }
}

/// Knobs for the wait above. The viewport is shared so that tests measuring
/// against it — `WebScrollToolTests` — read the size they were actually given
/// rather than restating it.
enum WebTestLoad {
    static let viewport = NSSize(width: 900, height: 700)
    static let timeout: TimeInterval = 10
    static let pollInterval: UInt64 = 20_000_000

    /// Only has to be unique across the loads of one run, which the tests drive one
    /// at a time on the main actor.
    @MainActor static var count = 0
}
