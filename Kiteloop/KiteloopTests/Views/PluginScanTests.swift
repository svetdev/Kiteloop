import XCTest
@testable import Kiteloop

final class PluginScanTests: XCTestCase {

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A skill as the app loads one: a subdirectory of `skills` holding a
    /// readable SKILL.md.
    private func makeSkill(_ url: URL) throws {
        try makeDir(url)
        try writeFile(url.appending(path: "SKILL.md"), "---\nname: skill\n---\nbody\n")
    }

    private func writeFile(_ url: URL, _ contents: String) throws {
        try Data(contents.utf8).write(to: url)
    }

    func testNewerDottedVersionBeatsTextOrder() throws {
        let cacheDir = try makeTemporaryDirectory(prefix: "plugin-cache")
        let pluginDir = cacheDir.appending(path: "registry/plugin-a")
        try makeSkill(pluginDir.appending(path: "1.9.0/skills/one"))
        try makeSkill(pluginDir.appending(path: "1.10.0/skills/one"))
        try makeSkill(pluginDir.appending(path: "1.10.0/skills/two"))

        let plugins = PluginManagerView.scanPlugins(cacheDir: cacheDir)

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "1.10.0")
        XCTAssertEqual(plugins.first?.skillCount, 2)
    }

    func testStrayFileBesideVersionsIsNeverChosen() throws {
        let cacheDir = try makeTemporaryDirectory(prefix: "plugin-cache")
        let pluginDir = cacheDir.appending(path: "registry/plugin-a")
        try makeSkill(pluginDir.appending(path: "1.0.0/skills/one"))
        FileManager.default.createFile(
            atPath: pluginDir.appending(path: "9-not-a-version.txt").path(percentEncoded: false),
            contents: Data("not a version".utf8)
        )

        let plugins = PluginManagerView.scanPlugins(cacheDir: cacheDir)

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "1.0.0")
        XCTAssertEqual(plugins.first?.skillCount, 1)
    }

    func testNonNumericVersionsFallBackToTextOrder() throws {
        let cacheDir = try makeTemporaryDirectory(prefix: "plugin-cache")
        let pluginDir = cacheDir.appending(path: "registry/plugin-a")
        try makeSkill(pluginDir.appending(path: "Alpha/skills/one"))
        try makeSkill(pluginDir.appending(path: "beta/skills/one"))
        try makeSkill(pluginDir.appending(path: "beta/skills/two"))

        let plugins = PluginManagerView.scanPlugins(cacheDir: cacheDir)

        // "beta" > "Alpha" under case-insensitive text order, though it sorts
        // before it under plain (case-sensitive) text order.
        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "beta")
        XCTAssertEqual(plugins.first?.skillCount, 2)
    }

    func testNoVersionEntriesReportsUnknown() throws {
        let cacheDir = try makeTemporaryDirectory(prefix: "plugin-cache")
        let pluginDir = cacheDir.appending(path: "registry/plugin-a")
        try makeDir(pluginDir)

        let plugins = PluginManagerView.scanPlugins(cacheDir: cacheDir)

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "unknown")
        XCTAssertEqual(plugins.first?.skillCount, 0)
    }

    func testLooseAndHiddenFilesBesideSkillsAreNotCounted() throws {
        let cacheDir = try makeTemporaryDirectory(prefix: "plugin-cache")
        let skillsDir = cacheDir.appending(path: "registry/plugin-a/1.0.0/skills")
        try makeSkill(skillsDir.appending(path: "one"))
        try makeSkill(skillsDir.appending(path: "two"))
        try writeFile(skillsDir.appending(path: "README.md"), "how to use these skills")
        try writeFile(skillsDir.appending(path: ".DS_Store"), "finder junk")

        let plugins = PluginManagerView.scanPlugins(cacheDir: cacheDir)

        XCTAssertEqual(plugins.first?.skillCount, 2)
    }

    func testSubdirectoryWithoutSkillFileIsNotCounted() throws {
        let cacheDir = try makeTemporaryDirectory(prefix: "plugin-cache")
        let skillsDir = cacheDir.appending(path: "registry/plugin-a/1.0.0/skills")
        try makeSkill(skillsDir.appending(path: "one"))
        try makeDir(skillsDir.appending(path: "assets"))

        let plugins = PluginManagerView.scanPlugins(cacheDir: cacheDir)

        XCTAssertEqual(plugins.first?.skillCount, 1)
    }

    func testVersionWithoutSkillsDirectoryStillAppearsWithZero() throws {
        let cacheDir = try makeTemporaryDirectory(prefix: "plugin-cache")
        try makeDir(cacheDir.appending(path: "registry/plugin-a/1.0.0"))

        let plugins = PluginManagerView.scanPlugins(cacheDir: cacheDir)

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "1.0.0")
        XCTAssertEqual(plugins.first?.skillCount, 0)
    }
}
