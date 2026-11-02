import XCTest
@testable import Kiteloop

/// One `WKWebView` renders the preview and a view has one superview, so the
/// manager has to say which host holds the page and be able to hand it back.
/// These drive show and close through an injected presenter, so no real window
/// is ever built.
@MainActor
final class WebPreviewWindowManagerTests: XCTestCase {

    /// Stands in for the detached window: records the teardown instead of
    /// closing an `NSWindow`, and can report a close the human made.
    private final class FakeWindow: WebPreviewDetachedWindowHosting {
        var focusCount = 0
        var closeCount = 0
        var onClose: (@MainActor () -> Void)?

        func focus() { focusCount += 1 }
        func close() { closeCount += 1 }

        /// What `NSWindow.willCloseNotification` does in the real presenter.
        func simulateHumanClose() { onClose?() }
    }

    private final class FakePresenter: WebPreviewWindowPresenting {
        var presentCount = 0
        var lastWindow: FakeWindow?

        func present(viewModel: WebPreviewViewModel,
                     onClose: @escaping @MainActor () -> Void) -> WebPreviewDetachedWindowHosting {
            presentCount += 1
            let window = FakeWindow()
            window.onClose = onClose
            lastWindow = window
            return window
        }
    }

    func testShowReportsDetached() {
        let presenter = FakePresenter()
        let manager = WebPreviewWindowManager(presenter: presenter)
        XCTAssertFalse(manager.isDetached)

        manager.show(viewModel: WebPreviewViewModel())

        XCTAssertTrue(manager.isDetached)
        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testShowingTwiceFocusesTheOneWindow() {
        let presenter = FakePresenter()
        let manager = WebPreviewWindowManager(presenter: presenter)
        let viewModel = WebPreviewViewModel()

        manager.show(viewModel: viewModel)
        manager.show(viewModel: viewModel)

        XCTAssertEqual(presenter.presentCount, 1)
        XCTAssertEqual(presenter.lastWindow?.focusCount, 1)
        XCTAssertTrue(manager.isDetached)
    }

    func testCloseDetachedWindowTearsItDownAndReportsAttached() {
        let presenter = FakePresenter()
        let manager = WebPreviewWindowManager(presenter: presenter)
        manager.show(viewModel: WebPreviewViewModel())

        manager.closeDetachedWindow()

        XCTAssertFalse(manager.isDetached)
        XCTAssertEqual(presenter.lastWindow?.closeCount, 1)
    }

    func testTheWindowClosingItselfReportsAttached() {
        let presenter = FakePresenter()
        let manager = WebPreviewWindowManager(presenter: presenter)
        manager.show(viewModel: WebPreviewViewModel())

        presenter.lastWindow?.simulateHumanClose()

        XCTAssertFalse(manager.isDetached)
        // The human already closed it; the manager must not close it again.
        XCTAssertEqual(presenter.lastWindow?.closeCount, 0)
    }

    func testClosingWhenNothingIsDetachedIsANoOp() {
        let presenter = FakePresenter()
        let manager = WebPreviewWindowManager(presenter: presenter)

        manager.closeDetachedWindow()

        XCTAssertFalse(manager.isDetached)
        XCTAssertEqual(presenter.presentCount, 0)
    }

    func testCloseAfterTheHumanClosedItDoesNotTearDownTwice() {
        let presenter = FakePresenter()
        let manager = WebPreviewWindowManager(presenter: presenter)
        manager.show(viewModel: WebPreviewViewModel())
        presenter.lastWindow?.simulateHumanClose()

        manager.closeDetachedWindow()

        XCTAssertFalse(manager.isDetached)
        XCTAssertEqual(presenter.lastWindow?.closeCount, 0)
    }

    func testShowAfterCloseDetachesAgain() {
        let presenter = FakePresenter()
        let manager = WebPreviewWindowManager(presenter: presenter)
        let viewModel = WebPreviewViewModel()
        manager.show(viewModel: viewModel)
        manager.closeDetachedWindow()

        manager.show(viewModel: viewModel)

        XCTAssertTrue(manager.isDetached)
        XCTAssertEqual(presenter.presentCount, 2)
    }
}
