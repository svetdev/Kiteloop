import XCTest
@testable import KiteloopCore

/// One sitting's runs, read back as what landed, what stalled and what was
/// spent — built from run records alone.
final class SittingSummaryTests: XCTestCase {

    private let project = "/tmp/project"
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var end: Date { start.addingTimeInterval(3_600) }

    private func record(_ item: String, _ outcome: PersistedRunRecord.Outcome?,
                        at offset: TimeInterval = 60, project: String? = nil,
                        ended: TimeInterval? = nil, reason: String? = nil,
                        cost: Double? = nil, merged: Bool? = nil,
                        mergeCommit: String? = nil) -> PersistedRunRecord {
        PersistedRunRecord(runId: "run-\(item)-\(offset)", projectID: project ?? self.project,
                           itemID: item, title: "Title of \(item)",
                           startedAt: start.addingTimeInterval(offset),
                           endedAt: ended.map { start.addingTimeInterval($0) },
                           outcome: outcome, reason: reason, costUSD: cost,
                           merged: merged, mergeCommit: mergeCommit)
    }

    private func summary(_ records: [PersistedRunRecord]) -> SittingSummary {
        SittingSummary.build(records: records, projectID: project, from: start, to: end)
    }

    // MARK: - Buckets

    func testEachOutcomeGoesToItsOwnList() {
        let built = summary([
            record("done", .done, at: 10),
            record("merged", .awaitingApproval, at: 20, merged: true, mergeCommit: "abc123"),
            record("blocked", .blocked, at: 30, reason: "verify failed"),
            record("refused", .didNotRun, at: 40, reason: "size is L"),
            record("gate", .awaitingApproval, at: 50),
            record("premise", .investigation, at: 60)
        ])

        XCTAssertEqual(built.landed.map(\.itemID), ["done", "merged"])
        XCTAssertEqual(built.landed.map(\.mergeCommit), [nil, "abc123"])
        XCTAssertEqual(built.blocked.map(\.itemID), ["blocked"])
        XCTAssertEqual(built.refusedAtPickup.map(\.itemID), ["refused"])
        XCTAssertEqual(built.atGate.map(\.itemID), ["gate", "premise"])
        XCTAssertEqual(built.stalledCount, 4)
        XCTAssertEqual(built.blocked.first?.title, "Title of blocked")
    }

    func testRunsThatNeitherLandedNorStalledAreInNoList() {
        let built = summary([
            record("cancelled", .cancelled), record("parked", .usageLimitParked),
            record("interrupted", .interrupted), record("open", nil)
        ])

        XCTAssertTrue(built.isEmpty)
        XCTAssertNil(built.notice)
    }

    // MARK: - Which records belong

    func testOtherProjectsAreIgnored() {
        let built = summary([record("mine", .done), record("theirs", .done, project: "/tmp/other", cost: 5)])

        XCTAssertEqual(built.landed.map(\.itemID), ["mine"])
        XCTAssertEqual(built.totalSpendUSD, 0)
    }

    func testRecordsOutsideTheWindowAreIgnored() {
        let built = summary([
            record("before", .done, at: -600, ended: -60, cost: 1),
            record("first", .done, at: 0, cost: 2),
            record("last", .done, at: 3_600, cost: 4),
            record("after", .done, at: 3_601, cost: 8)
        ])

        XCTAssertEqual(built.landed.map(\.itemID), ["first", "last"])
        XCTAssertEqual(built.totalSpendUSD, 6)
    }

    /// A control-API run's record opens with the request, just before the
    /// autopilot run whose window this is.
    func testARecordOpenedBeforeTheWindowAndEndedInsideItBelongs() {
        let built = summary([record("early", .blocked, at: -5, ended: 900)])

        XCTAssertEqual(built.blocked.map(\.itemID), ["early"])
    }

