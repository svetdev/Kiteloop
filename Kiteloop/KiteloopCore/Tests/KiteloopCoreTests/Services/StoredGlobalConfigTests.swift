import XCTest
@testable import KiteloopCore

/// A config written before the coordinator's refill mode and its own budget
/// retired still carries both keys. It has to load, keep the bound the old
/// budget set, and stop carrying either key once it is saved.
final class StoredGlobalConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> StoredGlobalConfig {
        try JSONDecoder().decode(StoredGlobalConfig.self, from: Data(json.utf8))
    }

    func testBothRetiredKeysLoadAndTheLegacyBudgetBecomesTheDailyBudget() throws {
        let stored = try decode("""
        {"coordinatorRefillEnabled": true, "coordinatorRefillMode": "advisory",
         "coordinatorRefillDailyBudgetUSD": 12.5}
        """)

        XCTAssertEqual(stored.config.dailyBudgetUSD, 12.5)
        XCTAssertEqual(stored.config.coordinatorRefillEnabled, true)
        XCTAssertTrue(stored.carriedRetiredKeys)
    }

    func testAStoredDailyBudgetWinsOverTheLegacyOne() throws {
        let stored = try decode("""
        {"dailyBudgetUSD": 40, "coordinatorRefillDailyBudgetUSD": 12.5}
        """)

        XCTAssertEqual(stored.config.dailyBudgetUSD, 40)
    }

    func testANonPositiveLegacyBudgetSetsNoCeiling() throws {
        let stored = try decode(#"{"coordinatorRefillDailyBudgetUSD": 0}"#)

        XCTAssertNil(stored.config.dailyBudgetUSD)
        XCTAssertTrue(stored.carriedRetiredKeys)
    }

    func testAConfigWithoutRetiredKeysSaysSo() throws {
        let stored = try decode(#"{"dailyBudgetUSD": 40}"#)

        XCTAssertFalse(stored.carriedRetiredKeys)
    }

    func testTheNextSaveWritesNeitherKey() throws {
        let stored = try decode("""
        {"coordinatorRefillMode": "advisory", "coordinatorRefillDailyBudgetUSD": 12.5}
        """)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let saved = String(decoding: try encoder.encode(stored.config), as: UTF8.self)

        XCTAssertFalse(saved.contains("coordinatorRefillMode"))
        XCTAssertFalse(saved.contains("coordinatorRefillDailyBudgetUSD"))
        XCTAssertTrue(saved.contains("\"dailyBudgetUSD\" : 12.5"))
    }
}
