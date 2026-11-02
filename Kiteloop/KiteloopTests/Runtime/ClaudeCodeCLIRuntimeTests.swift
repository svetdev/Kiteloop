import XCTest
import os
import KiteloopCore
@testable import Kiteloop

final class ClaudeCodeCLIRuntimeTests: XCTestCase {

    /// The `claude` binary, or nil if this machine has none we can run.
    ///
    /// This used to shell out to `which claude` and fall back with `?? "..."`,
    /// which only covers nil. Under the app-hosted test host the GUI `PATH`
    /// omits `~/.local/bin`, so `which` printed nothing, the fallback did not
    /// fire on the empty string, and `URL(fileURLWithPath: "")` resolved to the
    /// current directory — `run()` then failed EACCES trying to exec a
    /// directory. `CLIResolver` is what the app itself uses: it treats an empty
    /// `which` result as not-found and checks `~/.local/bin` and the Homebrew
    /// prefixes. We re-check executability here because a path from `which` is
    /// taken on trust.
    private static let claudePath: String? = {
        guard let path = CLIResolver.claude,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }()

    /// How long a test that spawns the real `claude` binary waits on it before
    /// giving up, ending the child and failing.
    ///
    /// Neither live-CLI test bounded anything: a wedged CLI was waited on for
    /// ever, so the suite ran to xcodebuild's own time limit and was ended —
    /// and a run ended that way records no tally at all, so the four thousand
    /// tests that had already passed measured nothing. Bounded, a wedged CLI
    /// costs one red test.
    private static let liveCLITimeout: TimeInterval = 120

    func testPipeReadFromGCD() async throws {
        guard let claudePath = Self.claudePath else {
            throw XCTSkip("No executable `claude` CLI found — this test spawns the real binary")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--print", "--output-format", "stream-json", "--verbose", "--model", "sonnet", "--no-session-persistence", "--max-turns", "1", "What is 2+2? One word."]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // The null device rather than a `Pipe()` nobody reads: an undrained pipe
        // fills, and the child then blocks for ever on its next write to stderr.
        process.standardError = FileHandle.nullDevice

        try process.run()

        // A CLI that neither answers nor closes stdout writes no EOF, so the read
        // loop below never sees the empty read that breaks it. Bound the wait: at
        // the deadline the child is ended, closing the pipe, and the loop and the
        // stream unwind on the EOF that follows.
        let child = LiveCLIChild(process)
        let watchdog = LiveCLIWatchdog.armed(after: Self.liveCLITimeout) { child.end() }

        let fileHandle = stdoutPipe.fileHandleForReading

        let stream = AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = ""
                while true {
                    let data = fileHandle.availableData
                    if data.isEmpty { break }
                    guard let chunk = String(data: data, encoding: .utf8) else { continue }
                    buffer += chunk
                    while let idx = buffer.firstIndex(of: "\n") {
                        let line = String(buffer[..<idx])
                        buffer = String(buffer[buffer.index(after: idx)...])
                        if !line.isEmpty {
                            continuation.yield(line)
                        }
                    }
                }
                continuation.finish()
            }
        }

        var lines: [String] = []
        for await line in stream {
            lines.append(line)
        }

        let timedOut = watchdog.disarm()
        // Not `waitUntilExit()`: after the `for await` above this body may be
        // on another cooperative thread, where that call parks the thread's run
        // loop for a wakeup that never comes — the wedge that held a parallel
        // clone to the suite's idle ceiling on 2026-09-22. The stream ended on
        // EOF, so the child is already on its way out.
        try await eventually("the `claude` child exits after its stdout closed") { !child.isRunning }

