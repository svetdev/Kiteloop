import XCTest
@testable import KiteloopCore

/// Unit tests for the control API's minimal HTTP/1.1 server: request parsing
/// (request line, headers, body framing), query-string splitting, reason-phrase
/// mapping, end-to-end dispatch of a live loopback request to the handler, and
/// SSE teardown when the client hangs up.
final class HTTPServerTests: XCTestCase {

    private func raw(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Request line

    func testParsesMethodAndPathFromRequestLine() {
        let request = HTTPServer.parse(raw("GET /v1/projects HTTP/1.1\r\nHost: localhost\r\n\r\n"))
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/v1/projects")
        XCTAssertEqual(request?.query, [:])
        XCTAssertEqual(request?.body, Data())
    }

    func testParsesRequestLineWithoutHTTPVersion() {
        // Only method and target are required; the version token is ignored.
        let request = HTTPServer.parse(raw("DELETE /v1/runs/abc\r\n\r\n"))
        XCTAssertEqual(request?.method, "DELETE")
        XCTAssertEqual(request?.path, "/v1/runs/abc")
    }

    func testParsesRequestLineWithRepeatedSpaces() {
        let request = HTTPServer.parse(raw("POST   /v1/runs   HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/v1/runs")
    }

    func testReturnsNilWhenHeaderTerminatorIsMissing() {
        XCTAssertNil(HTTPServer.parse(raw("GET /health HTTP/1.1\r\nHost: localhost\r\n")))
    }

    func testReturnsNilForRequestLineMissingTarget() {
        XCTAssertNil(HTTPServer.parse(raw("GET\r\n\r\n")))
    }

    func testReturnsNilForNonUTF8Headers() {
        var buffer = Data([0xFF, 0xFE, 0xFF])
        buffer.append(raw("\r\n\r\n"))
        XCTAssertNil(HTTPServer.parse(buffer))
    }

    // MARK: - Incomplete versus malformed

    private func isMalformed(_ buffer: Data) -> Bool {
        if case .malformed = HTTPServer.parseOutcome(buffer) { return true }
        return false
    }

    private func needsMoreBytes(_ buffer: Data) -> Bool {
        if case .needsMoreBytes = HTTPServer.parseOutcome(buffer) { return true }
        return false
    }

    func testCompleteNonUTF8HeadersAreMalformed() {
        var buffer = Data([0xFF, 0xFE, 0xFF])
        buffer.append(raw("\r\n\r\n"))
        XCTAssertTrue(isMalformed(buffer), "more bytes cannot make these headers UTF-8")
    }

    func testCompleteRequestLineMissingTargetIsMalformed() {
        XCTAssertTrue(isMalformed(raw("GET\r\n\r\n")))
    }

    func testMissingHeaderTerminatorNeedsMoreBytes() {
        XCTAssertTrue(needsMoreBytes(raw("GET /health HTTP/1.1\r\nHost: localhost\r\n")))
    }

    func testBodyShorterThanContentLengthNeedsMoreBytes() {
        XCTAssertTrue(needsMoreBytes(raw("POST /v1/runs HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc")))
    }

    // MARK: - Headers

    func testHeaderNamesAreLowercasedAndValuesTrimmed() {
        let request = HTTPServer.parse(raw(
            "GET /health HTTP/1.1\r\nContent-Type:   application/json  \r\nX-Empty:\r\n\r\n"
        ))
        XCTAssertEqual(request?.headers["content-type"], "application/json")
        XCTAssertEqual(request?.headers["x-empty"], "")
    }

    func testHeaderLookupIsCaseInsensitive() {
        let request = HTTPServer.parse(raw(
            "GET /health HTTP/1.1\r\nAuthorization: Bearer abc123\r\n\r\n"
        ))
        XCTAssertEqual(request?.header("Authorization"), "Bearer abc123")
        XCTAssertEqual(request?.header("AUTHORIZATION"), "Bearer abc123")
        XCTAssertEqual(request?.header("authorization"), "Bearer abc123")
        XCTAssertNil(request?.header("X-Absent"))
    }

    func testHeaderValueKeepsColonsAfterTheFirst() {
        let request = HTTPServer.parse(raw(
            "GET /health HTTP/1.1\r\nHost: 127.0.0.1:4517\r\n\r\n"
        ))
        XCTAssertEqual(request?.header("Host"), "127.0.0.1:4517")
    }

    func testHeaderLinesWithoutColonAreSkipped() {
        let request = HTTPServer.parse(raw(
            "GET /health HTTP/1.1\r\ngarbage-line\r\nAccept: */*\r\n\r\n"
        ))
        XCTAssertEqual(request?.headers.count, 1)
        XCTAssertEqual(request?.header("Accept"), "*/*")
    }

    func testRepeatedHeaderKeepsLastValue() {
        let request = HTTPServer.parse(raw(
            "GET /health HTTP/1.1\r\nX-Dup: first\r\nX-Dup: second\r\n\r\n"
        ))
        XCTAssertEqual(request?.header("X-Dup"), "second")
    }

    // MARK: - Body framing

    func testParsesBodyOfDeclaredContentLength() {
        let request = HTTPServer.parse(raw(
            "POST /v1/runs HTTP/1.1\r\nContent-Length: 13\r\n\r\n{\"item\":\"a\"}\n"
        ))
        XCTAssertEqual(request?.body, raw("{\"item\":\"a\"}\n"))
    }

    func testReturnsNilWhileBodyIsIncomplete() {
        XCTAssertNil(HTTPServer.parse(raw(
            "POST /v1/runs HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"item\":"
        )))
    }

    func testBodyIsEmptyWithoutContentLength() {
        let request = HTTPServer.parse(raw("POST /v1/runs HTTP/1.1\r\n\r\nignored-trailing-bytes"))
        XCTAssertEqual(request?.body, Data())
    }

    func testBytesBeyondContentLengthAreIgnored() {
        let request = HTTPServer.parse(raw(
            "POST /v1/runs HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi-and-then-some-more"
        ))
        XCTAssertEqual(request?.body, raw("hi"))
    }

    func testMalformedContentLengthIsTreatedAsZero() {
        let request = HTTPServer.parse(raw(
            "POST /v1/runs HTTP/1.1\r\nContent-Length: not-a-number\r\n\r\nbody"
        ))
        XCTAssertEqual(request?.body, Data())
    }

    func testNegativeContentLengthIsTreatedAsZero() {
        let request = HTTPServer.parse(raw(
            "POST /v1/runs HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
        ))
        XCTAssertEqual(request?.body, Data())
    }

    func testNegativeContentLengthDoesNotReadTrailingBytesAsBody() {
        let request = HTTPServer.parse(raw(
            "POST /v1/runs HTTP/1.1\r\nContent-Length: -1\r\n\r\nbody"
        ))
        XCTAssertEqual(request?.body, Data())
    }

    func testParsesBinaryBody() {
        var buffer = raw("POST /upload HTTP/1.1\r\nContent-Length: 4\r\n\r\n")
        let payload = Data([0x00, 0xFF, 0x0D, 0x0A])
        buffer.append(payload)
        XCTAssertEqual(HTTPServer.parse(buffer)?.body, payload)
    }

    func testBodyContainingHeaderTerminatorIsNotSplitEarly() {
        // The first \r\n\r\n ends the headers; a second one inside the body is data.
        let body = "a\r\n\r\nb"
        let request = HTTPServer.parse(raw(
            "POST /v1/runs HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        ))
        XCTAssertEqual(request?.body, raw(body))
    }

    // MARK: - Query splitting

    func testSplitTargetWithoutQuery() {
        let (path, query) = HTTPServer.splitTarget("/v1/backlog")
        XCTAssertEqual(path, "/v1/backlog")
        XCTAssertEqual(query, [:])
    }

    func testSplitTargetParsesMultiplePairs() {
        let (path, query) = HTTPServer.splitTarget("/v1/backlog?project=kiteloop&status=ready")
        XCTAssertEqual(path, "/v1/backlog")
        XCTAssertEqual(query, ["project": "kiteloop", "status": "ready"])
    }

    func testSplitTargetGivesEmptyStringForValuelessKeys() {
        let (_, query) = HTTPServer.splitTarget("/v1/backlog?a=&b")
        XCTAssertEqual(query, ["a": "", "b": ""])
    }

    func testSplitTargetKeepsEqualsSignsInsideValue() {
        let (_, query) = HTTPServer.splitTarget("/v1/backlog?token=a=b=c")
        XCTAssertEqual(query["token"], "a=b=c")
    }

    func testSplitTargetWithEmptyQueryString() {
        let (path, query) = HTTPServer.splitTarget("/v1/backlog?")
        XCTAssertEqual(path, "/v1/backlog")
        XCTAssertEqual(query, [:])
    }

    func testSplitTargetWithBareEqualsPair() {
        // `GET /health?=` used to trap on an empty split result and take the app
        // down — before any bearer check, so from an unauthenticated request.
        let (path, query) = HTTPServer.splitTarget("/health?=")
        XCTAssertEqual(path, "/health")
        XCTAssertEqual(query, [:])
    }

    func testSplitTargetDropsUnnamedPairWithAValue() {
        // A pair with no name names nothing: the value must not be promoted to a key.
        let (_, query) = HTTPServer.splitTarget("/v1/backlog?=value")
        XCTAssertEqual(query, [:])
    }

    func testSplitTargetKeepsNamedPairsBesideAnUnnamedOne() {
        let (_, query) = HTTPServer.splitTarget("/v1/backlog?a=1&=&b=2")
        XCTAssertEqual(query, ["a": "1", "b": "2"])
    }

    func testSplitTargetDecodesPercentEncoding() {
        let (path, query) = HTTPServer.splitTarget("/v1/back%20log?project=%2FUsers%2Fme%2Fmy%20app")
        XCTAssertEqual(path, "/v1/back log")
        XCTAssertEqual(query["project"], "/Users/me/my app")
    }

    func testSplitTargetDecodesPercentEncodedKeys() {
        let (_, query) = HTTPServer.splitTarget("/v1/backlog?my%20key=v")
        XCTAssertEqual(query["my key"], "v")
    }

    func testSplitTargetLeavesInvalidPercentEncodingIntact() {
        let (path, query) = HTTPServer.splitTarget("/v1/bad%zz?k=%zz")
        XCTAssertEqual(path, "/v1/bad%zz")
        XCTAssertEqual(query["k"], "%zz")
    }

    func testSplitTargetDoesNotDecodePlusAsSpace() {
        // Form-style '+' is not special here — only percent-encoding is decoded.
        let (_, query) = HTTPServer.splitTarget("/v1/backlog?q=a+b")
        XCTAssertEqual(query["q"], "a+b")
    }

    func testSplitTargetSplitsOnFirstQuestionMarkOnly() {
        let (path, query) = HTTPServer.splitTarget("/v1/backlog?a?b=1")
        XCTAssertEqual(path, "/v1/backlog")
        XCTAssertEqual(query["a?b"], "1")
    }

    func testRepeatedQueryKeyKeepsLastValue() {
        let (_, query) = HTTPServer.splitTarget("/v1/backlog?p=one&p=two")
        XCTAssertEqual(query["p"], "two")
    }

    func testParseAppliesQuerySplittingToTheRequestTarget() {
        let request = HTTPServer.parse(raw("GET /v1/backlog?project=demo HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(request?.path, "/v1/backlog")
        XCTAssertEqual(request?.query, ["project": "demo"])
    }

    // MARK: - Reason phrases

    func testReasonPhraseMapping() {
        let expected: [Int: String] = [
            200: "OK",
            201: "Created",
            202: "Accepted",
            400: "Bad Request",
            401: "Unauthorized",
            404: "Not Found",
            405: "Method Not Allowed",
            409: "Conflict",
            413: "Payload Too Large",
            500: "Internal Server Error",
            501: "Not Implemented"
        ]
        for (status, phrase) in expected {
            XCTAssertEqual(HTTPServer.reason(status), phrase, "status \(status)")
        }
    }

    func testReasonPhraseFallsBackForUnmappedStatus() {
        XCTAssertEqual(HTTPServer.reason(418), "Status")
        XCTAssertEqual(HTTPServer.reason(503), "Status")
    }

    // MARK: - Response builders

    func testJSONResponseSetsContentTypeAndBody() throws {
        let response = HTTPServer.Response.json(["status": "ok"])
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/json; charset=utf-8")
        let decoded = try JSONSerialization.jsonObject(with: response.body) as? [String: String]
        XCTAssertEqual(decoded, ["status": "ok"])
        XCTAssertNil(response.stream)
    }

    func testErrorResponseCarriesMessageAndStatus() throws {
        let response = HTTPServer.Response.error("nope", status: 409)
        XCTAssertEqual(response.status, 409)
        let decoded = try JSONSerialization.jsonObject(with: response.body) as? [String: String]
        XCTAssertEqual(decoded, ["error": "nope"])
    }

    // MARK: - Live dispatch over loopback

    func testServerDispatchesRequestToHandlerAndReturnsResponse() async throws {
        let recorder = RequestRecorder()
        let port = try freeLoopbackPort()
        let server = HTTPServer(port: port) { request in
            recorder.record(request)
            return .json(["path": request.path, "item": request.query["item"] ?? ""], status: 201)
        }
        try server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/runs?item=test-httpserver")!)
        request.httpMethod = "POST"
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"project":"demo"}"#.utf8)

        let (data, response) = try await send(request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 201)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), String(data.count))

        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(decoded, ["path": "/v1/runs", "item": "test-httpserver"])

        let received = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(received.method, "POST")
        XCTAssertEqual(received.path, "/v1/runs")
        XCTAssertEqual(received.query["item"], "test-httpserver")
        XCTAssertEqual(received.header("Authorization"), "Bearer secret")
        XCTAssertEqual(received.body, Data(#"{"project":"demo"}"#.utf8))
    }

    func testServerReportsHandlerErrorStatusWithReasonPhrase() async throws {
        let port = try freeLoopbackPort()
        let server = HTTPServer(port: port) { _ in .error("No route", status: 404) }
        try server.start()
        defer { server.stop() }

        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/nope")!)
        let (data, response) = try await send(request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 404)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(decoded, ["error": "No route"])
    }

    // MARK: - Listener state

    /// Collects `onStateChange` callbacks, which arrive on the server's
    /// private dispatch queue rather than the calling thread.
    private final class StateCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [HTTPServer.ListenerState] = []

        func record(_ state: HTTPServer.ListenerState) {
            lock.lock(); defer { lock.unlock() }
            states.append(state)
        }

        var all: [HTTPServer.ListenerState] {
            lock.lock(); defer { lock.unlock() }
            return states
        }
    }

    func testOnStateChangeReportsReadyOnceTheListenerBinds() async throws {
        let port = try freeLoopbackPort()
        let server = HTTPServer(port: port) { _ in .json(["ok": true]) }
        let collector = StateCollector()
        server.onStateChange = { collector.record($0) }
        try server.start()
        defer { server.stop() }

        try await eventually("the listener to report .ready") {
            collector.all.contains(.ready)
        }
    }

    func testOnStateChangeReportsFailedForASecondListenerOnAHeldPort() async throws {
        let port = try freeLoopbackPort()
        let holder = HTTPServer(port: port) { _ in .json(["ok": true]) }
        try holder.start()
        defer { holder.stop() }
        // Wait for the first listener to actually be bound, so the second
        // one's failure is a real conflict and not a race with the first.
        _ = try await send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))

        let contender = HTTPServer(port: port) { _ in .json(["ok": true]) }
        let collector = StateCollector()
        contender.onStateChange = { collector.record($0) }
        try contender.start()
        defer { contender.stop() }

        try await eventually("the second listener to report .failed") {
            collector.all.contains { if case .failed = $0 { return true } else { return false } }
        }
        XCTAssertFalse(collector.all.contains(.ready), "a listener that lost the port must never report ready")
        let reason = collector.all.compactMap { if case .failed(let why) = $0 { return why } else { return nil } }.first
        XCTAssertEqual(reason, "bind: Address already in use (errno 48)",
                       "the reason names the call that failed and what the system said")
    }

    /// The pairing forwarder holds the control port on the Mac's LAN and
    /// tailnet addresses. `NWListener` collided with any such socket, so the
    /// API never came up while the forwarder ran. A socket holding the port on
    /// every address stands in for the forwarder — `NWListener` fails beside
    /// it the same way, and a test machine may have no LAN address to use.
    func testListenerComesUpBesideASocketHoldingThePortOnOtherAddresses() async throws {
        let port = try freeLoopbackPort()
        let holder = try holdPortOnEveryAddress(port)
        defer { close(holder) }

        let server = HTTPServer(port: port) { _ in .json(["ok": true]) }
        let collector = StateCollector()
        server.onStateChange = { collector.record($0) }
        try server.start()
        defer { server.stop() }

        try await eventually("the listener to report .ready beside the holder") {
            collector.all.contains(.ready)
        }
        // The holder never accepts, so an answer can only have come from ours.
        let (data, response) = try await send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: Bool], ["ok": true])
    }

