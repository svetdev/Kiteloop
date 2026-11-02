import XCTest
import KiteloopCore
import WebKit
@testable import Kiteloop

/// A page's `alert`, `confirm` and `prompt` had no UI delegate method to reach,
/// so WebKit swallowed the alert, answered Cancel and returned an empty prompt
/// without asking anyone. These pin that the pane now parks the dialog for the
/// human and hands the answer back to the page — and that it still answers at
/// once while an agent drives the pane.
///
/// Each dialog is raised from a `setTimeout` so the script that schedules it
/// returns straight away; the page's own variable carries the answer back.
@MainActor
final class WebPreviewPageDialogTests: XCTestCase {
    /// Every `WKUIDelegate` method is optional, so a near-miss on an async
    /// spelling compiles and exports nothing, and the dialog goes back to
    /// being swallowed.
    func testTheDialogAndOpenPanelMethodsAreWiredIntoWebKitAtAll() throws {
        let preview = WebPreviewViewModel()
        let delegate = try XCTUnwrap(preview.webView.uiDelegate, "no UI delegate — WebKit has nobody to ask")

        for selector in [
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
        ] {
            XCTAssertTrue(delegate.responds(to: Selector(selector)), "WebKit has no \(selector) to call")
        }
    }

    func testAConfirmAnsweredOKGivesThePageTrue() async throws {
        let preview = try await previewWithPage()

        try await raise("confirm('x')", in: preview)
        let dialog = try await pendingDialog(in: preview)
        XCTAssertEqual(dialog.kind, .confirm)
        XCTAssertEqual(dialog.message, "x")
        preview.answerPageDialog(.ok())

        try await eventually("the page to receive OK") { await self.answer(in: preview) as? Bool == true }
        XCTAssertNil(preview.pendingPageDialog)
    }

    func testAConfirmAnsweredCancelGivesThePageFalse() async throws {
        let preview = try await previewWithPage()

        try await raise("confirm('x')", in: preview)
        _ = try await pendingDialog(in: preview)
        preview.answerPageDialog(.dismissed)

        try await eventually("the page to receive Cancel") { await self.answer(in: preview) as? Bool == false }
    }

    func testAPromptCarriesItsDefaultAndReturnsTheTypedValue() async throws {
        let preview = try await previewWithPage()

        try await raise("prompt('name', 'dflt')", in: preview)
        let dialog = try await pendingDialog(in: preview)
        XCTAssertEqual(dialog.kind, .prompt)
        XCTAssertEqual(dialog.message, "name")
        XCTAssertEqual(dialog.defaultText, "dflt")
        preview.answerPageDialog(.ok(text: "typed"))

        try await eventually("the page to receive the typed value") {
            await self.answer(in: preview) as? String == "typed"
        }
    }

    func testAConfirmWhileAnAgentDrivesParksNothingAndReturnsFalse() async throws {
        let preview = try await previewWithPage()

        let result = await preview.withAgentAttribution {
            try? await preview.webView.evaluateJavaScript("confirm('x')") as? Bool
        }

        XCTAssertEqual(result, false, "an agent's confirm is answered Cancel, as before")
        XCTAssertNil(preview.pendingPageDialog, "no sheet may wait on the human while an agent drives")
    }

    // MARK: - Helpers

    private func previewWithPage() async throws -> WebPreviewViewModel {
        let preview = WebPreviewViewModel()
        try await load("<p>dialogs</p>", into: preview)
        return preview
    }

    /// Schedules `call` on the page and returns before it runs, so the dialog
    /// it raises is not waited on by this script.
    private func raise(_ call: String, in preview: WebPreviewViewModel) async throws {
        _ = try await preview.webView.evaluateJavaScript(
            "window.__dialogAnswer = undefined; setTimeout(function () { window.__dialogAnswer = \(call); }, 0); true"
        )
    }

    private func pendingDialog(in preview: WebPreviewViewModel) async throws -> WebPageDialog {
        try await eventuallyValue("the page's dialog to be parked for the human") { preview.pendingPageDialog }
    }

    private func answer(in preview: WebPreviewViewModel) async -> Any? {
        try? await preview.webView.evaluateJavaScript("window.__dialogAnswer")
    }
}
