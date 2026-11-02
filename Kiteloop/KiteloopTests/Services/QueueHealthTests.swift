import XCTest
import KiteloopCore
@testable import Kiteloop

/// How much of a project's `ready` column could actually start, and what holds
/// the rest.
///
/// The defect: a queue of 20 items none of which could run rendered exactly like
/// a healthy one, because the only number anything counted was how deep it was.
/// So what is asserted here is the *gap* — that it is computed, that it
/// reconciles, that the reasons for it survive to somewhere a human can read
/// them, and that a count taken off the ledger is never passed off as a live
/// verdict.
final class QueueHealthTests: XCTestCase {

    // MARK: - Fixtures

    private func item(_ id: String,
                      status: BacklogItemStatus = .ready,
                      verify: String? = "swift build",
                      size: ItemSize? = .m,
                      title: String? = nil,
                      needs: [String] = []) -> BacklogItem {
        BacklogItem(id: id, title: title ?? "Item \(id)", verify: verify, status: status,
                    type: .local, size: size, detailPath: "backlog/\(id).md", needs: needs)
    }

    /// A detail file that satisfies every clause, so anything not runnable is so
    /// for a reason the test states.
    private func detail(_ id: String,
                        verify: [BacklogItemDetail.VerifyCommand] =
                            [.init(name: "build", cmd: "swift build", expect: nil)],
                        what: String? = "The outcome.",
                        approach: String? = "Touch these files.",
                        criteria: [String] = ["It works"]) -> BacklogItemDetail {
        BacklogItemDetail(id: id, title: "Item \(id)", verifyCommands: verify,
                          acceptanceCriteria: criteria, outOfScope: [],
                          what: what, approach: approach)
    }

    /// The detail lookup. A test that wants an ungroomed item leaves it out of
    /// `groomed`; one that wants an item with no `verify:` anywhere names it in
    /// `unverified` **and** clears the item line's own command.
    ///
    /// Both halves are needed, which is the trap: `DefinitionOfReady` takes the
    /// groomed file's command in preference to the line's, so an item written
    /// with no `verify:` on its line is still runnable if its detail file
    /// carries one — the gate is satisfied and the clause never fires.
    private func lookup(groomed: Set<String>,
                        unverified: Set<String> = []) -> (BacklogItem) -> BacklogItemDetail? {
        { item in
            guard groomed.contains(item.id) else { return nil }
            return unverified.contains(item.id)
                ? self.detail(item.id, verify: [])
                : self.detail(item.id)
        }
    }

    private func refusal(_ clause: QueueHealth.Clause,
                         _ reason: String? = nil) -> QueueHealth.Refusal {
        QueueHealth.Refusal(clause: clause, reason: reason)
    }

    // MARK: - Ready versus runnable

    /// The whole point: a ready item the gate would refuse counts toward `ready`
    /// and not toward `runnable`, so a full queue that cannot run says so.
    func testUngroomedReadyItemsAreCountedReadyAndNotRunnable() {
        let health = QueueHealth.make(
            items: [item("a"), item("b"), item("c")],
            detail: lookup(groomed: ["a"]))

        XCTAssertEqual(health.ready, 3)
        XCTAssertEqual(health.runnable, 1)
        XCTAssertEqual(health.startable, 1)
        XCTAssertFalse(health.isStalled, "one item can still start")
    }

    /// The state that used to read as the healthiest project in the portfolio.
    func testAQueueNothingCanStartReportsItselfAsStalled() {
        let health = QueueHealth.make(
            items: (1...20).map { item("item-\($0)") },
            detail: lookup(groomed: []))

        XCTAssertEqual(health.ready, 20)
        XCTAssertEqual(health.runnable, 0)
        XCTAssertTrue(health.isStalled)
        XCTAssertFalse(health.isClear)
    }

    func testAFullyGroomedQueueReadsAsClear() {
        let health = QueueHealth.make(
            items: [item("a"), item("b")],
            detail: lookup(groomed: ["a", "b"]))

        XCTAssertEqual(health.runnable, 2)
        XCTAssertTrue(health.isClear)
        XCTAssertFalse(health.isStalled)
        XCTAssertEqual(health.withheld, [], "nothing is held, so nothing is listed")
    }

    /// Only ready items are judged. A draft is not runnable work and counting it
    /// as withheld would report a filed idea as a grooming failure.
    func testOnlyReadyItemsAreJudged() {
        let health = QueueHealth.make(
            items: [item("a"), item("draft-1", status: .draft), item("shipped", status: .done),
                    item("stuck", status: .blocked)],
            detail: lookup(groomed: ["a"]))

        XCTAssertEqual(health.ready, 1)
        XCTAssertEqual(health.runnable, 1)
        XCTAssertEqual(health.withheld, [])
    }

