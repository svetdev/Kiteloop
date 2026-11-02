import XCTest
import os.log
@testable import KiteloopCore

/// `KiteloopFileLogger.bufferDidChange` drives the Diagnostics log tab, whose
/// `.onReceive` assigns to the `@State` arrays behind the list.
/// `NotificationCenter` delivers on whatever thread posted, so a log line
/// written on a background queue — most of `ClaudeCodeCLIRuntime`'s are — used
/// to mutate SwiftUI state from that queue while the window was open. These
/// cases hold the post to the main thread, and hold it to staying synchronous
/// for a caller that is already there, which is what lets the view see an entry
/// before the (async) disk write.
final class KiteloopFileLoggerTests: XCTestCase {

    /// One row per `bufferDidChange` delivery: the thread it arrived on, and
    /// whether the entry the test logged was in the buffer by then. The
    /// notification carries no payload and is global — anything else in the
    /// process that logs during a test is delivered here too — so the entry is
    /// what tells this test's delivery from someone else's.
    private final class DeliveryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [(onMain: Bool, isOurs: Bool)] = []

        func record(isOurs: Bool) {
            let onMain = Thread.isMainThread
            lock.lock()
            rows.append((onMain: onMain, isOurs: isOurs))
            lock.unlock()
        }

        private func count(where matches: ((onMain: Bool, isOurs: Bool)) -> Bool) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return rows.filter(matches).count
        }

        var offMainDeliveries: Int { count { !$0.onMain } }
        var mainThreadDeliveries: Int { count { $0.onMain } }
        var ourDeliveries: Int { count { $0.isOurs } }
    }

    private var observer: NSObjectProtocol?

    /// Every case here logs through `KiteloopFileLogger.shared` — the cap probe
    /// alone logs `bufferCapacity + 10` lines, and those used to be appended to
    /// the human's real log for the day. The process-wide redirect already keeps
    /// them out of it; this gives them a directory that goes away with the test,
    /// and gives the file cases below one to point the logger back at.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try redirectSharedLoggerToTemporaryDirectory(prefix: "kiteloop-logger-default")
    }

    override func tearDown() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        super.tearDown()
    }

    /// Records every `bufferDidChange` until the test ends, marking the ones
    /// that arrive with `message` already in the ring buffer.
    ///
    /// `queue: nil` is the point of the helper: an `OperationQueue.main`
    /// observer would hop to the main thread by itself and hide the very
    /// behaviour being asserted, so delivery is left on the posting thread.
    private func observeBufferDidChange(
        watchingFor message: String,
        onOurDelivery: (@Sendable () -> Void)? = nil
    ) -> DeliveryLog {
        let log = DeliveryLog()
        observer = NotificationCenter.default.addObserver(
            forName: KiteloopFileLogger.bufferDidChange,
            object: nil,
            queue: nil
        ) { _ in
            let isOurs = KiteloopFileLogger.shared.snapshot().contains { $0.message == message }
            log.record(isOurs: isOurs)
            if isOurs { onOurDelivery?() }
        }
        return log
    }

    // MARK: - Which thread the notification arrives on

    func testALogFromABackgroundQueueDeliversTheNotificationOnTheMainThread() {
        let message = "background log \(UUID().uuidString)"
        let delivered = expectation(description: "bufferDidChange for our entry")
        delivered.assertForOverFulfill = false
        let log = observeBufferDidChange(watchingFor: message) { delivered.fulfill() }

        DispatchQueue.global(qos: .userInitiated).async {
            KiteloopFileLogger.shared.log(message, category: "logger-test")
        }

        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(
            log.offMainDeliveries, 0,
            "bufferDidChange was delivered off the main thread — DiagnosticsLogView.refresh() would mutate @State there"
        )
        XCTAssertGreaterThan(log.mainThreadDeliveries, 0)
    }

    func testALogOnTheMainThreadDeliversTheNotificationBeforeItReturns() {
        XCTAssertTrue(Thread.isMainThread, "this case asserts what a main-thread caller sees")
        let message = "main log \(UUID().uuidString)"
        let log = observeBufferDidChange(watchingFor: message)

        KiteloopFileLogger.shared.log(message, category: "logger-test")

        XCTAssertEqual(
            log.ourDeliveries, 1,
            "a main-thread log must post synchronously, so the view sees the entry ahead of the disk write"
        )
        XCTAssertEqual(log.offMainDeliveries, 0)
    }

    // MARK: - The ring buffer itself

    func testSnapshotHoldsAnEntryLoggedOnTheMainThreadAsSoonAsLogReturns() {
        let message = "snapshot probe \(UUID().uuidString)"

        KiteloopFileLogger.shared.log(message, category: "logger-test", level: .error)

        let entry = KiteloopFileLogger.shared.snapshot().last { $0.message == message }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.category, "logger-test")
        XCTAssertEqual(entry?.levelTag, "ERROR")
    }

    func testTheRingBufferStillCapsAtItsCapacity() {
        let logger = KiteloopFileLogger.shared
        let capacity = logger.bufferCapacity
        let run = UUID().uuidString

        for index in 0..<(capacity + 10) {
            logger.log("cap probe \(run) \(index)", category: "logger-test")
        }

        let snapshot = logger.snapshot()
        XCTAssertEqual(snapshot.count, capacity)
        XCTAssertEqual(snapshot.last?.message, "cap probe \(run) \(capacity + 9)")
        XCTAssertFalse(
            snapshot.contains { $0.message == "cap probe \(run) 0" },
            "the oldest entries are the ones dropped"
        )
    }

    // MARK: - The file on disk

    /// Points the shared logger at `project` for the rest of the test. Putting it
    /// back is `setUpWithError`'s redirect teardown, which restores
    /// `KiteloopFileLogger.defaultBaseURL()` — so the next case's lines land
    /// neither in a directory this one deleted nor in the human's real log.
    private func pointLogger(at project: URL) {
        KiteloopFileLogger.shared.configure(projectURL: project)
    }

    private static func logsDirectory(of project: URL) -> URL {
        project.appending(path: ".kiteloop/logs")
    }

    /// Every `.log` file under `logsDir`, concatenated — empty when the
    /// directory is not there, which is one of the states being asserted.
    private static func logText(in logsDir: URL) -> String {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else { return "" }
        return files
            .filter { $0.pathExtension == "log" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined()
    }

    /// A project that has never been logged to has no `.kiteloop/logs` — and no
    /// `.kiteloop` either. The first line logged after `configure` must create
    /// both, open the day's file, and land there with its level and category.
    @MainActor
    func testALineLoggedUnderAFreshProjectLandsInThatProjectsLogFile() async throws {
        let project = try makeTemporaryDirectory(prefix: "kiteloop-logger")
        let logsDir = Self.logsDirectory(of: project)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: project.appending(path: ".kiteloop").path(percentEncoded: false)),
            "the case is about a project nothing has logged to yet"
        )
        let message = "disk probe \(UUID().uuidString)"

        pointLogger(at: project)
        KiteloopFileLogger.shared.log(message, category: "logger-test")

        try await eventually("the line to reach a .log file under \(logsDir.path(percentEncoded: false))") {
            Self.logText(in: logsDir).contains("[INFO] [logger-test] \(message)")
        }
    }

    /// A project path with a space in it — `~/Documents/my project` is an
    /// ordinary place for one — is one string on disk and another inside a
    /// `URL`, where the space is `%20`. The logger must look for, create and
    /// open its directory and file at the on-disk spelling. A sibling that
    /// happens to carry the encoded spelling is what makes the difference
    /// visible: a logger reading the URL's form would find the directory
    /// "already there", never create the real one, and write into the sibling.
    @MainActor
    func testAProjectPathWithASpaceIsLoggedToAtItsOnDiskSpelling() async throws {
        let parent = try makeTemporaryDirectory(prefix: "kiteloop-logger")
        let fm = FileManager.default
        let project = parent.appending(path: "my project")
        try fm.createDirectory(at: project, withIntermediateDirectories: false)
        let decoyLogs = Self.logsDirectory(of: parent.appending(path: "my%20project"))
        try fm.createDirectory(at: decoyLogs, withIntermediateDirectories: true)
        let logsDir = Self.logsDirectory(of: project)
        let message = "space probe \(UUID().uuidString)"

        pointLogger(at: project)
        KiteloopFileLogger.shared.log(message, category: "logger-test")

        try await eventually("the line to reach a .log file under \(logsDir.path(percentEncoded: false))") {
            Self.logText(in: logsDir).contains(message)
        }
        XCTAssertFalse(
            Self.logText(in: decoyLogs).contains(message),
            "the line was written under the URL-encoded spelling of the project path"
        )
    }

    /// `configure(projectURL:)` is called on every project open, and
    /// `currentLogFileURL()` is what the Diagnostics footer and its Reveal
    /// action read. Once a second `configure` has actually landed — a line
    /// logged after it is on disk — `currentLogFileURL()` must name the new
    /// project's directory, never the one before it.
    @MainActor
    func testCurrentLogFileURLNamesTheNewProjectOnceAReconfigureHasLanded() async throws {
        let projectA = try makeTemporaryDirectory(prefix: "kiteloop-logger-a")
        let projectB = try makeTemporaryDirectory(prefix: "kiteloop-logger-b")
        let logsDirA = Self.logsDirectory(of: projectA)
        let logsDirB = Self.logsDirectory(of: projectB)
        let messageA = "project A probe \(UUID().uuidString)"
        let messageB = "project B probe \(UUID().uuidString)"

        pointLogger(at: projectA)
        KiteloopFileLogger.shared.log(messageA, category: "logger-test")
        try await eventually("the line to reach project A's log file") {
            Self.logText(in: logsDirA).contains(messageA)
        }

        KiteloopFileLogger.shared.configure(projectURL: projectB)
        KiteloopFileLogger.shared.log(messageB, category: "logger-test")
        try await eventually("the line to reach project B's log file") {
            Self.logText(in: logsDirB).contains(messageB)
        }

        let currentPath = KiteloopFileLogger.shared.currentLogFileURL()?.path(percentEncoded: false) ?? ""
        XCTAssertTrue(
            currentPath.hasPrefix(logsDirB.path(percentEncoded: false)),
            "currentLogFileURL() (\(currentPath)) must name a file under \(logsDirB.path(percentEncoded: false))"
        )
        XCTAssertFalse(
            currentPath.hasPrefix(logsDirA.path(percentEncoded: false)),
            "currentLogFileURL() (\(currentPath)) must not name a file under the previous project's directory"
        )
    }

    /// `configure` prunes log files older than seven days, and only those: a
    /// log inside the window stays, and a file of some other kind that happens
    /// to be old is not the logger's to delete. The project path carries a
    /// space because the creation date is read by path, and only the on-disk
    /// spelling answers.
    @MainActor
    func testConfigurePrunesOnlyLogFilesOlderThanSevenDays() async throws {
        let parent = try makeTemporaryDirectory(prefix: "kiteloop-logger")
        let project = parent.appending(path: "old project")
        let logsDir = Self.logsDirectory(of: project)
        let fm = FileManager.default
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let staleLog = logsDir.appending(path: "kiteloop-2024-01-01.log")
        let staleOther = logsDir.appending(path: "notes.txt")
        let recentLog = logsDir.appending(
            path: KiteloopFileLogger.logFileName(for: Date().addingTimeInterval(-86_400), timeZone: .current)
        )
        for file in [staleLog, staleOther, recentLog] {
            try Data("old line\n".utf8).write(to: file)
        }
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86_400)
        for file in [staleLog, staleOther] {
            let path = file.path(percentEncoded: false)
            try fm.setAttributes([.creationDate: tenDaysAgo], ofItemAtPath: path)
            let created = try fm.attributesOfItem(atPath: path)[.creationDate] as? Date
            XCTAssertEqual(
                created?.timeIntervalSince1970 ?? 0, tenDaysAgo.timeIntervalSince1970, accuracy: 2,
                "the case needs a creation date it can set on \(file.lastPathComponent)"
            )
        }

        pointLogger(at: project)

        try await eventually("the stale log to be pruned") {
            !FileManager.default.fileExists(atPath: staleLog.path(percentEncoded: false))
        }
        XCTAssertTrue(
            fm.fileExists(atPath: staleOther.path(percentEncoded: false)),
            "only .log files are the logger's to prune"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: recentLog.path(percentEncoded: false)),
            "a log inside the seven-day window stays"
        )
    }

    // MARK: - Where a logger with no project open writes

    /// `shared` is a `static let`, built before anything can point it anywhere,
    /// so this is where every line logged before a project opens lands — in a
    /// test process too, which is how thousands of fixture lines came to be
    /// appended to the day's log in the human's own Kiteloop home.
    func testTheDefaultBaseDirectoryIsTheKiteloopHomeWhenNothingOverridesIt() {
        let expected = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kiteloop")

        XCTAssertEqual(
            KiteloopFileLogger.defaultBaseURL(environment: [:]).path(percentEncoded: false),
            expected.path(percentEncoded: false)
        )
    }

    /// An empty or whitespace-only variable is a variable nobody set — exporting
    /// one blank must not send the logs to the process's working directory.
    func testABlankOverrideLeavesTheDefaultAlone() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".kiteloop").path(percentEncoded: false)

        for blank in ["", "   ", "\n"] {
            let base = KiteloopFileLogger.defaultBaseURL(
                environment: [KiteloopFileLogger.baseDirectoryEnvironmentKey: blank]
            )
            XCTAssertEqual(base.path(percentEncoded: false), expected, "for \(blank.debugDescription)")
        }
    }

    /// The override itself — what `KiteloopTestLogRedirect` sets at load and
    /// `scripts/run-core-tests.sh` exports: a logger nothing has configured
    /// writes under it, and so nothing under the Kiteloop home.
    @MainActor
    func testTheEnvironmentOverrideDecidesWhereALoggerWithNoProjectWrites() async throws {
        let base = try makeTemporaryDirectory(prefix: "kiteloop-logger-env")
        let logsDir = Self.logsDirectory(of: base)
        let message = "env probe \(UUID().uuidString)"
        let logger = KiteloopFileLogger(
            environment: [KiteloopFileLogger.baseDirectoryEnvironmentKey: base.path(percentEncoded: false)]
        )

        logger.log(message, category: "logger-test")

        try await eventually("the line to reach a .log file under \(logsDir.path(percentEncoded: false))") {
            Self.logText(in: logsDir).contains(message)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        XCTAssertFalse(
            (logger.currentLogFileURL()?.path(percentEncoded: false) ?? home).hasPrefix(home),
            "an overridden logger must name no file under the human's home"
        )
    }
}
