import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/runs` — the index of runs this server has tracked since launch. A
/// driver that lost a `runId` (or attached to an app already working) needs a way
/// to find the runs in flight, so this lists them newest first with enough to
/// address each one: its id, item, project and current state. Exercised over a
/// real loopback socket, like the other control-API tests.
@MainActor
final class KiteloopControlServerRunsListTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var server: KiteloopControlServer { harness.server }
    /// The record-backed servers `startServerWithRecords` hands out, so tearDown
    /// closes their listeners too.
    private var extraHarnesses: [ControlServerHarness] = []
    private let token = "control-runs-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-runs")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        for extra in extraHarnesses { extra.stop() }
        extraHarnesses = []
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Listing

    /// Runs live in memory, so a freshly launched app lists an empty array rather
    /// than 404 — a poller can treat "no runs" as a normal state.
    func testEmptyListWhenNothingHasRun() async throws {
        let (status, body) = try await harness.get("/v1/runs")

        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["runs"] as? [[String: Any]])?.count, 0)
    }

    func testListsTrackedRunWithItemProjectAndStartTime() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let startedAt = Date(timeIntervalSince1970: 1_770_000_000)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1", title: "Ship the thing", startedAt: startedAt))

        let (status, body) = try await harness.get("/v1/runs")

        XCTAssertEqual(status, 200)
        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0]["runId"] as? String, "run-1")
        XCTAssertEqual(runs[0]["item"] as? String, "item-1")
        XCTAssertEqual(runs[0]["title"] as? String, "Ship the thing")
        XCTAssertEqual(runs[0]["project"] as? String, "alpha")
        XCTAssertEqual(runs[0]["startedAt"] as? String, ISO8601DateFormatter().string(from: startedAt))
        XCTAssertEqual(runs[0]["state"] as? String, "running")
    }

    /// Newest first: the run a driver most likely cares about is at index 0.
    func testOrdersNewestFirstAcrossProjects() async throws {
        let alpha = try registerProject(named: "alpha", backlog: "- [ ] item-1 | First | active")
        let beta = try registerProject(named: "beta", backlog: "- [ ] item-2 | Second | active")
        // This server keeps its runs in memory alone, so a live fixture never
        // reaches `RunRecordStore` and a fixed epoch cannot age out of it.
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        server.track(.init(runId: "older", projectID: alpha, itemId: "item-1", title: "First", startedAt: base))
        server.track(.init(runId: "newer", projectID: beta, itemId: "item-2", title: "Second", startedAt: base.addingTimeInterval(60)))

        let (_, body) = try await harness.get("/v1/runs")

        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.map { $0["runId"] as? String }, ["newer", "older"])
        XCTAssertEqual(runs.map { $0["project"] as? String }, ["beta", "alpha"])
    }

    // MARK: - State

    /// The state is derived live from the item, not frozen at tracking time, so a
    /// run that reached the human gate shows up as such in the list.
    func testStateReflectsAnItemWaitingAtTheApprovalGate() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Needs sign-off | awaiting-approval")
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1", title: "Needs sign-off", startedAt: Date()))

        let (_, body) = try await harness.get("/v1/runs")

        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs[0]["state"] as? String, "awaiting_approval")
    }

    /// Closing a project takes its session out of the registry, so its runs can no
    /// longer be inspected — they stay listed (with the project name) but read
    /// `unknown` rather than claiming to still be running.
    func testRunOfAClosedProjectReadsUnknown() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1", title: "Ship the thing", startedAt: Date()))
        await registry.unregister(projectID: projectID)

        let (_, body) = try await harness.get("/v1/runs")

        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs[0]["project"] as? String, "alpha")
        XCTAssertEqual(runs[0]["state"] as? String, "unknown")
    }

    // MARK: - Finalising

    /// The failure this exists for: `finished` used to be derived from the
    /// autopilot's in-memory results, which the *next* run clears — so runs whose
    /// work had merged days earlier went back to reading `running`. The record is
    /// closed once, and a closed record stays closed and keeps its outcome.
    func testFinishedRunStaysFinishedAfterTheAutopilotClearsItsResults() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        autopilot.stageResultForTesting(
            BacklogAutopilot.ItemResult(id: "item-1", title: "Ship the thing", outcome: .done, duration: 42)
        )
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1", title: "Ship the thing", startedAt: Date()))

        let (_, before) = try await harness.get("/v1/runs")
        XCTAssertEqual(try firstRun(before)["state"] as? String, "finished")

        autopilot.clearResultsForTesting()   // what starting the next run does

        let (_, after) = try await harness.get("/v1/runs")
        XCTAssertEqual(try firstRun(after)["state"] as? String, "finished")

        // The other half of "closed": it can still say how it ended.
        let (status, result) = try await harness.get("/v1/runs/run-1/result")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(result["outcome"] as? String, "done")
        XCTAssertEqual(result["durationSec"] as? Int, 42)
    }

    /// A cancelled run leaves the item back at `ready` and, when it was cut short
    /// before recording itself, nothing else behind. Nothing is driving it any
    /// more, so it is finalised rather than left reading `running` for the rest of
    /// the app's life — the case observed in production.
    func testCancelledRunIsFinalisedWithItsOutcome() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Called off | ready")
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1", title: "Called off", startedAt: Date()))

        let (_, body) = try await harness.get("/v1/runs")
        XCTAssertEqual(try firstRun(body)["state"] as? String, "finished")

        let (status, result) = try await harness.get("/v1/runs/run-1/result")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(result["outcome"] as? String, "cancelled")
    }

    /// A stalled or timed-out run ends with the item blocked. Same rule, and the
    /// record says which ending it was rather than only that it is over.
    func testStalledRunIsFinalisedAsBlocked() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Stalled out | blocked")
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1", title: "Stalled out", startedAt: Date()))

        let (_, body) = try await harness.get("/v1/runs")
        XCTAssertEqual(try firstRun(body)["state"] as? String, "finished")

        let (status, result) = try await harness.get("/v1/runs/run-1/result")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(result["outcome"] as? String, "blocked")
        XCTAssertFalse((result["reason"] as? String ?? "").isEmpty, "a blocked ending has to say why")
    }

    /// With every queue drained, nothing is executing — so nothing reads `running`.
    func testIdleQueuesLeaveNoRunReadingRunning() async throws {
        let alpha = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Merged | done")
        let beta = try registerProject(named: "beta", backlog: "- [ ] item-2 | Handed back | ready")
        server.track(.init(runId: "run-1", projectID: alpha, itemId: "item-1", title: "Merged", startedAt: Date()))
        server.track(.init(runId: "run-2", projectID: beta, itemId: "item-2", title: "Handed back", startedAt: Date()))

        let (_, body) = try await harness.get("/v1/runs")

        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.compactMap { $0["state"] as? String }, ["finished", "finished"])
    }

    /// `/health` and this listing answer from the same set: what the listing shows
    /// as open is exactly what `activeRuns` counts, so a driver can't read one
    /// number here and a different one there.
    func testActiveRunsCountsExactlyWhatTheListingShowsAsOpen() async throws {
        let alpha = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Working | active")
        let beta = try registerProject(named: "beta", backlog: "- [ ] item-2 | Merged | done")
        server.track(.init(runId: "run-1", projectID: alpha, itemId: "item-1", title: "Working", startedAt: Date()))
        server.track(.init(runId: "run-2", projectID: beta, itemId: "item-2", title: "Merged", startedAt: Date()))

        let (_, body) = try await harness.get("/v1/runs")
        let open = try XCTUnwrap(body["runs"] as? [[String: Any]])
            .filter { ($0["state"] as? String) != "finished" }
        XCTAssertEqual(open.count, 1)

        let (_, health) = try await harness.get("/health", bearer: nil)
        XCTAssertEqual(health["activeRuns"] as? Int, open.count)
    }

    // MARK: - What a run is costing

    /// The meter a headless driver paces itself by. The Autopilot panel has shown
    /// item spend against the effective ceiling since `ui-autopilot-cost-readout`;
    /// a driver with no window open could only learn what a run cost afterwards,
    /// from the metric records, by which point the money is spent.
    func testListingCarriesSpendSoFarAgainstTheCeilingTheRunIsMeasuredAgainst() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        // The item's own history of $3.00, plus half again.
        stageRunInFlight(autopilot, runId: "run-1", itemId: "item-1", spentUSD: 1.87, capUSD: 4.50,
                         prediction: .init(usd: 3.00, source: .ownHistory))
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))

        let (_, body) = try await harness.get("/v1/runs")

        let run = try firstRun(body)
        XCTAssertEqual(run["state"] as? String, "running")
        XCTAssertEqual(run["costUSD"] as? Double, 1.87)
        // The ceiling the run is actually measured against, not the flat cap in
        // settings — a driver pacing itself against $2.00 would call this run
        // over budget while the governor is perfectly happy with it.
        XCTAssertEqual(run["costCapUSD"] as? Double, 4.50)
        XCTAssertEqual(run["predictionSource"] as? String, "own history")
    }

    /// The `ledger-charges-phantom-spend` lesson on the API surface: a run whose
    /// spend nothing could be attributed to did not cost $0. A reported zero would
    /// have a driver pace a queue against a meter that never moves — absent says
    /// "not known", which is the fact.
    func testRunWithNoAttributableSpendReportsNoCostRatherThanZero() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        // Picked up, ceiling fixed, but no watchdog sample has landed yet.
        stageRunInFlight(autopilot, runId: "run-1", itemId: "item-1", spentUSD: 0, capUSD: 4.50)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))

        let (_, body) = try await harness.get("/v1/runs")

        let run = try firstRun(body)
        XCTAssertNil(run["costUSD"], "an unmeasured run must not read as a free one")
        // The ceiling is known from pickup, so it is reported from the first poll.
        XCTAssertEqual(run["costCapUSD"] as? Double, 4.50)
        // Nothing was predicted, so the flat cap is the whole story and there is
        // no rung to name.
        XCTAssertNil(run["predictionSource"])
    }

    /// An uncapped run has no ceiling to report, which is not a ceiling of zero —
    /// the same distinction the panel draws by showing the spend alone.
    func testUncappedRunReportsItsSpendWithoutACap() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        stageRunInFlight(autopilot, runId: "run-1", itemId: "item-1", spentUSD: 12.40, capUSD: nil)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))

        let (_, body) = try await harness.get("/v1/runs")

        let run = try firstRun(body)
        XCTAssertEqual(run["costUSD"] as? Double, 12.40)
        XCTAssertNil(run["costCapUSD"])
    }

    /// The 202 a poll loop sits on carries the meter too, so watching a run and
    /// reading its bill are the same two fields rather than two different places.
    func testPendingResultCarriesSpendSoFar() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        stageRunInFlight(autopilot, runId: "run-1", itemId: "item-1", spentUSD: 1.87, capUSD: 4.50,
                         prediction: .init(usd: 3.00, source: .ownHistory))
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))

        let (status, body) = try await harness.get("/v1/runs/run-1/result")

        XCTAssertEqual(status, 202)
        XCTAssertEqual(body["costUSD"] as? Double, 1.87)
        XCTAssertEqual(body["costCapUSD"] as? Double, 4.50)
        XCTAssertEqual(body["predictionSource"] as? String, "own history")
    }

    /// The bill, once the run has landed: the figure the run *recorded*, which is
    /// the final one — the in-flight sample trails the last turn by up to a
    /// watchdog tick and the item is charged after it — beside the ceiling it was
    /// measured against. The ceiling has to be kept rather than re-derived: the
    /// governor clears it the moment the item ends, and this run's own cost is now
    /// the first rung of the chain that would predict it again.
    func testFinishedResultCarriesTheRecordedCostAndTheCeilingItWasMeasuredAgainst() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let store = makeMetricStore()
        autopilot.stageMetricStoreForTesting(store)
        stageRunInFlight(autopilot, runId: "run-1", itemId: "item-1", spentUSD: 1.87, capUSD: 4.50,
                         prediction: .init(usd: 3.00, source: .ownHistory))
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        _ = try await harness.get("/v1/runs")   // a driver watching it work

        landRun(autopilot, itemId: "item-1", title: "Ship the thing")
        store.append(makeRecord(itemID: "item-1", executionID: "run-1", costUSD: 2.13,
                                predictionSource: "own history"))

        let (status, body) = try await harness.get("/v1/runs/run-1/result")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["outcome"] as? String, "done")
        XCTAssertEqual(body["costUSD"] as? Double, 2.13, "the recorded cost, not the last live sample")
        XCTAssertEqual(body["costCapUSD"] as? Double, 4.50)
        XCTAssertEqual(body["predictionSource"] as? String, "own history")
    }

    /// Spend is attributed by execution id, never by item: an item that has run
    /// before has records this run did not write, and reporting one of those as
    /// this run's cost would charge it for a different attempt — the phantom
    /// spend the ledger already learned not to invent.
    func testAnEarlierAttemptAtTheSameItemIsNotChargedToThisRun() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let store = makeMetricStore()
        autopilot.stageMetricStoreForTesting(store)
        // Last night's expensive attempt at the same item.
        store.append(makeRecord(itemID: "item-1", executionID: "run-0", costUSD: 9.99,
                                predictionSource: "own history"))
        // This run reached the gate without recording anything of its own.
        landRun(autopilot, itemId: "item-1", title: "Ship the thing")
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))

        let (status, body) = try await harness.get("/v1/runs/run-1/result")

        XCTAssertEqual(status, 200)
        XCTAssertNil(body["costUSD"], "run-0's bill is not run-1's")
        XCTAssertNil(body["predictionSource"])
    }

    // MARK: - How the run went

    /// How long an item took and how the judge scored it are what a night of
    /// unattended work is read for. The record holds both and `/result` returns
    /// both, so a listing that dropped them charged a driver one extra request
    /// per run to learn what the row it already had could have said.
    func testHistoricalRowCarriesItsDurationAndTheJudgesVerdict() async throws {
        var scored = record(runId: "run-scored", projectID: "/tmp/alpha")
        scored.qualityScore = 4.25
        scored.judgeDimensions = ["verify_passed": 1.0, "scope_respected": 0.5]
        let seeded = try await startServerWithRecords([scored])

        let (status, body) = try await seeded.get("/v1/runs")

        XCTAssertEqual(status, 200)
        let run = try firstRun(body)
        XCTAssertEqual(run["endedAt"] as? String, ISO8601DateFormatter().string(from: try XCTUnwrap(scored.endedAt)),
                       "when it ended is what places durationSec in time")
        XCTAssertEqual(run["durationSec"] as? Int, 42)
        XCTAssertEqual(run["qualityScore"] as? Double, 4.25)
        XCTAssertEqual(run["judgeDimensions"] as? [String: Double],
                       ["verify_passed": 1.0, "scope_respected": 0.5])
        XCTAssertNil(run["judgeUnavailable"])
    }

    /// `outcome: "blocked"` is the same word for a reviewer rejection, a run that
    /// ran out of budget and one `closeRun` never heard an ending from. The record
    /// holds the sentence that tells them apart and `/result` returns it, so a
    /// listing that dropped it made reading back a night one request per blocked
    /// run.
    func testBlockedRowSaysWhyItWasBlocked() async throws {
        var blocked = record(runId: "run-blocked", projectID: "/tmp/alpha")
        blocked.outcome = .blocked
        blocked.reason = "reviewer rejected: AC 3 is unimplemented"
        let seeded = try await startServerWithRecords([blocked])

        let (status, body) = try await seeded.get("/v1/runs")

        XCTAssertEqual(status, 200)
        let run = try firstRun(body)
        XCTAssertEqual(run["outcome"] as? String, "blocked")
        XCTAssertEqual(run["reason"] as? String, "reviewer rejected: AC 3 is unimplemented")
    }

    /// Absent rather than null when the record kept none — the rule every other
    /// optional field on the row follows. A run that simply finished has nothing
    /// to explain, and an empty string would read as an explanation nobody wrote.
    func testRowWithNothingToExplainCarriesNoReason() async throws {
        let seeded = try await startServerWithRecords([record(runId: "run-1", projectID: "/tmp/alpha")])

        let (status, body) = try await seeded.get("/v1/runs")

        XCTAssertEqual(status, 200)
        XCTAssertNil(try firstRun(body)["reason"])
    }

    /// The judge didn't deliver a score: the row says so, and says why, rather
    /// than reporting a number nobody produced. `judgeDimensions` belongs to a
    /// score, so it goes with it.
    func testRowWhoseJudgeDeliveredNothingCarriesTheReasonInsteadOfAScore() async throws {
        var unjudged = record(runId: "run-unjudged", projectID: "/tmp/alpha")
        unjudged.judgeUnavailable = "judge returned no verdict"
        let seeded = try await startServerWithRecords([unjudged])

        let (status, body) = try await seeded.get("/v1/runs")

        XCTAssertEqual(status, 200)
        let run = try firstRun(body)
        XCTAssertEqual(run["judgeUnavailable"] as? String, "judge returned no verdict")
        XCTAssertNil(run["qualityScore"])
        XCTAssertNil(run["judgeDimensions"])
    }

    /// A record from before the judge existed has neither a score nor a reason.
    /// Absent rather than null, the same rule the cost fields follow: an invented
    /// zero would read as "scored badly" rather than "never scored".
    func testRowWithNoVerdictAtAllCarriesNoneOfTheJudgeFields() async throws {
        let seeded = try await startServerWithRecords([record(runId: "run-1", projectID: "/tmp/alpha")])

        let (status, body) = try await seeded.get("/v1/runs")

        XCTAssertEqual(status, 200)
        let run = try firstRun(body)
        XCTAssertNil(run["qualityScore"])
        XCTAssertNil(run["judgeDimensions"])
        XCTAssertNil(run["judgeUnavailable"])
    }

    /// A live run has not ended, so it has no duration, no verdict and nothing to
    /// explain — and a driver must not read any of them from a row that is still
    /// moving.
    func testLiveRowCarriesNeitherADurationNorAVerdict() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Working | active")
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Working", startedAt: Date()))

        let (_, body) = try await harness.get("/v1/runs")

        let run = try firstRun(body)
        XCTAssertEqual(run["historical"] as? Bool, false)
        XCTAssertNil(run["reason"])
        XCTAssertNil(run["endedAt"])
        XCTAssertNil(run["durationSec"])
        XCTAssertNil(run["qualityScore"])
        XCTAssertNil(run["judgeDimensions"])
        XCTAssertNil(run["judgeUnavailable"])
    }

    // MARK: - A run that ended while this process is still up

    /// The gap this closes: a run that ended while the app was still running was
    /// listed as `finished` and nothing else — no outcome, no duration, no score
    /// — so the morning after an unattended night the listing was a column of
    /// finished runs with nothing to read off it, and quitting the app was the
    /// only way to see how the night had gone. The record `finalizeEndedRuns`
    /// wrote is already on disk by the time this handler runs, and it says the
    /// same as `/result` does for the same run.
    func testRunThatEndedInThisSessionIsListedWithHowItEnded() async throws {
        let seeded = try await startServerWithRecords([])
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let metrics = makeMetricStore()
        autopilot.stageMetricStoreForTesting(metrics)
        metrics.append(makeRecord(itemID: "item-1", executionID: "run-1", costUSD: 2.13,
                                  qualityScore: 4.25,
                                  judgeDimensions: ["verify_passed": 1.0, "scope_respected": 0.5]))
        landRun(autopilot, itemId: "item-1", title: "Ship the thing")
        seeded.server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                                  title: "Ship the thing", startedAt: Date()))

        let (status, body) = try await seeded.get("/v1/runs")
        let (_, result) = try await seeded.get("/v1/runs/run-1/result")

        XCTAssertEqual(status, 200)
        let run = try firstRun(body)
        XCTAssertEqual(run["state"] as? String, "finished")
        // Still answered from what this process is tracking, not from disk —
        // where the row came from hasn't changed, only what it says.
        XCTAssertEqual(run["historical"] as? Bool, false)
        XCTAssertEqual(run["outcome"] as? String, "done")
        // The wall clock the run closed at, which `durationSec` — the autopilot's
        // measure of the item — cannot stand in for.
        XCTAssertNotNil(run["endedAt"] as? String)
        XCTAssertEqual(run["durationSec"] as? Int, 42)
        XCTAssertEqual(run["qualityScore"] as? Double, 4.25)
        XCTAssertEqual(run["judgeDimensions"] as? [String: Double],
                       ["verify_passed": 1.0, "scope_respected": 0.5])
        // The point of the row: it says what a request per run used to have to.
        XCTAssertEqual(run["outcome"] as? String, result["outcome"] as? String)
        XCTAssertEqual(run["endedAt"] as? String, result["endedAt"] as? String)
        XCTAssertEqual(run["durationSec"] as? Int, result["durationSec"] as? Int)
        XCTAssertEqual(run["qualityScore"] as? Double, result["qualityScore"] as? Double)
    }

    /// `blocked` is one word for a reviewer rejection, a run that ran out of
    /// budget and one nothing recorded an ending for. A run blocked tonight has
    /// to say which it was in the listing, on the same terms as one read back
    /// next week — otherwise telling two of them apart is a request each.
    func testRunBlockedInThisSessionCarriesItsReasonInTheListing() async throws {
        let seeded = try await startServerWithRecords([])
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | blocked")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        autopilot.stageResultForTesting(BacklogAutopilot.ItemResult(
            id: "item-1", title: "Ship the thing",
            outcome: .blocked("reviewer rejected: AC 3 is unimplemented"), duration: 42))
        seeded.server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                                  title: "Ship the thing", startedAt: Date()))

        let (status, body) = try await seeded.get("/v1/runs")

        XCTAssertEqual(status, 200)
        let run = try firstRun(body)
        XCTAssertEqual(run["outcome"] as? String, "blocked")
        XCTAssertEqual(run["reason"] as? String, "reviewer rejected: AC 3 is unimplemented")
    }

    /// A run that has not ended has none of this, and its record is no way in:
    /// `track` opens one as the run begins, and an open record holds no outcome,
    /// no duration and no verdict to read. Absent, never null.
    func testRunStillWorkingCarriesNoEndingThoughItsRecordIsAlreadyOpen() async throws {
        let seeded = try await startServerWithRecords([])
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Working | active")
        seeded.server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                                  title: "Working", startedAt: Date()))

        let (status, body) = try await seeded.get("/v1/runs")

        XCTAssertEqual(status, 200)
        let run = try firstRun(body)
        XCTAssertEqual(run["state"] as? String, "running")
        XCTAssertNil(run["outcome"])
        XCTAssertNil(run["reason"])
        XCTAssertNil(run["endedAt"])
        XCTAssertNil(run["durationSec"])
        XCTAssertNil(run["qualityScore"])
        XCTAssertNil(run["judgeDimensions"])
        XCTAssertNil(run["judgeUnavailable"])
    }

    /// No score is not a score of zero, here as anywhere: the row says the judge
    /// delivered nothing and why, on exactly the terms a historical row does.
    func testRunEndedInThisSessionWithNoScoreSaysWhyInsteadOfReportingOne() async throws {
        let seeded = try await startServerWithRecords([])
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let metrics = makeMetricStore()
        autopilot.stageMetricStoreForTesting(metrics)
        metrics.append(makeRecord(itemID: "item-1", executionID: "run-1", costUSD: 2.13,
                                  judgeUnavailable: "judge returned no verdict"))
        landRun(autopilot, itemId: "item-1", title: "Ship the thing")
        seeded.server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                                  title: "Ship the thing", startedAt: Date()))

        let (status, body) = try await seeded.get("/v1/runs")

        XCTAssertEqual(status, 200)
        let run = try firstRun(body)
        XCTAssertEqual(run["judgeUnavailable"] as? String, "judge returned no verdict")
        XCTAssertNil(run["qualityScore"])
        XCTAssertNil(run["judgeDimensions"])
    }

    /// The whole claim, end to end: the same run listed by the process that ran
    /// it and by the next launch reads the same, and `historical` is the only
    /// thing that differs. Both halves emit these through one helper over the
    /// same record, so they cannot drift apart.
    func testTheSameRunReadsTheSameBeforeAndAfterARestart() async throws {
        let recordsURL = tempDir.appendingPathComponent("control-runs-restart.jsonl")
        let seeded = try await startServer(over: RunRecordStore(url: recordsURL))
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let metrics = makeMetricStore()
        autopilot.stageMetricStoreForTesting(metrics)
        metrics.append(makeRecord(itemID: "item-1", executionID: "run-1", costUSD: 2.13,
                                  qualityScore: 4.25))
        landRun(autopilot, itemId: "item-1", title: "Ship the thing")
        seeded.server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                                  title: "Ship the thing", startedAt: Date()))

        let (_, before) = try await seeded.get("/v1/runs")
        // A second server over the same file, which is what a restart is: the
        // run is in nobody's `runs`, so it is answered from the record.
        let restarted = try await startServer(over: RunRecordStore(url: recordsURL))
        let (status, after) = try await restarted.get("/v1/runs")

        XCTAssertEqual(status, 200)
        let live = try firstRun(before)
        let historical = try firstRun(after)
        XCTAssertEqual(live["outcome"] as? String, historical["outcome"] as? String)
        XCTAssertNotNil(live["endedAt"] as? String)
        XCTAssertEqual(live["endedAt"] as? String, historical["endedAt"] as? String)
        XCTAssertEqual(live["durationSec"] as? Int, historical["durationSec"] as? Int)
        XCTAssertEqual(live["qualityScore"] as? Double, historical["qualityScore"] as? Double)
        XCTAssertEqual(live["historical"] as? Bool, false)
        XCTAssertEqual(historical["historical"] as? Bool, true)
    }

    // MARK: - Narrowing to one project

    /// The whole point of `?project=`: a driver watching one project of a
    /// portfolio asks about that project rather than pulling every project's runs
    /// and filtering them itself.
    func testProjectNarrowsToThatProjectsLiveRuns() async throws {
        let alpha = try registerProject(named: "alpha", backlog: "- [ ] item-1 | First | active")
        let beta = try registerProject(named: "beta", backlog: "- [ ] item-2 | Second | active")
        server.track(.init(runId: "run-alpha", projectID: alpha, itemId: "item-1", title: "First", startedAt: Date()))
        server.track(.init(runId: "run-beta", projectID: beta, itemId: "item-2", title: "Second", startedAt: Date()))

        let (status, body) = try await harness.get("/v1/runs?project=beta")

        XCTAssertEqual(status, 200)
        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.map { $0["runId"] as? String }, ["run-beta"])
    }

    /// A project that has been closed since is still a project that ran things.
    /// Every other history endpoint 409s on one that isn't open; here that would
    /// make a run record unreachable by the only name a driver has for it, so this
    /// answers 200 from the records instead.
    func testProjectThatIsNotOpenAnswersFromItsRecordsRatherThan409() async throws {
        let seeded = try await startServerWithRecords([
            record(runId: "run-alpha", projectID: "/tmp/alpha"),
            record(runId: "run-beta", projectID: "/tmp/beta")
        ])

        let (status, body) = try await seeded.get("/v1/runs?project=alpha")

        XCTAssertEqual(status, 200)
        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.map { $0["runId"] as? String }, ["run-alpha"])
        XCTAssertEqual(runs.first?["historical"] as? Bool, true)
    }

    /// The same closed project by its full path — the other spelling the registry
    /// accepts while a project is open, which has to keep working once it isn't.
    func testClosedProjectResolvesByPathAsWellAsFolderName() async throws {
        let seeded = try await startServerWithRecords([
            record(runId: "run-alpha", projectID: "/tmp/alpha"),
            record(runId: "run-beta", projectID: "/tmp/beta")
        ])

        let (status, body) = try await seeded.get("/v1/runs?project=/tmp/alpha/")

        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["runs"] as? [[String: Any]])?.map { $0["runId"] as? String }, ["run-alpha"])
    }

    /// Narrowing to a project nothing has ever run is an empty list, not an error:
    /// "no runs" is the answer, and a poller can act on it.
    func testUnknownProjectIsAnEmptyListRatherThanAnError() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] item-1 | First | active")

        let (status, body) = try await harness.get("/v1/runs?project=nowhere")

        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["runs"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - Bounding the history

    /// Without a bound every call dragged the whole retained history — up to 500
    /// records — through the socket, on every tick of a poll loop.
    func testLimitBoundsTheHistoricalRowsNewestFirst() async throws {
        let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
        let seeded = try await startServerWithRecords((0..<6).map {
            record(runId: "run-\($0)", projectID: "/tmp/alpha",
                   startedAt: base.addingTimeInterval(Double($0) * 60))
        })

        let (status, body) = try await seeded.get("/v1/runs?limit=5")

        XCTAssertEqual(status, 200)
        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.map { $0["runId"] as? String },
                       ["run-5", "run-4", "run-3", "run-2", "run-1"],
                       "the newest five, not an arbitrary five")
    }

    /// An absent `limit` is the same default the other history endpoints apply.
    func testAbsentLimitDefaultsToTwentyRecords() async throws {
        let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
        let seeded = try await startServerWithRecords((0..<25).map {
            record(runId: "run-\($0)", projectID: "/tmp/alpha",
                   startedAt: base.addingTimeInterval(Double($0) * 60))
        })

        let (status, body) = try await seeded.get("/v1/runs")

        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["runs"] as? [[String: Any]])?.count, 20)
    }

    /// `limit` pages the history, never the live runs: a driver polling for what is
    /// in flight must not have it hidden behind a page of finished ones, however
    /// small a limit it asked for or however much newer the history is.
    func testLiveRunStaysListedBehindAFullPageOfNewerHistory() async throws {
        let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
        let seeded = try await startServerWithRecords((0..<3).map {
            record(runId: "history-\($0)", projectID: "/tmp/alpha",
                   startedAt: base.addingTimeInterval(Double($0 + 1) * 3600))
        })
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Working | active")
        seeded.server.track(.init(runId: "run-live", projectID: projectID, itemId: "item-1",
                         title: "Working", startedAt: base))

        let (status, body) = try await seeded.get("/v1/runs?limit=1")

        XCTAssertEqual(status, 200)
        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.map { $0["runId"] as? String }, ["history-2", "run-live"])
        XCTAssertEqual(runs.last?["state"] as? String, "running")
    }

    // MARK: - Errors

    func testRequiresBearerToken() async throws {
        let (status, body) = try await harness.get("/v1/runs", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    /// The same 400 and the same wording as `/v1/metrics` and `/v1/grooming` —
    /// a driver that learned the rule on one listing knows it on all of them.
    func testRejectsALimitOutsideTheRangeWithTheSameMessageTheOtherListingsUse() async throws {
        for raw in ["0", "201", "abc", "-3"] {
            let (status, body) = try await harness.get("/v1/runs?limit=\(raw)")

            XCTAssertEqual(status, 400, "limit=\(raw) should be refused")
            XCTAssertEqual(body["error"] as? String, "\"limit\" must be an integer in 1...200")
        }
    }

    // MARK: - Described

    /// The document is what a generated client is built from, so a parameter the
    /// endpoint takes and the document omits is one no client can send.
    func testOpenAPIDescribesBothQueryParameters() async throws {
        let (status, body) = try await harness.get("/v1/openapi.json")

        XCTAssertEqual(status, 200)
        let paths = try XCTUnwrap(body["paths"] as? [String: [String: Any]])
        let operation = try XCTUnwrap(paths["/v1/runs"]?["get"] as? [String: Any])
        let parameters = try XCTUnwrap(operation["parameters"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: parameters.compactMap { parameter -> (String, [String: Any])? in
            guard let name = parameter["name"] as? String else { return nil }
            return (name, parameter)
        })

        XCTAssertEqual(byName["project"]?["in"] as? String, "query")
        XCTAssertEqual(byName["project"]?["required"] as? Bool, false)
        XCTAssertEqual(byName["limit"]?["in"] as? String, "query")
        XCTAssertEqual(byName["limit"]?["required"] as? Bool, false)
        XCTAssertNotNil((operation["responses"] as? [String: Any])?["400"],
                        "the 400 a bad limit answers with has to be described")
    }

    // MARK: - Helpers

    /// A second control server, over its own run-record file seeded with
    /// `records` — the only way to exercise the historical half of the listing,
    /// since the shared server deliberately keeps its runs in memory alone rather
    /// than writing into the developer's real history.
    @discardableResult
    private func startServerWithRecords(
        _ records: [PersistedRunRecord]
    ) async throws -> ControlServerHarness {
        let store = RunRecordStore(url: tempDir.appendingPathComponent("control-runs-\(UUID().uuidString).jsonl"))
        for record in records { store.upsert(record) }
        return try await startServer(over: store)
    }

    /// A control server over a record store the caller holds — how a test runs
    /// two servers over the same file, which is what a restart actually is.
    private func startServer(over store: RunRecordStore) async throws -> ControlServerHarness {
        let extra = try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0, runRecords: store)
        }
        extraHarnesses.append(extra)
        return extra
    }

    /// A finished record — what an earlier launch left behind, which is all the
    /// listing needs from one.
    ///
    /// Dated relative to now, not at a fixed epoch: `RunRecordStore.upsert`
    /// applies both retention bounds on every write, so a hard-coded date ages
    /// past `retentionAge` and each fixture is dropped the instant it is stored —
    /// the seeded server then answers with an empty history and every assertion
    /// here fails for a reason that has nothing to do with the listing. Whole
    /// seconds because the record is encoded as ISO-8601 without fractional ones,
    /// and the callers' `+ 60` / `* 3600` offsets are what the newest-first and
    /// limit assertions turn on.
    private func record(
        runId: String,
        projectID: String,
        startedAt: Date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
    ) -> PersistedRunRecord {
        var record = PersistedRunRecord(runId: runId, projectID: projectID, itemID: "item-1",
                                        title: "Ship the thing", startedAt: startedAt)
        record.outcome = .done
        record.endedAt = startedAt.addingTimeInterval(42)
        record.durationSec = 42
        return record
    }

    /// The one run in a single-run listing, unwrapped so a test asserts on its
    /// state rather than on a chain of optionals.
    private func firstRun(_ body: [String: Any]) throws -> [String: Any] {
        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        return try XCTUnwrap(runs.first)
    }

    /// Puts the autopilot into the state a live run reaches by its first watchdog
    /// sample: it owns this execution, its queue is running, and the governor
    /// holds the item's spend, the ceiling `beginItem` fixed and the forecast
    /// behind it.
    private func stageRunInFlight(
        _ autopilot: BacklogAutopilot,
        runId: String,
        itemId: String,
        spentUSD: Double,
        capUSD: Double?,
        prediction: CostGovernor.Prediction? = nil
    ) {
        autopilot.stageExecutionIDForTesting(runId)
        autopilot.stageRunForTesting(
            status: .running(itemIndex: 0, total: 1),
            queue: [BacklogItem(id: itemId, title: "Ship the thing", verify: nil, status: .active, type: .local)]
        )
        autopilot.stageInFlightCostForTesting(spentUSD: spentUSD, capUSD: capUSD, prediction: prediction)
    }

    /// What the end of an item leaves behind: a recorded result, an idle queue,
    /// and a governor whose in-flight figures have been cleared — the state in
    /// which the ceiling the run was measured against is no longer readable
    /// anywhere but the record the server kept while it was live.
    private func landRun(_ autopilot: BacklogAutopilot, itemId: String, title: String) {
        autopilot.stageResultForTesting(
            BacklogAutopilot.ItemResult(id: itemId, title: title, outcome: .done, duration: 42)
        )
        autopilot.stageInFlightCostForTesting(spentUSD: 0, capUSD: nil)
        autopilot.stageRunForTesting(status: .idle, queue: [])
        autopilot.stageExecutionIDForTesting(nil)
    }

    /// A learning-engine store over the temp directory, so a test never appends to
    /// the developer's real `~/.kiteloop/task-metrics.jsonl`.
    private func makeMetricStore() -> TaskMetricStore {
        TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl")
        )
    }

    /// The record a finished run writes — only the fields these tests read.
    private func makeRecord(
        itemID: String,
        executionID: String,
        costUSD: Double,
        predictionSource: String? = nil,
        qualityScore: Double? = nil,
        judgeDimensions: [String: Double]? = nil,
        judgeUnavailable: String? = nil
    ) -> TaskMetricRecord {
        // An hour ago, ending a minute later — the same relative dating as the run
        // fixtures, so the pair stays coherent with the 60s duration below.
        let startedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
        var record = TaskMetricRecord(
            projectPath: "/tmp/alpha",
            projectName: "alpha",
            itemID: itemID,
            title: "Ship the thing",
            epic: "Work",
            declaredSize: "M",
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(60),
            durationSeconds: 60,
            costUSD: costUSD,
            reviewerRetries: 0,
            outcome: "done",
            workerAgent: "Builder",
            reviewerAgent: "Reviewer",
            executionID: executionID,
            toolErrors: nil
        )
        record.predictionSource = predictionSource
        // The judge's verdict, which is what a finished run's record carries it
        // over from — a score with its dimensions, or why there is neither.
        record.qualityScore = qualityScore
        record.judgeDimensions = judgeDimensions
        record.judgeUnavailableReason = judgeUnavailable
        return record
    }

    /// Builds a real `ProjectSession` over a throwaway directory, seeds its backlog
    /// from markdown, and registers it. Returns the canonical project id — the key
    /// `RunInfo` uses.
    @discardableResult
    private func registerProject(named name: String, backlog: String) throws -> String {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
        session.backlogViewModel.backlogFile = BacklogParser.parse("## Epic: Work\n\n\(backlog)\n")

        registry.register(session: session, autopilot: BacklogAutopilot())
        return session.project.id
    }

    /// All stores are pointed at the temp directory so the tests never read or
    /// write the developer's real global config.
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
