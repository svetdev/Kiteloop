import XCTest
@testable import Kiteloop

/// The backlog header's search narrows the rows to the items whose title or id
/// contains the query, ignoring case; a blank query hides nothing.
final class EpicBacklogSearchTests: XCTestCase {

    func testBlankQueryMatchesEverything() {
        XCTAssertTrue(EpicBacklogView.matchesQuery(title: "Retry the push", id: "retry-the-push", query: ""))
    }

    func testWhitespaceQueryMatchesEverything() {
        XCTAssertTrue(EpicBacklogView.matchesQuery(title: "Retry the push", id: "retry-the-push", query: "  \t "))
    }

    func testTitleMatchIgnoresCase() {
        XCTAssertTrue(EpicBacklogView.matchesQuery(title: "Retry the Push", id: "a1", query: "THE pUSH"))
    }

    func testQueryIsTrimmedBeforeMatching() {
        XCTAssertTrue(EpicBacklogView.matchesQuery(title: "Retry the push", id: "a1", query: "  push "))
    }

    func testIDIsSearchedWhenTheTitleDoesNotContainTheQuery() {
        XCTAssertTrue(EpicBacklogView.matchesQuery(title: "Backlog search", id: "the-backlog-cannot-be-searched", query: "Cannot-Be"))
    }

    func testQueryInNeitherTitleNorIDDoesNotMatch() {
        XCTAssertFalse(EpicBacklogView.matchesQuery(title: "Retry the push", id: "retry-the-push", query: "merge"))
    }

    func testDoneItemMatchingASearchIsShownEvenWhenCompletedAreHidden() {
        XCTAssertTrue(EpicBacklogView.isShown(status: .done, title: "Retry the push", id: "retry-the-push",
                                              hidesCompleted: true, query: "retry-the-push"))
    }

    func testDoneItemIsHiddenUnderABlankQueryWhenCompletedAreHidden() {
        XCTAssertFalse(EpicBacklogView.isShown(status: .done, title: "Retry the push", id: "retry-the-push",
                                               hidesCompleted: true, query: "  "))
    }

    func testDoneItemIsShownUnderABlankQueryWhenCompletedAreNotHidden() {
        XCTAssertTrue(EpicBacklogView.isShown(status: .done, title: "Retry the push", id: "retry-the-push",
                                              hidesCompleted: false, query: ""))
    }

    func testDoneItemThatDoesNotMatchIsHiddenEitherWay() {
        for hidesCompleted in [true, false] {
            XCTAssertFalse(EpicBacklogView.isShown(status: .done, title: "Retry the push", id: "retry-the-push",
                                                   hidesCompleted: hidesCompleted, query: "merge"))
        }
    }

    func testOpenItemIsShownUnderABlankQueryWhenCompletedAreHidden() {
        XCTAssertTrue(EpicBacklogView.isShown(status: .ready, title: "Retry the push", id: "retry-the-push",
                                              hidesCompleted: true, query: ""))
    }
}