        if timedOut {
            XCTFail("testPipeReadFromGCD: the `claude` CLI never closed stdout within \(Int(Self.liveCLITimeout))s — the child was ended and its descendants swept")
            return
        }
        XCTAssertGreaterThan(lines.count, 0, "Should have read lines from pipe via GCD")
    }

    func testSendAndStream() async throws {
        guard Self.claudePath != nil else {
            throw XCTSkip("No executable `claude` CLI found — this test spawns the real binary")
        }

        let runtime = ClaudeCodeCLIRuntime()
        let agent = Agent.defaultCoder
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory())

        let session = try await runtime.startSession(agent: agent, cwd: cwd)

        var receivedResult = false
        var receivedText = false

        let stream = runtime.send("What is 2+2? Reply with just the number.", to: session)

        // The same bound as `testPipeReadFromGCD`, one level up: this stream is
        // finished by the CLI's `result` line or by its stdout reaching EOF, so a
        // child that answers neither holds the loop below for ever. At the
        // deadline the runtime's own `stop(session:)` tears the session down —
        // through `ProcessTree.terminateAll`, which collects each root's
        // descendants before it signals anything, the ordering `ProcessTree`
        // requires — and the EOF that follows ends the stream.
        let watchdog = LiveCLIWatchdog.armed(after: Self.liveCLITimeout) {
            runtime.stop(session: session)
        }

        for await event in stream {
            switch event {
            case .assistantText(let text, _):
                receivedText = true
                XCTAssertFalse(text.isEmpty)
            case .result(let payload):
                receivedResult = true
                XCTAssertGreaterThan(payload.costUSD, 0)
            default:
                break
            }
        }

        if watchdog.disarm() {
            XCTFail("testSendAndStream: the `claude` CLI did not finish the exchange within \(Int(Self.liveCLITimeout))s — the session was stopped and its processes swept")
            return
        }

        XCTAssertTrue(receivedResult, "Should have received a result event")
        XCTAssertTrue(receivedText, "Should have received text event")
        runtime.stop(session: session)
    }

    // MARK: - loadOperatorToolsGrant's config read
    //
    // `loadOperatorToolsGrant` is private, so these pin the two pieces it
    // composes to resolve a port — `SpawnTimeConfigRead.load()` and
    // `KiteloopControlServer.resolvedPort` — directly: an undecodable or absent
    // settings file still resolves to the default port rather than nil turning
    // into something else, and a valid file's port passes through unchanged.

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "claude-code-cli-runtime")
    }

    override func tearDownWithError() throws {
        tempDir = nil
        try super.tearDownWithError()
    }

    /// A session whose agent carries a turn budget is spawned with it; one
    /// whose agent carries none keeps 50.
    func testMaxTurnsArgumentPassesTheAgentBudgetOrFifty() {
        var agent = Agent.defaultCoder
        XCTAssertEqual(ClaudeCodeCLIRuntime.maxTurnsArgument(for: agent), "50")
        agent.maxTurns = 90
        XCTAssertEqual(ClaudeCodeCLIRuntime.maxTurnsArgument(for: agent), "90")
    }

    private func makeInbox() -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "inbox.log"))
    }

    func testOperatorToolsGrantPortFallsBackToDefaultWhenSettingsAreUndecodable() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")
        try Data("not json at all".utf8).write(to: url)

        let port = SpawnTimeConfigRead.load(from: url, reporter: reporter)?.controlServerPort
        await reporter.drain()

        XCTAssertEqual(KiteloopControlServer.resolvedPort(port), KiteloopControlServer.defaultPort)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not read Settings")
    }

    func testOperatorToolsGrantPortFallsBackToDefaultWhenNoSettingsFileExists() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")

        let port = SpawnTimeConfigRead.load(from: url, reporter: reporter)?.controlServerPort
        await reporter.drain()

        XCTAssertEqual(KiteloopControlServer.resolvedPort(port), KiteloopControlServer.defaultPort)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    func testOperatorToolsGrantPortResolvesFromAValidSettingsFile() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")
        var written = GlobalConfig()
        written.controlServerPort = 5150
        try JSONEncoder().encode(written).write(to: url)

        let port = SpawnTimeConfigRead.load(from: url, reporter: reporter)?.controlServerPort
        await reporter.drain()

        XCTAssertEqual(KiteloopControlServer.resolvedPort(port), 5150)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    // MARK: - Reader teardown

    /// The reader holds no reference across its blocking read, so a runtime
    /// whose only reader is parked on the pipe still deallocates the moment
    /// its last owner lets go — `deinit`, and `terminateAll` taking the lock,
    /// on a thread that does not hold it. Lines written after the release reach
    /// a reader whose runtime is gone, which ends instead of crashing.
    @MainActor
    func testARuntimeDeallocatesWhileItsStdoutReaderIsParkedOnThePipe() async throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let assistantLine = Data("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n".utf8)
        weak var released: ClaudeCodeCLIRuntime?
        do {
            let runtime = ClaudeCodeCLIRuntime()
            released = runtime
            runtime.startStdoutReader(sessionID: "reader-teardown", stdoutPipe: pipe)
            // A few events through the locked regions before the release.
            for _ in 0..<20 { writer.write(assistantLine) }
        }
        try await eventually("the runtime to deallocate with its reader parked on the pipe") { released == nil }
        for _ in 0..<20 { writer.write(assistantLine) }
        try writer.close()
    }

    // MARK: - Between turns

    /// A background task that ends after the turn's `result` is reported when
    /// no turn is listening. The notice is held and opens the next turn, where
    /// the chat folds it; anything else that arrives then is dropped as before.
    @MainActor
    func testANoticeAboutBackgroundWorkBetweenTurnsOpensTheNextTurn() async throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let runtime = ClaudeCodeCLIRuntime()
        runtime.startStdoutReader(sessionID: "between-turns", stdoutPipe: pipe)
        let late = #"{"type":"assistant","message":{"content":[{"type":"text","text":"late"}]}}"#
        let notice = #"{"type":"system","subtype":"task_updated","task_id":"b1","patch":{"status":"completed"}}"#
        writer.write(Data((late + "\n" + notice + "\n").utf8))
        try await eventually("the reader to hold the notice") { runtime.heldActivityCount(for: "between-turns") == 1 }

        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()
        _ = runtime.registerContinuation(continuation, sessionID: "between-turns")
        continuation.finish()
        var delivered: [String] = []
        for await event in stream {
            if case .system(let subtype, _) = event { delivered.append(subtype) } else { delivered.append("other") }
        }
        XCTAssertEqual(delivered, ["task_updated"], "the held notice, and not the text no turn was there for")
        XCTAssertEqual(runtime.heldActivityCount(for: "between-turns"), 0)
        try writer.close()
    }

    /// The 2.1.281 fixture through a real reader: its first turn goes to the
    /// send that asked for it and ends at its `result`; the shell's notices
    /// after it and the turn the CLI then starts by itself arrive together as
    /// a turn of its own, on the session's unprompted-turn stream.
    @MainActor
    func testATurnTheCLIStartsByItselfAfterTheResultArrivesAsATurnOfItsOwn() async throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let runtime = ClaudeCodeCLIRuntime()
        let session = AgentSession(id: "unprompted", agentID: "agent", startedAt: .now)
        runtime.startStdoutReader(sessionID: session.id, stdoutPipe: pipe)
        let turns = runtime.unpromptedTurns(of: session)
        let second = OSAllocatedUnfairLock<[StreamEvent]?>(initialState: nil)
        let listener = Task {
            for await turn in turns {
                var events: [StreamEvent] = []
                for await event in turn { events.append(event) }
                let taken = events
                second.withLock { $0 = taken }
                return
            }
        }

        let (first, continuation) = AsyncStream<StreamEvent>.makeStream()
        _ = runtime.registerContinuation(continuation, sessionID: session.id)
        let lines = try StreamEventSubagentFixtureTests.fixtureLines()
        writer.write(Data((lines.joined(separator: "\n") + "\n").utf8))

        var firstTexts: [String] = []
        for await event in first {
            if case .assistantText(let text, _) = event { firstTexts.append(text) }
        }
        XCTAssertEqual(firstTexts.count, 2)
        XCTAssertTrue(firstTexts[0].hasPrefix("17 × 23 = 391"))

        try await eventually("the CLI's own turn to arrive and end") { second.withLock { $0 != nil } }
        let events = try XCTUnwrap(second.withLock { $0 })
        let subtypes = events.prefix(4).compactMap { event -> String? in
            if case .system(let subtype, _) = event { return subtype } else { return nil }
        }
        XCTAssertEqual(subtypes, ["background_tasks_changed", "task_updated", "task_notification", "init"],
                       "the notices held since the result open the turn, ahead of its init")
        let texts = events.compactMap { event -> String? in
            if case .assistantText(let text, _) = event { return text } else { return nil }
        }
        XCTAssertEqual(texts.count, 1)
        XCTAssertTrue(texts[0].hasPrefix("I did all three steps"))
        guard case .result(let payload)? = events.last else { return XCTFail("the turn did not end at its result") }
        XCTAssertEqual(payload.costUSD, 0.22322, accuracy: 1e-6)
        XCTAssertFalse(runtime.hasOpenUnpromptedTurn(for: session.id))
        listener.cancel()
        try writer.close()
    }

    /// A send made while the CLI's own turn is open waits for that turn's
    /// `result`: it is written only then, and its stream carries its own
    /// reply, not the rest of the other turn.
    @MainActor
    func testASendMadeDuringTheCLIsOwnTurnWaitsForItsResult() async throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let runtime = ClaudeCodeCLIRuntime()
        runtime.startStdoutReader(sessionID: "deferred", stdoutPipe: pipe)
        let line = { (json: String) in writer.write(Data((json + "\n").utf8)) }
        line(#"{"type":"system","subtype":"init"}"#)
        line(#"{"type":"assistant","message":{"content":[{"type":"text","text":"its own turn"}]}}"#)
        try await eventually("the reader to open the CLI's own turn") { runtime.hasOpenUnpromptedTurn(for: "deferred") }

        let written = OSAllocatedUnfairLock(initialState: false)
        let (reply, continuation) = AsyncStream<StreamEvent>.makeStream()
        runtime.registerOrDefer(continuation, sessionID: "deferred") { written.withLock { $0 = true } }
        XCTAssertFalse(written.withLock { $0 }, "not written while the other turn is open")

        line(#"{"type":"result","subtype":"success","result":"its own turn","total_cost_usd":0.01}"#)
        try await eventually("the send to go once that turn's result is in") { written.withLock { $0 } }
        line(#"{"type":"assistant","message":{"content":[{"type":"text","text":"the reply"}]}}"#)
        line(#"{"type":"result","subtype":"success","result":"the reply","total_cost_usd":0.02}"#)

        var texts: [String] = []
        for await event in reply {
            if case .assistantText(let text, _) = event { texts.append(text) }
        }
        XCTAssertEqual(texts, ["the reply"])
        try writer.close()
    }

    /// How many runtimes this test releases under a busy reader, and how many
    /// it holds open at once.
    ///
    /// Two hundred pipes opened together is four hundred descriptors held for
    /// the length of the test, on top of whatever the host clone already had
    /// open — and the crashes this test took its host down with came and went
    /// with what else was running. In batches the property is unchanged and the
    /// descriptor count is bounded.
    private static let busyReaderReleases = 200
    private static let busyReaderBatchSize = 25

    /// How many lines each writer pushes at its pipe while the runtime that
    /// reads it is released.
    private static let busyReaderWritesPerPipe = 50

    /// Two hundred runtimes released while their readers are busy. With the
    /// readers' old `self?` per statement, a release landing inside a locked
    /// region deadlocked the reader against its own `deinit` and the runtime
    /// never deallocated; the deadline turns that hang into a failure.
    ///
    /// The releases run in batches: the property is the same two hundred, and
    /// no more than `busyReaderBatchSize` pipes are open at any moment.
    @MainActor
    func testReleasingARuntimeUnderABusyReaderNeverDeadlocks() async throws {
        var deallocated = 0
        for batch in 0..<(Self.busyReaderReleases / Self.busyReaderBatchSize) {
            deallocated += try await releaseRuntimesUnderBusyReaders(batch: batch)
        }
        XCTAssertEqual(deallocated, Self.busyReaderReleases)
    }

    /// One batch of releases, returning how many of its runtimes deallocated.
    ///
    /// The pipes outlive their runtimes for as long as their writers run: a
    /// reader that has ended drops its read handle, and a writer still going
    /// against a closed read end would take the host down with SIGPIPE — a
    /// harness accident, not the deadlock this test is about. So the write ends
    /// close only once both waits are through, and the read ends go with the
    /// pipes when this returns.
    @MainActor
    private func releaseRuntimesUnderBusyReaders(batch: Int) async throws -> Int {
        var pipes: [Pipe] = []
        var released: [() -> Bool] = []
        let writersFinished = OSAllocatedUnfairLock(initialState: 0)
        for i in 0..<Self.busyReaderBatchSize {
            let index = batch * Self.busyReaderBatchSize + i
            let pipe = Pipe()
            pipes.append(pipe)
            let writer = BusyPipeWriter(
                descriptor: pipe.fileHandleForWriting.fileDescriptor,
                line: Array("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"\(index)\"}]}}\n".utf8),
                writes: Self.busyReaderWritesPerPipe,
                finished: writersFinished
            )
            DispatchQueue.global(qos: .userInitiated).async(execute: writer.run)
            weak var weakRuntime: ClaudeCodeCLIRuntime?
            do {
                let runtime = ClaudeCodeCLIRuntime()
                weakRuntime = runtime
                runtime.startStdoutReader(sessionID: "busy-\(index)", stdoutPipe: pipe)
            }
            released.append { weakRuntime == nil }
        }
        try await eventually(
            timeout: .seconds(20),
            "every runtime in batch \(batch) to deallocate under a busy reader"
        ) { released.allSatisfy { $0() } }
        // Every writer is done before its pipe closes under it.
        try await eventually(timeout: .seconds(20), "every writer in batch \(batch) to finish") {
            writersFinished.withLock { $0 } == Self.busyReaderBatchSize
        }
        for pipe in pipes { try pipe.fileHandleForWriting.close() }
        return released.filter { $0() }.count
    }

    // MARK: - Writing to a child that may already be gone

    /// A write to a handle whose descriptor is already closed — what
    /// `cleanup(_:)` does to a session's stdin from another thread while a
    /// send is still in flight — answers that it did not land, and the caller
    /// lives to read the answer. Through Foundation's non-throwing
    /// `FileHandle.write(_:)` this raises an Objective-C exception no Swift
    /// `catch` can take, so it would not fail this test, it would abort the
    /// whole host: the run reaching the next line is half of what is asserted.
    func testWriteToChildReportsARefusalOnAClosedHandle() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        try writer.close()

        XCTAssertFalse(ClaudeCodeCLIRuntime.writeToChild(Data("{\"type\":\"user\"}\n".utf8), through: writer))
        // Still running: a second refusal answers the same way, and the far
        // end is still ours to close.
        XCTAssertFalse(ClaudeCodeCLIRuntime.writeToChild(Data("and again\n".utf8), through: writer))
        try pipe.fileHandleForReading.close()
    }

    /// The other half of the same race: the handle is open, but the CLI on the
    /// far end has exited, so the pipe is broken. `write(2)` answers that with
    /// `EPIPE` — and not with SIGPIPE, whose default disposition would kill
    /// the host outright rather than fail a test.
    func testWriteToChildReportsARefusalWhenTheReaderIsGone() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()

        XCTAssertFalse(ClaudeCodeCLIRuntime.writeToChild(Data("{\"type\":\"user\"}\n".utf8),
                                                         through: pipe.fileHandleForWriting))
        try pipe.fileHandleForWriting.close()
    }

    /// A write that lands says so, and every byte of it arrives. The payload
    /// is far larger than a pipe's buffer, so delivering it takes more than
    /// one `write(2)` and a reader draining the far end — the partial writes
    /// the helper loops over.
    func testWriteToChildDeliversEveryByteOfAPayloadThatLands() async throws {
        let pipe = Pipe()
        let payload = Data((0..<(512 * 1024)).map { UInt8($0 % 251) })
        let reader = pipe.fileHandleForReading
        let received = OSAllocatedUnfairLock<Data?>(initialState: nil)
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            let all = reader.readDataToEndOfFile()
            received.withLock { $0 = all }
        }

        XCTAssertTrue(ClaudeCodeCLIRuntime.writeToChild(payload, through: pipe.fileHandleForWriting))
        try pipe.fileHandleForWriting.close()

        try await eventually(timeout: .seconds(20), "the far end to read the payload whole") {
            received.withLock { $0 != nil }
        }
        XCTAssertEqual(received.withLock { $0 }, payload)
        try reader.close()
    }
}

