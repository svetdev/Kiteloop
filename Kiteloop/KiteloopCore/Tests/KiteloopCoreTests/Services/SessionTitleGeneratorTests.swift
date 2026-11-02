import XCTest
@testable import KiteloopCore

/// Coverage for the child process behind session titling. Every case points the
/// generator at `/bin/sh` rather than `claude`, so nothing here depends on a CLI
/// being installed and the shapes that matter — an output larger than the pipe
/// buffer, a child that never exits — can be produced on demand.
///
/// The load-bearing case is `testLargeOutputStillReturns`: the generator used to
/// read stdout only from `terminationHandler`, and a child that filled the pipe
/// buffer blocked on write, never exited, never fired the handler, and left the
/// continuation unresumed for the life of the app.
final class SessionTitleGeneratorTests: XCTestCase {

    // MARK: - Fixtures

    private static let shell = URL(fileURLWithPath: "/bin/sh")

    private static var conversation: [Message] {
        [
            Message(id: UUID(), timestamp: Date(), sender: .human, content: .text("How do I add an agent?")),
            Message(id: UUID(), timestamp: Date(), sender: .agent("worker"),
                    content: .text("Create a package under knowledge/agents.")),
        ]
    }

    /// The XCTest wait has to outlast the generator's own watchdog, or a slow
    /// machine reads as a test failure instead of the generator's real answer:
    /// the child may still be starting when the watchdog's `timeout` fires, and
    /// only after it fires does `generate` return. This margin is on top of
    /// `timeout`, not a fixed floor, so a case cannot pick a wait shorter than
    /// the deadline it is waiting on.
    private static let expectationMargin: TimeInterval = 10

    /// Runs `generate` off the test's own thread and fails, rather than hangs, if
    /// it never comes back — the regression under test is precisely a call that
    /// does not return, so no case may `await` it unbounded.
    private func title(
        _ script: String,
        messages: [Message]? = nil,
        timeout: TimeInterval = 30,
        expectationTimeout: TimeInterval? = nil
    ) -> String? {
        run(executable: Self.shell, arguments: ["-c", script],
            messages: messages ?? Self.conversation,
            timeout: timeout, expectationTimeout: expectationTimeout)
    }

    private func run(
        executable: URL?,
        claudePath: String? = nil,
        arguments: [String],
        messages: [Message],
        timeout: TimeInterval,
        expectationTimeout: TimeInterval? = nil
    ) -> String? {
        let box = ResultBox()
        let done = expectation(description: "generate returned")
        let requested = Date()
        Task {
            box.taskStarted = Date()
            box.value = await SessionTitleGenerator.generate(
                from: messages,
                claudePath: claudePath,
                executableURL: executable,
                arguments: { _ in arguments },
                timeout: timeout
            )
            box.finished = Date()
            done.fulfill()
        }
        let deadline = expectationTimeout ?? timeout + Self.expectationMargin
        // `XCTWaiter(delegate: self)` rather than the bare `wait(for:timeout:)`
        // convenience: it reports the same "Asynchronous wait failed" failure to
        // this test case that the convenience method does, but also hands back
        // the result so a timeout can be logged before the case's own assertions
        // run — the convenience method discards it.
        if XCTWaiter(delegate: self).wait(for: [done], timeout: deadline) == .timedOut {
            logMissedDeadline(box: box, requestedAt: requested, deadline: deadline)
        }
        return box.value
    }

    /// This deadline has been missed under the full suite on a script that does
    /// nothing but `printf` — not under a machine running this file alone — which
    /// points at scheduling delay somewhere between "the Task was created" and
    /// "`generate` returned", rather than at the child or at `generate` itself.
    /// Neither half is instrumented in production, and adding that instrumentation
    /// is out of scope here, so this narrows it as far as the two points this test
    /// already controls allow: whether the `Task` itself was starved of a thread to
    /// start on, or whether it started promptly and the time went into `generate`
    /// (spawning the child, draining it, or the `DispatchQueue.global(qos: .utility)`
    /// work the timeout races against). Printed rather than asserted, so it never
    /// changes what a case asserts or its message — only what the log says the one
    /// time this fires.
    private func logMissedDeadline(box: ResultBox, requestedAt: Date, deadline: TimeInterval) {
        let now = Date()
        func elapsed(_ date: Date?) -> String {
            date.map { String(format: "%.2fs", $0.timeIntervalSince(requestedAt)) } ?? "—"
        }
        print("""
            [SessionTitleGeneratorTests] expectation missed its \(String(format: "%.1f", deadline))s deadline \
            (gave up at \(String(format: "%.2f", now.timeIntervalSince(requestedAt)))s): \
            Task started at \(elapsed(box.taskStarted)), generate() returned at \(elapsed(box.finished)).
            """)
    }

    /// A slot the `Task` writes and the test body reads once the expectation has
    /// been fulfilled, which is what orders the two. `taskStarted` and `finished`
    /// exist only to be read by `logMissedDeadline` on the timeout path, where that
    /// ordering does not hold — see its comment.
    private final class ResultBox: @unchecked Sendable {
        var value: String?
        var taskStarted: Date?
        var finished: Date?
    }

    // MARK: - Draining

    func testLargeOutputStillReturns() {
        // Far more than the 64 KB pipe buffer: undrained, this child blocks on
        // write and never exits.
        let result = title("printf 'A chatty child '; yes padding | tr '\\n' ' ' | head -c 200000")
        XCTAssertNotNil(result, "generate should return rather than hang on a child that outruns the pipe buffer")
        XCTAssertEqual(result?.hasPrefix("A chatty child"), true)
        XCTAssertEqual(result?.count, 60)
    }

    // MARK: - Timeout

