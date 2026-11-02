import XCTest
import KiteloopCore
@testable import Kiteloop

/// Project Settings → General → Budget, and what a typo in it used to cost.
///
/// The field's text went to the config as `Double(maxBudgetUSD)`, and the
/// runtime only passes a budget through when it is greater than zero. So
/// `abc`, `1,50` and `-5` all meant the same thing as an empty field —
/// unlimited — and the sheet said nothing, because a successful write clears
/// `saveError`. One stray keystroke removed the project's per-turn cap.
///
/// `ProjectSettingsView.parseBudget(_:)` is where that judgement now lives: a
/// pure static, so these drive it with no window and no project on disk.
final class ProjectSettingsBudgetTests: XCTestCase {

    // MARK: - Text that is not an amount stores nothing

    /// The case the report named: the cap must survive the typo, so the parser
    /// has to answer something other than "unlimited".
    func testLettersAreInvalid() {
        XCTAssertEqual(ProjectSettingsView.parseBudget("abc"), .invalid)
        XCTAssertNil(ProjectSettingsView.parseBudget("abc").storedValue,
                     "An invalid entry writes nothing, so the stored cap is left alone")
    }

    /// A comma decimal separator is refused with a message rather than
    /// reinterpreted — the field is not locale-aware, and pretending it is
    /// would turn 1,50 into some other number.
    func testCommaDecimalSeparatorIsInvalid() {
        XCTAssertEqual(ProjectSettingsView.parseBudget("1,50"), .invalid)
    }

    /// A negative number parses as a Double but means unlimited once the
    /// runtime's `> 0` test sees it, so it is invalid here.
    func testNegativeAmountIsInvalid() {
        XCTAssertEqual(ProjectSettingsView.parseBudget("-5"), .invalid)
        XCTAssertEqual(ProjectSettingsView.parseBudget("0"), .invalid)
    }

    // MARK: - Empty stays unlimited

    /// Clearing the field is how a project says "no cap", and that is unchanged.
    func testEmptyIsUnlimited() {
        XCTAssertEqual(ProjectSettingsView.parseBudget(""), .unlimited)
        XCTAssertEqual(ProjectSettingsView.parseBudget("   "), .unlimited)
        XCTAssertNil(ProjectSettingsView.parseBudget("").storedValue)
    }

    // MARK: - A real amount is stored

    /// The ordinary path: what a person types is what the config keeps.
    func testValidAmountIsStored() {
        XCTAssertEqual(ProjectSettingsView.parseBudget("2.50"), .amount(2.5))
        XCTAssertEqual(ProjectSettingsView.parseBudget(" 2.50 ").storedValue, 2.5)
        XCTAssertEqual(ProjectSettingsView.parseBudget("10").storedValue, 10)
    }

    // MARK: - What a save writes

    /// A typo in Budget refuses the whole save with the sentence the page
    /// shows, so the cap already on disk is the one that stays.
    @MainActor
    func testATypoInBudgetRefusesTheSaveAndSaysWhy() {
        let result = ProjectSettingsView.editedConfig(
            stored(budget: 5), model: "opus", permissionMode: "default", effort: "", budgetText: "abc")

        guard case .failure(let refusal) = result else { return XCTFail("a typo must not save: \(result)") }
        XCTAssertTrue(refusal.message.contains("isn't a dollar amount"), refusal.message)
    }

    /// The page's four fields land over what the project already stores; an
    /// empty Model or Effort is Default, stored as nothing so the app's value
    /// wins; and nothing the page does not show is lost on the way.
    @MainActor
    func testASaveWritesThePageFieldsAndKeepsEverythingElse() throws {
        var base = stored(budget: 5)
        base.goal = "Ship the thing"
        base.paused = true

        let config = try ProjectSettingsView.editedConfig(
            base, model: "", permissionMode: "plan", effort: "high", budgetText: " 2.50 ").get()

        XCTAssertNil(config.model, "an empty Model is Default")
        XCTAssertEqual(config.permissionMode, "plan")
        XCTAssertEqual(config.effort, "high")
        XCTAssertEqual(config.maxBudgetUSD, 2.5)
        XCTAssertEqual(config.goal, "Ship the thing")
        XCTAssertEqual(config.paused, true)
    }

    /// Clearing the Budget field is how a project says "no cap".
    @MainActor
    func testAnEmptyBudgetSavesAsUnlimited() throws {
        let config = try ProjectSettingsView.editedConfig(
            stored(budget: 5), model: "sonnet", permissionMode: "default", effort: "", budgetText: "").get()

        XCTAssertNil(config.maxBudgetUSD)
        XCTAssertEqual(config.model, "sonnet")
        XCTAssertNil(config.effort, "an empty Effort is Default")
    }

    private func stored(budget: Double) -> ProjectConfig {
        var config = ProjectConfig.default
        config.model = "opus"
        config.maxBudgetUSD = budget
        return config
    }
}
