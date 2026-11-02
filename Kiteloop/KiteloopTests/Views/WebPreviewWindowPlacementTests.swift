import AppKit
import XCTest
@testable import Kiteloop

/// The popped-out preview opens where it was last left. These place plain
/// windows that are never ordered front, each under a name of its own, and
/// remove that name's saved frame afterwards so the app's defaults keep none.
@MainActor
final class WebPreviewWindowPlacementTests: XCTestCase {
    private var autosaveName = ""

    override func setUp() {
        super.setUp()
        autosaveName = "WebPreviewWindowPlacementTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)")
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    func testWithNoSavedFrameTheWindowIsNineHundredBySevenHundredAndCentred() {
        let window = makeWindow()
        AppKitWebPreviewWindowPresenter.place(window, frameAutosaveName: autosaveName)

        let expected = makeWindow()
        expected.setContentSize(NSSize(width: 900, height: 700))
        expected.center()

        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size,
                       NSSize(width: 900, height: 700))
        XCTAssertEqual(window.frame, expected.frame)
        XCTAssertEqual(window.frameAutosaveName, autosaveName)
    }

    func testANewWindowWithTheSameNameGetsTheFrameTheLastOneWasLeftAt() {
        let moved = NSRect(x: 120, y: 140, width: 520, height: 410)
        autoreleasepool {
            let first = makeWindow()
            AppKitWebPreviewWindowPresenter.place(first, frameAutosaveName: autosaveName)
            first.setFrame(moved, display: false)
            first.close()
        }

        let second = makeWindow()
        AppKitWebPreviewWindowPresenter.place(second, frameAutosaveName: autosaveName)

        XCTAssertEqual(second.frame, moved)
        XCTAssertNotEqual(second.contentRect(forFrameRect: second.frame).size,
                          NSSize(width: 900, height: 700))
    }
}