    func testStatusesAreCountedForTheStatesTheScreenReadsOn() {
        let health = QueueHealth.make(
            items: [item("a"), item("running", status: .active),
                    item("signoff", status: .awaitingApproval),
                    item("signoff-2", status: .awaitingApproval)],
            detail: lookup(groomed: ["a"]))

        XCTAssertEqual(health.active, 1)
        XCTAssertEqual(health.awaitingApproval, 2)
    }

    /// AC: the two states nothing used to count. An item on the reviewer and an
    /// item at `blocked` were each counted by none of the numbers, so a project
    /// whose whole backlog was stuck rendered as one with nothing left to do.
    func testItemsOnTheReviewerAndAtBlockedAreCounted() {
        let health = QueueHealth.make(
            items: [item("reviewing", status: .inReview),
                    item("stuck-1", status: .blocked), item("stuck-2", status: .blocked),
                    item("stuck-3", status: .blocked)],
            detail: lookup(groomed: []))

        XCTAssertEqual(health.inReview, 1)
        XCTAssertEqual(health.blocked, 3)
    }

    /// AC: neither count touches the numbers that reconcile against the `ready`
    /// column. A blocked item is not a withheld ready item, and a stalled queue
    /// reads exactly the same with fourteen of them beside it as without.
    func testInReviewAndBlockedItemsLeaveTheReadyColumnUntouched() {
        func build(withStuckWork: Bool) -> QueueHealth {
            let stuck = withStuckWork
                ? [item("reviewing", status: .inReview)]
                    + (1...14).map { item("stuck-\($0)", status: .blocked) }
                : []
            return QueueHealth.make(
                items: [item("a"), item("b", verify: nil)] + stuck,
                detail: lookup(groomed: ["a", "b"], unverified: ["b"]),
                refusals: ["a": refusal(.notGrounded, "cites Services/Nope.swift")])
        }
        let with = build(withStuckWork: true)
        let without = build(withStuckWork: false)

        XCTAssertEqual(with.ready, without.ready)
        XCTAssertEqual(with.runnable, without.runnable)
        XCTAssertEqual(with.heldAtPickup, without.heldAtPickup)
        XCTAssertEqual(with.startable, without.startable)
        XCTAssertEqual(with.isStalled, without.isStalled)
        XCTAssertEqual(with.isClear, without.isClear)
        XCTAssertEqual(with.withheld, without.withheld)
        XCTAssertTrue(with.isStalled, "the ready column is stalled in both")
        XCTAssertEqual(with.blocked, 14, "...and the stuck work is still counted")
    }

    // MARK: - The breakdown

    /// The reasons, grouped by the clause a human would act on, most common
    /// first — the breakdown that used to exist only in a run log.
    func testWithheldItemsAreGroupedByClauseMostCommonFirst() {
        let health = QueueHealth.make(
            items: [item("a", verify: nil), item("b", verify: nil), item("c", verify: nil),
                    item("d", size: .xl), item("e", size: nil)],
            detail: lookup(groomed: ["a", "b", "c", "d", "e"], unverified: ["a", "b", "c"]))

        XCTAssertEqual(health.withheld.map(\.clause), [.noVerify, .unsized, .tooBig])
        XCTAssertEqual(health.withheld.map(\.count), [3, 1, 1])
    }

    /// An ungroomed item usually fails several clauses at once. Counting it once
    /// per clause would report more withheld items than the column holds — the
    /// breakdown has to reconcile against the counts beside it.
    func testAnItemFailingSeveralClausesIsCountedOnce() {
        // No detail file, no verify, no size: three unmet requirements, one item.
        let health = QueueHealth.make(
            items: [item("a", verify: nil, size: nil)],
            detail: lookup(groomed: []))

        XCTAssertEqual(health.ready - health.runnable, 1)
        XCTAssertEqual(health.withheld.reduce(0) { $0 + $1.count }, 1)
        XCTAssertEqual(health.withheld.map(\.clause), [.notGroomed],
                       "grouped under the first thing to fix")
    }

    func testTheWithheldCountsReconcileAgainstReadyMinusRunnable() {
        let health = QueueHealth.make(
            items: [item("a"), item("b", verify: nil), item("c", size: .l),
                    item("d"), item("e", size: nil), item("f")],
            detail: lookup(groomed: ["a", "b", "c", "e", "f"], unverified: ["b"]))

        let held = health.withheld.reduce(0) { $0 + $1.count }
        XCTAssertEqual(held, health.ready - health.runnable)
    }

