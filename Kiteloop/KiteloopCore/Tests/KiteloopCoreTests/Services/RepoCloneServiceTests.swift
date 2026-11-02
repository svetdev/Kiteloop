import XCTest
@testable import KiteloopCore

/// `RepoCloneService.runGit` used to inherit stdin from the app and wait on
/// its child with no deadline: a `git` that stopped to ask a question — an
/// unknown host key, a passphrase — had nothing to answer it and nothing to
/// time it out, so the wizard sat at "Cloning…" forever while
/// `cloneIfNeeded` never reached the next repo. These assert the fix: no
/// prompt can be asked (`makeGitProcess`), a child that asks one anyway is
/// killed along with anything it forked (`runGit` against a real hanging
/// process, the way `ProcessTreeTests` drives one), and `clone(repo:org:)`
/// turns that into a `.failed` status naming the timeout instead of leaving
/// the repo stuck at `.cloning`.
final class RepoCloneServiceTests: XCTestCase {

    // MARK: - No prompt can be asked

    /// What `runGit` hands the runner, read off the runner rather than off a
    /// child: the prompt is disabled in the environment, and the arguments and
    /// deadline arrive whole. EOF on stdin is the live runner's own guarantee,
    /// asserted in `SubprocessOutputTests`.
    @MainActor
    func testPromptsAreDisabledAndTheCallReachesTheRunnerWhole() async {
        let runner = ScriptedSubprocessRunner()
        let outcome = await withScriptedSubprocesses(runner) {
            await RepoCloneService().runGit(
                arguments: ["clone", "--filter=blob:none", "git@github.com:org/repo.git", "/tmp/dest"],
                executable: "/usr/bin/git",
                timeout: 7
            )
        }
        XCTAssertEqual(outcome, .success)
        let call = runner.calls.first
        XCTAssertEqual(call?.executable, "/usr/bin/git")
        XCTAssertEqual(call?.arguments, ["clone", "--filter=blob:none", "git@github.com:org/repo.git", "/tmp/dest"])
        XCTAssertEqual(call?.environment?["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(call?.timeout, 7)
    }

    /// The outcome is read off what the runner reports — a refusal and a kill
    /// past the deadline are different words in front of the wizard.
    @MainActor
    func testOutcomesFollowTheRunnersReport() async {
        let refused = ScriptedSubprocessRunner { _ in .init(status: 128) }
        let killed = ScriptedSubprocessRunner { _ in .init(timedOut: true) }
        let service = RepoCloneService()
        let a = await withScriptedSubprocesses(refused) { await service.runGit(arguments: ["fetch"]) }
        let b = await withScriptedSubprocesses(killed) { await service.runGit(arguments: ["fetch"]) }
        XCTAssertEqual(a, .failed)
        XCTAssertEqual(b, .timedOut)
    }

    // MARK: - A timed-out child is killed, runGit does not block

    /// Mirrors `ProcessTreeTests`: a root spawned as `/bin/zsh -lc "sleep … &
    /// wait"` forks `sleep` as its own child, which TERM/KILL on the shell
    /// alone would leave running and reparented. `runGit` must collect and
    /// sweep that descendant, and must not block past `timeout` doing it.
    @MainActor
    func testATimedOutChildAndItsForkedDescendantAreKilledAndRunGitDoesNotBlock() async {
        let service = RepoCloneService()
        let start = Date()
        let outcome = await service.runGit(
            arguments: ["-lc", "sleep 810301 & wait"],
            executable: "/bin/zsh",
            timeout: 0.3
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(elapsed, 2, "runGit must answer promptly rather than blocking on the hung child")
        XCTAssertFalse(isProcessRunning(matching: "sleep 810301"),
                        "the forked child must not survive runGit returning")
    }

    /// A command that exits promptly and successfully still reports success —
    /// the fix must not turn every clone into a failure.
    @MainActor
    func testACommandThatExitsPromptlyReportsSuccessTruthfully() async {
        let service = RepoCloneService()
        let outcome = await service.runGit(arguments: [], executable: "/usr/bin/true", timeout: 5)
        XCTAssertEqual(outcome, .success)
    }

    /// A command that exits promptly but fails is reported as failed, not
    /// timed out — the timeout wording is reserved for a child actually
    /// killed past the deadline.
    @MainActor
    func testACommandThatExitsPromptlyButFailsIsReportedFailedNotTimedOut() async {
        let service = RepoCloneService()
        let outcome = await service.runGit(arguments: [], executable: "/usr/bin/false", timeout: 5)
        XCTAssertEqual(outcome, .failed)
    }

    // MARK: - clone(repo:org:) turns a timeout into a truthful, terminal status

    /// The scenario the item is named for: a clone whose child hangs must not
    /// leave the repo at `.cloning` forever. `gitExecutable` points at a
    /// script that ignores its arguments (the real clone arguments are not a
    /// valid invocation of anything that sleeps) and forks a child that
    /// outlives a short timeout; `clone` must resolve to `.failed` naming the
    /// timeout, not stay `.cloning`.
    @MainActor
    func testACloneWhoseChildHangsBecomesFailedNamingTheTimeoutRatherThanStayingCloning() async throws {
        let service = RepoCloneService()
        let orgName = "kiteloop-test-repoclone-\(UUID().uuidString)"
        service.orgName = orgName
        defer { try? FileManager.default.removeItem(at: KiteloopProject.workspacesDir(orgName: orgName)) }

        let script = try makeHangingScript()
        defer { try? FileManager.default.removeItem(at: script) }

        await service.clone(repo: "repo", org: "org", gitExecutable: script.path(percentEncoded: false), timeout: 0.3)

        guard case .failed(let message) = service.statuses["repo"] else {
            XCTFail("expected .failed, got \(String(describing: service.statuses["repo"]))")
            return
        }
        XCTAssertTrue(message.lowercased().contains("time"), "the status text must name the timeout: \(message)")
    }

    /// The ordinary success path is unchanged: a clone whose child exits
    /// promptly and successfully ends `.cloned`.
    @MainActor
    func testACloneWhoseChildSucceedsBecomesCloned() async {
        let service = RepoCloneService()
        let orgName = "kiteloop-test-repoclone-\(UUID().uuidString)"
        service.orgName = orgName
        defer { try? FileManager.default.removeItem(at: KiteloopProject.workspacesDir(orgName: orgName)) }

        await service.clone(repo: "repo", org: "org", gitExecutable: "/usr/bin/true", timeout: 5)

        guard case .cloned = service.statuses["repo"] else {
            XCTFail("expected .cloned, got \(String(describing: service.statuses["repo"]))")
            return
        }
    }

    // MARK: - Helpers

    /// A script that forks a long sleep and waits on it, ignoring whatever
    /// arguments it's invoked with — the real clone arguments (`clone
    /// --filter=blob:none <url> <dest>`) are not a valid invocation of
    /// anything that hangs on its own, so a genuine hang needs a stand-in
    /// executable rather than a stand-in argument.
    private func makeHangingScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kiteloop-repoclone-hang-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 810302 &\nwait\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    /// True while some process anywhere on the machine has `pattern` in its
    /// command line — used to check a forked child is actually gone, not just
    /// the process that forked it.
    private func isProcessRunning(matching pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
