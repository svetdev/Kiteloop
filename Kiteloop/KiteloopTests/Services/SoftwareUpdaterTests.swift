import KiteloopCore
import KiteloopTestSupport
import SwiftUI
import XCTest
@testable import Kiteloop

/// The half of `SoftwareUpdater` that is the app's own: which copies update
/// themselves, and what one that does not looks like to the menu and the
/// preferences. The updating itself is Sparkle's, and is exercised against a
/// real feed (docs/release-runbook.md), not here.
@MainActor
final class SoftwareUpdaterTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        suiteName = "software-updater-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testATestHostIsNotACopyThatUpdatesItself() {
        XCTAssertFalse(SoftwareUpdater.updatesThisCopy)
    }

    func testACopyThatDoesNotUpdateItselfOffersNothingToCheckOrSwitch() {
        let updater = SoftwareUpdater(updatesThisCopy: false, defaults: defaults)

        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertFalse(updater.isAvailable)
        updater.checkForUpdates()
        XCTAssertFalse(updater.canCheckForUpdates, "asking a copy with no updater starts nothing")
    }

    /// The real Sparkle updater, built and never started: it schedules nothing
    /// and asks the network nothing, and its settings are only read here — a
    /// test host shares the app's defaults, so writing one would change the
    /// machine's own preference.
    func testACopyThatUpdatesItselfHasAnUpdaterToSwitchAndWaitsForItToStart() {
        let updater = SoftwareUpdater(updatesThisCopy: true, startsUpdater: false, defaults: defaults)

        XCTAssertTrue(updater.isAvailable)
        XCTAssertFalse(updater.canCheckForUpdates, "an updater that has not started has nothing to check with")
    }

    func testThePreferenceRowsDrawForACopyWithAnUpdaterAndForOneWithout() async throws {
        for updatesThisCopy in [true, false] {
            let updater = SoftwareUpdater(updatesThisCopy: updatesThisCopy, startsUpdater: false,
                                          defaults: defaults)
            let host = NSHostingView(rootView: Form { UpdatePreferenceRows(updater: updater) })
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()

            try await eventually("the rows are laid out") { host.fittingSize.height > 0 }
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }

    func testTheOldCheckSettingsAreRetiredEvenInACopyThatDoesNotUpdateItself() {
        defaults.set(false, forKey: LegacyUpdatePreferences.automaticCheckKey)

        _ = SoftwareUpdater(updatesThisCopy: false, defaults: defaults)

        XCTAssertNil(defaults.object(forKey: LegacyUpdatePreferences.automaticCheckKey))
    }
}