    func testEachUnmetRequirementIsGroupedUnderTheClauseAHumanActsOn() {
        let cases: [(DefinitionOfReady.Requirement, QueueHealth.Clause)] = [
            (.detail, .notGroomed), (.what, .notGroomed), (.how, .notGroomed),
            (.validation, .notGroomed), (.verify, .noVerify),
            (.verifySeparator, .malformedLine), (.titleSeparator, .malformedLine),
            (.size, .unsized), (.sizeTooLarge, .tooBig), (.qaProfile, .notOnboardedForQA),
            (.dependency, .waiting)
        ]
        for (requirement, clause) in cases {
            XCTAssertEqual(QueueHealth.Clause(requirement), clause, "\(requirement)")
        }
        XCTAssertEqual(Set(DefinitionOfReady.Requirement.allCases.map(QueueHealth.Clause.init)).count,
                       7, "every requirement maps somewhere, and several share a clause")
    }

    /// A clause carries one verdict verbatim, so the reader has something to go
    /// and fix rather than a category.
    func testAClauseCarriesOneVerdictVerbatim() {
        let health = QueueHealth.make(items: [item("a", verify: nil)],
                                      detail: lookup(groomed: ["a"], unverified: ["a"]))

        let example = try? XCTUnwrap(health.withheld.first?.example)
        XCTAssertEqual(example, "no verify: command — nothing objective for the run to pass")
    }

    // MARK: - Sequencing

    /// Dependencies are resolved against the whole file. An item waiting on
    /// something in another epic is waiting; one whose prerequisite shipped is
    /// not, and reporting it as held would send a groomer to fix nothing.
    func testAnItemWaitingOnUnfinishedWorkIsWithheldAndOneWaitingOnDoneWorkIsNot() {
        let health = QueueHealth.make(
            items: [item("waiting", needs: ["unfinished"]),
                    item("cleared", needs: ["shipped"]),
                    item("unfinished"),
                    item("shipped", status: .done)],
            detail: lookup(groomed: ["waiting", "cleared", "unfinished"]))

        XCTAssertEqual(health.ready, 3)
        XCTAssertEqual(health.runnable, 2, "`cleared` and `unfinished` — `waiting` is held")
        XCTAssertEqual(health.withheld.map(\.clause), [.waiting])
        XCTAssertEqual(health.withheld.first?.count, 1)
    }

    // MARK: - What the gates recorded

    /// `GroundingCheck` and `RetryCeiling` refuse items the Definition-of-Ready
    /// lets through, and neither is affordable on a landing screen. What they
    /// recorded is read instead — which is the whole of the gap that stalled this
    /// repo on 2026-08-11.
    func testRecordedRefusalsHoldItemsTheDefinitionOfReadyLetsThrough() {
        let health = QueueHealth.make(
            items: (1...20).map { item("item-\($0)") },
            detail: lookup(groomed: Set((1...20).map { "item-\($0)" })),
            refusals: Dictionary(uniqueKeysWithValues: (1...19).map {
                ("item-\($0)", refusal(.notGrounded, "cites Services/Nope.swift, which doesn't exist"))
            }))

        XCTAssertEqual(health.ready, 20)
        XCTAssertEqual(health.runnable, 20, "every item is inside the ODD...")
        XCTAssertEqual(health.heldAtPickup, 19, "...and 19 were refused after that")
        XCTAssertEqual(health.startable, 1)
        XCTAssertFalse(health.isStalled, "one item could still start")
        XCTAssertEqual(health.withheld.map(\.clause), [.notGrounded])
    }

    /// A refusal on record for an item the gate would now refuse anyway must not
    /// be counted twice — the item is held once, by the clause that answers now.
    func testARefusalOnAnItemThatIsNotRunnableAnywayIsNotCountedTwice() {
        let health = QueueHealth.make(
            items: [item("a", verify: nil)],
            detail: lookup(groomed: ["a"], unverified: ["a"]),
            refusals: ["a": refusal(.notGrounded)])

        XCTAssertEqual(health.runnable, 0)
        XCTAssertEqual(health.heldAtPickup, 0)
        XCTAssertEqual(health.withheld.map(\.clause), [.noVerify])
    }

    func testHeldItemsNeverOutnumberRunnableOnes() {
        let health = QueueHealth.make(
            items: [item("a"), item("b", verify: nil)],
            detail: lookup(groomed: ["a", "b"], unverified: ["b"]),
            refusals: ["a": refusal(.retired), "b": refusal(.retired)])

        XCTAssertEqual(health.runnable, 1)
        XCTAssertEqual(health.heldAtPickup, 1)
        XCTAssertEqual(health.startable, 0)
        XCTAssertTrue(health.isStalled)
    }

