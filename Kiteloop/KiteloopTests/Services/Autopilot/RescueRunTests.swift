import XCTest
import KiteloopCore
@testable import Kiteloop

/// The rescue extension's decision half: whether a merge-gate exclusion is
/// worth spending one capped agent run on, and the prompt/state that run is
/// built from — both exercised without git, an agent or a clock.
final class RescueRunTests: XCTestCase {

    // MARK: - classify

    func testAnExclusionIsWorthARescueWhenConsentedAndNeverRescuedBefore() {
        let signals = RescueRun.Signals(itemID: "item-1", autonomousWorkEnabled: true, alreadyRescued: false)
        XCTAssertEqual(RescueRun.classify(signals), .spawn)
    }

    /// A rescue is itself unattended work, and nothing here may start it
    /// without the project's own consent — asked first, before the ledger.
    func testNoRescueWithoutConsentForAutonomousWork() {
        let signals = RescueRun.Signals(itemID: "item-1", autonomousWorkEnabled: false, alreadyRescued: false)
        guard case .skip(let reason) = RescueRun.classify(signals) else {
            return XCTFail("consent must be required")
        }
        XCTAssertTrue(reason.contains("autonomous work is off"), reason)
    }

    /// One rescue per item, ever: a second qualifying exclusion on an item
    /// already rescued once — landed or not — does not spawn a second one.
    func testASecondRescueOnTheSameItemIsSkipped() {
        let signals = RescueRun.Signals(itemID: "item-1", autonomousWorkEnabled: true, alreadyRescued: true)
        guard case .skip(let reason) = RescueRun.classify(signals) else {
            return XCTFail("an item already rescued must not be rescued again")
        }
        XCTAssertTrue(reason.contains("already spent"), reason)
    }

    /// Consent is checked before the ledger — an item with no rescue on
    /// record yet is still refused outright when the project has not agreed
    /// to unattended work.
    func testConsentIsCheckedBeforeTheLedger() {
        let signals = RescueRun.Signals(itemID: "item-1", autonomousWorkEnabled: false, alreadyRescued: true)
        guard case .skip(let reason) = RescueRun.classify(signals) else {
            return XCTFail("consent must still gate an already-rescued item")
        }
        XCTAssertTrue(reason.contains("autonomous work is off"), reason)
    }

    // MARK: - Ledger

    func testAFreshLedgerHasNoRescueOnRecord() {
        XCTAssertFalse(RescueRun.Ledger().hasRescued(project: "demo", itemID: "item-1"))
    }

    func testRecordingARescueMakesItVisibleToHasRescued() {
        var ledger = RescueRun.Ledger()
        ledger.record(project: "demo", itemID: "item-1", outcome: "rescued", reason: "merged")
        XCTAssertTrue(ledger.hasRescued(project: "demo", itemID: "item-1"))
    }

    /// A failed rescue still spent the one attempt `classify` allows.
    func testAFailedRescueStillCountsAsSpent() {
        var ledger = RescueRun.Ledger()
        ledger.record(project: "demo", itemID: "item-1", outcome: "failed", reason: "review rejected")
        XCTAssertTrue(ledger.hasRescued(project: "demo", itemID: "item-1"))
    }

    func testALedgerEntryIsScopedToItsOwnProjectAndItem() {
        var ledger = RescueRun.Ledger()
        ledger.record(project: "demo", itemID: "item-1", outcome: "rescued", reason: "merged")
        XCTAssertFalse(ledger.hasRescued(project: "other", itemID: "item-1"))
        XCTAssertFalse(ledger.hasRescued(project: "demo", itemID: "item-2"))
    }

