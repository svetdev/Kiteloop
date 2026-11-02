import XCTest
import KiteloopCore
@testable import Kiteloop

/// The refill loop's decision half. Everything here is the pure planner — the
/// selection rules, the budget refusal, the bound on how much gets filed and the
/// ledger that stops a gap being groomed twice — so the guarantees are exercised
/// without an app, a registry or a model call.
final class QueueRefillTests: XCTestCase {

    // MARK: - Fixtures

    private func project(_ name: String,
                         ready: Int,
                         paused: Bool = false,
                         autopilotReady: Bool = true,
                         optedIn: Bool = true,
                         running: Bool = false,
                         startable: Int? = nil) -> PortfolioSnapshot.Project {
        PortfolioSnapshot.Project(
            name: name,
            path: "/tmp/\(name)",
            autopilotReady: autopilotReady,
            autonomousWorkEnabled: optedIn,
            statusCounts: ready > 0 ? [.ready: ready] : [:],
            startable: startable,
            run: running ? PortfolioSnapshot.RunState(phase: .running, itemID: "x", itemTitle: "x",
                                                      position: 1, total: 1, attempt: nil) : nil,
            recentOutcomes: [],
            paused: paused,
            goal: nil
        )
    }

    private func portfolio(_ projects: [PortfolioSnapshot.Project]) -> PortfolioSnapshot {
        PortfolioSnapshot(projects: projects)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Threshold and target depth

    func testProjectBelowThresholdIsToppedUpToTheTargetDepth() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 1)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 5, maxItemsPerPass: 10),
            now: now
        )
        let target = try? XCTUnwrap(decision.target)
        XCTAssertEqual(target?.project, "alpha")
        XCTAssertEqual(target?.readyCount, 1)
        // 5 wanted, 1 there — draft the 4 that are missing, not a fixed batch.
        XCTAssertEqual(target?.count, 4)
    }

    func testQueueAtOrAboveThresholdIsLeftAlone() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 2)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 5),
            now: now
        )
        XCTAssertEqual(decision.hold, .queuesHealthy)
    }

    func testFillIsBoundedByMaxItemsPerPass() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 0)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 20, maxItemsPerPass: 3),
            now: now
        )
        XCTAssertEqual(decision.target?.count, 3, "a loop that grooms whenever it can produces infinite work")
    }

    // MARK: - Hunger is judged on what could actually start

    /// The failure `QueueHealth` was written for: three items sit at `ready`,
    /// but nothing could pick any of them up. Read on the raw tally this project
    /// is above the default threshold and never drafted for; the loop must judge
    /// hunger on `startable` instead.
    func testAQueueDeepInReadyButNothingStartableIsHungryAtTheDefaultThreshold() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 3, startable: 0)]),
            now: now
        )

        let target = try? XCTUnwrap(decision.target)
        XCTAssertEqual(target?.project, "alpha")
        XCTAssertEqual(target?.readyCount, 3, "the raw tally is still reported")
        XCTAssertEqual(target?.startableCount, 0)
    }

    /// The other half of the same guarantee: a queue that is deep *and* every
    /// one of those items could run is genuinely healthy, and must stay that way.
    func testAQueueWhereEverythingReadyCanStartStaysHealthy() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 3, startable: 3)]),
            now: now
        )

        XCTAssertEqual(decision.hold, .queuesHealthy)
    }

    /// The shortfall drafted for is measured against `startable`, not the raw
    /// tally — a project with three unrunnable ready items is drafted for as if
    /// it had none, bounded the same way an empty queue would be.
    func testDraftedCountIsMeasuredAgainstTheStartableFigure() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 3, startable: 0)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 5, maxItemsPerPass: 3),
            now: now
        )

        XCTAssertEqual(decision.target?.count, 3, "capped by maxItemsPerPass despite a shortfall of 5")
    }

    /// A snapshot that carries no startable figure at all — the shape every
    /// existing test above builds — must decide exactly as it always has: off
    /// the raw `ready` tally.
    func testASnapshotWithNoStartableFigureFallsBackToTheReadyTally() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 1)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 5, maxItemsPerPass: 10),
            now: now
        )

        let target = try? XCTUnwrap(decision.target)
        XCTAssertEqual(target?.startableCount, nil)
        XCTAssertEqual(target?.count, 4, "unaffected: falls back to the ready tally, same as before")
    }

    func testSanitizedPolicyCannotAskForAnUnboundedOrShrinkingFill() {
        let policy = QueueRefill.Policy(threshold: 4, targetDepth: 1, maxItemsPerPass: 0,
                                        maxProjectsPerPass: 0).sanitized
        XCTAssertEqual(policy.targetDepth, 4, "a target below the threshold would never settle")
        XCTAssertEqual(policy.maxItemsPerPass, 1)
        XCTAssertEqual(policy.maxProjectsPerPass, 1, "a pass that serves nobody is the starvation itself")
    }

    /// The shipped policy has to be able to reach the depth it sets for itself.
    /// A target of 5 over a per-pass cap of 3 was unreachable by construction:
    /// an emptied queue climbed to 3 and spent the gap to the next pass short of
    /// the depth the policy had already decided it wanted. The target came down
    /// to meet the cap rather than the cap going up — three items a pass is the
    /// ceiling on how much unreviewed work is filed at once, and starvation was
    /// never a question of how much.
    func testAQueueAtZeroReachesTheTargetDepthInOnePass() {
        let policy = QueueRefill.Policy.default.sanitized
        let decision = QueueRefill.decide(portfolio: portfolio([project("alpha", ready: 0)]),
                                          policy: policy, now: now)

        XCTAssertEqual(decision.target?.count, policy.targetDepth,
                       "one pass has to be able to fill an empty queue to the target")
        XCTAssertEqual(policy.maxItemsPerPass, 3,
                       "the per-pass item ceiling is unchanged — this was never about how much")
    }

    // MARK: - One pass, the whole fleet

    /// The measured failure: three autopilot-ready projects, a pass that topped
    /// up one, and a cadence that therefore divided by three. Two of the three
    /// sat at `ready=0` while grooming had spent 1 of 150 passes and $3.85 of
    /// $350 — nothing capped, nothing wedged, the queue simply could not be
    /// refilled as fast as it drained.
    func testOnePassServesEveryHungryProject() {
        let decision = QueueRefill.decidePass(
            portfolio: portfolio([project("alpha", ready: 0),
                                  project("beta", ready: 0),
                                  project("gamma", ready: 1)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 4, maxItemsPerPass: 4),
            now: now
        )

        XCTAssertEqual(decision.targets.map(\.project), ["alpha", "beta", "gamma"])
        XCTAssertEqual(decision.targets.map(\.count), [4, 4, 3],
                       "each project is filled to its own shortfall, not to a shared batch")
    }

    /// A project at zero and a project at four should not wait the same length of
    /// time. The emptier queue is the one nearer to starving, so it is served
    /// first.
    func testTheEmptiestQueueIsServedFirst() {
        let decision = QueueRefill.decidePass(
            portfolio: portfolio([project("full-ish", ready: 3),
                                  project("empty", ready: 0),
                                  project("nearly", ready: 1)]),
            policy: QueueRefill.Policy(threshold: 4, targetDepth: 4),
            now: now
        )

        XCTAssertEqual(decision.targets.map(\.project), ["empty", "nearly", "full-ish"])
    }

    /// Need is the whole grooming order now: the deeper hole is served first
    /// whatever else is true of the two projects.
    func testTheDeeperHoleIsServedFirstWithNothingElseToConsult() {
        let decision = QueueRefill.decidePass(
            portfolio: portfolio([project("empty", ready: 0),
                                  project("nearly", ready: 1)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 4),
            now: now
        )

        XCTAssertEqual(decision.targets.map(\.project), ["empty", "nearly"])
    }

    /// Equally empty: the one that has been waiting longer.
    func testIdleTimeStillBreaksTheTieBetweenEquallyEmptyQueues() {
        let decision = QueueRefill.decidePass(
            portfolio: portfolio([project("recent", ready: 0), project("ancient", ready: 0)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 4),
            idleSince: ["recent": now.addingTimeInterval(-600),
                        "ancient": now.addingTimeInterval(-9_000)],
            now: now
        )

        XCTAssertEqual(decision.targets.map(\.project), ["ancient", "recent"])
    }

    /// A pass is raced against a deadline it does not get to extend by serving
    /// more projects, so how wide it fans out is bounded — and bounded by need
    /// order, so the ones dropped are the ones with the most left to run.
    func testAPassIsBoundedByHowManyProjectsItMayServe() {
        let decision = QueueRefill.decidePass(
            portfolio: portfolio([project("a", ready: 0), project("b", ready: 1),
                                  project("c", ready: 2), project("d", ready: 3)]),
            policy: QueueRefill.Policy(threshold: 4, targetDepth: 4, maxProjectsPerPass: 2),
            now: now
        )

        XCTAssertEqual(decision.targets.map(\.project), ["a", "b"])
    }

    func testAPausedOrUnrunnableProjectIsInNoPassHoweverEmptyItIs() {
        let decision = QueueRefill.decidePass(
            portfolio: portfolio([project("paused", ready: 0, paused: true),
                                  project("unrunnable", ready: 0, autopilotReady: false),
                                  project("open", ready: 1)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 4),
            now: now
        )

        XCTAssertEqual(decision.targets.map(\.project), ["open"])
    }

    /// The budget refuses the whole pass, not the projects after the first: an
    /// exhausted ceiling must not be reachable by fanning out.
    func testAnExhaustedBudgetServesNoProjectAtAll() {
        let decision = QueueRefill.decidePass(
            portfolio: portfolio([project("alpha", ready: 0), project("beta", ready: 0)]),
            budget: QueueRefill.Budget(spentUSD: 10, capUSD: 10, day: now),
            now: now
        )

        XCTAssertEqual(decision.targets, [])
        XCTAssertEqual(decision.hold?.kind, "budgetExhausted")
    }

    func testAHealthyFleetHoldsRatherThanServingNobody() {
        let decision = QueueRefill.decidePass(
            portfolio: portfolio([project("alpha", ready: 5), project("beta", ready: 9)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 5),
            now: now
        )

        XCTAssertEqual(decision.hold, .queuesHealthy)
    }

    /// The two readings of the same portfolio cannot disagree about which
    /// project comes first — a caller that wants one target is asking the same
    /// question a pass asks, just narrower.
    func testTheSingleTargetIsTheFirstOneThePassWouldServe() {
        let fleet = portfolio([project("full-ish", ready: 3), project("empty", ready: 0),
                               project("nearly", ready: 1)])
        let policy = QueueRefill.Policy(threshold: 4, targetDepth: 4)

        let one = QueueRefill.decide(portfolio: fleet, policy: policy, now: now)
        let all = QueueRefill.decidePass(portfolio: fleet, policy: policy, now: now)

        XCTAssertEqual(one.target, all.targets.first)
        XCTAssertEqual(one.target?.project, "empty")
    }

    // MARK: - The paused hard stop

    func testPausedProjectIsNeverChosenEvenWhenItIsTheEmptiest() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([
                project("paused-and-empty", ready: 0, paused: true),
                project("beta", ready: 1)
            ]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 4),
            now: now
        )
        XCTAssertEqual(decision.target?.project, "beta")
    }

    func testPausedProjectAloneYieldsNoEligibleProject() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 0, paused: true)]),
            now: now
        )
        XCTAssertEqual(decision.hold, .noEligibleProject)
    }

    func testProjectWithoutWorkerAndReviewerIsNotGroomedFor() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 0, autopilotReady: false)]),
            now: now
        )
        XCTAssertEqual(decision.hold, .noEligibleProject)
    }

    // MARK: - Emptiest queue, then idle longest

    func testTheEmptiestQueueDecidesBetweenTwoEligibleProjects() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([
                project("alpha", ready: 0),
                project("beta", ready: 1)
            ]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 4),
            now: now
        )
        XCTAssertEqual(decision.target?.project, "alpha", "the deeper hole is groomed for first")
    }

    func testIdleTimeBreaksTheTieBetweenEquallyEmptyProjects() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 0), project("beta", ready: 0)]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 4),
            idleSince: ["alpha": now.addingTimeInterval(-600),
                        "beta": now.addingTimeInterval(-9_000)],
            now: now
        )
        XCTAssertEqual(decision.target?.project, "beta", "idle longest has been waiting longest")
    }

    func testARunningProjectCountsAsIdleForNoTime() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([
                project("alpha", ready: 0, running: true),
                project("beta", ready: 0)
            ]),
            policy: QueueRefill.Policy(threshold: 2, targetDepth: 4),
            // alpha's stamp is ancient, but it is running right now.
            idleSince: ["alpha": now.addingTimeInterval(-90_000), "beta": now.addingTimeInterval(-60)],
            now: now
        )
        XCTAssertEqual(decision.target?.project, "beta")
    }

    func testTrackIdleKeepsTheFirstIdleInstantAndDropsRunningProjects() {
        let first = QueueRefill.trackIdle([:], portfolio: portfolio([project("alpha", ready: 0)]), now: now)
        XCTAssertEqual(first["alpha"], now)

        let later = now.addingTimeInterval(3_600)
        let kept = QueueRefill.trackIdle(first, portfolio: portfolio([project("alpha", ready: 0)]), now: later)
        XCTAssertEqual(kept["alpha"], now, "idle since is when it went idle, not when it was last looked at")

        let running = QueueRefill.trackIdle(kept, portfolio: portfolio([project("alpha", ready: 0, running: true)]),
                                            now: later)
        XCTAssertNil(running["alpha"])
    }

    // MARK: - Budget

    func testExhaustedSpendStopsThePassBeforeAProjectIsChosen() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 0)]),
            budget: QueueRefill.Budget(spentUSD: 12, capUSD: 10, day: now),
            now: now
        )
        guard case .budgetExhausted(let reason) = decision.hold else {
            return XCTFail("expected a budget refusal, got \(String(describing: decision.hold))")
        }
        XCTAssertTrue(reason.contains("12.00") && reason.contains("10.00"), reason)
        XCTAssertNil(decision.target, "exhausted means stop, not a smaller pass")
    }

    func testExhaustedPassCountStopsThePass() {
        let decision = QueueRefill.decide(
            portfolio: portfolio([project("alpha", ready: 0)]),
            budget: QueueRefill.Budget(passes: 12, maxPasses: 12, day: now),
            now: now
        )
        XCTAssertEqual(decision.hold, .budgetExhausted("daily grooming passes used (12 of 12)"))
    }

    func testBudgetRollsOverAtTheDayBoundary() {
        let spent = QueueRefill.Budget(spentUSD: 12, capUSD: 10, passes: 5, maxPasses: 12,
                                       abandonedPasses: 2, day: now)
        XCTAssertTrue(spent.isExhausted)

        let tomorrow = now.addingTimeInterval(26 * 3_600)
        let rolled = spent.rolled(to: tomorrow)
        XCTAssertEqual(rolled.spentUSD, 0)
        XCTAssertEqual(rolled.passes, 0)
        XCTAssertEqual(rolled.abandonedPasses, 0,
                       "yesterday's stalls are yesterday's, like the spend beside them")
        XCTAssertEqual(rolled.capUSD, 10, "the ceiling survives the day; only the counters reset")
        XCTAssertFalse(rolled.isExhausted)

        XCTAssertNotNil(QueueRefill.decide(portfolio: portfolio([project("alpha", ready: 0)]),
                                           budget: spent, now: tomorrow).target)
    }

    func testChargingAPassCountsItAgainstTheDay() {
        let charged = QueueRefill.Budget(capUSD: 10, maxPasses: 3, day: now).charged(1.25, at: now)
        XCTAssertEqual(charged.passes, 1)
        XCTAssertEqual(charged.spentUSD, 1.25, accuracy: 0.0001)
        XCTAssertEqual(charged.abandonedPasses, 0, "a pass is charged before it can be abandoned")
    }

    // MARK: - Passes that were ended rather than finished

    /// The count is a second reading of the same pass, not a second pass: the
    /// ceiling was already spent when it started, and telling an abandoned pass
    /// from one that filed work is the whole point of keeping them apart.
    func testAnAbandonedPassIsCountedBesideThePassesRatherThanInsideThem() {
        let charged = QueueRefill.Budget(spentUSD: 4, capUSD: 10, maxPasses: 3, day: now)
            .charged(1.25, at: now)
        let abandoned = charged.abandonedAPass()

        XCTAssertEqual(abandoned.abandonedPasses, 1)
        XCTAssertEqual(abandoned.passes, charged.passes, "the pass was spent when it started")
        XCTAssertEqual(abandoned.spentUSD, charged.spentUSD, accuracy: 0.0001)
        XCTAssertEqual(abandoned.abandonedAPass().abandonedPasses, 2, "a night can hang twice")
    }

    /// A day with nothing to report says zero rather than going quiet — the
    /// silence is what made a night of repeated stalls read like a calm one.
    func testTheAbandonedReadingStatesZeroRatherThanNothing() {
        XCTAssertEqual(QueueRefill.Budget(day: now).abandonedText, "0 passes abandoned today")
        // And the pluralisation, so a footer never reads "1 passes".
        XCTAssertEqual(QueueRefill.Budget(abandonedPasses: 1, day: now).abandonedText,
                       "1 pass abandoned today")
        XCTAssertEqual(QueueRefill.Budget(abandonedPasses: 4, day: now).abandonedText,
                       "4 passes abandoned today")
    }

    // MARK: - The nearest ceiling

    func testTheNearestCeilingIsTheProportionallyCloserOfTheTwo() {
        // Half the money, four fifths of the passes: the passes are nearer.
        let passesNearer = QueueRefill.Budget(spentUSD: 125, capUSD: 250,
                                              passes: 8, maxPasses: 10, day: now).nearestCeiling
        XCTAssertEqual(passesNearer.kind, .passes)
        XCTAssertEqual(passesNearer.text, "8 of 10 passes")
        XCTAssertEqual(passesNearer.summary, "8 of 10 passes · stops grooming")

        // Same budget, two passes in: now the money is nearer.
        let spendNearer = QueueRefill.Budget(spentUSD: 125, capUSD: 250,
                                             passes: 2, maxPasses: 10, day: now).nearestCeiling
        XCTAssertEqual(spendNearer.kind, .spend)
        XCTAssertEqual(spendNearer.text, "$125.00 of $250.00")
        XCTAssertEqual(spendNearer.summary, "$125.00 of $250.00 · stops grooming")
    }

    func testATieBetweenTheTwoCeilingsGoesToTheMoney() {
        let tied = QueueRefill.Budget(spentUSD: 125, capUSD: 250,
                                      passes: 5, maxPasses: 10, day: now).nearestCeiling
        XCTAssertEqual(tied.kind, .spend)
        XCTAssertEqual(tied.fraction, 0.5)
    }

    func testOnlyCeilingSetIsTheNearestOneWhicheverItIs() {
        let capped = QueueRefill.Budget(spentUSD: 3, capUSD: 250, passes: 9, day: now).nearestCeiling
        XCTAssertEqual(capped.kind, .spend, "an unset pass ceiling is no competition, however many passes ran")
        XCTAssertEqual(capped.text, "$3.00 of $250.00")

        let counted = QueueRefill.Budget(spentUSD: 300, passes: 1, maxPasses: 10, day: now).nearestCeiling
        XCTAssertEqual(counted.kind, .passes, "an unset spend ceiling is no competition, however much was spent")
        XCTAssertEqual(counted.text, "1 of 10 passes")
    }

    func testAnUncappedBudgetReadsAsUncappedRatherThanAsALimitOfZero() {
        let uncapped = QueueRefill.Budget(spentUSD: 18.5, passes: 1, day: now).nearestCeiling
        XCTAssertEqual(uncapped.kind, .uncapped)
        XCTAssertNil(uncapped.fraction, "no ceiling means no proportion, not a full bar")
        XCTAssertEqual(uncapped.summary, "$18.50 · 1 pass · grooming uncapped")
        XCTAssertFalse(uncapped.isExhausted)

        // The pluralisation, so a footer never reads "1 passes".
        let several = QueueRefill.Budget(spentUSD: 18.5, passes: 4, day: now).nearestCeiling
        XCTAssertEqual(several.summary, "$18.50 · 4 passes · grooming uncapped")
    }

    func testAStoppedBudgetSaysWhichCeilingStoppedItAndWhy() {
        let outOfMoney = QueueRefill.Budget(spentUSD: 250, capUSD: 250,
                                            passes: 2, maxPasses: 10, day: now).nearestCeiling
        XCTAssertEqual(outOfMoney.kind, .spend)
        XCTAssertTrue(outOfMoney.isExhausted)
        XCTAssertEqual(outOfMoney.summary,
                       "Stopped — daily grooming budget spent ($250.00 of $250.00)")

        // Passes gone with money to spare: the reading follows the ceiling that
        // actually stopped grooming, not the one with the bigger number on it.
        let outOfPasses = QueueRefill.Budget(spentUSD: 1, capUSD: 250,
                                             passes: 10, maxPasses: 10, day: now).nearestCeiling
        XCTAssertEqual(outOfPasses.kind, .passes)
        XCTAssertEqual(outOfPasses.summary, "Stopped — daily grooming passes used (10 of 10)")
    }

    func testACapOfZeroHasStoppedGroomingEvenThoughItHasNoProportion() {
        let ceiling = QueueRefill.Budget(spentUSD: 0, capUSD: 0, day: now).nearestCeiling
        XCTAssertEqual(ceiling.kind, .spend, "a cap with no fraction to measure has still stopped it")
        XCTAssertEqual(ceiling.fraction, 1)
        XCTAssertEqual(ceiling.summary, "Stopped — daily grooming budget spent ($0.00 of $0.00)")
    }

    func testTheHelpTextNamesBothCeilingsAndTheReasonWhenThereIsOne() {
        let running = QueueRefill.Budget(spentUSD: 18, capUSD: 250,
                                         passes: 4, maxPasses: 10, day: now)
        XCTAssertEqual(running.helpText,
                       "Grooming budget $18.00 of $250.00 · 4 of 10 passes · 0 passes abandoned today.")

        // What a night that hung and recovered leaves behind, beside ceilings
        // that never came near stopping anything.
        let stalled = QueueRefill.Budget(spentUSD: 52.59, capUSD: 350,
                                         passes: 20, maxPasses: 150,
                                         abandonedPasses: 3, day: now)
        XCTAssertEqual(stalled.helpText,
                       "Grooming budget $52.59 of $350.00 · 20 of 150 passes · 3 passes abandoned today.")

        let uncapped = QueueRefill.Budget(spentUSD: 18, passes: 1, day: now)
        XCTAssertEqual(uncapped.helpText,
                       "Grooming budget $18.00 · no cap set · 1 pass · no cap set · 0 passes abandoned today.")

        let stopped = QueueRefill.Budget(spentUSD: 250, capUSD: 250, day: now)
        XCTAssertTrue(stopped.helpText.hasSuffix(
            "Grooming has stopped: daily grooming budget spent ($250.00 of $250.00)."), stopped.helpText)
    }

    // MARK: - The ledger

    func testAFiledItemIsNotFiledAgainForTheSameProject() {
        var ledger = QueueRefill.Ledger()
        ledger.record(project: "alpha", id: "cache-the-index",
                      title: "Cache the source index between runs", disposition: .ready, at: now)

        XCTAssertTrue(ledger.hasFiled(project: "alpha", id: "cache-the-index", title: "anything"))
        XCTAssertTrue(ledger.hasFiled(project: "alpha", id: "different-id",
                                      title: "Cache the source index between runs"),
                      "the same item under a new id is still the same item")
        XCTAssertFalse(ledger.hasFiled(project: "beta", id: "cache-the-index",
                                       title: "Cache the source index between runs"),
                       "the same idea in another repo is another item")
    }

    func testARejectedItemIsNotReinventedByRewordingIt() {
        var ledger = QueueRefill.Ledger()
        // Filed, then rejected by a human — the ledger doesn't care which, it
        // only knows this gap was already groomed.
        ledger.record(project: "alpha", id: "grounding-cache",
                      title: "Cache the grounding index for a run", disposition: .draft, at: now)

        XCTAssertTrue(ledger.hasFiled(project: "alpha", id: "grounding-index-cache",
                                      title: "cache the grounding index for a run"))
        XCTAssertTrue(ledger.hasFiled(project: "alpha", id: "x",
                                      title: "Cache, for a run, the grounding index."),
                      "reordering and punctuation is not a new idea")
        XCTAssertFalse(ledger.hasFiled(project: "alpha", id: "y",
                                       title: "Invalidate the grounding index on file change"),
                       "a genuinely different item must still get through")
    }

    /// The drafter is judged against every filing, so it has to be shown every
    /// filing — the ordered accessor is what closes that gap, and it must not
    /// stop at some recent window however long the ledger gets.
    func testEveryFilingForAProjectIsListedOldestFirst() {
        var ledger = QueueRefill.Ledger()
        for index in 1...40 {
            ledger.record(project: "alpha", id: "alpha-\(index)",
                          title: "Alpha item \(index)", disposition: .ready, at: now)
            ledger.record(project: "beta", id: "beta-\(index)",
                          title: "Beta item \(index)", disposition: .ready, at: now)
        }

        let filed = ledger.filedIDsInOrder(project: "alpha")
        XCTAssertEqual(filed, (1...40).map { "alpha-\($0)" },
                       "every filing, oldest first — a window would hide the early ones")
        XCTAssertFalse(filed.contains { $0.hasPrefix("beta-") },
                       "another repo's filings are not this project's constraint")
        XCTAssertEqual(Set(filed), ledger.filedIDs(project: "alpha"),
                       "the ordered list and the set answer the same question")
    }

    func testFingerprintIgnoresCaseWordOrderAndFillerWords() {
        XCTAssertEqual(QueueRefill.Ledger.fingerprint("Cache the source index"),
                       QueueRefill.Ledger.fingerprint("cache source index"))
        XCTAssertNotEqual(QueueRefill.Ledger.fingerprint("Cache the source index"),
                          QueueRefill.Ledger.fingerprint("Cache the symbol index"))
    }

    // MARK: - Already on the board

    /// The ledger's blunt rule, applied to the backlog itself: an item that is
    /// already there is not drafted again, whoever wrote it. The ledger cannot
    /// answer this — it only knows what the coordinator filed — and a bare id
    /// collision is renamed rather than refused, so a hand-written item used to
    /// come back re-proposed under a suffixed id.
    func testACandidateAlreadyOnTheBoardNamesTheItemItDuplicates() {
        let items = [
            backlogItem(id: "existing-1", title: "Cache the source index between runs"),
            backlogItem(id: "existing-2", title: "Invalidate the index on file change")
        ]

        XCTAssertEqual(QueueRefill.Ledger.duplicate(of: "Cache the source index between runs",
                                                    in: items)?.id,
                       "existing-1",
                       "the refusal has to name the item, not only say there was one")
        XCTAssertEqual(QueueRefill.Ledger.duplicate(of: "cache, between runs, the source index.",
                                                    in: items)?.id,
                       "existing-1",
                       "the same rewording tolerance the ledger has")
        XCTAssertNil(QueueRefill.Ledger.duplicate(of: "Cache the symbol table between runs", in: items),
                     "a genuinely different item must still get through")
        XCTAssertNil(QueueRefill.Ledger.duplicate(of: "Anything at all", in: []))
    }

    /// A `done` item counts. Finished work is the clearest case of something not
    /// worth drafting again, and the fingerprint is exact enough that only a
    /// near-verbatim title reaches it.
    func testAFinishedItemIsStillAnItemTheBoardHolds() {
        let items = [backlogItem(id: "existing-1", title: "Cache the source index", status: .done)]

        XCTAssertEqual(QueueRefill.Ledger.duplicate(of: "Cache the source index", in: items)?.id,
                       "existing-1")
    }

    /// A title that fingerprints to nothing matches nothing rather than
    /// everything — the guard `hasFiled` carries, for the same reason.
    func testATitleOfNothingButFillerWordsMatchesNothing() {
        let items = [backlogItem(id: "existing-1", title: "the it and so")]

        XCTAssertEqual(QueueRefill.Ledger.fingerprint("of the this"), "")
        XCTAssertNil(QueueRefill.Ledger.duplicate(of: "of the this", in: items),
                     "two empty fingerprints are not two of the same item")
    }

    private func backlogItem(id: String, title: String,
                             status: BacklogItemStatus = .ready) -> BacklogItem {
        BacklogItem(id: id, title: title, verify: "true", status: status, type: .local, size: .s)
    }

    func testLedgerRoundTripsThroughItsFile() throws {
        let url = try makeTemporaryDirectory(prefix: "queue-refill")
            .appending(path: "ledger.jsonl")

        XCTAssertTrue(QueueRefill.Ledger.load(from: url).entries.isEmpty, "a missing file is an empty memory")

        let entry = QueueRefill.Ledger.Entry(at: now, project: "alpha", itemID: "cache-the-index",
                                             fingerprint: QueueRefill.Ledger.fingerprint("Cache the index"),
                                             disposition: "ready")
        QueueRefill.Ledger.append(entry, to: url)
        QueueRefill.Ledger.append(entry, to: url)

        let loaded = QueueRefill.Ledger.load(from: url)
        XCTAssertEqual(loaded.entries.count, 2)
        XCTAssertTrue(loaded.hasFiled(project: "alpha", id: "cache-the-index", title: "Cache the index"),
                      "the memory has to survive a restart or every rejection comes back")
        XCTAssertEqual(loaded.filedIDs(project: "alpha"), ["cache-the-index"])
    }

    func testACorruptLedgerLineIsSkippedRatherThanLosingTheRest() throws {
        let url = try makeTemporaryDirectory(prefix: "queue-refill")
            .appending(path: "ledger.jsonl")

        QueueRefill.Ledger.append(
            QueueRefill.Ledger.Entry(at: now, project: "alpha", itemID: "one",
                                     fingerprint: "one", disposition: "ready"), to: url)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write("{ truncated\n".data(using: .utf8)!)
        try handle.close()

        XCTAssertEqual(QueueRefill.Ledger.load(from: url).entries.count, 1)
    }

    /// A kill that cuts a line inside a multi-byte character leaves the file
    /// invalid UTF-8; read as one string, the whole memory loaded empty.
    func testALineCutInsideAMultiByteCharacterCostsOnlyThatLine() throws {
        let url = try makeTemporaryDirectory(prefix: "queue-refill")
            .appending(path: "ledger.jsonl")

        QueueRefill.Ledger.append(
            QueueRefill.Ledger.Entry(at: now, project: "alpha", itemID: "one",
                                     fingerprint: "one", disposition: "ready"), to: url)
        // The first two bytes of an em dash, then the newline a later append adds.
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"title\":\"a".utf8) + Data([0xE2, 0x80]) + Data("\n".utf8))
        try handle.close()
        QueueRefill.Ledger.append(
            QueueRefill.Ledger.Entry(at: now, project: "alpha", itemID: "two",
                                     fingerprint: "two", disposition: "ready"), to: url)

        XCTAssertEqual(QueueRefill.Ledger.load(from: url).entries.map(\.itemID), ["one", "two"])
    }

    /// And the entry appended *after* the crash keeps its own line. Appending
    /// straight onto the remnant would glue the two into something that decodes
    /// as neither, so the gap filled after the crash would be forgotten and the
    /// next pass would pay the model to propose the very item it already filed.
    func testAnEntryAppendedAfterATruncatedLineIsReadBackOnTheNextLoad() throws {
        let url = try makeTemporaryDirectory(prefix: "queue-refill")
            .appending(path: "ledger.jsonl")

        QueueRefill.Ledger.append(
            QueueRefill.Ledger.Entry(at: now, project: "alpha", itemID: "one",
                                     fingerprint: "one", disposition: "ready"), to: url)
        // The shape a kill mid-append leaves: half an entry, no newline after it.
        try appendRaw("{\"project\":\"alp", to: url)

        QueueRefill.Ledger.append(
            QueueRefill.Ledger.Entry(at: now, project: "alpha", itemID: "two",
                                     fingerprint: "two", disposition: "ready"), to: url)

        let loaded = QueueRefill.Ledger.load(from: url)
        XCTAssertEqual(loaded.entries.map(\.itemID), ["one", "two"],
                       "the filing recorded after the crash survives")
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("{\"project\":\"alp\n"),
                      "the remnant is still there, on its own line, and still skipped by the loader")
    }

    /// The ordinary append is unchanged by the repair: a file already ending in
    /// a newline gains one line, not a blank one before it.
    func testAppendingIntoALedgerEndingInANewlineAddsNoBlankLine() throws {
        let url = try makeTemporaryDirectory(prefix: "queue-refill")
            .appending(path: "ledger.jsonl")

        for id in ["one", "two"] {
            QueueRefill.Ledger.append(
                QueueRefill.Ledger.Entry(at: now, project: "alpha", itemID: id,
                                         fingerprint: id, disposition: "ready"), to: url)
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("\n\n"), "no blank line between the entries")
        XCTAssertEqual(QueueRefill.Ledger.load(from: url).entries.count, 2)
    }

    /// The ledger lives beside the coordinator's other logs, in a directory a
    /// fresh install has not created yet.
    func testAppendingIntoADirectoryThatDoesNotExistYetStillLands() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "queue-refill-\(UUID().uuidString)")
            .appending(path: "nested")
            .appending(path: "ledger.jsonl")
        defer {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent()
                .deletingLastPathComponent())
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.deletingLastPathComponent().path(percentEncoded: false)))

        QueueRefill.Ledger.append(
            QueueRefill.Ledger.Entry(at: now, project: "alpha", itemID: "one",
                                     fingerprint: "one", disposition: "ready"), to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasSuffix("\n"), "the line is newline-terminated")
        XCTAssertEqual(QueueRefill.Ledger.load(from: url).entries.map(\.itemID), ["one"])
    }

    private func appendRaw(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Drafts

    private let goodDraftJSON = """
    {"items":[{"id":"Cache The Index!","title":"Cache the source index between items",
      "size":"m","verify":"xcodebuild -scheme Kiteloop build",
      "what":"The index is built once per run.","how":"Hold it on the autopilot.",
      "validation":["A queue of five items builds the index once"],
      "outOfScope":["Persisting the index across launches"],"epic":"Now"}]}
    """

    func testParseAcceptsAWellFormedDraftAndNormalizesItsID() throws {
        let drafts = QueueRefill.Draft.parse(goodDraftJSON)
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.id, "cache-the-index", "an id has to survive being a filename")
        XCTAssertEqual(draft.size, "m")
        XCTAssertEqual(draft.validation, ["A queue of five items builds the index once"])
        XCTAssertEqual(draft.epic, "Now")
    }

    func testParseDropsDraftsMissingWhatTheDefinitionOfReadyNeeds() {
        let missingVerify = """
        {"items":[{"id":"a","title":"t","size":"S","verify":"","what":"w","how":"h","validation":["v"]}]}
        """
        let missingValidation = """
        {"items":[{"id":"a","title":"t","size":"S","verify":"make","what":"w","how":"h","validation":[]}]}
        """
        let badSize = """
        {"items":[{"id":"a","title":"t","size":"L","verify":"make","what":"w","how":"h","validation":["v"]}]}
        """
        XCTAssertTrue(QueueRefill.Draft.parse(missingVerify).isEmpty)
        XCTAssertTrue(QueueRefill.Draft.parse(missingValidation).isEmpty)
        XCTAssertTrue(QueueRefill.Draft.parse(badSize).isEmpty, "L is not autopilot work")
        XCTAssertTrue(QueueRefill.Draft.parse("no json here").isEmpty)
    }

    /// A backlog line is one line. `title` and `verify` go onto it as written, so
    /// a newline in either ends the line early — the item loses its `size:` token,
    /// its status and its detail link, and the rest is read back as an unparsed
    /// line. Refused at parse, where the other half-drafted candidates are.
    func testParseDropsADraftWhoseTitleOrVerifyWouldSplitTheLine() {
        let titleHoldsANewline = """
        {"items":[{"id":"a","title":"Cache the index\\nand the symbols","size":"S",
          "verify":"make","what":"w","how":"h","validation":["v"]}]}
        """
        let verifyHoldsANewline = """
        {"items":[{"id":"a","title":"t","size":"S","verify":"make build\\nmake test",
          "what":"w","how":"h","validation":["v"]}]}
        """
        XCTAssertTrue(QueueRefill.Draft.parse(titleHoldsANewline).isEmpty,
                      "a title with a newline cannot be written onto one line")
        XCTAssertTrue(QueueRefill.Draft.parse(verifyHoldsANewline).isEmpty,
                      "nor can a verify with one")
    }

    /// The trim each field already gets means a draft whose only newline is on the
    /// end is still perfectly writable, and stays accepted.
    func testParseKeepsADraftWhoseFieldsMerelyEndInWhitespace() throws {
        let json = """
        {"items":[{"id":"a","title":"\\nCache the index\\n","size":"S","verify":"  make  ",
          "what":"w","how":"h","validation":["v"]}]}
        """
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(json).first)
        XCTAssertEqual(draft.title, "Cache the index")
        XCTAssertEqual(draft.verify, "make")
        let line = BacklogSerializer.serializeItem(draft.item(status: .ready))
        XCTAssertEqual(BacklogParser.parseItemLine(line, verifyDefault: nil)?.title, "Cache the index")
    }

    // MARK: - The verify a detail file carries

    /// A draft that says nothing but its verify, so a round-trip failure is
    /// about the command and not about anything else on the file.
    private func draft(verify: String) -> QueueRefill.Draft {
        QueueRefill.Draft(id: "a", title: "An item", size: "S", verify: verify,
                          what: "w", how: "h", validation: ["v"], outOfScope: [])
    }

    /// The command as it comes back off the detail file the draft writes —
    /// which is the one `DefinitionOfReady` and `GroundingCheck` prefer, and
    /// the one a run executes.
    private func verifyThroughTheDetailFile(_ verify: String) throws -> String {
        let detail = try XCTUnwrap(BacklogParser.parseDetail(draft(verify: verify).detailMarkdown()))
        return try XCTUnwrap(detail.verifyCommands.first?.cmd)
    }

    /// Every escape the reader resolves has to be one the writer produces, or
    /// the file says something the groomer didn't. Writing escaped only `"`,
    /// so a backslash was eaten and a literal `\n` came back as a real newline.
    func testEveryEscapeTheReaderResolvesIsOneTheWriterWrites() {
        // A backslash, a quote, the two characters `\` and `n`, and a tab.
        let awkward = "grep -c \\d 'a\"b' \\n\tdone"

        let written = BacklogParser.doubleQuotedScalarLiteral(awkward)

        XCTAssertEqual(BacklogParser.doubleQuotedScalar(written), awkward)
        XCTAssertTrue(written.hasPrefix("\"") && written.hasSuffix("\""),
                      "the quotes are part of what the writer produces: \(written)")
    }

    /// The backslash has to be doubled *before* the quote is escaped, or the
    /// backslash the writer adds is itself escaped and the reader sees a literal
    /// backslash followed by the quote that ends the scalar.
    func testABackslashBeforeAQuoteIsEscapedInTheOrderTheReaderUndoes() {
        let value = "say \\\"hi\\\""  // say \"hi\"

        XCTAssertEqual(BacklogParser.doubleQuotedScalar(
            BacklogParser.doubleQuotedScalarLiteral(value)), value)
    }

    /// The shape this was found on: `-exec … {} \;` was written verbatim into a
    /// quoted scalar and read back as `-exec … {} ;`, which `find` refuses.
    func testABackslashInADraftsVerifySurvivesTheDetailFile() throws {
        let command = "find . -name '*.swift' -exec grep -l x {} \\;"

        XCTAssertEqual(try verifyThroughTheDetailFile(command), command)
    }

    /// The other half of the same defect: `CLAUDE.md` asks for one-liners piped
    /// without spaces, and one that mentions a newline used to come back with a
    /// real one in it — which the line-oriented reader then truncated at.
    func testALiteralNewlineEscapeInAVerifyStaysTwoCharacters() throws {
        let command = "kiteloopctl status --json|python3 -c 'import sys;print(sys.stdin.read().split(\"\\n\")[0])'"

        XCTAssertEqual(try verifyThroughTheDetailFile(command), command)
    }

    /// The overwhelmingly common shape — quotes, no backslashes — is untouched
    /// by any of this. This repo's own verify is the one every item carries.
    func testTheReposOwnVerifyRoundTripsUnchanged() throws {
        let command = "cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop "
            + "-destination \"platform=macOS\" build-for-testing"

        XCTAssertEqual(try verifyThroughTheDetailFile(command), command)
    }

    // MARK: - Provenance

    /// Splitting an item is where lineage is knowable, so a draft that came out
    /// of one carries the parent through to the line it becomes.
    func testADraftSplitOutOfAnItemCarriesTheParentOntoItsLine() throws {
        let json = """
        {"items":[{"id":"child","title":"Half of the big one","size":"S","verify":"make",
          "what":"w","how":"h","validation":["v"],"from":"big-parent-item"}]}
        """
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(json).first)
        XCTAssertEqual(draft.from, "big-parent-item")
        let line = BacklogSerializer.serializeItem(draft.item(status: .ready))
        XCTAssertEqual(BacklogParser.parseItemLine(line, verifyDefault: nil)?.from, "big-parent-item")
    }

    /// The common case: a gap found in the code, not in another item.
    func testADraftWithNoStatedParentHasNoProvenance() throws {
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(goodDraftJSON).first)
        XCTAssertNil(draft.from)
    }

    /// A parent is an id that already exists somewhere, so it is taken as
    /// written — only what the *line* cannot carry is refused, since a `|` or a
    /// newline would split the item into nonsense.
    func testAParentIDIsTakenAsWrittenUnlessItWouldBreakTheLine() {
        XCTAssertEqual(QueueRefill.Draft.parentID("  PROJ-123 "), "PROJ-123",
                       "an existing id must not be slugged into a different one")
        XCTAssertNil(QueueRefill.Draft.parentID(""))
        XCTAssertNil(QueueRefill.Draft.parentID("parent | ready"))
        XCTAssertNil(QueueRefill.Draft.parentID("parent\nready"))
    }

    /// Lineage is descriptive: the gate that decides whether the item runs must
    /// not notice it either way.
    func testProvenanceDoesNotChangeTheDefinitionOfReadyVerdict() throws {
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(goodDraftJSON).first)
        var withParent = draft
        withParent.from = "some-parent"
        XCTAssertEqual(
            DefinitionOfReady.evaluate(item: withParent.item(status: .ready), detail: withParent.detail).isReady,
            DefinitionOfReady.evaluate(item: draft.item(status: .ready), detail: draft.detail).isReady
        )
        XCTAssertTrue(DefinitionOfReady.evaluate(item: withParent.item(status: .ready),
                                                 detail: withParent.detail).isReady)
    }

    // MARK: - Sequencing

    /// The pass that splits an item into ordered pieces is the only thing that
    /// knows the order, so the second piece has to be able to say it — and the
    /// saying has to survive onto the line, which is where the pickup gate reads
    /// it.
    func testADraftThatStatesASequenceIsWithheldUntilItsPrerequisiteIsDone() throws {
        let json = """
        {"items":[{"id":"second-half","title":"The half that builds on the first","size":"S",
          "verify":"make","what":"w","how":"h","validation":["v"],"needs":["first-half"]}]}
        """
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(json).first)
        XCTAssertEqual(draft.needs, ["first-half"])

        let line = BacklogSerializer.serializeItem(draft.item(status: .ready))
        XCTAssertTrue(line.contains("needs:first-half"), line)
        let filed = try XCTUnwrap(BacklogParser.parseItemLine(line, verifyDefault: nil))
        XCTAssertEqual(filed.needs, ["first-half"])

        func verdict(prerequisite: BacklogItemStatus) -> DefinitionOfReady.Verdict {
            let first = BacklogItem(id: "first-half", title: "The first half", verify: "make",
                                    status: prerequisite, type: .local, size: .s)
            return DefinitionOfReady.evaluate(
                item: filed, detail: draft.detail,
                dependencies: DefinitionOfReady.Dependencies(items: [first, filed]))
        }
        XCTAssertFalse(verdict(prerequisite: .ready).isReady,
                       "the second half must wait for the first, not race it")
        XCTAssertTrue(verdict(prerequisite: .done).isReady, verdict(prerequisite: .done).summary)

        // The grooming gate judges a draft before its prerequisite could possibly
        // be done, and supplies no `Dependencies` for exactly that reason. Stating
        // a sequence must not be what parks the item.
        XCTAssertTrue(DefinitionOfReady.evaluate(item: filed, detail: draft.detail).isReady,
                      "a correctly sequenced draft must not be parked at grooming")
    }

    /// The fields on a line are split on `" | "`, so an id carrying one would
    /// truncate the line into nonsense. It is dropped on its own account: the
    /// draft is still worth filing, and its other prerequisites still hold.
    func testANeedsEntryTheLineCannotCarryIsDroppedAndTheRestStillFiles() throws {
        let json = """
        {"items":[{"id":"child","title":"Waits on two of three","size":"S","verify":"make",
          "what":"w","how":"h","validation":["v"],
          "needs":["  PROJ-1 ","broken | ready","also\\nbroken","second"]}]}
        """
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(json).first)
        XCTAssertEqual(draft.needs, ["PROJ-1", "second"],
                       "an existing id must not be slugged, and an unusable one must not take the draft with it")
        let line = BacklogSerializer.serializeItem(draft.item(status: .ready))
        XCTAssertEqual(BacklogParser.parseItemLine(line, verifyDefault: nil)?.needs, ["PROJ-1", "second"])
    }

    /// A draft carrying only what `resolveDependencies` reads: an id and what it
    /// needs. Everything else is a constant that satisfies the
    /// Definition-of-Ready without describing anything about the case.
    private func draft(id: String, needs: [String] = []) -> QueueRefill.Draft {
        QueueRefill.Draft(id: id, title: "Item \(id)", size: "S", verify: "make",
                          what: "w", how: "h", validation: ["v"], outOfScope: [], needs: needs)
    }

    /// Two drafts in one pass naming each other would file as `ready` on both
    /// ends — `gate` evaluates the Definition-of-Ready without dependencies on
    /// purpose — and then read as `dependency cycle` at every pickup for ever,
    /// the same never-runs failure an unresolvable id already gets dropped for.
    func testTwoDraftsNamingEachOtherHaveTheirLoopBroken() throws {
        let a = draft(id: "a", needs: ["b"])
        let b = draft(id: "b", needs: ["a"])

        let drafted = QueueRefill.resolveDependencies([a, b], existingIDs: [])

        let items = drafted.map { $0.draft.item(status: .ready) }
        let dependencies = DefinitionOfReady.Dependencies(items: items)
        for item in items {
            let unmet = dependencies.unmet(for: item)
            XCTAssertFalse(unmet.contains { $0.contains("dependency cycle") },
                           "\(item.id): \(unmet)")
        }
        // Breaking the loop needs only one of the two edges gone.
        let remaining = drafted.flatMap { $0.draft.needs }
        XCTAssertEqual(remaining.count, 1)
        let dropped = try XCTUnwrap(drafted.first { !$0.notes.isEmpty })
        XCTAssertTrue(dropped.notes[0].hasPrefix("dropped needs:"), dropped.notes[0])
        XCTAssertTrue(dropped.notes[0].contains("dependency cycle"), dropped.notes[0])
    }

    /// The self-reference case is the same loop with zero steps between —
    /// `cycleBack` finds it on the first pop of its queue rather than needing a
    /// special case.
    func testADraftNamingItsOwnIdHasThatIdDropped() {
        let a = draft(id: "a", needs: ["a"])

        let drafted = QueueRefill.resolveDependencies([a], existingIDs: [])

        XCTAssertEqual(drafted.first?.draft.needs, [])
        let notes = drafted.first?.notes ?? []
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].hasPrefix("dropped needs:a —"), notes[0])
        XCTAssertTrue(notes[0].contains("dependency cycle"), notes[0])
    }

    /// A legitimate chain — one draft naming another that names nothing — is not
    /// a cycle, and must not be mistaken for one.
    func testALegitimateChainKeepsItsNeedsAndGainsNoNote() throws {
        let a = draft(id: "a", needs: ["b"])
        let b = draft(id: "b")

        let drafted = QueueRefill.resolveDependencies([a, b], existingIDs: [])

        let resolvedA = try XCTUnwrap(drafted.first { $0.draft.id == "a" })
        XCTAssertEqual(resolvedA.draft.needs, ["b"])
        XCTAssertTrue(resolvedA.notes.isEmpty)
        let resolvedB = try XCTUnwrap(drafted.first { $0.draft.id == "b" })
        XCTAssertTrue(resolvedB.notes.isEmpty)
    }

    /// Most drafts wait for nothing, and their line has to read exactly as it did
    /// before sequencing was expressible — an empty token is a token.
    func testADraftWithNoStatedSequenceWritesNoNeedsToken() throws {
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(goodDraftJSON).first)
        XCTAssertTrue(draft.needs.isEmpty)
        let line = BacklogSerializer.serializeItem(draft.item(status: .ready))
        XCTAssertFalse(line.contains("needs:"), line)
        XCTAssertTrue(DefinitionOfReady.evaluate(
            item: draft.item(status: .ready), detail: draft.detail,
            dependencies: DefinitionOfReady.Dependencies(items: [draft.item(status: .ready)])).isReady)
    }

    // MARK: - Bounding the total filed

    /// A candidate's own fields don't matter to `boundedDrafts` — only which
    /// list it came from and how many there are — so a bare id is enough.
    private func drafted(_ id: String) -> QueueRefill.Drafted {
        QueueRefill.Drafted(draft: draft(id: id))
    }

    /// Signal and model drafts together already fit under the limit: nothing
    /// is trimmed, and the signal drafts still lead.
    func testNothingIsTrimmedWhenTheTotalFitsUnderTheLimit() {
        let signal = [drafted("s1")]
        let model = [drafted("m1"), drafted("m2")]

        let bounded = QueueRefill.boundedDrafts(signal: signal, model: model, limit: 5)

        XCTAssertEqual(bounded.drafts.map(\.draft.id), ["s1", "m1", "m2"])
        XCTAssertEqual(bounded.leftoverSignal, 0)
    }

    /// The model's own drafts already reach the limit — `draft(target:…)`
    /// caps them at `target.count`, so this is the case where the shortfall is
    /// entirely spoken for before a single finding is considered. No signal
    /// draft is filed, and every one of them is left over rather than
    /// silently dropped.
    func testEverySignalDraftIsTrimmedWhenTheModelAloneAlreadyFillsTheLimit() {
        let signal = [drafted("s1"), drafted("s2"), drafted("s3")]
        let model = [drafted("m1"), drafted("m2")]

        let bounded = QueueRefill.boundedDrafts(signal: signal, model: model, limit: 2)

        XCTAssertEqual(bounded.drafts.map(\.draft.id), ["m1", "m2"])
        XCTAssertEqual(bounded.leftoverSignal, 3)
    }

    /// More approval-ledger reopens than the shortfall: the signal findings
    /// alone would overrun `limit`, so only enough of them to reach it are
    /// kept, still ahead of the model's own drafts, and the rest are counted
    /// as left over for the next pass.
    func testExcessSignalDraftsAreTrimmedFromTheirOwnEndKeepingTheEarliestOnes() {
        let signal = [drafted("s1"), drafted("s2"), drafted("s3"), drafted("s4")]
        let model = [drafted("m1")]

        let bounded = QueueRefill.boundedDrafts(signal: signal, model: model, limit: 3)

        XCTAssertEqual(bounded.drafts.map(\.draft.id), ["s1", "s2", "m1"])
        XCTAssertEqual(bounded.leftoverSignal, 2)
    }

    /// No signal findings at all: a pass files exactly what it filed before
    /// this bound existed.
    func testNoSignalFindingsFilesExactlyTheModelsOwnDrafts() {
        let model = [drafted("m1"), drafted("m2")]

        let bounded = QueueRefill.boundedDrafts(signal: [], model: model, limit: 3)

        XCTAssertEqual(bounded.drafts.map(\.draft.id), ["m1", "m2"])
        XCTAssertEqual(bounded.leftoverSignal, 0)
    }

    func testUniqueIDAvoidsCollidingWithWhatIsAlreadyThere() {
        XCTAssertEqual(QueueRefill.Draft.uniqueID("cache", taken: []), "cache")
        XCTAssertEqual(QueueRefill.Draft.uniqueID("cache", taken: ["cache"]), "cache-2")
        XCTAssertEqual(QueueRefill.Draft.uniqueID("cache", taken: ["cache", "cache-2"]), "cache-3")
    }

    func testADraftPassesTheDefinitionOfReadyItWasBuiltToSatisfy() throws {
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(goodDraftJSON).first)
        let verdict = DefinitionOfReady.evaluate(item: draft.item(status: .ready), detail: draft.detail)
        XCTAssertTrue(verdict.isReady, verdict.summary)
    }

    func testDetailMarkdownRoundTripsThroughTheBacklogParser() throws {
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(goodDraftJSON).first)
        let parsed = try XCTUnwrap(BacklogParser.parseDetail(draft.detailMarkdown()))
        XCTAssertEqual(parsed.id, "cache-the-index")
        XCTAssertEqual(parsed.what?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "The index is built once per run.")
        XCTAssertEqual(parsed.approach?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Hold it on the autopilot.")
        XCTAssertEqual(parsed.acceptanceCriteria, ["A queue of five items builds the index once"])
        XCTAssertEqual(parsed.outOfScope, ["Persisting the index across launches"])
        // The verify command reaches the run through the backlog *line*, which is
        // where `fileGroomedItem` writes it and where `DefinitionOfReady` falls
        // back to. (The frontmatter block is written for a human to read; the
        // parser's frontmatter reader does not currently pick a `verify:` list
        // up — a pre-existing gap, not something this loop relies on.)
        XCTAssertEqual(draft.item(status: .ready).verify, "xcodebuild -scheme Kiteloop build")
        XCTAssertTrue(DefinitionOfReady.evaluate(item: draft.item(status: .ready), detail: parsed).isReady)
    }

    func testGatingNotesLandInTheDetailFileSoTheDraftSaysWhyItIsParked() throws {
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(goodDraftJSON).first)
        let markdown = draft.detailMarkdown(notes: ["grounding check failed: cites `Nope`"])
        XCTAssertTrue(markdown.contains("## Notes"))
        XCTAssertTrue(markdown.contains("grounding check failed: cites `Nope`"))
    }

    func testDraftWithATitleContainingAColonStillParses() throws {
        let json = """
        {"items":[{"id":"a","title":"Coordinator: refill the queue","size":"S","verify":"make",
          "what":"w","how":"h","validation":["v"]}]}
        """
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(json).first)
        let parsed = try XCTUnwrap(BacklogParser.parseDetail(draft.detailMarkdown()))
        XCTAssertEqual(parsed.title, "Coordinator: refill the queue")
    }

    // MARK: - The gates a drafted item faces

    func testAnUngroundedDraftFailsTheGroundingCheck() throws {
        let json = """
        {"items":[{"id":"a","title":"Fix it","size":"S","verify":"/bin/echo ok",
          "what":"Update `Services/NotAFile.swift` to do the thing.","how":"Edit it.",
          "validation":["It does the thing"]}]}
        """
        let draft = try XCTUnwrap(QueueRefill.Draft.parse(json).first)
        let sources = GroundingCheck.Sources(pathExists: { _ in false },
                                             definesSymbol: { _ in false },
                                             resolvesExecutable: { _ in true })
        let verdict = GroundingCheck.evaluate(item: draft.item(status: .ready),
                                              detail: draft.detail, sources: sources)
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertTrue(verdict.summary.contains("NotAFile.swift"), verdict.summary)
    }

    // MARK: - Prompt

    @MainActor
    func testPromptStatesTheBoundAndWhatMustNotBeProposedAgain() {
        let backlog = BacklogFile(project: "alpha", repo: nil, verifyDefault: nil, sections: [
            BacklogSection(name: "Now", items: [
                BacklogItem(id: "open-one", title: "Still open", verify: nil, status: .ready, type: .local),
                BacklogItem(id: "finished", title: "Long done", verify: nil, status: .done, type: .local)
            ])
        ])
        let prompt = CoordinatorQueueRefill.buildPrompt(
            target: QueueRefill.Target(project: "alpha", path: "/tmp/alpha", readyCount: 1, count: 3),
            backlog: backlog,
            goal: "Ship the coordinator",
            alreadyGroomed: ["cache-the-index"],
            repoKnowledge: nil
        )
        XCTAssertTrue(prompt.contains("Write 3 item(s)"))
        XCTAssertTrue(prompt.contains("Stop at 3"), "the bound has to be stated, not implied")
        XCTAssertTrue(prompt.contains("Ship the coordinator"))
        XCTAssertTrue(prompt.contains("open-one"))
        XCTAssertFalse(prompt.contains("finished"), "done work is not a duplicate risk")
        XCTAssertTrue(prompt.contains("cache-the-index"))
        XCTAssertTrue(prompt.contains("never propose these again"))
    }

    /// The prompt used to say "3 ready item(s)" for a queue where none of the
    /// three could start — a bare ready count that reads as depth when it is
    /// really a stall. Once the target carries a startable figure that
    /// disagrees, the prompt has to say so.
    @MainActor
    func testPromptSaysWhenTheReadyCountCannotStart() {
        let prompt = CoordinatorQueueRefill.buildPrompt(
            target: QueueRefill.Target(project: "alpha", path: "/tmp/alpha",
                                       readyCount: 3, startableCount: 0, count: 3),
            backlog: BacklogFile(project: "alpha", repo: nil, verifyDefault: nil, sections: []),
            goal: nil, alreadyGroomed: [], repoKnowledge: nil
        )

        XCTAssertTrue(prompt.contains("3 ready item(s)"))
        XCTAssertTrue(prompt.contains("only 0"), prompt)
        XCTAssertFalse(prompt.contains("3 ready item(s) — below the threshold"),
                       "a bare ready count is exactly what a stalled queue must not be described as")
    }

    /// When the two figures agree — or the snapshot never carried a startable
    /// figure at all — the prompt keeps the plain sentence it always had.
    @MainActor
    func testPromptStaysPlainWhenReadyAndStartableAgree() {
        let prompt = CoordinatorQueueRefill.buildPrompt(
            target: QueueRefill.Target(project: "alpha", path: "/tmp/alpha",
                                       readyCount: 1, count: 3),
            backlog: BacklogFile(project: "alpha", repo: nil, verifyDefault: nil, sections: []),
            goal: nil, alreadyGroomed: [], repoKnowledge: nil
        )

        XCTAssertTrue(prompt.contains("1 ready item(s) — below the threshold"))
        XCTAssertFalse(prompt.contains("only"))
    }

    /// The prompt used to carry only the newest 30 filings while the acceptance
    /// filter refused a candidate against all of them, so a drafter that
    /// re-proposed an older idea had it dropped and the pass came up short.
    @MainActor
    func testThePromptListsFilingsOlderThanTheNewestThirty() throws {
        var ledger = QueueRefill.Ledger()
        for index in 1...40 {
            ledger.record(project: "alpha", id: "alpha-\(index)",
                          title: "Alpha item \(index)", disposition: .ready, at: now)
        }

        let prompt = CoordinatorQueueRefill.buildPrompt(
            target: QueueRefill.Target(project: "alpha", path: "/tmp/alpha", readyCount: 1, count: 3),
            backlog: BacklogFile(project: "alpha", repo: nil, verifyDefault: nil, sections: []),
            goal: nil,
            alreadyGroomed: ledger.filedIDsInOrder(project: "alpha"),
            repoKnowledge: nil
        )

        let groomed = try XCTUnwrap(prompt.components(
            separatedBy: "## Already groomed by you for this project").last)
        // alpha-10 is the 31st filing counting back from the newest — outside the
        // window the prompt used to stop at, so the drafter was never shown it
        // and had it dropped anyway when it proposed it again.
        XCTAssertTrue(groomed.contains("- alpha-10\n"),
                      "a filing 31 back is still a constraint the drafter is judged by")
        XCTAssertTrue(groomed.contains("- alpha-1\n"), "the very first filing too")
        XCTAssertTrue(groomed.contains("- alpha-40"))
    }

    /// The same defect as the filings list, on the other section: the prompt
    /// listed only the first 40 open items while nothing downstream refuses a
    /// duplicate of the ones it hid — `uniqueID(_:taken:)` renames a colliding
    /// id to `<id>-2` and the ledger never saw a human-written item at all.
    @MainActor
    func testThePromptListsOpenItemsPastTheFortiethOne() throws {
        let items = (1...60).map {
            BacklogItem(id: "alpha-\($0)", title: "Alpha item \($0)",
                        verify: nil, status: .ready, type: .local)
        }
        let prompt = CoordinatorQueueRefill.buildPrompt(
            target: QueueRefill.Target(project: "alpha", path: "/tmp/alpha", readyCount: 1, count: 3),
            backlog: BacklogFile(project: "alpha", repo: nil, verifyDefault: nil,
                                 sections: [BacklogSection(name: "Now", items: items)]),
            goal: nil,
            alreadyGroomed: [],
            repoKnowledge: nil
        )

        let listed = try XCTUnwrap(prompt.components(
            separatedBy: "## Already in the backlog").last)
        // alpha-41 is the first one the cap used to drop.
        XCTAssertTrue(listed.contains("- alpha-41 [ready] Alpha item 41"),
                      "the 41st open item is as much of a duplicate risk as the 40th")
        XCTAssertTrue(listed.contains("- alpha-60 [ready] Alpha item 60"))
        for index in 1...60 {
            XCTAssertTrue(listed.contains("- alpha-\(index) ["), "alpha-\(index) is missing")
        }
    }

    @MainActor
    func testDrafterContractDemandsEverythingTheDefinitionOfReadyChecks() {
        let contract = CoordinatorQueueRefill.drafterContract
        for clause in ["What", "How", "Validation", "verify", "size", "outOfScope"] {
            XCTAssertTrue(contract.contains(clause), "the contract omits \(clause)")
        }
        XCTAssertTrue(contract.contains("READ the code"), "grounding is the drafter's job, not just the check's")
    }

    /// The drafter is the only thing that knows an item was split out of another
    /// one, so the contract has to ask for it — and has to say it changes nothing
    /// about when the item runs, or it will be filled in defensively.
    @MainActor
    func testDrafterContractAsksWhereASplitItemCameFrom() {
        let contract = CoordinatorQueueRefill.drafterContract
        XCTAssertTrue(contract.contains("\"from\""), "the JSON shape omits from")
        // The prose is hard-wrapped, so a phrase is matched against a re-flowed
        // rendering of it — asserting on the literal's line breaks would fail on
        // a rewrap that changed nothing the drafter reads.
        let flowed = contract.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flowed.contains("splitting an existing item"), contract)
        XCTAssertTrue(flowed.contains("never blocks the item"),
                      "the contract has to say from changes nothing, or it gets filled in defensively")
    }

    /// A pass that splits an item can only order the pieces if the contract says
    /// the field exists — and has to distinguish it from `from`, which looks the
    /// same and does nothing.
    @MainActor
    func testDrafterContractOffersAWayToSayWhatAnItemWaitsFor() {
        let contract = CoordinatorQueueRefill.drafterContract
        XCTAssertTrue(contract.contains("\"needs\""), "the JSON shape omits needs")
        let flowed = contract.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flowed.contains("withheld at pickup until every id it names is done"), contract)
    }
}
