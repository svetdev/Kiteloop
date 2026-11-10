import XCTest
import KiteloopCore
@testable import Kiteloop

/// Wire-level tests for `CopilotBridgeRuntime`, driven against a stub bridge
/// socket the test stands up itself.
///
/// Nothing here may depend on the environment: each test binds its own `AF_UNIX`
/// listener, serves a canned script over it, and asserts on the events the real
/// runtime's stream yields and on the bytes the listener received. None of them
/// can opt out — which is the point. The live-bridge smoke test that used to sit
/// next door needed VS Code running the bridge extension, so it skipped on every
/// machine, and on the one machine where it would have run it drove no Kiteloop
/// code at all.
final class CopilotBridgeRuntimeTests: XCTestCase {
    private var stub: StubBridgeServer?

    override func tearDown() {
        stub?.stop()
        stub = nil
        super.tearDown()
    }

    // MARK: - Request framing

    func testSendWritesOneNewlineTerminatedChatRequest() async throws {
        let stub = try startStub { _, request in [doneFrame(for: request, content: "ok")] }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(
            agent: copilotAgent(systemPrompt: "You are terse."),
            cwd: temporaryCwd,
            strategy: .fresh
        )

        _ = await collect(runtime.send("hello", attachments: [], to: session))

        XCTAssertEqual(stub.rawRequests.count, 1, "one send opens one connection and writes one request")
        let payload = try XCTUnwrap(stub.rawRequests.first)
        XCTAssertTrue(payload.hasSuffix("\n"), "the request must be newline-terminated")
        XCTAssertFalse(payload.dropLast().contains("\n"), "the request must be a single line")

        let request = try XCTUnwrap(parse(payload))
        XCTAssertEqual(request["type"] as? String, "chat")
        XCTAssertEqual(request["model"] as? String, "gpt-4o",
                       "the agent's model rides on the request, without the app's own copilot- prefix")
        XCTAssertFalse((request["id"] as? String ?? "").isEmpty, "the request must carry an id to match replies against")
        XCTAssertEqual(request["messages"] as? [[String: String]], [
            ["role": "system", "content": "You are terse."],
            ["role": "user", "content": "hello"]
        ])
    }

    func testAttachmentRidesOnTheRequestAsPartOfTheUserTurn() async throws {
        let stub = try startStub { _, request in [doneFrame(for: request, content: "ok")] }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)
        let attachment = ChatAttachment(
            filename: "main.swift",
            data: Data("func main() {}".utf8),
            mimeType: "text/x-swift"
        )

        _ = await collect(runtime.send("review this", attachments: [attachment], to: session))

