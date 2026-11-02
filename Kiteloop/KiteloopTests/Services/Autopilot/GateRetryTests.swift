import XCTest
import KiteloopCore
@testable import Kiteloop

/// The gate retry loop's decision half: which parked items are worth another
/// merge attempt, and which are excluded — permanently, for a red verify, or
/// for now, at the retry ceiling.
final class GateRetryTests: XCTestCase {

    // MARK: - Failure classification

    func testAMergeConflictReasonClassifiesAsConflictOrRace() {
        XCTAssertEqual(GateRetry.failure(of: "merge conflict in: README.md"), .conflictOrRace)
    }

    func testAFastForwardRaceReasonClassifiesAsConflictOrRace() {
        XCTAssertEqual(GateRetry.failure(
            of: "could not fast-forward the checkout onto the merge: some git output"), .conflictOrRace)
    }

    func testABaseRefRaceReasonClassifiesAsConflictOrRace() {
        XCTAssertEqual(GateRetry.failure(
            of: "could not move base branch main onto the merge: its tip moved from abc1234 "
              + "while the merge was verified"), .conflictOrRace)
    }

    func testAVerifyRefusalReasonClassifiesAsVerifyRed() {
        XCTAssertEqual(GateRetry.failure(of: "verify failed on merged tree (merge-verify)"), .verifyRed)
        XCTAssertEqual(GateRetry.failure(of: "verify timed out after 900s on merged tree (item verify)"),
                       .verifyRed)
    }

    /// The regression this item exists to fix: `WorktreeManager.conflictRefusal`
    /// names the conflicting paths in its reason, and a tracked file's name can
    /// itself contain "verify" — a bare substring check on that word would have
    /// misread this as the one class the loop must never retry.
    func testAConflictInAVerifyNamedFileClassifiesAsConflictOrRace() {
        XCTAssertEqual(GateRetry.failure(
            of: "merge conflict in: Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/VerifyCoverage.swift"),
            .conflictOrRace)
    }

    /// The multi-path form `conflictRefusal` builds when more paths conflict
    /// than it names — one of the shown paths is verify-named here too.
    func testAMultiPathConflictWithAVerifyNamedPathClassifiesAsConflictOrRace() {
        XCTAssertEqual(GateRetry.failure(
            of: "merge conflict in: Services/MergeVerifyPlan.swift, README.md (+2 more)"),
            .conflictOrRace)
    }

    func testAWorkingTreeRefusalClassifiesAsOther() {
        XCTAssertEqual(GateRetry.failure(of: "working tree not clean (modified): Foo.swift"), .other)
    }

    func testANilOrEmptyReasonClassifiesAsOther() {
        XCTAssertEqual(GateRetry.failure(of: nil), .other)
        XCTAssertEqual(GateRetry.failure(of: ""), .other)
    }

    // MARK: - classify: eligibility

    /// The regression this loop originally shipped with: `accept()` reaches
    /// the gate — and fires the freshness trigger this loop rides — *before*
    /// the run's own first merge is ever attempted. Reading "nothing on
    /// record yet" as a permanent exclusion locked every item out before it
    /// had a real failure to retry from. `.skip` is silent and unrecorded so
    /// a later, real failure is still free to classify as `.retry`.
    func testNoAttemptOnRecordIsSkippedNotExcluded() {
        XCTAssertEqual(GateRetry.classify(GateRetry.Signals(itemID: "item-1")).disposition, .skip)
    }

    func testALandedLastAttemptIsSkipped() {
        let signals = GateRetry.Signals(
            itemID: "item-1", lastAttempt: GateRetry.Attempt(merged: true, reason: "merged"))
        XCTAssertEqual(GateRetry.classify(signals).disposition, .skip,
                       "a landed merge has nothing left to retry")
    }

    func testAConflictIsEligibleForRetry() {
        let signals = GateRetry.Signals(
            itemID: "item-1",
            lastAttempt: GateRetry.Attempt(merged: false, reason: "merge conflict in: README.md"))
        XCTAssertEqual(GateRetry.classify(signals).disposition, .retry)
    }

    func testAConflictInAVerifyNamedFileIsEligibleForRetry() {
        let signals = GateRetry.Signals(
            itemID: "item-1",
            lastAttempt: GateRetry.Attempt(
                merged: false,
                reason: "merge conflict in: Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/VerifyCoverage.swift"))
        XCTAssertEqual(GateRetry.classify(signals).disposition, .retry)
    }

    func testARedVerifyIsExcludedRegardlessOfAttemptsSpent() {
        let signals = GateRetry.Signals(
            itemID: "item-1",
            lastAttempt: GateRetry.Attempt(merged: false, reason: "verify failed on merged tree (x)"),
            attemptsByThisLoop: 0)
        let verdict = GateRetry.classify(signals)
        guard case .exclude(let reason) = verdict.disposition else {
            return XCTFail("a red verify must never be retried")
        }
        XCTAssertTrue(reason.contains("verify"), reason)
    }

