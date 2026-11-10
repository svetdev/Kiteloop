import XCTest
@testable import KiteloopCore

final class LegacyUpdatePreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        suiteName = "legacy-update-preferences-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testAChoiceToStopCheckingIsHandedBackOnceAndItsKeyRemoved() {
        defaults.set(false, forKey: LegacyUpdatePreferences.automaticCheckKey)

        XCTAssertEqual(LegacyUpdatePreferences.retire(from: defaults), false)
        XCTAssertNil(defaults.object(forKey: LegacyUpdatePreferences.automaticCheckKey))
        XCTAssertNil(LegacyUpdatePreferences.retire(from: defaults),
                     "a second launch has nothing left to carry across")
    }

    func testAnInstallThatNeverTouchedTheToggleHasNoChoiceToCarry() {
        XCTAssertNil(LegacyUpdatePreferences.retire(from: defaults))
    }

    func testTheDaysAllowanceAndTheSkippedReleaseAreRemovedToo() {
        defaults.set(true, forKey: LegacyUpdatePreferences.automaticCheckKey)
        defaults.set(Date(), forKey: "updateCheckLastAnswered")
        defaults.set("v0.4.9", forKey: "updateCheckSkippedVersion")

        XCTAssertEqual(LegacyUpdatePreferences.retire(from: defaults), true)
        for key in LegacyUpdatePreferences.retiredKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }
}
