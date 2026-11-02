import XCTest
@testable import KiteloopCore

/// `KiteloopFileLogger.timestamp(for:timeZone:)` builds the per-line stamp
/// through an explicitly Gregorian, `en_US_POSIX`-locale `DateFormatter`
/// rather than one that reads `Locale.current` — the same hazard
/// `KiteloopFileLoggerFileNameTests` exercises for the file name: under an
/// Arabic-Indic or Devanagari numbering region, an unlocaled `DateFormatter`
/// would render the stamp in non-Latin digits.
final class KiteloopFileLoggerTimestampTests: XCTestCase {

    private static let fixedInstant: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 20
        components.hour = 12; components.minute = 0; components.second = 0
        return calendar.date(from: components)!
    }()

    func testTimestampForFixedInstantInFixedTimeZone() {
        let utc = TimeZone(identifier: "UTC")!
        let stamp = KiteloopFileLogger.timestamp(for: Self.fixedInstant, timeZone: utc)
        XCTAssertEqual(stamp, "12:00:00.000")
        XCTAssertTrue(stamp.allSatisfy { $0.isASCII })
    }

    func testTimestampReflectsTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(
            KiteloopFileLogger.timestamp(for: Self.fixedInstant, timeZone: tokyo),
            "21:00:00.000"
        )
    }

    func testLogLineMatchesFileLineShape() {
        let utc = TimeZone(identifier: "UTC")!
        let entry = KiteloopFileLogger.Entry(
            id: 1, timestamp: Self.fixedInstant, level: .error, category: "Orchestrator", message: "agent crashed"
        )
        let line = KiteloopFileLogger.logLine(for: entry, timeZone: utc)
        XCTAssertEqual(line, "12:00:00.000 [ERROR] [Orchestrator] agent crashed")
        XCTAssertTrue(line.allSatisfy { $0.isASCII })
    }
}
