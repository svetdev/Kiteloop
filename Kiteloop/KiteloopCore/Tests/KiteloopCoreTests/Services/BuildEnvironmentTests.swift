import XCTest
@testable import KiteloopCore

/// `BuildEnvironment` is what a project exports into every verify shell and
/// agent spawn on its behalf so build output is shared across item worktrees
/// — the fix for a Rust project's items each paying a cold `cargo build` on
/// 2026-09-03. These pin the derivation from marker files, that the config
/// map wins over it, the `~` and `$PROJECT_ROOT` expansion, that `PATH` is not
/// settable through it, and that `RunEnvironment` lays the exports beside the
/// composed `PATH`.
final class BuildEnvironmentTests: XCTestCase {

    private let home = "/Users/pat"
    private let root = URL(fileURLWithPath: "/repo/app", isDirectory: false)

    // MARK: - Derivation from markers

    func testACargoTomlSharesOneTargetDirectoryUnderTheProjectRoot() {
        let exports = BuildEnvironment.compose(projectRoot: root, markers: ["Cargo.toml"], explicit: [:], home: home)

        XCTAssertEqual(exports, [.init(name: "CARGO_TARGET_DIR", value: "/repo/app/.kiteloop/build/cargo")])
    }

    func testAPackageJsonSharesOneNpmCacheUnderTheProjectRoot() {
        let exports = BuildEnvironment.compose(projectRoot: root, markers: ["package.json"], explicit: [:], home: home)

        XCTAssertEqual(exports, [.init(name: "npm_config_cache", value: "/repo/app/.kiteloop/build/npm")])
    }

    func testNoMarkerAndNoMapExportsNothing() {
        XCTAssertEqual(BuildEnvironment.compose(projectRoot: root, markers: [], explicit: [:], home: home), [])
        XCTAssertEqual(BuildEnvironment.compose(projectRoot: root, markers: ["Makefile"], explicit: [:], home: home), [])
    }

    /// A root URL built with `isDirectory: true` carries a trailing slash in
    /// `path()`; the derived value must not read `root//.kiteloop`.
    func testADirectoryRootURLDerivesTheSamePath() {
        let slashed = URL(fileURLWithPath: "/repo/app", isDirectory: true)

        let exports = BuildEnvironment.compose(projectRoot: slashed, markers: ["Cargo.toml"], explicit: [:], home: home)

        XCTAssertEqual(exports.first?.value, "/repo/app/.kiteloop/build/cargo")
    }

    // MARK: - The explicit map

    func testAnExplicitEntryWinsOverTheDerivedOne() {
        let exports = BuildEnvironment.compose(
            projectRoot: root, markers: ["Cargo.toml"],
            explicit: ["CARGO_TARGET_DIR": "/mnt/fast/target"], home: home)

        XCTAssertEqual(exports, [.init(name: "CARGO_TARGET_DIR", value: "/mnt/fast/target")])
    }

    func testExplicitValuesExpandTildeAndTheProjectRootPlaceholder() {
        let exports = BuildEnvironment.compose(
            projectRoot: root, markers: [],
            explicit: ["SCCACHE_DIR": "~/.cache/sccache", "CARGO_TARGET_DIR": "$PROJECT_ROOT/../shared-target"],
            home: home)

        XCTAssertEqual(exports, [
            .init(name: "CARGO_TARGET_DIR", value: "/repo/app/../shared-target"),
            .init(name: "SCCACHE_DIR", value: "/Users/pat/.cache/sccache"),
        ])
    }

    /// The search path is one policy (`ExecutableSearchPath`); a map entry
    /// naming `PATH` is dropped rather than letting a config split it in two.
    func testAPathEntryInTheMapIsIgnored() {
        let exports = BuildEnvironment.compose(
            projectRoot: root, markers: ["Cargo.toml"],
            explicit: ["PATH": "/evil/bin", "RUSTFLAGS": "-C debuginfo=0"], home: home)

        XCTAssertEqual(exports.map(\.name), ["CARGO_TARGET_DIR", "RUSTFLAGS"])
    }

