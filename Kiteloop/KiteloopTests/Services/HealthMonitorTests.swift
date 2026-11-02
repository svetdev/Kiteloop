import XCTest
@testable import Kiteloop

/// What the Health tab's memory gauge says, and the one case it used to get
/// wrong: a reading the kernel refused is not a process using no memory.
final class HealthMonitorTests: XCTestCase {

    private func snapshot(memoryMB: Double? = nil, mainThreadLatencyMs: Double = 0) -> HealthMonitor.Snapshot {
        HealthMonitor.Snapshot(
            processMemoryMB: memoryMB, activeSubprocessCount: 0, mainThreadLatencyMs: mainThreadLatencyMs,
            hitches: [], agentWorking: 0, agentIdle: 0, agentCrashed: 0
        )
    }

    // MARK: - No reading

    func testNoReadingRendersAsDashAndIsNotHealthy() {
        let gauge = snapshot(memoryMB: nil).memoryGauge
        XCTAssertEqual(gauge.text, "—")
        XCTAssertEqual(gauge.level, .unknown)
        XCTAssertNotEqual(gauge.level, .healthy)
    }

    func testZeroIsStillARealReadingAndNotTheUnknownOne() {
        let gauge = snapshot(memoryMB: 0).memoryGauge
        XCTAssertEqual(gauge.text, "0 MB")
        XCTAssertEqual(gauge.level, .healthy)
    }

    // MARK: - A reading

    func testReadingBelowThresholdIsHealthy() {
        let gauge = snapshot(memoryMB: 412.4).memoryGauge
        XCTAssertEqual(gauge.text, "412 MB")
        XCTAssertEqual(gauge.level, .healthy)
    }

    func testThresholdItselfIsStillHealthy() {
        let gauge = snapshot(memoryMB: HealthMonitor.Snapshot.memoryHighThresholdMB).memoryGauge
        XCTAssertEqual(gauge.text, "500 MB")
        XCTAssertEqual(gauge.level, .healthy)
    }

    func testReadingAboveThresholdIsNotHealthy() {
        let gauge = snapshot(memoryMB: 812.9).memoryGauge
        XCTAssertEqual(gauge.text, "813 MB")
        XCTAssertEqual(gauge.level, .high)
    }

    // MARK: - latencyGauge
    //
    // The Main Thread card must agree with what `/health` reports for the same
    // figure -- both compare at-or-above `hitchThresholdMs`, unlike the memory
    // gauge's strictly-above check.

    func testLatencyBelowThresholdIsHealthy() {
        let gauge = snapshot(mainThreadLatencyMs: HealthMonitor.hitchThresholdMs - 0.1).latencyGauge
        XCTAssertEqual(gauge.level, .healthy)
    }

    func testLatencyAtThresholdIsDegraded() {
        let gauge = snapshot(mainThreadLatencyMs: HealthMonitor.hitchThresholdMs).latencyGauge
        XCTAssertEqual(gauge.level, .degraded)
    }

    func testLatencyGaugeTextRendersWholeMilliseconds() {
        let gauge = snapshot(mainThreadLatencyMs: 42.6).latencyGauge
        XCTAssertEqual(gauge.text, "43 ms")
    }

    // MARK: - The reading itself

    /// `task_info` answers for this process, so the nil branch cannot be driven
    /// here; what is assertable is that a successful call reports a real figure
    /// rather than the zero the old signature could not tell it apart from.
    func testResidentMemoryReportsAFigureForThisProcess() {
        let mb = HealthMonitor.residentMemoryMB()
        XCTAssertNotNil(mb)
        XCTAssertGreaterThan(mb ?? 0, 0)
    }

    // MARK: - ProbeScheduler
    //
    // A stall of the main thread spans several one-second timer ticks before
    // the probe dispatched at its start gets to run. `ProbeScheduler` is the
    // pure decision of which ticks dispatch a probe at all: exactly the first
    // one of a stall, none of the ones queued up behind it. That is what
    // turns one long stall into one hitch instead of one per tick it lasted.

    func testFirstTickDispatchesAProbe() {
        var scheduler = HealthMonitor.ProbeScheduler()
        XCTAssertTrue(scheduler.shouldDispatch())
        XCTAssertTrue(scheduler.outstanding)
    }

