import Foundation
import KiteloopCore
import os.log

private let log = Logger(subsystem: "ai.kasatkin.kiteloop", category: "ollama")

final class OllamaRuntime: AgentRuntime, @unchecked Sendable {
    private let baseURL: URL
    private let lock = NSLock()
    private var sessions: [String: OllamaSession] = [:]

    private struct OllamaSession {
        let agent: Agent
        var history: [[String: String]]
        /// The in-flight turn's task, so `interrupt` can cancel the network read
        /// without tearing the session down the way `stop` does.
        var currentTask: Task<Void, Never>?
    }

    /// Where `ollama serve` listens, and what every production call site uses;
    /// a test passes its stub's URL instead. Assembled from components rather
    /// than force-unwrapping `URL(string:)`: the parts are constants, so a nil
    /// here could only be a programming error.
    static let defaultBaseURL: URL = {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = 11434
        guard let url = components.url else { preconditionFailure("localhost:11434 is not a URL") }
        return url
    }()

    init(baseURL: URL = OllamaRuntime.defaultBaseURL) {
        self.baseURL = baseURL
    }

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        let sessionID = UUID().uuidString
        var history: [[String: String]] = []
        if !agent.systemPrompt.isEmpty {
            history.append(["role": "system", "content": agent.systemPrompt])
        }
        lock.withLock {
            sessions[sessionID] = OllamaSession(agent: agent, history: history)
        }
        return AgentSession(id: sessionID, agentID: agent.id, startedAt: Date())
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.performSend(
                    message: PlainTextAttachments.fold(text: message, attachments: attachments),
                    sessionID: session.id,
                    continuation: continuation
                )
            }
            lock.withLock {
                sessions[session.id]?.currentTask = task
            }
        }
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }


    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}

    func interrupt(session: AgentSession) {
        lock.withLock {
            sessions[session.id]?.currentTask?.cancel()
        }
    }

    func stop(session: AgentSession) {
        lock.withLock {
            _ = sessions.removeValue(forKey: session.id)
        }
    }

    // MARK: - Private

    private func performSend(message: String, sessionID: String, continuation: AsyncStream<StreamEvent>.Continuation) async {
        // The lock must never be held across an await, so the session
        // snapshot is taken (and the user message appended) up front.
        guard let session = snapshotAfterAppendingUserMessage(message, sessionID: sessionID) else {
            continuation.yield(.system(subtype: "error", payload: ["message": "Session not found" as Any]))
            continuation.finish()
            return
        }

        guard let (request, model) = buildChatRequest(for: session, continuation: continuation) else {
            return
        }

        let startTime = Date()
        var fullText = ""

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard validateResponse(response, model: model, startTime: startTime, sessionID: sessionID, continuation: continuation) else {
                return
            }

            if try await consumeStream(bytes, fullText: &fullText, sessionID: sessionID, startTime: startTime, continuation: continuation) {
                return
            }

            finishStreamEndedWithoutDone(fullText: fullText, sessionID: sessionID, startTime: startTime, continuation: continuation)

        } catch {
            if Task.isCancelled {
                finishInterruptedTurn(fullText: fullText, sessionID: sessionID, startTime: startTime, continuation: continuation)
                return
            }
            let msg = error.localizedDescription.contains("Connection refused")
                ? "Ollama not running. Start it with: ollama serve"
                : "Ollama error: \(error.localizedDescription)"
            yieldError(msg, continuation: continuation, startTime: startTime, sessionID: sessionID)
        }
    }

    /// Appends `message` to the session's history under the lock and returns
    /// the resulting snapshot, or `nil` if the session no longer exists.
    private func snapshotAfterAppendingUserMessage(_ message: String, sessionID: String) -> OllamaSession? {
        lock.withLock {
            guard var session = sessions[sessionID] else { return nil }
            session.history.append(["role": "user", "content": message])
            sessions[sessionID] = session
            return session
        }
    }

    /// Builds the `/api/chat` request for `session`'s history, yielding and
    /// closing out `continuation` itself on an encode failure.
    private func buildChatRequest(
        for session: OllamaSession,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) -> (request: URLRequest, model: String)? {
        let model = resolveModel(session.agent.model)
        let messages = session.history.map { msg -> [String: Any] in
            ["role": msg["role"] ?? "user", "content": msg["content"] ?? ""]
        }

        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            continuation.yield(.system(subtype: "error", payload: ["message": "Failed to encode request" as Any]))
            continuation.finish()
            return nil
        }

        let url = baseURL.appending(path: "/api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return (request, model)
    }

    /// A turn that reached Ollama's `done` signal: records the assistant turn
    /// in history and yields the final `.result` with Ollama's token counts.
    private func finishCompletedTurn(
        json: [String: Any],
        fullText: String,
        sessionID: String,
        startTime: Date,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) {
        let inputTokens = json["prompt_eval_count"] as? Int ?? 0
        let outputTokens = json["eval_count"] as? Int ?? 0
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)

        lock.withLock {
            if var s = sessions[sessionID] {
                s.history.append(["role": "assistant", "content": fullText])
                sessions[sessionID] = s
            }
        }

        let result = StreamEvent.ResultPayload(
            text: fullText,
            costUSD: 0,
            durationMs: duration,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0,
            sessionID: sessionID,
            permissionDenials: []
        )
        continuation.yield(.result(result))
        continuation.finish()
    }

    /// Validates the HTTP response for the `/api/chat` call, yielding and
    /// closing out `continuation` itself when it isn't a plain 200.
    private func validateResponse(
        _ response: URLResponse,
        model: String,
        startTime: Date,
        sessionID: String,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else {
            yieldError("Invalid response from Ollama", continuation: continuation, startTime: startTime, sessionID: sessionID)
            return false
        }
        if httpResponse.statusCode != 200 {
            yieldError("Ollama returned \(httpResponse.statusCode). Is the model '\(model)' pulled?", continuation: continuation, startTime: startTime, sessionID: sessionID)
            return false
        }
        return true
    }

    /// Reads the response body line by line, accumulating `fullText` in place
    /// so a caught cancellation still sees what had arrived. Returns `true`
    /// once the turn has been closed out (cancelled or `done`), `false` if the
    /// stream ran out first.
    private func consumeStream(
        _ bytes: URLSession.AsyncBytes,
        fullText: inout String,
        sessionID: String,
        startTime: Date,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) async throws -> Bool {
        for try await line in bytes.lines {
            if Task.isCancelled {
                finishInterruptedTurn(fullText: fullText, sessionID: sessionID, startTime: startTime, continuation: continuation)
                return true
            }

            if handleStreamLine(line, fullText: &fullText, sessionID: sessionID, startTime: startTime, continuation: continuation) {
                return true
            }
        }
        return false
    }

    /// Parses one line of the response body, yielding assistant text as it
    /// arrives and closing out the turn on `done`. Returns `true` once closed.
    private func handleStreamLine(
        _ line: String,
        fullText: inout String,
        sessionID: String,
        startTime: Date,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) -> Bool {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }

        if let msg = json["message"] as? [String: Any],
           let content = msg["content"] as? String, !content.isEmpty {
            fullText += content
            continuation.yield(.assistantText(content))
        }

        if json["done"] as? Bool == true {
            finishCompletedTurn(json: json, fullText: fullText, sessionID: sessionID, startTime: startTime, continuation: continuation)
            return true
        }
        return false
    }

    /// The body ended without ever sending `done`. Unlike `finishInterruptedTurn`,
    /// an empty `fullText` here yields no `.result` at all — nothing arrived to report.
    private func finishStreamEndedWithoutDone(
        fullText: String,
        sessionID: String,
        startTime: Date,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) {
        if !fullText.isEmpty {
            lock.withLock {
                if var s = sessions[sessionID] {
                    s.history.append(["role": "assistant", "content": fullText])
                    sessions[sessionID] = s
                }
            }

            let result = StreamEvent.ResultPayload(
                text: fullText,
                costUSD: 0,
                durationMs: Int(Date().timeIntervalSince(startTime) * 1000),
                inputTokens: 0,
                outputTokens: 0,
                cacheCreationInputTokens: 0,
                cacheReadInputTokens: 0,
                sessionID: sessionID,
                permissionDenials: []
            )
            continuation.yield(.result(result))
        }
        continuation.finish()
    }

    /// A turn cancelled by `interrupt(session:)` closes out with whatever text
    /// had arrived — a `.result`, not the `system(error)` a genuine failure
    /// yields — and keeps the session and its history intact for the next send.
    private func finishInterruptedTurn(
        fullText: String,
        sessionID: String,
        startTime: Date,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) {
        if !fullText.isEmpty {
            lock.withLock {
                if var s = sessions[sessionID] {
                    s.history.append(["role": "assistant", "content": fullText])
                    sessions[sessionID] = s
                }
            }
        }
        let result = StreamEvent.ResultPayload(
            text: fullText,
            costUSD: 0,
            durationMs: Int(Date().timeIntervalSince(startTime) * 1000),
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0,
            sessionID: sessionID,
            permissionDenials: []
        )
        continuation.yield(.result(result))
        continuation.finish()
    }

    private func yieldError(_ message: String, continuation: AsyncStream<StreamEvent>.Continuation, startTime: Date, sessionID: String) {
        log.error("\(message, privacy: .public)")
        continuation.yield(.system(subtype: "error", payload: ["message": message as Any]))
        let result = StreamEvent.ResultPayload(
            text: "Error: \(message)",
            costUSD: 0,
            durationMs: Int(Date().timeIntervalSince(startTime) * 1000),
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0,
            sessionID: sessionID,
            permissionDenials: []
        )
        continuation.yield(.result(result))
        continuation.finish()
    }

    private func resolveModel(_ model: String) -> String {
        switch model {
        case "ollama", "local": return "llama3.1"
        case "ollama-small", "local-small": return "llama3.2"
        case "ollama-code", "local-code": return "qwen2.5-coder"
        case "ollama-large", "local-large": return "llama3.1:70b"
        default: return model
        }
    }

    // MARK: - Health Check

    static func isAvailable(baseURL: URL = defaultBaseURL) async -> Bool {
        let url = baseURL.appending(path: "/api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// The models Ollama has pulled, or `nil` when Ollama could not be
    /// reached — an empty list means it is running with nothing pulled, which
    /// a caller showing status has to tell apart from not running at all.
    /// Carries the same two-second deadline `isAvailable` sets on the same
    /// endpoint, so a host that accepts the connection and then goes quiet
    /// cannot hold the caller for the URLSession default.
    static func availableModels(baseURL: URL = defaultBaseURL) async -> [String]? {
        let url = baseURL.appending(path: "/api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }
}
