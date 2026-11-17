import XCTest
@testable import KiteloopCore

/// What keeps routines from firing each other without end: a routine is in a
/// chain once, and where the chain is not known everything since the last
/// outside cause is taken for one.
final class RoutineCauseTests: XCTestCase {

    private var loops = RoutineLoopGuard()
    private let vault = "/vault"

    /// Sends `routine` on `cause` if nothing refuses it, as the runner does.
    /// Returns the refusal, or nil when its prompt was sent.
    @discardableResult
    private func fire(_ routine: String, on cause: RoutineCause, in project: String = "/vault") -> RoutineLoopGuard.Refusal? {
        if let refusal = loops.refusal(of: routine, in: project, cause: cause) { return refusal }
        loops.sent(routine, in: project, cause: cause)
        return nil
    }

    // MARK: - A chain that is known

    func testAScheduledRoutinesTurnFiresAnotherAndThatTurnCarriesBoth() {
        let brief = loops.sent("brief", in: vault, cause: .outside)
        XCTAssertEqual(brief, ["brief"])

        XCTAssertNil(loops.refusal(of: "triage", in: vault, cause: .chain(brief)))
        XCTAssertEqual(loops.sent("triage", in: vault, cause: .chain(brief)), ["brief", "triage"])
    }

    func testARoutineAlreadyInTheChainIsRefusedHoweverLongTheChain() {
        let brief = loops.sent("brief", in: vault, cause: .outside)
        let triage = loops.sent("triage", in: vault, cause: .chain(brief))
        let filing = loops.sent("filing", in: vault, cause: .chain(triage))
        XCTAssertEqual(filing, ["brief", "triage", "filing"], "three routines, each once, is a chain a person made")

        XCTAssertEqual(loops.refusal(of: "brief", in: vault, cause: .chain(filing)), .inItsOwnChain)
        XCTAssertEqual(loops.refusal(of: "triage", in: vault, cause: .chain(filing)), .inItsOwnChain)
        XCTAssertEqual(loops.refusal(of: "filing", in: vault, cause: .chain(filing)), .inItsOwnChain)
    }

    func testTheSameChainRunsAgainTheNextTimeItsScheduleStartsIt() {
        for _ in 0..<3 {
            let brief = loops.sent("brief", in: vault, cause: .outside)
            XCTAssertNil(fire("triage", on: .chain(brief)))
        }
    }

    // MARK: - A chain nobody followed

    func testTwoRoutinesFiringEachOtherUnseenStopAtTheSecondTurnOfTheFirst() {
        XCTAssertNil(fire("on-error", on: .unattributed))
        XCTAssertNil(fire("inbox", on: .unattributed))

        XCTAssertEqual(fire("on-error", on: .unattributed), .tookTurns)
        XCTAssertEqual(fire("on-error", on: .unattributed), .tookTurns, "and it stays refused")
        XCTAssertNil(fire("inbox", on: .unattributed), "nothing fired after the routine that fired last")
    }

    func testThreeRoutinesInARingStopOnceTheFirstComesRound() {
        XCTAssertNil(fire("a", on: .unattributed))
        XCTAssertNil(fire("b", on: .unattributed))
        XCTAssertNil(fire("c", on: .unattributed))
        XCTAssertEqual(fire("a", on: .unattributed), .tookTurns)
        XCTAssertEqual(fire("b", on: .unattributed), .tookTurns)
    }

    func testALoopWithOneHopSeenAndOneUnseenStopsToo() {
        XCTAssertNil(fire("on-error", on: .unattributed))
        XCTAssertNil(fire("inbox", on: .chain(["on-error"])))

        XCTAssertEqual(fire("on-error", on: .unattributed), .tookTurns)
    }

    func testOneRoutineFiredAgainAndAgainWithNoOtherBetweenIsNotALoopOfTwo() {
        for _ in 0..<4 { XCTAssertNil(fire("inbox", on: .unattributed)) }
    }

    func testAnOutsideCauseInTheProjectStartsTheCountingAgain() {
        fire("on-error", on: .unattributed)
        fire("inbox", on: .unattributed)
        XCTAssertEqual(fire("on-error", on: .unattributed), .tookTurns)

        XCTAssertNil(fire("brief", on: .outside), "a schedule, Run now or a webhook")
        XCTAssertNil(fire("on-error", on: .unattributed))
        XCTAssertNil(fire("inbox", on: .unattributed))
        XCTAssertEqual(fire("on-error", on: .unattributed), .tookTurns)
    }

    func testAnOutsideCauseIsNeverRefusedAndAnotherProjectsRoutinesAreNotCounted() {
        fire("on-error", on: .unattributed)
        fire("inbox", on: .unattributed)
        XCTAssertNil(loops.refusal(of: "on-error", in: vault, cause: .outside))

        XCTAssertNil(fire("brief", on: .outside, in: "/elsewhere"))
        XCTAssertEqual(fire("on-error", on: .unattributed), .tookTurns, "an outside cause elsewhere frees nothing here")
        XCTAssertNil(fire("on-error", on: .unattributed, in: "/elsewhere"))
    }

    func testARefusedFiringIsNotATurnSoItFreesNoOtherRoutine() {
        fire("a", on: .unattributed)
        fire("b", on: .unattributed)
        XCTAssertEqual(fire("a", on: .unattributed), .tookTurns)
        XCTAssertNil(fire("b", on: .unattributed), "b fired last; a's refused firing did not come between")
        XCTAssertEqual(fire("a", on: .unattributed), .tookTurns)
    }
}
