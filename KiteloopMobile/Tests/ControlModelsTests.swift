import XCTest
@testable import KiteloopMobile

/// The Now tab's spinner is driven by what `/v1/projects` says a project's
/// autopilot is doing — decoded here, so a field the Mac renames or drops is
/// caught as a failing test rather than a spinner that never turns.
final class ControlModelsTests: XCTestCase {

    func testAProjectWithARunUpIsRunningAndNamesTheItemAndItsStep() throws {
        let json = """
        {"projects": [{"id": "/p/travel", "name": "travel", "autopilotReady": true,
                       "queue": {"active": 1, "ready": 3, "awaitingApproval": 0},
                       "run": {"running": true, "item": "alerts-forecast-and-event-writes-checked",
                               "itemTitle": "The last three unchecked SQL statements",
                               "startedAt": "2026-09-06T19:58:00Z",
                               "phaseRail": {"attempt": 1, "currentStep": "worker", "stepsDone": []}}}]}
        """
        let reply = try JSONDecoder().decode(ProjectsReply.self, from: Data(json.utf8))
        let project = try XCTUnwrap(reply.projects?.first)
        XCTAssertTrue(project.isRunning)
        XCTAssertEqual(project.run?.itemTitle, "The last three unchecked SQL statements")
        XCTAssertEqual(project.run?.step, "worker")
    }

    func testAnIdleProjectAndAMacWithoutTheFieldAreNotRunning() throws {
        let idle = """
        {"projects": [{"id": "/p/kiteloop", "name": "kiteloop", "run": {"running": false, "item": null}}]}
        """
        let older = """
        {"projects": [{"id": "/p/vault", "name": "vault", "queue": {"active": 0}}]}
        """
        for json in [idle, older] {
            let reply = try JSONDecoder().decode(ProjectsReply.self, from: Data(json.utf8))
            let project = try XCTUnwrap(reply.projects?.first)
            XCTAssertFalse(project.isRunning, json)
            XCTAssertNil(project.run?.step)
        }
    }

