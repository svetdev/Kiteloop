import XCTest
import KiteloopCore
@testable import Kiteloop

/// The ladder is a rendering of rules that live elsewhere — so what these
/// tests pin is that it reports those rules faithfully: each rung met exactly
/// when its switches say so, unmet rungs speaking in the gates' own words, and
/// the advancing control on the first unmet rung alone.
///
/// Five rungs since advisory mode retired: grooming is one rung — the switch
/// is the whole choice — rather than an asks-first rung and an acts rung.
final class AutonomyLadderTests: XCTestCase {

    private func project(_ name: String, ready: Bool = true, optedIn: Bool = false,
                         approves: Bool = false, merges: Bool = false) -> AutonomyLadder.Project {
        AutonomyLadder.Project(name: name, autopilotReady: ready,
                               autonomousWorkEnabled: optedIn,
                               approveReviewPassedRuns: approves,
                               autoMergeOnApproval: merges)
    }

    func testAFreshInstallStandsOnRungOneAlone() {
        let rungs = AutonomyLadder.assess(AutonomyLadder.Inputs())
        XCTAssertEqual(rungs.count, 5)
        XCTAssertEqual(rungs.map(\.met), [true, false, false, false, false])
        XCTAssertEqual(rungs.filter { $0.advance != nil }.count, 1,
                       "only the first unmet rung carries the advancing control")
        XCTAssertEqual(rungs[1].advance?.isEmpty, false)
    }

    func testEveryRungMetNamesItsFacts() {
        var inputs = AutonomyLadder.Inputs(
            projects: [project("travel", optedIn: true, approves: true, merges: true)],
            refillEnabled: true,
            schedulerEnabled: true, dailyBudgetUSD: 200)
        inputs.projects.append(project("kiteloop"))
        let rungs = AutonomyLadder.assess(inputs)
        XCTAssertEqual(rungs.map(\.met), [true, true, true, true, true])
        XCTAssertTrue(rungs[3].detail.contains("travel"))
        XCTAssertTrue(rungs[3].detail.contains("$200.00"))
        XCTAssertTrue(rungs[3].detail.contains("Claude Code's auto mode"),
                      "the rung that starts unattended runs says how they are permitted: \(rungs[3].detail)")
        XCTAssertTrue(rungs[4].detail.contains("travel"))
        XCTAssertNil(rungs.compactMap(\.advance).first, "a full ladder advances nothing")
    }

    /// Grooming is one rung: the switch on means gated drafts get filed —
    /// there is no asks-first rung for a mode that no longer exists.
    func testGroomingIsASingleRungMetByTheSwitchAlone() {
        let rungs = AutonomyLadder.assess(AutonomyLadder.Inputs(
            projects: [project("alpha")],
            refillEnabled: true, dailyBudgetUSD: 100))
        XCTAssertTrue(rungs[2].met)
        XCTAssertTrue(rungs[2].detail.contains("filed"), rungs[2].detail)
    }

    /// The unmet-rung sentences are the gates' own — byte-identical, so the
    /// ladder can never disagree with the control it points at.
    func testUnmetRungsSpeakInTheGatesOwnWords() {
        // No budget: grooming and running rungs carry AutonomyArming's sentences.
        let unbudgeted = AutonomyLadder.assess(AutonomyLadder.Inputs(
            projects: [project("alpha")]))
        XCTAssertEqual(unbudgeted[2].detail,
                       AutonomyArming.armGrooming(dailyBudgetUSD: nil)?.message)
        XCTAssertEqual(unbudgeted[3].detail,
                       AutonomyArming.armScheduling(dailyBudgetUSD: nil)?.message)

        // Armed with a budget but nobody consented: the scheduler's own hold.
        let unconsented = AutonomyLadder.assess(AutonomyLadder.Inputs(
            projects: [project("alpha")],
            schedulerEnabled: true, dailyBudgetUSD: 100))
        XCTAssertEqual(unconsented[3].detail, RunScheduling.Hold.noProjectOptedIn.reason)
    }

    func testCapableButUnconsentedProjectsMeetRungTwoNotRungFour() {
        let rungs = AutonomyLadder.assess(AutonomyLadder.Inputs(
            projects: [project("alpha"), project("beta")],
            refillEnabled: true,
            schedulerEnabled: true, dailyBudgetUSD: 100))
        XCTAssertTrue(rungs[1].met)
        XCTAssertFalse(rungs[3].met)
    }
}
