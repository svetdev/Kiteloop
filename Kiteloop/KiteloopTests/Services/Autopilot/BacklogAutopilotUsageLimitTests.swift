import XCTest
import KiteloopCore
@testable import Kiteloop

/// A run that ends while the account's usage limit stands is parked, not
/// failed: the item goes back to `ready`, the retry ceiling does not count it,
/// its work is kept, and the scheduler is told when the limit lifts.
@MainActor
final class BacklogAutopilotUsageLimitTests: XCTestCase {
    private var tempDir: URL!
    private var orchestrator: Orchestrator!
    private var backlog: BacklogViewModel!
    private var autopilot: BacklogAutopilot!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "usage-limit-park")
        try "---\nproject: demo\n---\n\n# Demo Backlog\n\n## Epic: Now\n\n- [ ] item-1 | Ship the thing | active\n".write(
            to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        backlog = BacklogViewModel(globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")))
        backlog.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        orchestrator = Orchestrator(runtime: MockAgentRuntime())
        autopilot = BacklogAutopilot()
        autopilot.configure(orchestrator: orchestrator, backlogViewModel: backlog,
                            projectPath: tempDir.path(percentEncoded: false))
    }

    private func refusal(resetsIn seconds: TimeInterval) -> AgentActivityEvent.RateLimitInfo {
        .init(status: "rejected", window: "five_hour", resetsAt: Date().addingTimeInterval(seconds), utilization: 1)
    }

    func testARunEndingUnderTheLimitIsParkedBackToReadyAndTheSchedulerIsTold() throws {
        orchestrator.noteRateLimit(refusal(resetsIn: 3_600))
        var told: UsageLimitStop?
        autopilot.onUsageLimitParked = { told = $0 }
        let item = try XCTUnwrap(backlog.item(withID: "item-1"))

        let parked = try XCTUnwrap(autopilot.parkIfUsageLimitedForTesting(item, backlog: backlog))

        guard case .usageLimitParked(let until) = parked.outcome else {
            return XCTFail("expected a park, got \(parked.outcome)")
        }
        XCTAssertEqual(until, told?.resetsAt)
        XCTAssertEqual(backlog.item(withID: "item-1")?.status, .ready)
        XCTAssertTrue(autopilot.log.contains { $0.message.contains("Usage limit") })
    }

    func testWithNoLimitStandingARunThatEndedBadlyIsAnOrdinaryFailure() throws {
        let item = try XCTUnwrap(backlog.item(withID: "item-1"))
        XCTAssertNil(autopilot.parkIfUsageLimitedForTesting(item, backlog: backlog))

        orchestrator.noteRateLimit(refusal(resetsIn: 3_600))
        orchestrator.noteRateLimit(.init(status: "allowed", window: "five_hour", resetsAt: nil, utilization: 0.1))
        XCTAssertNil(autopilot.parkIfUsageLimitedForTesting(item, backlog: backlog),
                     "a reading that lets calls through again lifts the limit")
    }

    /// Not an attempt at the item, so the retry ceiling skips it; not a verdict
    /// on the work, so its worktree is committed and kept like a cancel's.
    func testAParkIsNeitherEvidenceAgainstTheItemNorWorkThrownAway() {
        let outcome = BacklogAutopilot.ItemResult.Outcome.usageLimitParked(until: Date())
        XCTAssertEqual(BacklogAutopilot.outcomeString(outcome), TaskMetricRecord.usageLimitParkedOutcome)
        XCTAssertEqual(WorktreeSession.teardownAction(for: outcome), .commit)
        XCTAssertFalse(AutopilotHistorySummary.isPass(outcome))
    }
}