    func testALedgerRoundTripsThroughDisk() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "rescue-run-ledger")
        let url = tempDir.appending(path: "rescue-run.jsonl")
        RescueRun.Ledger.append(
            RescueRun.Ledger.Entry(at: Date(), project: "demo", itemID: "item-1",
                                   outcome: "rescued", reason: "merged"),
            to: url)

        let reloaded = RescueRun.Ledger.load(from: url)
        XCTAssertTrue(reloaded.hasRescued(project: "demo", itemID: "item-1"))
    }

    // MARK: - Outcome vocabulary

    /// Distinguishable from every ordinary outcome string, so a machine
    /// rescue is never silently folded into `done` or an ordinary `blocked`.
    func testOutcomeStringsAreDistinguishableFromOrdinaryOnes() {
        XCTAssertEqual(RescueRun.rescuedOutcome, "rescued")
        XCTAssertNotEqual(RescueRun.rescuedOutcome, "done")
        XCTAssertNotEqual(RescueRun.rescuedOutcome, "awaiting-approval")
        XCTAssertEqual(RescueRun.rescueFailedOutcome, "blocked:rescue-failed")
        XCTAssertTrue(RescueRun.rescueFailedOutcome.hasPrefix("blocked:"),
                      "still a blocked:<reason>, so nothing reading that prefix has to special-case it")
    }

    // MARK: - buildRescueInitialState

    private func item(id: String = "item-1", title: String = "Some item") -> BacklogItem {
        BacklogItem(id: id, title: title, status: .awaitingApproval, type: .local)
    }

    /// AC: a rescue run is spawned with the conflicted paths in its prompt.
    func testConflictedPathsAppearInTheWorkerAndReviewerPrompt() {
        let state = BacklogAutopilot.buildRescueInitialState(
            item: item(), detail: nil, worktree: URL(fileURLWithPath: "/tmp/rescue"),
            exclusionReason: "merge conflict in: CHANGELOG.md",
            conflictedPaths: ["CHANGELOG.md", "Sources/Foo.swift"])

        let what = state["what"]?.stringValue ?? ""
        XCTAssertTrue(what.contains("CHANGELOG.md"), what)
        XCTAssertTrue(what.contains("Sources/Foo.swift"), what)
        XCTAssertTrue(what.contains("merge conflict in: CHANGELOG.md"), what)
    }

    /// AC: a rescue diff touching files outside the conflicted/integration
    /// surface is rejected by the reviewer round — checked here at the input
    /// the reviewer is actually handed, since `reviewerNodePrompt` renders
    /// `state.what` under "## What was requested".
    func testTheScopeConstraintNamesTheConflictedSurfaceForTheReviewer() {
        let state = BacklogAutopilot.buildRescueInitialState(
            item: item(), detail: nil, worktree: URL(fileURLWithPath: "/tmp/rescue"),
            exclusionReason: "merge conflict in: CHANGELOG.md",
            conflictedPaths: ["CHANGELOG.md"])

        let what = state["what"]?.stringValue ?? ""
        XCTAssertTrue(what.contains("Change nothing outside"), what)
        let acceptanceCriteria = state["acceptanceCriteria"]?.stringValue ?? ""
        XCTAssertTrue(acceptanceCriteria.contains("Nothing changes outside"), acceptanceCriteria)
        XCTAssertTrue(acceptanceCriteria.contains("CHANGELOG.md"), acceptanceCriteria)
    }

    /// The verify-red case has no conflicted paths to name — the constraint
    /// still reads sensibly, naming the verify's own surface instead.
    func testWithNoConflictedPathsTheScopeConstraintNamesTheVerifyInstead() {
        let state = BacklogAutopilot.buildRescueInitialState(
            item: item(), detail: nil, worktree: URL(fileURLWithPath: "/tmp/rescue"),
            exclusionReason: "verify failed on merged tree (merge-verify: swift build)",
            conflictedPaths: [])

        let what = state["what"]?.stringValue ?? ""
        XCTAssertTrue(what.contains("what the failing verify names"), what)
        XCTAssertFalse(what.contains("- \n"), "an empty conflicted-paths list must not leave a bare bullet")
    }

    /// The item's own `## Notes` are handed to the run through the same
    /// `previousFeedback` field a regroomed item's feedback already uses.
    func testTheItemsNotesReachTheRunAsPreviousFeedback() {
        var detail = BacklogItemDetail(id: "item-1", title: "Some item",
                                       verifyCommands: [], acceptanceCriteria: [], outOfScope: [])
        detail.notes = "- 2026-09-04 — merge conflict in: CHANGELOG.md"

        let state = BacklogAutopilot.buildRescueInitialState(
            item: item(), detail: detail, worktree: URL(fileURLWithPath: "/tmp/rescue"),
            exclusionReason: "merge conflict in: CHANGELOG.md", conflictedPaths: ["CHANGELOG.md"])

        XCTAssertEqual(state["previousFeedback"]?.stringValue?.contains(detail.notes!), true)
    }

    func testNoNotesMeansNoPreviousFeedbackField() {
        let state = BacklogAutopilot.buildRescueInitialState(
            item: item(), detail: nil, worktree: URL(fileURLWithPath: "/tmp/rescue"),
            exclusionReason: "merge conflict in: CHANGELOG.md", conflictedPaths: ["CHANGELOG.md"])
        XCTAssertNil(state["previousFeedback"])
    }

    func testTheTitleIsMarkedAsARescue() {
        let state = BacklogAutopilot.buildRescueInitialState(
            item: item(title: "Fix the thing"), detail: nil, worktree: URL(fileURLWithPath: "/tmp/rescue"),
            exclusionReason: "merge conflict in: CHANGELOG.md", conflictedPaths: ["CHANGELOG.md"])
        XCTAssertEqual(state["title"]?.stringValue, "Rescue: Fix the thing")
    }
}
