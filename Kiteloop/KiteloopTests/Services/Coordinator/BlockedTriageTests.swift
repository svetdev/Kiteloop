import XCTest
import KiteloopCore
@testable import Kiteloop

/// The blocked pile's decision half: which failures are re-runnable, which need
/// feedback, and which have failed often enough that a third attempt is just
/// spending.
///
/// Every case here is built from what a run *records* — an outcome, a reason, a
/// duration, a cost, judge dimensions, whether the branch has commits. Nothing
/// re-runs anything, which is the property under test as much as the verdicts
/// are.
final class BlockedTriageTests: XCTestCase {

    // MARK: - Helpers

    private func blockedRun(reason: String? = nil, duration: Double = 600,
                            cost: Double = 4.20, dimensions: [String: Double]? = nil,
                            branchHasCommits: Bool? = nil,
                            at: Date = Date()) -> BlockedTriage.Run {
        BlockedTriage.Run(outcome: "blocked", reason: reason, durationSeconds: duration,
                          costUSD: cost, qualityScore: nil, judgeDimensions: dimensions,
                          completedAt: at, branchHasCommits: branchHasCommits)
    }

    private func signals(_ runs: [BlockedTriage.Run],
                         retries: Int = 0) -> BlockedTriage.Signals {
        BlockedTriage.Signals(itemID: "stuck-item", title: "Something stuck",
                              runs: runs, lifetimeRetries: retries)
    }

    // MARK: - Retry: the failure was environmental