    func testExportsAreSortedByName() {
        let exports = BuildEnvironment.compose(
            projectRoot: root, markers: ["package.json", "Cargo.toml"],
            explicit: ["ZZZ": "1", "AAA": "2"], home: home)

        XCTAssertEqual(exports.map(\.name), ["AAA", "CARGO_TARGET_DIR", "ZZZ", "npm_config_cache"])
    }

    // MARK: - The live policy

    func testResolvedReadsTheMarkersAndTheConfigFromTheTree() throws {
        let projectRoot = try makeTemporaryDirectory(prefix: "build-environment")
        try "[package]\n".write(to: projectRoot.appending(path: "Cargo.toml"), atomically: true, encoding: .utf8)
        let project = KiteloopProject(rootURL: projectRoot)
        try project.ensureKiteloopDirectory()
        var config = ProjectConfig.default
        config.buildEnvironment = ["RUSTFLAGS": "-C debuginfo=0"]
        try project.saveConfig(config)

        let exports = BuildEnvironment.resolved(projectRoot: projectRoot)

        XCTAssertEqual(exports, [
            .init(name: "CARGO_TARGET_DIR", value: projectRoot.appending(path: ".kiteloop/build/cargo").path(percentEncoded: false)),
            .init(name: "RUSTFLAGS", value: "-C debuginfo=0"),
        ])
    }

    /// An old `config.json` without the map still decodes, and decodes to
    /// "the project adds nothing".
    func testAConfigWithoutTheMapDecodesToNil() throws {
        let data = Data(#"{"permissionMode":"acceptEdits","autoApprovedTools":[],"deniedTools":[]}"#.utf8)

        let config = try JSONDecoder().decode(ProjectConfig.self, from: data)

        XCTAssertNil(config.buildEnvironment)
    }

    // MARK: - RunEnvironment: PATH and the exports together

    func testTheComposedEnvironmentCarriesBothThePathAndTheExports() throws {
        let projectRoot = try makeTemporaryDirectory(prefix: "run-environment")
        try "{}\n".write(to: projectRoot.appending(path: "package.json"), atomically: true, encoding: .utf8)

        let env = RunEnvironment.environment(projectRoot: projectRoot, base: ["HOME": home, "PATH": "/thin"])

        XCTAssertEqual(env["HOME"], home, "the base is kept")
        XCTAssertEqual(env["PATH"], ExecutableSearchPath.resolved(projectRoot: projectRoot).joined)
        XCTAssertNotEqual(env["PATH"], "/thin")
        XCTAssertEqual(env["npm_config_cache"], projectRoot.appending(path: ".kiteloop/build/npm").path(percentEncoded: false))
    }

    func testNoProjectGetsThePathAlone() {
        let overlay = RunEnvironment.overlay(projectRoot: nil)

        XCTAssertEqual(Array(overlay.keys), ["PATH"])
        XCTAssertEqual(overlay["PATH"], ExecutableSearchPath.resolved(projectRoot: nil).joined)
    }

    /// The shape the runtime is handed: a spawn in an item's worktree reads the
    /// project above it, markers included.
    func testAWorktreeSpawnGetsTheProjectsExports() throws {
        let projectRoot = try makeTemporaryDirectory(prefix: "run-environment-worktree")
        try "[package]\n".write(to: projectRoot.appending(path: "Cargo.toml"), atomically: true, encoding: .utf8)
        let worktree = projectRoot.appending(path: ".kiteloop/worktrees/item-1")

        let overlay = RunEnvironment.overlay(forWorkingDirectory: worktree)

        XCTAssertEqual(overlay["CARGO_TARGET_DIR"], projectRoot.appending(path: ".kiteloop/build/cargo").path(percentEncoded: false))
        XCTAssertNotNil(overlay["PATH"])
    }
}
