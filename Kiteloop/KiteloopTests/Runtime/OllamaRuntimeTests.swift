import XCTest
import KiteloopCore
@testable import Kiteloop

/// Wire-level tests for `OllamaRuntime` — the `/api/chat` turn path and the
/// `/api/tags` health probes — driven against a stub server the test stands up
/// itself on loopback TCP: no `ollama serve` required, and none of these can
/// silently no-op the way a smoke test against a real install would on a
/// machine without Ollama running.
final class OllamaRuntimeTests: XCTestCase {
    private var stub: StubOllamaServer?

    override func tearDown() {
        stub?.stop()
        stub = nil
        super.tearDown()
    }

    // MARK: - Happy path

    func testDeltaChunksYieldAssistantTextAndAccumulateIntoTheResult() async throws {
        let stub = try startStub { _, _, writer in
            writer.writeLine(chunk(content: "Hel"))
            writer.writeLine(chunk(content: "lo, "))
            writer.writeLine(chunk(content: "world"))
            writer.writeLine(doneChunk(promptEvalCount: 7, evalCount: 3))
        }
        let runtime = OllamaRuntime(baseURL: stub.baseURL)
        let session = try await runtime.startSession(agent: ollamaAgent(), cwd: try makeTemporaryDirectory(), strategy: .fresh)

        let events = await collect(runtime.send("hi", attachments: [], to: session))

        XCTAssertEqual(labels(events), [
            "assistantText(Hel)",
            "assistantText(lo, )",
            "assistantText(world)",
            "result"
        ])
        let result = try XCTUnwrap(firstResult(events))
        XCTAssertEqual(result.text, "Hello, world", "the result carries the accumulated deltas")
        XCTAssertEqual(result.sessionID, session.id)
        XCTAssertEqual(result.inputTokens, 7, "the input token count comes from the done frame's prompt_eval_count")
        XCTAssertEqual(result.outputTokens, 3, "the output token count comes from the done frame's eval_count")
    }

    func testHistoryCarriesTheUserAndAssistantTurnsIntoTheNextRequest() async throws {
        let stub = try startStub { index, _, writer in
            writer.writeLine(chunk(content: "A\(index + 1)"))
            writer.writeLine(doneChunk())
        }
        let runtime = OllamaRuntime(baseURL: stub.baseURL)
        let session = try await runtime.startSession(
            agent: ollamaAgent(systemPrompt: "You are terse."),
            cwd: try makeTemporaryDirectory(),
            strategy: .fresh
        )

        _ = await collect(runtime.send("first question", attachments: [], to: session))
        _ = await collect(runtime.send("second question", attachments: [], to: session))

        XCTAssertEqual(stub.requests.count, 2)
        let second = try XCTUnwrap(parse(stub.requests[1]))
        XCTAssertEqual(second["messages"] as? [[String: String]], [
            ["role": "system", "content": "You are terse."],
            ["role": "user", "content": "first question"],
            ["role": "assistant", "content": "A1"],
            ["role": "user", "content": "second question"]
        ], "the prior turns ride on the next request")
    }

    // MARK: - Interrupt

    /// Drips one chunk, waits for the test to call `interrupt` mid-stream, then
    /// tries to write a further chunk the runtime must not surface — proving the
    /// turn stops reading rather than only reacting to a closed socket by luck.
    func testInterruptStopsYieldingDeltasAndEndsTheTurnWithAResult() async throws {
        let interrupted = DispatchSemaphore(value: 0)
        let doneWriting = DispatchSemaphore(value: 0)
        let connectionWasDropped = LockedBox(false)
        let stub = try startStub { _, _, writer in
            writer.writeLine(chunk(content: "before"))
            _ = interrupted.wait(timeout: .now() + 5)
            // Retry the write for a couple of seconds: the runtime's
            // cancellation tears the connection down asynchronously, so the
            // very next write can still land in the local send buffer.
            connectionWasDropped.value = writer.writeUntilDropped(chunk(content: "after"), timeout: .now() + 2)
            doneWriting.signal()
        }
        let runtime = OllamaRuntime(baseURL: stub.baseURL)
        let session = try await runtime.startSession(agent: ollamaAgent(), cwd: try makeTemporaryDirectory(), strategy: .fresh)

        var events: [StreamEvent] = []
        for await event in runtime.send("hi", attachments: [], to: session) {
            events.append(event)
            if case .assistantText("before", _) = event {
                runtime.interrupt(session: session)
                interrupted.signal()
            }
        }

        XCTAssertEqual(doneWriting.wait(timeout: .now() + 5), .success, "the stub's write attempt did not hang")
        XCTAssertTrue(connectionWasDropped.value, "the stub sees the connection dropped rather than the remaining lines consumed")
        XCTAssertEqual(labels(events), ["assistantText(before)", "result"], "no delta sent after the interrupt is yielded, and the turn still ends with a result")
        let result = try XCTUnwrap(firstResult(events))
        XCTAssertEqual(result.text, "before", "the result carries whatever text had arrived before the interrupt")
    }