// MARK: - Writing at a pipe from a background queue

/// Pushes lines at a pipe from a background queue while the runtime reading it
/// is released, isolated to nothing and raising nothing.
///
/// Both of the ways this test used to abort its host came from doing this work
/// in a block written inside the test method. `FileHandle.write(contentsOf:)`
/// reports a refused write by raising an Objective-C
/// `NSFileHandleOperationException`, which no Swift `catch` — not even
/// `try?` — takes, so the first refusal called `abort()`; and the block itself
/// carried the method's `@MainActor` isolation, so running it on
/// `com.apple.root.default-qos` tripped the executor check. Declared out here
/// the writing is `Sendable`, isolated to nothing and touches no main-actor
/// state, and it goes through the descriptor, where a refusal is a return value.
private struct BusyPipeWriter: Sendable {
    /// The pipe's write end. Its `FileHandle` outlives every writer — the test
    /// holds the `Pipe` until both of its waits are through — so this is never
    /// a closed or recycled descriptor.
    let descriptor: Int32
    let line: [UInt8]
    let writes: Int
    /// How many writers have finished. Incremented exactly once per writer,
    /// whether it wrote everything or was refused, so the test's wait on it
    /// cannot park on a writer that stopped early.
    let finished: OSAllocatedUnfairLock<Int>

