import XCTest
@testable import KiteloopCore

/// `KiteloopFileLogger.logFileName(for:timeZone:)` builds the log file name
/// through `DayKey` rather than a `DateFormatter` that reads `Locale.current`
/// — the same hazard `DayKeyTests` exercises: under a Japanese-calendar or
/// Arabic-Indic-numbering region, an unlocaled `DateFormatter` would name the
/// file with an era year or non-Latin digits instead of `2026-08-20`.
final class KiteloopFileLoggerFileNameTests: XCTestCase {

    private static let fixedInstant: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 20
        components.hour = 12; components.minute = 0; components.second = 0
        return calendar.date(from: components)!
    }()

    func testLogFileNameForFixedInstantInFixedTimeZone() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(
            KiteloopFileLogger.logFileName(for: Self.fixedInstant, timeZone: utc),
            "kiteloop-2026-08-20.log"
        )
    }
}
