import XCTest
@testable import Kiteloop
import KiteloopCore

/// Covers the record a steer note leaves and the gate that decides whether
/// there is a worker to hand it to at all. What a note's text becomes on its
/// way to the worker — `sanitize` and `prompt` — is pure and asserted once, in
/// `KiteloopCoreTests`.
///
/// What is deliberately *not* faked here is the delivery turn — that needs a
/// live CLI session, and a test double for it would assert that the double
/// works. The seam it is delivered through (`ChatViewModel.runSteerNoteTurn`,
/// drained from `Orchestrator`) is covered by the queue tests below at its own
/// boundary: what goes in comes out once, and nothing comes out for an agent
/// nobody steered.
@MainActor
final class RunSteerNoteTests: XCTestCase {

    // MARK: - The record it leaves

    func testTranscriptLineNamesTheOperatorRatherThanShowingBareText() {
        let line = RunSteerNote.transcriptLine("try the other branch")
        XCTAssertTrue(line.contains("Operator"),
                      "a reader scrolling a run must be able to tell this from the worker's own prose")
        XCTAssertTrue(line.contains("try the other branch"))
    }

    /// `BacklogViewModel.appendNote` stamps the date; this carries the time,
    /// because a run's steers happen minutes apart and a date alone could not
    /// order them.
    func testItemNoteLineCarriesTheTimeAndTheNote() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 10
        components.hour = 14; components.minute = 32
        let when = Calendar(identifier: .gregorian).date(from: components)!

        let line = RunSteerNote.itemNoteLine("look at the FIFO reader", at: when)
        XCTAssertTrue(line.contains("14:32"), "got: \(line)")
        XCTAssertTrue(line.contains("look at the FIFO reader"))
    }

    // MARK: - The queue it waits in

    func testAQueuedNoteIsDeliveredOnceAndOnlyToTheAgentItWasSentTo() {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.queueSteerNote("use the worktree branch", for: "worker")

        XCTAssertTrue(orchestrator.takeSteerNotes(for: "reviewer").isEmpty,
                      "the reviewer's independence is part of what its verdict is worth")
        XCTAssertEqual(orchestrator.takeSteerNotes(for: "worker"), ["use the worktree branch"])
        XCTAssertTrue(orchestrator.takeSteerNotes(for: "worker").isEmpty,
                      "draining is destructive — a note must not be delivered twice")
    }

    func testAnAgentNobodySteeredHasNothingWaiting() {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        XCTAssertTrue(orchestrator.takeSteerNotes(for: "anyone").isEmpty,
                      "every agent in an ordinary chat is this case")
    }

    /// Notes queue in the order they were typed, so a correction that supersedes
    /// an earlier one is read after it.
    func testNotesKeepTheOrderTheyWereTypedIn() {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.queueSteerNote("one", for: "worker")
        orchestrator.queueSteerNote("two", for: "worker")

        XCTAssertEqual(orchestrator.takeSteerNotes(for: "worker"), ["one", "two"])
    }

    /// The run's cleanup path calls this. Without it, a note typed seconds
    /// before an item ended would be delivered to whatever that agent does next
    /// — an operator's correction about a finished item arriving in an unrelated
    /// chat.
    func testClearingLeavesNothingBehindForTheNextRun() {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.queueSteerNote("too late", for: "worker")
        orchestrator.clearSteerNotes(for: "worker")

        XCTAssertTrue(orchestrator.takeSteerNotes(for: "worker").isEmpty)
    }

    // MARK: - The gate

    /// An idle autopilot has no worker to reach, so the note is refused rather
    /// than queued for whatever runs next. This is what makes the panel's field
    /// a no-op with no run in flight instead of a delayed surprise.
    func testSteeringAnIdleAutopilotIsRefusedWithAReason() {
        let autopilot = BacklogAutopilot()
        XCTAssertFalse(autopilot.canSteer)

        guard case .refused(let reason) = autopilot.steerWorker("go left") else {
            return XCTFail("an idle autopilot has no worker to steer")
        }
        XCTAssertFalse(reason.isEmpty, "a refusal has to say what to do about it")
    }
}