    // MARK: - Reading the ledger

    private func record(_ itemID: String, project: String, event: GroomingRecord.Event,
                        check: String? = nil, reason: String? = nil,
                        at: Date) -> GroomingRecord {
        GroomingRecord(at: at, projectPath: project, projectName: "p", itemID: itemID,
                       event: event, check: check, reason: reason)
    }

    func testRefusalsAreReadFromTheLedgerByCheck() {
        let now = Date()
        let refusals = QueueHealth.recordedRefusals([
            record("a", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.grounding, reason: "no such symbol", at: now),
            record("b", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.retryCeiling, reason: "3 attempts, no work", at: now)
        ], projectPath: "/tmp/p")

        XCTAssertEqual(refusals["a"], QueueHealth.Refusal(clause: .notGrounded,
                                                          reason: "no such symbol"))
        XCTAssertEqual(refusals["b"], QueueHealth.Refusal(clause: .retired,
                                                          reason: "3 attempts, no work"))
    }

    /// A recorded Definition-of-Ready refusal is dropped: that verdict is
    /// recomputed live, so an item refused last night and groomed this morning
    /// must not still be counted against a clause it no longer fails.
    func testARecordedDefinitionOfReadyRefusalIsNotReplayed() {
        let refusals = QueueHealth.recordedRefusals([
            record("a", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.definitionOfReady, reason: "no verify:", at: Date())
        ], projectPath: "/tmp/p")

        XCTAssertEqual(refusals, [:])
    }

    /// Releasing an item is a human lifting the ceiling's refusal. Reporting it
    /// as still held would contradict the pickup that is about to run it.
    func testAReleaseNewerThanTheRefusalClearsIt() {
        let now = Date()
        let refusals = QueueHealth.recordedRefusals([
            record("a", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.retryCeiling, reason: "retired", at: now - 60),
            record("a", project: "/tmp/p", event: .released,
                   check: GroomingRecord.Check.retryCeiling, reason: "re-attempt it", at: now)
        ], projectPath: "/tmp/p")

        XCTAssertEqual(refusals, [:])
    }

    /// A refusal recorded *after* a release still stands — the item was released,
    /// attempted again, and refused again.
    func testARefusalNewerThanTheReleaseStillHolds() {
        let now = Date()
        let refusals = QueueHealth.recordedRefusals([
            record("a", project: "/tmp/p", event: .released,
                   check: GroomingRecord.Check.retryCeiling, reason: "re-attempt it", at: now - 60),
            record("a", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.grounding, reason: "still ungrounded", at: now)
        ], projectPath: "/tmp/p")

        XCTAssertEqual(refusals["a"]?.clause, .notGrounded)
    }

    /// The ledger is portfolio-wide and item ids are only unique within a
    /// project, so an unscoped read would hand one project's refusal to another
    /// project's identically-named item.
    func testRefusalsAreScopedToTheProject() {
        let now = Date()
        let records = [
            record("shared-id", project: "/tmp/alpha", event: .checkFailed,
                   check: GroomingRecord.Check.grounding, reason: "alpha's", at: now),
            record("shared-id", project: "/tmp/beta", event: .checkFailed,
                   check: GroomingRecord.Check.retryCeiling, reason: "beta's", at: now)
        ]

        XCTAssertEqual(QueueHealth.recordedRefusals(records, projectPath: "/tmp/alpha")["shared-id"]?.reason,
                       "alpha's")
        XCTAssertEqual(QueueHealth.recordedRefusals(records, projectPath: "/tmp/beta")["shared-id"]?.reason,
                       "beta's")
        XCTAssertEqual(QueueHealth.recordedRefusals(records, projectPath: "/tmp/alpha").count, 1)
    }

    /// An empty ledger means "nothing on record", never "nothing refused" — the
    /// counts degrade to the live verdict rather than reporting a clear queue.
    func testAnEmptyLedgerHoldsNothing() {
        let health = QueueHealth.make(items: [item("a")], detail: lookup(groomed: ["a"]),
                                      refusals: QueueHealth.recordedRefusals([], projectPath: "/tmp/p"))

        XCTAssertEqual(health.heldAtPickup, 0)
        XCTAssertEqual(health.startable, 1)
    }

    // MARK: - A refusal older than the regroom that fixed it

    /// The defect: a `grounding-check` refusal recorded before the item's detail
    /// file was last edited must not still count against it — the item may no
    /// longer fail the clause it was refused for.
    func testAStaleGroundingRefusalIsDroppedByARegroom() {
        let refusedAt = Date()
        let groomedAt = refusedAt.addingTimeInterval(3600)
        let refusals = QueueHealth.recordedRefusals([
            record("a", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.grounding, reason: "no such symbol", at: refusedAt)
        ], projectPath: "/tmp/p", detailModified: { $0 == "a" ? groomedAt : nil })

        XCTAssertEqual(refusals, [:])
    }

