import XCTest
@testable import KiteloopCore

/// `.kiteloop/config.json` holds whether a project is parked and what it is
/// for: a truncated one decodes as `.default`, and the next `setPaused(_:goal:)`
/// writes that emptiness back permanently. These tests pin `saveConfig` to the
/// durable writer rather than to a plain `Data.write`.
final class KiteloopProjectConfigSaveTests: XCTestCase {

    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-project-config-atomic")
        project = KiteloopProject(rootURL: tempDir)
    }

    override func tearDownWithError() throws {
        project = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    /// Every save replaces the file in place, so a writer that abandoned its
    /// drafts would litter `.kiteloop` with one temp file per save.
    func testTwentySavesLeaveOnlyTheConfigFileBehind() throws {
        try FileManager.default.createDirectory(at: project.kiteloopDirURL, withIntermediateDirectories: true)

        for i in 0..<20 {
            var config = ProjectConfig.default
            config.paused = true
            config.goal = "goal-\(i)"
            try project.saveConfig(config)

            let reloaded = project.loadConfig()
            XCTAssertEqual(reloaded.goal, "goal-\(i)")
        }

        let entries = try FileManager.default
            .contentsOfDirectory(atPath: project.kiteloopDirURL.path(percentEncoded: false))
        XCTAssertEqual(entries, ["config.json"])
    }

    /// Today only `setPaused(_:goal:)` creates `.kiteloop` before writing;
    /// `saveConfig` on its own must create it too.
    func testSaveCreatesTheKiteloopDirectoryIfMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.kiteloopDirURL.path(percentEncoded: false)))

        var config = ProjectConfig.default
        config.goal = "a fresh goal"
        try project.saveConfig(config)

        let reloaded = project.loadConfig()
        XCTAssertEqual(reloaded.goal, "a fresh goal")
    }

    /// A `config.json` whose permissions were tightened by hand must keep that
    /// mode across a save.
    func testSavePreservesTightenedFilePermissions() throws {
        try FileManager.default.createDirectory(at: project.kiteloopDirURL, withIntermediateDirectories: true)
        try project.saveConfig(.default)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: project.configURL.path(percentEncoded: false)
        )

        var config = ProjectConfig.default
        config.goal = "still tightened"
        try project.saveConfig(config)

        let attributes = try FileManager.default
            .attributesOfItem(atPath: project.configURL.path(percentEncoded: false))
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }
}