    /// Not `.exclude`: a dirty project checkout is not this item's own doing
    /// and may well clear up on its own before the next trigger, so it is not
    /// worth a permanent, ledger-recorded verdict — only `.skip` for now.
    func testAnOtherRefusalIsSkippedNotExcluded() {
        let signals = GateRetry.Signals(
            itemID: "item-1",
            lastAttempt: GateRetry.Attempt(merged: false, reason: "working tree not clean: Foo.swift"))
        XCTAssertEqual(GateRetry.classify(signals).disposition, .skip)
    }

    func testAConflictAtTheCeilingIsExcludedNamingTheCount() {
        let signals = GateRetry.Signals(
            itemID: "item-1",
            lastAttempt: GateRetry.Attempt(merged: false, reason: "merge conflict in: README.md"),
            attemptsByThisLoop: 3)
        let verdict = GateRetry.classify(signals, policy: GateRetry.Policy(maxAttempts: 3))
        guard case .exclude(let reason) = verdict.disposition else {
            return XCTFail("the ceiling must stop further retries")
        }
        XCTAssertTrue(reason.contains("3"), reason)
    }

    func testAConflictUnderTheCeilingIsRetried() {
        let signals = GateRetry.Signals(
            itemID: "item-1",
            lastAttempt: GateRetry.Attempt(merged: false, reason: "merge conflict in: README.md"),
            attemptsByThisLoop: 2)
        XCTAssertEqual(
            GateRetry.classify(signals, policy: GateRetry.Policy(maxAttempts: 3)).disposition, .retry)
    }

    func testANegativeCeilingSanitizesToZero() {
        let signals = GateRetry.Signals(
            itemID: "item-1",
            lastAttempt: GateRetry.Attempt(merged: false, reason: "merge conflict in: README.md"),
            attemptsByThisLoop: 0)
        guard case .exclude = GateRetry.classify(
            signals, policy: GateRetry.Policy(maxAttempts: -1)).disposition else {
            return XCTFail("a negative ceiling must never license an unbounded retry")
        }
    }

    // MARK: - Ledger

    private func makeLedgerURL() throws -> URL {
        try makeTemporaryDirectory(prefix: "gate-retry-ledger").appending(path: "gate-retry.jsonl")
    }

    func testLedgerCountsOnlyRetryEntriesForTheItem() {
        var ledger = GateRetry.Ledger()
        ledger.record(project: "proj", itemID: "item-1", disposition: "retry", reason: "conflict")
        ledger.record(project: "proj", itemID: "item-1", disposition: "excluded", reason: "verify red")
        ledger.record(project: "proj", itemID: "item-2", disposition: "retry", reason: "conflict")

        XCTAssertEqual(ledger.attempts(project: "proj", itemID: "item-1"), 1)
        XCTAssertEqual(ledger.attempts(project: "proj", itemID: "item-2"), 1)
        XCTAssertEqual(ledger.attempts(project: "other", itemID: "item-1"), 0)
    }

    func testLedgerIsExcludedReadsOnlyExcludedEntries() {
        var ledger = GateRetry.Ledger()
        XCTAssertFalse(ledger.isExcluded(project: "proj", itemID: "item-1"))
        ledger.record(project: "proj", itemID: "item-1", disposition: "retry", reason: "conflict")
        XCTAssertFalse(ledger.isExcluded(project: "proj", itemID: "item-1"))
        ledger.record(project: "proj", itemID: "item-1", disposition: "excluded", reason: "verify red")
        XCTAssertTrue(ledger.isExcluded(project: "proj", itemID: "item-1"))
    }

    func testLedgerPersistsAcrossALoad() throws {
        let url = try makeLedgerURL()
        let entry = GateRetry.Ledger.Entry(
            at: Date(), project: "proj", itemID: "item-1", disposition: "retry", reason: "conflict")
        GateRetry.Ledger.append(entry, to: url)
        GateRetry.Ledger.append(entry, to: url)

        let reloaded = GateRetry.Ledger.load(from: url)
        XCTAssertEqual(reloaded.attempts(project: "proj", itemID: "item-1"), 2,
                       "the ceiling must hold across a relaunch, so it is read off disk")
    }

    func testLedgerLoadSkipsACorruptLineRatherThanFailingTheWholeFile() throws {
        let url = try makeLedgerURL()
        let entry = GateRetry.Ledger.Entry(
            at: Date(), project: "proj", itemID: "item-1", disposition: "retry", reason: "conflict")
        GateRetry.Ledger.append(entry, to: url)
        try "not json\n".appendToFile(at: url)
        GateRetry.Ledger.append(entry, to: url)

        let reloaded = GateRetry.Ledger.load(from: url)
        XCTAssertEqual(reloaded.attempts(project: "proj", itemID: "item-1"), 2)
    }
}

private extension String {
    func appendToFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(Data(utf8))
    }
}
