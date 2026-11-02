import XCTest
@testable import KiteloopCore

/// Against real child processes, because the defect this helper exists to
/// prevent lives in the kernel's pipe buffer — a fake `Process` cannot fill one,
/// so it cannot deadlock, so it would assert nothing.
final class SubprocessOutputTests: XCTestCase {

    /// Comfortably past the ~64 KB pipe buffer, so a stream nobody drains blocks
    /// the child rather than merely fitting.
    private static let floodBytes = 200_000

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = try makeTemporaryDirectory(prefix: "subprocess-output")
    }

    /// The defect: an undrained stderr pipe wedges the child, `waitUntilExit()`
    /// never returns, and the caller's thread is stranded for ever. Run on a
    /// background queue behind an expectation so a regression fails the test
    /// instead of hanging the suite.
    func testAChildFloodingStderrStillReportsItsExitStatus() throws {
        let script = try writeFloodScript(stream: "2", exitCode: 3)

        let finished = expectation(description: "the flooding child was waited on")
        let box = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = try? SubprocessOutput.run(executable: "/bin/sh", arguments: [script])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)

        XCTAssertEqual(box.value?.status, 3)
    }

    /// Draining before the wait is only half of it: the payload has to come back
    /// whole. A read that stopped at the first buffer-full would return ~64 KB of
    /// a 200 KB write and every caller would parse the truncation silently.
    func testStdoutLargerThanThePipeBufferComesBackWhole() throws {
        let script = try writeFloodScript(stream: "1", exitCode: 0)

        let finished = expectation(description: "the whole payload was read")
        let box = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = try? SubprocessOutput.run(executable: "/bin/sh", arguments: [script])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)

        XCTAssertEqual(box.value?.status, 0)
        XCTAssertEqual(box.value?.standardOutput.count, Self.floodBytes)
        XCTAssertEqual(box.value?.standardOutput, Data(repeating: UInt8(ascii: "x"), count: Self.floodBytes))
    }

    func testStdoutIsReturnedTrimmedForParsing() throws {
        let result = try SubprocessOutput.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '  1.2.3 \\n'"]
        )

        XCTAssertEqual(result.trimmedOutput, "1.2.3")
    }

    func testAFailingChildReportsItsNonZeroStatus() throws {
        let result = try SubprocessOutput.run(executable: "/bin/sh", arguments: ["-c", "exit 7"])

        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.standardOutput.isEmpty)
    }

    /// The environment is handed to the child rather than dropped — how
    /// `fetchGitHubRepoSize` gets `gh` onto PATH.
    func testTheGivenEnvironmentReachesTheChild() throws {
        let result = try SubprocessOutput.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$KITELOOP_TEST_MARKER\""],
            environment: ["KITELOOP_TEST_MARKER": "reached"]
        )

        XCTAssertEqual(result.trimmedOutput, "reached")
    }

    /// `run` has no deadline behind it, so a child that stopped to ask for a
    /// credential — git wanting one, an askpass, a shim that prompts — would
    /// otherwise sit on whatever stdin it inherited, the app's own, for ever. It
    /// must inherit the null device instead and read EOF.
    func testRunGivesTheChildTheNullDeviceAsStandardInput() throws {
        // `-ef` compares device and inode, so this says *which* file fd 0 is,
        // not merely that reading it ends at once.
        let probe = "if [ /dev/fd/0 -ef /dev/null ]; then printf nulldev; else printf other; fi"

        let result = try SubprocessOutput.run(executable: "/bin/sh", arguments: ["-c", probe])

        XCTAssertEqual(result.trimmedOutput, "nulldev")
    }

    /// A missing executable throws rather than reading as a child that ran and
    /// said nothing — the callers decide what that means.
    func testAMissingExecutableThrows() {
        XCTAssertThrowsError(
            try SubprocessOutput.run(
                executable: dir.appendingPathComponent("not-a-binary").path(percentEncoded: false),
                arguments: []
            )
        )
    }

    // MARK: - git

    /// Against a real repository, because the readings the three call sites
    /// branch on are git's own: `rev-parse --verify --quiet` answering 1 for a
    /// branch that isn't there is not something a stub could be trusted to
    /// reproduce.
    func testGitReportsItsExitStatusAndStdout() throws {
        let repo = try makeRepo()

        let present = SubprocessOutput.git(
            ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/kept"])
        XCTAssertEqual(present.status, 0)
        XCTAssertEqual(present.output.trimmingCharacters(in: .whitespacesAndNewlines).count, 40)

        // 1, not 128: git answered, and the ref isn't there. `ItemGitTruth`
        // reads .absent off exactly this and .unreadable off anything else.
        let absent = SubprocessOutput.git(
            ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/never-existed"])
        XCTAssertEqual(absent.status, 1)
        XCTAssertEqual(absent.output, "")
    }

    /// Verbatim stdout, not trimmed: the callers split it into lines and trim
    /// the pieces themselves, and a helper that trimmed first would drop the
    /// trailing newline every one of those splits relies on being there.
    func testGitReturnsStdoutVerbatim() throws {
        let repo = try makeRepo()

        let counted = SubprocessOutput.git(["-C", repo, "rev-list", "--count", "kept", "^HEAD"])

        XCTAssertEqual(counted.status, 0)
        XCTAssertEqual(counted.output, "1\n")
    }

    /// stderr goes to the null device rather than into the returned text. A git
    /// that complains would otherwise land its complaint where the caller parses
    /// an answer — `RunWorkEvidence` reads `fsck --dangling` line by line, and
    /// git writes its progress to stderr.
    func testGitDoesNotFoldStderrIntoItsOutput() throws {
        let repo = try makeRepo()

        // No such object, so git prints a fatal to stderr and nothing to stdout.
        let result = SubprocessOutput.git(["-C", repo, "log", "-1", "--format=%s", "not-a-ref"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.output, "")
    }

    /// A git that could not be started at all is `(-1, "")` — the same reading
    /// the three call sites already take for a git that ran and failed, which is
    /// why this flattens the throw rather than propagating it.
    func testGitThatCannotBeSpawnedReportsAFailedCommand() {
        let result = SubprocessOutput.git(
            ["--version"],
            executable: dir.appendingPathComponent("not-a-binary").path(percentEncoded: false)
        )

        XCTAssertEqual(result.status, -1)
        XCTAssertEqual(result.output, "")
    }

    /// A Latin-1 commit message or a binary blob puts a byte in git's stdout
    /// that is not UTF-8. That byte costs only itself: the text around it still
    /// comes back.
    func testGitOutputHoldingAnInvalidByteStillReturnsTheTextAroundIt() {
        let result = SubprocessOutput.git(["-c", cutOffEmDash], executable: "/bin/sh")

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("before"), result.output)
        XCTAssertTrue(result.output.contains("after"), result.output)
    }

    func testTrimmedOutputHoldingAnInvalidByteStillReturnsTheReadableText() {
        let result = SubprocessOutput.Result(
            status: 0, standardOutput: Data("  readable".utf8) + Data([0xFF]) + Data("\n".utf8))

        XCTAssertEqual(result.trimmedOutput, "readable\u{FFFD}")
    }

    // MARK: - runWithDeadline

    /// A child killed partway through a multi-byte character leaves the log
    /// holding bytes that are not UTF-8; everything else it wrote still reads.
    func testADeadlineOutputHoldingAnInvalidByteStillReturnsTheTextAroundIt() {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/bin/sh",
            arguments: ["-c", cutOffEmDash],
            timeout: 10
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("before"), result.output)
        XCTAssertTrue(result.output.contains("after"), result.output)
    }

    /// The deadline path is where the lost output hurt most: a timed-out
    /// command reported only its suffix, and what it printed before the kill
    /// was gone.
    func testATimedOutCommandKeepsWhatItPrintedBeforeAnInvalidByte() {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'before the kill\\377'; sleep 810703"],
            timeout: 1
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.output.contains("before the kill"), result.output)
        XCTAssertTrue(result.output.contains("timed out after 1s"), result.output)
    }

    /// The defect this runner exists for: a `git fetch` against an unreachable
    /// host never exits, so a caller holding a serial queue while it waits
    /// blocks everything behind it for ever. Past the deadline the call must
    /// come back — at about the deadline, not when the child would have
    /// finished — reporting a failed command that says why, and the child must
    /// actually be gone.
    func testACommandThatOutlivesItsDeadlineIsKilledAndReportedAsFailed() {
        let started = Date()
        let result = SubprocessOutput.runWithDeadline(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 810701"],
            timeout: 1
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.output.contains("timed out after 1s"), result.output)
        // The child would have slept for a week: anything near the deadline
        // proves the wait was bounded rather than the child having exited.
        XCTAssertLessThan(elapsed, 15)
        XCTAssertFalse(isProcessRunning(matching: "sleep 810701"),
                       "the killed command must not still be running")
    }

    /// Signalling the child alone leaves anything *it* forked running and
    /// reparented — the case `PullRequestPublisher` already carries. The
    /// descendants have to be collected while the tree is intact and swept once
    /// the root is down.
    func testATimedOutCommandsForkedChildIsAlsoKilled() {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 810702 & wait"],
            timeout: 1
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(isProcessRunning(matching: "sleep 810702"),
                       "the forked child must not survive the call returning")
    }

    /// `GIT_TERMINAL_PROMPT=0` does not stop an askpass read, so a git that
    /// stopped for a passphrase would sit on whatever stdin it inherited — the
    /// app's own — until the deadline killed it. It must inherit the null
    /// device instead and read EOF.
    func testTheChildsStandardInputIsTheNullDevice() throws {
        // `-ef` compares device and inode, so this says *which* file fd 0 is,
        // not merely that reading it ends at once.
        let probe = "if [ /dev/fd/0 -ef /dev/null ]; then printf nulldev; else printf other; fi"

        let result = SubprocessOutput.runWithDeadline(
            executable: "/bin/sh",
            arguments: ["-c", probe],
            timeout: 10
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "nulldev")

        // The same probe with a real file on stdin, to show the check
        // discriminates rather than saying `nulldev` whatever it is handed.
        let file = dir.appendingPathComponent("stdin.txt")
        try Data("hello".utf8).write(to: file)
        let control = Process()
        control.executableURL = URL(fileURLWithPath: "/bin/sh")
        control.arguments = ["-c", probe]
        control.standardInput = try FileHandle(forReadingFrom: file)
        let pipe = Pipe()
        control.standardOutput = pipe
        control.standardError = FileHandle.nullDevice
        try control.run()
        let controlOutput = pipe.fileHandleForReading.readDataToEndOfFile()
        control.waitUntilExit()
        XCTAssertEqual(String(data: controlOutput, encoding: .utf8), "other")
    }

    /// The deadline changes nothing for a command that finishes inside it: its
    /// own exit status and its own output, stdout and stderr interleaved as the
    /// hand-rolled runner this replaces did.
    func testACommandThatFinishesInsideItsDeadlineReportsItsOwnStatusAndOutput() {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; exit 5"],
            timeout: 10
        )

        XCTAssertEqual(result.status, 5)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.output.contains("out"), result.output)
        XCTAssertTrue(result.output.contains("err"), result.output)
    }

    /// `discardStandardError: true` sends the child's stderr to the null
    /// device instead of folding it into `output` — what `SessionTitleGenerator`
    /// needs so a chatty stderr cannot land where a title is parsed from.
    func testDiscardStandardErrorDropsStderrFromOutput() {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; exit 5"],
            timeout: 10,
            discardStandardError: true
        )

        XCTAssertEqual(result.status, 5)
        XCTAssertEqual(result.output, "out")
    }

    /// Pins the default: without asking for it, stderr still lands in `output`
    /// interleaved with stdout — the behaviour `DebateOrchestrator` and
    /// `BacklogParser` already depend on.
    func testDefaultStillFoldsStandardErrorIntoOutput() {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; exit 5"],
            timeout: 10
        )

        XCTAssertEqual(result.status, 5)
        XCTAssertTrue(result.output.contains("out"), result.output)
        XCTAssertTrue(result.output.contains("err"), result.output)
    }

    func testTheWorkingDirectoryAndEnvironmentReachTheChild() {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s %s' \"$(pwd)\" \"$KITELOOP_TEST_MARKER\""],
            directory: dir,
            environment: ["KITELOOP_TEST_MARKER": "reached"],
            timeout: 10
        )

        XCTAssertTrue(result.output.hasSuffix(" reached"), result.output)
        XCTAssertTrue(result.output.contains(dir.lastPathComponent), result.output)
    }

    /// A missing executable is a failed command rather than a throw: the git
    /// call sites branch on the status, and there is no meaningful difference
    /// between a git that could not start and one that failed.
    func testAMissingExecutableReportsAFailedCommand() {
        let result = SubprocessOutput.runWithDeadline(
            executable: dir.appendingPathComponent("not-a-binary").path(percentEncoded: false),
            arguments: [],
            timeout: 10
        )

        XCTAssertEqual(result.status, -1)
        XCTAssertFalse(result.timedOut)
    }

    // MARK: - Helpers

    /// A shell script printing `before`, the first two bytes of an em dash
    /// (0xE2 0x80) with its third cut off, then `after`.
    private let cutOffEmDash = "printf 'before\\342\\200after'"

    /// A repository holding one commit on `main` and a `kept` branch one commit
    /// ahead of it — the shape `ItemGitTruth` and `RunWorkEvidence` ask their
    /// questions against. Built with `run` rather than with `git`, so the
    /// fixture is not made by the thing the cases assert.
    private func makeRepo() throws -> String {
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let path = repo.path(percentEncoded: false)
        let file = repo.appendingPathComponent("file.txt")

        func setup(_ arguments: [String]) throws {
            // An identity and no signing: the machine's own git config must not
            // decide whether a commit here can be made.
            let identity = ["-c", "user.name=Kiteloop Tests",
                            "-c", "user.email=tests@kiteloop.invalid",
                            "-c", "commit.gpgsign=false"]
            let result = try SubprocessOutput.run(
                executable: "/usr/bin/git",
                arguments: ["-C", path] + identity + arguments
            )
            XCTAssertEqual(result.status, 0, "fixture setup failed: git \(arguments.joined(separator: " "))")
        }

        try setup(["init", "-q", "-b", "main"])
        try Data("base\n".utf8).write(to: file)
        try setup(["add", "file.txt"])
        try setup(["commit", "-qm", "base"])
        try setup(["checkout", "-qb", "kept"])
        try Data("more\n".utf8).write(to: file)
        try setup(["commit", "-qam", "more"])
        try setup(["checkout", "-q", "main"])
        return path
    }

    /// True while some process anywhere on the machine has `pattern` in its
    /// command line — used to check a killed child is actually gone, not just
    /// the shell that forked it.
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

    /// A script that writes `floodBytes` to one stream and exits with a known
    /// status. Written from a file on disk so the payload is exact and does not
    /// depend on `yes`, `dd` or `tr` behaving the same everywhere.
    private func writeFloodScript(stream: String, exitCode: Int32) throws -> String {
        let payload = dir.appendingPathComponent("payload.txt")
        try Data(repeating: UInt8(ascii: "x"), count: Self.floodBytes)
            .write(to: payload)
        let script = dir.appendingPathComponent("flood.sh")
        let path = payload.path(percentEncoded: false)
        try "cat '\(path)' >&\(stream)\nexit \(exitCode)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        return script.path(percentEncoded: false)
    }

    // MARK: - The runner seam

    func testTheDefaultRunnerIsTheLiveOne() {
        XCTAssertTrue(SubprocessOutput.runner is LiveSubprocessRunner)
    }

    /// Every entry point goes through the installed runner, and none of them
    /// spawns: the executable here does not exist, and nothing throws.
    func testAnInstalledRunnerAnswersEveryEntryPointWithoutSpawning() async throws {
        let runner = ScriptedSubprocessRunner { _ in .init(status: 3, output: "scripted\n") }
        try await withScriptedSubprocesses(runner) {
            let run = try SubprocessOutput.run(executable: "/nonexistent/tool", arguments: ["a"])
            XCTAssertEqual(run.status, 3)
            XCTAssertEqual(run.trimmedOutput, "scripted")
            let git = SubprocessOutput.git(["status"])
            XCTAssertEqual(git.status, 3)
            XCTAssertEqual(git.output, "scripted\n")
            let deadline = SubprocessOutput.runWithDeadline(executable: "/nonexistent/tool", arguments: [], timeout: 1)
            XCTAssertEqual(deadline.status, 3)
            XCTAssertFalse(deadline.timedOut)
        }
        XCTAssertEqual(runner.calls.map(\.executable), ["/nonexistent/tool", "/usr/bin/git", "/nonexistent/tool"])
        XCTAssertEqual(runner.calls[2].timeout, 1)
        XCTAssertTrue(SubprocessOutput.runner is LiveSubprocessRunner, "the live runner is put back")
    }

    func testAScriptedTimeoutReadsAsTheLiveOneWould() async {
        let runner = ScriptedSubprocessRunner { _ in .init(output: "partial", timedOut: true) }
        let result = await withScriptedSubprocesses(runner) {
            SubprocessOutput.runWithDeadline(executable: "/usr/bin/git", arguments: ["fetch"], timeout: 5)
        }
        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.output, "partial\ntimed out after 5s")
    }

    func testAScriptedSpawnFailureThrowsFromRunAndReportsFailedFromTheDeadlineForm() async throws {
        let runner = ScriptedSubprocessRunner { _ in .init(spawnFails: true) }
        try await withScriptedSubprocesses(runner) {
            XCTAssertThrowsError(try SubprocessOutput.run(executable: "/usr/bin/git", arguments: []))
            XCTAssertEqual(SubprocessOutput.git(["status"]).status, -1)
            let deadline = SubprocessOutput.runWithDeadline(executable: "/usr/bin/git", arguments: [], timeout: 1)
            XCTAssertEqual(deadline.status, -1)
            XCTAssertFalse(deadline.timedOut)
        }
    }
}

/// The spawn has to happen on another thread — that is the whole point of the
/// deadlock cases — and a `var` captured by a concurrent closure is a Swift 6
/// error, so the result crosses back through a lock.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SubprocessOutput.Result?

    var value: SubprocessOutput.Result? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