    func run() {
        for _ in 0..<writes {
            guard writeLine() else { break }
        }
        finished.withLock { $0 += 1 }
    }

    /// One line through the descriptor, looping over a partial write. False
    /// means the OS refused this writer — it stops there rather than spinning
    /// on an error that will not clear.
    private func writeLine() -> Bool {
        var offset = 0
        while offset < line.count {
            let written = line.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(descriptor, base + offset, buffer.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

// MARK: - Bounding a live-CLI test

/// A spawned `claude`, reachable from the watchdog's queue.
///
/// `Process` is not `Sendable`, and the watchdog fires on a background queue
/// while the test's own thread sits in a read the child may never end, so the
/// two reach it through this box.
private final class LiveCLIChild: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    /// Ends the child and everything it forked.
    ///
    /// `descendantPIDs(of:)` runs *before* the root is signalled — the ordering
    /// `ProcessTree` states in its own comments: `pgrep -P` reads the parent link
    /// off the still-running child, and a killed or reparented process no longer
    /// reports one. `claude` is the real executable here and forks children that
    /// TERM or KILL on the root never reaches.
    func end() {
        guard process.isRunning else { return }
        let descendants = ProcessTree.descendantPIDs(of: process.processIdentifier)
        process.terminate()
        usleep(500_000)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        ProcessTree.killDescendants(descendants)
    }
}

/// Runs `onExpiry` once if the test has not finished with its child by the
/// deadline, and afterwards reports whether it fired.
///
/// The expiry runs on a background queue while the test's own thread is blocked
/// on the child, so the two race for one lock-guarded slot the way
/// `SessionTitleGenerator` does: exactly one of them claims the run, so a test
/// that finished normally is never killed out from under itself, and never
/// reports a timeout it did not have.
private final class LiveCLIWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var expired = false

    /// Schedules the expiry and hands back the watchdog to disarm.
    static func armed(
        after timeout: TimeInterval,
        onExpiry: @escaping @Sendable () -> Void
    ) -> LiveCLIWatchdog {
        let watchdog = LiveCLIWatchdog()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard watchdog.expire() else { return }
            onExpiry()
        }
        return watchdog
    }

    /// Stands the watchdog down and reports whether it had already fired: true
    /// means the wait ended because the child was killed at the deadline, not
    /// because the CLI answered.
    func disarm() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        settled = true
        return expired
    }

    /// True if this call is the one that expired the watchdog — false if the
    /// test disarmed it first, in which case nothing is killed.
    private func expire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return false }
        settled = true
        expired = true
        return true
    }

}
