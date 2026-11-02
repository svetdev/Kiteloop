import XCTest
import KiteloopCore
@testable import Kiteloop

/// Switching the pane's mode back to Trusted has to make good on what the
/// label promises, not just relabel whatever External left standing: every
/// host the human approved, any confirmation still parked, and the page
/// currently on screen all have to answer to the new mode. Widening from
/// Trusted to External is the easy direction and grants nothing on its own,
/// so it is covered here mainly to pin that it stays a no-op.
@MainActor
final class WebPreviewModeSwitchTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "web-preview-mode-switch-tests")
    }

    // MARK: - Trusted revokes what External granted

    func testSwitchingToTrustedRevokesAConfirmedHost() {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        XCTAssertEqual(preview.load("https://example.invalid/", source: .programmatic), .confirm,
                       "setup: an unapproved external host should park for confirmation")
        preview.confirmPendingExternal()
        XCTAssertEqual(preview.allowlist, ["example.invalid"], "setup: the host should be approved")

        preview.setMode(.trusted)

        XCTAssertTrue(preview.allowlist.isEmpty,
                      "Trusted must not inherit a host External approved")
        XCTAssertNil(preview.pendingExternalURL)
    }

    func testSwitchingToTrustedDropsAStillPendingConfirmation() {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        XCTAssertEqual(preview.load("https://example.invalid/", source: .programmatic), .confirm,
                       "setup: an unapproved external host should park for confirmation")
        XCTAssertNotNil(preview.pendingExternalURL, "setup: the confirmation should be pending")

        preview.setMode(.trusted)

        XCTAssertNil(preview.pendingExternalURL,
                     "a confirmation still waiting on the human must not survive the switch")
    }

    // MARK: - Trusted re-checks the page on screen

    /// `.invalid` is reserved never to resolve (RFC 2606), so this reaches the
    /// real `WKNavigationDelegate` path — the same guarantee `WebScrollToolTests`
    /// and `WebClickToolTests` rely on — without the test ever touching the
    /// network.
    func testSwitchingToTrustedBlocksAndLeavesAPageTheGateRefusesThere() async throws {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        // `loadHTMLString(_:baseURL:)`, not a real load of an .invalid host:
        // the page commits from memory with the refused host as its URL, so
        // the delegate path runs without DNS — the "never touching the
        // network" this test's own doc promises, and deterministic under a
        // loaded suite host where a failing provisional load may surface no
        // callback at all.
        preview.webView.loadHTMLString("<html><body>external</body></html>",
                                       baseURL: URL(string: "https://example.invalid/next")!)
        try await eventually(timeout: .seconds(30), "the pane picks up the external page") {
            preview.currentURL?.host == "example.invalid"
        }

        preview.setMode(.trusted)

        XCTAssertEqual(preview.mode, .trusted)
        XCTAssertTrue(preview.blockedMessage?.contains("example.invalid") == true,
                      "expected a block naming the refused host, got: \(preview.blockedMessage ?? "nil")")
        try await eventually(timeout: .seconds(30), "the pane moves off the refused page") {
            preview.currentURL?.host != "example.invalid"
        }
    }

    func testSwitchingToTrustedKeepsALocalPageLoaded() async throws {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        let page = try writePage("<html><body>hi</body></html>")
        try await loadFile(page, into: preview)
        let before = preview.currentURL

        preview.setMode(.trusted)

        XCTAssertEqual(preview.currentURL, before,
                       "a page Trusted already allows must not be navigated away from")
        XCTAssertNil(preview.blockedMessage)
    }

    // MARK: - External only widens

    func testSwitchingToExternalClearsNothingAndBlocksNothing() {
        let preview = WebPreviewViewModel()
        preview.mode = .trusted
        preview.allowlist = ["example.com"]

        preview.setMode(.external)

        XCTAssertEqual(preview.mode, .external)
        XCTAssertEqual(preview.allowlist, ["example.com"],
                       "External must not touch an allowlist it did not build")
        XCTAssertNil(preview.blockedMessage)
    }

    // MARK: - No-op

    func testSettingTheSameModeDoesNotDisturbState() {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        preview.allowlist = ["example.com"]

        preview.setMode(.external)

        XCTAssertEqual(preview.allowlist, ["example.com"])
    }

    // MARK: - Load in External

    func testATrustedRefusalRecordsTheRefusedAddress() {
        let preview = WebPreviewViewModel()

        XCTAssertEqual(preview.load("example.invalid", source: .user), .deny)

        XCTAssertTrue(preview.blockedMessage?.contains("example.invalid") == true,
                      "expected a block naming the refused host, got: \(preview.blockedMessage ?? "nil")")
        XCTAssertEqual(preview.refusedURL?.absoluteString, "https://example.invalid")
    }

    func testLoadingTheRefusedAddressInExternalSwitchesModeAndLoadsIt() {
        let preview = WebPreviewViewModel()
        preview.load("example.invalid", source: .user)

        preview.loadRefusedInExternal()

        XCTAssertEqual(preview.mode, .external)
        XCTAssertNil(preview.blockedMessage)
        XCTAssertEqual(preview.urlText, "https://example.invalid")
    }

    func testAnInvalidAddressRecordsNothingToLoadInExternal() {
        let preview = WebPreviewViewModel()

        XCTAssertEqual(preview.load("", source: .user), .deny)
        XCTAssertEqual(preview.blockedMessage, "Not a valid URL or path.")
        XCTAssertNil(preview.refusedURL)

        preview.loadRefusedInExternal()

        XCTAssertEqual(preview.mode, .trusted)
    }

    func testSwitchingToTrustedRecordsTheBlankedPageAsRefused() async throws {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        preview.webView.loadHTMLString("<html><body>external</body></html>",
                                       baseURL: URL(string: "https://example.invalid/next")!)
        try await eventually(timeout: .seconds(30), "the pane picks up the external page") {
            preview.currentURL?.host == "example.invalid"
        }

        preview.setMode(.trusted)

        XCTAssertEqual(preview.refusedURL?.absoluteString, "https://example.invalid/next")
    }

    func testAnAllowedLoadClearsTheRefusedAddress() throws {
        let preview = WebPreviewViewModel()
        preview.load("example.invalid", source: .user)
        XCTAssertNotNil(preview.refusedURL, "setup: the refusal should record its address")

        let page = try writePage("<html><body>hi</body></html>")
        XCTAssertEqual(preview.load(page.path, source: .user), .allow)

        XCTAssertNil(preview.refusedURL)
    }

    // MARK: - Helpers

    /// Writes `html` into the test's directory and returns the page's file URL.
    private func writePage(_ html: String) throws -> URL {
        let dir = tempDir.appending(path: "pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = dir.appending(path: "page.html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        return page
    }
}
