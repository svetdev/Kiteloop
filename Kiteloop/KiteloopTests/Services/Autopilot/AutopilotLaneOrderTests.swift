import XCTest
import KiteloopCore
@testable import Kiteloop

/// The run order: lane first, the order the file is written in second.
///
/// The epic used to be the only way to say "run this next", which spent the one
/// field that records *where* an item belongs on *when* it runs. The queue the
/// pickup pass builds is what has to honour the lane instead — and it has to
/// honour it before the gates run, so what they log and refuse is in the order
/// the run will walk.
@MainActor
final class AutopilotLaneOrderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "autopilot-lane-order")
    }

    /// A `now` item in the last epic is picked up ahead of the `later` items in
    /// the first — the whole point of the lane: the item never left its epic to
    /// get there.
    func testANowItemInTheLastEpicIsQueuedAheadOfEveryLaterOne() async throws {
        try writeBacklog("""
        ## Epic: Platform

        - [ ] first-later | A | ready → [detail](backlog/first-later.md)
        - [ ] second-later | B | ready → [detail](backlog/second-later.md)

        ## Epic: Onboarding

        - [ ] last-now | C | lane:now | ready → [detail](backlog/last-now.md)
        """)

        let autopilot = try await stagePickup(selecting: ["first-later", "second-later", "last-now"])

        XCTAssertEqual(autopilot.runQueue.map(\.id), ["last-now", "first-later", "second-later"])
    }

    /// Within a lane nothing is reordered: two promoted items in two different
    /// epics run in the order the file writes them.
    func testTwoNowItemsInDifferentEpicsKeepDocumentOrder() async throws {
        try writeBacklog("""
        ## Epic: Platform

        - [ ] first-now | A | lane:now | ready → [detail](backlog/first-now.md)
        - [ ] middle-later | B | ready → [detail](backlog/middle-later.md)

        ## Epic: Onboarding

        - [ ] last-now | C | lane:now | ready → [detail](backlog/last-now.md)
        """)

        let autopilot = try await stagePickup(selecting: ["first-now", "middle-later", "last-now"])

        XCTAssertEqual(autopilot.runQueue.map(\.id), ["first-now", "last-now", "middle-later"])
    }

    /// A backlog nobody has promoted anything in queues exactly as it did
    /// before lanes existed.
    func testABacklogWithNoLanesQueuesInDocumentOrder() async throws {
        try writeBacklog("""
        ## Epic: Platform

        - [ ] first-later | A | ready → [detail](backlog/first-later.md)

        ## Epic: Onboarding

        - [ ] last-later | C | ready → [detail](backlog/last-later.md)
        """)

        let autopilot = try await stagePickup(selecting: ["first-later", "last-later"])

        XCTAssertEqual(autopilot.runQueue.map(\.id), ["first-later", "last-later"])
    }

    // MARK: - Fixtures

    /// Drives the pickup pass over the written backlog and hands back the
    /// autopilot holding the queue it built.
    private func stagePickup(selecting ids: [String]) async throws -> BacklogAutopilot {
        for id in ids { try writeDetail(id: id) }
        let vm = BacklogViewModel(globalConfigStore:
            GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json")))
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())  // retained: the autopilot holds it weakly
        let autopilot = BacklogAutopilot()
        autopilot.configure(orchestrator: orchestrator, backlogViewModel: vm,
                            metricStore: TaskMetricStore(
                                metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
                                estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
                                approvalsURL: tempDir.appending(path: "task-approvals.jsonl")),
                            projectPath: tempDir.path(percentEncoded: false), projectName: "demo")
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        autopilot.selectedItemIDs = Set(ids)
        await autopilot.admitSelectionForTesting()
        return autopilot
    }

    private func writeBacklog(_ epics: String) throws {
        try """
        ---
        project: demo
        verify_default: true
        ---

        # Demo Backlog

        \(epics)
        """.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
    }

    /// Groomed enough to pass every pickup gate — What/How/Validation, a size, a
    /// verify — and citing nothing, so the grounding check has nothing to
    /// resolve and the queue that comes out is the ordering, not the grooming.
    private func writeDetail(id: String) throws {
        let dir = tempDir.appending(path: "backlog")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        id: \(id)
        title: An item
        status: ready
        size: S
        verify:
          - name: build
            cmd: "true"
        ---

        ## What

        Something small and self-contained.

        ## How

        Change it in place.

        ## Validation

        - [ ] It still works
        """.write(to: dir.appending(path: "\(id).md"), atomically: true, encoding: .utf8)
    }
}
