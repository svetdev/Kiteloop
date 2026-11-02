import XCTest
@testable import Kiteloop

/// Covers the pair of named pipes the MCP tool bridge runs on: the request FIFO
/// (node → Kiteloop, one `tool_call` line per call) and the response FIFO
/// (Kiteloop → node, one `result` line per call). Both directions are
/// newline-delimited JSON, so the tests exercise framing as well as content —
/// a stray raw newline on either side desynchronises the bridge permanently.
final class MCPToolFIFOProtocolTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a request line exactly as `toolBridgeScript` does:
    /// `JSON.stringify({ type: 'tool_call', request_id, tool_name, input }) + '\n'`.
    private func bridgeRequestLine(
        requestID: String,
        toolName: String,
        input: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let object: [String: Any] = [
            "type": "tool_call",
            "request_id": requestID,
            "tool_name": toolName,
            "input": input
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            XCTFail("Could not encode a bridge request line", file: file, line: line)
            return ""
        }
        return json + "\n"
    }

    /// Splits a FIFO stream into lines the way the pipe readers do, so framing
    /// bugs surface here rather than only in a live session.
    private func fifoLines(_ stream: String) -> [String] {
        stream.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func decodeObject(
        _ json: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected \(json) to decode as a JSON object", file: file, line: line)
            return [:]
        }
        return object
    }

    // MARK: - Request FIFO: decoding

    func testParsesToolCallFromRequestPipe() throws {
        let line = #"{"type":"tool_call","request_id":"tool_1_1700000000","tool_name":"publish_event","input":{"title":"Deploy done"}}"#
        let payload = try XCTUnwrap(ClaudeCodeCLIRuntime.parseToolRequestLine(line))

        XCTAssertEqual(payload.requestID, "tool_1_1700000000")
        XCTAssertEqual(payload.toolName, "publish_event")
        XCTAssertEqual(decodeObject(payload.input)["title"] as? String, "Deploy done")
    }

    func testParsesToolCallWrittenByTheBridge() throws {
        let line = bridgeRequestLine(
            requestID: "tool_3_1700000000",
            toolName: "message_agent",
            input: ["to": "Reviewer", "body": "ping"]
        )
        let payload = try XCTUnwrap(ClaudeCodeCLIRuntime.parseToolRequestLine(String(line.dropLast())))

        XCTAssertEqual(payload.requestID, "tool_3_1700000000")
        XCTAssertEqual(payload.toolName, "message_agent")
        XCTAssertEqual(decodeObject(payload.input)["to"] as? String, "Reviewer")
    }

    func testMissingInputDecodesToEmptyObject() throws {
        let line = #"{"type":"tool_call","request_id":"tool_1","tool_name":"recall_knowledge"}"#
        let payload = try XCTUnwrap(ClaudeCodeCLIRuntime.parseToolRequestLine(line))

        XCTAssertEqual(payload.input, "{}")
    }

    func testNonObjectInputDecodesToEmptyObject() throws {
        let line = #"{"type":"tool_call","request_id":"tool_1","tool_name":"recall_knowledge","input":"nope"}"#
        let payload = try XCTUnwrap(ClaudeCodeCLIRuntime.parseToolRequestLine(line))

        XCTAssertEqual(payload.input, "{}")
    }

    func testNestedInputSurvivesReEncoding() throws {
        let line = bridgeRequestLine(
            requestID: "tool_1",
            toolName: "save_knowledge",
            input: [
                "path": "notes/a.md",
                "tags": ["one", "two"],
                "meta": ["pinned": true, "weight": 3],
                "count": 42
            ]
        )
        let payload = try XCTUnwrap(ClaudeCodeCLIRuntime.parseToolRequestLine(String(line.dropLast())))
        let input = decodeObject(payload.input)

        XCTAssertEqual(input["path"] as? String, "notes/a.md")
        XCTAssertEqual(input["tags"] as? [String], ["one", "two"])
        XCTAssertEqual(input["count"] as? Int, 42)
        let meta = input["meta"] as? [String: Any]
        XCTAssertEqual(meta?["pinned"] as? Bool, true)
        XCTAssertEqual(meta?["weight"] as? Int, 3)
    }

    func testUnicodeAndEscapesSurviveDecoding() throws {
        let body = "line one\nline \"two\"\ttabbed 🎉"
        let line = bridgeRequestLine(
            requestID: "tool_1",
            toolName: "message_agent",
            input: ["body": body]
        )

        XCTAssertEqual(fifoLines(line).count, 1, "an embedded newline must not split the request line")

        let payload = try XCTUnwrap(ClaudeCodeCLIRuntime.parseToolRequestLine(String(line.dropLast())))
        XCTAssertEqual(decodeObject(payload.input)["body"] as? String, body)
    }

    // MARK: - Request FIFO: lines that are not tool calls

    /// The request pipe carries nothing but tool calls, so an unnamed tool is a
    /// malformed line rather than a call on the empty-string tool.
    func testDropsLineWithoutToolName() {
        XCTAssertNil(ClaudeCodeCLIRuntime.parseToolRequestLine(#"{"type":"tool_call","request_id":"tool_1"}"#))
    }

    func testDropsLineWithoutRequestID() {
        XCTAssertNil(ClaudeCodeCLIRuntime.parseToolRequestLine(#"{"type":"tool_call","tool_name":"publish_event"}"#))
    }

    func testDropsLineWithNonStringFields() {
        XCTAssertNil(ClaudeCodeCLIRuntime.parseToolRequestLine(#"{"request_id":7,"tool_name":"publish_event"}"#))
        XCTAssertNil(ClaudeCodeCLIRuntime.parseToolRequestLine(#"{"request_id":"tool_1","tool_name":42}"#))
    }

    func testDropsMalformedAndNonObjectLines() {
        XCTAssertNil(ClaudeCodeCLIRuntime.parseToolRequestLine(""))
        XCTAssertNil(ClaudeCodeCLIRuntime.parseToolRequestLine(#"{"request_id":"tool_1""#))
        XCTAssertNil(ClaudeCodeCLIRuntime.parseToolRequestLine("node:internal/errors: throw err"))
        XCTAssertNil(ClaudeCodeCLIRuntime.parseToolRequestLine(#"["request_id","tool_1"]"#))
    }

    /// `type` is informational on this pipe — the bridge only ever writes
    /// `tool_call`, and the reader keys off the required fields instead.
    func testParsesLineWithoutTypeMarker() throws {
        let line = #"{"request_id":"tool_1","tool_name":"publish_event","input":{}}"#
        let payload = try XCTUnwrap(ClaudeCodeCLIRuntime.parseToolRequestLine(line))

        XCTAssertEqual(payload.toolName, "publish_event")
    }

    // MARK: - Response FIFO: encoding

    func testResultLineIsOneNewlineTerminatedJSONObject() {
        let json = ClaudeCodeCLIRuntime.mcpToolResultJSON(requestID: "tool_1", result: "ok")

        XCTAssertTrue(json.hasSuffix("\n"), "bridge splits the FIFO stream on newlines")
        let object = decodeObject(String(json.dropLast()))
        XCTAssertEqual(object["request_id"] as? String, "tool_1")
        XCTAssertEqual(object["result"] as? String, "ok")
    }

    func testEmptyResultIsStillAValidLine() {
        let json = ClaudeCodeCLIRuntime.mcpToolResultJSON(requestID: "tool_1", result: "")
        let object = decodeObject(String(json.dropLast()))

        // The bridge falls back to '' on a missing result; an empty string must
        // still arrive as a resolved call rather than a dropped line.
        XCTAssertEqual(object["result"] as? String, "")
    }

    /// Tool results routinely carry multi-line text (search hits, file bodies).
    /// Those newlines must be escaped or the bridge sees a truncated line
    /// followed by garbage and never resolves the call.
    func testMultiLineResultStaysOnOneLine() {
        let result = "first\nsecond\nthird"
        let json = ClaudeCodeCLIRuntime.mcpToolResultJSON(requestID: "tool_1", result: result)

        XCTAssertEqual(fifoLines(json).count, 1)
        XCTAssertEqual(decodeObject(String(json.dropLast()))["result"] as? String, result)
    }

    func testResultEscapesQuotesBackslashesAndControlCharacters() {
        let result = #"say "hi"\ then"# + "\tstop\r\n"
        let json = ClaudeCodeCLIRuntime.mcpToolResultJSON(requestID: "tool_1", result: result)

        XCTAssertEqual(fifoLines(json).count, 1)
        XCTAssertEqual(decodeObject(String(json.dropLast()))["result"] as? String, result)
    }

    func testResultPreservesUnicode() {
        let result = "héllo 🎉 — done"
        let json = ClaudeCodeCLIRuntime.mcpToolResultJSON(requestID: "tool_1", result: result)

        XCTAssertEqual(decodeObject(String(json.dropLast()))["result"] as? String, result)
    }

    func testRequestIDIsEscapedInTheResultLine() {
        let requestID = "tool_\"1\"\n\\weird"
        let json = ClaudeCodeCLIRuntime.mcpToolResultJSON(requestID: requestID, result: "ok")

        XCTAssertEqual(fifoLines(json).count, 1, "the embedded newline must be escaped")
        XCTAssertEqual(decodeObject(String(json.dropLast()))["request_id"] as? String, requestID)
    }

    // MARK: - Full round-trip

    /// The whole bridge contract in one test: the node script writes a call,
    /// Kiteloop decodes it, runs the tool, and writes a result the script can
    /// match back to the same pending promise by `request_id`.
    func testToolCallRoundTripsThroughBothPipes() throws {
        let requestID = "tool_7_1700000000"
        let requestLine = bridgeRequestLine(
            requestID: requestID,
            toolName: "recall_knowledge",
            input: ["query": "deploy runbook", "limit": 5]
        )

        let payload = try XCTUnwrap(ClaudeCodeCLIRuntime.parseToolRequestLine(String(requestLine.dropLast())))
        XCTAssertEqual(payload.toolName, "recall_knowledge")
        XCTAssertEqual(decodeObject(payload.input)["query"] as? String, "deploy runbook")
        XCTAssertEqual(decodeObject(payload.input)["limit"] as? Int, 5)

        let result = "Found 2 notes:\n- runbook.md\n- rollback.md"
        let responseLine = ClaudeCodeCLIRuntime.mcpToolResultJSON(requestID: payload.requestID, result: result)
        let response = decodeObject(String(responseLine.dropLast()))

        XCTAssertEqual(response["request_id"] as? String, requestID, "the bridge matches the pending call by request_id")
        XCTAssertEqual(response["result"] as? String, result)
    }

    /// Several calls can be in flight at once; each pipe stream must split into
    /// one line per call and the results must stay keyed to the right request.
    func testConcurrentCallsKeepTheirOwnRequestIDs() throws {
        let calls = [
            ("tool_1_1700000000", "publish_event", "published"),
            ("tool_2_1700000001", "message_agent", "delivered\nto Reviewer"),
            ("tool_3_1700000002", "ask_human", "")
        ]

        let requestStream = calls.map {
            bridgeRequestLine(requestID: $0.0, toolName: $0.1, input: ["n": $0.0])
        }.joined()
        let requestLines = fifoLines(requestStream)
        XCTAssertEqual(requestLines.count, calls.count)

        let payloads = requestLines.compactMap(ClaudeCodeCLIRuntime.parseToolRequestLine)
        XCTAssertEqual(payloads.map(\.requestID), calls.map { $0.0 })
        XCTAssertEqual(payloads.map(\.toolName), calls.map { $0.1 })

        // Results come back out of order, as they would when tools finish at
        // different times — the bridge relies on request_id, not on ordering.
        let responseStream = zip(payloads, calls).reversed().map {
            ClaudeCodeCLIRuntime.mcpToolResultJSON(requestID: $0.0.requestID, result: $0.1.2)
        }.joined()
        let responses = fifoLines(responseStream).map { decodeObject($0) }
        XCTAssertEqual(responses.count, calls.count)

        for (index, call) in calls.enumerated() {
            let response = try XCTUnwrap(responses.first { $0["request_id"] as? String == call.0 })
            XCTAssertEqual(response["result"] as? String, call.2, "result \(index) reached the wrong call")
        }
    }
}
