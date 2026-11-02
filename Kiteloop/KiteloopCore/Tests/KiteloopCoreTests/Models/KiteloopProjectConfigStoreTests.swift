import XCTest
@testable import KiteloopCore

/// A `.kiteloop/config.json` the decoder refused used to read as a project
/// nobody had configured: `loadConfig()` answered `.default` exactly as it does
/// for no file at all, and the next `saveConfig(_:)` wrote those defaults over
/// the bytes for good — silently re-permitting the project and unparking a
/// project a human had paused. These pin the replacement: the file is
/// moved aside and reported once, a project with no file stays silent, and a
/// valid file still round-trips every field.
final class KiteloopProjectConfigStoreTests: XCTestCase {

    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try redirectSharedLoggerToTemporaryDirectory(prefix: "kiteloop-project-config-store-log")
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-project-config-store")
        project = KiteloopProject(rootURL: tempDir)
        try FileManager.default.createDirectory(at: project.kiteloopDirURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        project = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makeInbox(_ name: String = "inbox") -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "\(name).log"))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func quarantined(besides url: URL) throws -> [URL] {
        let prefix = "\(url.lastPathComponent).unreadable-"
        return try FileManager.default
            .contentsOfDirectory(at: project.kiteloopDirURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func testAnUndecodableConfigIsKeptAsideAndTheProjectReadsDefaults() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let original = Data(#"{"permissionMode": "acceptEdits", "autoApprovedTools"#.utf8)
        try original.write(to: project.configURL)

        let loaded = project.loadConfig(reporter: reporter)
        await reporter.drain()

        XCTAssertEqual(loaded.permissionMode, ProjectConfig.default.permissionMode)
        XCTAssertEqual(loaded.paused, ProjectConfig.default.paused)
        // The point of the whole thing: the bytes the decoder refused are not
        // where the next `saveConfig` would overwrite them, and they are intact
        // beside it.
        XCTAssertFalse(exists(project.configURL))
        let aside = try quarantined(besides: project.configURL)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(aside.first)), original)
    }

    func testAnUndecodableConfigReportsOnceAndNotAgainOnceQuarantined() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        try Data("not json at all".utf8).write(to: project.configURL)

        _ = project.loadConfig(reporter: reporter)
        await reporter.drain()

        let firstPending = await inbox.pending()
        XCTAssertEqual(firstPending.count, 1)
        XCTAssertEqual(firstPending.first?.type, .error)
        XCTAssertEqual(firstPending.first?.title, "Could not read \(KiteloopProject.configStoreName)")

        // The refused file is gone — quarantined — so a second load finds
        // nothing to complain about and files no second report.
        _ = project.loadConfig(reporter: reporter)
        await reporter.drain()

        let secondPending = await inbox.pending()
        XCTAssertEqual(secondPending.count, 1)
    }

    /// The fix keeps the evidence and tells the human — it does not invent a
    /// parked state. A quarantined paused project reads as the safe unparked
    /// default, but the `paused` value itself survives, readable in the file
    /// moved aside.
    func testAQuarantinedPausedConfigReadsUnpausedButStaysReadableInTheMovedAsideFile() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let original = Data(#"{"paused": true, "permissionMode": "acceptEdits", "autoApprovedTools": ["#.utf8)
        try original.write(to: project.configURL)

        let loaded = project.loadConfig(reporter: reporter)
        await reporter.drain()

        XCTAssertNil(loaded.paused)
        let aside = try quarantined(besides: project.configURL)
        XCTAssertEqual(aside.count, 1)
        let asideContents = try String(contentsOf: try XCTUnwrap(aside.first), encoding: .utf8)
        XCTAssertTrue(asideContents.contains("paused"))
    }

    func testAProjectWithNoConfigFileReportsNothingAndReturnsDefault() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)

        let loaded = project.loadConfig(reporter: reporter)
        await reporter.drain()

        XCTAssertEqual(loaded.permissionMode, ProjectConfig.default.permissionMode)
        XCTAssertEqual(try quarantined(besides: project.configURL).count, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    func testAValidConfigRoundTripsThroughSaveAndLoadWithEveryFieldIntact() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        var config = ProjectConfig.default
        config.model = "claude-sonnet-5"
        config.permissionMode = "manual"
        config.deniedTools = ["Bash"]
        config.agentSessionIDs = ["reviewer": "session-123"]
        config.maxBudgetUSD = 42.5
        config.paused = true
        config.goal = "keep the lights on"

        try project.saveConfig(config)
        let loaded = project.loadConfig(reporter: reporter)
        await reporter.drain()

        XCTAssertEqual(loaded.model, config.model)
        XCTAssertEqual(loaded.permissionMode, config.permissionMode)
        XCTAssertEqual(loaded.deniedTools, config.deniedTools)
        XCTAssertEqual(loaded.agentSessionIDs, config.agentSessionIDs)
        XCTAssertEqual(loaded.maxBudgetUSD, config.maxBudgetUSD)
        XCTAssertEqual(loaded.paused, config.paused)
        XCTAssertEqual(loaded.goal, config.goal)
        XCTAssertEqual(try quarantined(besides: project.configURL).count, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    // MARK: - The removed permission dials

    /// A `config.json` written before auto mode and the per-project permission
    /// rules were removed still loads: the keys that no longer exist are
    /// unknown to the decoder and ignored, and everything beside them reads as
    /// it did.
    func testAConfigCarryingTheRemovedPermissionKeysStillLoads() throws {
        try Data("""
        {"permissionMode": "acceptEdits", "deniedTools": ["Bash"],
         "autoApprovedTools": ["Read", "Glob"], "autoModeThreshold": "high",
         "permissionRules": [{"toolPattern": "Bash", "action": "deny"}],
         "goal": "keep the lights on"}
        """.utf8).write(to: project.configURL)

        let loaded = project.loadConfig()

        XCTAssertEqual(loaded.permissionMode, "acceptEdits")
        XCTAssertEqual(loaded.deniedTools, ["Bash"])
        XCTAssertEqual(loaded.goal, "keep the lights on")
        XCTAssertEqual(try quarantined(besides: project.configURL).count, 0)
    }

    // MARK: - The removed hook fields

    /// A `config.json` written while Kiteloop ran its own hook rules still
    /// loads, and the next save writes none of the hook keys back.
    func testAConfigCarryingTheRemovedHookKeysLoadsAndTheNextSaveDropsThem() throws {
        try Data("""
        {"permissionMode": "acceptEdits", "deniedTools": [],
         "hookSchemaVersion": 1, "hooksTrusted": true,
         "hooks": [{"event": "turnComplete", "action": {"type": "logEvent"}}],
         "goal": "keep the lights on"}
        """.utf8).write(to: project.configURL)

        let loaded = project.loadConfig()
        XCTAssertEqual(loaded.permissionMode, "acceptEdits")
        XCTAssertEqual(loaded.goal, "keep the lights on")
        XCTAssertEqual(try quarantined(besides: project.configURL).count, 0)

        try project.saveConfig(loaded)

        let written = try String(contentsOf: project.configURL, encoding: .utf8)
        XCTAssertFalse(written.contains("hook"), written)
        XCTAssertTrue(written.contains("keep the lights on"), written)
    }

    // MARK: - The legacy priority key

    /// The one thing the old three-way priority said that survives: a project a
    /// human parked before the dial became a switch must still be parked after
    /// the upgrade, without anybody re-parking it by hand.
    func testALegacyPausedPriorityLoadsAsPaused() throws {
        try legacyConfig(priority: "paused").write(to: project.configURL)

        XCTAssertEqual(project.loadConfig().paused, true)
        XCTAssertTrue(project.isPaused)
    }

    /// `high` and `normal` ranked a fleet that now orders itself by which
    /// project has been idle longest, so they map to nothing — and in
    /// particular never to a park.
    func testALegacyRankingPriorityLoadsAsNotPaused() throws {
        for ranking in ["high", "normal", "urgent", ""] {
            try legacyConfig(priority: ranking).write(to: project.configURL)

            XCTAssertNil(project.loadConfig().paused, ranking)
            XCTAssertFalse(project.isPaused, ranking)
        }
    }

    /// The migration is one-way: once the project is saved, the file speaks the
    /// new key and the old one is gone.
    func testSavingALegacyConfigWritesPausedAndDropsPriority() throws {
        try legacyConfig(priority: "paused").write(to: project.configURL)

        try project.saveConfig(project.loadConfig())

        let written = try String(contentsOf: project.configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("\"paused\" : true"), written)
        XCTAssertFalse(written.contains("priority"), written)
    }

    /// A `config.json` as it was written before this change: the legacy
    /// `priority` string beside the fields that have not moved.
    private func legacyConfig(priority: String) -> Data {
        Data("""
        {"priority": "\(priority)", "permissionMode": "acceptEdits",
         "autoApprovedTools": ["Read"], "deniedTools": []}
        """.utf8)
    }
}
