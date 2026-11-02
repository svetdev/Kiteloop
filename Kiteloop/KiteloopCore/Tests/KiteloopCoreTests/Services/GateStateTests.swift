import XCTest
@testable import KiteloopCore

/// Three states behind one status, resolved from the same facts everywhere.
final class GateStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testAnItemNotAtTheGateHasNoGateState() {
        XCTAssertNil(GateState.resolve(isAwaitingApproval: false, verifyingSince: t0, lastMerge: nil))
    }

    func testAGateStillVerifyingIsVerifyingWhateverTheLedgerSays() {
        let refused = GateState.LastMerge(merged: false, at: t0, reason: "verify failed on merged tree")
        let state = GateState.resolve(isAwaitingApproval: true, verifyingSince: t0.addingTimeInterval(30), lastMerge: refused)
        XCTAssertEqual(state?.kind, .verifying)
        XCTAssertEqual(state?.line(now: t0.addingTimeInterval(75)), "At gate — verifying the merged tree (45s)")
        XCTAssertEqual(state?.line(now: t0.addingTimeInterval(330)), "At gate — verifying the merged tree (5 min)")
    }

    func testARefusalOnRecordIsRefusedWithItsReason() {
        let refused = GateState.LastMerge(merged: false, at: t0, reason: "merge conflict in: a.swift")
        let state = GateState.resolve(isAwaitingApproval: true, verifyingSince: nil, lastMerge: refused)
        XCTAssertEqual(state, GateState(kind: .refused, since: t0, reason: "merge conflict in: a.swift"))
        XCTAssertEqual(state?.line(now: t0), "At gate — refused: merge conflict in: a.swift")
    }

    func testARefusalOlderThanThisVisitToTheGateIsNotThisVisitsRefusal() {
        let old = GateState.LastMerge(merged: false, at: t0, reason: "verify failed")
        let state = GateState.resolve(isAwaitingApproval: true, verifyingSince: nil, lastMerge: old,
                                      gateOpenedAt: t0.addingTimeInterval(600))
        XCTAssertEqual(state?.kind, .waiting)
    }

    func testNothingOnRecordAndNothingRunningIsWaitingOnAPerson() {
        let state = GateState.resolve(isAwaitingApproval: true, verifyingSince: nil, lastMerge: nil)
        XCTAssertEqual(state, GateState(kind: .waiting))
        XCTAssertEqual(state?.line(now: t0), "At gate — waiting on you")
        let landed = GateState.LastMerge(merged: true, at: t0, reason: nil)
        XCTAssertEqual(GateState.resolve(isAwaitingApproval: true, verifyingSince: nil, lastMerge: landed)?.kind, .waiting)
    }
}
