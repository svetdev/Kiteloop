import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers `autoMergeVerifyTimeoutMinutes` — the merge gate's own clock — now
/// that it is derived from this project's own gate phases rather than set on
/// the Autopilot page. `RunTimeoutsTests` pins the arithmetic; this pins the
/// wiring: which records count as this project's landed runs, and that the
/// number a run is actually timed against comes off them.
@MainActor
final class BacklogAutopilotAutoMergeVerifyTimeoutTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "autopilot-merge-verify-timeout")
    }

    private func makeStore() -> TaskMetricStore {
        TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl"),
            mergesURL: tempDir.appendingPathComponent("task-merges.jsonl"))
    }

    /// One run of `project`, carrying whichever phase durations it measured.
    /// A record carrying any of them is a sample of that phase.
    private func landed(project: String, worker: Double?, gate: Double?,
                        verify: Double? = nil) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: project, projectName: "demo", itemID: "item-1", title: "An item",
            epic: nil, declaredSize: nil, startedAt: Date(), completedAt: Date(),
            durationSeconds: 3_600, costUSD: 1, reviewerRetries: 0, outcome: "done",
            workerAgent: nil, reviewerAgent: nil, executionID: nil, toolErrors: nil)
        record.workerPhaseSeconds = worker
        record.gatePhaseSeconds = gate
        record.verifyPhaseSeconds = verify
        return record
    }

    private func makeAutopilot(configURL: URL, store: TaskMetricStore? = nil) -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(
                    storageURL: tempDir.appendingPathComponent("global-config.json")
                )
            ),
            configURL: configURL,
            metricStore: store,
            projectPath: tempDir.path(percentEncoded: false),
            projectName: "demo"
        )
        return autopilot
    }

    // MARK: - What a project runs on before it has measured itself

    /// A project with nothing on record runs the deadline every project ran on
    /// before the derivation existed, and `GET /v1/autopilot` can say so.
    func testAProjectWithNoLandedRunsUsesTheDefault() {
        let autopilot = makeAutopilot(configURL: tempDir.appendingPathComponent("autopilot-config.json"))
        XCTAssertEqual(autopilot.autoMergeVerifyTimeoutMinutes, RunTimeouts.defaultGateMinutes)
        XCTAssertEqual(autopilot.runTimeouts.gate.source, .default)
    }

    /// Four landed runs is still too few — the fifth is where the ledger starts
    /// answering.
    func testFourLandedRunsStillUseTheDefault() {
        let store = makeStore()
        let project = tempDir.path(percentEncoded: false)
        for _ in 0..<4 { store.append(landed(project: project, worker: 1_800, gate: 1_200)) }

        let autopilot = makeAutopilot(
            configURL: tempDir.appendingPathComponent("autopilot-config.json"), store: store)

        XCTAssertEqual(autopilot.autoMergeVerifyTimeoutMinutes, RunTimeouts.defaultGateMinutes)
        XCTAssertEqual(autopilot.runTimeouts.gate.source, .default)
    }

    // MARK: - What a project runs on once it has

    /// Ten landed runs, and the gate's clock is their p95 gate phase plus half
    /// again — 1200s × 1.5 = 30 minutes — not the whole run's duration, which
    /// here is three times longer.
    func testTenLandedRunsDeriveTheGateDeadline() {
        let store = makeStore()
        let project = tempDir.path(percentEncoded: false)
        for _ in 0..<10 { store.append(landed(project: project, worker: 600, gate: 1_200)) }

        let autopilot = makeAutopilot(
            configURL: tempDir.appendingPathComponent("autopilot-config.json"), store: store)

        XCTAssertEqual(autopilot.autoMergeVerifyTimeoutMinutes, 30)
        XCTAssertEqual(autopilot.runTimeouts.gate.source, .derived)
    }

    // MARK: - Which records count

    /// Another project's runs are another project's history: this one is still
    /// on the default with ten of them on the same ledger, because there is one
    /// metrics file for every project the app has ever run.
    func testAnotherProjectsRunsAreNotThisProjectsHistory() {
        let store = makeStore()
        for _ in 0..<10 { store.append(landed(project: "/somewhere/else/", worker: 1_800, gate: 1_800)) }

        let autopilot = makeAutopilot(
            configURL: tempDir.appendingPathComponent("autopilot-config.json"), store: store)

        XCTAssertEqual(autopilot.runTimeouts.gate.source, .default)
        XCTAssertEqual(autopilot.runTimeouts.worker.source, .default)
    }

    /// A record written before the phase durations existed is skipped, not read
    /// as zero — a ledger full of them would otherwise floor every deadline.
    func testRecordsWithoutPhaseDurationsAreSkipped() {
        let project = tempDir.path(percentEncoded: false)
        let records = (0..<10).map { _ in landed(project: project, worker: nil, gate: nil) }
        XCTAssertTrue(BacklogAutopilot.landedPhaseSamples(records: records,
                                                          projectPath: project).isEmpty)
    }

    /// A run recorded under a path ending in a slash is this project's run:
    /// the project the ledger was written for and the project asking are the
    /// same folder, spelled two ways.
    func testARunRecordedUnderASlashedPathIsStillThisProjectsRun() {
        let slashed = tempDir.path(percentEncoded: false) + "/"
        let records = [landed(project: slashed, worker: 600, gate: 1_200)]
        XCTAssertEqual(BacklogAutopilot.landedPhaseSamples(
            records: records, projectPath: KiteloopProject.canonicalPath(slashed)),
                       [RunTimeouts.Sample(workerSeconds: 600, gateSeconds: 1_200, costUSD: 1)])
    }

    // MARK: - The pre-review verify is a gate sample too

    /// A project running under `propose` parks every passed run at the approval
    /// gate, so no run of it ever measures a merge phase — but every run of it
    /// measures the pre-review verify, which is the same command on the same
    /// class of tree under the same clock. Five of them derive the gate
    /// deadline: 1200s × 1.5 = 30 minutes, twice the 15-minute default a cold
    /// build kept dying at, and reported as measured.
    func testRunsThatOnlyReachedThePreReviewVerifyDeriveTheGateDeadline() {
        let store = makeStore()
        let project = tempDir.path(percentEncoded: false)
        for _ in 0..<5 {
            store.append(landed(project: project, worker: nil, gate: nil, verify: 1_200))
        }

        let autopilot = makeAutopilot(
            configURL: tempDir.appendingPathComponent("autopilot-config.json"), store: store)

        XCTAssertEqual(autopilot.autoMergeVerifyTimeoutMinutes, 30)
        XCTAssertEqual(autopilot.runTimeouts.gate.source, .derived)
    }

    /// A run carrying both readings contributes the larger as its one gate
    /// sample — the deadline has to clear the slowest of the runs it was
    /// measured from, whichever of the two verifies that was.
    func testARecordCarryingBothVerifyReadingsContributesTheLarger() {
        let project = tempDir.path(percentEncoded: false)
        let records = [landed(project: project, worker: nil, gate: 1_800, verify: 600),
                       landed(project: project, worker: nil, gate: 600, verify: 1_800)]
        XCTAssertEqual(BacklogAutopilot.landedPhaseSamples(records: records, projectPath: project),
                       [RunTimeouts.Sample(gateSeconds: 1_800, costUSD: 1),
                        RunTimeouts.Sample(gateSeconds: 1_800, costUSD: 1)])
    }

    /// A record carrying none of the three is still skipped, not read as zero —
    /// which is every record written before these fields existed.
    func testARecordWithNoPhaseReadingAtAllIsStillSkipped() {
        let project = tempDir.path(percentEncoded: false)
        let records = (0..<10).map { _ in
            landed(project: project, worker: nil, gate: nil, verify: nil)
        }
        XCTAssertTrue(BacklogAutopilot.landedPhaseSamples(records: records,
                                                          projectPath: project).isEmpty)
    }

    // MARK: - What a run writes down about its own verify

    /// The seconds the pre-review verify took reach the metric record off the
    /// same rail step a person watches it on — this run's worker round took
    /// 300s and its verify 900s, and the record says both.
    func testAFinishedRunRecordsThePreReviewVerifysSeconds() throws {
        let store = makeStore()
        let project = tempDir.path(percentEncoded: false)
        let autopilot = makeAutopilot(
            configURL: tempDir.appendingPathComponent("autopilot-config.json"), store: store)

        let start = Date()
        autopilot.notePhaseForTesting(.itemStart, at: start)
        autopilot.notePhaseForTesting(.worker, at: start)
        autopilot.notePhaseForTesting(.verify, at: start.addingTimeInterval(300))
        autopilot.notePhaseForTesting(.reviewer, at: start.addingTimeInterval(1_200))
        autopilot.fileMetricForTesting(landed(project: project, worker: nil, gate: nil), to: store)

        let record = try XCTUnwrap(store.records.last)
        XCTAssertEqual(record.verifyPhaseSeconds, 900)
        XCTAssertEqual(record.workerPhaseSeconds, 300)
        XCTAssertNil(record.gatePhaseSeconds)
    }

    /// An item that declares no `verify:` never logs the phase, so the record
    /// carries no reading — nil, not a zero that would floor the gate's clock.
    func testARunThatDeclaresNoVerifyWritesNoVerifySeconds() throws {
        let store = makeStore()
        let project = tempDir.path(percentEncoded: false)
        let autopilot = makeAutopilot(
            configURL: tempDir.appendingPathComponent("autopilot-config.json"), store: store)

        let start = Date()
        autopilot.notePhaseForTesting(.itemStart, at: start)
        autopilot.notePhaseForTesting(.worker, at: start)
        autopilot.notePhaseForTesting(.reviewer, at: start.addingTimeInterval(600))
        autopilot.fileMetricForTesting(landed(project: project, worker: nil, gate: nil), to: store)

        let record = try XCTUnwrap(store.records.last)
        XCTAssertNil(record.verifyPhaseSeconds)
        XCTAssertEqual(record.workerPhaseSeconds, 600)
    }

    /// The worker's clock reads only the worker phase: a ledger of verify-only
    /// runs measures the gate and leaves the worker on its default.
    func testAVerifyReadingSaysNothingAboutTheWorkerDeadline() {
        let store = makeStore()
        let project = tempDir.path(percentEncoded: false)
        for _ in 0..<6 {
            store.append(landed(project: project, worker: nil, gate: nil, verify: 1_200))
        }

        let autopilot = makeAutopilot(
            configURL: tempDir.appendingPathComponent("autopilot-config.json"), store: store)

        XCTAssertEqual(autopilot.stallTimeoutMinutes, RunTimeouts.defaultWorkerMinutes)
        XCTAssertEqual(autopilot.runTimeouts.worker.source, .default)
    }

    /// A run that never reached the gate measured no gate phase, and it is
    /// still a worker sample: it carries a worker phase, which is the only
    /// thing the worker deadline reads. Held out, a project whose runs stop at
    /// the approval gate could never measure a worker deadline at all.
    func testARunThatNeverReachedTheGateIsStillAWorkerSample() {
        let project = tempDir.path(percentEncoded: false)
        let records = [landed(project: project, worker: 900, gate: nil),
                       landed(project: project, worker: 900, gate: 300)]
        let samples = BacklogAutopilot.landedPhaseSamples(records: records, projectPath: project)
        XCTAssertEqual(samples, [RunTimeouts.Sample(workerSeconds: 900, gateSeconds: nil, costUSD: 1),
                                 RunTimeouts.Sample(workerSeconds: 900, gateSeconds: 300, costUSD: 1)])
    }

    /// The whole of this item, end to end: five runs that stopped at the
    /// approval gate give this project a measured worker deadline — 1800s ×
    /// 1.5 = 45 minutes, well past the 20 its rounds outgrew — while the gate,
    /// which those runs never reached, stays on its default and says so.
    func testRunsThatStopAtTheGateStillDeriveTheWorkerDeadline() {
        let store = makeStore()
        let project = tempDir.path(percentEncoded: false)
        for _ in 0..<5 { store.append(landed(project: project, worker: 1_800, gate: nil)) }

        let autopilot = makeAutopilot(
            configURL: tempDir.appendingPathComponent("autopilot-config.json"), store: store)

        XCTAssertEqual(autopilot.stallTimeoutMinutes, 45)
        XCTAssertEqual(autopilot.runTimeouts.worker.source, .derived)
        XCTAssertEqual(autopilot.autoMergeVerifyTimeoutMinutes, RunTimeouts.defaultGateMinutes)
        XCTAssertEqual(autopilot.runTimeouts.gate.source, .default)
    }

    /// A project with no identity has no runs of its own on a shared ledger.
    func testNoProjectPathMeansNoSamples() {
        let records = [landed(project: "/somewhere/", worker: 900, gate: 300)]
        XCTAssertTrue(BacklogAutopilot.landedPhaseSamples(records: records, projectPath: nil).isEmpty)
    }

    // MARK: - No longer a setting

    /// An `autopilot-config.json` written when this was a setting still loads;
    /// its copy of the number is simply not what the gate runs on any more.
    func testAnOldConfigFileNoLongerSetsTheDeadline() throws {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")
        try #"{"autoMergeVerifyTimeoutMinutes":90,"maxRetries":2}"#
            .write(to: configURL, atomically: true, encoding: .utf8)

        let autopilot = makeAutopilot(configURL: configURL)

        XCTAssertEqual(autopilot.autoMergeVerifyTimeoutMinutes, RunTimeouts.defaultGateMinutes)
        XCTAssertEqual(autopilot.maxRetries, 2, "the settings that are still settings still load")
    }

    /// Nothing about the deadline can leave the config off its defaults, so the
    /// Reset control is not offered for a number nobody can set.
    func testTheDeadlineDoesNotAffectTheResetControl() {
        let autopilot = makeAutopilot(configURL: tempDir.appendingPathComponent("autopilot-config.json"))
        XCTAssertTrue(autopilot.isConfigAtDefaults)
    }
}
