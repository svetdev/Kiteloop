import XCTest
@testable import KiteloopCore

/// Where skills are looked for, in order: the user's own, every installed
/// plugin's newest version, and the project's when it has one — walked over a
/// home directory each case builds, so the plugin cache is the case's and not
/// this machine's.
final class SkillRegistryScanPathsTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = try makeTemporaryDirectory(prefix: "skills-home")
    }

    private func plugin(_ registry: String, _ name: String, versions: [String]) throws {
        for version in versions {
            let dir = home.appending(path: ".claude/plugins/cache/\(registry)/\(name)/\(version)/skills")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Each path with the temporary home spelled `~`; symlinks resolved on both sides,
    /// since the directory walk answers in `/private/var` for a home made under `/var`.
    private func paths(project: URL? = nil) -> [String] {
        let root = home.resolvingSymlinksInPath().path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return SkillRegistry.defaultScanPaths(projectSkillsURL: project, home: home).map {
            var path = $0.resolvingSymlinksInPath().path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path.replacingOccurrences(of: "/" + root, with: "~")
        }
    }

    func testTheUsersOwnSkillsComeFirstEvenWithNoPluginCache() {
        XCTAssertEqual(paths(), ["~/.claude/skills"])
    }

    func testEachPluginContributesItsNewestVersionsSkills() throws {
        try plugin("community", "linter", versions: ["1.0.0", "1.2.0", "1.10.0"])
        try plugin("community", "deploy", versions: ["0.3.0"])
        XCTAssertEqual(Set(paths()), ["~/.claude/skills",
                                      "~/.claude/plugins/cache/community/linter/1.10.0/skills",
                                      "~/.claude/plugins/cache/community/deploy/0.3.0/skills"],
                       "one path per plugin, at its newest version")
    }

    func testPluginsAcrossRegistriesAreAllScanned() throws {
        try plugin("community", "a", versions: ["1.0.0"])
        try plugin("private", "b", versions: ["2.0.0"])
        XCTAssertEqual(paths().count, 3)
    }

    func testHiddenEntriesInTheCacheAreSkipped() throws {
        try plugin("community", "a", versions: ["1.0.0"])
        try FileManager.default.createDirectory(at: home.appending(path: ".claude/plugins/cache/.DS_Store-like/x/1.0.0/skills"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(paths().count, 2)
    }

    func testAPluginWithNoVersionDirectoryContributesNothing() throws {
        try FileManager.default.createDirectory(at: home.appending(path: ".claude/plugins/cache/community/empty"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(paths(), ["~/.claude/skills"])
    }

    func testTheProjectsSkillsComeLast() throws {
        try plugin("community", "a", versions: ["1.0.0"])
        let project = URL(fileURLWithPath: "/tmp/some-project/.claude/skills")
        let with = SkillRegistry.defaultScanPaths(projectSkillsURL: project, home: home)
        XCTAssertEqual(with.last, project)
        XCTAssertEqual(with.count, 3)
    }
}
