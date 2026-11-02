import Foundation
import os
import os.log

private let httpLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "control-http")

/// A minimal localhost HTTP/1.1 server over a loopback BSD socket — just enough for
/// the Kiteloop control API. Unary request→response only (no keep-alive, no SSE);
/// every response closes the connection. Not a general-purpose web server.
///
/// Bound to 127.0.0.1 and nothing else (`LoopbackListener`). The route handler runs on the main actor so
/// it can touch app state directly.
package final class HTTPServer: @unchecked Sendable {

    package struct Request {
        package let method: String
        package let path: String
        package let query: [String: String]
        package let headers: [String: String]
        package let body: Data

        /// Case-insensitive header lookup.
        package func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }

        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(method: String, path: String, query: [String: String], headers: [String: String], body: Data) {
            self.method = method
            self.path = path
            self.query = query
            self.headers = headers
            self.body = body
        }
    }

    package struct Response {
        package var status: Int
        package var headers: [String: String]
        package var body: Data
        /// When set, the connection is kept open as an SSE stream and this closure
        /// drives it instead of a unary body being sent.
        package var stream: (@MainActor (SSEWriter) async -> Void)?
        /// Seconds between keepalive comments on an open stream; 0 disables them.
        package var keepAlive: TimeInterval = 0

        package init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
            self.stream = nil
        }

        package static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? Data()
            return Response(status: status,
                            headers: ["Content-Type": "application/json; charset=utf-8"],
                            body: data)
        }

        package static func error(_ message: String, status: Int) -> Response {
            json(["error": message], status: status)
        }

        /// A Server-Sent Events response. `handler` pushes frames through the
        /// writer and returns when the stream is done. While the handler is
        /// running, a `: keepalive` comment goes out every `keepAlive` seconds so
        /// an idle stream doesn't look dead to clients and proxies.
        package static func sse(keepAlive: TimeInterval = 15,
                        _ handler: @escaping @MainActor (SSEWriter) async -> Void) -> Response {
            var response = Response(status: 200)
            response.stream = handler
            response.keepAlive = keepAlive
            return response
        }
    }

    /// Async route handler, invoked on the main actor.
    package typealias Handler = @MainActor (Request) async -> Response

    /// What the listener is doing right now, reported through `onStateChange`:
    /// bound and accepting, refused the port (with why), or stopped.
    package enum ListenerState: Equatable, Sendable {
        case ready
        case failed(String)
        case cancelled
    }

    private let port: UInt16
    private var listener: LoopbackListener?
    private let queue = DispatchQueue(label: "ai.kasatkin.kiteloop.control-http")
    private let handler: Handler

    /// Fired on the server's dispatch queue — not the main actor — every time
    /// the listener reaches `.ready`, `.failed` or `.cancelled`. Set before
    /// calling `start()` so no transition is missed; the owner is responsible
    /// for hopping to whatever actor it needs.
    package var onStateChange: (@Sendable (ListenerState) -> Void)?

    package init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    /// Binds 127.0.0.1:`port` and starts accepting. A port that cannot be
    /// bound is reported as `.failed` through `onStateChange`, never thrown, so
    /// an owner has one place to react; `.ready` likewise arrives there, after
    /// this returns.
    package func start() throws {
        let boundPort = port
        let onStateChange = onStateChange
        do {
            listener = try LoopbackListener(
                port: port, queue: queue,
                onConnection: { [weak self] connection in self?.accept(connection) },
                onCancel: { onStateChange?(.cancelled) })
        } catch {
            httpLog.error("listener failed: \(String(describing: error), privacy: .public)")
            queue.async { onStateChange?(.failed(String(describing: error))) }
            return
        }
        httpLog.info("control server listening on 127.0.0.1:\(boundPort, privacy: .public)")
        queue.async { onStateChange?(.ready) }
    }

    package func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    /// Accumulates bytes until there is a full request (headers +
    /// Content-Length body), then dispatches it once; anything the client sends
    /// after that is not part of the protocol and is ignored. Caps the request
    /// size to avoid unbounded buffering.
    private func accept(_ connection: SocketConnection) {
        let exchange = OSAllocatedUnfairLock(initialState: Exchange())
        connection.startReading(onChunk: { [weak self] chunk in
            guard let self else { return }
            // Reads arrive one at a time, so nothing appends between this
            // decision and recording that the request was answered.
            let buffer: Data? = exchange.withLock { exchange in
                guard !exchange.answered else { return nil }
                exchange.buffer.append(chunk)
                return exchange.buffer
            }
            guard let buffer else { return }
            let answered: Bool
            if buffer.count > 2 * 1024 * 1024 {
                self.send(connection, .error("Request too large", status: 413))
                answered = true
            } else {
                answered = self.answer(connection, Self.parseOutcome(buffer))
            }
            exchange.withLock { $0.answered = answered }
        }, onEnd: { error in
            if let error {
                httpLog.error("receive error: \(String(describing: error), privacy: .public)")
            }
            // A client gone before its request was whole gets nothing; one
            // answered is closed by its response, or by its stream ending.
            if !exchange.withLock({ $0.answered }) { connection.cancel() }
        })
    }

    /// One connection's request as it arrives.
    private struct Exchange {
        var buffer = Data()
        var answered = false
    }

    /// Dispatches a whole request to the handler, or refuses a malformed one
    /// with 400. Returns false when the request is still arriving, so the
    /// caller keeps reading.
    private func answer(_ connection: SocketConnection, _ outcome: ParseOutcome) -> Bool {
        switch outcome {
        case .request(let request):
            Task { @MainActor in
                let response = await self.handler(request)
                self.send(connection, response)
            }
            return true
        case .malformed:
            send(connection, .error("Malformed request", status: 400))
            return true
        case .needsMoreBytes:
            return false
        }
    }

    private func send(_ connection: SocketConnection, _ response: Response) {
        if let stream = response.stream {
            sendStream(connection, stream, keepAlive: response.keepAlive)
            return
        }
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(out) { _ in
            connection.cancel()
        }
    }

    /// Writes SSE headers, keeps the connection open, and hands a writer to the
    /// stream closure. Client disconnects close the writer *and* cancel the
    /// closure, so a handler parked waiting for its next frame unwinds and drops
    /// whatever it subscribed to instead of streaming into a dead socket.
    /// A keepalive ticker runs alongside the closure for as long as it streams.
    private func sendStream(_ connection: SocketConnection,
                            _ handler: @escaping @MainActor (SSEWriter) async -> Void,
                            keepAlive: TimeInterval) {
        let head = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/event-stream; charset=utf-8\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: keep-alive\r\n\r\n"
        let writer = SSEWriter(connection: connection)
        // An SSE client says nothing after its request, so the read ending is
        // the only sign it hung up — and with keepalives off and a quiet
        // stream, no write may ever fail to say so instead.
        connection.whenReadEnds { writer.close() }
        connection.send(Data(head.utf8)) { error in
            if error != nil { writer.close(); return }
            let ticker = Self.startKeepAlive(writer: writer, interval: keepAlive)
            let work = Task { @MainActor in
                await handler(writer)
                ticker?.cancel()
                writer.close()
            }
            // The handler may be awaiting something that will never arrive now
            // that the client is gone (the next run event, say). Cancelling it is
            // what makes it return and release its resources.
            writer.whenClosed {
                ticker?.cancel()
                work.cancel()
            }
        }
    }

    /// Pings an otherwise-silent stream with SSE comments, which clients ignore
    /// as data but still see as traffic. Returns nil when keepalives are off.
    private static func startKeepAlive(writer: SSEWriter, interval: TimeInterval) -> Task<Void, Never>? {
        guard interval > 0 else { return nil }
        return Task.detached {
            while !Task.isCancelled && !writer.isClosed {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, !writer.isClosed else { break }
                writer.comment("keepalive")
            }
        }
    }

    // MARK: - Parsing

    /// What a buffer holds so far: a whole request, a request still arriving, or
    /// a header block that has fully arrived and can never be a request.
    package enum ParseOutcome {
        case request(Request)
        case needsMoreBytes
        case malformed
    }

    /// Returns a fully-received Request, or nil if more bytes are needed or the
    /// header block is malformed.
    package static func parse(_ buffer: Data) -> Request? {
        guard case .request(let request) = parseOutcome(buffer) else { return nil }
        return request
    }

    /// Tells a request that is still arriving apart from one that never will
    /// parse: once the header terminator is in, bad UTF-8 or a request line
    /// without a target is malformed, and waiting for more bytes cannot fix it.
    package static func parseOutcome(_ buffer: Data) -> ParseOutcome {
        guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .needsMoreBytes }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEndRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return .malformed }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .malformed }
        let method = String(parts[0])
        let rawTarget = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Wait for the full body if Content-Length says there's more.
        // A negative length would survive the `available < contentLength` guard below and
        // then form a Range whose lower bound is above its upper — a fatal precondition,
        // not a thrown error. Clamp it, so it reads as no body like any other length we
        // cannot use.
        let contentLength = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        let bodyStart = headerEndRange.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength { return .needsMoreBytes }
        let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))

        let (path, query) = Self.splitTarget(rawTarget)
        return .request(Request(method: method, path: path, query: query, headers: headers, body: body))
    }

    package static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else {
            return (target.removingPercentEncoding ?? target, [:])
        }
        let path = String(target[target.startIndex..<q])
        let queryString = String(target[target.index(after: q)...])
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            // `omittingEmptySubsequences: false` is what keeps a nameless pair from
            // trapping: the default drops empty pieces, so `=` splits to an empty
            // array and reading element 0 is a fatal index — a crash of the whole
            // app, reachable before the bearer check ever runs.
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = kv.first, !rawKey.isEmpty else { continue }
            let key = String(rawKey).removingPercentEncoding ?? String(rawKey)
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            query[key] = value
        }
        return (path.removingPercentEncoding ?? path, query)
    }

    /// Pushes Server-Sent Events over an open connection. Thread-safe; `close()`
    /// is idempotent and also fires when the client disconnects.
    package final class SSEWriter: @unchecked Sendable {
        private let connection: SocketConnection
        private let lock = NSLock()
        private var closed = false
        private var closeHandlers: [() -> Void] = []

        package init(connection: SocketConnection) {
            self.connection = connection
        }

        /// Runs `body` when the stream closes — right away if it already has.
        /// This is how the server tears down what was feeding the stream once the
        /// client is gone; handlers run once and are then released, so nothing
        /// they capture outlives the connection.
        package func whenClosed(_ body: @escaping () -> Void) {
            lock.lock()
            guard !closed else {
                lock.unlock()
                body()
                return
            }
            closeHandlers.append(body)
            lock.unlock()
        }

        package var isClosed: Bool {
            lock.lock(); defer { lock.unlock() }
            return closed
        }

        /// Sends one `data:` frame. `payload` must be single-line (compact JSON).
        package func send(_ payload: String) {
            guard !isClosed else { return }
            let frame = "data: \(payload)\n\n"
            connection.send(Data(frame.utf8)) { [weak self] error in
                if error != nil { self?.close() }
            }
        }

        /// Sends a `:` comment frame — ignored by SSE clients, but a failed write
        /// tells us the peer is gone, which is the point of the keepalive.
        package func comment(_ text: String) {
            guard !isClosed else { return }
            connection.send(Data(": \(text)\n\n".utf8)) { [weak self] error in
                if error != nil { self?.close() }
            }
        }

        package func close() {
            lock.lock()
            let wasClosed = closed
            closed = true
            let handlers = closeHandlers
            closeHandlers = []
            lock.unlock()
            guard !wasClosed else { return }
            connection.cancel()
            for handler in handlers { handler() }
        }
    }

    package static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Status"
        }
    }
}
