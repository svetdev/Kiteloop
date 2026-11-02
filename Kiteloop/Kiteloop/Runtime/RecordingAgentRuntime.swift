import Foundation
import KiteloopCore
import os.log

private let log = Logger(subsystem: "ai.kasatkin.kiteloop", category: "recording-runtime")

/// Wraps any AgentRuntime, transparently recording all interactions to disk.
/// Use this to capture a real session once, then replay it forever with ReplayAgentRuntime.
///
/// Usage:
///   let real = ClaudeCodeCLIRuntime()
///   let recorder = RecordingAgentRuntime(wrapped: real, outputDirectory: recordingsDir)
///   // Use `recorder` as the runtime — it passes through to `real` and saves recordings.
///
final class RecordingAgentRuntime: AgentRuntime, @unchecked Sendable {
    private let wrapped: any AgentRuntime
    private let outputDirectory: URL
    private let lock = NSLock()
    private var sessions: [String: RecordingState] = [:]

    private struct RecordingState {
        let agentID: String
        let sessionID: String
        let startedAt: Date
        var interactions: [RecordedInteraction] = []
    }

    /// Every live recorder, held weakly. `KiteloopApp.runtime` builds a fresh
    /// wrapper per call and nothing else keeps one instance around, so this is
    /// the only way app quit can reach a recording still capturing a session —
    /// without giving the recorders a strong, process-wide owner.
    private static let registryLock = NSLock()
    /// Every access is guarded by `registryLock` — the compiler can't see
    /// that, hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) static var registry: [WeakRuntime] = []

    private struct WeakRuntime {
        weak var instance: RecordingAgentRuntime?
    }

    init(wrapped: any AgentRuntime, outputDirectory: URL) {
        self.wrapped = wrapped
        self.outputDirectory = outputDirectory
        Self.registryLock.withLock {
            Self.registry.removeAll { $0.instance == nil }
            Self.registry.append(WeakRuntime(instance: self))
        }
    }

    /// Flush every recorder still alive. Call once, at app quit, before agent
    /// subprocesses are torn down — a session that is still live at that point
    /// has nothing else that will ever persist what it captured.
    static func flushAllLiveRecordings() {
        let runtimes: [RecordingAgentRuntime] = registryLock.withLock {
            registry.removeAll { $0.instance == nil }
            return registry.compactMap { $0.instance }
        }
        for runtime in runtimes {
            runtime.flushAll()
        }
    }

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        try await startSession(agent: agent, cwd: cwd, strategy: strategy, options: SessionOptions())
    }

    /// Forwarded rather than left to the protocol's default, which would drop
    /// the options: a recording wrapper must not quietly spawn an unattended
    /// session on different terms from the runtime it wraps.
    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession {
        let session = try await wrapped.startSession(
            agent: agent, cwd: cwd, strategy: strategy, options: options
        )
        lock.withLock {
            sessions[session.id] = RecordingState(
                agentID: agent.id, sessionID: session.id, startedAt: session.startedAt
            )
        }
        log.info("Recording started for agent \(agent.id) session \(session.id)")
        return session
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        let upstream = wrapped.send(message, attachments: attachments, to: session)
        let sessionID = session.id
        let interactionStart = Date()

        return AsyncStream { continuation in
            Task { [weak self] in
                var events: [TimestampedEvent] = []

                for await event in upstream {
                    let offset = Int(Date().timeIntervalSince(interactionStart) * 1000)
                    events.append(TimestampedEvent(offsetMs: offset, event: .from(event)))
                    continuation.yield(event)
                }

                let interaction = RecordedInteraction(
                    requestType: .send,
                    timestamp: interactionStart,
                    message: message,
                    attachments: attachments.map { att in
                        RecordedAttachment(
                            filename: att.filename,
                            mimeType: att.mimeType,
                            dataBase64: att.data.base64EncodedString()
                        )
                    },
                    toolCallID: nil,
                    events: events
                )

                self?.appendInteraction(interaction, sessionID: sessionID)
                continuation.finish()
            }
        }
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        let upstream = wrapped.sendToolResult(toolCallID: toolCallID, content: content, to: session)
        let sessionID = session.id
        let interactionStart = Date()

        return AsyncStream { continuation in
            Task { [weak self] in
                var events: [TimestampedEvent] = []

                for await event in upstream {
                    let offset = Int(Date().timeIntervalSince(interactionStart) * 1000)
                    events.append(TimestampedEvent(offsetMs: offset, event: .from(event)))
                    continuation.yield(event)
                }

                let interaction = RecordedInteraction(
                    requestType: .sendToolResult,
                    timestamp: interactionStart,
                    message: content,
                    attachments: [],
                    toolCallID: toolCallID,
                    events: events
                )

                self?.appendInteraction(interaction, sessionID: sessionID)
                continuation.finish()
            }
        }
    }


    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {
        wrapped.sendMCPToolResult(requestID: requestID, result: result, to: session)
    }

    func interrupt(session: AgentSession) {
        wrapped.interrupt(session: session)
    }

    func stop(session: AgentSession) {
        wrapped.stop(session: session)
        flush(sessionID: session.id)
    }

    // MARK: - Persistence

    /// Write the current recording to disk. Call when session ends or on demand.
    /// Removes the session from memory once written, so a session already
    /// flushed by `stop(session:)` is not written again by a later `flushAll()`.
    func flush(sessionID: String) {
        lock.lock()
        guard let state = sessions.removeValue(forKey: sessionID) else {
            lock.unlock()
            return
        }
        lock.unlock()

        let recorded = RecordedSession(
            agentID: state.agentID,
            sessionID: state.sessionID,
            recordedAt: state.startedAt,
            interactions: state.interactions
        )

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let filename = "\(state.agentID)_\(ISO8601DateFormatter().string(from: Date())).json"
            let fileURL = outputDirectory.appendingPathComponent(filename)
            let data = try JSONEncoder.prettyRecording.encode(recorded)
            try data.write(to: fileURL, options: .atomic)
            log.info("Recording saved: \(fileURL.lastPathComponent) (\(state.interactions.count) interactions)")
        } catch {
            log.error("Failed to save recording: \(error.localizedDescription)")
        }
    }

    /// Flush all active sessions (e.g., on app quit).
    func flushAll() {
        lock.lock()
        let ids = Array(sessions.keys)
        lock.unlock()
        for id in ids { flush(sessionID: id) }
    }

    private func appendInteraction(_ interaction: RecordedInteraction, sessionID: String) {
        lock.lock()
        sessions[sessionID]?.interactions.append(interaction)
        lock.unlock()
    }
}

private extension JSONEncoder {
    static let prettyRecording: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
