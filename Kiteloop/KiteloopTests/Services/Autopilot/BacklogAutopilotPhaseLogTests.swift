import XCTest
@testable import Kiteloop

/// Covers the structured lines the autopilot writes to the unified log at each
/// run-phase boundary. The formatting is the contract — anything reading a
/// marathon back out of `log show` parses these — so the shape of a line and the
/// phase names are pinned here.
final class BacklogAutopilotPhaseLogTests: XCTestCase {

    func testPhaseComesFirstAndFieldsKeepTheirOrder() {
        let line = BacklogAutopilot.phaseLine(.itemStart, [
            ("item", "logging-structured-run"),
            ("index", "1"),
            ("total", "3"),
        ])
        XCTAssertEqual(line, "phase=item.start item=logging-structured-run index=1 total=3")
    }

    func testNilAndEmptyFieldsAreDroppedNotLoggedAsBlanks() {
        let line = BacklogAutopilot.phaseLine(.itemEnd, [
            ("item", "abc"),
            ("branch", nil),          // ran in the live tree — no branch to name
            ("quality", ""),          // judge off — unscored, not zero
            ("costUSD", "0.4210"),
        ])
        XCTAssertEqual(line, "phase=item.end item=abc costUSD=0.4210")
    }

    /// An item title is free text; a space in it must not read as the next field.
    func testValuesWithSpacesOrEqualsAreQuoted() {
        let line = BacklogAutopilot.phaseLine(.itemStart, [
            ("title", "Add structured os.Logger lines"),
            ("reason", "cap=exceeded"),
        ])
        XCTAssertEqual(line, #"phase=item.start title="Add structured os.Logger lines" reason="cap=exceeded""#)
    }

    func testQuotesAndNewlinesInValuesAreEscaped() {
        let line = BacklogAutopilot.phaseLine(.itemEnd, [("reason", "said \"no\"\nand stopped")])
        XCTAssertEqual(line, #"phase=item.end reason="said \"no\"\nand stopped""#)
    }

    func testPlainValuesAreNotQuoted() {
        let line = BacklogAutopilot.phaseLine(.merge, [("merged", "true"), ("branch", "kiteloop/some-item")])
        XCTAssertEqual(line, "phase=merge merged=true branch=kiteloop/some-item")
    }

    func testPhaseWithNoFieldsIsStillAWellFormedLine() {
        XCTAssertEqual(BacklogAutopilot.phaseLine(.runEnd, []), "phase=run.end")
        XCTAssertEqual(BacklogAutopilot.phaseLine(.runEnd, [("run", nil)]), "phase=run.end")
    }

    // MARK: - A skip for the item's status

    /// The fourth skip bucket used to leave prose in the run log and nothing in
    /// the phase stream, so a reader parsing `item.start` rows saw three of the
    /// four reasons an item was passed over. This row is the fourth.
    func testWrongStatusSkipWritesAnItemStartRowNamingTheStatusAndTheStages() {
        let line = BacklogAutopilot.phaseLine(.itemStart, BacklogAutopilot.wrongStatusSkipFields(
            itemID: "wrong-status-skip-leaves-no-phase-row",
            status: .draft,
            pickupStages: [.ready]))
        XCTAssertEqual(line, "phase=item.start item=wrong-status-skip-leaves-no-phase-row"
                       + " status=skipped source=pickup-stage stage=draft pickupStages=ready")
    }

    /// Stage names are the raw spellings, not the display ones: `in-review`
    /// parses as a field, `In Review` would have to be quoted to.
    func testWrongStatusSkipNamesEveryPickupStageInItsRawSpelling() {
        let line = BacklogAutopilot.phaseLine(.itemStart, BacklogAutopilot.wrongStatusSkipFields(
            itemID: "abc",
            status: .inReview,
            pickupStages: [.ready, .inReview]))
        XCTAssertEqual(line, "phase=item.start item=abc status=skipped source=pickup-stage"
                       + " stage=in-review pickupStages=ready,in-review")
    }

    /// The run-log line and the aborted start's reason are the same sentence, so
    /// they can't drift into saying different things about one skip.
    func testWrongStatusSummaryNamesTheStatusAndTheStagesAutopilotRuns() {
        XCTAssertEqual(BacklogAutopilot.wrongStatusSkipSummary(status: .blocked,
                                                               pickupStages: [.ready, .inReview]),
                       "status Blocked, autopilot only runs Ready/In Review")
    }

    // MARK: - The app's own verify

    /// The stretch where the app runs the item's `verify:` itself is a build
    /// that can take the whole of `verifyTimeout`, and it used to write no
    /// phase line at all — so a night's runs could not be counted by it, and
    /// the rail sat on `worker` throughout. The row names the item, the command
    /// and the deadline it ran under.
    func testVerifyRowNamesTheItemTheCommandAndTheDeadlineItRanUnder() {
        let line = BacklogAutopilot.phaseLine(.verify, BacklogAutopilot.verifyPhaseFields(
            itemID: "phase-rail-verify-step-is-never-current",
            command: "swift test",
            timeout: 900))
        XCTAssertEqual(line, "phase=verify.start item=phase-rail-verify-step-is-never-current"
                       + " command=\"swift test\" deadlineSec=900")
    }

    // MARK: - The reason an aborted start records

    /// "wrong status: 2" didn't say which two. Every bucket names its items now,
    /// wrong-status first, in the order the counts are listed.
    func testAbortReasonNamesTheWrongStatusItemsAlongsideTheOtherThree() {
        let detail = BacklogAutopilot.noRunnableItemsDetail(
            selected: 4,
            wrongStatus: [(id: "a", summary: "status Draft, autopilot only runs Ready")],
            notReady: [(id: "b", summary: "no verify command")],
            retired: [(id: "c", summary: "3 attempts produced no work")],
            notGrounded: [(id: "d", summary: "no such file: Foo.swift")])
        XCTAssertEqual(detail, "No runnable items selected (selected: 4, wrong status: 1,"
                       + " not ready: 1, retired: 1, not grounded: 1)"
                       + " — a (status Draft, autopilot only runs Ready), b (no verify command),"
                       + " c (3 attempts produced no work), d (no such file: Foo.swift)")
    }

    /// The three other sources read exactly as they did before wrong-status
    /// joined them — same counts, same order, same separator.
    func testAbortReasonForTheOtherThreeSourcesIsUnchanged() {
        let detail = BacklogAutopilot.noRunnableItemsDetail(
            selected: 2,
            wrongStatus: [],
            notReady: [(id: "b", summary: "no verify command")],
            retired: [],
            notGrounded: [(id: "d", summary: "no such file: Foo.swift")])
        XCTAssertEqual(detail, "No runnable items selected (selected: 2, wrong status: 0,"
                       + " not ready: 1, retired: 0, not grounded: 1)"
                       + " — b (no verify command), d (no such file: Foo.swift)")
    }

    /// Nothing to name — the reason stops at the counts rather than trailing an
    /// empty dash.
    func testAbortReasonWithNothingToNameIsJustTheCounts() {
        XCTAssertEqual(BacklogAutopilot.noRunnableItemsDetail(selected: 0, wrongStatus: [],
                                                              notReady: [], retired: [], notGrounded: []),
                       "No runnable items selected (selected: 0, wrong status: 0,"
                       + " not ready: 0, retired: 0, not grounded: 0)")
    }

    /// The names are what a grep or a log parser keys off — changing one breaks
    /// every reader, so they're pinned rather than derived.
    func testPhaseNamesAreStable() {
        XCTAssertEqual(BacklogAutopilot.RunPhase.runStart.rawValue, "run.start")
        XCTAssertEqual(BacklogAutopilot.RunPhase.itemStart.rawValue, "item.start")
        XCTAssertEqual(BacklogAutopilot.RunPhase.worker.rawValue, "worker.start")
        XCTAssertEqual(BacklogAutopilot.RunPhase.verify.rawValue, "verify.start")
        XCTAssertEqual(BacklogAutopilot.RunPhase.reviewer.rawValue, "reviewer.start")
        XCTAssertEqual(BacklogAutopilot.RunPhase.itemAbort.rawValue, "item.abort")
        XCTAssertEqual(BacklogAutopilot.RunPhase.itemOverBudget.rawValue, "item.over-budget")
        XCTAssertEqual(BacklogAutopilot.RunPhase.itemNearCap.rawValue, "item.near-cap")
        XCTAssertEqual(BacklogAutopilot.RunPhase.itemEnd.rawValue, "item.end")
        XCTAssertEqual(BacklogAutopilot.RunPhase.agentRestart.rawValue, "agent.restart")
        XCTAssertEqual(BacklogAutopilot.RunPhase.merge.rawValue, "merge")
        XCTAssertEqual(BacklogAutopilot.RunPhase.mergeWaiting.rawValue, "merge.waiting")
        XCTAssertEqual(BacklogAutopilot.RunPhase.runPause.rawValue, "run.pause")
        XCTAssertEqual(BacklogAutopilot.RunPhase.runEnd.rawValue, "run.end")
    }

    // MARK: - A merge queued behind another on the same project

    /// A merge waiting for the project's merge gate is not a merge in progress,
    /// and used to read as exactly one: the rail said `merge` and the bus said
    /// nothing, so an operator watching a second merge saw it verifying while it
    /// was still queued. `noteMergeGateWait` is the one place that difference is
    /// written down — `merge.waiting` on the rail and an `autopilot-merge-waiting`
    /// event for as long as the wait lasts, back to `merge` the moment the gate
    /// is held.
    @MainActor
    func testAMergeWaitingOnTheProjectsGateSaysSoOnTheRailAndOnTheBus() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "autopilot-merge-waiting")
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: orchestrator,
            backlogViewModel: BacklogViewModel(globalConfigStore: GlobalConfigStore(
                storageURL: tempDir.appendingPathComponent("global-config.json"))),
            configURL: tempDir.appendingPathComponent("autopilot-config.json"))

        autopilot.noteMergeGateWait(.waiting, itemID: "queued-item", branch: "kiteloop/queued-item")

        XCTAssertEqual(autopilot.currentRunPhase, .mergeWaiting)
        XCTAssertEqual(PortfolioSnapshot.RunState.PhaseRail.step(for: .mergeWaiting), .waitingForGate,
                       "the rail draws the wait as its own step, not as the merge")
        let event = try await eventuallyValue("the autopilot-merge-waiting event") {
            await orchestrator.eventBus.recentEvents()
                .last { $0.payload["kind"] == "autopilot-merge-waiting" }
        }
        XCTAssertEqual(event.source, "Autopilot")
        XCTAssertEqual(event.payload["item"], "queued-item")
        XCTAssertEqual(event.payload["branch"], "kiteloop/queued-item")

        autopilot.noteMergeGateWait(.acquired, itemID: "queued-item", branch: "kiteloop/queued-item")

        XCTAssertEqual(autopilot.currentRunPhase, .merge,
                       "holding the gate puts the rail back on the merge itself")
    }
}