    /// A refusal recorded *after* the item's detail file was last edited is a
    /// verdict on the item as it reads now, and stands.
    func testAFreshGroundingRefusalSurvivesARegroom() {
        let groomedAt = Date()
        let refusedAt = groomedAt.addingTimeInterval(3600)
        let refusals = QueueHealth.recordedRefusals([
            record("a", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.grounding, reason: "still no such symbol", at: refusedAt)
        ], projectPath: "/tmp/p", detailModified: { $0 == "a" ? groomedAt : nil })

        XCTAssertEqual(refusals["a"]?.clause, .notGrounded)
    }

    /// No known edit date means nothing is known to have changed — the reading
    /// is unchanged from before this parameter existed.
    func testARefusalWithNoKnownDetailDateIsKept() {
        let refusals = QueueHealth.recordedRefusals([
            record("a", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.grounding, reason: "no such symbol", at: Date())
        ], projectPath: "/tmp/p", detailModified: { _ in nil })

        XCTAssertEqual(refusals["a"]?.clause, .notGrounded)
    }

    /// `RetryCeiling`'s refusal is read back from the same ledger the same way,
    /// so it goes stale the same way.
    func testAStaleRetryCeilingRefusalIsDroppedTheSameWay() {
        let refusedAt = Date()
        let groomedAt = refusedAt.addingTimeInterval(3600)
        let refusals = QueueHealth.recordedRefusals([
            record("a", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.retryCeiling, reason: "3 attempts, no work", at: refusedAt)
        ], projectPath: "/tmp/p", detailModified: { $0 == "a" ? groomedAt : nil })

        XCTAssertEqual(refusals, [:])
    }

    /// A human's release still wins over a refusal regardless of the item's edit
    /// date — the same as today, just checked with a `detailModified` in play.
    func testAReleaseStillWinsWithADetailDateSupplied() {
        let now = Date()
        let refusals = QueueHealth.recordedRefusals([
            record("a", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.retryCeiling, reason: "retired", at: now - 60),
            record("a", project: "/tmp/p", event: .released,
                   check: GroomingRecord.Check.retryCeiling, reason: "re-attempt it", at: now)
        ], projectPath: "/tmp/p", detailModified: { $0 == "a" ? now.addingTimeInterval(-3600) : nil })

        XCTAssertEqual(refusals, [:])
    }

    /// End to end: a ready item held only by a stale refusal is not held at all
    /// — it counts toward `startable`, produces no `not grounded` entry in
    /// `withheld`, and the counts still reconcile against `ready`.
    func testAReadyItemHeldOnlyByAStaleRefusalCountsAsStartable() {
        let refusedAt = Date()
        let groomedAt = refusedAt.addingTimeInterval(3600)
        let refusals = QueueHealth.recordedRefusals([
            record("a", project: "/tmp/p", event: .checkFailed,
                   check: GroomingRecord.Check.grounding, reason: "no such symbol", at: refusedAt)
        ], projectPath: "/tmp/p", detailModified: { $0 == "a" ? groomedAt : nil })

        let health = QueueHealth.make(items: [item("a")], detail: lookup(groomed: ["a"]),
                                      refusals: refusals)

        XCTAssertEqual(health.ready, 1)
        XCTAssertEqual(health.runnable, 1)
        XCTAssertEqual(health.heldAtPickup, 0)
        XCTAssertEqual(health.startable, 1)
        XCTAssertEqual(health.withheld, [], "the stale refusal produces no withholding")
    }

    // MARK: - The one honest line

    func testAClearQueueSaysSo() {
        let health = QueueHealth.make(items: [item("a"), item("b")],
                                      detail: lookup(groomed: ["a", "b"]))

        XCTAssertEqual(health.summary, "2 ready, all runnable")
    }

    func testAStalledQueueNamesTheReasons() {
        let health = QueueHealth.make(
            items: (1...20).map { item("item-\($0)", verify: $0 == 20 ? nil : "swift build") },
            detail: lookup(groomed: Set((1...20).map { "item-\($0)" }), unverified: ["item-20"]),
            refusals: Dictionary(uniqueKeysWithValues: (1...19).map {
                ("item-\($0)", refusal(.notGrounded))
            }))

        XCTAssertEqual(health.summary,
                       "20 ready, none can start — 19 not grounded, 1 no verify: command")
    }

