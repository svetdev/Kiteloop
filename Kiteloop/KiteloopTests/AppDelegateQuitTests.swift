import AppKit
import XCTest
@testable import Kiteloop

/// `AppDelegate.terminateReply` in isolation, over the AppKit terminate
/// handshake it never touches.
///
/// The bug this guards: a drained "quit when quiet" fired a *second*,
/// re-entrant `applicationShouldTerminate` from inside `NSApp.terminate(nil)`,
/// nested on the same call stack. That pass used to answer `.terminateLater`
/// and wait on an `NSApp.reply` that a blocked stack frame can never deliver —
/// this table is what the app reads instead, once the drained quit has
/// already finalized before calling terminate.
@MainActor
final class AppDelegateQuitTests: XCTestCase {

    /// The re-entrant pass: fleet drained, approved and already finalized.
    /// Nothing left to wait on, so the reply must be synchronous.
    func testDrainedAndFinalizedTerminatesNow() {
        XCTAssertEqual(
            AppDelegate.terminateReply(hasFleet: true, quitApproved: true, quitFinalized: true, hasFinalizer: true),
            .terminateNow
        )
        XCTAssertEqual(
            AppDelegate.terminateReply(hasFleet: true, quitApproved: true, quitFinalized: true, hasFinalizer: false),
            .terminateNow
        )
    }

    /// A fleet wired and no approval yet is the prompt path — asked about
    /// asynchronously, never short-circuited.
    func testAFleetWithNoApprovalDefersToThePrompt() {
        XCTAssertEqual(
            AppDelegate.terminateReply(hasFleet: true, quitApproved: false, quitFinalized: false, hasFinalizer: true),
            .terminateLater
        )
    }

    /// No fleet wired and no record to close: there is nothing to defer for.
    func testNoFleetAndNoFinalizerTerminatesNow() {
        XCTAssertEqual(
            AppDelegate.terminateReply(hasFleet: false, quitApproved: false, quitFinalized: false, hasFinalizer: false),
            .terminateNow
        )
    }

    /// No fleet wired but a record to close still gets its async pass.
    func testNoFleetWithAFinalizerDefers() {
        XCTAssertEqual(
            AppDelegate.terminateReply(hasFleet: false, quitApproved: false, quitFinalized: false, hasFinalizer: true),
            .terminateLater
        )
    }

    /// `AppDelegate.presentation(hasWindow:)` in isolation, over the alert it
    /// never touches.
    ///
    /// The bug this guards: the quit prompt used to always be `NSAlert.runModal()`,
    /// which parks the main thread in a nested modal run loop — and
    /// `KiteloopControlServer` is `@MainActor`, so every control API request
    /// hung for as long as the prompt was on screen. A window to sheet on picks
    /// the non-blocking path instead; only the absence of one falls back to the
    /// blocking modal.
    func testPresentationSheetsWhenAWindowExists() {
        XCTAssertEqual(AppDelegate.presentation(hasWindow: true), .sheet)
    }

    func testPresentationFallsBackToModalWithNoWindow() {
        XCTAssertEqual(AppDelegate.presentation(hasWindow: false), .modalSession)
    }
}
