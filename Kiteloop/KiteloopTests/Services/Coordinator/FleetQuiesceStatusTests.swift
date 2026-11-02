import XCTest
@testable import Kiteloop

/// The mapping from what the quiesce seam answers to what the app shows —
/// `FleetQuiesceTests` covers the decisions the seam makes, this covers what the
/// footer and the quit offer say about them.
///
/// All of it is over plain readings: nothing here holds a queue, so a case can
/// state a fleet — two projects busy, one held, drained — that would take a run
/// to reach for real.
@MainActor
final class FleetQuiesceStatusTests: XCTestCase {

    // MARK: - State and action

    /// A fleet nobody has held offers the hold, and nothing else. The title is
    /// the operator's word — the scope rides beside it in the footer's Fleet
    /// badge, since a project's own Pause is the weaker control.
    func testNotQuiescedOffersTheHold() {
        let status = FleetQuiesceStatus(reading: reading(quiesced: false, projects: [project("alpha")]))

        XCTAssertEqual(status.state, .takingWork)
        XCTAssertEqual(status.action, .quiesce)
        XCTAssertEqual(status.action.title, "Pause")
    }

    /// Quiesced with a run still going is the state the box exists to show: held
    /// is not drained, and only the second makes a restart safe.
    func testQuiescedWithARunStillGoingReadsAsDraining() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: true,
            projects: [project("alpha", running: true, item: "a1"), project("beta")]
        ))

        XCTAssertEqual(status.state, .draining)
        XCTAssertEqual(status.action, .resume)
        XCTAssertEqual(status.action.title, "Resume")
    }

    /// The state a quiesce is taken to reach.
    func testQuiescedAndDrainedReadsAsHeld() {
        let status = FleetQuiesceStatus(reading: reading(quiesced: true, projects: [project("alpha")]))

        XCTAssertEqual(status.state, .held)
        XCTAssertEqual(status.action, .resume)
    }

    // MARK: - The state line

    /// The line under the control says what the fleet is doing in the words the
    /// control is named in — a hold that is still landing runs is "pausing", and
    /// only the state a restart is safe in reads "paused".
    func testStateLineSaysWhereTheFleetIs() {
        let pausing = reading(quiesced: true, projects: [project("alpha", running: true, item: "a1"),
                                                         project("beta", running: true, item: "b1")])
        let paused = reading(quiesced: true, projects: [project("alpha")])
        let busy = reading(quiesced: false, projects: [project("alpha", running: true, item: "a1")])
        let idle = reading(quiesced: false, projects: [project("alpha")])

        XCTAssertEqual(FleetQuiesceStatus(reading: pausing).stateLine, "pausing — 2 run(s) finishing")
        XCTAssertEqual(FleetQuiesceStatus(reading: paused).stateLine, "paused — all quiet")
        XCTAssertEqual(FleetQuiesceStatus(reading: busy).stateLine, "taking work — 1 run(s) in flight")
        XCTAssertEqual(FleetQuiesceStatus(reading: idle).stateLine, "taking work — all quiet")
    }

    /// No user-facing line says "quiesce" or "drained" — those are the seam's
    /// words, and an operator should not need to know them to park their fleet.
    func testNothingTheOperatorReadsSaysQuiesce() {
        let fleets = [
            reading(quiesced: true, projects: [project("alpha", running: true, item: "a1",
                                                       heldByQuiesce: true, heldItems: 2)]),
            reading(quiesced: true, projects: [project("alpha")]),
            reading(quiesced: false, projects: [project("alpha", running: true, item: "a1")]),
            reading(quiesced: false, projects: [project("alpha")])
        ]

        for fleet in fleets {
            let status = FleetQuiesceStatus(reading: fleet, isQuittingWhenDrained: true)
            let prompt = FleetQuitPrompt(reading: fleet)
            let shown = [status.stateLine, status.action.title, status.help, status.quitNotice ?? ""]
                + status.projects.map(\.line)
                + [prompt?.message ?? "", prompt?.detail ?? ""]
                + (prompt?.choices.map(\.title) ?? [])
            for line in shown {
                XCTAssertFalse(line.lowercased().contains("quiesc"), line)
                XCTAssertFalse(line.lowercased().contains("drain"), line)
            }
        }
    }

    /// The endpoint's sentence is untouched by any of that: `summary` is a field
    /// of `GET /v1/fleet/quiesce` that scripts and the runbook read, so it keeps
    /// its machine spelling while the footer speaks plainly.
    func testTheSeamsOwnSummaryKeepsItsMachineSpelling() {
        let held = reading(quiesced: true, projects: [project("alpha", running: true, item: "a1")])

        XCTAssertEqual(held.summary, "quiesced, 1 run(s) still finishing")
    }

    // MARK: - What is still running

    /// A count says how much is left; this says what it is, which is what an
    /// operator deciding whether to wait actually needs.
    func testStillRunningNamesEachProjectAndItsItem() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: true,
            projects: [project("alpha", running: true, item: "a1"),
                       project("beta", running: true, item: "b7"),
                       project("gamma")]
        ))

        XCTAssertEqual(status.stillRunning, "alpha (a1), beta (b7)")
    }

    /// A running project whose item cannot be named is still named itself —
    /// dropping it would under-report what a quit would interrupt.
    func testStillRunningNamesAProjectWithNoItem() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: false, projects: [project("alpha", running: true, item: nil)]
        ))

        XCTAssertEqual(status.stillRunning, "alpha")
    }

    /// The footer is a 240pt column, so the list is capped — and says what the
    /// cap dropped, because a truncated list that looks complete is worse than a
    /// short one.
    func testStillRunningCapsTheListAndSaysWhatItDropped() {
        let busy = (1...5).map { project("p\($0)", running: true, item: "i\($0)") }

        let status = FleetQuiesceStatus(reading: reading(quiesced: true, projects: busy))

        XCTAssertEqual(status.stillRunning, "p1 (i1), p2 (i2), p3 (i3), +2 more")
    }

    /// A drained fleet shows one line rather than an empty second one.
    func testStillRunningIsNilWhenNothingIsRunning() {
        let status = FleetQuiesceStatus(reading: reading(quiesced: true, projects: [project("alpha")]))

        XCTAssertNil(status.stillRunning)
    }

    // MARK: - The drawer's project rows

    /// The drawer draws one row per open project, in the order the reading
    /// listed them — the list the footer's capped sentence is a summary of.
    func testEveryOpenProjectGetsARow() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: true,
            projects: [project("alpha", running: true, item: "a1"),
                       project("beta"),
                       project("gamma", running: true, item: "g9")]
        ))

        XCTAssertEqual(status.projects.map(\.name), ["alpha", "beta", "gamma"])
        XCTAssertEqual(status.projects.map(\.id), ["alpha", "beta", "gamma"])
        XCTAssertEqual(status.projects.map(\.isRunning), [true, false, true])
    }

    /// The item is what the row's mention opens, so it is carried as the id
    /// rather than folded into a sentence — a running project with no item to
    /// name is still a row, as it is still something a quit would interrupt.
    func testARowCarriesTheItemInFlight() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: false,
            projects: [project("alpha", running: true, item: "a1"),
                       project("beta", running: true, item: nil),
                       project("gamma")]
        ))

        XCTAssertEqual(status.projects.map(\.item), ["a1", nil, nil])
    }

    /// The row's line says the two things the fleet-wide count cannot: whether
    /// this project is what the fleet is still waiting on, and how much its
    /// queue is holding back.
    func testARowsLineSaysWhatTheProjectIsDoing() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: true,
            projects: [project("alpha", running: true, item: "a1"),
                       project("beta")]
        ))

        XCTAssertEqual(status.projects.map(\.line), ["running", "quiet"])
    }

    /// A queue *this* pause holds says so, and a resume picks up exactly those.
    /// A project that was already paused when the hold arrived never enters the
    /// ledger, so its row does not claim to be one of them.
    func testARowSaysWhetherThisPauseIsHoldingIt() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: true,
            projects: [project("alpha", running: true, item: "a1", heldByQuiesce: true, heldItems: 3),
                       project("beta", heldItems: 2)]
        ))

        XCTAssertEqual(status.projects[0].heldByQuiesce, true)
        XCTAssertEqual(status.projects[0].line, "running · queue held by this pause · 3 item(s) waiting")
        XCTAssertEqual(status.projects[1].heldByQuiesce, false)
        XCTAssertEqual(status.projects[1].line, "quiet · 2 item(s) waiting")
    }

    /// A queue holding nothing back says nothing about it — a row of zeros is
    /// how a list stops being read.
    func testARowIsSilentAboutAnEmptyHeldQueue() {
        let status = FleetQuiesceStatus(reading: reading(quiesced: false, projects: [project("alpha")]))

        XCTAssertEqual(status.projects.map(\.line), ["quiet"])
        XCTAssertEqual(status.projects.map(\.heldItems), [0])
    }

    /// A fleet with nothing open is a fleet, just an empty one: no rows, and the
    /// drawer says so rather than drawing a blank list.
    func testAFleetWithNoOpenProjectHasNoRows() {
        let status = FleetQuiesceStatus(reading: reading(quiesced: true, projects: []))

        XCTAssertTrue(status.projects.isEmpty)
        XCTAssertEqual(status.state, .held)
    }

    /// The list and the footer's capped sentence are read off one reading, so
    /// the two cannot come to disagree about which projects are still finishing.
    func testTheRowsAndTheCappedSentenceAgree() {
        let busy = (1...5).map { project("p\($0)", running: true, item: "i\($0)") }

        let status = FleetQuiesceStatus(reading: reading(quiesced: true, projects: busy))

        XCTAssertEqual(status.projects.filter(\.isRunning).count, 5)
        XCTAssertEqual(status.stillRunning, "p1 (i1), p2 (i2), p3 (i3), +2 more")
    }

    // MARK: - Busy and the pending quit

    /// A second click must not start a hold on top of a hold.
    func testTheControlIsDisabledWhileACallIsInFlight() {
        let idle = reading(quiesced: false, projects: [project("alpha")])

        XCTAssertTrue(FleetQuiesceStatus(reading: idle).canAct)
        XCTAssertFalse(FleetQuiesceStatus(reading: idle, isBusy: true).canAct)
    }

    /// No quit pending is the ordinary case and says nothing.
    func testNoQuitNoticeWithoutAPendingQuit() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: true, projects: [project("alpha", running: true, item: "a1")]
        ))

        XCTAssertNil(status.quitNotice)
    }

    /// A quit waiting on the drain is standing news: the app is going to close
    /// itself, and an operator who does not know that reads the fleet as merely
    /// held.
    func testQuitNoticeWhileStillDraining() {
        let status = FleetQuiesceStatus(
            reading: reading(quiesced: true, projects: [project("alpha", running: true, item: "a1")]),
            isQuittingWhenDrained: true
        )

        XCTAssertEqual(status.quitNotice, "quitting once it's quiet")
    }

    func testQuitNoticeOnceTheFleetIsQuiet() {
        let status = FleetQuiesceStatus(
            reading: reading(quiesced: true, projects: [project("alpha")]),
            isQuittingWhenDrained: true
        )

        XCTAssertEqual(status.quitNotice, "all quiet — quitting")
    }

    // MARK: - Help

    /// The one thing an operator needs to know before pressing it: it does not
    /// cost them the run in flight.
    func testHelpSaysARunInFlightIsNotInterrupted() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: false, projects: [project("alpha", running: true, item: "a1")]
        ))

        XCTAssertTrue(status.help.contains("finish at their own gate"), status.help)
    }

    /// The distinction the name cannot carry: this Pause also refuses new runs,
    /// where a project's Pause holds its queue and lets a fresh start through.
    func testHelpSaysThisPauseAlsoRefusesNewRuns() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: false, projects: [project("alpha", running: true, item: "a1")]
        ))

        XCTAssertTrue(status.help.contains("unlike a project's Pause"), status.help)
        XCTAssertTrue(status.help.contains("refuse new runs"), status.help)
    }

    /// A quiet fleet is the fact a restart turns on, so the hover says it in
    /// those words rather than leaving it to be inferred from a count of zero.
    func testHelpSaysWhenARestartStrandsNothing() {
        let status = FleetQuiesceStatus(reading: reading(quiesced: true, projects: [project("alpha")]))

        XCTAssertTrue(status.help.contains("strands nothing"), status.help)
    }

    func testHelpCountsWhatIsStillFinishing() {
        let status = FleetQuiesceStatus(reading: reading(
            quiesced: true,
            projects: [project("alpha", running: true, item: "a1"),
                       project("beta", running: true, item: "b1")]
        ))

        XCTAssertTrue(status.help.contains("2 run(s) are still finishing"), status.help)
    }

    // MARK: - The quit offer

    /// A drained fleet quits without a word — there is nothing to ask about.
    func testNoPromptWhenTheFleetIsDrained() {
        XCTAssertNil(FleetQuitPrompt(reading: reading(quiesced: false, projects: [project("alpha")])))
        XCTAssertNil(FleetQuitPrompt(reading: reading(quiesced: true, projects: [project("alpha")])))
    }

    func testPromptCountsTheRunsInFlight() throws {
        let one = try XCTUnwrap(FleetQuitPrompt(reading: reading(
            quiesced: false, projects: [project("alpha", running: true, item: "a1")]
        )))
        let two = try XCTUnwrap(FleetQuitPrompt(reading: reading(
            quiesced: false,
            projects: [project("alpha", running: true, item: "a1"),
                       project("beta", running: true, item: "b1")]
        )))

        XCTAssertEqual(one.message, "1 run is still in flight")
        XCTAssertEqual(two.message, "2 runs are still in flight")
    }

    /// What is at stake, said rather than implied: the cost of quitting now is a
    /// run that re-runs from scratch, and the operator cannot weigh that against
    /// waiting unless it is on the alert.
    func testPromptNamesWhatIsRunningAndWhatQuittingCosts() throws {
        let prompt = try XCTUnwrap(FleetQuitPrompt(reading: reading(
            quiesced: false, projects: [project("alpha", running: true, item: "a1")]
        )))

        XCTAssertTrue(prompt.detail.contains("alpha (a1)"), prompt.detail)
        XCTAssertTrue(prompt.detail.contains("re-runs from scratch"), prompt.detail)
    }

    /// The drain is the default and quitting now is still there — today's
    /// behaviour is an option, not a thing the offer takes away.
    func testPromptOffersTheDrainFirstAndQuitNowBesideIt() throws {
        let prompt = try XCTUnwrap(FleetQuitPrompt(reading: reading(
            quiesced: false, projects: [project("alpha", running: true, item: "a1")]
        )))

        XCTAssertEqual(prompt.choices, [.quiesceThenQuit, .quitNow, .cancel])
        XCTAssertEqual(prompt.choices.map(\.title),
                       ["Pause the Fleet and Quit When It's Quiet", "Quit Now", "Cancel"])
    }

    // MARK: - Helpers

    private func project(
        _ name: String, running: Bool = false, item: String? = nil,
        heldByQuiesce: Bool = false, heldItems: Int = 0
    ) -> FleetQuiesce.ProjectReading {
        FleetQuiesce.ProjectReading(
            id: name, name: name,
            status: running ? "running" : "idle",
            state: running ? "running" : "idle",
            running: running, item: item, heldItems: heldItems,
            heldByQuiesce: heldByQuiesce, action: nil
        )
    }

    /// A reading built the way `FleetQuiesce.reading()` builds one — `running`
    /// and `drained` counted off the projects rather than stated, so no case can
    /// assert a fleet the seam could not produce.
    private func reading(quiesced: Bool, projects: [FleetQuiesce.ProjectReading]) -> FleetQuiesce.Reading {
        let running = projects.filter(\.running).count
        return FleetQuiesce.Reading(
            quiesced: quiesced, drained: running == 0, running: running, projects: projects
        )
    }
}