    func testAPartlyHeldQueueSaysHowManyCanStart() {
        let health = QueueHealth.make(
            items: [item("a"), item("b"), item("c", size: .l)],
            detail: lookup(groomed: ["a", "b", "c"]))

        XCTAssertEqual(health.summary, "3 ready, 2 can start — 1 too big for autopilot")
    }

    /// AC: a project with nothing ready but items at the gate is not an idle one.
    func testNothingReadyWithWorkAtTheGateIsDistinguishableFromIdle() {
        let waiting = QueueHealth.make(
            items: [item("signoff", status: .awaitingApproval),
                    item("signoff-2", status: .awaitingApproval)],
            detail: lookup(groomed: []))
        let idle = QueueHealth.make(items: [item("shipped", status: .done)],
                                    detail: lookup(groomed: []))

        XCTAssertEqual(waiting.summary, "Nothing ready · 2 awaiting your approval")
        XCTAssertEqual(idle.summary, "Nothing ready")
        XCTAssertNotEqual(waiting.summary, idle.summary)
    }

    func testNothingReadyWithAnItemInFlightSaysWhatItIsDoing() {
        let health = QueueHealth.make(items: [item("running", status: .active)],
                                      detail: lookup(groomed: []))

        XCTAssertEqual(health.summary, "Nothing ready · 1 in flight")
    }

    /// AC: a backlog of nothing but ungroomed drafts is a grooming bottleneck,
    /// not a finished project — and it used to render the same sentence as one.
    func testABacklogOfNothingButDraftsIsNotAnEmptyOne() {
        let health = QueueHealth.make(
            items: (1...60).map { item("draft-\($0)", status: .draft) },
            detail: lookup(groomed: []))

        XCTAssertEqual(health.drafts, 60)
        XCTAssertEqual(health.ready, 0)
        XCTAssertEqual(health.runnable, 0)
        XCTAssertEqual(health.summary, "Nothing ready · 60 ungroomed drafts")
        XCTAssertNotEqual(health.summary, QueueHealth.empty.summary)
    }

    /// AC: the failure this item exists for. Nothing ready, one item on the
    /// reviewer and fourteen at `blocked` is a backlog that is stuck solid, and
    /// it rendered the sentence a finished project renders.
    func testABacklogStuckInReviewAndBlockedIsNotAnIdleOne() {
        let health = QueueHealth.make(
            items: [item("reviewing", status: .inReview)]
                + (1...14).map { item("stuck-\($0)", status: .blocked) },
            detail: lookup(groomed: []))

        XCTAssertEqual(health.ready, 0)
        XCTAssertEqual(health.summary, "Nothing ready · 1 in review · 14 blocked")
        XCTAssertNotEqual(health.summary, QueueHealth.empty.summary)
    }

    /// Each of the two stands on its own — a project with only blocked work says
    /// so without an in-review clause it has no items for.
    func testEachStuckStateIsNamedOnItsOwn() {
        let reviewing = QueueHealth.make(items: [item("reviewing", status: .inReview)],
                                         detail: lookup(groomed: []))
        let stuck = QueueHealth.make(items: [item("stuck", status: .blocked)],
                                     detail: lookup(groomed: []))

        XCTAssertEqual(reviewing.summary, "Nothing ready · 1 in review")
        XCTAssertEqual(stuck.summary, "Nothing ready · 1 blocked")
    }

    /// The clauses sit in the order work moves through them, and no one of them
    /// replaces another.
    func testTheStuckClausesFollowTheInFlightOneAndPrecedeTheDrafts() {
        let health = QueueHealth.make(
            items: [item("running", status: .active), item("reviewing", status: .inReview),
                    item("stuck", status: .blocked), item("draft-1", status: .draft),
                    item("signoff", status: .awaitingApproval)],
            detail: lookup(groomed: []))

        XCTAssertEqual(health.summary,
                       "Nothing ready · 1 in flight · 1 in review · 1 blocked · "
                       + "1 ungroomed draft · 1 awaiting your approval")
    }

    /// The stuck states are named only where the ready column is empty, like the
    /// drafts: a project with work it can start has already answered the question
    /// the clause exists for.
    func testInReviewAndBlockedDoNotChangeTheLineForAQueueWithReadyItemsInIt() {
        let health = QueueHealth.make(
            items: [item("a"), item("b"), item("reviewing", status: .inReview)]
                + (1...14).map { item("stuck-\($0)", status: .blocked) },
            detail: lookup(groomed: ["a", "b"]))

        XCTAssertEqual(health.inReview, 1)
        XCTAssertEqual(health.blocked, 14)
        XCTAssertEqual(health.summary, "2 ready, all runnable")
    }

