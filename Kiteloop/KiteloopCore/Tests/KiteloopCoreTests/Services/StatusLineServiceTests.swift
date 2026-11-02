import XCTest
import Combine
@testable import KiteloopCore

/// Every service here is built against a settings file in a temp directory, never
/// `~/.claude/settings.json`. The assertions that `statusText` stays empty are
/// only meaningful when *no* `statusLine.command` is configured, and on a machine
/// where the developer has one they used to read it — and `start` would then shell
/// out to whatever it happened to be.
@MainActor
final class StatusLineServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "status-line")
    }

    /// A settings URL under the temp directory. With no `command` the file is not
    /// written at all, which is the "nothing configured" case.
    private func settingsURL(command: String? = nil) throws -> URL {
        let url = tempDir.appending(path: "settings.json")
        if let command {
            let json: [String: Any] = ["statusLine": ["command": command]]
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        return url
    }

    func testStripAnsiCodes() {
        let input = "\u{001B}[32msonnet\u{001B}[0m | \u{001B}[33m$0.02\u{001B}[0m"
        let stripped = input.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        XCTAssertEqual(stripped, "sonnet | $0.02")
    }

    func testUpdateSessionDataModel() throws {
        let service = StatusLineService(settingsURL: try settingsURL())
        service.updateSessionData(model: "opus")

        XCTAssertEqual((service.statusText), "")
    }

    func testUpdateSessionDataCost() throws {
        let service = StatusLineService(settingsURL: try settingsURL())
        service.updateSessionData(costUSD: 0.05)
        service.updateSessionData(model: "sonnet", costUSD: 0.12, inputTokens: 500, outputTokens: 200, contextWindowSize: 200_000)

        // Service stores data internally — verify no crash and statusText remains empty (no command configured)
        XCTAssertEqual(service.statusText, "")
    }

    func testContextPercentIncludesCacheTokens() throws {
        let service = StatusLineService(settingsURL: try settingsURL())
        // Claude Code caches the whole prior conversation: input_tokens is tiny,
        // real occupancy lives in cache_read/cache_creation.
        service.updateSessionData(
            inputTokens: 300, outputTokens: 600,
            cacheReadInputTokens: 155_000, cacheCreationInputTokens: 4_000,
            contextWindowSize: 200_000
        )
        // Input components only — the 600 output tokens are the model's response,
        // billed separately and not occupying the window:
        // (300 + 155_000 + 4_000) / 200_000 = 79.65%
        XCTAssertNotNil(service.contextWindowPercent)
        XCTAssertEqual(service.contextWindowPercent!, 79.65, accuracy: 0.01)
    }

    func testStartWithNoCommandDoesNotCrash() throws {
        let service = StatusLineService(settingsURL: try settingsURL())
        // The injected settings file doesn't exist, so command is nil — start
        // should be a no-op and run no subprocess.
        service.start(interval: 1)
        service.stop()
        XCTAssertEqual(service.statusText, "")
    }

    func testStopClearsStatusText() throws {
        let service = StatusLineService(settingsURL: try settingsURL())
        service.stop()
        XCTAssertEqual(service.statusText, "")
    }

    /// The parameter is honoured, not merely accepted: a command written into the
    /// injected file is the one that runs.
    func testCommandIsReadFromInjectedSettingsFile() async throws {
        let service = StatusLineService(settingsURL: try settingsURL(command: "echo injected-status"))

        let ran = expectation(description: "status line command produced output")
        var cancellable: AnyCancellable?
        cancellable = service.$statusText
            .filter { !$0.isEmpty }
            .sink { text in
                XCTAssertEqual(text, "injected-status")
                ran.fulfill()
            }
        defer { cancellable?.cancel() }

        service.refresh()
        await fulfillment(of: [ran], timeout: 10)
        service.stop()
    }

    /// A command that outlives its deadline — waiting on a network call, a
    /// stalled `git`, a script reading stdin — must not be waited on forever:
    /// it and everything it forked (a `sleep` the shell forks as its own
    /// child, the same shape `ProcessTreeTests` asserts) are dead by the time
    /// `refresh()`'s result lands, and the wait itself takes about the
    /// deadline rather than the command's own runtime.
    func testCommandPastItsTimeoutIsKilledRatherThanWaitedOn() async throws {
        // Backgrounded + `wait`, as ProcessTreeTests' helper does: bash forks
        // `sleep` as its own child rather than exec-replacing itself for it
        // (which a plain trailing command would), and flushes its buffered
        // `echo` output to the sink before that fork.
        let service = StatusLineService(
            settingsURL: try settingsURL(command: "echo about-to-hang; sleep 810401 & wait"),
            commandTimeout: 0.2
        )

        let ran = expectation(description: "status line command returned after being killed")
        var cancellable: AnyCancellable?
        cancellable = service.$statusText
            .filter { !$0.isEmpty }
            .sink { text in
                XCTAssertEqual(text, "about-to-hang", "output written before the kill must still be captured")
                ran.fulfill()
            }
        defer { cancellable?.cancel() }

        let start = Date()
        service.refresh()
        await fulfillment(of: [ran], timeout: 5)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3.0, "a hung command must be killed at its deadline, not waited out")
        XCTAssertFalse(isProcessRunning(matching: "sleep 810401"),
                        "the forked child must not survive the refresh returning")
        service.stop()
    }

    /// `refresh()` called while a previous command is still in flight must
    /// start no second process — otherwise a hung command plus a 10s tick
    /// accumulates one blocked shell per refresh for the life of the app.
    func testRefreshWhileACommandIsInFlightStartsNoSecondProcess() async throws {
        let marker = tempDir.appending(path: "marker.txt")
        let command = "echo x >> '\(marker.path(percentEncoded: false))'; sleep 0.3; echo done"
        let service = StatusLineService(settingsURL: try settingsURL(command: command))

        let ran = expectation(description: "status line command produced output")
        var cancellable: AnyCancellable?
        cancellable = service.$statusText
            .filter { !$0.isEmpty }
            .sink { _ in ran.fulfill() }
        defer { cancellable?.cancel() }

        service.refresh()
        service.refresh() // still in flight — must be a no-op

        await fulfillment(of: [ran], timeout: 10)
        service.stop()

        let markerContents = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        let lines = markerContents.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 1, "a second refresh() while one was in flight must not start a second process")
    }

    /// True while some process anywhere on the machine has `pattern` in its
    /// command line — mirrors `ProcessTreeTests`' helper of the same name, used
    /// here to confirm a killed status-line command's forked child is actually
    /// gone, not just the shell that forked it.
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

    /// A context window of zero reports zero occupancy rather than dividing by
    /// it: `Int(pct)` of the infinity (or NaN) that division would produce traps.
    func testZeroContextWindowReportsZeroPercent() throws {
        let service = StatusLineService(settingsURL: try settingsURL())
        service.updateSessionData(inputTokens: 100, contextWindowSize: 0)
        XCTAssertEqual(service.contextWindowPercent, 0)
    }

    /// `start` with a command configured refreshes at once, not only on the
    /// first tick — a status line that stays blank for ten seconds after
    /// launch reads as "not configured".
    func testStartWithACommandRefreshesImmediately() async throws {
        let service = StatusLineService(settingsURL: try settingsURL(command: "echo started"))

        let ran = expectation(description: "start ran the status line command")
        var cancellable: AnyCancellable?
        cancellable = service.$statusText
            .filter { !$0.isEmpty }
            .first()
            .sink { text in
                XCTAssertEqual(text, "started")
                ran.fulfill()
            }
        defer { cancellable?.cancel() }

        service.start(interval: 60)
        await fulfillment(of: [ran], timeout: 10)
        service.stop()
    }

    /// The timer repeats: the command is re-run on every tick for the life of
    /// the service, not once after the first interval and never again.
    func testStartKeepsRefreshingOnEveryTick() async throws {
        let marker = tempDir.appending(path: "ticks.txt")
        let command = "echo tick >> '\(marker.path(percentEncoded: false))'; echo tick"
        let service = StatusLineService(settingsURL: try settingsURL(command: command))

        service.start(interval: 0.2)
        defer { service.stop() }

        // One run from `start` itself plus two ticks: a one-shot timer stops at two lines.
        try await eventually(timeout: .seconds(10), "three runs of the status line command") {
            let contents = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            return contents.split(whereSeparator: \.isNewline).count >= 3
        }
    }

    /// A refresh after the previous one has finished runs the command again:
    /// the in-flight guard is released when the result lands, not held forever.
    func testRefreshAfterThePreviousOneFinishedRunsTheCommandAgain() async throws {
        let marker = tempDir.appending(path: "runs.txt")
        // Prints how many times it has run, so each result is told apart from the last.
        let command = "echo run >> '\(marker.path(percentEncoded: false))'; wc -l < '\(marker.path(percentEncoded: false))'"
        let service = StatusLineService(settingsURL: try settingsURL(command: command))
        defer { service.stop() }

        service.refresh()
        try await eventually("the first refresh to finish") { service.statusText == "1" }

        service.refresh()
        try await eventually("the second refresh to run the command again") { service.statusText == "2" }
    }
}
