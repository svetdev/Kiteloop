import Foundation
import KiteloopCore
import os.log

private let log = Logger(subsystem: "ai.kasatkin.kiteloop", category: "copilot-bridge")

final class CopilotBridgeRuntime: AgentRuntime, @unchecked Sendable {
    private let socketPath: String
    private let lock = NSLock()
    private var sessions: [String: CopilotSession] = [:]
    private let maxHistoryMessages: Int
    /// How long a connected socket may go without a byte before a turn ends
    /// itself with an error instead of parking the read forever.
    private let silenceDeadline: TimeInterval
    /// How often a blocking read gives up and returns, so the loop can re-check
    /// `turnGeneration` and elapsed silence between lines. Independent of
    /// `silenceDeadline` so interrupt lands quickly even with a long deadline.
    private var readTickInterval: TimeInterval { min(0.1, silenceDeadline) }

    private struct CopilotSession {
        let agent: Agent
        var history: [[String: String]]
        /// Bumped by `interrupt(session:)`; a turn started at an older value than
        /// what it later reads back is the turn's cue to stop yielding deltas and
        /// wrap up, without tearing down the session the way `stop` does.
        var turnGeneration: Int = 0
    }

    /// Where the VS Code bridge extension binds its listener.
    static var defaultSocketPath: String {
        KiteloopHome.url.appending(path: ".kiteloop/copilot-bridge.sock").path
    }

    /// The production silence deadline: long enough for a slow reply, short
    /// enough that a bridge that has gone quiet does not park the turn all day.
    static let defaultSilenceDeadline: TimeInterval = 120

