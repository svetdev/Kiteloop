import XCTest
import KiteloopCore

/// The 7-day prune used to run only from `configure(baseURL:)` — reached at
/// launch and on project open. Kiteloop is meant to be always running, so an
/// install left up for weeks over one project pruned once, at launch, and then
/// kept every daily log forever. These cover the fix: pruning also runs from
/// the branch of `rotateIfNeeded()` that rolls the day, which an always-running
/// app is guaranteed to reach without a restart or a project open.
final class KiteloopFileLoggerTests: XCTestCase {

    /// Thread-safe box for the clock a test steps across a day boundary.
    /// `log()` reads the clock from its own background queue while the test
    /// thread advances it, so a plain `var` would race.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ date: Date) { self.current = date }

        func advance(byDays days: Int) {
            lock.lock()
            current = current.addingTimeInterval(Double(days) * 86_400)
            lock.unlock()
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    private static func logsDirectory(of base: URL) -> URL {
        base.appending(path: ".kiteloop/logs")
    }

    /// Writes a file `daysOld` days in the past by creation date — the same
    /// idiom `KiteloopFileLoggerTests` (KiteloopCoreTests) uses for
    /// `configure`'s own prune, applied here to the rollover path instead.
    private func makeAgedFile(named name: String, in logsDir: URL, daysOld: Int) throws {
        let fm = FileManager.default
        let file = logsDir.appending(path: name)
        try Data("old line\n".utf8).write(to: file)
        let created = Date().addingTimeInterval(-Double(daysOld) * 86_400)
        let path = file.path(percentEncoded: false)
        try fm.setAttributes([.creationDate: created], ofItemAtPath: path)
        let readBack = try fm.attributesOfItem(atPath: path)[.creationDate] as? Date
        XCTAssertEqual(
            readBack?.timeIntervalSince1970 ?? 0, created.timeIntervalSince1970, accuracy: 2,
            "the case needs a creation date it can set on \(name)"
        )
    }

    /// The core fix: a stale log is removed once the clock crosses into a new
    /// day and one line is logged — with no call to `configure` beyond the one
    /// construction itself makes. A log inside the seven-day window, and a
    /// non-`.log` file, both survive the same rollover.
    func testADayRolloverPrunesOnlyStaleLogFilesWithNoCallToConfigure() async throws {
        let project = try makeTemporaryDirectory(prefix: "kiteloop-logger-rollover")
        let logsDir = Self.logsDirectory(of: project)
        let clock = TestClock(Date())
        let logger = KiteloopFileLogger(baseURL: project, clock: clock.now)

        try await eventually("the logs directory to exist after construction") {
            FileManager.default.fileExists(atPath: logsDir.path(percentEncoded: false))
        }

        let staleName = KiteloopFileLogger.logFileName(
            for: clock.now().addingTimeInterval(-8 * 86_400), timeZone: .current
        )
        let recentName = KiteloopFileLogger.logFileName(
            for: clock.now().addingTimeInterval(-3 * 86_400), timeZone: .current
        )
        try makeAgedFile(named: staleName, in: logsDir, daysOld: 8)
        try makeAgedFile(named: recentName, in: logsDir, daysOld: 3)
        let nonLogFile = logsDir.appending(path: "notes.txt")
        try makeAgedFile(named: "notes.txt", in: logsDir, daysOld: 10)

        clock.advance(byDays: 1)
        logger.log("rollover probe \(UUID().uuidString)", category: "logger-test")

        try await eventually("the stale log to be pruned by the rollover, not by a configure call") {
            !FileManager.default.fileExists(atPath: logsDir.appending(path: staleName).path(percentEncoded: false))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: logsDir.appending(path: recentName).path(percentEncoded: false)),
            "a log inside the seven-day window survives the same rollover"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nonLogFile.path(percentEncoded: false)),
            "a non-.log file is not the rollover prune's to remove"
        )
    }

    /// The file the logger just rolled onto is never the one it prunes, and it
    /// keeps taking lines afterward.
    func testTheNewCurrentFileSurvivesTheRolloverPruneAndKeepsReceivingLines() async throws {
        let project = try makeTemporaryDirectory(prefix: "kiteloop-logger-rollover-current")
        let logsDir = Self.logsDirectory(of: project)
        let clock = TestClock(Date())
        let logger = KiteloopFileLogger(baseURL: project, clock: clock.now)

        try await eventually("the logs directory to exist after construction") {
            FileManager.default.fileExists(atPath: logsDir.path(percentEncoded: false))
        }

        let staleName = KiteloopFileLogger.logFileName(
            for: clock.now().addingTimeInterval(-8 * 86_400), timeZone: .current
        )
        try makeAgedFile(named: staleName, in: logsDir, daysOld: 8)

        clock.advance(byDays: 1)
        let firstLine = "rollover probe \(UUID().uuidString)"
        logger.log(firstLine, category: "logger-test")

        let newFile = logsDir.appending(path: KiteloopFileLogger.logFileName(for: clock.now(), timeZone: .current))
        try await eventually("the day's new file to exist and the stale one to be gone") {
            FileManager.default.fileExists(atPath: newFile.path(percentEncoded: false))
                && !FileManager.default.fileExists(atPath: logsDir.appending(path: staleName).path(percentEncoded: false))
        }

        let secondLine = "after prune \(UUID().uuidString)"
        logger.log(secondLine, category: "logger-test")

        try await eventually("both lines logged after the rollover to land in the new current file") {
            let text = (try? String(contentsOf: newFile, encoding: .utf8)) ?? ""
            return text.contains(firstLine) && text.contains(secondLine)
        }
    }

    /// `configure` — reached at launch and project open — still prunes on its
    /// own, unchanged from before this fix.
    func testConstructingTheLoggerStillPrunesAnAlreadyStaleLogAtConfigure() async throws {
        let project = try makeTemporaryDirectory(prefix: "kiteloop-logger-configure")
        let logsDir = Self.logsDirectory(of: project)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let staleName = KiteloopFileLogger.logFileName(for: Date().addingTimeInterval(-8 * 86_400), timeZone: .current)
        try makeAgedFile(named: staleName, in: logsDir, daysOld: 8)

        _ = KiteloopFileLogger(baseURL: project)

        try await eventually("construction's own configure to prune the already-stale log") {
            !FileManager.default.fileExists(atPath: logsDir.appending(path: staleName).path(percentEncoded: false))
        }
    }
}
