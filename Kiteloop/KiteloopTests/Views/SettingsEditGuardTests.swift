import XCTest
@testable import Kiteloop

/// Whether leaving a settings page is allowed to throw away what was typed on
/// it.
///
/// The settings sheet draws one page at a time and destroys the view — and all
/// its `@State` — when another sidebar row is picked, so a half-written hook or
/// server row was simply gone, with nothing said, and Done lost it the same
/// way. `SettingsEditGuard` is where the two pages with their own Save button
/// report unsaved work, and its `decision(for:)` is what the sheet asks before
/// it moves.
@MainActor
final class SettingsEditGuardTests: XCTestCase {

    /// The two pages that have their own Save button, and so can hold
    /// unsaved work.
    private let savingPages: [ProjectSettingsPage] = [.hooks, .mcpServers]

    // MARK: - The decision

    func testLeavingACleanPageIsNeverConfirmed() {
        let guardian = SettingsEditGuard()

        for page in savingPages {
            guardian.report(isDirty: false, for: page)

            XCTAssertEqual(guardian.decision(for: .done), .proceed, "\(page.title) → Done")
            XCTAssertEqual(guardian.decision(for: .page(.general)), .proceed, "\(page.title) → General")
        }
    }

    func testLeavingADirtyPageIsConfirmed() {
        for page in savingPages {
            let guardian = SettingsEditGuard()
            guardian.report(isDirty: true, for: page)

            XCTAssertEqual(guardian.decision(for: .done), .confirm(page), "\(page.title) → Done")
            XCTAssertEqual(guardian.decision(for: .page(.general)), .confirm(page), "\(page.title) → General")
        }
    }

    /// Picking the row that is already selected is not leaving anywhere.
    func testStayingOnTheDirtyPageIsNotConfirmed() {
        for page in savingPages {
            let guardian = SettingsEditGuard()
            guardian.report(isDirty: true, for: page)

            XCTAssertEqual(guardian.decision(for: .page(page)), .proceed, page.title)
        }
    }

    // MARK: - Clearing it

    /// What a page's own Save does: from there the next page switch or Done
    /// asks nothing.
    func testSavingAPageClearsItsUnsavedWork() {
        for page in savingPages {
            let guardian = SettingsEditGuard()
            guardian.report(isDirty: true, for: page)
            guardian.report(isDirty: false, for: page)

            XCTAssertNil(guardian.dirtyPage, page.title)
            XCTAssertEqual(guardian.decision(for: .done), .proceed, page.title)
        }
    }

    /// A page that has nothing unsaved does not clear another page's edits —
    /// a freshly opened page reports itself clean as it loads, and that must
    /// not be the moment the pending work is forgotten.
    func testACleanPageDoesNotClearAnotherPagesUnsavedWork() {
        let guardian = SettingsEditGuard()
        guardian.report(isDirty: true, for: .hooks)

        guardian.report(isDirty: false, for: .mcpServers)

        XCTAssertEqual(guardian.dirtyPage, .hooks)
    }

    /// What Discard does.
    func testClearingLetsTheNavigationThrough() {
        let guardian = SettingsEditGuard()
        guardian.report(isDirty: true, for: .hooks)

        guardian.clear()

        XCTAssertNil(guardian.dirtyPage)
        XCTAssertEqual(guardian.decision(for: .page(.git)), .proceed)
    }
}