    func testTicksDuringAStallDispatchNothingWhileAProbeIsOutstanding() {
        var scheduler = HealthMonitor.ProbeScheduler()
        XCTAssertTrue(scheduler.shouldDispatch())

        // A 3.7s stall spans four ticks; only the first should have
        // dispatched a probe.
        XCTAssertFalse(scheduler.shouldDispatch())
        XCTAssertFalse(scheduler.shouldDispatch())
        XCTAssertFalse(scheduler.shouldDispatch())
    }

    func testATickAfterTheProbeReturnsDispatchesAnother() {
        var scheduler = HealthMonitor.ProbeScheduler()
        XCTAssertTrue(scheduler.shouldDispatch())

        scheduler.probeCompleted()
        XCTAssertFalse(scheduler.outstanding)

        // A second, independent stall gets its own probe -- and so its own
        // hitch -- rather than being folded into the first.
        XCTAssertTrue(scheduler.shouldDispatch())
    }

    // MARK: - ProbeScheduler: in-flight elapsed time
    //
    // While the main thread is wedged, the probe dispatched at the start of
    // the stall never completes -- so `outstandingElapsedMs` is what lets a
    // snapshot taken mid-stall see it, instead of only ever hearing about a
    // stall after the main thread has already recovered.

    func testNeverDispatchedReportsNothingPending() {
        let scheduler = HealthMonitor.ProbeScheduler()
        XCTAssertNil(scheduler.outstandingElapsedMs())
    }

    func testOutstandingProbeReportsAtLeastTheElapsedInterval() {
        var scheduler = HealthMonitor.ProbeScheduler()
        let dispatched = DispatchTime.now()
        XCTAssertTrue(scheduler.shouldDispatch(now: dispatched))

        let asked = dispatched + .milliseconds(250)
        let elapsed = scheduler.outstandingElapsedMs(now: asked)

        XCTAssertNotNil(elapsed)
        XCTAssertGreaterThanOrEqual(elapsed ?? 0, 250)
    }

    func testCompletedProbeReportsNothingPending() {
        var scheduler = HealthMonitor.ProbeScheduler()
        XCTAssertTrue(scheduler.shouldDispatch())
        scheduler.probeCompleted()

        XCTAssertNil(scheduler.outstandingElapsedMs())
    }

    // MARK: - reportedLatencyMs
    //
    // What a snapshot combines the last completed probe's figure with: an
    // outstanding probe waiting longer than that, so a stall reads as
    // degraded while it is happening rather than only once it ends.

    func testReportedLatencyDuringAnOutstandingStallIsAtLeastTheThreshold() {
        var scheduler = HealthMonitor.ProbeScheduler()
        let dispatched = DispatchTime.now()
        XCTAssertTrue(scheduler.shouldDispatch(now: dispatched))

        let asked = dispatched + .milliseconds(Int(HealthMonitor.hitchThresholdMs) + 50)
        let reported = HealthMonitor.reportedLatencyMs(latest: 3, scheduler: scheduler, now: asked)

        XCTAssertGreaterThanOrEqual(reported, HealthMonitor.hitchThresholdMs)
    }

    func testReportedLatencyIgnoresAShortOutstandingWaitBelowTheLatestFigure() {
        var scheduler = HealthMonitor.ProbeScheduler()
        let dispatched = DispatchTime.now()
        XCTAssertTrue(scheduler.shouldDispatch(now: dispatched))

        let asked = dispatched + .milliseconds(5)
        let reported = HealthMonitor.reportedLatencyMs(latest: 42, scheduler: scheduler, now: asked)

        XCTAssertEqual(reported, 42)
    }

    func testReportedLatencyAfterCompletionIsTheCompletedFigureAgain() {
        var scheduler = HealthMonitor.ProbeScheduler()
        let dispatched = DispatchTime.now()
        XCTAssertTrue(scheduler.shouldDispatch(now: dispatched))
        scheduler.probeCompleted()

        // Asked long after the probe that was outstanding would have crossed
        // the threshold -- the stale reading must not resurface.
        let asked = dispatched + .milliseconds(Int(HealthMonitor.hitchThresholdMs) + 500)
        let reported = HealthMonitor.reportedLatencyMs(latest: 6.4, scheduler: scheduler, now: asked)

        XCTAssertEqual(reported, 6.4)
    }
}
