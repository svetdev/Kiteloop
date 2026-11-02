import XCTest
@testable import Kiteloop

/// The Delete Epic confirmation says what the menu it was chosen from doesn't:
/// which epic goes, and how many of its items go with it.
final class EpicBacklogDeleteConfirmationTests: XCTestCase {

    func testMessageForAnEmptyEpicSaysItHoldsNoItems() {
        let message = EpicBacklogView.deleteEpicMessage(name: "Onboarding", itemCount: 0)
        XCTAssertTrue(message.contains("Onboarding"))
        XCTAssertTrue(message.contains("holds no items"))
        XCTAssertFalse(message.contains("0 items"))
    }

    func testMessageForOneItemReadsSingular() {
        let message = EpicBacklogView.deleteEpicMessage(name: "Onboarding", itemCount: 1)
        XCTAssertTrue(message.contains("Onboarding"))
        XCTAssertTrue(message.contains("the 1 item in it"))
    }

    func testMessageForSeveralItemsNamesTheCount() {
        let message = EpicBacklogView.deleteEpicMessage(name: "Control API", itemCount: 7)
        XCTAssertTrue(message.contains("Control API"))
        XCTAssertTrue(message.contains("all 7 items in it"))
    }

    func testRemoveItemMessageNamesTheItemByTitleAndID() {
        let message = EpicBacklogView.removeItemMessage(title: "Retry the push", id: "retry-the-push")
        XCTAssertTrue(message.contains("Retry the push"))
        XCTAssertTrue(message.contains("retry-the-push"))
    }

    func testRemoveItemMessageSaysItCannotBeUndone() {
        let message = EpicBacklogView.removeItemMessage(title: "Retry the push", id: "retry-the-push")
        XCTAssertTrue(message.contains("can't be undone"))
    }
}
