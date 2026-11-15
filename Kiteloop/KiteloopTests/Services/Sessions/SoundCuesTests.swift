import XCTest
import SwiftUI
import UserNotifications
import KiteloopCore
@testable import Kiteloop

/// Kiteloop's sounds: that the app carries each one, what a banner is given
/// under each theme, and what Settings says about the choice.
@MainActor
final class SoundCuesTests: XCTestCase {
    func testTheAppCarriesASoundForEveryCue() {
        for cue in SoundCue.allCases {
            let sound = SoundCues.bundledSound(for: cue)
            XCTAssertNotNil(sound, "\(cue.fileName) is not in the app bundle")
            XCTAssertGreaterThan(sound?.duration ?? 0, 0.3, "\(cue.fileName) did not load as audio")
            XCTAssertLessThan(sound?.duration ?? 9, 1.5, "\(cue.fileName) is longer than a cue should be")
        }
    }

    func testABannerUnderKiteloopsThemeNamesTheCuesOwnSound() {
        for cue in SoundCue.allCases {
            let sound = SoundCues.notificationSound(for: cue, theme: .soft)
            XCTAssertEqual(sound, UNNotificationSound(named: UNNotificationSoundName(cue.fileName)))
            XCTAssertNotEqual(sound, UNNotificationSound.default)
        }
    }

    func testABannerUnderTheSystemThemeKeepsTheSystemsSounds() {
        XCTAssertEqual(SoundCues.notificationSound(for: .finished, theme: .system), UNNotificationSound.default)
        XCTAssertEqual(SoundCues.notificationSound(for: .needsYou, theme: .system), UNNotificationSound.default)
        XCTAssertEqual(SoundCues.notificationSound(for: .failed, theme: .system), UNNotificationSound.defaultCritical)
    }

    func testABannerWithSoundsOffCarriesNone() {
        for cue in SoundCue.allCases {
            XCTAssertNil(SoundCues.notificationSound(for: cue, theme: .silent))
        }
    }

    func testBannerContentCarriesTheSoundItIsGivenAndNoneOtherwise() {
        let quiet = NotificationService.bannerContent(title: "t", body: "b", badge: 1, destination: nil)
        XCTAssertNil(quiet.sound)

        let sound = SoundCues.notificationSound(for: .needsYou, theme: .soft)
        let loud = NotificationService.bannerContent(title: "t", body: "b", badge: 1, destination: nil, sound: sound)
        XCTAssertEqual(loud.sound, sound)
    }

    func testSettingsSaysWhatEachChoiceDoes() {
        XCTAssertTrue(SoundSettingsSection.explanation(for: .soft).hasPrefix("Kiteloop's own short, quiet sounds"))
        XCTAssertTrue(SoundSettingsSection.explanation(for: .system).hasPrefix("The macOS alert sound"))
        XCTAssertTrue(SoundSettingsSection.explanation(for: .silent).hasPrefix("Banners and finished turns make no sound"))
    }

    func testTheSoundsSectionDraws() {
        let host = NSHostingView(rootView: Form { SoundSettingsSection() }.frame(width: 500, height: 300))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