    func testOneDraftReadsSingular() {
        let health = QueueHealth.make(items: [item("draft-1", status: .draft)],
                                      detail: lookup(groomed: []))

        XCTAssertEqual(health.summary, "Nothing ready · 1 ungroomed draft")
    }

    /// The in-flight clause keeps its own phrasing; the drafts follow it rather
    /// than replacing it.
    func testNothingReadyWithBothARunInFlightAndDraftsSaysBoth() {
        let health = QueueHealth.make(
            items: [item("running", status: .active), item("draft-1", status: .draft),
                    item("draft-2", status: .draft)],
            detail: lookup(groomed: []))

        XCTAssertEqual(health.summary, "Nothing ready · 1 in flight · 2 ungroomed drafts")
    }

    /// The drafts are named only where the ready column is empty. A project with
    /// work it can start has already answered the question the clause exists for.
    func testDraftsDoNotChangeTheLineForAQueueWithReadyItemsInIt() {
        let health = QueueHealth.make(
            items: [item("a"), item("b")] + (1...9).map { item("draft-\($0)", status: .draft) },
            detail: lookup(groomed: ["a", "b"]))

        XCTAssertEqual(health.drafts, 9)
        XCTAssertEqual(health.summary, "2 ready, all runnable")
    }

    func testAQueueThatIsBothHeldAndAtTheGateSaysBoth() {
        let health = QueueHealth.make(
            items: [item("a", verify: nil), item("signoff", status: .awaitingApproval)],
            detail: lookup(groomed: ["a"], unverified: ["a"]))

        XCTAssertEqual(health.summary,
                       "1 ready, none can start — 1 no verify: command · 1 awaiting your approval")
    }

    /// The line sits under a project name, so it stops counting — and says that
    /// it stopped, because a capped list read as a complete one is the failure
    /// worth spending characters against.
    func testTheSummaryCapsTheClausesItNamesAndSaysWhatItLeftOut() {
        let health = QueueHealth.make(
            items: [item("a", verify: nil), item("b", size: nil), item("c", size: .xl),
                    item("d", needs: ["nope"])],
            detail: lookup(groomed: ["a", "b", "c", "d"], unverified: ["a"]))

        XCTAssertEqual(health.withheld.count, 4)
        XCTAssertTrue(health.reasonsPhrase.hasSuffix("+1 more"), health.reasonsPhrase)
        XCTAssertEqual(health.reasonsPhrase.split(separator: ",").count,
                       QueueHealth.summaryClauseLimit + 1)
    }

    /// Two projects in the same state read the same way — a clause tie is broken
    /// by declaration order, never by dictionary iteration.
    func testTwoQueuesInTheSameStateRenderIdentically() {
        func build() -> QueueHealth {
            QueueHealth.make(items: [item("a", verify: nil), item("b", size: .xl)],
                             detail: lookup(groomed: ["a", "b"], unverified: ["a"]))
        }
        for _ in 0..<20 {
            XCTAssertEqual(build().summary, "2 ready, none can start — 1 no verify: command, 1 too big for autopilot")
        }
    }

    // MARK: - The line inside an open project

    /// The panel's line is the queue and nothing else. The gate box directly
    /// under it names every item waiting on a human and carries the buttons that
    /// resolve it, so the clause `summary` ends with would be saying it twice —
    /// and everything before that clause is identical, because the two surfaces
    /// are answering one question.
    func testTheOpenProjectLineLeavesTheApprovalClauseToTheGateBeneathIt() {
        let health = QueueHealth.make(
            items: [item("a"), item("b", size: .l), item("signoff", status: .awaitingApproval)],
            detail: lookup(groomed: ["a", "b"]))

        XCTAssertEqual(health.queueSummary, "2 ready, 1 can start — 1 too big for autopilot")
        XCTAssertEqual(health.summary, health.queueSummary + " · 1 awaiting your approval")
    }

    /// AC: with every ready item startable there is no held clause to list, so
    /// the line names none.
    func testAClearQueueCarriesNoHeldClausesInTheOpenProjectLine() {
        let health = QueueHealth.make(items: [item("a"), item("b")],
                                      detail: lookup(groomed: ["a", "b"]))

        XCTAssertEqual(health.startable, health.ready)
        XCTAssertTrue(health.withheld.isEmpty)
        XCTAssertEqual(health.queueSummary, "2 ready, all runnable")
        XCTAssertFalse(health.queueSummary.contains("—"), health.queueSummary)
    }

