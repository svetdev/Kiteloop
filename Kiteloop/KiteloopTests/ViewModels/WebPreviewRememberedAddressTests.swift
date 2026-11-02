import XCTest
import KiteloopCore
@testable import Kiteloop

/// The address bar remembers the last address loaded in Trusted mode across
/// launches — only filling the field in, never loading it — and only when the
/// view model was given a store to remember it in.
@MainActor
final class WebPreviewRememberedAddressTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDir: URL!

    override func setUp() async throws {
        // A suite of this test's own, so nothing leaks into the app's defaults.
        suiteName = "WebPreviewRememberedAddressTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = try makeTemporaryDirectory(prefix: "web-preview-remembered-address-tests")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    private func writePage(named name: String) throws -> URL {
        let page = tempDir.appendingPathComponent(name)
        try "<html><body>page</body></html>".write(to: page, atomically: true, encoding: .utf8)
        return page
    }

    func testATrustedLoadFillsTheNextPreviewsAddressWithoutLoadingIt() throws {
        let page = try writePage(named: "index.html")
        let first = WebPreviewViewModel(addressStore: defaults)
        XCTAssertEqual(first.load(page.absoluteString, source: .user), .allow,
                       "setup: Trusted mode should allow a local file")

        let second = WebPreviewViewModel(addressStore: defaults)

        XCTAssertEqual(second.urlText, first.urlText)
        XCTAssertEqual(second.urlText, page.absoluteString)
        XCTAssertNil(second.currentURL, "the remembered address must only fill the field, not load")
    }

    func testAnAddressTheGateRefusesIsNotRemembered() throws {
        let page = try writePage(named: "index.html")
        let first = WebPreviewViewModel(addressStore: defaults)
        first.load(page.absoluteString, source: .user)
        XCTAssertEqual(first.load("https://example.invalid/", source: .user), .deny,
                       "setup: Trusted mode should refuse an external host")

        XCTAssertEqual(WebPreviewViewModel(addressStore: defaults).urlText, page.absoluteString)
    }

    func testAnAddressLoadedInExternalModeIsNotRemembered() {
        let first = WebPreviewViewModel(addressStore: defaults)
        first.setMode(.external)
        XCTAssertEqual(first.load("https://example.invalid/", source: .user), .allow,
                       "setup: External mode should let the human's own load through")

        XCTAssertEqual(WebPreviewViewModel(addressStore: defaults).urlText, "")
    }

    func testAPreviewWithoutAStoreStartsEmptyAndWritesNothing() throws {
        let page = try writePage(named: "index.html")
        let key = WebPreviewViewModel.rememberedAddressKey
        let standardBefore = UserDefaults.standard.object(forKey: key) as? String

        let preview = WebPreviewViewModel()
        XCTAssertEqual(preview.urlText, "")
        preview.load(page.absoluteString, source: .user)

        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? String, standardBefore)
        XCTAssertNil(defaults.object(forKey: key))
    }
}