    func testInterruptedTurnEndsWithAResultNotAnOllamaErrorSystemEvent() async throws {
        let interrupted = DispatchSemaphore(value: 0)
        let stub = try startStub { _, _, writer in
            writer.writeLine(chunk(content: "partial"))
            _ = interrupted.wait(timeout: .now() + 5)
        }
        let runtime = OllamaRuntime(baseURL: stub.baseURL)
        let session = try await runtime.startSession(agent: ollamaAgent(), cwd: try makeTemporaryDirectory(), strategy: .fresh)

        var events: [StreamEvent] = []
        for await event in runtime.send("hi", attachments: [], to: session) {
            events.append(event)
            if case .assistantText("partial", _) = event {
                runtime.interrupt(session: session)
                interrupted.signal()
            }
        }

        XCTAssertFalse(labels(events).contains("system(error)"), "a cancellation is not reported as an Ollama error")
        let result = try XCTUnwrap(firstResult(events))
        XCTAssertFalse(result.text.contains("Ollama error"), "the result text is the turn's own content, not yieldError's message")
    }

    /// The session an interrupted turn belongs to must stay usable: the next
    /// `send` gets answered rather than told the session is gone.
    func testInterruptLeavesTheSessionUsableForTheNextSend() async throws {
        let interrupted = DispatchSemaphore(value: 0)
        let stub = try startStub { index, _, writer in
            if index == 0 {
                writer.writeLine(chunk(content: "before"))
                _ = interrupted.wait(timeout: .now() + 5)
            } else {
                writer.writeLine(chunk(content: "second reply"))
                writer.writeLine(doneChunk())
            }
        }
        let runtime = OllamaRuntime(baseURL: stub.baseURL)
        let session = try await runtime.startSession(agent: ollamaAgent(), cwd: try makeTemporaryDirectory(), strategy: .fresh)

        for await event in runtime.send("first question", attachments: [], to: session) {
            if case .assistantText("before", _) = event {
                runtime.interrupt(session: session)
                interrupted.signal()
            }
        }

        let second = await collect(runtime.send("second question", attachments: [], to: session))
        XCTAssertFalse(labels(second).contains("system(error)"), "Ollama answers the next send instead of reporting the session missing")
        let result = try XCTUnwrap(firstResult(second))
        XCTAssertEqual(result.text, "second reply")
    }

    // MARK: - Stop

    func testStopStillMakesTheNextSendAnswerSessionNotFound() async throws {
        let stub = try startStub { _, _, writer in
            writer.writeLine(chunk(content: "ok"))
            writer.writeLine(doneChunk())
        }
        let runtime = OllamaRuntime(baseURL: stub.baseURL)
        let session = try await runtime.startSession(agent: ollamaAgent(), cwd: try makeTemporaryDirectory(), strategy: .fresh)
        _ = await collect(runtime.send("hi", attachments: [], to: session))

        runtime.stop(session: session)

        let events = await collect(runtime.send("hello again", attachments: [], to: session))
        XCTAssertEqual(labels(events), ["system(error)"])
        XCTAssertEqual(systemErrorMessages(events), ["Session not found"])
    }

    // MARK: - Health probes

    func testIsAvailableAnswersTrueOffTheTagsEndpoint() async throws {
        let paths = LockedBox<[String]>([])
        let stub = try startStub { _, request, writer in
            paths.value.append(request.path)
            writer.writeLine(tagsPayload(models: ["llama3.1:latest"]))
        }

        let available = await OllamaRuntime.isAvailable(baseURL: stub.baseURL)

        XCTAssertTrue(available, "a 200 from /api/tags is Ollama running")
        XCTAssertEqual(paths.value, ["/api/tags"], "availability is probed on the tags endpoint")
    }

    func testIsAvailableAnswersFalseWhenNothingIsListening() async throws {
        let available = await OllamaRuntime.isAvailable(baseURL: try unusedLoopbackBaseURL())

        XCTAssertFalse(available, "a refused connection is Ollama not running")
    }

    func testAvailableModelsReadsTheModelNamesOffOneTagsRequest() async throws {
        let paths = LockedBox<[String]>([])
        let stub = try startStub { _, request, writer in
            paths.value.append(request.path)
            writer.writeLine(tagsPayload(models: ["llama3.1:latest", "qwen2.5-coder:7b"]))
        }

        let models = await OllamaRuntime.availableModels(baseURL: stub.baseURL)

        XCTAssertEqual(models, ["llama3.1:latest", "qwen2.5-coder:7b"], "the names come from the stub's own payload")
        XCTAssertEqual(paths.value, ["/api/tags"], "the status reads /api/tags once, not once to check and once to list")
    }

