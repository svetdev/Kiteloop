import XCTest
@testable import KiteloopCore

/// `DayKey` exists so a day key means the same thing on every machine. The
/// test that matters is the hazard it removes: a `DateFormatter` with
/// `dateFormat = "yyyy-MM-dd"` and no `locale` reads `Locale.current`, and
/// under a Japanese-calendar region `yyyy` is the era year, not the Gregorian
/// one — the same instant would file under a different string depending on
/// who's reading it back.
final class DayKeyTests: XCTestCase {

    private static let fixedInstant: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 20
        components.hour = 12; components.minute = 0; components.second = 0
        return calendar.date(from: components)!
    }()

    func testDayKeyForFixedInstantInFixedTimeZone() {
        let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
        // 2026-08-20 12:00 UTC is still 2026-08-20 02:00 in Honolulu.
        XCTAssertEqual(DayKey.string(for: Self.fixedInstant, timeZone: honolulu), "2026-08-20")

        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-08-20 12:00 UTC is already 2026-08-20 21:00 in Tokyo — same day,
        // different offset, exercising the rollover math either way.
        XCTAssertEqual(DayKey.string(for: Self.fixedInstant, timeZone: tokyo), "2026-08-20")
    }

    /// The hazard `DayKey` removes: a `DateFormatter` reading a Japanese-era
    /// locale disagrees with the Gregorian key for the same instant.
    func testJapaneseCalendarDateFormatterDisagreesWithDayKey() {
        let key = DayKey.string(for: Self.fixedInstant, timeZone: TimeZone(identifier: "UTC")!)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "ja_JP@calendar=japanese")
        formatter.calendar = Calendar(identifier: .japanese)
        formatter.timeZone = TimeZone(identifier: "UTC")!
        let japaneseEraString = formatter.string(from: Self.fixedInstant)

        XCTAssertNotEqual(japaneseEraString, key,
                          "a Japanese-era DateFormatter reads the era year, not 2026 — DayKey must not agree with it")
        XCTAssertEqual(key, "2026-08-20")
    }
}
