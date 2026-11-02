import XCTest
@testable import KiteloopCore

/// Covers the one rejection in the system that used to go nowhere: a person's
/// own verdict at the approval gate. Recorded here rather than left only in the
/// item's `## Notes`, so the next run's worker and reviewer both read it back —
/// see `GateRejection.outstanding` and `promptBlock`.
final class GateRejectionTests: XCTestCase {

    private var tempDir: URL!
    private var url: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "gate-rejection")
        url = GateRejection.url(projectPath: tempDir.path(percentEncoded: false))
    }

    private func rejected(itemID: String, reason: String = "left the bug in place",
                          ref: String? = "refs/kiteloop/rejected/abc", at: Date = Date()) -> GateRejection.Record {
        .init(itemID: itemID, kind: .rejected, reason: reason, ref: ref, at: at)
    }

    private func cleared(itemID: String, at: Date = Date()) -> GateRejection.Record {
        .init(itemID: itemID, kind: .cleared, reason: nil, ref: nil, at: at)
    }

    private func judgeBlocked(itemID: String, reason: String = "the waiting-for-gate step never released",
                              ref: String? = "refs/kiteloop/rejected/abc", at: Date = Date()) -> GateRejection.Record {
        .init(itemID: itemID, kind: .judgeBlocked, reason: reason, ref: ref, at: at)
    }

    // MARK: - outstanding

    func testAnItemNeverRejectedHasNoOutstandingRecord() {
        XCTAssertNil(GateRejection.outstanding(itemID: "abc", entries: []))
    }

    func testARejectedItemsRecordIsOutstanding() {
        let record = rejected(itemID: "abc")
        XCTAssertEqual(GateRejection.outstanding(itemID: "abc", entries: [record]), record)
    }

    func testAClearedRejectionIsNoLongerOutstanding() {
        let entries = [rejected(itemID: "abc"), cleared(itemID: "abc")]
        XCTAssertNil(GateRejection.outstanding(itemID: "abc", entries: entries))
    }

    /// A second rejection after a clear is its own, independent record — the
    /// item can be sent back more than once across its lifetime.
    func testARejectionAfterAClearIsOutstandingAgain() {
        let second = rejected(itemID: "abc", reason: "same defect, still there")
        let entries = [rejected(itemID: "abc"), cleared(itemID: "abc"), second]
        XCTAssertEqual(GateRejection.outstanding(itemID: "abc", entries: entries), second)
    }

    func testOnlyTheNamedItemsEntriesAreConsidered() {
        let entries = [rejected(itemID: "other")]
        XCTAssertNil(GateRejection.outstanding(itemID: "abc", entries: entries))
        XCTAssertNotNil(GateRejection.outstanding(itemID: "other", entries: entries))
    }

    /// The quality judge's own block is outstanding exactly the way a hand
    /// rejection is — read back until a `.cleared` entry answers it.
    func testAJudgeBlockedItemsRecordIsOutstanding() {
        let record = judgeBlocked(itemID: "abc")
        XCTAssertEqual(GateRejection.outstanding(itemID: "abc", entries: [record]), record)
    }

    func testAClearedJudgeBlockIsNoLongerOutstanding() {
        let entries = [judgeBlocked(itemID: "abc"), cleared(itemID: "abc")]
        XCTAssertNil(GateRejection.outstanding(itemID: "abc", entries: entries))
    }

    // MARK: - promptBlock

    func testPromptBlockCarriesTheReasonVerbatimAndTheRef() {
        let block = try! XCTUnwrap(GateRejection.promptBlock(
            rejected(itemID: "abc", reason: "the gateCommand mismatch is still there",
                    ref: "refs/kiteloop/rejected/abc")))
        XCTAssertTrue(block.contains("## Rejected last time"), block)
        XCTAssertTrue(block.contains("the gateCommand mismatch is still there"), block)
        XCTAssertTrue(block.contains("refs/kiteloop/rejected/abc"), block)
    }

    /// An item that never ran isolated has no branch to preserve — the block
    /// still carries the reason, just not a ref pointing nowhere.
    func testPromptBlockOmitsTheRefLineWhenThereIsNone() {
        let block = try! XCTUnwrap(GateRejection.promptBlock(
            rejected(itemID: "abc", reason: "still wrong", ref: nil)))
        XCTAssertTrue(block.contains("still wrong"), block)
        XCTAssertFalse(block.contains("branch tip"), block)
    }

    func testPromptBlockIsNilForAClearedRecord() {
        XCTAssertNil(GateRejection.promptBlock(cleared(itemID: "abc")))
    }

    func testPromptBlockIsNilForABlankReason() {
        XCTAssertNil(GateRejection.promptBlock(rejected(itemID: "abc", reason: "   ")))
    }

    /// The judge's block renders under its own heading naming the judge, not
    /// a person — everything else (the reason verbatim, the ref line) is
    /// identical to the hand-rejection rendering.
    func testPromptBlockNamesTheQualityJudgeForAJudgeBlockedRecord() throws {
        let block = try XCTUnwrap(GateRejection.promptBlock(
            judgeBlocked(itemID: "abc", reason: "the waiting-for-gate step never released",
                        ref: "refs/kiteloop/rejected/abc")))
        XCTAssertTrue(block.contains("## Blocked by the quality judge last time"), block)
        XCTAssertTrue(block.contains("The quality judge blocked the previous run"), block)
        XCTAssertTrue(block.contains("the waiting-for-gate step never released"), block)
        XCTAssertTrue(block.contains("refs/kiteloop/rejected/abc"), block)
        XCTAssertFalse(block.contains("A person rejected"), block)
    }

    func testPromptBlockIsNilForABlankJudgeBlockedReason() {
        XCTAssertNil(GateRejection.promptBlock(judgeBlocked(itemID: "abc", reason: "   ")))
    }

    // MARK: - Persistence

    func testAppendedRecordsReadBackInOrder() {
        let first = rejected(itemID: "abc", at: Date(timeIntervalSince1970: 0))
        let second = cleared(itemID: "abc", at: Date(timeIntervalSince1970: 10))
        GateRejection.append(first, to: url)
        GateRejection.append(second, to: url)

        let entries = GateRejection.read(from: url)
        XCTAssertEqual(entries, [first, second])
    }

    func testReadingAMissingLedgerIsEmptyNotAnError() {
        XCTAssertEqual(GateRejection.read(from: url), [])
    }

    /// The truncation `AtomicFileWriter.append` is written to survive, read
    /// back: a kill part-way through a multi-byte character leaves a last line
    /// whose bytes are not valid UTF-8. Decoding the file as one string lost
    /// every record to that one line — including the standing rejection the
    /// next pickup has to find.
    func testATruncatedLastLineCostsOnlyItselfAndLeavesTheRejectionStanding() throws {
        let record = rejected(itemID: "abc", reason: "the gateCommand mismatch is still there",
                              at: Date(timeIntervalSince1970: 0))
        GateRejection.append(record, to: url)
        let cut = Data(#"{"itemID":"abc","kind":"rejected","reason":"cut — "#.utf8).dropLast(2)
        XCTAssertNil(String(data: cut, encoding: .utf8), "the em dash is genuinely cut in half")
        try appendBytes(cut)

        let entries = GateRejection.read(from: url)

        XCTAssertEqual(entries, [record])
        XCTAssertEqual(GateRejection.outstanding(itemID: "abc", entries: entries), record)
    }

    /// A blank line — what `AtomicFileWriter.append`'s repair leaves when it
    /// prepends a newline nobody needed — contributes no entry and is not an
    /// error.
    func testABlankLineContributesNoRecord() throws {
        let record = rejected(itemID: "abc", at: Date(timeIntervalSince1970: 0))
        GateRejection.append(record, to: url)
        try appendBytes(Data("\n\n".utf8))

        XCTAssertEqual(GateRejection.read(from: url), [record])
    }

    /// Raw bytes onto the end of the log, the way a killed append leaves them —
    /// `GateRejection.append` only ever writes whole encoded records.
    private func appendBytes(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    // MARK: - The ref name itself

    func testRefLivesOutsideRefsHeadsSoBranchDeletionNeverTouchesIt() {
        XCTAssertEqual(GateRejection.ref(itemID: "abc"), "refs/kiteloop/rejected/abc")
    }
}
