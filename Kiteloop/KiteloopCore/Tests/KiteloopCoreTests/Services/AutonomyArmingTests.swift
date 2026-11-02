import XCTest
@testable import KiteloopCore

/// The arming gate: switching unattended work or grooming on needs the ceiling
/// it will spend against. A missing budget is refused, naming what has to be
/// set first; a budget that is set arms. Off-by-default is only half the
/// principle, and this is the other half.
final class AutonomyArmingTests: XCTestCase {

    // MARK: - Scheduling

    func testSchedulingIsRefusedWithoutADailyBudget() throws {
        let refusal = try XCTUnwrap(AutonomyArming.armScheduling(dailyBudgetUSD: nil),
                                    "arming against no ceiling must be refused")

        XCTAssertEqual(refusal.missing, "daily autonomy budget")
        XCTAssertTrue(refusal.message.contains("unattended runs"), "got \(refusal.message)")
    }

    func testSchedulingArmsOnceADailyBudgetIsSet() {
        XCTAssertNil(AutonomyArming.armScheduling(dailyBudgetUSD: 200))
    }

    // MARK: - Grooming

    func testGroomingIsRefusedWithoutADailyBudget() throws {
        let refusal = try XCTUnwrap(AutonomyArming.armGrooming(dailyBudgetUSD: nil),
                                    "arming against no ceiling must be refused")

        XCTAssertEqual(refusal.missing, "daily autonomy budget")
        XCTAssertTrue(refusal.message.contains("grooming"), "got \(refusal.message)")
    }

    func testGroomingArmsOnceADailyBudgetIsSet() {
        XCTAssertNil(AutonomyArming.armGrooming(dailyBudgetUSD: 200))
    }
}
