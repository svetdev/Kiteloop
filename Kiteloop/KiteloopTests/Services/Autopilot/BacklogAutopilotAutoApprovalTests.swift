import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers `approveReviewPassedRuns` — the per-project setting that lets a run
/// clear its own approval gate instead of parking every review-passed item at
/// `awaiting-approval` for a human who is asleep.
///
/// It widens ADR-0001's human gate, so what is asserted here is mostly what it
/// does *not* do: the routing rule (`gateResolution`) one ending at a time, the
/// default being the gate, a reset putting the gate back, and the automatic
/// approval saying so in the item's Notes and in the run record — the only
/// thing that tells a morning reader "a human accepted this" from "the setting
/// accepted this".
@MainActor
final class BacklogAutopilotAutoApprovalTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "autopilot-auto-approval")
    }

    private func makeAutopilot(configURL: URL) -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(
                    storageURL: tempDir.appendingPathComponent("global-config.json")
                )
            ),
            configURL: configURL
        )
        return autopilot
    }

    /// `gateResolution` with everything else held favourable, so a case that
    /// routes to `.human` did so for the reason it names.
    private func resolution(
        outcome: BacklogAutopilot.ItemResult.Outcome = .awaitingApproval,
        reviewPassed: Bool = true,
        settingOn: Bool = true,
        mergeRefusal: String? = nil
    ) -> BacklogAutopilot.GateResolution {
        BacklogAutopilot.gateResolution(outcome: outcome,
                                        reviewPassed: reviewPassed,
                                        autoApproveReviewPassed: settingOn,
                                        mergeRefusal: mergeRefusal)
    }

    // MARK: - The routing rule

    /// The one ending the setting covers: the reviewer passed, the item is at
    /// the gate, and the project asked for this.
    func testAReviewPassedItemIsApprovedWhenTheSettingIsOn() {
        XCTAssertEqual(resolution(), .automatic)
    }

    /// Off is the gate. The same ending, with the setting off, is what every run
    /// has always done: wait for a person.
    func testTheSameItemWaitsForAHumanWhenTheSettingIsOff() {
        XCTAssertEqual(resolution(settingOn: false), .human)
    }

    /// A rejected or blocked run has no gate to clear, so it routes exactly as
    /// it does today whether the setting is on or off — the setting must not
    /// turn "the reviewer said no" into a `done` item.
    func testARejectedOrBlockedRunRoutesTheSameWithTheSettingOnOrOff() {
        let endings: [(String, BacklogAutopilot.ItemResult.Outcome)] = [
            ("review rejected", .blocked("review did not pass")),
            ("stalled", .blocked("no progress for 20 min")),
            ("cancelled", .cancelled),
        ]
        for (name, outcome) in endings {
            XCTAssertEqual(resolution(outcome: outcome, settingOn: true), .human,
                           "\(name) has no gate for the setting to clear")
            XCTAssertEqual(resolution(outcome: outcome, settingOn: false), .human,
                           "\(name) routes the same with the setting off")
        }
    }

    /// An item that reached `done` on its own — the approval gate is off for the
    /// project, or its branch auto-merged — is already resolved. Nothing here
    /// approves it a second time, and nothing here records it as automatic:
    /// that ending predates the setting.
    func testAnItemThatIsAlreadyDoneIsNotApprovedAgain() {
        XCTAssertEqual(resolution(outcome: .done), .human)
    }

    /// A run the retry ceiling, a stall or a cost cap cut short can still be
    /// salvaged by its own `verify:` and reaches the same gate — but nobody
    /// reviewed that diff, and the setting says *review*-passed.
    func testASalvagedRunIsNotAReviewPassAndStillWaits() {
        XCTAssertEqual(resolution(reviewPassed: false), .human)
    }

    /// A merge that was attempted and refused leaves the work unlanded.
    /// Approving over it would stamp `done` on commits `main` has never seen —
    /// the same refusal `resolveGate` makes for a human's approval.
    func testAnItemWhoseMergeWasRefusedStillWaitsForAHuman() {
        XCTAssertEqual(resolution(mergeRefusal: "working tree not clean"), .human)
    }

    /// The other two merge readings are not refusals: a merge that landed takes
    /// the item to `done` before this is asked, and a run where none was
    /// attempted — auto-merge off, or no branch — carries no refusal at all.
    func testNoMergeRefusalIsNotTheSameAsAFailedMerge() {
        XCTAssertEqual(resolution(mergeRefusal: nil), .automatic)
    }

    // MARK: - What the approval says about itself

    /// The Notes line has to be readable as "nobody looked at this" by someone
    /// scanning the backlog in the morning — that is the whole point of
    /// recording it.
    func testTheNoteSaysNoHumanAcceptedTheItem() {
        let note = BacklogAutopilot.automaticApprovalNote(unmergedBranch: nil)
        XCTAssertTrue(note.contains("Approved automatically"), note)
        XCTAssertTrue(note.contains("reviewer passed"), note)
        XCTAssertTrue(note.contains("No human accepted this item."), note)
    }

    /// With `autoMergeOnApproval` off the item reads `done` while its commits
    /// sit on a branch nothing has merged. The note names that branch, so the
    /// item can't read as delivered when the work has not landed.
    func testTheNoteNamesAnUnmergedBranch() {
        let note = BacklogAutopilot.automaticApprovalNote(unmergedBranch: "kiteloop/some-item")
        XCTAssertTrue(note.contains("kiteloop/some-item"), note)
        XCTAssertTrue(note.contains("has not been merged"), note)
    }

    /// A run with no branch has nowhere for work to be stranded, so it says
    /// nothing about merging rather than naming an empty ref.
    func testTheNoteSaysNothingAboutMergingWithoutABranch() {
        for branch in [nil, ""] as [String?] {
            let note = BacklogAutopilot.automaticApprovalNote(unmergedBranch: branch)
            XCTAssertFalse(note.contains("branch"), note)
        }
    }

    /// The run record is the copy that outlives the run, so the word has to
    /// survive the round trip through `run-history.json`.
    func testTheRunRecordCarriesTheAutomaticApprovalThroughACodableRoundTrip() throws {
        let record = BacklogAutopilot.RunRecord.ItemRecord(
            id: "some-item", title: "Some item", outcome: "done", duration: 12,
            executionID: "exec-1", approval: BacklogAutopilot.ItemResult.Approval.automatic.rawValue
        )
        let decoded = try JSONDecoder().decode(
            BacklogAutopilot.RunRecord.ItemRecord.self,
            from: try JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.approval, "automatic")
    }

    /// Thirty history rows on 2026-09-18 each read `done` and none said
    /// whether the branch had landed. The row now carries the run's own
    /// merge, and the commit it became, through the same round trip.
    func testTheRunRecordCarriesTheMergeOutcomeThroughACodableRoundTrip() throws {
        let record = BacklogAutopilot.RunRecord.ItemRecord(
            id: "some-item", title: "Some item", outcome: "done", duration: 12,
            executionID: "exec-1", merged: true, mergeCommit: "abc1234"
        )
        let decoded = try JSONDecoder().decode(
            BacklogAutopilot.RunRecord.ItemRecord.self,
            from: try JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.merged, true)
        XCTAssertEqual(decoded.mergeCommit, "abc1234")
    }

    /// The wire says `merged` only when a merge was attempted: a run that
    /// attempted none is not "unmerged", and must not read as refused.
    func testTheWireCarriesAMergeOnlyWhenOneWasAttempted() {
        XCTAssertTrue(KiteloopControlServer.mergeFields(merged: nil, commit: nil).isEmpty)
        let refused = KiteloopControlServer.mergeFields(merged: false, commit: nil)
        XCTAssertEqual(refused["merged"] as? Bool, false)
        XCTAssertNil(refused["mergeCommit"])
        let landed = KiteloopControlServer.mergeFields(merged: true, commit: "abc1234")
        XCTAssertEqual(landed["merged"] as? Bool, true)
        XCTAssertEqual(landed["mergeCommit"] as? String, "abc1234")
    }

    /// History written before the field existed still decodes, and an item
    /// nobody approved here reads as absent rather than as some default word.
    func testARecordWithoutAnApprovalStillDecodes() throws {
        let json = Data("""
        {"id":"old-item","title":"Old item","outcome":"awaiting-approval","duration":9}
        """.utf8)
        let decoded = try JSONDecoder().decode(BacklogAutopilot.RunRecord.ItemRecord.self, from: json)
        XCTAssertNil(decoded.approval)
        XCTAssertNil(decoded.merged)
    }

    /// The durable control-API record keeps the merge the same way, and a
    /// line written before the field existed reads as "none attempted".
    func testThePersistedRunRecordCarriesTheMergeAndDecodesWithoutIt() throws {
        var record = PersistedRunRecord(runId: "run-1", projectID: "/tmp/alpha",
                                        itemID: "some-item", title: "Some item",
                                        startedAt: Date())
        record.merged = false
        let decoded = try JSONDecoder().decode(
            PersistedRunRecord.self, from: try JSONEncoder().encode(record))
        XCTAssertEqual(decoded.merged, false)
        XCTAssertNil(decoded.mergeCommit)
        let old = Data("""
        {"runId":"run-0","projectID":"/tmp/alpha","itemID":"old","title":"Old","startedAt":0}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(PersistedRunRecord.self, from: old).merged)
    }

    /// The durable control-API record answers the same question after a
    /// restart, which is the only place a night's runs can still be read from.
    func testThePersistedRunRecordCarriesTheApprovalAndDecodesWithoutIt() throws {
        var record = PersistedRunRecord(runId: "run-1", projectID: "/tmp/alpha",
                                        itemID: "some-item", title: "Some item",
                                        startedAt: Date())
        record.approval = "automatic"
        let decoded = try JSONDecoder().decode(
            PersistedRunRecord.self, from: try JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.approval, "automatic")

        let older = Data("""
        {"runId":"run-0","projectID":"/tmp/alpha","itemID":"some-item","title":"Some item",
         "startedAt":760000000}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(PersistedRunRecord.self, from: older).approval)
    }

    // MARK: - The setting itself

    /// Off, per project. A run that has not been told otherwise asks.
    func testTheSettingIsOffByDefault() {
        XCTAssertEqual(BacklogAutopilot.Defaults.approvalGate, .propose)
        let autopilot = makeAutopilot(configURL: tempDir.appendingPathComponent("config.json"))
        XCTAssertFalse(autopilot.approveReviewPassedRuns)
        XCTAssertTrue(autopilot.isConfigAtDefaults)
    }

    /// It is a project setting: it survives a relaunch, and a reset puts the
    /// gate back — a widened gate nobody can remember widening is exactly what
    /// the Reset control is for.
    func testItPersistsAndAResetPutsTheGateBack() {
        let configURL = tempDir.appendingPathComponent("config.json")
        let autopilot = makeAutopilot(configURL: configURL)
        autopilot.approvalGate = .land
        XCTAssertFalse(autopilot.isConfigAtDefaults)

        let reloaded = makeAutopilot(configURL: configURL)
        XCTAssertTrue(reloaded.approveReviewPassedRuns, "a project setting outlives the session")

        reloaded.resetConfigToDefaults()
        XCTAssertFalse(reloaded.approveReviewPassedRuns)
        XCTAssertTrue(reloaded.isConfigAtDefaults)
        XCTAssertFalse(makeAutopilot(configURL: configURL).approveReviewPassedRuns,
                       "the reset is written through, not just held in memory")
    }

    // MARK: - The dial over the gate

    /// The dial writes both values it reads, and reads back what it wrote; the
    /// old switches only ever read off the gate, so neither half can be set
    /// apart from the other.
    func testEveryRungWritesTheGateAndReadsBack() {
        let autopilot = makeAutopilot(configURL: tempDir.appendingPathComponent("config.json"))
        let expected: [BacklogAutopilot.Autonomy: (work: Bool, gate: BacklogAutopilot.ApprovalGate)] = [
            .off: (false, .propose), .propose: (true, .propose), .land: (true, .land)
        ]
        for rung in BacklogAutopilot.Autonomy.allCases {
            autopilot.autonomy = rung
            XCTAssertEqual(autopilot.autonomy, rung)
            XCTAssertEqual(autopilot.autonomousWorkEnabled, expected[rung]?.work)
            XCTAssertEqual(autopilot.approvalGate, expected[rung]?.gate)
            XCTAssertEqual(autopilot.approveReviewPassedRuns, autopilot.autoMergeOnApproval)
        }
    }
}
