import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers the two decisions the run's poll loop used to make inline:
/// `BacklogAutopilot.nodeEntry(forNode:attempt:)` — what entering a node is
/// announced as — and `BacklogAutopilot.runOutcome(for:)` — how a finished
/// execution ends the loop.
///
/// `awaitWorkflowCompletion` polls a live `WorkflowEngine` on a two-second
/// sleep, so no unit test reaches it; both judgements are pure functions off it
/// for the same reason `itemStatus(forNode:useReviewStage:)` is.
final class BacklogAutopilotNodeAnnouncementTests: XCTestCase {

    // MARK: - What a node's start is announced as

    func testTheFirstWorkerPassReadsAsAStart() {
        let entry = BacklogAutopilot.nodeEntry(forNode: "worker", attempt: 1)
        XCTAssertEqual(entry?.phase, .worker)
        XCTAssertEqual(entry?.message, "→ Worker started")
        XCTAssertEqual(entry?.isReview, false)
    }

    /// A second visit to the worker is a retry, and the log counts the retries,
    /// not the visits — the third visit is retry 2.
    func testALaterWorkerPassCountsTheRetriesNotTheVisits() {
        XCTAssertEqual(BacklogAutopilot.nodeEntry(forNode: "worker", attempt: 2)?.message,
                       "→ Worker (retry 1)")
        XCTAssertEqual(BacklogAutopilot.nodeEntry(forNode: "worker", attempt: 3)?.message,
                       "→ Worker (retry 2)")
    }

    func testTheReviewerCarriesTheAttemptAndReadsAsReview() {
        let entry = BacklogAutopilot.nodeEntry(forNode: "reviewer", attempt: 2)
        XCTAssertEqual(entry?.phase, .reviewer)
        XCTAssertEqual(entry?.message, "→ Reviewer (attempt 2)")
        XCTAssertEqual(entry?.isReview, true)
    }

    /// The follow-up ask is the same attempt, still waiting on the same verdict,
    /// so the panel keeps reading it as reviewing — but it gets its own phase,
    /// because "the reviewer had to be asked twice" is the signal that says
    /// whether the follow-up is carrying the run.
    func testTheClarifyAskIsItsOwnPhaseAndStillReview() {
        let entry = BacklogAutopilot.nodeEntry(forNode: BacklogAutopilot.reviewerClarifyNodeID,
                                               attempt: 1)
        XCTAssertEqual(entry?.phase, .reviewerClarify)
        XCTAssertEqual(entry?.isReview, true)
    }

    /// Every other node opens its span and says nothing — the run log stays quiet
    /// and the panel's status is left exactly where the last announced node put it.
    func testAnyOtherNodeIsAnnouncedAsNothing() {
        for node in ["done", "blocked", "gate", ""] {
            XCTAssertNil(BacklogAutopilot.nodeEntry(forNode: node, attempt: 1), node)
        }
    }

    // MARK: - How a finished execution ends the loop

    func testACompletedExecutionEndsTheLoopWithASuccessfulSpan() {
        let ending = BacklogAutopilot.runOutcome(for: .completed)
        XCTAssertEqual(ending?.status, .completed)
        XCTAssertEqual(Self.describe(ending?.span), "success")
    }

    /// Each way an execution can end hands its own status back, and closes the
    /// open span with a reason a reader of the run's spans can tell apart.
    func testEachTerminalStatusIsHandedBackWithItsOwnSpanReason() {
        let expected: [(ExecutionStatus, String)] = [
            (.failed, "failed: failed"),
            (.cancelled, "failed: cancelled"),
            (.timedOut, "failed: timed out"),
        ]
        for (status, span) in expected {
            let ending = BacklogAutopilot.runOutcome(for: status)
            XCTAssertEqual(ending?.status, status, status.rawValue)
            XCTAssertEqual(Self.describe(ending?.span), span, status.rawValue)
        }
    }

    /// A live execution is not an ending: the loop is told to poll again rather
    /// than to close the span it has open.
    func testALiveExecutionIsNoEndingAtAll() {
        for status: ExecutionStatus in [.running, .pending, .paused, .awaitingApproval] {
            XCTAssertNil(BacklogAutopilot.runOutcome(for: status), status.rawValue)
        }
    }

    /// The ending table and the model's own `isTerminal` have to agree about
    /// every status there is. This is what the exhaustive switch used to buy:
    /// a status added to `ExecutionStatus` and given no reason here would end
    /// nothing, and the poll loop would spin on a run that had already settled.
    func testTheEndingTableCoversExactlyTheTerminalStatuses() {
        for status in ExecutionStatus.allCases {
            XCTAssertEqual(
                BacklogAutopilot.runOutcome(for: status) != nil, status.isTerminal,
                status.rawValue
            )
        }
    }

    /// `SpanOutcome` is not `Equatable`, and giving it a conformance only tests
    /// use would be the test writing the code — so read it as a string here.
    private static func describe(_ outcome: BacklogAutopilot.ExecutionSpan.SpanOutcome?) -> String {
        switch outcome {
        case .success: return "success"
        case .running: return "running"
        case .failed(let reason): return "failed: \(reason)"
        case nil: return "none"
        }
    }
}
