import XCTest
@testable import KiteloopCore

final class SoundCueTests: XCTestCase {
    func testAnUnsetOrUnknownChoiceIsKiteloopsOwnSounds() {
        XCTAssertEqual(SoundTheme(stored: nil), .soft)
        XCTAssertEqual(SoundTheme(stored: "loud"), .soft)
        XCTAssertEqual(SoundTheme(stored: "system"), .system)
        XCTAssertEqual(SoundTheme(stored: "silent"), .silent)
    }

    func testKiteloopsOwnThemePlaysEachCuesOwnFile() {
        XCTAssertEqual(SoundTheme.soft.bannerSound(for: .finished), .file("kiteloop-finished.wav"))
        XCTAssertEqual(SoundTheme.soft.bannerSound(for: .needsYou), .file("kiteloop-needs-you.wav"))
        XCTAssertEqual(SoundTheme.soft.bannerSound(for: .failed), .file("kiteloop-failed.wav"))
    }

    func testTheSystemThemeKeepsTheCriticalSoundForAStoppedAgent() {
        XCTAssertEqual(SoundTheme.system.bannerSound(for: .finished), .systemDefault)
        XCTAssertEqual(SoundTheme.system.bannerSound(for: .needsYou), .systemDefault)
        XCTAssertEqual(SoundTheme.system.bannerSound(for: .failed), .systemCritical)
    }

    func testOffMakesNoSoundForAnyCue() {
        for cue in SoundCue.allCases {
            XCTAssertEqual(SoundTheme.silent.bannerSound(for: cue), SoundTheme.BannerSound.none)
        }
    }

    func testEveryCueAndThemeHasAName() {
        XCTAssertEqual(SoundCue.allCases.map(\.label), ["Agent finished", "Needs you", "Agent stopped"])
        XCTAssertEqual(SoundTheme.allCases.map(\.label), ["Kiteloop", "System", "Off"])
    }
}
