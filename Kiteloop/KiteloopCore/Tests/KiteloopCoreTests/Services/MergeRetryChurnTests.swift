import XCTest
@testable import KiteloopCore

/// `MergeRetryChurn` is the piece shared by `TaskMetricStore.escapedDefectRate`
/// and `EscapedDefectReader`: a reopen the gate-retry loop re-approves within
/// its own retry window is one attempt, not a new approval and not an escape.
final class MergeRetryChurnTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func moment(_ isReopen: Bool, at offset: TimeInterval, key: String = "item-1") ->
        MergeRetryChurn.Moment<String> {
        MergeRetryChurn.Moment(key: key, isReopen: isReopen, at: t0 + offset, payload: isReopen ? "reopened" : "approved")
    }

    /// The shape the real incident took: a reopen re-approved seconds later —
    /// both drop, and the approval that stood before the bounce is untouched.
    func testReopenImmediatelyReapprovedDropsBoth() {
        let moments = [moment(false, at: 0), moment(true, at: 27), moment(false, at: 29)]
        let genuine = MergeRetryChurn.genuine(moments)
        XCTAssertEqual(genuine.map(\.payload), ["approved"])
    }

    /// The window is generous next to the observed cascade but still tiny next
    /// to the escaped-defect window — a reopen the loop takes an hour to
    /// re-approve is not its own retry finishing.
    func testReopenReapprovedPastTheWindowIsNotChurn() {
        let moments = [moment(false, at: 0), moment(true, at: 60), moment(false, at: 60 + MergeRetryChurn.window + 1)]
        let genuine = MergeRetryChurn.genuine(moments)
        XCTAssertEqual(genuine.map(\.payload), ["approved", "reopened", "approved"])
    }

    /// A reopen nothing re-approves — a person's own reopen, or one still
    /// standing — passes through untouched.
    func testReopenWithNoFollowingApprovalIsKept() {
        let moments = [moment(false, at: 0), moment(true, at: 60)]
        XCTAssertEqual(MergeRetryChurn.genuine(moments).map(\.payload), ["approved", "reopened"])
    }

    /// Two reopens in a row (no approval between them) are each their own
    /// event — nothing here to collapse.
    func testConsecutiveReopensAreBothKept() {
        let moments = [moment(true, at: 0), moment(true, at: 60)]
        XCTAssertEqual(MergeRetryChurn.genuine(moments).map(\.payload), ["reopened", "reopened"])
    }

    /// The full 2026-09-05 cascade for one item: four reopen/reapprove pairs,
    /// each inside the window — only the first approval survives.
    func testTheFullCascadeCollapsesToOneApproval() {
        let offsets: [(Bool, TimeInterval)] = [
            (false, 0), (true, 27), (false, 29), (true, 274), (false, 276),
            (true, 498), (false, 499), (true, 726), (false, 727),
        ]
        let moments = offsets.map { moment($0.0, at: $0.1) }
        XCTAssertEqual(MergeRetryChurn.genuine(moments).map(\.payload), ["approved"])
    }

    /// Keys are never blended: two items bouncing at the same moments are each
    /// judged on their own timeline.
    func testDifferentKeysAreNeverCollapsedTogether() {
        let moments = [
            moment(false, at: 0, key: "a"), moment(true, at: 60, key: "b"),
        ]
        XCTAssertEqual(Set(MergeRetryChurn.genuine(moments).map(\.payload)), ["approved", "reopened"])
    }
}