    /// A gate still verifying is not waiting on a person; a refused one is,
    /// and carries its reason.
    func testAGateVerifyingIsNotWaitingOnAPerson() throws {
        let verifying = #"{"id": "a", "status": "awaiting-approval", "gate": {"state": "verifying", "since": "2026-09-07T14:26:41Z"}}"#
        let item = try JSONDecoder().decode(BacklogItem.self, from: Data(verifying.utf8))
        XCTAssertTrue(item.isGate)
        XCTAssertTrue(item.isVerifying)
        XCTAssertFalse(item.needsPerson)
        let refused = #"{"id": "b", "status": "awaiting-approval", "gate": {"state": "refused", "reason": "verify failed on merged tree"}}"#
        let other = try JSONDecoder().decode(BacklogItem.self, from: Data(refused.utf8))
        XCTAssertTrue(other.needsPerson)
        XCTAssertEqual(other.gate?.reason, "verify failed on merged tree")
        let plain = try JSONDecoder().decode(BacklogItem.self, from: Data(#"{"id": "c", "status": "awaiting-approval"}"#.utf8))
        XCTAssertTrue(plain.needsPerson, "an older Mac sends no gate — a person is still the default")
    }

    /// The queue lists `now` items first, off the lane `/v1/backlog` reports; an
    /// older Mac sends no lane, and its items are all `later`.
    func testAnItemsLaneReadsNowOnlyWhenTheMacSaysSo() throws {
        let decode = { (json: String) in try JSONDecoder().decode(BacklogItem.self, from: Data(json.utf8)) }
        let now = try decode(#"{"id": "a", "epic": "Platform", "lane": "now"}"#)
        XCTAssertTrue(now.isNow)
        XCTAssertEqual(now.flippedLane, "later")
        XCTAssertFalse(try decode(#"{"id": "b", "lane": "later"}"#).isNow)
        XCTAssertEqual(try decode(#"{"id": "c"}"#).flippedLane, "now", "an older Mac's item is later, so a flip promotes it")
    }

    /// The Fleet tab's runs-at-once stepper and its "Starting:" line both read
    /// off the scheduling reply — the ceiling straight from `maxConcurrentRuns`,
    /// the names from the starts still running while `startsInFlight` counts any.
    func testASchedulingReplyCarriesTheRunCeilingAndNamesTheRunsInFlight() throws {
        let json = """
        {"enabled": true, "startInFlight": true, "startsInFlight": 2, "maxConcurrentRuns": 4,
         "budget": {"spentTodayUSD": 3.2, "budgetUSD": 20},
         "starts": [{"at": "2026-09-07T10:02:00Z", "project": "travel", "item": "a", "outcome": "running"},
                    {"at": "2026-09-07T10:01:00Z", "project": "kiteloop", "item": "b", "outcome": "running"},
                    {"at": "2026-09-07T09:40:00Z", "project": "vault", "item": "c", "outcome": "done"}]}
        """
        let reply = try JSONDecoder().decode(SchedulingReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.maxConcurrentRuns, 4)
        XCTAssertEqual(reply.startsInFlight, 2)
        XCTAssertEqual(reply.startingProjects, ["travel", "kiteloop"], "a finished start is not in flight")
    }

    /// A Mac older than the two fields still decodes, and says nothing is
    /// starting — so the stepper falls back and the line stays away.
    func testAMacWithoutTheRunCeilingDecodesWithNoCountAndNamesNothing() throws {
        let older = #"{"enabled": true, "startInFlight": false, "starts": [{"project": "travel", "outcome": "running"}]}"#
        let reply = try JSONDecoder().decode(SchedulingReply.self, from: Data(older.utf8))
        XCTAssertNil(reply.maxConcurrentRuns)
        XCTAssertNil(reply.startsInFlight)
        XCTAssertEqual(reply.startingProjects, [])
        let idle = #"{"enabled": true, "startsInFlight": 0, "maxConcurrentRuns": 1, "starts": []}"#
        let quiet = try JSONDecoder().decode(SchedulingReply.self, from: Data(idle.utf8))
        XCTAssertEqual(quiet.maxConcurrentRuns, 1)
        XCTAssertEqual(quiet.startingProjects, [], "nothing in flight names nothing")
    }

    /// A patch longer than the phone's row cap is cut on the phone even when
    /// the Mac sent it whole — and the header says so, naming both caps.
    func testAPatchPastTheRowCapReportsItselfCutThoughTheMacSentItWhole() throws {
        let patch = (1...1500).map { "+ line \($0)" }.joined(separator: "\n")
        let preview = try XCTUnwrap(DiffReply(patch: patch, truncated: false).preview)
        XCTAssertEqual(preview.lines.count, DiffPreview.lineCap)
        XCTAssertEqual(preview.lines.last, "+ line 1200")
        XCTAssertTrue(preview.cut, "300 lines are missing — the screen must not stay silent")
        XCTAssertEqual(preview.header, DiffPreview.cutHeader)
        XCTAssertTrue(DiffPreview.cutHeader.contains("the Mac"), "the wording names the Mac's cap")
        XCTAssertTrue(DiffPreview.cutHeader.contains("this screen"), "and the phone's own row cap")
    }

    /// A patch the screen shows whole keeps every line and the plain header.
    func testAShortPatchKeepsEveryLineAndThePlainHeader() throws {
        let patch = (1...100).map { "+ line \($0)" }.joined(separator: "\n")
        let preview = DiffPreview(patch: patch, truncated: false)
        XCTAssertEqual(preview.lines.count, 100)
        XCTAssertFalse(preview.cut)
        XCTAssertEqual(preview.header, "Diff")
    }

    /// The Mac's own flag still stands on its own: a patch it cut reports
    /// itself cut even though it is far under the row cap.
    func testAPatchTheMacTruncatedReportsItselfCutUnderTheRowCap() throws {
        let preview = DiffPreview(patch: "+ one\n+ two", truncated: true)
        XCTAssertEqual(preview.lines.count, 2)
        XCTAssertTrue(preview.cut)
        XCTAssertEqual(preview.header, DiffPreview.cutHeader)
        XCTAssertNil(DiffReply(patch: "", truncated: true).preview, "no patch is nothing to preview")
    }

    /// A ready item the Mac would not start says why, in the gate's words; a
    /// retired one is flagged; an older Mac's item, with no verdict, reads as startable.
    func testABacklogItemCarriesTheMacsVerdictOnWhetherItCanStart() throws {
        let json = """
        {"items": [
          {"id": "triaged", "status": "ready", "ready": false,
           "notReady": ["no verify: command — nothing objective for the run to pass"]},
          {"id": "stuck", "status": "ready", "ready": false, "retired": true,
           "notReady": ["retired: 3 attempts started and produced no work (ceiling 3)"]},
          {"id": "fine", "status": "ready", "ready": true},
          {"id": "older", "status": "ready"}
        ]}
        """
        let items = try XCTUnwrap(JSONDecoder().decode(BacklogReply.self, from: Data(json.utf8)).items)
        XCTAssertTrue(items[0].cannotStart)
        XCTAssertTrue(items[0].isJudged)
        XCTAssertEqual(items[0].notReady, ["no verify: command — nothing objective for the run to pass"])
        XCTAssertFalse(items[0].isRetired)
        XCTAssertTrue(items[1].isRetired)
        XCTAssertTrue(items[1].cannotStart)
        XCTAssertFalse(items[2].cannotStart)
        XCTAssertTrue(items[2].isJudged)
        XCTAssertFalse(items[3].cannotStart, "no verdict from an older Mac reads as startable")
        XCTAssertFalse(items[3].isJudged, "so the grooming ledger still speaks for it")
        XCTAssertFalse(items[3].isRetired)
        XCTAssertNil(items[3].notReady)
    }

    /// Release lifts the retry ceiling: offered on a retired ready item, never on
    /// a blocked one, where it changes nothing, nor on a plain ready one.
    func testReleaseIsOfferedOnlyOnARetiredReadyItem() throws {
        let decode = { (json: String) in try JSONDecoder().decode(BacklogItem.self, from: Data(json.utf8)) }
        XCTAssertTrue(try decode(#"{"id": "a", "status": "ready", "ready": false, "retired": true}"#).offersRelease)
        XCTAssertFalse(try decode(#"{"id": "b", "status": "blocked"}"#).offersRelease)
        XCTAssertFalse(try decode(#"{"id": "c", "status": "ready", "ready": true}"#).offersRelease)
    }

    /// `runnable` sits beside `ready` in a project's queue; an older Mac omits it.
    func testQueueCountsDecodeWithAndWithoutRunnable() throws {
        let json = """
        {"projects": [{"id": "/p/a", "name": "a", "queue": {"ready": 5, "runnable": 1}},
                      {"id": "/p/b", "name": "b", "queue": {"ready": 5}}]}
        """
        let projects = try XCTUnwrap(JSONDecoder().decode(ProjectsReply.self, from: Data(json.utf8)).projects)
        XCTAssertEqual(projects[0].queue?.runnable, 1)
        XCTAssertEqual(projects[0].queue?.ready, 5)
        XCTAssertNil(projects[1].queue?.runnable)
        XCTAssertEqual(projects[1].queue?.ready, 5)
    }

}
