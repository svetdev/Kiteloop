import XCTest
@testable import KiteloopCore

/// A store whose JSON the decoder refused used to read as a store that had never
/// been written, and the next save made that permanent. These pin the other
/// behaviour: the file is moved aside before the caller starts fresh, the human
/// is told where it went, and a valid file still loads exactly as it did.
final class QuarantiningJSONFileTests: XCTestCase {

    private struct Settings: Codable, Equatable {
        var name: String
        var count: Int
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try redirectSharedLoggerToTemporaryDirectory(prefix: "quarantining-json-log")
        tempDir = try makeTemporaryDirectory(prefix: "quarantining-json")
    }

    private func makeInbox(_ name: String = "inbox") -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "\(name).log"))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// The files sitting beside `url` that this type moved aside.
    private func quarantined(besides url: URL) throws -> [URL] {
        let prefix = "\(url.lastPathComponent).unreadable-"
        return try FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - The file loads

    func testAValidFileDecodesAndIsLeftWhereItIs() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "settings.json")
        let stored = Settings(name: "kiteloop", count: 3)
        try JSONEncoder().encode(stored).write(to: url)

        let loaded = QuarantiningJSONFile.load(Settings.self,
                                               from: url,
                                               store: "Settings",
                                               reporter: reporter)
        await reporter.drain()

        XCTAssertEqual(loaded, stored)
        XCTAssertTrue(exists(url))
        XCTAssertEqual(try quarantined(besides: url).count, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    /// Every one of these stores is created by its first save, so no file is the
    /// ordinary first-launch state — not a problem to report and nothing to move.
    func testAMissingFileIsSilent() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "settings.json")

        let loaded = QuarantiningJSONFile.load(Settings.self,
                                               from: url,
                                               store: "Settings",
                                               reporter: reporter)
        await reporter.drain()

        XCTAssertNil(loaded)
        XCTAssertFalse(exists(url))
        XCTAssertEqual(try quarantined(besides: url).count, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    // MARK: - The file the decoder refuses

    func testAnUndecodableFileIsMovedAsideWithItsBytesIntact() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "settings.json")
        let original = Data(#"{"name": "kiteloop", "cou"#.utf8)  // truncated mid-key
        try original.write(to: url)

        let loaded = QuarantiningJSONFile.load(Settings.self,
                                               from: url,
                                               store: "Settings",
                                               reporter: reporter)
        await reporter.drain()

        XCTAssertNil(loaded)
        // The point of the whole thing: what was at the store's path is gone from
        // there — so the next save cannot overwrite it — and is intact beside it.
        XCTAssertFalse(exists(url))
        let aside = try quarantined(besides: url)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(aside.first)), original)
    }

    /// A silent quarantine would only move the surprise later. The row has to
    /// name the store, the file, and where the file went.
    func testAnUndecodableFileIsReportedNamingWhereItWent() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "settings.json")
        try Data("not json at all".utf8).write(to: url)

        _ = QuarantiningJSONFile.load(Settings.self,
                                      from: url,
                                      store: "Settings",
                                      reporter: reporter)
        await reporter.drain()

        let aside = try XCTUnwrap(try quarantined(besides: url).first)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not read Settings")
        XCTAssertEqual(pending.first?.body.contains(url.path(percentEncoded: false)), true)
        // By name, not full path: `contentsOfDirectory` answers in the
        // canonicalized /private/var form while the body carries the caller's
        // /var form — the unique quarantine filename proves "names where it
        // went" without tying the test to which form macOS hands back.
        XCTAssertEqual(pending.first?.body.contains(aside.lastPathComponent), true)
    }

    func testAnUndecodableFileWritesADiagnosticsLine() async throws {
        let reporter = StoreProblemReporter(notifications: makeInbox())
        let marker = "marker-\(UUID().uuidString)"
        let url = tempDir.appending(path: "\(marker).json")
        try Data("{".utf8).write(to: url)

        _ = QuarantiningJSONFile.load(Settings.self,
                                      from: url,
                                      store: "Settings",
                                      reporter: reporter)
        await reporter.drain()

        let lines = KiteloopFileLogger.shared.snapshot()
            .filter { $0.category == StoreProblemReporter.logCategory && $0.message.contains(marker) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.levelTag, "ERROR")
        XCTAssertEqual(lines.first?.message.contains("moved aside"), true)
    }

    /// The quarantine name carries a timestamp only to the second, so two
    /// refusals inside one second name the same file — and a rename that
    /// overwrote would destroy the first one, which is the exact failure this
    /// type exists to prevent. `now` is pinned here so the collision is certain
    /// rather than a matter of when the test happens to run.
    func testTwoRefusalsInTheSameSecondBothSurvive() async throws {
        let reporter = StoreProblemReporter(notifications: makeInbox())
        let url = tempDir.appending(path: "settings.json")
        let sameSecond = Date(timeIntervalSince1970: 1_786_000_000)

        let first = Data("first broken file".utf8)
        try first.write(to: url)
        _ = QuarantiningJSONFile.load(Settings.self, from: url, store: "Settings",
                                      reporter: reporter, now: sameSecond)

        let second = Data("second broken file".utf8)
        try second.write(to: url)
        _ = QuarantiningJSONFile.load(Settings.self, from: url, store: "Settings",
                                      reporter: reporter, now: sameSecond)
        await reporter.drain()

        let aside = try quarantined(besides: url)
        XCTAssertEqual(aside.count, 2)
        XCTAssertEqual(Set(try aside.map { try Data(contentsOf: $0) }), [first, second])
    }

    /// A file that cannot be read at all — a directory standing where the store's
    /// file belongs — is reported, but not moved: there is nothing a move would
    /// rescue, and what could not be read is as easily lost by moving it.
    func testAFileThatCannotBeReadIsReportedAndLeftAlone() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "settings.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let loaded = QuarantiningJSONFile.load(Settings.self,
                                               from: url,
                                               store: "Settings",
                                               reporter: reporter)
        await reporter.drain()

        XCTAssertNil(loaded)
        XCTAssertTrue(exists(url))
        XCTAssertEqual(try quarantined(besides: url).count, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not read Settings")
    }

    // MARK: - Handing the problem back

    /// A caller that has to *act* on the failure needs it back, not only reported:
    /// the daily ledger refuses an autonomous start while today's spend is
    /// unknown, and "unknown" is exactly this being non-nil.
    func testReadHandsTheProblemBackAsWellAsReportingIt() async throws {
        let reporter = StoreProblemReporter(notifications: makeInbox())
        let url = tempDir.appending(path: "settings.json")
        try Data("not json at all".utf8).write(to: url)

        let outcome = QuarantiningJSONFile.read(Settings.self, from: url,
                                                store: "Settings", reporter: reporter)
        await reporter.drain()

        XCTAssertNil(outcome.value)
        let problem = try XCTUnwrap(outcome.problem)
        let aside = try XCTUnwrap(try quarantined(besides: url).first)
        XCTAssertTrue(problem.contains(aside.lastPathComponent),
                      "the problem has to say where the bytes went: \(problem)")
    }

    /// The two cases that are not problems, told apart from the one that is: a
    /// missing file is the ordinary first-launch state, and a file that decoded
    /// has nothing to say either.
    func testReadHasNothingToSayAboutAMissingOrValidFile() async throws {
        let reporter = StoreProblemReporter(notifications: makeInbox())
        let url = tempDir.appending(path: "settings.json")

        XCTAssertNil(QuarantiningJSONFile.read(Settings.self, from: url,
                                               store: "Settings", reporter: reporter).problem)

        let stored = Settings(name: "kiteloop", count: 3)
        try JSONEncoder().encode(stored).write(to: url)
        let outcome = QuarantiningJSONFile.read(Settings.self, from: url,
                                                store: "Settings", reporter: reporter)
        await reporter.drain()

        XCTAssertEqual(outcome.value, stored)
        XCTAssertNil(outcome.problem)
    }
}