    func testAnItemRunTwiceAppearsOnceUnderItsLatestRecord() {
        let built = summary([
            record("again", .done, at: 900, cost: 2),
            record("again", .blocked, at: 100, reason: "first attempt", cost: 1),
            record("retry", .blocked, at: 200, reason: "older"),
            record("retry", .blocked, at: 800, reason: "newer")
        ])

        XCTAssertEqual(built.landed.map(\.itemID), ["again"])
        XCTAssertEqual(built.blocked.map(\.reason), ["newer"])
        XCTAssertEqual(built.totalSpendUSD, 3, "every attempt was paid for")
    }

    func testListsAreInTheOrderTheRunsStarted() {
        let built = summary([record("b", .blocked, at: 300), record("a", .blocked, at: 100)])

        XCTAssertEqual(built.blocked.map(\.itemID), ["a", "b"])
    }

    // MARK: - Reasons and actions

    func testAReasonIsCutToItsFirstLineThatSaysAnything() {
        let built = summary([record("x", .blocked, reason: "\n  verify failed  \nexit 65\nmore output")])

        XCTAssertEqual(built.blocked.first?.reason, "verify failed")
    }

    func testAMissingReasonGetsAPlaceholder() {
        let built = summary([
            record("blocked", .blocked, at: 10),
            record("blank", .didNotRun, at: 20, reason: "  \n"),
            record("refusedMerge", .awaitingApproval, at: 30, merged: false),
            record("premise", .investigation, at: 40)
        ])

        XCTAssertEqual(built.blocked.first?.reason, SittingSummary.noReasonRecorded)
        XCTAssertEqual(built.refusedAtPickup.first?.reason, SittingSummary.noReasonRecorded)
        XCTAssertEqual(built.atGate.map(\.reason), ["the run's own merge was refused",
                                                    "the worker refuted the item's premise; its report is at the gate"])
    }

    func testEveryStalledRowCarriesTheActionForItsKind() {
        let built = summary([record("b", .blocked, at: 10), record("r", .didNotRun, at: 20),
                             record("g", .awaitingApproval, at: 30), record("i", .investigation, at: 40)])

        XCTAssertEqual(built.blocked.map(\.action), [SittingSummary.Stall.blocked.action])
        XCTAssertEqual(built.refusedAtPickup.map(\.action), [SittingSummary.Stall.refusedAtPickup.action])
        XCTAssertEqual(built.atGate.map(\.action), Array(repeating: SittingSummary.Stall.atGate.action, count: 2))
        for kind in SittingSummary.Stall.allCases {
            XCTAssertFalse(kind.action.isEmpty)
        }
        XCTAssertEqual(Set(SittingSummary.Stall.allCases.map(\.action)).count, 3)
    }

    // MARK: - Spend

    func testSpendIsTheSumOfTheCostsThatWereRecorded() {
        let built = summary([record("a", .done, at: 10, cost: 1.25), record("b", .blocked, at: 20),
                             record("c", .cancelled, at: 30, cost: 0.5)])

        XCTAssertEqual(built.totalSpendUSD, 1.75, accuracy: 0.0001)
    }

    func testSpendIsZeroWhenNoRecordCarriesACost() {
        XCTAssertEqual(summary([record("a", .done), record("b", .blocked)]).totalSpendUSD, 0)
    }

    // MARK: - The notice

    func testASittingWithNoRecordsFilesNoNotice() {
        XCTAssertNil(summary([]).notice)
    }

    func testASittingWhereEverythingLandedIsAReportNotAnAction() throws {
        let notice = try XCTUnwrap(summary([record("a", .done, cost: 2)]).notice)

        XCTAssertEqual(notice.type, .complete)
        XCTAssertFalse(notice.type.isActionable)
        XCTAssertEqual(notice.title, "Sitting summary")
        XCTAssertEqual(notice.body, "1 landed, 0 stalled, $2.00 spent.\n\nLanded:\n- a: Title of a")
    }

