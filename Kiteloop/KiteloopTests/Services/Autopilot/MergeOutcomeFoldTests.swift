import XCTest
import KiteloopCore
@testable import Kiteloop

/// The join that makes `merged` answerable at all.
///
/// A run's metric row is written when the run ends; whether its branch reached
/// main is decided afterwards, at the gate. Every test here is about attaching
/// the second fact to the right instance of the first — and, at least as much,
/// about *not* attaching it to a run it doesn't describe. `merged` counts in the
/// report that says whether a night of unattended work was worth it, so a wrong
/// value is worse than the nil it replaces.
final class MergeOutcomeFoldTests: XCTestCase {

    // MARK: - An event that names its run

    /// The auto-merge case: the outcome is decided inside the run, so it can name
    /// the execution, and the id is what places it.
    func testAnEventNamingAnExecutionFoldsOntoThatRun() {
        let runs = [run(itemID: "a", execution: "exec-1"), run(itemID: "a", execution: "exec-2")]

        let folded = MergeOutcomeFold.apply([event(itemID: "a", merged: true, execution: "exec-2")], to: runs)

        XCTAssertNil(folded[0].merged, "the run the event didn't name says nothing")
        XCTAssertEqual(folded[1].merged, true)
    }

    /// The reason rule 1 does not fall back to rule 2. The auto-merge records its
    /// outcome *before* the run's row is appended, so at that moment the newest
    /// row belongs to the item's **previous** run — which is exactly the one
    /// answer a time comparison would give, and exactly the wrong one.
    func testAnEventNamingAnExecutionNeverFallsBackToTheNewestRun() {
        let earlier = run(itemID: "a", execution: "exec-1", completedAt: t(0))
        let events = [event(itemID: "a", merged: true, execution: "exec-2", at: t(60))]

        let beforeTheRowLands = MergeOutcomeFold.apply(events, to: [earlier])
        XCTAssertNil(beforeTheRowLands[0].merged,
                     "the previous run of the same item must not inherit this outcome")

        // …and it attaches the moment the row it names does land.
        let later = run(itemID: "a", execution: "exec-2", completedAt: t(120))
        let afterTheRowLands = MergeOutcomeFold.apply(events, to: [earlier, later])
        XCTAssertNil(afterTheRowLands[0].merged)
        XCTAssertEqual(afterTheRowLands[1].merged, true)
    }

    // MARK: - An event that names no run

    /// The human gate: the run ended and its row was written long before anyone
    /// looked at it, so the event is placed by time.
    func testAnEventNamingNoExecutionFoldsOntoTheItemsMostRecentFinishedRun() {
        let runs = [
            run(itemID: "a", execution: "exec-1", completedAt: t(0)),
            run(itemID: "a", execution: "exec-2", completedAt: t(100)),
            run(itemID: "a", execution: "exec-3", completedAt: t(500))
        ]

        let folded = MergeOutcomeFold.apply([event(itemID: "a", merged: true, at: t(200))], to: runs)

        XCTAssertEqual(folded.map(\.merged), [nil, true, nil],
                       "the newest run that had finished when the gate was resolved, not the newest of all")
    }

    /// A gate resolved before the item had ever finished a run describes no run
    /// here. Guessing at the next one would file an outcome against work that had
    /// not been done when it was decided.
    func testAnEventOlderThanEveryRunOfTheItemFoldsOntoNothing() {
        let runs = [run(itemID: "a", execution: "exec-1", completedAt: t(500))]

        let folded = MergeOutcomeFold.apply([event(itemID: "a", merged: true, at: t(100))], to: runs)

        XCTAssertNil(folded[0].merged)
    }

    // MARK: - What the fold refuses to touch

    /// Item ids are only unique within a project, and two projects running the
    /// same backlog id is ordinary.
    func testAnEventDoesNotCrossProjects() {
        let runs = [run(itemID: "a", project: "/tmp/alpha"), run(itemID: "a", project: "/tmp/beta")]

        let folded = MergeOutcomeFold.apply([event(itemID: "a", merged: true, project: "/tmp/beta")], to: runs)

        XCTAssertNil(folded[0].merged)
        XCTAssertEqual(folded[1].merged, true)
    }

    /// The same project written two ways is the same project — the paths in the
    /// two logs come from different callers.
    func testAnEventMatchesItsProjectByCanonicalPath() {
        let runs = [run(itemID: "a", project: "/tmp/alpha")]

        let folded = MergeOutcomeFold.apply([event(itemID: "a", merged: true, project: "/tmp/alpha/")], to: runs)

        XCTAssertEqual(folded[0].merged, true)
    }

    func testAnEventForAnotherItemFoldsOntoNothing() {
        let runs = [run(itemID: "a", execution: "exec-1")]

        let folded = MergeOutcomeFold.apply([event(itemID: "b", merged: true)], to: runs)

        XCTAssertNil(folded[0].merged)
    }

