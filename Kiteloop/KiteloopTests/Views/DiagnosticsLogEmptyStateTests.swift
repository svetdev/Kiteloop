import XCTest
@testable import Kiteloop

/// What the Diagnostics Logs tab draws when it shows no lines. It used to be a
/// blank pane, whether the filters hid every line or there were none to hide.
final class DiagnosticsLogEmptyStateTests: XCTestCase {

    func testAListShowingLinesHasNoEmptyState() {
        XCTAssertNil(DiagnosticsView.logEmptyState(totalCount: 12, shownCount: 3))
    }

    func testLinesHiddenByTheFiltersNameTheControlsThatBringThemBack() throws {
        let copy = try XCTUnwrap(DiagnosticsView.logEmptyState(totalCount: 12, shownCount: 0))
        XCTAssertTrue(copy.title.contains("filters"))
        XCTAssertTrue(copy.message.contains("All in the category menu"))
        XCTAssertTrue(copy.message.contains("Info and Errors"))
        XCTAssertTrue(copy.message.contains("Search"))
    }

    func testAnEmptyLogSaysSoAndDoesNotBlameTheFilters() throws {
        let copy = try XCTUnwrap(DiagnosticsView.logEmptyState(totalCount: 0, shownCount: 0))
        XCTAssertTrue(copy.title.contains("empty"))
        XCTAssertFalse(copy.title.contains("filter"))
        XCTAssertFalse(copy.message.contains("filter"))
        XCTAssertFalse(copy.message.contains("Search"))
        XCTAssertNil(copy.control)
    }

    func testAFooterBelowTheCapacityReadsAsItAlwaysHas() {
        XCTAssertEqual(
            DiagnosticsView.logFooterCaption(totalCount: 120, shownCount: 40, capacity: 2000),
            "40 of 120 shown"
        )
    }

    func testAFooterAtTheCapacitySaysOlderLinesAreOnlyInTheLogFile() {
        let caption = DiagnosticsView.logFooterCaption(totalCount: 2000, shownCount: 2000, capacity: 2000)
        XCTAssertTrue(caption.hasPrefix("2000 of 2000 shown"))
        XCTAssertTrue(caption.contains("latest 2,000 lines only"))
        XCTAssertTrue(caption.contains("older lines are in the log file"))
    }

    func testTheCapacityClauseFollowsTheTotalNotTheFilteredCount() {
        let caption = DiagnosticsView.logFooterCaption(totalCount: 2000, shownCount: 3, capacity: 2000)
        XCTAssertTrue(caption.hasPrefix("3 of 2000 shown"))
        XCTAssertTrue(caption.contains("older lines are in the log file"))
    }
}