    func testAvailableModelsAnswersAnEmptyListWhenOllamaHasNothingPulled() async throws {
        let stub = try startStub { _, _, writer in
            writer.writeLine(tagsPayload(models: []))
        }

        let models = await OllamaRuntime.availableModels(baseURL: stub.baseURL)

        XCTAssertEqual(models, [], "an Ollama running with nothing pulled answers an empty list, not nil")
    }

    func testAvailableModelsAnswersNilWhenNothingIsListening() async throws {
        let models = await OllamaRuntime.availableModels(baseURL: try unusedLoopbackBaseURL())

        XCTAssertNil(models, "unreachable is nil, told apart from the empty list a running Ollama answers")
    }

    // MARK: - Harness

    private func startStub(_ script: @escaping @Sendable (Int, StubRequest, StubLineWriter) -> Void) throws -> StubOllamaServer {
        let server = try StubOllamaServer(script: script)
        stub = server
        return server
    }

    /// A loopback URL nothing answers on: a stub is bound to claim a
    /// kernel-assigned port and torn down again, so the port is known and
    /// known-closed rather than guessed.
    private func unusedLoopbackBaseURL() throws -> URL {
        let server = try StubOllamaServer { _, _, _ in }
        let url = server.baseURL
        server.stop()
        return url
    }

