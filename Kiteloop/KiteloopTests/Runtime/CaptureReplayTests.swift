import XCTest
@testable import Kiteloop

/// Tests for the capture/replay mechanism.
/// Verifies that RecordingAgentRuntime faithfully captures events and
/// ReplayAgentRuntime replays them with identical content.
final class CaptureReplayTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-replay")
    }

    // MARK: - CodableStreamEvent Round-Trip

    /// Every StreamEvent case survives encode → decode → toStreamEvent() faithfully.
    func testCodableStreamEvent_RoundTrip() throws {
        let events: [StreamEvent] = [
            .assistantText("Hello world"),
            .thinking("Let me think..."),
            .toolUse(id: "tc-1", name: "bash", input: #"{"command":"ls"}"#),
            .toolResult(id: "tc-1", output: "file1.txt\nfile2.txt"),
            .image(base64Data: "aGVsbG8=", mimeType: "image/png"),
            .hook(StreamEvent.HookPayload(
                hookType: "pre", hookName: "lint", toolName: "bash",
                output: "ok", exitCode: 0
            )),
            .result(StreamEvent.ResultPayload(
                text: "Done", costUSD: 0.003, durationMs: 1500,
                inputTokens: 100, outputTokens: 50,
                cacheCreationInputTokens: 10, cacheReadInputTokens: 90,
                sessionID: "sess-123",
                permissionDenials: [StreamEvent.PermissionDenial(toolName: "bash", detail: "rm -rf /")]
            )),
            .unknown("mystery_type")
        ]

        for original in events {
            let codable = CodableStreamEvent.from(original)
            let data = try JSONEncoder().encode(codable)
            let decoded = try JSONDecoder().decode(CodableStreamEvent.self, from: data)
            let reconstituted = decoded.toStreamEvent()

            assertStreamEventsEqual(original, reconstituted,
                                    message: "Round-trip failed for \(original)")
        }
    }

    // MARK: - RecordingAgentRuntime

    /// Recording captures all events from a wrapped runtime and persists to disk.
    func testRecording_CapturesEventsAndWritesToDisk() async throws {
        let inner = MockAgentRuntime()
        inner.events = [
            .assistantText("chunk 1"),
            .assistantText("chunk 2"),
            .result(StreamEvent.ResultPayload(
                text: "chunk 1chunk 2", costUSD: 0.001, durationMs: 200,
                inputTokens: 10, outputTokens: 5,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "mock-session", permissionDenials: []
            ))
        ]

        let recordingDir = tempDir.appendingPathComponent("recordings")
        let recorder = RecordingAgentRuntime(wrapped: inner, outputDirectory: recordingDir)

        let agent = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "You are Alpha.", tools: [],
            denied: [], permissionMode: "default",
            crossAgentAccess: [], state: .idle
        )

        let session = try await recorder.startSession(agent: agent, cwd: tempDir)
        let stream = recorder.send("Hello", attachments: [], to: session)

        var collected: [StreamEvent] = []
        for await event in stream {
            collected.append(event)
        }

        // Events passed through correctly
        XCTAssertEqual(collected.count, 3)
        if case .assistantText(let t, _) = collected[0] { XCTAssertEqual(t, "chunk 1") }
        if case .assistantText(let t, _) = collected[1] { XCTAssertEqual(t, "chunk 2") }

        // Flush and verify file exists
        recorder.flush(sessionID: session.id)

        let files = try FileManager.default.contentsOfDirectory(at: recordingDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "Expected exactly one recording file")

        let data = try Data(contentsOf: files[0])
        let recorded = try JSONDecoder.iso8601Decoder.decode(RecordedSession.self, from: data)
        XCTAssertEqual(recorded.agentID, "alpha")
        XCTAssertEqual(recorded.interactions.count, 1)
        XCTAssertEqual(recorded.interactions[0].requestType, .send)
        XCTAssertEqual(recorded.interactions[0].message, "Hello")
        XCTAssertEqual(recorded.interactions[0].events.count, 3)
    }

    /// Recording captures sendToolResult interactions separately.
    func testRecording_CapturesToolResults() async throws {
        let inner = MockAgentRuntime()
        inner.events = [
            .toolUse(id: "tc-1", name: "message_agent", input: #"{"agent":"Beta"}"#)
        ]
        inner.toolResultEvents = [
            .assistantText("Got it"),
            .result(StreamEvent.ResultPayload(
                text: "Got it", costUSD: 0, durationMs: 50,
                inputTokens: 5, outputTokens: 3,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "mock-session", permissionDenials: []
            ))
        ]

        let recordingDir = tempDir.appendingPathComponent("recordings")
        let recorder = RecordingAgentRuntime(wrapped: inner, outputDirectory: recordingDir)

        let agent = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: [], denied: [],
            permissionMode: "default", crossAgentAccess: [], state: .idle
        )

        let session = try await recorder.startSession(agent: agent, cwd: tempDir)

        // First: send
        let stream1 = recorder.send("test", attachments: [], to: session)
        for await _ in stream1 {}

        // Second: sendToolResult
        let stream2 = recorder.sendToolResult(toolCallID: "tc-1", content: "result data", to: session)
        for await _ in stream2 {}

        recorder.flush(sessionID: session.id)

        let files = try FileManager.default.contentsOfDirectory(at: recordingDir, includingPropertiesForKeys: nil)
        let data = try Data(contentsOf: files[0])
        let recorded = try JSONDecoder.iso8601Decoder.decode(RecordedSession.self, from: data)

        XCTAssertEqual(recorded.interactions.count, 2)
        XCTAssertEqual(recorded.interactions[0].requestType, .send)
        XCTAssertEqual(recorded.interactions[1].requestType, .sendToolResult)
        XCTAssertEqual(recorded.interactions[1].toolCallID, "tc-1")
        XCTAssertEqual(recorded.interactions[1].message, "result data")
    }

    // MARK: - Quit-time flush registry

    /// Two recorders, each still holding a live session, are both flushed by
    /// one call to the app-quit entry point — each into its own output
    /// directory, since nothing else in the app shares one recorder instance.
    func testFlushAllLiveRecordings_FlushesEveryLiveRecorder() async throws {
        let dirA = tempDir.appendingPathComponent("recordings-a")
        let dirB = tempDir.appendingPathComponent("recordings-b")

        let recorderA = RecordingAgentRuntime(wrapped: MockAgentRuntime(), outputDirectory: dirA)
        let recorderB = RecordingAgentRuntime(wrapped: MockAgentRuntime(), outputDirectory: dirB)

        let agent = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: [], denied: [],
            permissionMode: "default", crossAgentAccess: [], state: .idle
        )

        _ = try await recorderA.startSession(agent: agent, cwd: tempDir)
        _ = try await recorderB.startSession(agent: agent, cwd: tempDir)

        RecordingAgentRuntime.flushAllLiveRecordings()

        let filesA = try FileManager.default.contentsOfDirectory(at: dirA, includingPropertiesForKeys: nil)
        let filesB = try FileManager.default.contentsOfDirectory(at: dirB, includingPropertiesForKeys: nil)
        XCTAssertEqual(filesA.count, 1, "recorder A's session should be flushed to its own directory")
        XCTAssertEqual(filesB.count, 1, "recorder B's session should be flushed to its own directory")
    }

    /// A recorder that has since been released is held only weakly by the
    /// registry, so it is gone by the time the quit flush runs and nothing is
    /// written for it.
    func testFlushAllLiveRecordings_SkipsReleasedRecorder() async throws {
        let dir = tempDir.appendingPathComponent("recordings-released")
        var recorder: RecordingAgentRuntime? = RecordingAgentRuntime(
            wrapped: MockAgentRuntime(), outputDirectory: dir
        )

        let agent = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: [], denied: [],
            permissionMode: "default", crossAgentAccess: [], state: .idle
        )
        _ = try await recorder!.startSession(agent: agent, cwd: tempDir)
        recorder = nil

        RecordingAgentRuntime.flushAllLiveRecordings()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.path),
            "a released recorder must not be kept alive by the registry or flushed"
        )
    }

    /// A session `stop(session:)` already wrote to disk is not written again
    /// when the quit-time flush subsequently walks every live recorder.
    func testFlushAllLiveRecordings_DoesNotRewriteASessionAlreadyFlushedByStop() async throws {
        let dir = tempDir.appendingPathComponent("recordings-stopped")
        let recorder = RecordingAgentRuntime(wrapped: MockAgentRuntime(), outputDirectory: dir)

        let agent = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: [], denied: [],
            permissionMode: "default", crossAgentAccess: [], state: .idle
        )
        let session = try await recorder.startSession(agent: agent, cwd: tempDir)
        recorder.stop(session: session)

        RecordingAgentRuntime.flushAllLiveRecordings()

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(
            files.count, 1,
            "stop() already flushed this session; the quit-time flush must not duplicate it"
        )
    }

    // MARK: - ReplayAgentRuntime

    /// Replay produces the exact same events that were recorded.
    func testReplay_ProducesIdenticalEvents() async throws {
        // Create a recording manually
        let session = RecordedSession(
            agentID: "beta",
            sessionID: "sess-beta-1",
            recordedAt: Date(),
            interactions: [
                RecordedInteraction(
                    requestType: .send,
                    timestamp: Date(),
                    message: "[Alpha]: What is 2+2?",
                    attachments: [],
                    toolCallID: nil,
                    events: [
                        TimestampedEvent(offsetMs: 0, event: .assistantText("The answer")),
                        TimestampedEvent(offsetMs: 50, event: .assistantText(" is 4.")),
                        TimestampedEvent(offsetMs: 200, event: .result(.init(
                            text: "The answer is 4.", costUSD: 0.001, durationMs: 200,
                            inputTokens: 10, outputTokens: 5,
                            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                            sessionID: "sess-beta-1", permissionDenials: []
                        )))
                    ]
                )
            ]
        )

        // Save to disk
        let fileURL = tempDir.appendingPathComponent("beta_recording.json")
        let data = try JSONEncoder.iso8601Encoder.encode(session)
        try data.write(to: fileURL)

        // Load and replay
        let replay = try ReplayAgentRuntime.load(from: fileURL)
        let agent = Agent(
            id: "beta", name: "Beta", model: "haiku",
            systemPrompt: "", tools: [], denied: [],
            permissionMode: "default", crossAgentAccess: [], state: .idle
        )
        let replaySession = try await replay.startSession(agent: agent, cwd: tempDir)
        let stream = replay.send("[Alpha]: What is 2+2?", to: replaySession)

        var events: [StreamEvent] = []
        for await event in stream {
            events.append(event)
        }

        XCTAssertEqual(events.count, 3)
        if case .assistantText(let t, _) = events[0] { XCTAssertEqual(t, "The answer") }
        if case .assistantText(let t, _) = events[1] { XCTAssertEqual(t, " is 4.") }
        if case .result(let r) = events[2] {
            XCTAssertEqual(r.text, "The answer is 4.")
            XCTAssertEqual(r.costUSD, 0.001, accuracy: 0.0001)
        }

        XCTAssertTrue(replay.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    /// Replay handles multiple sequential interactions (send then sendToolResult).
    func testReplay_MultipleInteractionsInSequence() async throws {
        let session = RecordedSession(
            agentID: "alpha",
            sessionID: "sess-alpha-1",
            recordedAt: Date(),
            interactions: [
                RecordedInteraction(
                    requestType: .send,
                    timestamp: Date(),
                    message: "Ask Beta",
                    attachments: [],
                    toolCallID: nil,
                    events: [
                        TimestampedEvent(offsetMs: 0, event: .toolUse(
                            id: "tc-1", name: "message_agent",
                            input: #"{"agent":"Beta","message":"hi"}"#
                        ))
                    ]
                ),
                RecordedInteraction(
                    requestType: .sendToolResult,
                    timestamp: Date(),
                    message: "Beta says hello",
                    attachments: [],
                    toolCallID: "tc-1",
                    events: [
                        TimestampedEvent(offsetMs: 0, event: .assistantText("Beta responded: hello")),
                        TimestampedEvent(offsetMs: 100, event: .result(.init(
                            text: "Beta responded: hello", costUSD: 0.002, durationMs: 100,
                            inputTokens: 20, outputTokens: 10,
                            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                            sessionID: "sess-alpha-1", permissionDenials: []
                        )))
                    ]
                )
            ]
        )

        let fileURL = tempDir.appendingPathComponent("alpha_recording.json")
        let data = try JSONEncoder.iso8601Encoder.encode(session)
        try data.write(to: fileURL)

        let replay = try ReplayAgentRuntime.load(from: fileURL)
        let agent = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: ["message_agent"], denied: [],
            permissionMode: "default", crossAgentAccess: ["*"], state: .idle
        )
        let replaySession = try await replay.startSession(agent: agent, cwd: tempDir)

        // First interaction: send → should get toolUse
        let stream1 = replay.send("Ask Beta", to: replaySession)
        var events1: [StreamEvent] = []
        for await event in stream1 { events1.append(event) }

        XCTAssertEqual(events1.count, 1)
        if case .toolUse(_, let name, _, _) = events1[0] {
            XCTAssertEqual(name, "message_agent")
        } else {
            XCTFail("Expected toolUse event")
        }

        // Second interaction: sendToolResult → should get final text
        let stream2 = replay.sendToolResult(toolCallID: "tc-1", content: "Beta says hello", to: replaySession)
        var events2: [StreamEvent] = []
        for await event in stream2 { events2.append(event) }

        XCTAssertEqual(events2.count, 2)
        if case .assistantText(let t, _) = events2[0] {
            XCTAssertEqual(t, "Beta responded: hello")
        }

        XCTAssertTrue(replay.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    /// When recording is exhausted, replay returns a graceful fallback.
    func testReplay_ExhaustedRecording() async throws {
        let session = RecordedSession(
            agentID: "alpha",
            sessionID: "sess-1",
            recordedAt: Date(),
            interactions: [
                RecordedInteraction(
                    requestType: .send,
                    timestamp: Date(),
                    message: "first",
                    attachments: [],
                    toolCallID: nil,
                    events: [
                        TimestampedEvent(offsetMs: 0, event: .assistantText("response 1")),
                        TimestampedEvent(offsetMs: 50, event: .result(.init(
                            text: "response 1", costUSD: 0, durationMs: 50,
                            inputTokens: 5, outputTokens: 3,
                            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                            sessionID: "sess-1", permissionDenials: []
                        )))
                    ]
                )
            ]
        )

        let fileURL = tempDir.appendingPathComponent("alpha.json")
        try JSONEncoder.iso8601Encoder.encode(session).write(to: fileURL)

        let replay = try ReplayAgentRuntime.load(from: fileURL)
        let agent = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: [], denied: [],
            permissionMode: "default", crossAgentAccess: [], state: .idle
        )
        let replaySession = try await replay.startSession(agent: agent, cwd: tempDir)

        // First call — uses the one recorded interaction
        let stream1 = replay.send("first", to: replaySession)
        for await _ in stream1 {}

        // Second call — no more interactions
        let stream2 = replay.send("second", to: replaySession)
        var events: [StreamEvent] = []
        for await event in stream2 { events.append(event) }

        // Should get the exhaustion fallback
        XCTAssertFalse(events.isEmpty)
        if case .assistantText(let t, _) = events[0] {
            XCTAssertTrue(t.contains("replay exhausted"))
        }

        // The exhaustion should be recorded, distinct from an unrecorded agent
        XCTAssertEqual(replay.exhaustions.count, 1)
        XCTAssertEqual(replay.exhaustions[0].agentID, "alpha")
        XCTAssertEqual(replay.exhaustions[0].requestType, .send)
        XCTAssertEqual(replay.exhaustions[0].reason, .cursorExhausted)
    }

    /// Asking for an interaction type the recording never held (only `.send` was
    /// captured) leaves an exhaustion entry naming the type that was asked for.
    func testReplay_WrongRequestType_RecordsExhaustion() async throws {
        let session = RecordedSession(
            agentID: "alpha",
            sessionID: "sess-1",
            recordedAt: Date(),
            interactions: [
                RecordedInteraction(
                    requestType: .send,
                    timestamp: Date(),
                    message: "first",
                    attachments: [],
                    toolCallID: nil,
                    events: [
                        TimestampedEvent(offsetMs: 0, event: .assistantText("response 1")),
                        TimestampedEvent(offsetMs: 50, event: .result(.init(
                            text: "response 1", costUSD: 0, durationMs: 50,
                            inputTokens: 5, outputTokens: 3,
                            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                            sessionID: "sess-1", permissionDenials: []
                        )))
                    ]
                )
            ]
        )

        let fileURL = tempDir.appendingPathComponent("alpha-send-only.json")
        try JSONEncoder.iso8601Encoder.encode(session).write(to: fileURL)

        let replay = try ReplayAgentRuntime.load(from: fileURL)
        let agent = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: [], denied: [],
            permissionMode: "default", crossAgentAccess: [], state: .idle
        )
        let replaySession = try await replay.startSession(agent: agent, cwd: tempDir)

        let stream = replay.sendToolResult(toolCallID: "tc-1", content: "result", to: replaySession)
        for await _ in stream {}

        XCTAssertEqual(replay.exhaustions.count, 1)
        XCTAssertEqual(replay.exhaustions[0].agentID, "alpha")
        XCTAssertEqual(replay.exhaustions[0].requestType, .sendToolResult)
        XCTAssertEqual(replay.exhaustions[0].reason, .cursorExhausted)
    }

    /// Asking for an agent the runtime holds no recording for at all leaves an
    /// exhaustion entry with a reason distinguishable from a merely exhausted cursor.
    func testReplay_NoRecordingForAgent_RecordsDistinctExhaustion() async throws {
        let session = RecordedSession(
            agentID: "alpha",
            sessionID: "sess-1",
            recordedAt: Date(),
            interactions: [
                RecordedInteraction(
                    requestType: .send,
                    timestamp: Date(),
                    message: "first",
                    attachments: [],
                    toolCallID: nil,
                    events: [
                        TimestampedEvent(offsetMs: 0, event: .assistantText("response 1")),
                        TimestampedEvent(offsetMs: 50, event: .result(.init(
                            text: "response 1", costUSD: 0, durationMs: 50,
                            inputTokens: 5, outputTokens: 3,
                            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                            sessionID: "sess-1", permissionDenials: []
                        )))
                    ]
                )
            ]
        )

        let fileURL = tempDir.appendingPathComponent("alpha-only.json")
        try JSONEncoder.iso8601Encoder.encode(session).write(to: fileURL)

        let replay = try ReplayAgentRuntime.load(from: fileURL)

        // Bypass startSession (which would throw for an unrecorded agent) to reach
        // the runtime's own "no recording" branch directly.
        let unknownSession = AgentSession(id: "replay-ghost", agentID: "ghost", startedAt: .now)
        let stream = replay.send("hello", to: unknownSession)
        for await _ in stream {}

        XCTAssertEqual(replay.exhaustions.count, 1)
        XCTAssertEqual(replay.exhaustions[0].agentID, "ghost")
        XCTAssertEqual(replay.exhaustions[0].requestType, .send)
        XCTAssertEqual(replay.exhaustions[0].reason, .noRecordingForAgent)
    }

    /// Full round-trip: record with MockRuntime → save → load → replay matches.
    func testFullRoundTrip_RecordThenReplay() async throws {
        // Step 1: Record
        let inner = MockAgentRuntime()
        inner.events = [
            .assistantText("I'll help with that."),
            .toolUse(id: "tc-99", name: "bash", input: #"{"command":"echo hi"}"#)
        ]
        inner.toolResultEvents = [
            .assistantText("Command executed."),
            .result(StreamEvent.ResultPayload(
                text: "Command executed.", costUSD: 0.002, durationMs: 300,
                inputTokens: 15, outputTokens: 8,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "mock-session", permissionDenials: []
            ))
        ]

        let recordingDir = tempDir.appendingPathComponent("recordings")
        let recorder = RecordingAgentRuntime(wrapped: inner, outputDirectory: recordingDir)

        let agent = Agent(
            id: "gamma", name: "Gamma", model: "sonnet",
            systemPrompt: "You are Gamma.", tools: ["bash"],
            denied: [], permissionMode: "default",
            crossAgentAccess: [], state: .idle
        )

        let session = try await recorder.startSession(agent: agent, cwd: tempDir)
        let s1 = recorder.send("run echo hi", attachments: [], to: session)
        for await _ in s1 {}

        let s2 = recorder.sendToolResult(toolCallID: "tc-99", content: "hi\n", to: session)
        for await _ in s2 {}

        recorder.flush(sessionID: session.id)

        // Step 2: Load recording and replay
        let files = try FileManager.default.contentsOfDirectory(at: recordingDir, includingPropertiesForKeys: nil)
        let replay = try ReplayAgentRuntime.load(from: files[0])
        let replaySession = try await replay.startSession(agent: agent, cwd: tempDir)

        // Replay send
        let r1 = replay.send("run echo hi", to: replaySession)
        var replayEvents1: [StreamEvent] = []
        for await event in r1 { replayEvents1.append(event) }

        XCTAssertEqual(replayEvents1.count, 2)
        if case .assistantText(let t, _) = replayEvents1[0] {
            XCTAssertEqual(t, "I'll help with that.")
        }
        if case .toolUse(let id, let name, _, _) = replayEvents1[1] {
            XCTAssertEqual(id, "tc-99")
            XCTAssertEqual(name, "bash")
        }

        // Replay sendToolResult
        let r2 = replay.sendToolResult(toolCallID: "tc-99", content: "hi\n", to: replaySession)
        var replayEvents2: [StreamEvent] = []
        for await event in r2 { replayEvents2.append(event) }

        XCTAssertEqual(replayEvents2.count, 2)
        if case .assistantText(let t, _) = replayEvents2[0] {
            XCTAssertEqual(t, "Command executed.")
        }
        if case .result(let r) = replayEvents2[1] {
            XCTAssertEqual(r.costUSD, 0.002, accuracy: 0.0001)
            XCTAssertEqual(r.durationMs, 300)
        }

        XCTAssertTrue(replay.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Timing Modes

    /// Instant mode produces events with no delay (< 50ms total).
    func testTimingMode_Instant() async throws {
        let session = RecordedSession(
            agentID: "alpha",
            sessionID: "sess-1",
            recordedAt: Date(),
            interactions: [
                RecordedInteraction(
                    requestType: .send,
                    timestamp: Date(),
                    message: "test",
                    attachments: [],
                    toolCallID: nil,
                    events: [
                        TimestampedEvent(offsetMs: 0, event: .assistantText("a")),
                        TimestampedEvent(offsetMs: 500, event: .assistantText("b")),
                        TimestampedEvent(offsetMs: 1000, event: .assistantText("c")),
                        TimestampedEvent(offsetMs: 2000, event: .result(.init(
                            text: "abc", costUSD: 0, durationMs: 2000,
                            inputTokens: 1, outputTokens: 1,
                            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                            sessionID: "sess-1", permissionDenials: []
                        )))
                    ]
                )
            ]
        )

        let replay = ReplayAgentRuntime(sessions: [session], timingMode: .instant)
        let agent = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: [], denied: [],
            permissionMode: "default", crossAgentAccess: [], state: .idle
        )
        let replaySession = try await replay.startSession(agent: agent, cwd: tempDir)

        let start = Date()
        let stream = replay.send("test", to: replaySession)
        var count = 0
        for await _ in stream { count += 1 }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(count, 4)
        XCTAssertLessThan(elapsed, 0.1, "Instant mode should complete in < 100ms (original was 2000ms)")

        XCTAssertTrue(replay.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Helpers

    private func assertStreamEventsEqual(_ lhs: StreamEvent, _ rhs: StreamEvent, message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        switch (lhs, rhs) {
        case (.assistantText(let a, let parentA), .assistantText(let b, let parentB)):
            XCTAssertEqual(a, b, message, file: file, line: line)
            XCTAssertEqual(parentA, parentB, message, file: file, line: line)
        case (.thinking(let a, let parentA), .thinking(let b, let parentB)):
            XCTAssertEqual(a, b, message, file: file, line: line)
            XCTAssertEqual(parentA, parentB, message, file: file, line: line)
        case (.toolUse(let id1, let n1, let i1, _), .toolUse(let id2, let n2, let i2, _)):
            XCTAssertEqual(id1, id2, message, file: file, line: line)
            XCTAssertEqual(n1, n2, message, file: file, line: line)
            XCTAssertEqual(i1, i2, message, file: file, line: line)
        case (.toolResult(let id1, let o1, _), .toolResult(let id2, let o2, _)):
            XCTAssertEqual(id1, id2, message, file: file, line: line)
            XCTAssertEqual(o1, o2, message, file: file, line: line)
        case (.image(let d1, let m1), .image(let d2, let m2)):
            XCTAssertEqual(d1, d2, message, file: file, line: line)
            XCTAssertEqual(m1, m2, message, file: file, line: line)
        case (.hook(let h1), .hook(let h2)):
            XCTAssertEqual(h1.hookType, h2.hookType, message, file: file, line: line)
            XCTAssertEqual(h1.exitCode, h2.exitCode, message, file: file, line: line)
        case (.result(let r1), .result(let r2)):
            XCTAssertEqual(r1.text, r2.text, message, file: file, line: line)
            XCTAssertEqual(r1.costUSD, r2.costUSD, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(r1.sessionID, r2.sessionID, message, file: file, line: line)
        case (.unknown(let a), .unknown(let b)):
            XCTAssertEqual(a, b, message, file: file, line: line)
        default:
            XCTFail("Events don't match: \(lhs) vs \(rhs) — \(message)", file: file, line: line)
        }
    }
}

private extension JSONEncoder {
    static let iso8601Encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let iso8601Decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
