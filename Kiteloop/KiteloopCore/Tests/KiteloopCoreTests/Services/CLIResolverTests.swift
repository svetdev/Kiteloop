import XCTest
@testable import KiteloopCore

/// `resolve(globalConfig:)` decides which `claude` and `node` binary the app
/// spawns and which path Settings reports. A configured override that is not
/// honoured means the app silently runs a different binary than the one the user
/// pointed it at; an override honoured too eagerly — one that no longer exists,
/// or was never executable — means it fails to launch anything at all instead of
/// falling back to the copy on PATH.
final class CLIResolverTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "cli-resolver")
    }

    /// The fallback both statics hold. Asserting against it rather than against a
    /// literal keeps these cases honest on a machine with no `claude` installed,
    /// where the right answer is nil.
    private var fallbackClaude: String? { CLIResolver.claude }
    private var fallbackNode: String? { CLIResolver.node }

    private func makeExecutable(named name: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url.path(percentEncoded: false)
    }

    private func makeNonExecutable(named name: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try Data("not a program".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false))
        return url.path(percentEncoded: false)
    }

    // MARK: - An executable override is honoured

    func testExecutableClaudeOverrideIsUsed() throws {
        let path = try makeExecutable(named: "claude")
        var config = GlobalConfig()
        config.claudePath = path

        XCTAssertEqual(CLIResolver.resolve(globalConfig: config).claude, path)
    }

    func testExecutableNodeOverrideIsUsed() throws {
        let path = try makeExecutable(named: "node")
        var config = GlobalConfig()
        config.nodePath = path

        XCTAssertEqual(CLIResolver.resolve(globalConfig: config).node, path)
    }

    /// The two overrides are read independently: pointing one at a binary must
    /// not drag the other off its own resolution.
    func testOverridingOneLeavesTheOtherOnItsFallback() throws {
        let path = try makeExecutable(named: "claude")
        var config = GlobalConfig()
        config.claudePath = path

        let resolved = CLIResolver.resolve(globalConfig: config)

        XCTAssertEqual(resolved.claude, path)
        XCTAssertEqual(resolved.node, fallbackNode)
    }

    // MARK: - An unusable override is ignored

    func testNonExecutableOverrideFallsBack() throws {
        var config = GlobalConfig()
        config.claudePath = try makeNonExecutable(named: "claude")
        config.nodePath = try makeNonExecutable(named: "node")

        let resolved = CLIResolver.resolve(globalConfig: config)

        XCTAssertEqual(resolved.claude, fallbackClaude)
        XCTAssertEqual(resolved.node, fallbackNode)
    }

    func testOverrideNamingNothingOnDiskFallsBack() {
        var config = GlobalConfig()
        config.claudePath = tempDir.appendingPathComponent("no-such-claude").path(percentEncoded: false)
        config.nodePath = tempDir.appendingPathComponent("no-such-node").path(percentEncoded: false)

        let resolved = CLIResolver.resolve(globalConfig: config)

        XCTAssertEqual(resolved.claude, fallbackClaude)
        XCTAssertEqual(resolved.node, fallbackNode)
    }

    /// An empty string is what a settings field cleared by hand leaves behind —
    /// it means "nothing configured", not "run the binary at ''".
    func testEmptyOverrideFallsBack() {
        var config = GlobalConfig()
        config.claudePath = ""
        config.nodePath = ""

        let resolved = CLIResolver.resolve(globalConfig: config)

        XCTAssertEqual(resolved.claude, fallbackClaude)
        XCTAssertEqual(resolved.node, fallbackNode)
    }

    // MARK: - No override at all

    func testNilOverrideResolvesTheSameAsTheStatics() {
        let resolved = CLIResolver.resolve(globalConfig: GlobalConfig())

        XCTAssertNil(GlobalConfig().claudePath, "a default config configures no path — the case this asserts")
        XCTAssertEqual(resolved.claude, fallbackClaude)
        XCTAssertEqual(resolved.node, fallbackNode)
    }
}