        let request = try XCTUnwrap(parse(try XCTUnwrap(stub.rawRequests.first)))
        XCTAssertEqual(request["messages"] as? [[String: String]], [
            ["role": "user", "content": "review this\n\n--- main.swift ---\nfunc main() {}"]
        ], "the attached file reaches the bridge under its filename rather than being dropped")
    }

    func testImageAttachmentIsNamedOnTheRequestRatherThanSentAsBase64() async throws {
        let stub = try startStub { _, request in [doneFrame(for: request, content: "ok")] }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let attachment = ChatAttachment(filename: "screenshot.png", data: png, mimeType: "image/png")

        _ = await collect(runtime.send("describe", attachments: [attachment], to: session))

        let payload = try XCTUnwrap(stub.rawRequests.first)
        let request = try XCTUnwrap(parse(payload))
        XCTAssertEqual(request["messages"] as? [[String: String]], [
            ["role": "user", "content": "describe\n\n--- screenshot.png ---\n[not sent: this model cannot see images]"]
        ], "the omission is stated in the prompt instead of nowhere")
        XCTAssertFalse(payload.contains(png.base64EncodedString()), "no base64 image rides on a text-only backend")
    }

    // MARK: - Response frames

    // MARK: - Which model is asked for, and which answered

    /// `copilot` is the app's name for the runtime. Sent as a model it matched
    /// no Copilot family, and the bridge silently answered with the first
    /// model VS Code listed.
    func testTheBareCopilotAliasAsksTheBridgeForNoModel() async throws {
        let stub = try startStub { _, request in [doneFrame(for: request, content: "ok")] }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(
            agent: Agent(name: "Copilot", model: "copilot", systemPrompt: "", tools: [], denied: [],
                         permissionMode: "default", runtimeKind: "copilot"),
            cwd: temporaryCwd, strategy: .fresh)

        _ = await collect(runtime.send("hello", attachments: [], to: session))

        let request = try XCTUnwrap(parse(try XCTUnwrap(stub.rawRequests.first)))
        XCTAssertNil(request["model"], "no model is named, so the bridge takes Copilot's own first")
    }

    func testTheBridgeModelDropsOnlyTheAppsOwnPrefix() {
        XCTAssertNil(CopilotBridgeRuntime.bridgeModel(for: "copilot"))
        XCTAssertNil(CopilotBridgeRuntime.bridgeModel(for: "  "))
        XCTAssertEqual(CopilotBridgeRuntime.bridgeModel(for: "copilot-gpt-4o"), "gpt-4o")
        XCTAssertEqual(CopilotBridgeRuntime.bridgeModel(for: "claude-haiku-5.5"), "claude-haiku-5.5")
    }

    func testADoneFrameNamingItsModelReportsItBeforeTheResult() async throws {
        let stub = try startStub { _, request in
            [frame(["id": requestID(of: request), "type": "done", "content": "ok",
                    "model": "claude-haiku-5.5", "vendor": "copilot", "family": "claude-haiku-5.5"])]
        }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)

        let events = await collect(runtime.send("hello", attachments: [], to: session))

        let reported = events.compactMap { (event: StreamEvent) -> String? in
            guard case .system(let subtype, let payload) = event, subtype == "init" else { return nil }
            return payload["model"] as? String
        }
        XCTAssertEqual(reported, ["claude-haiku-5.5"])
        XCTAssertNotNil(firstResult(events))
    }

    /// A bridge built before `done` carried a model claims nothing.
    func testADoneFrameWithoutAModelReportsNone() async throws {
        let stub = try startStub { _, request in [doneFrame(for: request, content: "ok")] }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)

        let events = await collect(runtime.send("hello", attachments: [], to: session))

        XCTAssertFalse(events.contains { event in
            if case .system(let subtype, _) = event { return subtype == "init" }
            return false
        })
    }

    func testDeltaFramesYieldAssistantTextAndAccumulateIntoTheResult() async throws {
        let stub = try startStub { _, request in
            [
                deltaFrame(for: request, content: "Hel"),
                deltaFrame(for: request, content: "lo, "),
                deltaFrame(for: request, content: "world"),
                doneFrame(for: request)
            ]
        }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)

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
    }

    func testDoneFrameAppendsTheAssistantTurnToTheSessionHistory() async throws {
        let stub = try startStub { index, request in
            [doneFrame(for: request, content: "A\(index + 1)")]
        }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(
            agent: copilotAgent(systemPrompt: "You are terse."),
            cwd: temporaryCwd,
            strategy: .fresh
        )

        let first = await collect(runtime.send("first question", attachments: [], to: session))
        let firstResult = try XCTUnwrap(firstResult(first))
        XCTAssertEqual(firstResult.text, "A1", "a done frame's own content stands in when no delta arrived")

        _ = await collect(runtime.send("second question", attachments: [], to: session))

        XCTAssertEqual(stub.rawRequests.count, 2)
        let second = try XCTUnwrap(parse(stub.rawRequests[1]))
        XCTAssertEqual(second["messages"] as? [[String: String]], [
            ["role": "system", "content": "You are terse."],
            ["role": "user", "content": "first question"],
            ["role": "assistant", "content": "A1"],
            ["role": "user", "content": "second question"]
        ])
    }

    func testErrorFrameYieldsASystemErrorFollowedByAResult() async throws {
        let stub = try startStub { _, request in [errorFrame(for: request, message: "boom")] }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)

        let events = await collect(runtime.send("hi", attachments: [], to: session))

        XCTAssertEqual(labels(events), ["system(error)", "result"], "the error is reported before the leg is closed out")
        XCTAssertEqual(systemErrorMessages(events), ["boom"], "the bridge's own message reaches the caller")
        let result = try XCTUnwrap(firstResult(events))
        XCTAssertEqual(result.text, "Error: boom")
    }

    func testFrameForAnotherRequestIDIsIgnored() async throws {
        let stub = try startStub { _, request in
            [
                deltaFrame(id: "some-other-request", content: "leaked"),
                deltaFrame(for: request, content: "kept"),
                doneFrame(for: request)
            ]
        }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)

        let events = await collect(runtime.send("hi", attachments: [], to: session))

        XCTAssertEqual(labels(events), ["assistantText(kept)", "result"], "a reply addressed elsewhere is dropped")
        let result = try XCTUnwrap(firstResult(events))
        XCTAssertEqual(result.text, "kept")
    }

    // MARK: - History trimming

    func testHistoryCapAppliesToTurnsOnlyAndKeepsTheSystemPrompt() async throws {
        let stub = try startStub { index, request in
            [doneFrame(for: request, content: "A\(index + 1)")]
        }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path, maxHistoryMessages: 2)
        let session = try await runtime.startSession(
            agent: copilotAgent(systemPrompt: "You are terse."),
            cwd: temporaryCwd,
            strategy: .fresh
        )

        for turn in 1...3 {
            _ = await collect(runtime.send("U\(turn)", attachments: [], to: session))
        }

        XCTAssertEqual(stub.rawRequests.count, 3)
        let second = try XCTUnwrap(parse(stub.rawRequests[1]))
        XCTAssertEqual(second["messages"] as? [[String: String]], [
            ["role": "system", "content": "You are terse."],
            ["role": "assistant", "content": "A1"],
            ["role": "user", "content": "U2"]
        ], "the oldest turn falls off once the cap is exceeded")

        let third = try XCTUnwrap(parse(stub.rawRequests[2]))
        XCTAssertEqual(third["messages"] as? [[String: String]], [
            ["role": "system", "content": "You are terse."],
            ["role": "assistant", "content": "A2"],
            ["role": "user", "content": "U3"]
        ], "the system prompt survives the cap however old it gets")
    }

    // MARK: - Interrupt and stop

    /// Drips one delta, waits for the test to call `interrupt` mid-stream, then
    /// writes a further delta the runtime must not surface — proving the read
    /// loop notices the interrupt rather than only reacting to a closed socket.
    func testInterruptStopsYieldingDeltasAndEndsTheTurnWithAResult() async throws {
        let interrupted = DispatchSemaphore(value: 0)
        let stub = try startStreamingStub { _, request, writer in
            writer.write(deltaFrame(for: request, content: "before"))
            _ = interrupted.wait(timeout: .now() + 5)
            writer.write(deltaFrame(for: request, content: "after"))
        }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)

        var events: [StreamEvent] = []
        for await event in runtime.send("hi", attachments: [], to: session) {
            events.append(event)
            if case .assistantText("before", _) = event {
                runtime.interrupt(session: session)
                interrupted.signal()
            }
        }

        XCTAssertEqual(labels(events), ["assistantText(before)", "result"], "no delta sent after the interrupt is yielded, and the turn still ends with a result")
        let result = try XCTUnwrap(firstResult(events))
        XCTAssertEqual(result.text, "before", "the result carries whatever text had arrived before the interrupt")
    }

    /// The session an interrupted turn belongs to must stay usable, and its
    /// history must not carry a user turn with no assistant reply for the next
    /// send to choke on.
    func testInterruptLeavesTheSessionUsableWithConsistentHistory() async throws {
        let interrupted = DispatchSemaphore(value: 0)
        let stub = try startStreamingStub { index, request, writer in
            if index == 0 {
                writer.write(deltaFrame(for: request, content: "before"))
                _ = interrupted.wait(timeout: .now() + 5)
                writer.write(deltaFrame(for: request, content: "after"))
            } else {
                writer.write(doneFrame(for: request, content: "second reply"))
            }
        }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(
            agent: copilotAgent(systemPrompt: "You are terse."),
            cwd: temporaryCwd,
            strategy: .fresh
        )

        for await event in runtime.send("first question", attachments: [], to: session) {
            if case .assistantText("before", _) = event {
                runtime.interrupt(session: session)
                interrupted.signal()
            }
        }

        let second = await collect(runtime.send("second question", attachments: [], to: session))
        XCTAssertFalse(labels(second).contains("system(error)"), "the bridge answers the next send instead of reporting the session missing")

        XCTAssertEqual(stub.rawRequests.count, 2)
        let secondRequest = try XCTUnwrap(parse(stub.rawRequests[1]))
        XCTAssertEqual(secondRequest["messages"] as? [[String: String]], [
            ["role": "system", "content": "You are terse."],
            ["role": "user", "content": "first question"],
            ["role": "assistant", "content": "before"],
            ["role": "user", "content": "second question"]
        ], "the interrupted turn closes out with what arrived, rather than leaving a dangling user message")
    }

    func testStopStillMakesTheNextSendAnswerSessionNotFound() async throws {
        let stub = try startStub { _, request in [doneFrame(for: request, content: "ok")] }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)
        _ = await collect(runtime.send("hi", attachments: [], to: session))

        runtime.stop(session: session)

        let events = await collect(runtime.send("hello again", attachments: [], to: session))
        XCTAssertEqual(labels(events), ["system(error)"])
        XCTAssertEqual(systemErrorMessages(events), ["Session not found"])
    }

    // MARK: - Silence deadline

    /// Against a stub that accepts the connection and then never writes or
    /// closes it, the turn must not park forever: it ends itself with a system
    /// error naming the socket and the deadline, then a result — the shape the
    /// "bridge not running" branch already uses.
    func testQuietBridgeEndsTheTurnWithASystemErrorNamingTheDeadlineThenAResult() async throws {
        let assertionsDone = DispatchSemaphore(value: 0)
        let stub = try startStreamingStub { _, _, _ in
            // Take the request and go quiet, exactly like an extension that
            // accepted the connection and stopped answering.
            _ = assertionsDone.wait(timeout: .now() + 5)
        }
        let runtime = CopilotBridgeRuntime(socketPath: stub.path, silenceDeadline: 0.3)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)

        let events = await collect(runtime.send("hi", attachments: [], to: session))
        assertionsDone.signal()

        XCTAssertEqual(labels(events), ["system(error)", "result"], "a quiet bridge ends the turn instead of parking the read forever")
        let messages = systemErrorMessages(events)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains(stub.path), "the error names the bridge socket: \(messages[0])")
        XCTAssertTrue(messages[0].contains("0.3"), "the error names the silence deadline: \(messages[0])")
        let result = try XCTUnwrap(firstResult(events))
        XCTAssertEqual(result.sessionID, session.id)
    }

    /// `interrupt` must end a turn stuck against a quiet bridge too, not only
    /// one that is streaming — Stop cannot depend on the bridge ever answering.
    func testInterruptEndsTheTurnAgainstAQuietBridge() async throws {
        let requestReceived = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let stub = try startStreamingStub { _, _, _ in
            requestReceived.signal()
            _ = released.wait(timeout: .now() + 5)
        }
        // A deadline long enough that only the interrupt, not the deadline, can
        // be what ends this turn within the test's own timeout below.
        let runtime = CopilotBridgeRuntime(socketPath: stub.path, silenceDeadline: 30)
        let session = try await runtime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)

        let stream = runtime.send("hi", attachments: [], to: session)
        let sendTask = Task {
            var events: [StreamEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        XCTAssertEqual(requestReceived.wait(timeout: .now() + 5), .success, "the stub must have the request in hand before interrupt races it")
        runtime.interrupt(session: session)
        released.signal()

        let events = await sendTask.value
        XCTAssertEqual(labels(events), ["result"], "interrupt ends the quiet turn well short of the silence deadline")
        let result = try XCTUnwrap(firstResult(events))
        XCTAssertEqual(result.text, "", "no text had arrived when the interrupt landed")
    }

    /// A `done` frame delivered only after the read loop has already ticked at
    /// least once on an empty socket must reach the caller exactly as it would
    /// with no tick in between — the bytes a tick leaves half-read must carry
    /// into the next read rather than being dropped or corrupted.
    func testDoneFrameArrivingAfterATickStillReachesTheCallerWhole() async throws {
        let immediateStub = try startStub { _, request in [doneFrame(for: request, content: "Hello, world")] }
        let immediateRuntime = CopilotBridgeRuntime(socketPath: immediateStub.path, silenceDeadline: 5)
        let immediateSession = try await immediateRuntime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)
        let immediateEvents = await collect(immediateRuntime.send("hi", attachments: [], to: immediateSession))
        immediateStub.stop()

        let holdBeforeWriting = DispatchSemaphore(value: 0)
        let delayedStub = try startStreamingStub { _, request, writer in
            // Never signaled: lets the runtime's read loop tick several times
            // on an empty socket before any byte of the frame exists to read.
            _ = holdBeforeWriting.wait(timeout: .now() + 0.35)
            writer.write(doneFrame(for: request, content: "Hello, world"))
        }
        let delayedRuntime = CopilotBridgeRuntime(socketPath: delayedStub.path, silenceDeadline: 5)
        let delayedSession = try await delayedRuntime.startSession(agent: copilotAgent(), cwd: temporaryCwd, strategy: .fresh)
        let delayedEvents = await collect(delayedRuntime.send("hi", attachments: [], to: delayedSession))

        XCTAssertEqual(labels(delayedEvents), labels(immediateEvents))
        let immediateResult = try XCTUnwrap(firstResult(immediateEvents))
        let delayedResult = try XCTUnwrap(firstResult(delayedEvents))
        XCTAssertEqual(delayedResult.text, "Hello, world")
        XCTAssertEqual(delayedResult.text, immediateResult.text, "a tick before the frame arrives must not change what the caller receives")
    }

    func testSilenceDeadlineDefaultsToTheProductionValueWhenNotPassed() {
        XCTAssertEqual(CopilotBridgeRuntime.defaultSilenceDeadline, 120)
    }

    // MARK: - Availability

    func testIsAvailableIsTrueWhileSomethingIsListeningOnTheSocket() async throws {
        // No frames: availability is a connect, not an exchange.
        let stub = try startStub { _, _ in [] }

        let available = await CopilotBridgeRuntime.isAvailable(socketPath: stub.path)

        XCTAssertTrue(available, "a bound, listening bridge socket reads as available")
    }

    func testIsAvailableIsFalseWhenNothingSitsAtThePath() async {
        let path = "/tmp/kl-bridge-absent-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the path names no file to begin with")

        let available = await CopilotBridgeRuntime.isAvailable(socketPath: path)

        XCTAssertFalse(available, "no bridge has ever run here")
    }

    func testIsAvailableIsFalseForASocketFileNobodyIsListeningOn() async throws {
        let path = try abandonedSocketFile()
        defer { unlink(path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the socket file outlives the listener that bound it")

        let available = await CopilotBridgeRuntime.isAvailable(socketPath: path)

        XCTAssertFalse(available, "a file at the path is not a bridge — the connection is refused")
    }

    // MARK: - Harness

    private var temporaryCwd: URL { URL(fileURLWithPath: NSTemporaryDirectory()) }

    /// Binds an `AF_UNIX` socket and closes it without unlinking, leaving behind
    /// exactly what a bridge that exited without cleaning up leaves behind: a
    /// socket file that `connect` refuses.
    private func abandonedSocketFile() throws -> String {
        let path = "/tmp/kl-bridge-stale-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StubBridgeError.failed("socket: \(String(cString: strerror(errno)))") }

        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                UnsafeMutableRawPointer(ptr).copyMemory(from: src, byteCount: strlen(src) + 1)
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addrLen) }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw StubBridgeError.failed("bind \(path): \(reason)")
        }
        Darwin.close(fd)
        return path
    }

    private func startStub(_ script: @escaping @Sendable (Int, String) -> [String]) throws -> StubBridgeServer {
        let server = try StubBridgeServer(script: script)
        stub = server
        return server
    }

    private func startStreamingStub(_ script: @escaping @Sendable (Int, String, StubLineWriter) -> Void) throws -> StubBridgeServer {
        let server = try StubBridgeServer(streaming: script)
        stub = server
        return server
    }

    private func collect(_ stream: AsyncStream<StreamEvent>) async -> [StreamEvent] {
        var events: [StreamEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}

// MARK: - Event readers

/// One short string per event, so a test can assert content *and* order at once.
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

private func copilotAgent(systemPrompt: String = "") -> Agent {
    Agent(
        name: "Copilot",
        model: "copilot-gpt-4o",
        systemPrompt: systemPrompt,
        tools: [],
        denied: [],
        permissionMode: "default",
        runtimeKind: "copilot"
    )
}

private func parse(_ payload: String) -> [String: Any]? {
    let line = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func requestID(of request: String) -> String {
    parse(request)?["id"] as? String ?? ""
}

private func frame(_ fields: [String: String]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: fields),
          let line = String(data: data, encoding: .utf8) else { return "{}" }
    return line
}

private func deltaFrame(id: String, content: String) -> String {
    frame(["id": id, "type": "delta", "content": content])
}

private func deltaFrame(for request: String, content: String) -> String {
    deltaFrame(id: requestID(of: request), content: content)
}

private func doneFrame(for request: String, content: String? = nil) -> String {
    var fields = ["id": requestID(of: request), "type": "done"]
    if let content { fields["content"] = content }
    return frame(fields)
}

private func errorFrame(for request: String, message: String) -> String {
    frame(["id": requestID(of: request), "type": "error", "message": message])
}

// MARK: - Stub bridge

private enum StubBridgeError: Error {
    case failed(String)
}

/// A stand-in for the VS Code bridge extension.
///
/// Binds an `AF_UNIX`/`SOCK_STREAM` listener under `/tmp` — `connectToSocket`
/// copies at most 104 bytes into `sun_path`, and a `/var/folders/...` temp path
/// can approach that — accepts on a background thread, and serves one canned
/// newline-delimited script per connection. The runtime opens a fresh connection
/// per `send`, so the script is handed the connection's index alongside the
/// payload that arrived on it.
/// Writes one line at a time to a connection, rather than the whole script's
/// lines at once — so a script can pause between writes (e.g. wait on a
/// semaphore for the test to call `interrupt` before writing the rest), which
/// the array-returning script variant below cannot express.
private struct StubLineWriter {
    let fd: Int32
    func write(_ line: String) {
        let out = line + "\n"
        _ = out.withCString { Darwin.write(fd, $0, strlen($0)) }
    }
}

private final class StubBridgeServer: @unchecked Sendable {
    let path: String

    private let listenFD: Int32
    private let script: @Sendable (Int, String, StubLineWriter) -> Void
    private let lock = NSLock()
    private var received: [String] = []
    private var stopping = false
    private let finished = DispatchSemaphore(value: 0)

    /// Every payload the listener read, verbatim — trailing newline included, so
    /// a test can assert on the framing and not just on the JSON inside it.
    var rawRequests: [String] { lock.withLock { received } }

    convenience init(script: @escaping @Sendable (Int, String) -> [String]) throws {
        try self.init(streaming: { index, request, writer in
            for line in script(index, request) { writer.write(line) }
        })
    }

    /// - Parameter streaming: given the connection index, the request payload,
    ///   and a writer, writes as many lines as it likes, in its own time. The
    ///   connection stays open, and unwritten, until the closure returns.
    init(streaming script: @escaping @Sendable (Int, String, StubLineWriter) -> Void) throws {
        self.script = script
        self.path = "/tmp/kl-bridge-\(UUID().uuidString.prefix(8)).sock"

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StubBridgeError.failed("socket: \(Self.errnoText())") }
        self.listenFD = fd

        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                UnsafeMutableRawPointer(ptr).copyMemory(from: src, byteCount: strlen(src) + 1)
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addrLen) }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw StubBridgeError.failed("bind \(path): \(Self.errnoText())")
        }
        guard Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            unlink(path)
            throw StubBridgeError.failed("listen \(path): \(Self.errnoText())")
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in serve() }
    }

    /// Stops accepting and waits for the listener thread to let go of the socket,
    /// so a test never leaves a stray file or thread behind.
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

            let request = Self.readRequest(from: client)
            lock.withLock { received.append(request) }
            script(index, request, StubLineWriter(fd: client))
            // Closing ends the runtime's read loop even if the script never sent
            // a terminal frame, so a regression there fails a test instead of
            // hanging the suite.
            Darwin.close(client)
            index += 1
        }
        Darwin.close(listenFD)
        unlink(path)
        finished.signal()
    }

    /// Reads everything the runtime wrote for one request: bytes up to the first
    /// newline, plus a short grace poll afterwards so "nothing followed the
    /// newline" is something the test observed rather than assumed.
    private static func readRequest(from fd: Int32) -> String {
        var bytes = [UInt8]()
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let timeout: Int32 = bytes.contains(0x0A) ? 50 : 2000
            guard poll(&pfd, 1, timeout) > 0 else { break }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            bytes.append(contentsOf: chunk[0..<count])
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
