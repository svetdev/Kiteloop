import XCTest
@testable import KiteloopCore

final class NotificationItemTests: XCTestCase {

    // MARK: - What reaches the badged inbox

    /// An approval, a question and an error each leave an agent blocked until a
    /// human does something; they are what the badge counts.
    func testTheTypesAHumanMustActOnAreActionable() {
        XCTAssertTrue(NotificationItem.NotificationType.approval.isActionable)
        XCTAssertTrue(NotificationItem.NotificationType.question.isActionable)
        XCTAssertTrue(NotificationItem.NotificationType.error.isActionable)
    }

    /// A completion and a plain event are ambient activity: worth watching,
    /// but nothing is waiting on the human, and they must not compete with a
    /// blocked agent for the badge.
    func testAmbientActivityIsNotActionable() {
        XCTAssertFalse(NotificationItem.NotificationType.complete.isActionable)
        XCTAssertFalse(NotificationItem.NotificationType.event.isActionable)
    }

    /// The item answers for its type, so a row can be sorted without looking
    /// inside it.
    func testAnItemIsActionableExactlyWhenItsTypeIs() {
        let blocked = NotificationItem(agentID: "a", type: .approval, title: "t", body: "b")
        let done = NotificationItem(agentID: "a", type: .complete, title: "t", body: "b")

        XCTAssertTrue(blocked.isActionable)
        XCTAssertFalse(done.isActionable)
    }

    // MARK: - How a gate closed

    /// The reasons are read by a person in the feed, so each one has to say
    /// which surface closed the gate: "done" and "somebody approved this over
    /// the API while you were asleep" are different mornings.
    func testEachClosureSaysWhichSurfaceClosedTheGate() {
        XCTAssertEqual(GateClosure.approved.reason, "approved")
        XCTAssertEqual(GateClosure.approvedViaAPI.reason, "approved via API")
        XCTAssertEqual(GateClosure.autoApproved.reason, "auto-approved")
        XCTAssertEqual(GateClosure.rejected.reason, "rejected")
        XCTAssertEqual(GateClosure.noLongerAtTheGate.reason,
                       "the item is no longer at the approval gate")
        XCTAssertEqual(GateClosure.superseded.reason, "replaced by a newer notice")
    }

    /// A blank reason would leave a resolved row saying nothing at all, which is
    /// indistinguishable from one a person cleared by hand.
    func testNoClosureHasABlankReason() {
        for closure in GateClosure.allCases {
            XCTAssertFalse(closure.reason.isEmpty, "\(closure) has nothing to say")
        }
    }

    // MARK: - Roll-up keys

    /// One live "finished" row per project: two projects must not share a key,
    /// or one project's run finishing would clear the other's row.
    func testRunFinishedKeysAreDistinctPerProject() {
        XCTAssertNotEqual(NotificationItem.runFinishedRollUpKey(projectID: "a"),
                          NotificationItem.runFinishedRollUpKey(projectID: "b"))
        XCTAssertEqual(NotificationItem.runFinishedRollUpKey(projectID: "a"),
                       NotificationItem.runFinishedRollUpKey(projectID: "a"))
    }

    /// A notice is an event unless it says otherwise: the default carries no key
    /// and no resolution, which is every notice raised before this existed.
    func testANoticeIsAnEventUnlessItSaysOtherwise() {
        let item = NotificationItem(agentID: "a", type: .complete, title: "t", body: "b")
        XCTAssertNil(item.rollUpKey)
        XCTAssertNil(item.resolution)
    }
}
