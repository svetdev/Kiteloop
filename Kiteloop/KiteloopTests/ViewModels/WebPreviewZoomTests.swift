import XCTest
import KiteloopCore
@testable import Kiteloop

/// The control bar's zoom steps the page through fixed percentages. These pin
/// the steps, the ends of the range, the reset, that the web view's page zoom
/// always matches the percentage shown, that a load or reload keeps it, and
/// that a preview given a store brings the zoom back on the next launch.
@MainActor
final class WebPreviewZoomTests: XCTestCase {
    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "web-preview-zoom-tests")
        // A suite of this test's own, so nothing leaks into the app's defaults.
        suiteName = "WebPreviewZoomTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testAFreshPreviewIsAtOneHundredPercent() {
        let preview = WebPreviewViewModel()

        XCTAssertEqual(preview.zoomPercent, 100)
        XCTAssertEqual(preview.webView.pageZoom, 1.0)
    }

    func testZoomInAndOutMoveOneStepAndKeepThePageInStep() {
        let preview = WebPreviewViewModel()

        preview.zoomIn()
        XCTAssertEqual(preview.zoomPercent, 110)
        XCTAssertEqual(preview.webView.pageZoom, 1.1, accuracy: 0.0001)

        preview.zoomOut()
        preview.zoomOut()
        XCTAssertEqual(preview.zoomPercent, 90)
        XCTAssertEqual(preview.webView.pageZoom, 0.9, accuracy: 0.0001)
    }

    func testZoomInStopsAtThreeHundredPercent() {
        let preview = WebPreviewViewModel()
        for _ in WebPreviewViewModel.zoomSteps { preview.zoomIn() }
        XCTAssertEqual(preview.zoomPercent, 300)
        XCTAssertFalse(preview.canZoomIn)

        preview.zoomIn()

        XCTAssertEqual(preview.zoomPercent, 300)
        XCTAssertEqual(preview.webView.pageZoom, 3.0, accuracy: 0.0001)
        XCTAssertTrue(preview.canZoomOut)
    }

    func testZoomOutStopsAtFiftyPercent() {
        let preview = WebPreviewViewModel()
        for _ in WebPreviewViewModel.zoomSteps { preview.zoomOut() }
        XCTAssertEqual(preview.zoomPercent, 50)
        XCTAssertFalse(preview.canZoomOut)

        preview.zoomOut()

        XCTAssertEqual(preview.zoomPercent, 50)
        XCTAssertEqual(preview.webView.pageZoom, 0.5, accuracy: 0.0001)
        XCTAssertTrue(preview.canZoomIn)
    }

    func testResetReturnsToOneHundredPercentFromEveryStep() {
        let preview = WebPreviewViewModel()
        for step in WebPreviewViewModel.zoomSteps {
            preview.resetZoom()
            while preview.zoomPercent < step { preview.zoomIn() }
            while preview.zoomPercent > step { preview.zoomOut() }
            XCTAssertEqual(preview.zoomPercent, step)

            preview.resetZoom()

            XCTAssertEqual(preview.zoomPercent, 100, "from \(step)%")
            XCTAssertEqual(preview.webView.pageZoom, 1.0, "from \(step)%")
        }
    }

    func testZoomSurvivesALoadAndAReload() async throws {
        let preview = WebPreviewViewModel()
        while preview.zoomPercent < 150 { preview.zoomIn() }
        let page = tempDir.appending(path: "page.html")
        try "<html><body>hello</body></html>".write(to: page, atomically: true, encoding: .utf8)

        try await loadFile(page, into: preview)
        XCTAssertEqual(preview.zoomPercent, 150)
        XCTAssertEqual(preview.webView.pageZoom, 1.5, accuracy: 0.0001)

        let started = preview.navigationsStarted
        preview.reload()
        try await eventually("the reload to finish") { preview.navigationsStarted > started && !preview.isLoading }

        XCTAssertEqual(preview.zoomPercent, 150)
        XCTAssertEqual(preview.webView.pageZoom, 1.5, accuracy: 0.0001)
    }

    func testTheZoomComesBackOnTheNextLaunch() {
        WebPreviewViewModel(addressStore: defaults).zoomIn()

        let next = WebPreviewViewModel(addressStore: defaults)

        XCTAssertEqual(next.zoomPercent, 110)
        XCTAssertEqual(next.webView.pageZoom, 1.1, accuracy: 0.0001)
    }

    func testAResetIsRememberedToo() {
        let first = WebPreviewViewModel(addressStore: defaults)
        first.zoomIn()
        first.resetZoom()

        let next = WebPreviewViewModel(addressStore: defaults)

        XCTAssertEqual(next.zoomPercent, 100)
        XCTAssertEqual(next.webView.pageZoom, 1.0)
    }

    func testAStoredValueThatIsNotAZoomStepIsIgnored() {
        defaults.set(137, forKey: WebPreviewViewModel.rememberedZoomKey)

        let preview = WebPreviewViewModel(addressStore: defaults)

        XCTAssertEqual(preview.zoomPercent, 100)
        XCTAssertEqual(preview.webView.pageZoom, 1.0)
    }

    func testAPreviewWithoutAStoreStartsAtOneHundredAndWritesNothing() {
        let key = WebPreviewViewModel.rememberedZoomKey
        let standardBefore = UserDefaults.standard.object(forKey: key) as? Int

        let preview = WebPreviewViewModel()
        XCTAssertEqual(preview.zoomPercent, 100)
        preview.zoomIn()

        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Int, standardBefore)
        XCTAssertNil(defaults.object(forKey: key))
    }
}
