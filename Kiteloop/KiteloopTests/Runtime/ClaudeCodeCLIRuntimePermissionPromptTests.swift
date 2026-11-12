import XCTest
import os
import KiteloopCore
@testable import Kiteloop

/// A session's permission prompts through a real stdout reader: they go to
/// the session's own listener, never into a turn's stream, whether or not a
/// turn is listening when they arrive.
final class ClaudeCodeCLIRuntimePermissionPromptTests: XCTestCase {

    private let ask = #"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"make"},"tool_use_id":"toolu_1"}}"#
    private let takeBack = #"{"type":"control_cancel_request","request_id":"req-1"}"#
    private let text = #"{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}"#
    private let result = #"{"type":"result","subtype":"success","result":"done","session_id":"s"}"#

    private func collect(_ prompts: AsyncStream<PermissionPrompt.Line>) -> (lines: OSAllocatedUnfairLock<[PermissionPrompt.Line]>, done: OSAllocatedUnfairLock<Bool>) {
        let lines = OSAllocatedUnfairLock<[PermissionPrompt.Line]>(initialState: [])
        let done = OSAllocatedUnfairLock(initialState: false)
        Task {
            for await line in prompts { lines.withLock { $0.append(line) } }
            done.withLock { $0 = true }
        }
        return (lines, done)
    }

    /// A subagent still running after its turn's `result` asks when no turn
    /// is listening; the question is not dropped with the rest of what
    /// arrives then.
    @MainActor
    func testAPromptBetweenTurnsReachesTheListener() async throws {
        let pipe = Pipe()
        let runtime = ClaudeCodeCLIRuntime()
        let session = AgentSession(id: "prompt-between", agentID: "agent", startedAt: .now)
        runtime.startStdoutReader(sessionID: session.id, stdoutPipe: pipe)
        let heard = collect(runtime.permissionPrompts(of: session))

        pipe.fileHandleForWriting.write(Data((ask + "\n" + takeBack + "\n").utf8))

        try await eventually("both prompt lines to reach the listener") { heard.lines.withLock { $0.count } == 2 }
        let lines = heard.lines.withLock { $0 }
        guard case .request(let request) = lines[0] else { return XCTFail("the first line is the request") }
        XCTAssertEqual(request.id, "req-1")
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(lines[1], .cancelled(requestID: "req-1"))

        try pipe.fileHandleForWriting.close()
        try await eventually("the prompt stream to end with the session") { heard.done.withLock { $0 } }
    }

    /// A prompt in the middle of a turn is not part of what the turn says.
    @MainActor
    func testAPromptDuringATurnStaysOutOfTheTurnsStream() async throws {
        let pipe = Pipe()
        let runtime = ClaudeCodeCLIRuntime()
        let session = AgentSession(id: "prompt-in-turn", agentID: "agent", startedAt: .now)
        runtime.startStdoutReader(sessionID: session.id, stdoutPipe: pipe)
        let heard = collect(runtime.permissionPrompts(of: session))
        let (turn, continuation) = AsyncStream<StreamEvent>.makeStream()
        _ = runtime.registerContinuation(continuation, sessionID: session.id)

        pipe.fileHandleForWriting.write(Data([text, ask, result].map { $0 + "\n" }.joined().utf8))

        var kinds: [String] = []
        for await event in turn {
            switch event {
            case .assistantText: kinds.append("text")
            case .result: kinds.append("result")
            default: kinds.append("other")
            }
        }
        XCTAssertEqual(kinds, ["text", "result"])
        try await eventually("the prompt to reach the listener") { heard.lines.withLock { $0.count } == 1 }
        try pipe.fileHandleForWriting.close()
    }

    /// The session waits on every prompt without limit, so one that arrives
    /// before anybody listens is kept for whoever does.
    @MainActor
    func testAPromptBeforeAnyoneListensIsKeptForTheFirstListener() async throws {
        let pipe = Pipe()
        let runtime = ClaudeCodeCLIRuntime()
        let session = AgentSession(id: "prompt-held", agentID: "agent", startedAt: .now)
        runtime.startStdoutReader(sessionID: session.id, stdoutPipe: pipe)
        let (turn, continuation) = AsyncStream<StreamEvent>.makeStream()
        _ = runtime.registerContinuation(continuation, sessionID: session.id)
        // The result after the prompt says the reader is past it.
        pipe.fileHandleForWriting.write(Data((ask + "\n" + result + "\n").utf8))
        for await _ in turn {}

        let heard = collect(runtime.permissionPrompts(of: session))

        try await eventually("the held prompt to reach the late listener") { heard.lines.withLock { $0.count } == 1 }
        try pipe.fileHandleForWriting.close()
    }
}
