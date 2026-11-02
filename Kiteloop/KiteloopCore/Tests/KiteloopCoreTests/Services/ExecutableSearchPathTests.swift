import XCTest
@testable import KiteloopCore

/// `ExecutableSearchPath` is the one search policy every consumer reads. These
/// pin the order it composes — login shell, fixed extras, global setting,
/// project setting — the dedup, the `~` expansion, and that a login shell
/// that fails or hangs falls back rather than taking the first spawn with it.
final class ExecutableSearchPathTests: XCTestCase {

    private let home = "/Users/pat"

    // MARK: - Composition

    func testLoginPathComesFirstThenFixedExtrasThenGlobalThenProject() {
        let resolved = ExecutableSearchPath.compose(
            loginPath: "/usr/bin:/bin", home: home,
            globalExtras: ["/opt/global/bin"], projectExtras: ["/srv/project/bin"])

        XCTAssertEqual(resolved.directories,
                       ["/usr/bin", "/bin"] + ExecutableSearchPath.fixedExtras(home: home)
                           + ["/opt/global/bin", "/srv/project/bin"])
        XCTAssertEqual(resolved.joined, resolved.directories.joined(separator: ":"))
    }

    func testFixedExtrasReachCargoAndTheRestOfTheUsualToolchainHomes() {
        let extras = ExecutableSearchPath.fixedExtras(home: home)

        for expected in ["/opt/homebrew/bin", "/usr/local/bin", "/Users/pat/.local/bin",
                         "/Users/pat/.npm/bin", "/Users/pat/.cargo/bin"] {
            XCTAssertTrue(extras.contains(expected), "\(expected) missing from \(extras)")
        }
        // A prior copy wrote `\(home).local/bin`, a sibling of the home directory.
        XCTAssertFalse(extras.contains { $0.contains("/Users/pat.") })
    }

    func testADirectoryIsKeptOnceAtItsFirstOccurrence() {
        let resolved = ExecutableSearchPath.compose(
            loginPath: "/opt/homebrew/bin:/usr/bin:/usr/bin", home: home,
            globalExtras: ["/usr/local/bin", "/opt/tools"], projectExtras: ["/opt/tools"])

        XCTAssertEqual(resolved.directories.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertEqual(resolved.directories.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertEqual(resolved.directories.filter { $0 == "/opt/tools" }.count, 1)
        XCTAssertEqual(resolved.directories.first, "/opt/homebrew/bin", "first occurrence wins")
    }

    func testSettingsEntriesExpandTildeAgainstHome() {
        let resolved = ExecutableSearchPath.compose(
            loginPath: "/usr/bin", home: home,
            globalExtras: ["~/tools/bin", "~"], projectExtras: ["~/.venv/bin", "/abs/bin"])

        XCTAssertTrue(resolved.directories.contains("/Users/pat/tools/bin"))
        XCTAssertTrue(resolved.directories.contains("/Users/pat"))
        XCTAssertTrue(resolved.directories.contains("/Users/pat/.venv/bin"))
        XCTAssertTrue(resolved.directories.contains("/abs/bin"))
        XCTAssertFalse(resolved.directories.contains { $0.hasPrefix("~") })
    }

    func testEmptyEntriesAreDropped() {
        let resolved = ExecutableSearchPath.compose(
            loginPath: "/usr/bin::/bin", home: home, globalExtras: [""], projectExtras: [])

        XCTAssertFalse(resolved.directories.contains(""))
    }

    func testNoLoginPathFallsBackToTheStandardSystemPath() {
        let resolved = ExecutableSearchPath.compose(
            loginPath: nil, home: home, globalExtras: [], projectExtras: [])

        XCTAssertEqual(Array(resolved.directories.prefix(4)), ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    }

    // MARK: - The login shell capture

    func testTheLoginShellsPathIsWhatItPrinted() async {
        let runner = ScriptedSubprocessRunner { _ in .init(output: "/Users/pat/.cargo/bin:/usr/bin\n") }

        let captured = await withScriptedSubprocesses(runner) {
            ExecutableSearchPath.captureLoginShellPath(fallback: "/fallback")
        }

        XCTAssertEqual(captured, "/Users/pat/.cargo/bin:/usr/bin")
        let call = runner.calls.first
        XCTAssertEqual(call?.executable, "/bin/zsh")
        XCTAssertEqual(call?.arguments.first, "-lc")
        XCTAssertEqual(call?.timeout, ExecutableSearchPath.loginShellTimeout)
    }

    func testAFailingLoginShellFallsBackToTheAppsOwnPath() async {
        let runner = ScriptedSubprocessRunner { _ in .init(status: 1, output: "zprofile: command not found") }

        let captured = await withScriptedSubprocesses(runner) {
            ExecutableSearchPath.captureLoginShellPath(fallback: "/usr/bin:/bin")
        }

        XCTAssertEqual(captured, "/usr/bin:/bin")
    }

    func testALoginShellThatHangsIsAbandonedForTheFallback() async {
        let runner = ScriptedSubprocessRunner { _ in .init(timedOut: true) }

        let captured = await withScriptedSubprocesses(runner) {
            ExecutableSearchPath.captureLoginShellPath(fallback: "/usr/bin:/bin")
        }

        XCTAssertEqual(captured, "/usr/bin:/bin")
    }

    func testALoginShellThatCannotSpawnWithNoFallbackGivesTheStandardPath() async {
        let runner = ScriptedSubprocessRunner { _ in .init(spawnFails: true) }

        let captured = await withScriptedSubprocesses(runner) {
            ExecutableSearchPath.captureLoginShellPath(fallback: nil)
        }

        XCTAssertEqual(captured, ExecutableSearchPath.standardSystemPath)
    }

    // MARK: - The live policy

    func testAProjectsOwnExtraPathsAreAppendedFromItsConfig() throws {
        let root = try makeTemporaryDirectory(prefix: "search-path-project")
        let project = KiteloopProject(rootURL: root)
        try project.ensureKiteloopDirectory()
        var config = ProjectConfig.default
        config.extraExecutablePaths = ["/srv/project-tools/bin"]
        try project.saveConfig(config)

        let resolved = ExecutableSearchPath.resolved(projectRoot: root)

        XCTAssertEqual(resolved.directories.last, "/srv/project-tools/bin")
        XCTAssertTrue(resolved.directories.contains("/opt/homebrew/bin"))
    }

    func testAWorktreeSpawnReadsTheProjectAboveIt() {
        let worktree = URL(fileURLWithPath: "/repo/app/.kiteloop/worktrees/item-1", isDirectory: true)

        XCTAssertEqual(ExecutableSearchPath.projectRoot(enclosing: worktree).path(percentEncoded: false),
                       "/repo/app")
        let plain = URL(fileURLWithPath: "/repo/app", isDirectory: true)
        XCTAssertEqual(ExecutableSearchPath.projectRoot(enclosing: plain), plain)
    }
}
