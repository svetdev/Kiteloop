import XCTest

@MainActor
final class WebPreviewUITests: KiteloopUITestCase {

    /// Toggling the toolbar button shows and hides the web preview pane.
    func testTogglesWebPreviewPane() {
        launchAndOpenProject()

        let toggle = app.buttons["inspector-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Web preview toggle should exist in the toolbar")

        let urlField = app.textFields["web-preview-url-field"]
        XCTAssertFalse(urlField.exists, "Pane should be hidden before toggling")

        toggle.click()
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "URL field should appear when the pane opens")
        // SwiftUI's segmented Picker surfaces as a RadioGroup on macOS.
        XCTAssertTrue(app.radioGroups["web-preview-mode-picker"].waitForExistence(timeout: 3),
                      "Mode picker should be present")

        toggle.click()
        // The field should go away when the pane closes.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: urlField)
        waitForExpectations(timeout: 5)
    }

    /// In Trusted mode, an external URL is refused by the navigation gate and a
    /// "Blocked" banner is shown instead of navigating.
    func testTrustedModeBlocksExternalURL() {
        launchAndOpenProject()

        let toggle = app.buttons["inspector-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()

        let urlField = app.textFields["web-preview-url-field"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        urlField.click()
        urlField.typeText("https://example.com\n")

        let blocked = app.staticTexts["web-preview-blocked-banner"]
        XCTAssertTrue(blocked.waitForExistence(timeout: 5),
                      "Trusted mode should block an external URL with a banner")
        // SwiftUI Text surfaces its string as `value`, not `label`.
        let bannerText = (blocked.value as? String) ?? blocked.label
        XCTAssertTrue(bannerText.localizedCaseInsensitiveContains("blocked"),
                      "Banner should say the URL was blocked; got: \(bannerText)")
    }

    /// A local file:// document renders in Trusted mode (end-to-end WebKit load).
    func testLoadsLocalFileInTrustedMode() throws {
        let marker = "KITELOOP_PREVIEW_OK"
        let html = "<html><body><h1>\(marker)</h1></body></html>"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiteloop-preview-\(UUID().uuidString).html")
        try html.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        launchAndOpenProject()
        let toggle = app.buttons["inspector-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()

        let urlField = app.textFields["web-preview-url-field"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        urlField.click()
        urlField.typeText(fileURL.path + "\n")

        let rendered = app.webViews.staticTexts[marker]
        XCTAssertTrue(rendered.waitForExistence(timeout: 10),
                      "The local HTML should render inside the web view")
    }
}
