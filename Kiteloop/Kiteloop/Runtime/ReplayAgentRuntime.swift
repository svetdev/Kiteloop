import Foundation
import KiteloopCore
import os.log

private let log = Logger(subsystem: "ai.kasatkin.kiteloop", category: "replay-runtime")

/// Replays recorded sessions with configurable timing fidelity.
/// Produces the exact same StreamEvent sequence as the original session,
/// including real JSON parsing artifacts, partial text chunks, and timing gaps.
///
/// Usage:
///   let recording = try ReplayAgentRuntime.load(from: recordingURL)
///   // or load from bundle:
///   let recording = try ReplayAgentRuntime.load(resource: "alpha_ping_pong", bundle: .module)
///
final class ReplayAgentRuntime: AgentRuntime, @unchecked Sendable {
    enum TimingMode {
        /// Replay with original timing (real delays between events)
        case realTime
        /// Replay at N× speed (e.g., 10× = 100ms delay becomes 10ms)
        case accelerated(factor: Double)
        /// No delays — emit all events immediately (fastest for CI)
        case instant
    }

    /// Why a replayed stream fell back to `emptyStream()` instead of a recorded interaction.
    enum ExhaustionReason: Equatable {
        /// No recording exists for the requesting agent at all.
        case noRecordingForAgent
        /// A recording exists, but its cursor has no remaining interaction of the requested type.
        case cursorExhausted
    }

    private let sessions: [String: RecordedSession]
    private let timingMode: TimingMode
    private let lock = NSLock()
    private var cursors: [String: Int] = [:]
    private(set) var replayedInteractions: [(agentID: String, requestType: RecordedInteraction.RequestType, message: String)] = []
    private(set) var exhaustions: [(agentID: String, requestType: RecordedInteraction.RequestType, reason: ExhaustionReason)] = []

    init(sessions: [RecordedSession], timingMode: TimingMode = .instant) {
        var map: [String: RecordedSession] = [:]
        for session in sessions {
            map[session.agentID] = session
        }
        self.sessions = map
        self.timingMode = timingMode
    }

    /// Load a single recorded session from a JSON file.
    static func load(from url: URL) throws -> ReplayAgentRuntime {
        let data = try Data(contentsOf: url)
        let session = try JSONDecoder.recording.decode(RecordedSession.self, from: data)
        return ReplayAgentRuntime(sessions: [session])
    }

    /// Load multiple recorded sessions from a directory.
    static func loadAll(from directory: URL, timingMode: TimingMode = .instant) throws -> ReplayAgentRuntime {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var sessions: [RecordedSession] = []
        for file in files {
            let data = try Data(contentsOf: file)
            let session = try JSONDecoder.recording.decode(RecordedSession.self, from: data)
            sessions.append(session)
        }
        return ReplayAgentRuntime(sessions: sessions, timingMode: timingMode)
    }

    /// Load from test bundle resource.
    static func load(resource: String, extension ext: String = "json", bundle: Bundle, timingMode: TimingMode = .instant) throws -> ReplayAgentRuntime {
        guard let url = bundle.url(forResource: resource, withExtension: ext) else {
            throw ReplayError.resourceNotFound(resource)
        }
        let data = try Data(contentsOf: url)
        let session = try JSONDecoder.recording.decode(RecordedSession.self, from: data)
        return ReplayAgentRuntime(sessions: [session], timingMode: timingMode)
    }

    // MARK: - AgentRuntime

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        guard sessions[agent.id] != nil else {
            throw ReplayError.noRecordingForAgent(agent.id)
        }
        lock.withLock {
            cursors[agent.id] = 0
        }
        log.info("Replay session started for \(agent.id)")
        return AgentSession(id: "replay-\(agent.id)", agentID: agent.id, startedAt: .now)
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        lock.lock()
        replayedInteractions.append((agentID: session.agentID, requestType: .send, message: message))
        lock.unlock()
        return replayNextInteraction(for: session.agentID, expectedType: .send, message: message)
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        lock.lock()
        replayedInteractions.append((agentID: session.agentID, requestType: .sendToolResult, message: content))
        lock.unlock()
        return replayNextInteraction(for: session.agentID, expectedType: .sendToolResult, message: content)
    }

    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
    func interrupt(session: AgentSession) {}
    func stop(session: AgentSession) {}

    // MARK: - Replay Engine

    private func replayNextInteraction(for agentID: String, expectedType: RecordedInteraction.RequestType, message: String) -> AsyncStream<StreamEvent> {
        lock.lock()
        guard let session = sessions[agentID] else {
            exhaustions.append((agentID: agentID, requestType: expectedType, reason: .noRecordingForAgent))
            lock.unlock()
            log.error("No recording for agent \(agentID)")
            return emptyStream()
        }
        let cursor = cursors[agentID] ?? 0

        // Find next interaction matching the expected type
        var matchIndex: Int?
        for i in cursor..<session.interactions.count {
            if session.interactions[i].requestType == expectedType {
                matchIndex = i
                break
            }
        }

        guard let idx = matchIndex else {
            exhaustions.append((agentID: agentID, requestType: expectedType, reason: .cursorExhausted))
            lock.unlock()
            log.warning("No more \(expectedType.rawValue) interactions for \(agentID) (cursor=\(cursor), total=\(session.interactions.count))")
            return emptyStream()
        }

        cursors[agentID] = idx + 1
        lock.unlock()

        let interaction = session.interactions[idx]
        let timing = self.timingMode

        return AsyncStream { continuation in
            Task {
                var lastOffset = 0
                for timestamped in interaction.events {
                    let delay = self.computeDelay(from: lastOffset, to: timestamped.offsetMs, mode: timing)
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    }
                    lastOffset = timestamped.offsetMs
                    continuation.yield(timestamped.event.toStreamEvent())
                }
                continuation.finish()
            }
        }
    }

    private func computeDelay(from: Int, to: Int, mode: TimingMode) -> Int {
        let delta = max(0, to - from)
        switch mode {
        case .realTime:
            return delta
        case .accelerated(let factor):
            return Int(Double(delta) / factor)
        case .instant:
            return 0
        }
    }

    private func emptyStream() -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            continuation.yield(.assistantText("(replay exhausted)"))
            continuation.yield(.result(StreamEvent.ResultPayload(
                text: "(replay exhausted)", costUSD: 0, durationMs: 0,
                inputTokens: 0, outputTokens: 0,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "", permissionDenials: []
            )))
            continuation.finish()
        }
    }
}

enum ReplayError: LocalizedError {
    case resourceNotFound(String)
    case noRecordingForAgent(String)
    case interactionMismatch(expected: String, got: String)

    var errorDescription: String? {
        switch self {
        case .resourceNotFound(let name):
            return "Recording resource not found: \(name)"
        case .noRecordingForAgent(let id):
            return "No recorded session for agent: \(id)"
        case .interactionMismatch(let expected, let got):
            return "Expected \(expected) interaction but got \(got)"
        }
    }
}

private extension JSONDecoder {
    static let recording: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
