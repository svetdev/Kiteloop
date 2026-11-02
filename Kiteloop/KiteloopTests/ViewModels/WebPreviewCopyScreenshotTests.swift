import AppKit
import XCTest
import KiteloopCore
@testable import Kiteloop

/// The action row's Copy Screenshot button puts the rendered page on the
/// clipboard, with or without an agent. These copy to a uniquely named
/// pasteboard so the user's clipboard is never touched.
@MainActor
final class WebPreviewCopyScreenshotTests: XCTestCase {
    private var tempDir: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "web-preview-copy-screenshot-tests")
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    func testCopyingALoadedPageLeavesAPNGWithNoAgentSelected() async throws {
        let preview = WebPreviewViewModel()
        let page = tempDir.appending(path: "page.html")
        try "<html><body>hello</body></html>".write(to: page, atomically: true, encoding: .utf8)
        try await loadFile(page, into: preview)
        XCTAssertNil(preview.attachTargetVM, "setup: no agent selected")
        XCTAssertNil(preview.currentAgentName, "setup: no agent selected")

        await preview.copyScreenshot(to: pasteboard)

        let data = try XCTUnwrap(pasteboard.data(forType: .png), "a PNG is on the pasteboard")
        let image = try XCTUnwrap(NSImage(data: data), "the data decodes as an image")
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertNil(preview.loadFailure, "a copy that worked shows no banner")
        XCTAssertNil(preview.attachTargetVM, "copying attaches to no chat")
    }

    /// A zero-frame web view is the state WebKit cannot render.
    func testAFailedCaptureSaysSoAndLeavesThePasteboardAlone() async {
        let preview = WebPreviewViewModel()
        pasteboard.clearContents()
        pasteboard.setString("kept", forType: .string)

        await preview.copyScreenshot(to: pasteboard)

        XCTAssertEqual(preview.loadFailure,
                       WebPreviewViewModel.ScreenshotError.captureFailed.errorDescription,
                       "same text a failed Send screenshot shows")
        XCTAssertEqual(pasteboard.string(forType: .string), "kept", "the pasteboard was not cleared")
        XCTAssertNil(pasteboard.data(forType: .png))
    }
}
