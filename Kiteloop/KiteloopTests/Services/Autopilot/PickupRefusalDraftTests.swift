import XCTest
import KiteloopCore
@testable import Kiteloop

/// A grounding or definition-of-ready refusal, at the exact seam
/// `BacklogAutopilot.start()` refuses one from — the way three real items were
/// retired: `health-endpoint-cannot-report-unhealth` and
/// `daily-logs-are-pruned-only-when-a-project-opens` in this repo,
/// `app-association-files-name-the-real-app` in travel, each refused three
/// times on a single citation to reword with no run ever starting. What is
/// pinned here is the whole pickup pass, not just `RetryCeiling`'s count: the
/// item ends `draft`, with the refusal in its Notes, and the ceiling reads it
/// as never having been attempted.
@MainActor
final class PickupRefusalDraftTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "pickup-refusal-draft")
    }

    /// The three items replayed at once: each cites a path or symbol the repo
    /// does not have, each is otherwise fully groomed, and all three come out
    /// of the same pickup pass as drafts carrying their own reason — not
    /// retired, and not counted against the ceiling.
    func testItemsRefusedOnGroundingAlonePickUpAsDraftsNotRetirements() async throws {
        let items: [(id: String, citation: String)] = [
            ("health-endpoint-cannot-report-unhealth", "`Services/HealthReport.swift`"),
            ("daily-logs-are-pruned-only-when-a-project-opens", "`Services/DailyLogPruner.swift`"),
            ("app-association-files-name-the-real-app", "`applicationId`"),
        ]
        for entry in items { try writeGroundedButUnresolvedItem(id: entry.id, citing: entry.citation) }
        try writeBacklog(itemIDs: items.map(\.id))

        let store = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"))
        let vm = BacklogViewModel(globalConfigStore: makeConfigStore())
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())  // retained: the autopilot holds it weakly
        let autopilot = BacklogAutopilot()
        autopilot.configure(orchestrator: orchestrator,
                            backlogViewModel: vm, metricStore: store,
                            projectPath: tempDir.path(percentEncoded: false), projectName: "demo")
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        autopilot.selectedItemIDs = Set(items.map(\.id))

        await autopilot.start()

        for entry in items {
            let onDisk = try XCTUnwrap(parseDisk().sections.flatMap(\.items).first { $0.id == entry.id })
            XCTAssertEqual(onDisk.status, .draft, "\(entry.id) should be sent back to draft, not left ready")

            let notes = try XCTUnwrap(vm.loadDetail(for: onDisk)?.notes, "\(entry.id) has no Notes")
            XCTAssertTrue(notes.contains("sent back to draft:"), "\(entry.id): \(notes)")
            XCTAssertTrue(notes.contains(entry.citation), "\(entry.id) should name what it cited: \(notes)")

            let verdict = RetryCeiling.evaluate(itemID: entry.id,
                                                projectPath: tempDir.path(percentEncoded: false),
                                                records: store.records)
            XCTAssertEqual(verdict.noWorkAttempts, 0, "\(entry.id) should not have spent an attempt")
            XCTAssertFalse(verdict.isRetired, "\(entry.id) should not be retired")
        }
    }

    /// Replayed three times over, the way the real items were refused three
    /// ticks running before a human reworded them — still no attempt spent,
    /// and still not retired, because each pickup redirects to `draft` before
    /// the ceiling is ever asked.
    func testThreeConsecutivePickupsOnTheSameCitationNeverRetireTheItem() async throws {
        let id = "app-association-files-name-the-real-app"
        try writeGroundedButUnresolvedItem(id: id, citing: "`applicationId`")
        try writeBacklog(itemIDs: [id])

        let store = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"))

        for _ in 0..<3 {
            let vm = BacklogViewModel(globalConfigStore: makeConfigStore())
            vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))
            // Put it back to `ready`, the way a person would after skimming the
            // note but before actually fixing the citation — the failure mode
            // that used to cost the item an attempt every time.
            vm.updateItemStatus(itemID: id, newStatus: .ready)

            let orchestrator = Orchestrator(runtime: MockAgentRuntime())  // retained: the autopilot holds it weakly
            let autopilot = BacklogAutopilot()
            autopilot.configure(orchestrator: orchestrator,
                                backlogViewModel: vm, metricStore: store,
                                projectPath: tempDir.path(percentEncoded: false), projectName: "demo")
            autopilot.workerAgentID = "worker"
            autopilot.reviewerAgentID = "reviewer"
            autopilot.selectedItemIDs = [id]

            await autopilot.start()
        }

        let verdict = RetryCeiling.evaluate(itemID: id, projectPath: tempDir.path(percentEncoded: false),
                                            records: store.records)
        XCTAssertEqual(verdict.noWorkAttempts, 0)
        XCTAssertFalse(verdict.isRetired, "Three refusals on the same wording must not retire the item")
        XCTAssertEqual(store.records.filter { $0.itemID == id }.count, 3,
                       "the history is still kept, one row per pickup")
    }

    // MARK: - Fixtures

    private func makeConfigStore() -> GlobalConfigStore {
        GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
    }

    private var backlogURL: URL { tempDir.appending(path: "BACKLOG.md") }

    private func writeBacklog(itemIDs: [String]) throws {
        let lines = itemIDs.map { "- [ ] \($0) | An item | ready → [detail](backlog/\($0).md)" }
        try """
        ---
        project: demo
        verify_default: swift build
        ---

        # Demo Backlog

        ## Epic: Now

        \(lines.joined(separator: "\n"))
        """.write(to: backlogURL, atomically: true, encoding: .utf8)
    }

    /// Fully groomed — every Definition-of-Ready clause is met — except that
    /// its `## What` cites something the repo does not have, so pickup reaches
    /// the grounding check and is refused there, not earlier.
    private func writeGroundedButUnresolvedItem(id: String, citing: String) throws {
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

        Fix \(citing), which this draft claims is already there.

        ## How

        Edit it in place.

        ## Validation

        - [ ] The claim holds
        """.write(to: dir.appending(path: "\(id).md"), atomically: true, encoding: .utf8)
    }

    private func parseDisk() throws -> BacklogFile {
        BacklogParser.parse(try String(contentsOf: backlogURL, encoding: .utf8))
    }
}