    /// What a gate recorded holds the item here exactly as it does on the
    /// landing screen: `startable` is the number the line states, not `runnable`.
    func testTheOpenProjectLineCountsStartableRatherThanRunnable() {
        let health = QueueHealth.make(
            items: [item("a"), item("b"), item("c")],
            detail: lookup(groomed: ["a", "b", "c"]),
            refusals: ["a": refusal(.notGrounded), "b": refusal(.retired)])

        XCTAssertEqual(health.runnable, 3)
        XCTAssertEqual(health.startable, 1)
        XCTAssertEqual(health.queueSummary,
                       "3 ready, 1 can start — 1 not grounded, 1 retired by the retry ceiling")
    }

    /// With nothing at the gate the two surfaces say the same sentence, so a
    /// screenshot of the panel and one of the card cannot disagree about whether
    /// a project has anything to run.
    func testTheOpenProjectLineIsTheWholeSummaryWhenNothingIsAtTheGate() {
        let health = QueueHealth.make(items: (1...20).map { item("item-\($0)") },
                                      detail: lookup(groomed: []))

        XCTAssertEqual(health.queueSummary, health.summary)
        XCTAssertEqual(health.queueSummary, "20 ready, none can start — 20 not groomed")
    }

    /// An empty ready column still says which of the silent states it is: the
    /// panel gets the same clauses the card does, not a blank line.
    func testTheOpenProjectLineStillNamesAnEmptyReadyColumnsState() {
        let health = QueueHealth.make(
            items: [item("running", status: .active)]
                + (1...3).map { item("draft-\($0)", status: .draft) },
            detail: lookup(groomed: []))

        XCTAssertEqual(health.queueSummary, "Nothing ready · 1 in flight · 3 ungroomed drafts")
    }

    // MARK: - A project with no backlog

    func testTheEmptyQueueIsNotAStalledOne() {
        XCTAssertFalse(QueueHealth.empty.isStalled)
        XCTAssertFalse(QueueHealth.empty.isClear)
        XCTAssertEqual(QueueHealth.empty.startable, 0)
        XCTAssertEqual(QueueHealth.empty.inReview, 0)
        XCTAssertEqual(QueueHealth.empty.blocked, 0)
        XCTAssertEqual(QueueHealth.empty.summary, "Nothing ready")
    }

    /// AC: the state the new clauses must not fire on. A finished backlog is the
    /// one project that has earned the bare sentence, so nothing trails it.
    func testAFinishedBacklogStillReadsAsThePlainLine() {
        let health = QueueHealth.make(items: (1...5).map { item("shipped-\($0)", status: .done) },
                                      detail: lookup(groomed: []))

        XCTAssertEqual(health.inReview, 0)
        XCTAssertEqual(health.blocked, 0)
        XCTAssertEqual(health.summary, "Nothing ready")
    }

    /// A backlog with nothing in it at all is still the plain line — and the
    /// hand-written `empty` still stands for exactly what building one produces.
    func testABacklogWithNoItemsAtAllReadsAsTheEmptyQueue() {
        let health = QueueHealth.make(items: [], detail: lookup(groomed: []))

        XCTAssertEqual(health.drafts, 0)
        XCTAssertEqual(health.summary, "Nothing ready")
        XCTAssertEqual(health, QueueHealth.empty)
    }

    // MARK: - The fleet

    /// The failure was fleet-level: two of three projects stalled for different
    /// reasons while the third was fine, and a total would have hidden exactly
    /// that.
    func testTheFleetLineNamesTheStalledProjects() {
        let stalled = QueueHealth.make(items: (1...20).map { item("i-\($0)") },
                                       detail: lookup(groomed: []))
        let other = QueueHealth.make(items: [item("x")], detail: lookup(groomed: []))

        let line = QueueHealth.fleetStallLine([("kiteloop", stalled), ("travel", other)])

        XCTAssertEqual(line, "21 ready in 2 projects that can't start — kiteloop, travel")
    }

    func testTheFleetLineIsAbsentWhenNothingIsStalled() {
        XCTAssertNil(QueueHealth.fleetStallLine([]))
    }

    func testTheFleetLineCapsTheNamesAndSaysWhatItLeftOut() {
        let stalled = QueueHealth.make(items: [item("a")], detail: lookup(groomed: []))
        let line = QueueHealth.fleetStallLine(
            ["one", "two", "three", "four", "five"].map { ($0, stalled) })

        XCTAssertEqual(line, "5 ready in 5 projects that can't start — one, two, three +2 more")
    }

    func testTheFleetLineReadsSingularForOneProject() {
        let stalled = QueueHealth.make(items: [item("a")], detail: lookup(groomed: []))

        XCTAssertEqual(QueueHealth.fleetStallLine([("kiteloop", stalled)]),
                       "1 ready in 1 project that can't start — kiteloop")
    }
}
