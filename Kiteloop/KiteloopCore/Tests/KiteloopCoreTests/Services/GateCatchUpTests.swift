import XCTest
@testable import KiteloopCore

/// `GateCatchUp.run` — the bounded loop a gate-refresh round uses when the
/// base moved while the round was running — and the note each ending fails
/// the round with.
final class GateCatchUpTests: XCTestCase {

    /// A scripted branch: stale for the first `staleReads` reads, merges
    /// answering from `mergeResults` in order.
    private actor Script {
        var staleReads: Int
        var mergeResults: [Bool]
        private(set) var mergesAsked = 0

        init(staleReads: Int, mergeResults: [Bool] = []) {
            self.staleReads = staleReads
            self.mergeResults = mergeResults
        }

        func isStale() -> Bool {
            guard staleReads > 0 else { return false }
            staleReads -= 1
            return true
        }

        func merge() -> Bool {
            mergesAsked += 1
            return mergeResults.isEmpty ? true : mergeResults.removeFirst()
        }
    }

    private func run(_ script: Script, limit: Int) async -> GateCatchUp.Result {
        await GateCatchUp.run(
            limit: limit,
            isStale: { await script.isStale() },
            mergeBase: { await script.merge() })
    }

    func testAFreshBranchIsCaughtUpWithoutAMerge() async {
        let script = Script(staleReads: 0)
        let result = await run(script, limit: 3)
        XCTAssertEqual(result, .caughtUp(merges: 0))
        let asked = await script.mergesAsked
        XCTAssertEqual(asked, 0, "a fresh branch is never merged into")
    }

    func testABaseThatMovedOnceIsCaughtUpByOneMerge() async {
        let script = Script(staleReads: 1)
        let result = await run(script, limit: 3)
        XCTAssertEqual(result, .caughtUp(merges: 1))
    }

    func testAMergeThatDoesNotGoCleanlyEndsTheCatchUp() async {
        let script = Script(staleReads: 5, mergeResults: [true, false])
        let result = await run(script, limit: 3)
        XCTAssertEqual(result, .conflicted)
        let asked = await script.mergesAsked
        XCTAssertEqual(asked, 2, "nothing is merged after a conflict")
    }

    func testABaseThatKeepsMovingStopsAtTheLimit() async {
        let script = Script(staleReads: .max)
        let result = await run(script, limit: 3)
        XCTAssertEqual(result, .stillBehind(merges: 3))
        let asked = await script.mergesAsked
        XCTAssertEqual(asked, 3, "the limit is the number of merges, not of reads")
    }

    func testTheLastAllowedMergeStillCounts() async {
        let script = Script(staleReads: 3)
        let result = await run(script, limit: 3)
        XCTAssertEqual(result, .caughtUp(merges: 3))
    }

    func testALimitOfZeroMergesNothing() async {
        let script = Script(staleReads: .max)
        let result = await run(script, limit: 0)
        XCTAssertEqual(result, .stillBehind(merges: 0))
        let asked = await script.mergesAsked
        XCTAssertEqual(asked, 0)
    }

    // MARK: - Notes

    func testCaughtUpHasNoFailureNote() {
        XCTAssertNil(GateCatchUp.failureNote(for: .caughtUp(merges: 2), branch: "kiteloop/x", base: "main"))
    }

    func testConflictNoteNamesTheConflictTheBaseAndTheBranch() {
        let note = GateCatchUp.failureNote(for: .conflicted, branch: "kiteloop/x", base: "main")
        XCTAssertEqual(note, "merging main into kiteloop/x conflicted after the base moved during the round")
    }

    func testStillBehindNoteNamesTheBound() {
        let note = GateCatchUp.failureNote(for: .stillBehind(merges: 3), branch: "kiteloop/x", base: "main")
        XCTAssertEqual(note, "kiteloop/x is still behind main after 3 catch-up merges — the base keeps moving")
        let one = GateCatchUp.failureNote(for: .stillBehind(merges: 1), branch: "kiteloop/x", base: "main")
        XCTAssertEqual(one, "kiteloop/x is still behind main after 1 catch-up merge — the base keeps moving")
    }

    func testStillBehindWithNoMergeAllowedKeepsTheOldWording() {
        let note = GateCatchUp.failureNote(for: .stillBehind(merges: 0), branch: "kiteloop/x", base: "main")
        XCTAssertEqual(note, "kiteloop/x is still behind main after the round")
    }
}