    /// The whole point of the nil: a run nobody has resolved a gate for is
    /// *unknown*, not "did not merge". The fold only ever writes an answer it was
    /// given.
    func testARunNoEventDescribesKeepsItsUnknown() {
        let runs = [run(itemID: "a", execution: "exec-1"), run(itemID: "b", execution: "exec-2")]

        let folded = MergeOutcomeFold.apply([event(itemID: "a", merged: false, execution: "exec-1")], to: runs)

        XCTAssertEqual(folded[0].merged, false, "recorded: it was decided, and the answer was no")
        XCTAssertNil(folded[1].merged, "not recorded: nobody said")
    }

    func testFoldingNoEventsChangesNothing() {
        let runs = [run(itemID: "a", execution: "exec-1")]

        XCTAssertEqual(MergeOutcomeFold.apply([], to: runs).map(\.merged), [nil])
    }

    /// Folding is done on every read back and on every append, so it has to be
    /// safe to repeat.
    func testFoldingTwiceLandsOnTheSameAnswer() {
        let runs = [run(itemID: "a", execution: "exec-1")]
        let events = [event(itemID: "a", merged: true, execution: "exec-1")]

        let once = MergeOutcomeFold.apply(events, to: runs)
        let twice = MergeOutcomeFold.apply(events, to: once)

        XCTAssertEqual(twice.map(\.merged), once.map(\.merged))
    }

    // MARK: - Several events for one run

    /// A merge refused at the gate and merged by hand afterwards: the last word
    /// is the one that stands.
    func testTheLastEventRecordedForARunWins() {
        let runs = [run(itemID: "a", execution: "exec-1", completedAt: t(0))]
        let events = [
            event(itemID: "a", merged: false, execution: "exec-1", at: t(10)),
            event(itemID: "a", merged: true, at: t(3000))
        ]

        XCTAssertEqual(MergeOutcomeFold.apply(events, to: runs)[0].merged, true)
    }

    /// …in both directions. A `true` already on record is not sticky.
    func testALaterEventCanTakeAMergeBack() {
        let runs = [run(itemID: "a", execution: "exec-1", completedAt: t(0))]
        let events = [
            event(itemID: "a", merged: true, execution: "exec-1", at: t(10)),
            event(itemID: "a", merged: false, execution: "exec-1", at: t(20))
        ]

        XCTAssertEqual(MergeOutcomeFold.apply(events, to: runs)[0].merged, false)
    }

    // MARK: - Fixtures

    // MARK: - Rows for attempts that never ran

    /// The trap a pickup refusal sets for rule 2. A refusal is written to the
    /// same ledger, and an item parked at the human gate is refused every time
    /// it is selected — so between the run that did the work and the gate being
    /// resolved there can sit a row for an attempt that never started. It would
    /// be the item's "most recent finished run", and the merge outcome would
    /// land on it while the work's own row kept `merged: nil`.
    func testARefusalAtPickupNeverTakesTheMergeOutcome() {
        let runs = [
            run(itemID: "a", execution: "exec-1", completedAt: t(0)),
            refusal(itemID: "a", at: t(100)),
        ]

        let folded = MergeOutcomeFold.apply([event(itemID: "a", merged: true, at: t(200))], to: runs)

        XCTAssertEqual(folded[0].merged, true, "the run that produced the work")
        XCTAssertNil(folded[1].merged, "not the attempt that never started")
    }

    /// And with nothing else to fold onto, the outcome folds onto nothing rather
    /// than onto the refusal.
    func testAnItemWhoseOnlyRowIsARefusalFoldsOntoNothing() {
        let folded = MergeOutcomeFold.apply([event(itemID: "a", merged: true, at: t(200))],
                                            to: [refusal(itemID: "a", at: t(100))])

        XCTAssertNil(folded[0].merged)
    }

    private func t(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_770_000_000 + offset)
    }

    private func run(itemID: String,
                     project: String = "/tmp/alpha",
                     execution: String? = "exec-1",
                     completedAt: Date? = nil) -> TaskMetricRecord {
        let end = completedAt ?? t(0)
        return TaskMetricRecord(
            projectPath: project, projectName: "alpha", itemID: itemID, title: "Task \(itemID)",
            epic: nil, declaredSize: "M", startedAt: end.addingTimeInterval(-600),
            completedAt: end, durationSeconds: 600, costUSD: 1.0, reviewerRetries: 0,
            outcome: "done", workerAgent: "Builder", reviewerAgent: "Reviewer",
            executionID: execution
        )
    }

    /// The row a pickup gate writes when it refuses the item — no branch, no
    /// execution, nothing for a merge outcome to be about.
    private func refusal(itemID: String, project: String = "/tmp/alpha",
                         at: Date) -> TaskMetricRecord {
        RetryCeiling.refusalRecord(
            item: BacklogItem(id: itemID, title: "Task \(itemID)", verify: nil, status: .ready,
                              type: .local, size: .s, queries: nil, cost: nil, completedDate: nil,
                              blockedReason: nil, jiraKey: nil, team: nil, detailPath: nil),
            refusal: .notGrounded, projectPath: project, projectName: "alpha", at: at)
    }

    private func event(itemID: String,
                       merged: Bool,
                       project: String = "/tmp/alpha",
                       execution: String? = nil,
                       at: Date? = nil) -> ItemMergeEvent {
        ItemMergeEvent(projectPath: project, projectName: "alpha", itemID: itemID,
                       merged: merged, at: at ?? t(60), executionID: execution)
    }
}