    /// The dead-session signature the item was written for: a run that produced
    /// an empty worktree in near-zero time.
    func testEmptyWorktreeInNearZeroTimeIsRetried() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "max retries", duration: 3, cost: 2.50, branchHasCommits: false)
        ]))
        XCTAssertEqual(verdict.disposition, .retry)
        XCTAssertEqual(verdict.failure, .producedNothing)
        XCTAssertTrue(verdict.reason.contains("re-runnable unchanged"), verdict.reason)
    }

    /// The other half of the same signature: no billable work at all. Reuses the
    /// app's own `isNoWorkBlock` threshold, so a branch nobody looked at is not
    /// needed to spot it.
    func testNoBillableWorkInNearZeroTimeIsRetried() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "review did not pass", duration: 2, cost: 0.001)
        ]))
        XCTAssertEqual(verdict.disposition, .retry)
        XCTAssertEqual(verdict.failure, .producedNothing)
    }

    /// A cost cap that killed a run with the work already done — one of the five
    /// items merged by hand on 2026-08-07.
    func testCostCapKillIsRetried() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "session cost cap $16.00 exceeded ($16.95) on reviewer",
                       duration: 3_000, cost: 16.95)
        ]))
        XCTAssertEqual(verdict.disposition, .retry)
        XCTAssertEqual(verdict.failure, .costCapped)
    }

    func testStallIsRetried() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "stalled: no progress for 20 min on worker", duration: 1_500)
        ]))
        XCTAssertEqual(verdict.disposition, .retry)
        XCTAssertEqual(verdict.failure, .stalled)
    }

    /// A long, expensive run says nothing was empty about it, whatever the
    /// branch probe couldn't tell us. `nil` is "nobody looked", never "no".
    func testUnknownBranchStateIsNotEvidenceOfAnEmptyWorktree() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "review did not pass", duration: 4, cost: 3.10,
                       branchHasCommits: nil)
        ]))
        XCTAssertEqual(verdict.failure, .reviewRejected)
        XCTAssertNotEqual(verdict.disposition, .retry)
    }

    // MARK: - Regroom: the failure was substantive

    func testVerifyFailureIsRegroomedWithFeedback() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "review did not pass", duration: 1_800, cost: 6.40,
                       dimensions: ["verify_passed": 0, "scope_respected": 1,
                                    "tests_meaningful": 1, "conventions": 1])
        ]))
        XCTAssertEqual(verdict.failure, .verifyFailed)
        guard case .regroom(let feedback) = verdict.disposition else {
            return XCTFail("expected regroom, got \(verdict.disposition)")
        }
        XCTAssertTrue(feedback.contains("verify_passed"), feedback)
        XCTAssertTrue(feedback.contains("review did not pass"), feedback)
    }

    func testReviewerRejectionIsRegroomed() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "review did not pass", duration: 1_200, cost: 5)
        ]))
        XCTAssertEqual(verdict.failure, .reviewRejected)
        XCTAssertEqual(verdict.disposition.name, "regroom")
    }

    /// Retry needs positive evidence: a reason nothing recognises is substantive
    /// by default, because re-running what you can't explain is just spending.
    func testUnrecognisedReasonIsRegroomedRatherThanRetried() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "the sky fell in", duration: 900, cost: 3)
        ]))
        XCTAssertEqual(verdict.failure, .unrecognised)
        XCTAssertEqual(verdict.disposition.name, "regroom")
    }

    /// A coverage gap is the verify never being *asked*, not failing — and its
    /// remedy is mechanical, so the verdict carries the commands to add. Sent
    /// back with only a note, the same gate refused the same diff on the next
    /// run: 12 items circled that way on 2026-08-24, 36 runs for nothing.
    func testACoverageGapIsRegroomedWithTheCommandsToWiden() {
        let gap = "diff touches **/*.swift (2 files: A.swift, ATests.swift) but verify never runs "
            + "`./quality/bin/check-complexity.sh`; diff touches **/*.swift (2 files: A.swift, "
            + "ATests.swift) but verify never runs `./quality/bin/check-layering.py`"
        let verdict = BlockedTriage.classify(signals([blockedRun(reason: gap, duration: 900, cost: 4)]))
        XCTAssertEqual(verdict.failure, .verifyUncovered)
        XCTAssertEqual(verdict.disposition.name, "regroom")
        XCTAssertEqual(verdict.missingVerifyCommands,
                       ["./quality/bin/check-complexity.sh", "./quality/bin/check-layering.py"])
    }

    /// The other verify failures carry nothing to widen — there is no command a
    /// failing build is missing.
    func testAVerifyFailureCarriesNoCommandsToWiden() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "verify failed: exit 65", duration: 900, cost: 4)
        ]))
        XCTAssertEqual(verdict.failure, .verifyFailed)
        XCTAssertEqual(verdict.missingVerifyCommands, [])
    }

    // MARK: - Escalate

    func testSameFailureTwiceIsEscalatedNotRetried() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "stalled: no progress for 20 min on worker", duration: 1_500),
            blockedRun(reason: "stalled: no progress for 20 min on reviewer", duration: 1_500)
        ]))
        XCTAssertEqual(verdict.disposition, .escalate)
        XCTAssertTrue(verdict.reason.contains("failed the same way 2 times"), verdict.reason)
    }

    /// The same words twice is the item's defect, not the runs': the verdict
    /// says so and sends the reader to the How. Merely the same class, with
    /// different words, says nothing more than it did.
    func testTheSameStatedReasonTwiceNamesTheItemAsTheDefect() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "review did not pass: deviates from the prescribed regex backreference", duration: 1_200, cost: 5),
            blockedRun(reason: "Review did not pass: deviates from the prescribed regex backreference.", duration: 1_100, cost: 5)
        ]))
        XCTAssertEqual(verdict.disposition, .escalate)
        XCTAssertTrue(verdict.reason.contains("same stated reason"), verdict.reason)
        XCTAssertTrue(verdict.reason.contains("regroom the item"), verdict.reason)

        let sameClassOnly = BlockedTriage.classify(signals([
            blockedRun(reason: "stalled: no progress for 20 min on worker", duration: 1_500),
            blockedRun(reason: "stalled: no progress for 20 min on reviewer", duration: 1_500)
        ]))
        XCTAssertFalse(sameClassOnly.reason.contains("same stated reason"), sameClassOnly.reason)
    }

    /// Two different failures are two accidents, not a pattern — the newest one
    /// still decides.
    func testTwoDifferentFailuresAreNotAPattern() {
        let verdict = BlockedTriage.classify(signals([
            blockedRun(reason: "stalled: no progress for 20 min on worker", duration: 1_500),
            blockedRun(reason: "review did not pass", duration: 1_200, cost: 5)
        ]))
        XCTAssertEqual(verdict.disposition, .retry)
    }

    func testItemWithNoBlockedRunOnRecordIsEscalatedRatherThanGuessedAt() {
        let verdict = BlockedTriage.classify(signals([]))
        XCTAssertEqual(verdict.disposition, .escalate)
        XCTAssertTrue(verdict.reason.contains("no blocked run on record"), verdict.reason)
    }

    /// A `done` run says nothing about why this item is stuck now.
    func testNonBlockedRunsAreNotClassifiedFrom() {
        let verdict = BlockedTriage.classify(signals([
            BlockedTriage.Run(outcome: "done", durationSeconds: 900, costUSD: 4)
        ]))
        XCTAssertEqual(verdict.disposition, .escalate)
    }

    // MARK: - The lifetime retry ceiling

    func testRetryCeilingEscalatesAnOtherwiseRetryableItem() {
        let run = blockedRun(reason: "session cost cap $8.00 exceeded ($8.10) on worker",
                             duration: 2_000, cost: 8.10)
        let policy = BlockedTriage.Policy(maxLifetimeRetries: 2)

        XCTAssertEqual(BlockedTriage.classify(signals([run], retries: 1), policy: policy)
                        .disposition, .retry)

        let spent = BlockedTriage.classify(signals([run], retries: 2), policy: policy)
        XCTAssertEqual(spent.disposition, .escalate)
        XCTAssertTrue(spent.reason.contains("lifetime ceiling is 2"), spent.reason)
    }

    /// The ceiling is read from the ledger on disk, and only *applied* retries
    /// count — so a new pass and a new launch both
    /// leave it exactly where it was.
    func testLedgerRetryCountIsLifetimeAndCountsOnlyAppliedRetries() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "triage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        for (disposition, applied) in [("retry", true), ("retry", false),
                                       ("regroom", true), ("escalate", false)] {
            BlockedTriage.Ledger.append(
                BlockedTriage.Ledger.Entry(at: Date(), project: "kiteloop", itemID: "a",
                                           disposition: disposition, reason: "because",
                                           applied: applied),
                to: url)
        }

        // Reloaded from disk — the state a *new pass* and a new launch both see.
        let reloaded = BlockedTriage.Ledger.load(from: url)
        XCTAssertEqual(reloaded.retries(project: "kiteloop", itemID: "a"), 1)
        XCTAssertEqual(reloaded.history(project: "kiteloop", itemID: "a").count, 4)
        // Scoped per project: the same id in another repo is another item.
        XCTAssertEqual(reloaded.retries(project: "travel", itemID: "a"), 0)
    }

    func testLedgerSkipsCorruptLinesRatherThanLosingEveryCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "triage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        BlockedTriage.Ledger.append(
            BlockedTriage.Ledger.Entry(at: Date(), project: "kiteloop", itemID: "a",
                                       disposition: "retry", reason: "because", applied: true),
            to: url)
        try (try String(contentsOf: url, encoding: .utf8) + "{ not json\n")
            .write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(BlockedTriage.Ledger.load(from: url)
                        .retries(project: "kiteloop", itemID: "a"), 1)
    }

    /// A line whose bytes stop part-way through a multi-byte character is not
    /// UTF-8. Reading the ledger as one string failed on it and loaded nothing,
    /// so the item's retry count went back to zero; the entries on both sides of
    /// it load now.
    func testALineEndingMidCharacterDoesNotResetTheRetryCount() throws {
        let url = try makeTemporaryDirectory(prefix: "triage").appending(path: "triage.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var bytes = Data()
        for reason in ["first", "second"] {
            let entry = BlockedTriage.Ledger.Entry(at: Date(), project: "kiteloop", itemID: "a",
                                                   disposition: "retry", reason: reason, applied: true)
            bytes.append(try encoder.encode(entry))
            bytes.append(UInt8(ascii: "\n"))
            if reason == "first" {
                // "é" is 0xC3 0xA9; the kill landed between the two bytes.
                bytes.append(Data("{\"reason\":\"caf".utf8) + [0xC3, UInt8(ascii: "\n")])
            }
        }
        try bytes.write(to: url)

        let reloaded = BlockedTriage.Ledger.load(from: url)

        XCTAssertEqual(reloaded.history(project: "kiteloop", itemID: "a").map(\.reason),
                       ["first", "second"])
        XCTAssertEqual(reloaded.retries(project: "kiteloop", itemID: "a"), 2)
    }

    func testAMissingLedgerLoadsEmpty() throws {
        let url = try makeTemporaryDirectory(prefix: "triage").appending(path: "absent.jsonl")

        XCTAssertTrue(BlockedTriage.Ledger.load(from: url).history(project: "kiteloop", itemID: "a").isEmpty)
    }

    /// And the entry appended *after* the crash keeps its own line. Appending
    /// straight onto the remnant would glue the two into something that decodes
    /// as neither, so the retry recorded after the crash would not count against
    /// the lifetime ceiling and the item would be tried past it.
    func testAnEntryAppendedAfterATruncatedLineIsReadBackOnTheNextLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "triage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        BlockedTriage.Ledger.append(
            BlockedTriage.Ledger.Entry(at: Date(), project: "kiteloop", itemID: "a",
                                       disposition: "retry", reason: "first", applied: true),
            to: url)
        // The shape a kill mid-append leaves: half an entry, no newline after it.
        try appendRaw("{\"project\":\"kite", to: url)

        BlockedTriage.Ledger.append(
            BlockedTriage.Ledger.Entry(at: Date(), project: "kiteloop", itemID: "a",
                                       disposition: "retry", reason: "second", applied: true),
            to: url)

        let reloaded = BlockedTriage.Ledger.load(from: url)
        XCTAssertEqual(reloaded.history(project: "kiteloop", itemID: "a").map(\.reason),
                       ["first", "second"],
                       "the triage recorded after the crash survives")
        XCTAssertEqual(reloaded.retries(project: "kiteloop", itemID: "a"), 2)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("{\"project\":\"kite\n"),
                      "the remnant is still there, on its own line, and still skipped by the loader")
    }

    /// The ordinary append is unchanged by the repair: a file already ending in
    /// a newline gains one line, not a blank one before it.
    func testAppendingIntoALedgerEndingInANewlineAddsNoBlankLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "triage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        for reason in ["first", "second"] {
            BlockedTriage.Ledger.append(
                BlockedTriage.Ledger.Entry(at: Date(), project: "kiteloop", itemID: "a",
                                           disposition: "retry", reason: reason, applied: true),
                to: url)
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("\n\n"), "no blank line between the entries")
        XCTAssertEqual(BlockedTriage.Ledger.load(from: url)
                        .history(project: "kiteloop", itemID: "a").count, 2)
    }

    /// The ledger lives beside the coordinator's other logs, in a directory a
    /// fresh install has not created yet.
    func testAppendingIntoADirectoryThatDoesNotExistYetStillLands() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "triage-\(UUID().uuidString)")
        let url = directory.appending(path: "coordinator-triage.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))

        BlockedTriage.Ledger.append(
            BlockedTriage.Ledger.Entry(at: Date(), project: "kiteloop", itemID: "a",
                                       disposition: "retry", reason: "because", applied: true),
            to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasSuffix("\n"), "the line is newline-terminated")
        XCTAssertEqual(BlockedTriage.Ledger.load(from: url)
                        .retries(project: "kiteloop", itemID: "a"), 1)
    }

    private func appendRaw(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Every disposition is recorded with its reason

    func testEveryDispositionCarriesANonEmptyReason() {
        let cases: [[BlockedTriage.Run]] = [
            [blockedRun(reason: "max retries", duration: 2, cost: 0)],            // retry
            [blockedRun(reason: "review did not pass", duration: 900, cost: 5)],  // regroom
            [blockedRun(reason: "stalled: no progress", duration: 900),
             blockedRun(reason: "stalled: no progress", duration: 900)],          // escalate
            []                                                                    // escalate
        ]
        for runs in cases {
            let verdict = BlockedTriage.classify(signals(runs))
            XCTAssertFalse(verdict.reason.isEmpty,
                           "\(verdict.disposition.name) recorded no reason")
            XCTAssertEqual(verdict.itemID, "stuck-item")
        }
    }

    // MARK: - Withholding a verdict the pickup gate would refuse

    /// The pickup gate's verdict on an item nobody groomed — built by running
    /// `DefinitionOfReady` over a real item rather than by hand, so the phrasing
    /// under test is the gate's own and a reworded clause shows up here.
    private func ungroomed() -> DefinitionOfReady.Verdict {
        let verdict = DefinitionOfReady.evaluate(
            item: BacklogItem(id: "stuck-item", title: "Something stuck",
                              verify: nil, status: .blocked, type: .local, size: nil),
            detail: nil)
        XCTAssertFalse(verdict.isReady, "Precondition: an item with no detail, verify or size")
        return verdict
    }

    private func retryVerdict() -> BlockedTriage.Verdict {
        BlockedTriage.classify(signals([
            blockedRun(reason: "stalled: no progress for 20 min on worker", duration: 1_500)
        ]))
    }

    private func regroomVerdict() -> BlockedTriage.Verdict {
        BlockedTriage.classify(signals([
            blockedRun(reason: "review did not pass", duration: 1_200, cost: 5)
        ]))
    }

    /// A retry writes the item back to `ready`, where autopilot skips it at
    /// pickup and `POST /v1/runs` answers 422 — so it is withheld and said
    /// instead.
    func testRetryIsWithheldWhenTheItemWouldBeRefusedAtPickup() {
        let readiness = ungroomed()
        let retry = retryVerdict()
        XCTAssertEqual(retry.disposition, .retry, "Precondition: an environmental failure")

        let held = BlockedTriage.withholding(retry, readiness: readiness)

        XCTAssertEqual(held.disposition, .escalate)
        XCTAssertTrue(held.reason.contains(readiness.summary),
                      "the unmet clauses aren't named: \(held.reason)")
        XCTAssertTrue(held.reason.contains("retry"),
                      "the replaced disposition isn't named: \(held.reason)")
        // The item it is about, and what went wrong, are untouched — only the
        // decision changed.
        XCTAssertEqual(held.itemID, retry.itemID)
        XCTAssertEqual(held.title, retry.title)
        XCTAssertEqual(held.failure, retry.failure)
    }

    /// Regroom writes too — `reject` returns the item to `ready` with feedback —
    /// so it is withheld on the same terms, and the backlog is left alone.
    func testRegroomIsWithheldWhenTheItemWouldBeRefusedAtPickup() {
        let readiness = ungroomed()
        let regroom = regroomVerdict()
        XCTAssertEqual(regroom.disposition.name, "regroom", "Precondition: a substantive failure")

        let held = BlockedTriage.withholding(regroom, readiness: readiness)

        XCTAssertEqual(held.disposition, .escalate)
        XCTAssertFalse(held.disposition.writesToBacklog, "a withheld verdict must write nothing")
        XCTAssertTrue(held.reason.contains(readiness.summary), held.reason)
        XCTAssertTrue(held.reason.contains("regroom"), held.reason)
    }

    /// A ready item is triage's business as usual: whatever it decided stands,
    /// reason and all.
    func testAReadyItemsVerdictIsReturnedUnchanged() {
        for verdict in [retryVerdict(), regroomVerdict(), BlockedTriage.classify(signals([]))] {
            XCTAssertEqual(BlockedTriage.withholding(verdict, readiness: .ready), verdict,
                           "a ready item's \(verdict.disposition.name) was rewritten")
        }
    }

    /// An escalation already writes nothing, so there is nothing to withhold —
    /// and rewriting its reason would lose why triage escalated in the first
    /// place.
    func testAnEscalationIsReturnedUnchangedWhateverTheReadiness() {
        let escalation = BlockedTriage.classify(signals([]))
        XCTAssertEqual(escalation.disposition, .escalate, "Precondition")

        XCTAssertEqual(BlockedTriage.withholding(escalation, readiness: ungroomed()), escalation)
    }

    // MARK: - The readiness triage asks about, dependencies included

    /// A groomed item — everything the gate asks for except, in some cases
    /// below, a dependency it has to wait for.
    private func groomedItem(id: String = "stuck-item",
                             status: BacklogItemStatus = .blocked,
                             needs: [String] = []) -> BacklogItem {
        BacklogItem(id: id, title: "Something stuck", verify: "swift build",
                    status: status, type: .local, size: .m, needs: needs)
    }

    private func groomedDetail(id: String = "stuck-item") -> BacklogItemDetail {
        BacklogItemDetail(id: id, title: "Something stuck", verifyCommands: [],
                          acceptanceCriteria: ["The queue moves"], outOfScope: [],
                          what: "Unstick the item.", approach: "Read the run record.")
    }

    private func backlog(_ items: [BacklogItem]) -> BacklogFile {
        BacklogFile(project: "kiteloop", sections: [BacklogSection(name: "Epic", items: items)])
    }

    /// The gate withholds an item whose `needs:` isn't `done`, so triage has to
    /// ask it the same way — otherwise the item goes back to `ready`, pickup
    /// skips it every pass, and triage never looks at it again because it only
    /// reads `blocked` items.
    func testAWriteIsWithheldWhenTheItemWaitsOnAnItemThatIsNotDone() {
        let item = groomedItem(needs: ["schema-migration"])
        let file = backlog([item, groomedItem(id: "schema-migration", status: .ready)])

        let readiness = CoordinatorBlockedTriage.readiness(
            of: item, detail: groomedDetail(), in: file)

        XCTAssertFalse(readiness.isReady, "a dependency that isn't done read as ready")
        XCTAssertEqual(readiness.unmet, [.dependency],
                       "only the sequencing clause should fail: \(readiness.summary)")
        XCTAssertTrue(readiness.summary.contains("schema-migration"), readiness.summary)

        for verdict in [retryVerdict(), regroomVerdict()] {
            let held = BlockedTriage.withholding(verdict, readiness: readiness)
            XCTAssertEqual(held.disposition, .escalate,
                           "\(verdict.disposition.name) still wrote the item back to ready")
            XCTAssertTrue(held.reason.contains("schema-migration"),
                          "the unmet dependency isn't named: \(held.reason)")
        }
    }

    /// The other side of the same clause: everything it waits for has shipped,
    /// so triage's verdict stands exactly as it did before.
    func testAnItemWhoseDependenciesAreAllDoneIsCarriedOutUnchanged() {
        let item = groomedItem(needs: ["schema-migration", "seed-data"])
        let file = backlog([item,
                            groomedItem(id: "schema-migration", status: .done),
                            groomedItem(id: "seed-data", status: .done)])

        let readiness = CoordinatorBlockedTriage.readiness(
            of: item, detail: groomedDetail(), in: file)
        XCTAssertTrue(readiness.isReady, readiness.summary)

        for verdict in [retryVerdict(), regroomVerdict()] {
            XCTAssertEqual(BlockedTriage.withholding(verdict, readiness: readiness), verdict,
                           "a \(verdict.disposition.name) with its dependencies met was rewritten")
        }
    }

    /// An item that names no dependency is judged on how it is written, as
    /// before — something else in the file being unfinished is not its problem.
    func testAnItemThatNamesNoDependencyIsUnaffected() {
        let item = groomedItem()
        let file = backlog([item, groomedItem(id: "schema-migration", status: .ready)])

        XCTAssertTrue(CoordinatorBlockedTriage.readiness(
            of: item, detail: groomedDetail(), in: file).isReady)
    }

    /// No backlog to resolve against leaves the sequencing clause silent rather
    /// than unmet — the same reading `DefinitionOfReady` documents. Triage's own
    /// lookup miss reads ready one level up, for the same reason: a backlog that
    /// moved under us is not evidence a dependency is unmet.
    func testNoBacklogToResolveAgainstLeavesTheClauseSilent() {
        let item = groomedItem(needs: ["schema-migration"])

        XCTAssertTrue(CoordinatorBlockedTriage.readiness(
            of: item, detail: groomedDetail(), in: nil).isReady)
    }

    /// How the item is written is still judged when it also has to wait: both
    /// clauses are reported, so the escalation says everything a human has to
    /// fix rather than only the first thing found.
    func testAnUngroomedItemWithAnUnmetDependencyReportsBoth() {
        let item = BacklogItem(id: "stuck-item", title: "Something stuck", verify: nil,
                               status: .blocked, type: .local, size: nil,
                               needs: ["schema-migration"])
        let file = backlog([item, groomedItem(id: "schema-migration", status: .blocked)])

        let readiness = CoordinatorBlockedTriage.readiness(of: item, detail: nil, in: file)

        XCTAssertEqual(readiness.unmet, [.detail, .verify, .size, .dependency])
        XCTAssertTrue(readiness.summary.contains("schema-migration"), readiness.summary)
    }

    // MARK: - The budget

    func testExhaustedBudgetRefusesTheWholePlanRatherThanRetrying() {
        let retryable = signals([blockedRun(reason: "max retries", duration: 2, cost: 0)])
        let budget = QueueRefill.Budget(spentUSD: 20, capUSD: 20)

        let plan = BlockedTriage.plan(project: "kiteloop", signals: [retryable], budget: budget)
        XCTAssertTrue(plan.isRefused)
        XCTAssertTrue(plan.verdicts.isEmpty, "a refused plan must classify nothing")
        XCTAssertTrue(plan.tally.isEmpty)
        XCTAssertTrue(plan.summary.contains("not triaged"), plan.summary)
    }

    /// Yesterday's spend can't exhaust today — the budget rolls at the calendar
    /// boundary, exactly as the refill loop's does.
    func testYesterdaysSpendDoesNotRefuseTodaysTriage() {
        let yesterday = Date().addingTimeInterval(-60 * 60 * 48)
        let budget = QueueRefill.Budget(spentUSD: 20, capUSD: 20, day: yesterday)
        let retryable = signals([blockedRun(reason: "max retries", duration: 2, cost: 0)])

        let plan = BlockedTriage.plan(project: "kiteloop", signals: [retryable], budget: budget)
        XCTAssertFalse(plan.isRefused)
        XCTAssertEqual(plan.tally.retry, 1)
    }

    /// `maxPasses` bounds how often the grooming loop wakes up; triage runs
    /// inside a pass that has already been counted, so it is the *spend* ceiling
    /// that refuses here and not the pass ceiling.
    func testPassCeilingDoesNotRefuseTriage() {
        let budget = QueueRefill.Budget(spentUSD: 1, capUSD: 20, passes: 12, maxPasses: 12)
        let plan = BlockedTriage.plan(
            project: "kiteloop",
            signals: [signals([blockedRun(reason: "max retries", duration: 2, cost: 0)])],
            budget: budget)
        XCTAssertFalse(plan.isRefused)
    }

    // MARK: - Plan

    func testPlanTalliesAWholePile() {
        let plan = BlockedTriage.plan(project: "kiteloop", signals: [
            BlockedTriage.Signals(itemID: "a", title: "A",
                                  runs: [blockedRun(reason: "max retries", duration: 2, cost: 0)]),
            BlockedTriage.Signals(itemID: "b", title: "B",
                                  runs: [blockedRun(reason: "review did not pass",
                                                    duration: 900, cost: 5)]),
            BlockedTriage.Signals(itemID: "c", title: "C", runs: [])
        ])
        XCTAssertEqual(plan.tally.retry, 1)
        XCTAssertEqual(plan.tally.regroom, 1)
        XCTAssertEqual(plan.tally.escalate, 1)
        XCTAssertEqual(plan.tally.total, 3)
        XCTAssertEqual(plan.untriaged, 0)
        XCTAssertEqual(plan.blockedCount, 3)
        XCTAssertTrue(plan.summary.contains("triaged 3 blocked"), plan.summary)
        XCTAssertFalse(plan.summary.contains("not read"),
                       "a pass that read the whole pile has no remainder to name: \(plan.summary)")
    }

    // MARK: - What the pass didn't read

    /// The defect: "triaged 12 blocked" on a two-hundred-item pile reads as a
    /// finished pile. A bounded pass now names what it never looked at, in the
    /// same sentence.
    func testPartialPassSummaryNamesWhatItDidNotRead() {
        let plan = BlockedTriage.plan(
            project: "kiteloop",
            signals: [signals([blockedRun(reason: "max retries", duration: 2, cost: 0)])],
            untriaged: 188)

        XCTAssertEqual(plan.untriaged, 188)
        XCTAssertEqual(plan.blockedCount, 189)
        XCTAssertTrue(plan.summary.contains("triaged 1 of 189 blocked"), plan.summary)
        XCTAssertTrue(plan.summary.contains("188 not read this pass"), plan.summary)
        XCTAssertTrue(plan.summary.contains(plan.tally.summary),
                      "the tally is still what the pass decided: \(plan.summary)")
    }

    /// A bound of zero triages nothing while the pile is anything but empty, so
    /// "nothing blocked to triage" would be a plain lie. The remainder is what
    /// tells the two apart.
    func testAPassThatReadNoneOfANonEmptyPileDoesNotReportAnEmptyPile() {
        let plan = BlockedTriage.plan(project: "kiteloop", signals: [], untriaged: 5)

        XCTAssertFalse(plan.summary.contains("nothing blocked"), plan.summary)
        XCTAssertTrue(plan.summary.contains("triaged 0 of 5 blocked"), plan.summary)
        XCTAssertTrue(plan.summary.contains("5 not read this pass"), plan.summary)
    }

    /// An empty pile still reads as one — the sentence a pass with nothing to do
    /// has always printed.
    func testAnEmptyPileStillReadsAsAnEmptyPile() {
        let plan = BlockedTriage.plan(project: "kiteloop", signals: [])

        XCTAssertEqual(plan.untriaged, 0)
        XCTAssertEqual(plan.summary, "kiteloop: nothing blocked to triage")
    }

    /// A refused pass gathered nothing, so it has no remainder to report: a
    /// count there would claim a pile nobody read was read. The refusal is still
    /// the whole of what it says.
    func testARefusedPlanReportsItsRefusalAndNoCount() {
        let budget = QueueRefill.Budget(spentUSD: 20, capUSD: 20)
        let plan = BlockedTriage.plan(
            project: "kiteloop",
            signals: [signals([blockedRun(reason: "max retries", duration: 2, cost: 0)])],
            untriaged: 188, budget: budget)

        XCTAssertTrue(plan.isRefused)
        XCTAssertEqual(plan.untriaged, 0)
        XCTAssertTrue(plan.summary.contains("not triaged"), plan.summary)
        XCTAssertFalse(plan.summary.contains("not read this pass"), plan.summary)
    }

    // MARK: - Policy bounds

    /// A hand-edited config can't turn the classification off: a
    /// `repeatedFailureLimit` below 2 would escalate every first failure.
    func testPolicySanitizesAnUnusableRepeatedFailureLimit() {
        let policy = BlockedTriage.Policy(maxLifetimeRetries: -3, repeatedFailureLimit: 1,
                                          emptyRunSeconds: -10, unmetDimensionScore: 9)
        XCTAssertEqual(policy.sanitized.repeatedFailureLimit, 2)
        XCTAssertEqual(policy.sanitized.maxLifetimeRetries, 0)
        XCTAssertEqual(policy.sanitized.emptyRunSeconds, 0)
        XCTAssertEqual(policy.sanitized.unmetDimensionScore, 1)

        // A zero ceiling is "never retry", not a crash: the item still gets a
        // recorded disposition.
        let verdict = BlockedTriage.classify(
            signals([blockedRun(reason: "max retries", duration: 2, cost: 0)]),
            policy: policy)
        XCTAssertEqual(verdict.disposition, .escalate)
    }

    // MARK: - Dispositions

    func testOnlyRetryAndRegroomTouchTheBacklog() {
        XCTAssertTrue(BlockedTriage.Disposition.retry.writesToBacklog)
        XCTAssertTrue(BlockedTriage.Disposition.regroom(feedback: "x").writesToBacklog)
        XCTAssertFalse(BlockedTriage.Disposition.escalate.writesToBacklog,
                       "escalation is a sentence, not a write")
    }

    /// The reason half of `blocked:<reason>` is what triage classifies from, so
    /// it has to survive the trip through the metric record it was written into.
    func testRunIsReadBackFromAMetricRecordWithItsReasonIntact() {
        let record = TaskMetricRecord(
            projectPath: "/tmp/kiteloop", projectName: "kiteloop", itemID: "a", title: "A",
            epic: nil, declaredSize: "S", startedAt: Date(), completedAt: Date(),
            durationSeconds: 4, costUSD: 0.01, reviewerRetries: 0,
            outcome: "blocked:stalled: no progress for 20 min on worker",
            workerAgent: nil, reviewerAgent: nil, executionID: nil)

        let run = CoordinatorBlockedTriage.run(record)
        XCTAssertTrue(run.isBlocked)
        XCTAssertEqual(run.reason, "stalled: no progress for 20 min on worker")
        XCTAssertEqual(run.durationSeconds, 4)
        XCTAssertNil(run.branchHasCommits, "the branch is probed separately, never guessed")
    }

    // MARK: - The write path

    /// The defect, end to end: a bounded pass used to write an ungroomed blocked
    /// item back to `ready`, where autopilot skips it at pickup and `POST
    /// /v1/runs` answers 422 — a queue reading as if it had work it cannot start.
    /// The item now stays `blocked`, and the escalation is what the ledger and the
    /// event stream carry.
    @MainActor
    func testBoundedTriageWithholdsAnItemThePickupGateWouldRefuse() async throws {
        let fixture = try TriageFixture(items: [
            "- [ ] stuck-item | Something stuck | blocked"
        ])
        defer { fixture.tearDown() }
        fixture.recordBlockedRun(itemID: "stuck-item",
                                 reason: "stalled: no progress for 20 min on worker")

        let result = await fixture.triage.triage(project: fixture.name,
                                                 budget: QueueRefill.Budget(capUSD: 20))

        // Precondition: read on its own the record says retry. The substitution
        // is the write path's, not the classification's.
        XCTAssertEqual(result.plan.verdicts.first?.disposition, .retry)
        XCTAssertEqual(fixture.item("stuck-item")?.status, .blocked,
                       "an item the gate refuses must not be written back to ready")
        XCTAssertEqual(result.recovered, 0, "nothing moved, so nothing was recovered")

        let recorded = try XCTUnwrap(fixture.ledgerEntry(itemID: "stuck-item"))
        XCTAssertEqual(recorded.disposition, "escalate")
        XCTAssertFalse(recorded.applied, "an escalation is a sentence, not a write")
        XCTAssertTrue(recorded.reason.contains("refused at pickup"), recorded.reason)
        XCTAssertTrue(recorded.reason.contains("retry"),
                      "the ledger must say which disposition was withheld: \(recorded.reason)")

        let published = try await fixture.triageEvent(itemID: "stuck-item")
        XCTAssertEqual(published.payload["disposition"], "escalate")
        XCTAssertEqual(published.payload["reason"], recorded.reason)
    }

    /// The other half: a groomed item is still recovered. The gate withholds the
    /// items it refuses and nothing else.
    @MainActor
    func testBoundedTriageStillReturnsAGroomedItemToReady() async throws {
        let fixture = try TriageFixture(
            items: ["- [ ] groomed-item | Fully groomed | blocked | size: S → [detail](backlog/groomed-item.md)"],
            details: ["backlog/groomed-item.md": TriageFixture.groomedDetail(id: "groomed-item")])
        defer { fixture.tearDown() }
        fixture.recordBlockedRun(itemID: "groomed-item",
                                 reason: "stalled: no progress for 20 min on worker")

        let result = await fixture.triage.triage(project: fixture.name,
                                                 budget: QueueRefill.Budget(capUSD: 20))

        XCTAssertEqual(fixture.item("groomed-item")?.status, .ready)
        XCTAssertEqual(result.recovered, 1)
        let recorded = try XCTUnwrap(fixture.ledgerEntry(itemID: "groomed-item"))
        XCTAssertEqual(recorded.disposition, "retry")
        XCTAssertTrue(recorded.applied)
    }

    /// The pass end to end: a bound that leaves part of the pile unread is
    /// reported everywhere the pass speaks — the plan it returns, the `lastPlan`
    /// a surface reads, and the event it publishes. Before this, the remainder
    /// went to os_log alone, which nothing in the app or the control API reads.
    @MainActor
    func testABoundedPassReportsHowManyBlockedItemsItDidNotRead() async throws {
        let fixture = try TriageFixture(items: [
            "- [ ] stuck-one | Stuck one | blocked",
            "- [ ] stuck-two | Stuck two | blocked",
            "- [ ] stuck-three | Stuck three | blocked"
        ])
        defer { fixture.tearDown() }
        fixture.triage.maxItemsPerPass = 1

        let result = await fixture.triage.triage(project: fixture.name,
                                                 budget: QueueRefill.Budget(capUSD: 20))

        XCTAssertEqual(result.plan.verdicts.count, 1, "the bound is still a bound")
        XCTAssertEqual(result.plan.untriaged, 2)
        XCTAssertTrue(result.plan.summary.contains("triaged 1 of 3 blocked"), result.plan.summary)
        XCTAssertTrue(result.plan.summary.contains("2 not read this pass"), result.plan.summary)
        XCTAssertEqual(fixture.triage.lastPlan?.untriaged, 2,
                       "the surface reads `lastPlan`, so the count has to survive into it")

        let event = try await fixture.passEvent()
        XCTAssertEqual(event.payload["untriaged"], "2")
        XCTAssertEqual(event.payload["detail"], result.plan.summary)
    }

    /// A pass that read the whole pile has no remainder, and says nothing about
    /// one: the event carries no `untriaged` key at all.
    @MainActor
    func testAPassThatReadsTheWholePileCarriesNoRemainder() async throws {
        let fixture = try TriageFixture(items: ["- [ ] stuck-one | Stuck one | blocked"])
        defer { fixture.tearDown() }

        let result = await fixture.triage.triage(project: fixture.name,
                                                 budget: QueueRefill.Budget(capUSD: 20))

        XCTAssertEqual(result.plan.untriaged, 0)
        XCTAssertTrue(result.plan.summary.contains("triaged 1 blocked"), result.plan.summary)

        let event = try await fixture.passEvent()
        XCTAssertNil(event.payload["untriaged"],
                     "a finished pile has no remainder to name")
    }

    /// A pass the budget refused gathered nothing, so it reports its refusal and
    /// no count — a `0` there would claim a pile nobody read was read.
    @MainActor
    func testASpendRefusedPassReportsItsRefusalAndNoCount() async throws {
        let fixture = try TriageFixture(items: [
            "- [ ] stuck-one | Stuck one | blocked",
            "- [ ] stuck-two | Stuck two | blocked"
        ])
        defer { fixture.tearDown() }
        fixture.triage.maxItemsPerPass = 1

        let result = await fixture.triage.triage(project: fixture.name,
            budget: QueueRefill.Budget(spentUSD: 20, capUSD: 20))

        XCTAssertTrue(result.plan.isRefused)
        XCTAssertEqual(result.plan.untriaged, 0)
        XCTAssertTrue(result.plan.summary.contains("not triaged"), result.plan.summary)

        let event = try await fixture.passEvent()
        XCTAssertNotNil(event.payload["refusal"])
        XCTAssertNil(event.payload["untriaged"])
    }

    /// The other refusal: a project nothing has open. It still says why, and it
    /// gains no count either — nobody read a backlog to have a remainder of.
    @MainActor
    func testAClosedProjectReportsItsRefusalAndNoCount() async throws {
        let fixture = try TriageFixture(items: ["- [ ] stuck-one | Stuck one | blocked"])
        defer { fixture.tearDown() }

        let result = await fixture.triage.triage(project: "not-open",
                                                 budget: QueueRefill.Budget(capUSD: 20))

        XCTAssertTrue(result.plan.isRefused)
        XCTAssertEqual(result.plan.untriaged, 0)
        XCTAssertTrue(result.plan.summary.contains("isn't open"), result.plan.summary)
        XCTAssertFalse(result.plan.summary.contains("not read this pass"), result.plan.summary)
        XCTAssertEqual(fixture.triage.lastPlan?.untriaged, 0)
    }

    // MARK: - Fixture

    /// A real project on disk — BACKLOG.md, a `ProjectSession` in a registry, a
    /// metric store — for the handful of cases that are about what triage
    /// *writes* rather than what it decides. Everything lives in a temp
    /// directory, so no test reads or writes the developer's own `~/.kiteloop`.
    @MainActor
    private final class TriageFixture {
        let name = "alpha"
        let root: URL
        let triage: CoordinatorBlockedTriage
        let backlog: BacklogViewModel

        /// The path the session reports for itself — what a metric record has to
        /// carry to be read as this project's.
        private let projectPath: String
        private let tempDir: URL
        private let registry: ControlSessionRegistry
        private let metrics: TaskMetricStore
        private let eventBus: EventBus

        init(items: [String], details: [String: String] = [:]) throws {
            tempDir = try TemporaryDirectory.make(prefix: "blocked-triage")
            root = tempDir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            try "# \(name) Backlog\n\n## Now\n\n\(items.joined(separator: "\n"))\n"
                .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
            for (path, contents) in details {
                let url = root.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }

            let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
            projectPath = rootURL.path(percentEncoded: false)
            let project = KiteloopProject(rootURL: rootURL)
            try project.ensureDirectoryExists()
            eventBus = EventBus(eventsURL: project.eventsURL)
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
                context: ProjectSessionContext(
                    runtimeFactory: { MockAgentRuntime() },
                    agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
                    packageResolver: nil,
                    globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
                    orgManifestLoader: OrgManifestLoader(),
                    repoCloneService: RepoCloneService()
                )
            )
            backlog = session.backlogViewModel

            registry = ControlSessionRegistry()
            registry.register(session: session, autopilot: BacklogAutopilot())
            metrics = TaskMetricStore(metricsURL: tempDir.appendingPathComponent("metrics.jsonl"),
                                      estimatesURL: tempDir.appendingPathComponent("estimates.jsonl"),
                                      approvalsURL: tempDir.appendingPathComponent("approvals.jsonl"))
            triage = CoordinatorBlockedTriage(
                ledgerURL: tempDir.appendingPathComponent("triage.jsonl"))
            triage.configure(registry: registry, metrics: metrics)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: tempDir)
        }

        /// One blocked run on record for the item, long and expensive enough that
        /// it isn't read as the dead-session signature.
        func recordBlockedRun(itemID: String, reason: String) {
            metrics.append(TaskMetricRecord(
                projectPath: projectPath, projectName: name,
                itemID: itemID, title: "Something stuck", epic: nil, declaredSize: "S",
                startedAt: Date(), completedAt: Date(), durationSeconds: 1_500, costUSD: 5,
                reviewerRetries: 0, outcome: "blocked:\(reason)",
                workerAgent: nil, reviewerAgent: nil, executionID: nil))
        }

        func item(_ id: String) -> BacklogItem? { backlog.item(withID: id) }

        /// Asked with the canonical path, which is what a pass records under —
        /// the folder name is what the plan and the events carry.
        func ledgerEntry(itemID: String) -> BlockedTriage.Ledger.Entry? {
            triage.ledger.history(project: projectPath, itemID: itemID).last
        }

        /// The per-item triage event, once the orchestrator's detached publish has
        /// reached the bus.
        func triageEvent(itemID: String) async throws -> KiteloopEvent {
            let bus = eventBus
            return try await eventuallyValue("a triage event for \(itemID) to reach the stream") {
                await bus.recentEvents().last {
                    $0.payload["item"] == itemID && $0.payload["disposition"] != nil
                }
            }
        }

        /// The one event the pass itself publishes — what it read, and what it
        /// left — once the orchestrator's detached publish has reached the bus.
        func passEvent() async throws -> KiteloopEvent {
            let bus = eventBus
            return try await eventuallyValue("the pass event to reach the stream") {
                await bus.recentEvents().last {
                    $0.payload["kind"] == "blocked-triage"
                }
            }
        }

        /// What the pickup gate reads out of a detail file: What, How, Validation
        /// and a `verify:`.
        static func groomedDetail(id: String) -> String {
            """
            ---
            id: \(id)
            title: Fully groomed
            size: S
            verify:
              - name: build
                cmd: "true"
            ---

            ## What

            The outcome this item delivers.

            ## How

            Touch these files, follow this pattern.

            ## Validation

            - [ ] The observable behaviour that proves it works

            ## Out of Scope

            - Anything else
            """
        }
    }
}
