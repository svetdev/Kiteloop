import XCTest
import KiteloopCore
@testable import Kiteloop

/// What number the toolbar bell shows, given the map of pending notices the
/// window's refresh tick keeps.
///
/// The point of deriving it here is cadence: the badge used to be re-read only
/// when the active project changed or the popover opened, so an approval gate
/// reached mid tool call notified nobody until the one moment the human no
/// longer needed telling.
final class NotificationBadgeCountTests: XCTestCase {

    private func notice(_ type: NotificationItem.NotificationType) -> NotificationItem {
        NotificationItem(agentID: "agent", type: type, title: "t", body: "b")
    }

    // MARK: - What counts

    /// Only what needs a human. A completion and an event are still recorded
    /// and still listed — they just don't ring the bell.
    func testOnlyActionableNoticesAreCounted() {
        let pending = ["proj": [notice(.approval), notice(.question), notice(.error),
                                notice(.complete), notice(.event)]]
        XCTAssertEqual(
            NotificationBadgeCount.forActiveProject(pending: pending, activeProjectID: "proj"),
            3
        )
    }

    /// Ambient activity alone leaves the bell unbadged rather than showing a
    /// number nothing can clear.
    func testAmbientNoticesAloneCountZero() {
        let pending = ["proj": [notice(.complete), notice(.event)]]
        XCTAssertEqual(
            NotificationBadgeCount.forActiveProject(pending: pending, activeProjectID: "proj"),
            0
        )
    }

    // MARK: - Whose notices they are

    /// The badge is a view over the active project's inbox, and the map carries
    /// every open project's. A background project's approval gate belongs on
    /// its own tab, not on this number.
    func testAnotherOpenProjectsNoticesDoNotReachTheBadge() {
        let pending = ["active": [notice(.approval)],
                       "background": [notice(.approval), notice(.question)]]
        XCTAssertEqual(
            NotificationBadgeCount.forActiveProject(pending: pending, activeProjectID: "active"),
            1
        )
    }

    /// A project whose inbox hasn't been read into the map yet — it has no
    /// entry at all — counts nothing, the same as an empty one.
    func testProjectWithNoEntryCountsZero() {
        let pending = ["other": [notice(.approval)]]
        XCTAssertEqual(
            NotificationBadgeCount.forActiveProject(pending: pending, activeProjectID: "active"),
            0
        )
        XCTAssertEqual(
            NotificationBadgeCount.forActiveProject(pending: ["active": []], activeProjectID: "active"),
            0
        )
    }

    /// No project open at all: no bell to badge.
    func testNoActiveProjectCountsZero() {
        let pending = ["proj": [notice(.approval)]]
        XCTAssertEqual(
            NotificationBadgeCount.forActiveProject(pending: pending, activeProjectID: nil),
            0
        )
    }

    // MARK: - Cadence

    /// The regression: a notice arrives while the human is looking at the
    /// window and nothing else changes — no streaming flip, no project switch,
    /// no click on the bell. Re-running the count over the map the tick just
    /// assigned is what moves the number.
    func testANoticeArrivingOnTheTickMovesTheNumber() {
        var pending: [String: [NotificationItem]] = ["proj": []]
        XCTAssertEqual(
            NotificationBadgeCount.forActiveProject(pending: pending, activeProjectID: "proj"),
            0
        )
        pending["proj"] = [notice(.approval)]
        XCTAssertEqual(
            NotificationBadgeCount.forActiveProject(pending: pending, activeProjectID: "proj"),
            1
        )
    }

    /// And the same map read for a different active project gives that
    /// project's answer — switching tabs can't disagree with the tick, because
    /// both go through here.
    func testSwitchingProjectsReadsTheSameMap() {
        let pending = ["a": [notice(.approval), notice(.error)],
                       "b": [notice(.question)]]
        XCTAssertEqual(
            NotificationBadgeCount.forActiveProject(pending: pending, activeProjectID: "a"),
            2
        )
        XCTAssertEqual(
            NotificationBadgeCount.forActiveProject(pending: pending, activeProjectID: "b"),
            1
        )
    }
}
