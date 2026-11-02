import XCTest
@testable import Kiteloop

/// `PluginManagerView.installPlugin` used to spawn `/usr/bin/env claude` inline —
/// the one `claude` spawn in the app that skipped `CLIResolver`, so it failed on
/// the minimal PATH a GUI app inherits from Finder and ignored an operator's
/// `claudePath` override — with no deadline and no way to cancel a hang. These
/// cases drive `runInstall`, the extracted static runner, directly: the deadline
/// arm (mirroring `GitIntegrationViewRunnerTests`) and the unresolvable-CLI arm
/// this view now has that `GitIntegrationView.runGit` does not.
final class PluginManagerViewRunnerTests: XCTestCase {

    /// The defect this item exists for: a child that never exits must be
    /// abandoned at the deadline rather than parking the caller forever. Driven
    /// through the injectable `executable` with a stub that sleeps far longer
    /// than the deadline, so the call returning at all — well inside this test's
    /// own timeout — proves the deadline fired.
    func testRunInstall_AbandonsAChildThatOutlivesItsDeadline() {
        let started = Date()

        let result = PluginManagerView.runInstall(
            ["-c", "sleep 810601"],
            executable: "/bin/sh",
            timeout: 1
        )

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.timedOut)
        // The stub would have slept for over a week: coming back near the
        // deadline proves the wait was bounded rather than the child exiting.
        XCTAssertLessThan(elapsed, 15)
    }

    /// A well-behaved child still reports its real status and output through the
    /// deadline path.
    func testRunInstall_SuccessfulCommandReturnsItsOutput() {
        let result = PluginManagerView.runInstall(
            ["-c", "echo installed"],
            executable: "/bin/sh",
            timeout: 5
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.output.contains("installed"))
    }

    /// No usable Claude CLI resolved: the runner must report a failure naming the
    /// setting to fix and must never reach `Process` — proven by returning
    /// immediately rather than waiting anywhere near `timeout`.
    func testRunInstall_UnresolvableCLIReturnsSettingNamingMessageWithoutSpawning() {
        let started = Date()

        let result = PluginManagerView.runInstall(
            PluginManagerView.installArguments(for: "plugin@marketplace"),
            executable: nil,
            timeout: 30
        )

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("Claude CLI"))
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("Settings"))
        // A spawn that respected the 30s timeout would still take a moment; an
        // instant return is only possible if `Process` was never touched.
        XCTAssertLessThan(elapsed, 1)
    }

    /// Install runs the CLI's real `plugin install` subcommand — the app once
    /// passed a slash-commands option and `/install`, which the CLI does not
    /// have, so every install failed.
    func testInstallArguments_RunThePluginInstallSubcommand() {
        XCTAssertEqual(
            PluginManagerView.installArguments(for: "foo@bar"),
            ["plugin", "install", "foo@bar"]
        )
    }
}

/// `removePlugins` used to delete unconditionally and drop every selected row
/// from the list regardless of whether `FileManager.removeItem` actually
/// succeeded — a plugin the app could not delete (a permission it lacks on
/// `~/.claude/plugins/cache`, a file held open, a read-only volume) vanished
/// from the panel while still installed and still loaded by every agent. These
/// cases drive the extracted static `removePlugins(_:at:removeItem:)` directly
/// with an injected `removeItem` closure, mirroring `PluginManagerViewRunnerTests`.
final class PluginManagerViewRemovalTests: XCTestCase {
    private func plugin(_ name: String) -> InstalledPlugin {
        InstalledPlugin(
            registry: "registry",
            name: name,
            version: "1.0.0",
            skillCount: 1,
            path: URL(fileURLWithPath: "/tmp/\(name)")
        )
    }

    /// A plugin whose removal throws stays in the kept list, and the failure
    /// message names it and the underlying error.
    func testRemovePlugins_FailedRemovalStaysInTheListAndIsNamed() {
        let a = plugin("a")
        struct RemovalError: Error, LocalizedError {
            var errorDescription: String? { "permission denied" }
        }

        let result = PluginManagerView.removePlugins([a], at: IndexSet(integer: 0)) { _ in
            throw RemovalError()
        }

        XCTAssertEqual(result.kept.map(\.name), ["a"])
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.failureMessage!.contains("Error"))
        XCTAssertTrue(result.failureMessage!.contains("a"))
        XCTAssertTrue(result.failureMessage!.contains("permission denied"))
    }

    /// A removal that succeeds still drops its row, exactly as before, and
    /// reports no failure.
    func testRemovePlugins_SuccessfulRemovalDropsItsRow() {
        let a = plugin("a")
        var removed: [URL] = []

        let result = PluginManagerView.removePlugins([a], at: IndexSet(integer: 0)) { url in
            removed.append(url)
        }

        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(removed, [a.path])
    }

    /// Several rows deleted at once with one failing: only the ones actually
    /// deleted are dropped, and the failing one is named without disturbing the
    /// others.
    func testRemovePlugins_MixedBatchKeepsOnlyTheFailure() {
        let a = plugin("a")
        let b = plugin("b")
        let c = plugin("c")
        struct RemovalError: Error, LocalizedError {
            var errorDescription: String? { "in use" }
        }

        let result = PluginManagerView.removePlugins([a, b, c], at: IndexSet([0, 1, 2])) { url in
            if url.lastPathComponent == "b" {
                throw RemovalError()
            }
        }

        XCTAssertEqual(result.kept.map(\.name), ["b"])
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.failureMessage!.contains("b"))
        XCTAssertTrue(result.failureMessage!.contains("in use"))
        XCTAssertFalse(result.failureMessage!.contains("a ("))
        XCTAssertFalse(result.failureMessage!.contains("c ("))
    }

    /// No failures at all: the message is nil, exactly as the pre-existing
    /// behaviour with nothing to report.
    func testRemovePlugins_AllSucceedReportsNoMessage() {
        let a = plugin("a")
        let b = plugin("b")

        let result = PluginManagerView.removePlugins([a, b], at: IndexSet([0, 1])) { _ in }

        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertNil(result.failureMessage)
    }
}
