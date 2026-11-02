import XCTest
@testable import Kiteloop
import KiteloopCore

/// The participation filter, and the panel's wiring to the arming gate: a
/// project with a worker and reviewer is *able* to run, and only its own
/// opt-in makes the scheduler or the grooming loop touch it. The gate itself —
/// refusing to arm unattended work or grooming without a daily budget — is
/// asserted once, in `KiteloopCoreTests`; this file only checks that the panel
/// reads the gate's own sentence rather than keeping a copy.
final class AutonomyArmingTests: XCTestCase {

    // MARK: - The panel's wiring to the gate

    /// The panel's caption and the API's 422 must be the same sentence — the
    /// panel model reads the gate rather than keeping its own copy.
    func testThePanelShowsTheGatesOwnSentence() {
        let controls = CoordinatorPanelModel.Controls(
            refillWired: true, schedulerWired: true, storeWired: true,
            runningBudgetUSD: nil, schedulingEnabled: false,
            refillEnabled: false)
        XCTAssertEqual(controls.schedulingDisabledReason,
                       AutonomyArming.armScheduling(dailyBudgetUSD: nil)?.message)
        XCTAssertEqual(controls.groomingSwitchDisabledReason,
                       AutonomyArming.armGrooming(dailyBudgetUSD: nil)?.message)
    }

    /// Already-on always accepts input: the rule guards the way in, never the
    /// way out.
    func testAnArmedSwitchStaysOperableWithoutABudget() {
        let controls = CoordinatorPanelModel.Controls(
            refillWired: true, schedulerWired: true, storeWired: true,
            runningBudgetUSD: nil, schedulingEnabled: true,
            refillEnabled: true)
        XCTAssertTrue(controls.isSchedulingSwitchOperable)
        XCTAssertTrue(controls.isGroomingSwitchOperable)
        XCTAssertNil(controls.schedulingDisabledReason)
        XCTAssertNil(controls.groomingSwitchDisabledReason)
    }

    // MARK: - The participation filter

    private func project(_ name: String, ready: Int = 2,
                         optedIn: Bool) -> PortfolioSnapshot.Project {
        let items = (0..<ready).map {
            PortfolioSnapshot.Item(id: "\(name)-\($0)", title: "Item \($0)", size: "S", lastRun: nil)
        }
        return PortfolioSnapshot.Project(
            name: name,
            path: "/tmp/\(name)",
            autopilotReady: true,
            autonomousWorkEnabled: optedIn,
            statusCounts: ready > 0 ? [.ready: ready] : [:],
            readyItems: PortfolioSnapshot.ItemSample(items: items, omitted: 0),
            run: nil,
            recentOutcomes: [],
            paused: false,
            goal: nil)
    }

    private func decide(_ projects: [PortfolioSnapshot.Project]) -> RunScheduling.Decision {
        RunScheduling.decide(portfolio: PortfolioSnapshot(projects: projects),
                             enabled: true,
                             budget: DailyBudget(budgetUSD: 20, spentUSD: 1))
    }

    func testSchedulerHoldsWhenNoProjectOptedIn() {
        let decision = decide([project("alpha", optedIn: false),
                               project("beta", optedIn: false)])
        XCTAssertEqual(decision.hold, .noProjectOptedIn)
    }

    func testSchedulerStartsOnlyForAnOptedInProject() {
        let decision = decide([project("alpha", optedIn: false),
                               project("beta", optedIn: true)])
        XCTAssertEqual(decision.target?.project, "beta")
    }

    func testRefillHoldsWhenNoProjectOptedIn() {
        let portfolio = PortfolioSnapshot(projects: [project("alpha", ready: 0, optedIn: false)])
        let decision = QueueRefill.decidePass(portfolio: portfolio)
        XCTAssertEqual(decision, .hold(.noProjectOptedIn))
    }

    func testRefillServesOnlyOptedInProjects() {
        let portfolio = PortfolioSnapshot(projects: [project("alpha", ready: 0, optedIn: false),
                                                    project("beta", ready: 0, optedIn: true)])
        guard case .refill(let targets) = QueueRefill.decidePass(portfolio: portfolio) else {
            return XCTFail("expected a refill")
        }
        XCTAssertEqual(targets.map(\.project), ["beta"])
    }
}
