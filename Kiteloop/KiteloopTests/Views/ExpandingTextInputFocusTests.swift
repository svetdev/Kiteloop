import AppKit
import SwiftUI
import XCTest
@testable import Kiteloop

/// The chat input takes the cursor back when the bar above it asks — closing
/// the Ctrl+R history search bumps `focusRequest` — and only then. SwiftUI
/// calls `updateNSView` on every change of every input the view has, so a
/// request answered on each of those would pull the cursor back from wherever
/// the person had put it since.
@MainActor
final class ExpandingTextInputFocusTests: XCTestCase {

    private var window: NSWindow!
    private var input: InputTextView!
    private var elsewhere: NSTextView!
    private var coordinator: ExpandingTextInput.Coordinator!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        input = InputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        elsewhere = NSTextView(frame: NSRect(x: 0, y: 60, width: 300, height: 40))
        window.contentView?.addSubview(input)
        window.contentView?.addSubview(elsewhere)

        let view = ExpandingTextInput(text: .constant(""), textHeight: .constant(20), onSubmit: {})
        coordinator = view.makeCoordinator()
        coordinator.textView = input
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    func testABumpedRequestHandsTheCursorBackToTheInput() async throws {
        window.makeFirstResponder(elsewhere)

        XCTAssertTrue(coordinator.answer(focusRequest: 1))

        try await eventually("the input to take the cursor") { self.window.firstResponder === self.input }
    }

    func testAnUpdateWithNoNewRequestLeavesTheCursorWhereThePersonPutIt() async throws {
        coordinator.answer(focusRequest: 1)
        try await eventually("the input to take the cursor") { self.window.firstResponder === self.input }
        window.makeFirstResponder(elsewhere)

        XCTAssertFalse(coordinator.answer(focusRequest: 1), "the same request is already answered")
        await drainMainQueue()

        XCTAssertTrue(window.firstResponder === elsewhere)
    }

    /// The input starts at request 0 and makes itself first responder when it
    /// is built, so the initial value asks for nothing more.
    func testTheInitialRequestAsksForNothing() {
        XCTAssertFalse(coordinator.answer(focusRequest: 0))
    }

    /// Everything enqueued on the main queue before this call has run once it
    /// returns — the focus hand-back included, had one been asked for.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