    func testASittingWithAStallIsActionableAndSaysWhatClearsIt() throws {
        let built = summary([record("a", .done, at: 10), record("b", .blocked, at: 20, reason: "verify failed"),
                             record("c", .didNotRun, at: 30, reason: "no verify")])
        let notice = try XCTUnwrap(built.notice)

        XCTAssertTrue(notice.type.isActionable)
        XCTAssertEqual(notice.body, """
        1 landed, 2 stalled, $0.00 spent.

        Landed:
        - a: Title of a

        Blocked:
        - b: Title of b. verify failed. To clear: \(SittingSummary.Stall.blocked.action).

        Refused at pickup:
        - c: Title of c. no verify. To clear: \(SittingSummary.Stall.refusedAtPickup.action).
        """)
    }

    // MARK: - The payload

    func testThePayloadCarriesEveryListAndTheSpend() throws {
        let built = summary([record("a", .done, at: 10, cost: 1.5, merged: true, mergeCommit: "abc"),
                             record("b", .blocked, at: 20, reason: "stuck"),
                             record("g", .awaitingApproval, at: 30)])
        let payload = built.payload
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertFalse(data.isEmpty)

        XCTAssertEqual(payload["project"] as? String, project)
        XCTAssertEqual(payload["from"] as? String, start.formatted(.iso8601))
        XCTAssertEqual(payload["to"] as? String, end.formatted(.iso8601))
        XCTAssertEqual(payload["summary"] as? String, "1 landed, 2 stalled, $1.50 spent")
        XCTAssertEqual(payload["totalSpendUSD"] as? Double, 1.5)
        XCTAssertEqual(payload["text"] as? String, built.text)
        let landed = try XCTUnwrap(payload["landed"] as? [[String: Any]])
        XCTAssertEqual(landed.first?["itemId"] as? String, "a")
        XCTAssertEqual(landed.first?["mergeCommit"] as? String, "abc")
        let blocked = try XCTUnwrap(payload["blocked"] as? [[String: Any]])
        XCTAssertEqual(blocked.first?["reason"] as? String, "stuck")
        XCTAssertEqual(blocked.first?["action"] as? String, SittingSummary.Stall.blocked.action)
        XCTAssertEqual((payload["refusedAtPickup"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((payload["atGate"] as? [[String: Any]])?.first?["itemId"] as? String, "g")
    }

    func testTheSummarySurvivesARoundTripThroughJSON() throws {
        let built = summary([record("a", .done, cost: 1), record("b", .blocked, at: 90, reason: "stuck")])
        let decoded = try JSONDecoder().decode(SittingSummary.self, from: JSONEncoder().encode(built))

        XCTAssertEqual(decoded, built)
    }

    // MARK: - Open sittings

    func testASittingRunsFromItsFirstStartToTheEnd() {
        var sittings = OpenSittings()
        XCTAssertTrue(sittings.isEmpty)
        sittings.started(in: "b", at: start.addingTimeInterval(300))
        sittings.started(in: "a", at: start)
        sittings.started(in: "a", at: start.addingTimeInterval(600))

        XCTAssertEqual(sittings.end(at: end), [
            OpenSittings.Ended(projectID: "a", from: start, to: end),
            OpenSittings.Ended(projectID: "b", from: start.addingTimeInterval(300), to: end)
        ])
    }

    func testASittingEndsOnce() {
        var sittings = OpenSittings()
        sittings.started(in: "a", at: start)
        _ = sittings.end(at: end)

        XCTAssertTrue(sittings.isEmpty)
        XCTAssertEqual(sittings.end(at: end.addingTimeInterval(60)), [])
    }

    func testAnEndedSittingNeverRunsBackwards() {
        var sittings = OpenSittings()
        sittings.started(in: "a", at: end)

        XCTAssertEqual(sittings.end(at: start), [OpenSittings.Ended(projectID: "a", from: end, to: end)])
    }
}
