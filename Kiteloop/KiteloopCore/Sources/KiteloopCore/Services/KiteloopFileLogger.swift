import Foundation
import os.log

/// Persistent file logger. Writes to `.kiteloop/logs/kiteloop-YYYY-MM-DD.log`
/// (or `~/.kiteloop/logs/…` before a project has been opened) and mirrors
/// recent lines to an in-memory ring buffer for the Diagnostics window.
/// Automatically prunes files older than 7 days.
package final class KiteloopFileLogger: @unchecked Sendable {
    package static let shared = KiteloopFileLogger()

    package struct Entry: Identifiable, Hashable {
        package let id: UInt64
        package let timestamp: Date
        package let level: OSLogType
        package let category: String
        package let message: String

        package var levelTag: String {
            switch level {
            case .error: return "ERROR"
            case .fault: return "FAULT"
            case .debug: return "DEBUG"
            default: return "INFO"
            }
        }

        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: UInt64, timestamp: Date, level: OSLogType, category: String, message: String) {
            self.id = id
            self.timestamp = timestamp
            self.level = level
            self.category = category
            self.message = message
        }
    }

    package static let bufferDidChange = Notification.Name("KiteloopFileLogger.bufferDidChange")

    private let queue = DispatchQueue(label: "ai.kasatkin.kiteloop.file-logger", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentLogFileName: String = ""
    private var logsDirectory: URL?

    /// Guards `buffer` and, separately, `logsDirectory`: `configure(baseURL:)`
    /// assigns the latter inside a `queue.async` block, while
    /// `currentLogFileURL()`, `rotateIfNeeded()` and `pruneOldLogs()` read or
    /// write it from whichever thread calls them — this lock is the one thing
    /// that makes that safe, not just the buffer's.
    private let bufferLock = NSLock()
    private var buffer: [Entry] = []
    private var nextID: UInt64 = 0
    /// How many entries the ring buffer keeps. Readable so a test can assert
    /// the cap against the real number rather than a copy of it.
    package let bufferCapacity = 2000

    /// Test-only: production always reads `Date()`. Injected so a test can step
    /// across a day boundary — where pruning happens — without waiting for one.
    private let clock: () -> Date

    /// The environment variable naming another base directory to log under.
    package static let baseDirectoryEnvironmentKey = "KITELOOP_LOG_BASE_DIRECTORY"

    /// Where a logger given no `baseURL` writes: `~/.kiteloop`, unless
    /// `KITELOOP_LOG_BASE_DIRECTORY` names somewhere else.
    ///
    /// The override is what keeps a test process out of the human's real log.
    /// `shared` is a `static let`, so anything that logs before a project is
    /// open — every `kiteloopLog` a store makes while a fixture's write fails —
    /// lands under this directory, and in a test process that used to be the
    /// same `~/.kiteloop` the running app writes to: a `swift test` run appended
    /// tens of thousands of fixture lines to the day's file. A test process sets
    /// the variable before any test runs — `KiteloopTestLogRedirect`, whose
    /// load-time constructor `KiteloopTestSupport` pulls in — and
    /// `scripts/run-core-tests.sh` names a scratch directory it throws away.
    package static func defaultBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let override = environment[baseDirectoryEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard override.isEmpty else { return URL(filePath: override) }
        return KiteloopHome.url.appending(path: ".kiteloop")
    }

    /// Injectable for tests via `init(baseURL:environment:clock:)`, like the
    /// other single-writer file logs (`RunRecordStore`).
    ///
    /// `baseURL` defaults to `defaultBaseURL(environment:)` so logs from app
    /// launch (before any project is opened) still land somewhere.
    package init(baseURL: URL? = nil,
                 environment: [String: String] = ProcessInfo.processInfo.environment,
                 clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
        configure(baseURL: baseURL ?? Self.defaultBaseURL(environment: environment))
    }

    /// Point the logger at a project directory. Called on each project open.
    package func configure(projectURL: URL) {
        configure(baseURL: projectURL)
    }

    private func configure(baseURL: URL) {
        queue.async { [self] in
            let logsDir = baseURL.appending(path: ".kiteloop/logs")
            let fm = FileManager.default
            if !fm.fileExists(atPath: logsDir.path(percentEncoded: false)) {
                try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            }
            bufferLock.lock()
            self.logsDirectory = logsDir
            bufferLock.unlock()
            self.fileHandle?.closeFile()
            self.fileHandle = nil
            self.currentLogFileName = ""
            rotateIfNeeded()
            pruneOldLogs()
        }
    }

    /// Current log file path, if configured. Used by the Diagnostics window.
    package func currentLogFileURL() -> URL? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard let dir = logsDirectory else { return nil }
        return dir.appending(path: Self.logFileName(for: clock(), timeZone: .current))
    }

    /// `kiteloop-YYYY-MM-DD.log` for `date` in `timeZone` — Gregorian, Latin
    /// digits, regardless of the Mac's calendar or numbering region.
    package static func logFileName(for date: Date, timeZone: TimeZone) -> String {
        "kiteloop-\(DayKey.string(for: date, timeZone: timeZone)).log"
    }

    /// `HH:mm:ss.SSS` for `date` in `timeZone` — Gregorian, Latin digits,
    /// regardless of the Mac's calendar or numbering region. A `DateFormatter`
    /// with no `locale` set inherits `Locale.current`, which carries a
    /// numbering system as well as a calendar: under an Arabic-Indic or
    /// Devanagari numbering region the stamp on every log line would render
    /// in non-Latin digits inside a file whose name is already pinned against
    /// that hazard (see `DayKey`).
    package static func timestamp(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    /// `HH:mm:ss.SSS [LEVEL] [category] message` for `entry` in `timeZone` —
    /// the same line shape `log(_:category:level:)` writes to the file,
    /// exposed so the Diagnostics window's copy-to-pasteboard renders the
    /// stamp through `timestamp(for:timeZone:)` rather than a formatter of
    /// its own.
    package static func logLine(for entry: Entry, timeZone: TimeZone) -> String {
        let ts = timestamp(for: entry.timestamp, timeZone: timeZone)
        return "\(ts) [\(entry.levelTag)] [\(entry.category)] \(entry.message)"
    }

    package func log(_ message: String, category: String, level: OSLogType = .info) {
        let now = clock()
        // Append to ring buffer on the caller's thread so the Diagnostics view
        // sees events as soon as they happen (writing to disk is async).
        bufferLock.lock()
        nextID &+= 1
        let entry = Entry(id: nextID, timestamp: now, level: level, category: category, message: message)
        buffer.append(entry)
        if buffer.count > bufferCapacity {
            buffer.removeFirst(buffer.count - bufferCapacity)
        }
        bufferLock.unlock()
        postBufferDidChange()

        queue.async { [self] in
            rotateIfNeeded()
            guard let fh = fileHandle else { return }
            let ts = Self.timestamp(for: now, timeZone: .current)
            let line = "\(ts) [\(entry.levelTag)] [\(category)] \(message)\n"
            if let data = line.data(using: .utf8) {
                fh.write(data)
            }
        }
    }

    /// Announce the new entry to the Diagnostics window.
    ///
    /// `NotificationCenter` delivers on the thread that posts, and the one
    /// observer — `DiagnosticsLogView` — assigns to SwiftUI `@State` from it,
    /// so a log line written on a background queue (most of
    /// `ClaudeCodeCLIRuntime`'s are) would drive that state off the main
    /// thread. Post from the main thread instead; a caller already there keeps
    /// its synchronous delivery, so the view still sees the entry before
    /// `log(_:category:level:)` returns.
    private func postBufferDidChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.bufferDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.bufferDidChange, object: nil)
            }
        }
    }

    /// Snapshot of the ring buffer for the Diagnostics window.
    package func snapshot() -> [Entry] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return buffer
    }

    /// Distinct category tags currently in the buffer.
    package func categories() -> [String] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return Array(Set(buffer.map { $0.category })).sorted()
    }

    private func rotateIfNeeded() {
        bufferLock.lock()
        let dir = logsDirectory
        bufferLock.unlock()
        guard let logsDir = dir else { return }
        let fileName = Self.logFileName(for: clock(), timeZone: .current)
        guard fileName != currentLogFileName else { return }

        fileHandle?.closeFile()
        fileHandle = nil
        currentLogFileName = fileName

        let filePath = logsDir.appending(path: fileName).path(percentEncoded: false)
        let fm = FileManager.default
        if !fm.fileExists(atPath: filePath) {
            fm.createFile(atPath: filePath, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: filePath)
        fileHandle?.seekToEndOfFile()

        // The day rolling over is the one event an always-running app is
        // guaranteed to reach without a restart or a project open — pruning
        // here, not only from `configure`, is what keeps the retention window
        // true for an install nobody quits.
        pruneOldLogs()
    }

    private func pruneOldLogs() {
        bufferLock.lock()
        let dir = logsDirectory
        bufferLock.unlock()
        guard let logsDir = dir else { return }
        let fm = FileManager.default
        let now = clock()
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now

        guard let files = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files where file.pathExtension == "log" {
            if let attrs = try? fm.attributesOfItem(atPath: file.path(percentEncoded: false)),
               let created = attrs[.creationDate] as? Date,
               created < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}

/// Convenience for logging alongside os.log — use in place of Logger calls.
package func kiteloopLog(_ message: String, category: String, level: OSLogType = .info) {
    KiteloopFileLogger.shared.log(message, category: category, level: level)
}