    func testChildThatNeverExitsTimesOutAndIsKilled() {
        let pidFile = FileManager.default.temporaryDirectory
            .appending(path: "session-title-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        // `exec` keeps the pid: the process the generator launched *is* the sleep,
        // so terminating it leaves nothing orphaned behind.
        let script = "echo $$ > '\(pidFile.path(percentEncoded: false))'; exec sleep 120"
        XCTAssertNil(title(script, timeout: 1))

        let recorded = (try? String(contentsOf: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = recorded.flatMap({ pid_t($0) }) else {
            return XCTFail("the child should have recorded its pid before sleeping")
        }
        XCTAssertTrue(hasExited(pid), "the timed-out child is still running")
    }

    /// `kill(pid, 0)` answers 0 while the process exists — including as a zombie,
    /// which it briefly is until the drain reaps it — so this polls.
    private func hasExited(_ pid: pid_t, within: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(within)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return kill(pid, 0) != 0
    }

    func testChildThatIgnoresSIGTERMIsKilled() {
        let pidFile = FileManager.default.temporaryDirectory
            .appending(path: "session-title-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        // Ignoring TERM defeats `terminate()` alone; the watchdog must escalate
        // to KILL once the grace period passes rather than ask nicely once.
        let script = "trap '' TERM; echo $$ > '\(pidFile.path(percentEncoded: false))'; sleep 120"
        XCTAssertNil(title(script, timeout: 1))

        let recorded = (try? String(contentsOf: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = recorded.flatMap({ pid_t($0) }) else {
            return XCTFail("the child should have recorded its pid before sleeping")
        }
        XCTAssertTrue(hasExited(pid), "a child ignoring SIGTERM must still be killed")
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

    /// Polls until nothing matches `pattern` — the sweep of a backgrounded
    /// descendant runs after `generate` has already returned the title, so
    /// asserting immediately would race it.
    private func processExited(matching pattern: String, within: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(within)
        while Date() < deadline {
            if !isProcessRunning(matching: pattern) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isProcessRunning(matching: pattern)
    }

    func testChildThatBackgroundsAnUnreapedChildIsSweptToo() {
        // No `exec`: the sleep is a forked descendant the shell backgrounds and
        // waits on — exactly what TERM or KILL aimed at the shell alone never
        // reaches, and what `claude` itself does when it forks its own children.
        XCTAssertNil(title("sleep 920101 & wait", timeout: 1))
        XCTAssertTrue(processExited(matching: "sleep 920101"),
                      "the backgrounded descendant must not survive the watchdog")
    }

    func testSweepLeavesABystanderProcessAlone() {
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["920102"]
        try? bystander.run()
        defer {
            bystander.terminate()
            bystander.waitUntilExit()
        }

        XCTAssertNil(title("sleep 920102 & wait", timeout: 1))
        // Every signal the sweep sends has gone by the time `generate` returns
        // (`ProcessTree.killDescendants` runs inside `runWithDeadline`), so this
        // only gives `Process` the sweep's own grace period to notice a death
        // that would already have been delivered before checking the bystander.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(bystander.isRunning,
                      "a process outside this call's own tree must not be touched")
    }

    // MARK: - Shaping the answer

    func testShortAnswerIsTrimmed() {
        XCTAssertEqual(title("printf '  \\n Adding a backlog item \\n\\n'"), "Adding a backlog item")
    }

    func testLongAnswerIsCappedAtSixtyCharacters() {
        let long = String(repeating: "a", count: 120)
        XCTAssertEqual(title("printf '%s' '\(long)'"), String(repeating: "a", count: 60))
    }

    func testOnlyTheFirstLineOfAMultiLineAnswerIsTheTitle() {
        XCTAssertEqual(
            title("printf 'Adding  a backlog item\\n\\nThis title sums up the question.\\n'"),
            "Adding a backlog item")
    }

    func testEmptyAnswerIsNoTitle() {
        XCTAssertNil(title("printf '   \\n'"))
    }

    func testStderrIsNotFoldedIntoTheTitle() {
        XCTAssertEqual(
            title("printf 'noisy stderr\\n' >&2; printf 'Adding a backlog item'"),
            "Adding a backlog item")
    }

    // MARK: - Nothing to ask about

    func testNoTextMessagesIsNoTitle() {
        let toolOnly = [
            Message(id: UUID(), timestamp: Date(), sender: .agent("worker"),
                    content: .toolCall(Message.ToolCall(id: "t1", name: "Bash", input: "{}"))),
        ]
        // No context to summarise, so no child is spawned and the script that
        // would have answered never runs.
        XCTAssertNil(title("printf 'unreachable'", messages: toolOnly))
    }

    func testUnlaunchableExecutableIsNoTitle() {
        XCTAssertNil(run(executable: URL(fileURLWithPath: "/nonexistent/claude"),
                         arguments: [], messages: Self.conversation,
                         timeout: 5))
    }

    // MARK: - Executable resolution

    /// With no `executableURL` test override, the resolved `claudePath` the
    /// caller hands in is what actually gets spawned — the generator makes no
    /// lookup of its own.
    func testResolvedClaudePathIsSpawnedWhenNoExecutableOverride() {
        let result = run(executable: nil, claudePath: "/bin/sh",
                          arguments: ["-c", "printf 'Resolved from claudePath'"],
                          messages: Self.conversation, timeout: 5)
        XCTAssertEqual(result, "Resolved from claudePath")
    }

    /// No override and no resolved path: no child is spawned and the call
    /// answers no title.
    func testNothingResolvedIsNoTitleAndSpawnsNothing() {
        XCTAssertNil(run(executable: nil, claudePath: nil,
                         arguments: ["-c", "printf 'unreachable'"],
                         messages: Self.conversation, timeout: 5))
    }
}
