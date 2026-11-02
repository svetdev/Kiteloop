import XCTest
@testable import Kiteloop

/// The drawer's Starts section, as a value.
///
/// The scheduler's record is the thing under test's *input*, not its subject:
/// what is asserted here is the mapping — that the newest run is read first, that
/// each outcome the scheduler can write reads as itself, that the two outcomes
/// which don't explain themselves carry the explanation, that the list is bounded
/// and says what the bound cost, and that the standing line answers "why is
/// nothing happening" for every decision the scheduler can be standing on.
@MainActor
final class CoordinatorStartsModelTests: XCTestCase {

    private var tempDir: URL!
    private var startsURL: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "starts-model")
        startsURL = tempDir.appendingPathComponent("coordinator-starts.jsonl")
    }

    // MARK: - Order

    /// `startHistory` appends, so the newest run is last in it and first on
    /// screen — the same reversal `GET /v1/coordinator/scheduling` does, because
    /// a reader coming to this section wants last night's last run, not the first
    /// one it ever made.
    func testNewestFirst() {
        let model = CoordinatorStartsModel.make(
            history: [record("alpha-1", at: base),
                      record("alpha-2", at: base.addingTimeInterval(600)),
                      record("alpha-3", at: base.addingTimeInterval(1_200))],
            lastDecision: nil, isSchedulingOn: true)

        XCTAssertEqual(model.rows.items.map(\.itemID), ["alpha-3", "alpha-2", "alpha-1"])
    }

    // MARK: - One record as a row

    /// Every field on the row comes off the record. Nothing here is derived a
    /// second way: the endpoint and the drawer are reporting one set of records.
    func testARowCarriesTheRecordItWasMadeFrom() throws {
        let finished = base.addingTimeInterval(420)
        let model = CoordinatorStartsModel.make(
            history: [record("alpha-1", at: base, outcome: "done", finishedAt: finished)],
            lastDecision: nil, isSchedulingOn: true)

        let row = try XCTUnwrap(model.rows.items.first)
        XCTAssertEqual(row.at, base)
        XCTAssertEqual(row.finishedAt, finished)
        XCTAssertEqual(row.project, "alpha")
        XCTAssertEqual(row.itemID, "alpha-1")
        XCTAssertEqual(row.headline, "Ship alpha-1")
        XCTAssertEqual(row.subtitle, "alpha · alpha-1")
        XCTAssertEqual(row.outcome, "done", "the record's own word, not a paraphrase")
        XCTAssertEqual(row.kind, .done)
        XCTAssertEqual(row.detail, "idle 12m, 4 ready · budget $6.40 of $20.00")
        XCTAssertNil(row.note, "`done` says what it means already")
    }

    /// A start read back from an older log can carry no title. The id is a worse
    /// headline than a title and a much better one than an empty line.
    func testARecordWithNoTitleFallsBackToItsID() {
        let model = CoordinatorStartsModel.make(history: [record("alpha-1", at: base, title: "")],
                                                lastDecision: nil, isSchedulingOn: true)

        XCTAssertEqual(model.rows.items.first?.headline, "alpha-1")
    }

    // MARK: - Outcomes

    /// Every outcome the scheduler writes — `StartRecord`'s own constants and
    /// `PortfolioSnapshot.outcomeName` — reads as its own case.
    func testEachOutcomeTheSchedulerWritesReadsAsItself() {
        let expected: [(String, CoordinatorStartsModel.Row.Kind)] = [
            (CoordinatorRunScheduler.StartRecord.running, .running),
            ("done", .done),
            ("awaiting-approval", .awaitingApproval),
            ("blocked", .blocked),
            ("cancelled", .cancelled),
            (CoordinatorRunScheduler.StartRecord.didNotRun, .didNotRun),
            (CoordinatorRunScheduler.StartRecord.interrupted, .interrupted)
        ]

        for (outcome, kind) in expected {
            XCTAssertEqual(CoordinatorStartsModel.Row.kind(of: outcome), kind, outcome)
        }
    }

    /// An outcome this reading doesn't know is drawn plainly rather than filed
    /// under the nearest case — and the string itself still reaches the row, so
    /// the screen shows what actually happened either way.
    func testAnUnknownOutcomeIsNotGuessedAt() throws {
        let model = CoordinatorStartsModel.make(
            history: [record("alpha-1", at: base, outcome: "quiesced-mid-flight")],
            lastDecision: nil, isSchedulingOn: true)

        let row = try XCTUnwrap(model.rows.items.first)
        XCTAssertEqual(row.kind, .other)
        XCTAssertEqual(row.outcome, "quiesced-mid-flight")
        XCTAssertNil(row.note)
    }

    /// The refusal. `did-not-run` is the one outcome a reader stops at: the
    /// scheduler committed to the start and the run came back with no result for
    /// the item, which reads as a fault and is the pickup gates doing their job.
    /// The record keeps no reason of its own, so the row names the possibilities
    /// rather than picking one.
    func testADidNotRunCarriesItsRefusalReason() throws {
        let model = CoordinatorStartsModel.make(
            history: [record("alpha-1", at: base,
                             outcome: CoordinatorRunScheduler.StartRecord.didNotRun)],
            lastDecision: nil, isSchedulingOn: true)

        let note = try XCTUnwrap(model.rows.items.first?.note)
        XCTAssertTrue(note.contains("pickup gates"), note)
        XCTAssertTrue(note.contains("agent session"), note)
    }

    /// The other one: a run whose app went away under it. Distinct from a refusal
    /// — the run may well have been working — and it needs saying, because
    /// `interrupted` alone reads as something the run did.
    func testAnInterruptedRunSaysWhatInterruptedMeans() throws {
        let model = CoordinatorStartsModel.make(
            history: [record("alpha-1", at: base,
                             outcome: CoordinatorRunScheduler.StartRecord.interrupted)],
            lastDecision: nil, isSchedulingOn: true)

        let note = try XCTUnwrap(model.rows.items.first?.note)
        XCTAssertTrue(note.contains("app went away"), note)
    }

    /// The outcomes that explain themselves get no note. A line under every row
    /// saying nothing is how the two that do need one stop being read.
    func testTheOutcomesThatExplainThemselvesCarryNoNote() {
        for outcome in [CoordinatorRunScheduler.StartRecord.running,
                        "done", "awaiting-approval", "blocked", "cancelled"] {
            let model = CoordinatorStartsModel.make(
                history: [record("alpha-1", at: base, outcome: outcome)], lastDecision: nil,
                isSchedulingOn: true)
            XCTAssertNil(model.rows.items.first?.note, outcome)
        }
    }

    // MARK: - The bound

    /// `startHistory` holds up to `maxStartHistory` runs and this section sits
    /// above a conversation, so the list is capped at construction — and says
    /// what the cap dropped, because a truncated list that looks complete is
    /// worse than a short one.
    func testTheListIsBoundedAndSaysWhatItDropped() {
        let total = CoordinatorStartsModel.rowLimit + 3
        let history = (0..<total).map { record("alpha-\($0)", at: base.addingTimeInterval(Double($0) * 600)) }

        let model = CoordinatorStartsModel.make(history: history, lastDecision: nil, isSchedulingOn: true)

        XCTAssertEqual(model.rows.items.count, CoordinatorStartsModel.rowLimit)
        XCTAssertEqual(model.rows.items.first?.itemID, "alpha-\(total - 1)", "the newest survives the cap")
        XCTAssertEqual(model.rows.omitted, 3)
        XCTAssertEqual(model.rows.omittedLabel, "+3 more")
    }

    func testNothingEverRunIsAnEmptyListRatherThanAMissingOne() {
        let model = CoordinatorStartsModel.make(history: [], lastDecision: nil, isSchedulingOn: true)

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.rows.omittedLabel)
    }

    // MARK: - The standing decision

    /// The question this section exists to answer: why is it doing nothing right
    /// now? A hold names its own reason, so the answer is on screen rather than
    /// inferred from an empty list.
    func testAHoldIsShownWithItsReason() {
        let model = CoordinatorStartsModel.make(history: [],
                                                lastDecision: .hold(.nothingRunnable),
                                                isSchedulingOn: true)

        XCTAssertEqual(model.standing.kind, .held)
        XCTAssertEqual(model.standing.text, "Held — nothing ready to run")
    }

    /// Every hold, not only the tidy one. Each is a different answer to "why was
    /// the machine quiet", and a line that collapsed any two would send the
    /// operator to fix the wrong thing.
    func testEveryHoldReasonReachesTheLine() {
        let holds: [RunScheduling.Hold] = [
            .disabled, .unwired, .projectHeld("3 autonomous runs in alpha failed"),
            .budgetExhausted("$20.00 of $20.00 spent today"), .noEligibleProject,
            .allBusy, .nothingRunnable, .quiesced
        ]

        for hold in holds {
            let model = CoordinatorStartsModel.make(history: [], lastDecision: .hold(hold),
                                                    isSchedulingOn: true)
            XCTAssertEqual(model.standing.kind, .held, hold.kind)
            XCTAssertEqual(model.standing.text, "Held — \(hold.reason)", hold.kind)
        }
    }

    func testAStartIsShownWithTheItemItStarted() {
        let model = CoordinatorStartsModel.make(history: [], lastDecision: .start(target),
                                                isSchedulingOn: true)

        XCTAssertEqual(model.standing.kind, .started)
        XCTAssertEqual(model.standing.text, "Started alpha/alpha-1")
    }

    /// Before the first look there is no decision, which is not the same as a
    /// hold: nothing has refused anything yet.
    func testNoDecisionYetSaysSoRatherThanReadingAsAHold() {
        let model = CoordinatorStartsModel.make(history: [], lastDecision: nil, isSchedulingOn: true)

        XCTAssertEqual(model.standing.kind, .noDecision)
        XCTAssertTrue(model.standing.text.contains("hasn't taken a look"), model.standing.text)
    }

    /// The shipped state, and the commonest answer to "why is nothing happening":
    /// a switched-off scheduler has no timer, so it never reaches a decision to
    /// report — and "no decision yet" would be a poor answer when the answer is
    /// that it is off. Said in the hold's own words, not a second wording of it.
    func testSwitchedOffWithNoDecisionSaysItIsOff() {
        let model = CoordinatorStartsModel.make(history: [], lastDecision: nil, isSchedulingOn: false)

        XCTAssertEqual(model.standing.kind, .held)
        XCTAssertEqual(model.standing.text, "Held — \(RunScheduling.Hold.disabled.reason)")
    }

    /// The switch is only consulted when there is no decision. One that has been
    /// reached is what the scheduler is standing on, and reporting the switch
    /// over it would hide the reason it actually refused.
    func testARealDecisionIsReportedEvenWithTheSwitchOff() {
        let model = CoordinatorStartsModel.make(history: [],
                                                lastDecision: .hold(.budgetExhausted("$20.00 of $20.00")),
                                                isSchedulingOn: false)

        XCTAssertEqual(model.standing.text, "Held — $20.00 of $20.00")
    }

    // MARK: - Capture

    /// The section is built from the live scheduler and nothing else — no second
    /// store, and no file read of its own. A fresh one is off, which is the
    /// shipped state and what its standing line says.
    func testCaptureReadsTheLiveScheduler() {
        let scheduler = CoordinatorRunScheduler(logURL: startsURL)

        let model = CoordinatorStartsModel.capture(scheduler)

        XCTAssertNotNil(model)
        XCTAssertTrue(model?.rows.isEmpty ?? false)
        XCTAssertEqual(model?.standing.kind, .held)
        XCTAssertEqual(model?.standing.text, "Held — \(RunScheduling.Hold.disabled.reason)")
    }

    /// With no scheduler wired into the window there is no section at all — an
    /// empty list there would read as "nothing ever ran", which is a claim.
    func testCaptureWithNoSchedulerIsNoSection() {
        XCTAssertNil(CoordinatorStartsModel.capture(nil))
    }

    /// The acceptance criterion the whole record exists for: the app that ran the
    /// night is gone, and the section still shows what it did. Nothing here reads
    /// the log itself — the scheduler does that at launch, and this is what
    /// reaches the screen afterwards.
    func testTheListSurvivesARestartThroughTheLogReadBack() throws {
        let started = base
        try writeLog([
            logLine(at: started, item: "alpha-1", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: started.addingTimeInterval(300), item: "alpha-1", event: "finish",
                    outcome: "awaiting-approval"),
            // The second run's app died under it: a start with no finish beside
            // it, which is the state a restart is most often asked about.
            logLine(at: started.addingTimeInterval(900), item: "alpha-2", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running)
        ])

        let relaunched = CoordinatorRunScheduler(logURL: startsURL,
                                                 now: started.addingTimeInterval(1_200))
        let model = try XCTUnwrap(CoordinatorStartsModel.capture(relaunched))

        XCTAssertEqual(model.rows.items.map(\.itemID), ["alpha-2", "alpha-1"])
        XCTAssertEqual(model.rows.items.map(\.kind), [.interrupted, .awaitingApproval])
        XCTAssertNotNil(model.rows.items.first?.note, "an interrupted run says what interrupted it")
        XCTAssertEqual(model.rows.items.last?.why, "idle 12m, 1 ready")
    }

    // MARK: - Fixtures

    /// Fixed, because a row is dated by the record and a fixture that moved with
    /// the clock would make the order assertions depend on when they ran.
    private let base = Date(timeIntervalSince1970: 1_786_000_000)

    private let target = RunScheduling.Target(project: "alpha", path: "/tmp/alpha",
                                              itemID: "alpha-1", itemTitle: "Ship alpha-1",
                                              readyCount: 4, reason: "idle 12m, 4 ready")

    private func record(_ itemID: String,
                        at: Date,
                        title: String? = nil,
                        outcome: String = "done",
                        finishedAt: Date? = nil) -> CoordinatorRunScheduler.StartRecord {
        CoordinatorRunScheduler.StartRecord(
            at: at, project: "alpha", itemID: itemID,
            itemTitle: title ?? "Ship \(itemID)",
            why: "idle 12m, 4 ready",
            budgetText: "$6.40 of $20.00",
            outcome: outcome, finishedAt: finishedAt)
    }

    /// The log's own shape, as `CoordinatorRunScheduler.encode` writes it — a
    /// `finish` carries `finishedAt` in the `at` field.
    private func logLine(at: Date, item: String, event: String, outcome: String) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        {"at":"\(formatter.string(from: at))","event":"\(event)","project":"alpha",\
        "item":"\(item)","title":"Ship \(item)","why":"idle 12m, 1 ready",\
        "budget":"$6.40 of $20.00","outcome":"\(outcome)"}
        """
    }

    private func writeLog(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: startsURL, atomically: true,
                                                         encoding: .utf8)
    }
}