    init(socketPath: String? = nil, maxHistoryMessages: Int = 20, silenceDeadline: TimeInterval = CopilotBridgeRuntime.defaultSilenceDeadline) {
        self.socketPath = socketPath ?? Self.defaultSocketPath
        self.maxHistoryMessages = maxHistoryMessages
        self.silenceDeadline = silenceDeadline
    }

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        let sessionID = UUID().uuidString
        var history: [[String: String]] = []
        if !agent.systemPrompt.isEmpty {
            history.append(["role": "system", "content": agent.systemPrompt])
        }
        lock.withLock {
            sessions[sessionID] = CopilotSession(agent: agent, history: history)
        }
        return AgentSession(id: sessionID, agentID: agent.id, startedAt: Date())
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            Task.detached { [weak self] in
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
        }
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }


    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}

    func interrupt(session: AgentSession) {
        lock.withLock {
            guard var copilotSession = sessions[session.id] else { return }
            copilotSession.turnGeneration += 1
            sessions[session.id] = copilotSession
        }
    }

    func stop(session: AgentSession) {
        lock.withLock {
            _ = sessions.removeValue(forKey: session.id)
        }
    }

    // MARK: - Private

    private func performSend(message: String, sessionID: String, continuation: AsyncStream<StreamEvent>.Continuation) async {
        guard let prepared = prepareRequest(message: message, sessionID: sessionID, continuation: continuation) else { return }
        guard let socket = openConnection(requestLine: prepared.requestLine, sessionID: sessionID, continuation: continuation) else { return }
        defer { close(socket) }

        var fullText = ""
        let startTime = Date()
        var wasInterrupted = false
        var buffer: [UInt8] = []
        var lastByteAt = Date()

        readLoop: while true {
            switch readLine(from: socket, buffer: &buffer) {
            case .closed:
                break readLoop

            case .tick:
                if generationChanged(sessionID: sessionID, from: prepared.startGeneration) {
                    wasInterrupted = true
                    break readLoop
                }
                guard Date().timeIntervalSince(lastByteAt) >= silenceDeadline else { continue }
                yieldSilenceTimeout(fullText: fullText, sessionID: sessionID, startTime: startTime, continuation: continuation)
                return

            case .line(let line):
                lastByteAt = Date()
                if generationChanged(sessionID: sessionID, from: prepared.startGeneration) {
                    wasInterrupted = true
                    break readLoop
                }
                switch handleResponseLine(line, requestID: prepared.requestID, sessionID: sessionID, startTime: startTime, fullText: &fullText, continuation: continuation) {
                case .handled: continue
                case .finished: return
                }
            }
        }

        if !wasInterrupted {
            wasInterrupted = generationChanged(sessionID: sessionID, from: prepared.startGeneration)
        }
        if wasInterrupted {
            appendAssistantHistory(fullText, sessionID: sessionID)
            let resultPayload = makeResultPayload(text: fullText, sessionID: sessionID, startTime: startTime)
            continuation.yield(.result(resultPayload))
        }
        continuation.finish()
    }

    private struct PreparedRequest {
        let requestID: String
        let requestLine: String
        let startGeneration: Int
    }

    /// Folds the user turn into history and encodes the bridge request, or
    /// reports why it could not and ends the turn — "session not found" and a
    /// JSON encoding failure are both terminal, not retryable.
    private func prepareRequest(message: String, sessionID: String, continuation: AsyncStream<StreamEvent>.Continuation) -> PreparedRequest? {
        let snapshot: CopilotSession? = lock.withLock {
            guard var copilotSession = sessions[sessionID] else { return nil }
            copilotSession.history.append(["role": "user", "content": message])
            trimHistory(&copilotSession)
            sessions[sessionID] = copilotSession
            return copilotSession
        }
        guard let copilotSession = snapshot else {
            continuation.yield(.system(subtype: "error", payload: ["message": "Session not found" as Any]))
            continuation.finish()
            return nil
        }

        let requestID = UUID().uuidString
        var request: [String: Any] = [
            "id": requestID,
            "type": "chat",
            "messages": copilotSession.history,
            "maxTokens": 4096
        ]
        if let model = Self.bridgeModel(for: copilotSession.agent.model) { request["model"] = model }
        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              let requestLine = String(data: requestData, encoding: .utf8) else {
            continuation.yield(.system(subtype: "error", payload: ["message": "Failed to encode request" as Any]))
            continuation.finish()
            return nil
        }
        return PreparedRequest(requestID: requestID, requestLine: requestLine + "\n", startGeneration: copilotSession.turnGeneration)
    }

    /// The model name the bridge is asked for, or nil to leave the choice to
    /// Copilot.
    ///
    /// `copilot` is this app's name for the runtime, not a model: sent as one,
    /// it matched no Copilot family, and the bridge answered with whichever
    /// model VS Code listed first. So the bare alias asks for nothing, and
    /// `copilot-gpt-4o` asks for `gpt-4o`. Anything else is passed as written
    /// — a family or an id from the bridge's `ping` list.
    static func bridgeModel(for agentModel: String) -> String? {
        let name = agentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "copilot" { return nil }
        if name.hasPrefix("copilot-") { return String(name.dropFirst("copilot-".count)) }
        return name
    }

    /// Says which model answered, when the bridge's `done` frame names one:
    /// an `init` notice, the frame every runtime reports its model on, so the
    /// chat's status line and the turn's trace span carry it. A bridge built
    /// before the frame carried a model says nothing, and nothing is claimed.
    private func yieldAnsweringModel(_ frame: [String: Any], continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let model = frame["model"] as? String, !model.isEmpty else { return }
        let vendor = frame["vendor"] as? String ?? ""
        log.info("Copilot bridge answered with \(model, privacy: .public) (\(vendor, privacy: .public))")
        continuation.yield(.system(subtype: "init", payload: ["model": model as Any]))
    }

    /// Connects to the bridge and writes the request, or reports why it could
    /// not and ends the turn. Closes the socket itself on a write failure only —
    /// the caller owns the close once a usable socket comes back.
    private func openConnection(requestLine: String, sessionID: String, continuation: AsyncStream<StreamEvent>.Continuation) -> Int32? {
        guard let socket = connectToSocket() else {
            continuation.yield(.system(subtype: "error", payload: ["message": "Copilot bridge not running. Ensure VS Code extension is active." as Any]))
            let resultPayload = StreamEvent.ResultPayload(
                text: "Error: Copilot bridge not available",
                costUSD: 0,
                durationMs: 0,
                inputTokens: 0,
                outputTokens: 0,
                cacheCreationInputTokens: 0,
                cacheReadInputTokens: 0,
                sessionID: sessionID,
                permissionDenials: []
            )
            continuation.yield(.result(resultPayload))
            continuation.finish()
            return nil
        }
        guard writeToSocket(socket, data: requestLine.data(using: .utf8)!) else {
            continuation.yield(.system(subtype: "error", payload: ["message": "Failed to write to socket" as Any]))
            continuation.finish()
            close(socket)
            return nil
        }
        return socket
    }

    private enum FrameOutcome {
        case handled
        case finished
    }

    /// Applies one decoded line from the bridge to the turn in progress: a delta
    /// yields text and keeps the loop going, `done`/`error` close the turn out.
    /// A frame addressed to another request, or one that fails to parse, is
    /// silently skipped — `.handled` either way.
    private func handleResponseLine(
        _ line: String,
        requestID: String,
        sessionID: String,
        startTime: Date,
        fullText: inout String,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) -> FrameOutcome {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseID = json["id"] as? String,
              responseID == requestID else { return .handled }

        switch json["type"] as? String ?? "" {
        case "delta":
            if let content = json["content"] as? String {
                fullText += content
                continuation.yield(.assistantText(content))
            }
            return .handled
        case "done":
            if let content = json["content"] as? String, fullText.isEmpty {
                fullText = content
            }
            appendAssistantHistory(fullText, sessionID: sessionID)
            yieldAnsweringModel(json, continuation: continuation)
            let resultPayload = makeResultPayload(text: fullText, sessionID: sessionID, startTime: startTime)
            continuation.yield(.result(resultPayload))
            continuation.finish()
            return .finished
        case "error":
            let msg = json["message"] as? String ?? "Unknown error"
            log.error("Copilot bridge error: \(msg, privacy: .public)")
            continuation.yield(.system(subtype: "error", payload: ["message": msg as Any]))
            let resultPayload = makeResultPayload(text: "Error: \(msg)", sessionID: sessionID, startTime: startTime)
            continuation.yield(.result(resultPayload))
            continuation.finish()
            return .finished
        default:
            return .handled
        }
    }

    /// Ends a turn whose socket accepted the connection and then never sent
    /// another byte: an error naming the socket and the deadline, then a result
    /// carrying whatever text had arrived, same shape as an `error` frame.
    private func yieldSilenceTimeout(
        fullText: String,
        sessionID: String,
        startTime: Date,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) {
        let message = "Copilot bridge socket \(socketPath) sent nothing for \(silenceDeadline)s; ending the turn."
        log.error("\(message, privacy: .public)")
        continuation.yield(.system(subtype: "error", payload: ["message": message as Any]))
        appendAssistantHistory(fullText, sessionID: sessionID)
        let resultPayload = makeResultPayload(text: fullText, sessionID: sessionID, startTime: startTime)
        continuation.yield(.result(resultPayload))
        continuation.finish()
    }

    private func generationChanged(sessionID: String, from startGeneration: Int) -> Bool {
        lock.withLock { sessions[sessionID]?.turnGeneration } != startGeneration
    }

    private func appendAssistantHistory(_ text: String, sessionID: String) {
        lock.withLock {
            if var s = sessions[sessionID] {
                s.history.append(["role": "assistant", "content": text])
                sessions[sessionID] = s
            }
        }
    }

    private func makeResultPayload(text: String, sessionID: String, startTime: Date) -> StreamEvent.ResultPayload {
        StreamEvent.ResultPayload(
            text: text,
            costUSD: 0,
            durationMs: Int(Date().timeIntervalSince(startTime) * 1000),
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0,
            sessionID: sessionID,
            permissionDenials: []
        )
    }

    private func trimHistory(_ session: inout CopilotSession) {
        let systemMessages = session.history.filter { $0["role"] == "system" }
        var nonSystem = session.history.filter { $0["role"] != "system" }
        if nonSystem.count > maxHistoryMessages {
            nonSystem = Array(nonSystem.suffix(maxHistoryMessages))
        }
        session.history = systemMessages + nonSystem
    }

    // MARK: - Socket I/O

    private func connectToSocket(retries: Int = 3) -> Int32? {
        for attempt in 0..<retries {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = socketPath.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let bound = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    pathBytes.withUnsafeBufferPointer { src in
                        let count = min(src.count, 104)
                        dest.update(from: src.baseAddress!, count: count)
                        return count
                    }
                }
                _ = bound
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(fd, sockPtr, addrLen)
                }
            }

            if result == 0 {
                setReceiveTimeout(fd, seconds: readTickInterval)
                return fd
            }

            Darwin.close(fd)
            if attempt < retries - 1 {
                Thread.sleep(forTimeInterval: 0.5 * Double(attempt + 1))
            }
        }
        log.warning("Failed to connect to Copilot bridge at \(self.socketPath, privacy: .public)")
        return nil
    }

    private func writeToSocket(_ fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return false }
            let written = Darwin.write(fd, ptr, data.count)
            return written == data.count
        }
    }

    /// A line read from the bridge socket, a tick that brought no newline yet, or
    /// the peer closing. `buffer` carries bytes read so far across calls, so a
    /// frame split across a tick is not lost.
    private enum ReadOutcome {
        case line(String)
        case tick
        case closed
    }

    private func readLine(from fd: Int32, buffer: inout [UInt8]) -> ReadOutcome {
        while true {
            var byte: UInt8 = 0
            let bytesRead = Darwin.read(fd, &byte, 1)
            if bytesRead > 0 {
                if byte == 0x0A {
                    let line = String(bytes: buffer, encoding: .utf8) ?? ""
                    buffer.removeAll()
                    return .line(line)
                }
                buffer.append(byte)
                continue
            }
            if bytesRead == 0 { return .closed }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .tick }
            return .closed
        }
    }

    /// Makes a blocking read on `fd` give up and return after `seconds`, so the
    /// caller's loop can re-check state between lines instead of parking forever.
    private func setReceiveTimeout(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval()
        tv.tv_sec = Int(seconds)
        tv.tv_usec = Int32((seconds - Double(Int(seconds))) * 1_000_000)
        _ = withUnsafeBytes(of: &tv) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr.baseAddress, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private func close(_ fd: Int32) {
        Darwin.close(fd)
    }

    /// Whether something is answering on the bridge socket right now — a file at
    /// `socketPath` is not enough, a stale one left behind by a closed listener
    /// refuses the connection.
    static func isAvailable(socketPath path: String = CopilotBridgeRuntime.defaultSocketPath) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard FileManager.default.fileExists(atPath: path) else {
                    continuation.resume(returning: false)
                    return
                }
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(returning: false)
                    return
                }
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = path.utf8CString
                withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                        pathBytes.withUnsafeBufferPointer { src in
                            let count = min(src.count, 104)
                            dest.update(from: src.baseAddress!, count: count)
                        }
                    }
                }
                let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let result = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.connect(fd, sockPtr, addrLen)
                    }
                }
                Darwin.close(fd)
                continuation.resume(returning: result == 0)
            }
        }
    }
}