    func testStopReportsCancelled() async throws {
        let port = try freeLoopbackPort()
        let server = HTTPServer(port: port) { _ in .json(["ok": true]) }
        let collector = StateCollector()
        server.onStateChange = { collector.record($0) }
        try server.start()
        try await eventually("the listener to report .ready") { collector.all.contains(.ready) }

        server.stop()

        try await eventually("the listener to report .cancelled") { collector.all.contains(.cancelled) }
    }

    // MARK: - SSE keepalive

    func testSSEResponseCarriesStreamAndDefaultKeepAliveInterval() {
        let response = HTTPServer.Response.sse { _ in }
        XCTAssertNotNil(response.stream)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.keepAlive, 15)
        XCTAssertEqual(HTTPServer.Response.sse(keepAlive: 0.5) { _ in }.keepAlive, 0.5)
        // Unary responses never tick.
        XCTAssertEqual(HTTPServer.Response.json(["a": 1]).keepAlive, 0)
    }

    func testIdleSSEStreamSendsPeriodicKeepAliveComments() async throws {
        let port = try freeLoopbackPort()
        let server = HTTPServer(port: port) { _ in
            // A stream that never emits data — only the keepalive should be seen.
            .sse(keepAlive: 0.2) { writer in
                while !writer.isClosed {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        try server.start()
        defer { server.stop() }
        let session = streamingSession()
        defer { session.invalidateAndCancel() }

        var comments = 0
        for try await line in try await openStream(session, port: port, path: "/v1/runs/r1/events") {
            if line.hasPrefix(":") {
                XCTAssertEqual(line, ": keepalive")
                comments += 1
                if comments == 2 { break }
            } else {
                XCTAssertTrue(line.isEmpty, "unexpected frame on an idle stream: \(line)")
            }
        }
        XCTAssertEqual(comments, 2, "idle stream should keep pinging")
    }

    func testSSEStreamWithoutKeepAliveStaysSilentWhileIdle() async throws {
        let port = try freeLoopbackPort()
        let server = HTTPServer(port: port) { _ in
            .sse(keepAlive: 0) { writer in
                // Idle well past the keepalive interval used above, then speak.
                try? await Task.sleep(nanoseconds: 600_000_000)
                writer.send(#"{"type":"run.completed"}"#)
                while !writer.isClosed {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        try server.start()
        defer { server.stop() }

        let session = streamingSession()
        defer { session.invalidateAndCancel() }

        var frames: [String] = []
        for try await line in try await openStream(session, port: port, path: "/v1/runs/r1/events") where !line.isEmpty {
            frames.append(line)
            break
        }
        XCTAssertEqual(frames, [#"data: {"type":"run.completed"}"#],
                       "no comment should precede the data frame when keepalives are off")
    }

    // MARK: - Disconnect cleanup

    func testClientDisconnectClosesWriterAndCancelsTheStreamHandler() async throws {
        let port = try freeLoopbackPort()
        let finished = expectation(description: "stream handler returned")
        let closedOnExit = Flag()
        let server = HTTPServer(port: port) { _ in
            // Keepalives off, so a failed write can never be what notices the
            // disconnect — only watching the socket can.
            .sse(keepAlive: 0) { writer in
                writer.send(#"{"type":"run.started"}"#)
                // Parked exactly like the run-events handler is between events:
                // this stream never yields, so only cancellation ends the loop.
                let quiet = AsyncStream<Int> { _ in }
                for await _ in quiet {}
                closedOnExit.set(writer.isClosed)
                finished.fulfill()
            }
        }
        try server.start()
        defer { server.stop() }

        let session = streamingSession()
        for try await line in try await openStream(session, port: port, path: "/v1/runs/r1/events") where !line.isEmpty {
            XCTAssertEqual(line, #"data: {"type":"run.started"}"#)
            break
        }
        // Hang up the way a killed `curl -N` does.
        session.invalidateAndCancel()

        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(closedOnExit.value, "the writer should be closed by the time the handler unwinds")
    }

    func testWhenClosedHandlersRunOnceAndFireImmediatelyAfterClose() {
        let writer = HTTPServer.SSEWriter(connection: idleConnection())
        let counter = Counter()
        writer.whenClosed { counter.increment() }
        writer.whenClosed { counter.increment() }
        XCTAssertEqual(counter.value, 0, "handlers should not run while the stream is open")

        writer.close()
        XCTAssertEqual(counter.value, 2)
        XCTAssertTrue(writer.isClosed)

        // close() is idempotent, and a late registration still gets its callback.
        writer.close()
        writer.whenClosed { counter.increment() }
        XCTAssertEqual(counter.value, 3)
    }

    func testClosedWriterDropsFrames() {
        let writer = HTTPServer.SSEWriter(connection: idleConnection())
        writer.close()
        // Nothing to assert beyond "doesn't send / doesn't trap" — the guard is
        // what keeps a finished handler from writing into a cancelled connection.
        writer.send(#"{"type":"run.completed"}"#)
        writer.comment("keepalive")
        XCTAssertTrue(writer.isClosed)
    }

    // MARK: - Request size cap

    /// The cap is on bytes buffered, and a request of exactly that many bytes
    /// is inside it: it is parsed and served. One byte more is refused with
    /// 413 before it is parsed, however well-formed it is.
    func testRequestOfExactlyTheSizeCapIsServedAndOneByteOverIsRefused() async throws {
        let cap = 2 * 1024 * 1024
        let port = try freeLoopbackPort()
        let server = HTTPServer(port: port) { request in .json(["received": request.body.count]) }
        try server.start()
        defer { server.stop() }

        let atCap = Self.request(totalBytes: cap)
        let exact = try await RawClient.connect(port: port)
        try exact.write(atCap.bytes)
        let served = exact.readToEnd()
        XCTAssertEqual(Self.statusCode(of: served), 200, "a request of exactly the cap is within it")
        XCTAssertEqual(Self.jsonBody(of: served)?["received"] as? Int, atCap.bodyCount)

        let overCap = Self.request(totalBytes: cap + 1)
        let over = try await RawClient.connect(port: port)
        try over.write(overCap.bytes)
        XCTAssertEqual(Self.statusCode(of: over.readToEnd()), 413, "one byte past the cap is refused")
    }

    // MARK: - Malformed request

    /// A header block that has fully arrived but can never parse is answered
    /// with 400 and closed, rather than held open waiting for bytes that
    /// cannot fix it. The handler never sees it.
    func testCompleteMalformedRequestIsAnsweredWith400() async throws {
        let port = try freeLoopbackPort()
        let calls = Counter()
        let server = HTTPServer(port: port) { _ in
            calls.increment()
            return .json(["ok": true])
        }
        try server.start()
        defer { server.stop() }

        let client = try await RawClient.connect(port: port)
        try client.write("GET\r\n\r\n")
        let started = Date()
        let response = client.readToEnd()
        XCTAssertEqual(Self.statusCode(of: response), 400)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the connection should close, not wait out the read timeout")
        XCTAssertEqual(calls.value, 0, "a malformed request never reaches the handler")
    }

    // MARK: - Watching the SSE client

    /// A client that simply hangs up — end of input, no error — closes the
    /// writer: the watcher reads a clean FIN as the peer going away.
    func testCleanClientHangUpClosesTheWriter() async throws {
        let port = try freeLoopbackPort()
        let box = WriterBox()
        let server = parkedStreamServer(port: port, box: box)
        try server.start()
        defer { server.stop() }

        let client = try await RawClient.connect(port: port)
        try await client.openStream(path: "/v1/runs/r1/events")
        XCTAssertEqual(box.isClosed, false, "the stream is open while the client is connected")

        client.halfClose()
        try await eventually("the writer to close after the client's FIN") { box.isClosed == true }
    }

    /// Bytes a client sends on an open stream are not part of the protocol:
    /// they are ignored, and the stream stays open and live.
    func testStrayBytesFromTheClientDoNotEndTheStream() async throws {
        let port = try freeLoopbackPort()
        let box = WriterBox()
        let server = parkedStreamServer(port: port, box: box)
        try server.start()
        defer { server.stop() }

        let client = try await RawClient.connect(port: port)
        try await client.openStream(path: "/v1/runs/r1/events")

        try client.write("ping\r\n")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(box.isClosed, false, "stray input must not be read as a hang-up")

        // Not merely unclosed: a frame sent now still reaches the client.
        box.send(#"{"type":"still-here"}"#)
        XCTAssertTrue(client.read(until: "still-here").contains(#"data: {"type":"still-here"}"#),
                      "the stream should still be carrying frames after stray input")
    }

    /// Stray input does not end the watch either: a hang-up that comes after
    /// it is still noticed, which is what lets a parked handler unwind.
    func testClientHangUpAfterStrayBytesStillClosesTheWriter() async throws {
        let port = try freeLoopbackPort()
        let box = WriterBox()
        let server = parkedStreamServer(port: port, box: box)
        try server.start()
        defer { server.stop() }

        let client = try await RawClient.connect(port: port)
        try await client.openStream(path: "/v1/runs/r1/events")

        try client.write("ping\r\n")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(box.isClosed, false, "stray input must not be read as a hang-up")

        client.halfClose()
        try await eventually("the writer to close after a FIN that followed stray bytes") { box.isClosed == true }
    }

    // MARK: - Consecutive frames

    /// Every frame a handler sends reaches the client, not just the first: a
    /// write that succeeds leaves the stream open for the next one.
    func testConsecutiveDataFramesAllReachTheClient() async throws {
        let port = try freeLoopbackPort()
        let server = HTTPServer(port: port) { _ in
            .sse(keepAlive: 0) { writer in
                for n in 1...3 {
                    writer.send(#"{"n":\#(n)}"#)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                // Park until the client hangs up — for at most ten seconds, so
                // a writer nothing closes cannot keep this handler forever.
                for _ in 0..<200 where !writer.isClosed {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        try server.start()
        defer { server.stop() }
        let session = streamingSession()
        defer { session.invalidateAndCancel() }

        var frames: [String] = []
        do {
            for try await line in try await openStream(session, port: port, path: "/v1/runs/r1/events") where !line.isEmpty {
                frames.append(line)
                if frames.count == 3 { break }
            }
        } catch {
            // The stream ended early; the assertion below says after what.
        }
        XCTAssertEqual(frames, [#"data: {"n":1}"#, #"data: {"n":2}"#, #"data: {"n":3}"#])
    }

    // MARK: - Helpers

    /// One end of a socket pair nothing reads — enough to build an SSEWriter
    /// around for the tests that only exercise its close bookkeeping. The
    /// other end is closed with the test.
    private func idleConnection() -> SocketConnection {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        addTeardownBlock { [peer = pair[1]] in close(peer) }
        return SocketConnection(fileDescriptor: pair[0])
    }

    /// A counter for callbacks that fire off the test's thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    /// A boolean written on the handler's task and read back on the test's.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func set(_ newValue: Bool) {
            lock.lock(); defer { lock.unlock() }
            flag = newValue
        }

        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return flag
        }
    }

    /// A session whose request timeout is long enough that an idle SSE stream
    /// isn't torn down before the keepalive has had time to fire.
    private func streamingSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    /// Opens an SSE response and returns its lines, retrying while the listener
    /// finishes binding. The caller stops reading by breaking out of the loop,
    /// and owns the session — invalidating it is what closes the stream.
    private func openStream(_ session: URLSession, port: UInt16, path: String, attempts: Int = 20) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!

        var lastError: Error?
        for _ in 0..<attempts {
            do {
                let (bytes, response) = try await session.bytes(from: url)
                let http = try XCTUnwrap(response as? HTTPURLResponse)
                XCTAssertEqual(http.statusCode, 200)
                XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/event-stream; charset=utf-8")
                return bytes.lines
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw try XCTUnwrap(lastError)
    }

    /// Collects the requests a live server handed to its route handler.
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [HTTPServer.Request] = []

        func record(_ request: HTTPServer.Request) {
            lock.lock(); defer { lock.unlock() }
            storage.append(request)
        }

        var requests: [HTTPServer.Request] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    /// Binds port 0 on loopback, reads back the port the kernel picked, and
    /// releases it — so the test server gets a port nothing else is using.
    private func freeLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(fd < 0, "Could not create a probe socket")
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(bound != 0, "Could not bind a loopback probe port")

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        try XCTSkipIf(named != 0, "Could not read back the probe port")
        return UInt16(bigEndian: assigned.sin_port)
    }

    /// Listens on 0.0.0.0:`port`, the way another program holding the port on
    /// all of the Mac's addresses would. Returns the socket to close.
    private func holdPortOnEveryAddress(_ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(fd < 0, "Could not create a holder socket")
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw XCTSkip("Could not hold port \(port) on every address")
        }
        return fd
    }

    /// Sends a request, retrying briefly while the listener finishes binding.
    private func send(_ request: URLRequest, attempts: Int = 20) async throws -> (Data, URLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var lastError: Error?
        for _ in 0..<attempts {
            do {
                return try await session.data(for: request)
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw try XCTUnwrap(lastError)
    }

    // MARK: - Helpers for the raw-socket tests

    /// The writer a stream handler was given, so a test can ask whether the
    /// server has closed it, and push a frame through it itself.
    private final class WriterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: HTTPServer.SSEWriter?

        func set(_ writer: HTTPServer.SSEWriter) {
            lock.lock(); defer { lock.unlock() }
            stored = writer
        }

        /// nil until the handler has run.
        var isClosed: Bool? {
            lock.lock(); defer { lock.unlock() }
            return stored?.isClosed
        }

        func send(_ payload: String) {
            lock.lock(); defer { lock.unlock() }
            stored?.send(payload)
        }
    }

    /// A server whose stream handler sends one frame and then parks until its
    /// writer closes — for at most ten seconds, so a writer nothing closes
    /// cannot keep the handler forever. Keepalives are off: only the
    /// disconnect watcher can notice the client going away.
    private func parkedStreamServer(port: UInt16, box: WriterBox) -> HTTPServer {
        HTTPServer(port: port) { _ in
            .sse(keepAlive: 0) { writer in
                box.set(writer)
                writer.send(#"{"type":"run.started"}"#)
                for _ in 0..<200 where !writer.isClosed {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
    }

    /// A POST whose request line, headers and body together come to exactly
    /// `totalBytes`.
    private static func request(totalBytes: Int) -> (bytes: Data, bodyCount: Int) {
        func head(_ bodyCount: Int) -> String {
            "POST /v1/upload HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(bodyCount)\r\n\r\n"
        }
        // The body count is written into its own header, so settle it by iteration.
        var bodyCount = totalBytes - head(totalBytes).utf8.count
        while head(bodyCount).utf8.count + bodyCount != totalBytes {
            bodyCount = totalBytes - head(bodyCount).utf8.count
        }
        var bytes = Data(head(bodyCount).utf8)
        bytes.append(Data(repeating: UInt8(ascii: "x"), count: bodyCount))
        return (bytes, bodyCount)
    }

    private static func statusCode(of response: Data) -> Int? {
        let statusLine = String(decoding: response, as: UTF8.self).prefix { $0 != "\r" }
        let parts = statusLine.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    private static func jsonBody(of response: Data) -> [String: Any]? {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: response[split.upperBound...])) as? [String: Any]
    }

    /// A plain TCP client for what URLSession cannot do: send a request of an
    /// exact byte count, write on the socket after the request has gone out,
    /// and half-close it so the server sees a clean end of input rather than
    /// an error.
    private final class RawClient {
        private let fd: Int32
        private var received = Data()

        private init(fd: Int32) { self.fd = fd }
        deinit { _ = Darwin.close(fd) }

        /// Connects to loopback, retrying while the listener finishes binding.
        static func connect(port: UInt16, attempts: Int = 20) async throws -> RawClient {
            var lastErrno: Int32 = ECONNREFUSED
            for _ in 0..<attempts {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw POSIXError(.EMFILE) }
                var on: Int32 = 1
                // A write to a socket the server has closed must fail, not kill the test host.
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let connected = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if connected == 0 { return RawClient(fd: fd) }
                lastErrno = errno
                _ = Darwin.close(fd)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw POSIXError(POSIXErrorCode(rawValue: lastErrno) ?? .ECONNREFUSED)
        }

        /// Sends a GET for an SSE stream and reads up to its first `data:`
        /// frame, asserting the response opened as a stream.
        func openStream(path: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            try write("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            let opened = read(until: "\n\ndata: ")
            XCTAssertTrue(opened.hasPrefix("HTTP/1.1 200 OK"), opened, file: file, line: line)
            XCTAssertTrue(opened.contains("Content-Type: text/event-stream"), opened, file: file, line: line)
        }

        func write(_ text: String) throws { try write(Data(text.utf8)) }

        func write(_ data: Data) throws {
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { raw -> Int in
                    Darwin.write(fd, raw.baseAddress! + offset, data.count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }

        /// Reads until everything received so far contains `marker`, the peer
        /// closes, or `timeout` passes, and returns everything received so far.
        @discardableResult
        func read(until marker: String, timeout: TimeInterval = 5) -> String {
            let deadline = Date().addingTimeInterval(timeout)
            while !text.contains(marker), Date() < deadline {
                if readSome(timeout: 0.1) == .closed { break }
            }
            return text
        }

        /// Reads until the peer closes or `timeout` passes.
        func readToEnd(timeout: TimeInterval = 10) -> Data {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if readSome(timeout: 0.1) == .closed { break }
            }
            return received
        }

        /// Sends a FIN and keeps reading: the clean hang-up, as opposed to a
        /// reset.
        func halfClose() { _ = shutdown(fd, SHUT_WR) }

        private var text: String { String(decoding: received, as: UTF8.self) }

        private enum ReadOutcome { case data, closed, nothingYet }

        private func readSome(timeout: TimeInterval) -> ReadOutcome {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return .nothingYet }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count > 0 {
                received.append(contentsOf: chunk[0..<count])
                return .data
            }
            if count == 0 { return .closed }
            return errno == EINTR || errno == EAGAIN ? .nothingYet : .closed
        }
    }
}