    private func collect(_ stream: AsyncStream<StreamEvent>) async -> [StreamEvent] {
        var events: [StreamEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}

// MARK: - Event readers

private func labels(_ events: [StreamEvent]) -> [String] {
    events.map { event in
        switch event {
        case .assistantText(let text, _): return "assistantText(\(text))"
        case .system(let subtype, _): return "system(\(subtype))"
        case .result: return "result"
        default: return "other"
        }
    }
}

private func firstResult(_ events: [StreamEvent]) -> StreamEvent.ResultPayload? {
    for event in events {
        if case .result(let payload) = event { return payload }
    }
    return nil
}

private func systemErrorMessages(_ events: [StreamEvent]) -> [String] {
    events.compactMap { (event: StreamEvent) -> String? in
        guard case .system(let subtype, let payload) = event, subtype == "error" else { return nil }
        return payload["message"] as? String
    }
}

// MARK: - Fixtures

private func ollamaAgent(systemPrompt: String = "") -> Agent {
    Agent(
        name: "Local",
        model: "ollama",
        systemPrompt: systemPrompt,
        tools: [],
        denied: [],
        permissionMode: "default",
        runtimeKind: "ollama"
    )
}

private func parse(_ body: String) -> [String: Any]? {
    guard let data = body.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func chunk(content: String) -> String {
    frame(["model": "llama3.1", "message": ["role": "assistant", "content": content], "done": false])
}

private func doneChunk(promptEvalCount: Int = 0, evalCount: Int = 0) -> String {
    frame([
        "model": "llama3.1",
        "message": ["role": "assistant", "content": ""],
        "done": true,
        "prompt_eval_count": promptEvalCount,
        "eval_count": evalCount
    ])
}

/// `ollama serve`'s `/api/tags` body: one entry per pulled model.
private func tagsPayload(models: [String]) -> String {
    frame(["models": models.map { ["name": $0, "size": 0] }])
}

private func frame(_ fields: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: fields),
          let line = String(data: data, encoding: .utf8) else { return "{}" }
    return line
}

// MARK: - Stub Ollama server

private enum StubOllamaError: Error {
    case failed(String)
}

/// A lock-protected mutable cell — what a `@Sendable` stub script needs to
/// report a result back to the test after running on its own thread, since a
/// plain captured `var` is a data race under strict concurrency even though
/// the semaphores around it make the actual access single-threaded at a time.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Writes one NDJSON line at a time to a connection, so a script can pause
/// between writes — e.g. wait on a semaphore for the test to call `interrupt`
/// before writing more — which a canned all-at-once response cannot express.
/// `SO_NOSIGPIPE` is set on the connection so a write after the client has
/// dropped it fails with `EPIPE` instead of killing the test process with
/// `SIGPIPE`, which is exactly the case an interrupt test needs to observe.
private final class StubLineWriter {
    let fd: Int32

    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Returns whether the write reached the socket buffer. `false` means the
    /// peer had already dropped the connection.
    @discardableResult
    func writeLine(_ line: String) -> Bool {
        let out = line + "\n"
        let count = out.withCString { Darwin.write(fd, $0, strlen($0)) }
        return count == out.utf8.count
    }

    /// Writes the same line repeatedly, waiting briefly between attempts,
    /// until a write fails or `timeout` passes. A cancelled `Task` tears its
    /// connection down asynchronously, so the write immediately following an
    /// interrupt can still land in the local send buffer — this is what lets
    /// a test wait out that race instead of asserting on the first attempt.
    /// Returns whether a failed write was observed.
    func writeUntilDropped(_ line: String, timeout: DispatchTime) -> Bool {
        while DispatchTime.now() < timeout {
            if !writeLine(line) { return true }
            usleep(50_000)
        }
        return false
    }
}

/// One request the stub read: the path off the request line, so a script can
/// tell an `/api/tags` probe from an `/api/chat` turn, and the body that
/// followed it.
private struct StubRequest {
    let path: String
    let body: String
}

/// A stand-in for `ollama serve`'s `/api/chat` and `/api/tags`. Binds a TCP
/// listener on `127.0.0.1` with a kernel-assigned port, accepts on a background
/// thread, and serves one canned response per connection — `OllamaRuntime`
/// opens a fresh request per `send` and per health probe, so the script is
/// handed the connection's index alongside the request that arrived on it.
private final class StubOllamaServer: @unchecked Sendable {
    let baseURL: URL

    private let listenFD: Int32
    private let script: @Sendable (Int, StubRequest, StubLineWriter) -> Void
    private let lock = NSLock()
    private var received: [String] = []
    private var stopping = false
    private let finished = DispatchSemaphore(value: 0)

    /// Every request body the listener read, as raw JSON text.
    var requests: [String] { lock.withLock { received } }

    init(script: @escaping @Sendable (Int, StubRequest, StubLineWriter) -> Void) throws {
        self.script = script

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StubOllamaError.failed("socket: \(Self.errnoText())") }
        self.listenFD = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addrLen) }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw StubOllamaError.failed("bind: \(Self.errnoText())")
        }
        guard Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw StubOllamaError.failed("listen: \(Self.errnoText())")
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &boundLen) }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!

        DispatchQueue.global(qos: .userInitiated).async { [self] in serve() }
    }

    func stop() {
        lock.withLock { stopping = true }
        _ = finished.wait(timeout: .now() + 5)
    }

    private var isStopping: Bool { lock.withLock { stopping } }

    private func serve() {
        var index = 0
        while !isStopping {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 100) > 0 else { continue }

            let client = Darwin.accept(listenFD, nil, nil)
            guard client >= 0 else { continue }

            guard let request = Self.readRequest(from: client) else {
                Darwin.close(client)
                continue
            }
            lock.withLock { received.append(request.body) }

            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n"
            _ = head.withCString { Darwin.write(client, $0, strlen($0)) }

            script(index, request, StubLineWriter(fd: client))
            Darwin.close(client)
            index += 1
        }
        Darwin.close(listenFD)
        finished.signal()
    }

    /// Reads headers, then exactly `Content-Length` bytes of body — enough to
    /// stand in for `ollama serve`'s request framing without a general HTTP
    /// parser.
    private static func readRequest(from fd: Int32) -> StubRequest? {
        var bytes = [UInt8]()
        let headerEnd: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

        func headerRange() -> Range<Int>? {
            guard bytes.count >= headerEnd.count else { return nil }
            for start in 0...(bytes.count - headerEnd.count) {
                if Array(bytes[start..<start + headerEnd.count]) == headerEnd {
                    return start..<(start + headerEnd.count)
                }
            }
            return nil
        }

        var headerRangeFound: Range<Int>?
        while headerRangeFound == nil {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 2000) > 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &buf, buf.count)
            if count <= 0 { return nil }
            bytes.append(contentsOf: buf[0..<count])
            headerRangeFound = headerRange()
        }
        guard let range = headerRangeFound,
              let headerText = String(bytes: bytes[0..<range.lowerBound], encoding: .utf8) else { return nil }

        let contentLength = Self.contentLength(inHeader: headerText)

        var bodyBytes = Array(bytes[range.upperBound...])
        while bodyBytes.count < contentLength {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 2000) > 0 else { break }
            var buf = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &buf, buf.count)
            if count <= 0 { break }
            bodyBytes.append(contentsOf: buf[0..<count])
        }
        return StubRequest(
            path: Self.path(inHeader: headerText),
            body: String(bytes: bodyBytes, encoding: .utf8) ?? ""
        )
    }

    /// The path off the request line — `/api/tags` out of `GET /api/tags HTTP/1.1`.
    private static func path(inHeader header: String) -> String {
        let requestLine = header.components(separatedBy: "\r\n").first ?? ""
        let fields = requestLine.split(separator: " ")
        return fields.count >= 2 ? String(fields[1]) : ""
    }

    private static func contentLength(inHeader header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
