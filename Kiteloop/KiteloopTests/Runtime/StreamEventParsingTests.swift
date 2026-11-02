import XCTest
@testable import Kiteloop

final class StreamEventParsingTests: XCTestCase {

    // MARK: - Helpers

    /// Re-decodes a `toolUse` input blob so assertions can look at values
    /// instead of the pretty-printed/sorted formatting.
    private func decodeObject(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected \(json) to decode as a JSON object", file: file, line: line)
            return [:]
        }
        return object
    }

    // MARK: - system

    func testParseSystemInitEvent() throws {
        let json = #"{"type":"system","subtype":"init","tools":["Bash","Read","Edit"]}"#
        let event = try StreamEvent.parse(json)
        guard case .system(let subtype, _) = event else {
            XCTFail("Expected system event"); return
        }
        XCTAssertEqual(subtype, "init")
    }

    func testParseSystemHookEvent() throws {
        let json = #"{"type":"system","subtype":"hook_started"}"#
        let event = try StreamEvent.parse(json)
        guard case .system(let subtype, _) = event else {
            XCTFail("Expected system event"); return
        }
        XCTAssertEqual(subtype, "hook_started")
    }

    func testSystemEventCarriesWholeLineAsPayload() throws {
        let json = #"{"type":"system","subtype":"init","session_id":"s-1","tools":["Bash","Read"]}"#
        let event = try StreamEvent.parse(json)
        guard case .system(_, let payload) = event else {
            XCTFail("Expected system event"); return
        }
        XCTAssertEqual(payload["type"] as? String, "system")
        XCTAssertEqual(payload["session_id"] as? String, "s-1")
        XCTAssertEqual(payload["tools"] as? [String], ["Bash", "Read"])
    }

    func testSystemEventWithoutSubtypeUsesEmptyString() throws {
        let event = try StreamEvent.parse(#"{"type":"system"}"#)
        guard case .system(let subtype, _) = event else {
            XCTFail("Expected system event"); return
        }
        XCTAssertEqual(subtype, "")
    }

    // MARK: - assistant

    func testParseAssistantTextEvent() throws {
        let json = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .assistantText(let text, _) = event else {
            XCTFail("Expected assistant text"); return
        }
        XCTAssertEqual(text, "Hello")
    }

    func testParseAssistantTextPreservesUnicodeAndEscapes() throws {
        let json = #"{"type":"assistant","message":{"content":[{"type":"text","text":"line1\nline2 \"quoted\" — ✅"}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .assistantText(let text, _) = event else {
            XCTFail("Expected assistant text"); return
        }
        XCTAssertEqual(text, "line1\nline2 \"quoted\" — ✅")
    }

    func testParseAssistantThinkingEvent() throws {
        let json = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"weighing options"}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .thinking(let text, _) = event else {
            XCTFail("Expected thinking event"); return
        }
        XCTAssertEqual(text, "weighing options")
    }

    func testParseAssistantImageEvent() throws {
        let json = #"{"type":"assistant","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJD"}}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .image(let base64Data, let mimeType) = event else {
            XCTFail("Expected image event"); return
        }
        XCTAssertEqual(base64Data, "QUJD")
        XCTAssertEqual(mimeType, "image/png")
    }

    /// A single line can hold several content blocks; parsing collapses it to
    /// the first block it recognises.
    func testAssistantWithThinkingAndTextYieldsFirstBlock() throws {
        let json = #"""
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Hello"}]}}
        """#
        let event = try StreamEvent.parse(json)
        guard case .thinking(let text, _) = event else {
            XCTFail("Expected the leading thinking block"); return
        }
        XCTAssertEqual(text, "hmm")
    }

    func testAssistantSkipsUnrecognizedBlocksBeforeText() throws {
        let json = #"{"type":"assistant","message":{"content":[{"type":"redacted_thinking","data":"xx"},{"type":"text","text":"Hello"}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .assistantText(let text, _) = event else {
            XCTFail("Expected assistant text"); return
        }
        XCTAssertEqual(text, "Hello")
    }

    func testAssistantWithNoRecognizedBlocksIsUnknown() throws {
        let json = #"{"type":"assistant","message":{"content":[{"type":"redacted_thinking","data":"xx"}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .unknown(let type) = event else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertEqual(type, "assistant")
    }

    func testAssistantWithEmptyContentIsUnknown() throws {
        let event = try StreamEvent.parse(#"{"type":"assistant","message":{"content":[]}}"#)
        guard case .unknown(let type) = event else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertEqual(type, "assistant")
    }

    func testAssistantWithoutMessageIsUnknown() throws {
        let event = try StreamEvent.parse(#"{"type":"assistant"}"#)
        guard case .unknown(let type) = event else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertEqual(type, "assistant")
    }

    // MARK: - tool_use

    func testParseToolUseEvent() throws {
        let json = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/test.txt"}}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .toolUse(let id, let name, let input, _) = event else {
            XCTFail("Expected tool use"); return
        }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(name, "Read")
        XCTAssertTrue(input.contains("test.txt"))
    }

    func testToolUseInputIsSerializedJSONObject() throws {
        let json = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls -la","timeout":5000,"nested":{"a":true}}}]}}
        """#
        let event = try StreamEvent.parse(json)
        guard case .toolUse(_, let name, let input, _) = event else {
            XCTFail("Expected tool use"); return
        }
        XCTAssertEqual(name, "Bash")

        let decoded = decodeObject(input)
        XCTAssertEqual(decoded["command"] as? String, "ls -la")
        XCTAssertEqual(decoded["timeout"] as? Int, 5000)
        XCTAssertEqual((decoded["nested"] as? [String: Any])?["a"] as? Bool, true)
    }

    /// Keys are sorted so the same tool call always renders identically.
    func testToolUseInputKeysAreSorted() throws {
        let json = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Edit","input":{"z":"1","a":"2","m":"3"}}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .toolUse(_, _, let input, _) = event else {
            XCTFail("Expected tool use"); return
        }
        let aIdx = try XCTUnwrap(input.range(of: "\"a\"")).lowerBound
        let mIdx = try XCTUnwrap(input.range(of: "\"m\"")).lowerBound
        let zIdx = try XCTUnwrap(input.range(of: "\"z\"")).lowerBound
        XCTAssertTrue(aIdx < mIdx && mIdx < zIdx, "Expected sorted keys, got: \(input)")
    }

    func testToolUseWithoutInputYieldsEmptyObject() throws {
        let json = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"Glob"}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .toolUse(let id, let name, let input, _) = event else {
            XCTFail("Expected tool use"); return
        }
        XCTAssertEqual(id, "t4")
        XCTAssertEqual(name, "Glob")
        XCTAssertTrue(decodeObject(input).isEmpty)
    }

    func testToolUseWithMissingIDAndNameUsesEmptyStrings() throws {
        let json = #"{"type":"assistant","message":{"content":[{"type":"tool_use","input":{}}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .toolUse(let id, let name, _, _) = event else {
            XCTFail("Expected tool use"); return
        }
        XCTAssertEqual(id, "")
        XCTAssertEqual(name, "")
    }

    func testParseMCPToolUseKeepsFullyQualifiedName() throws {
        let json = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t5","name":"mcp__kiteloop-tools__message_agent","input":{"to":"Reviewer","message":"ping"}}]}}
        """#
        let event = try StreamEvent.parse(json)
        guard case .toolUse(_, let name, let input, _) = event else {
            XCTFail("Expected tool use"); return
        }
        XCTAssertEqual(name, "mcp__kiteloop-tools__message_agent")
        XCTAssertEqual(decodeObject(input)["to"] as? String, "Reviewer")
    }

    // MARK: - tool_result (user)

    func testParseToolResultWithStringContent() throws {
        let json = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"file contents"}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .toolResult(let id, let output, _) = event else {
            XCTFail("Expected tool result"); return
        }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(output, "file contents")
    }

    func testParseToolResultWithBlockArrayContentJoinsText() throws {
        let json = #"""
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}]}}
        """#
        let event = try StreamEvent.parse(json)
        guard case .toolResult(let id, let output, _) = event else {
            XCTFail("Expected tool result"); return
        }
        XCTAssertEqual(id, "t2")
        XCTAssertEqual(output, "first\nsecond")
    }

    func testParseToolResultWithUnsupportedContentYieldsEmptyOutput() throws {
        let json = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":42}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .toolResult(let id, let output, _) = event else {
            XCTFail("Expected tool result"); return
        }
        XCTAssertEqual(id, "t3")
        XCTAssertEqual(output, "")
    }

    func testPlainUserMessageIsUnknown() throws {
        let json = #"{"type":"user","message":{"content":[{"type":"text","text":"hi"}]}}"#
        let event = try StreamEvent.parse(json)
        guard case .unknown(let type) = event else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertEqual(type, "user")
    }

    // MARK: - result

    func testParseResultEvent() throws {
        let json = #"{"type":"result","subtype":"success","result":"Done.","total_cost_usd":0.003,"duration_ms":1200}"#
        let event = try StreamEvent.parse(json)
        guard case .result(let payload) = event else {
            XCTFail("Expected result"); return
        }
        XCTAssertEqual(payload.text, "Done.")
        XCTAssertEqual(payload.costUSD, 0.003)
        XCTAssertEqual(payload.durationMs, 1200)
    }

    func testResultParsesUsageAndSessionID() throws {
        let json = #"""
        {"type":"result","subtype":"success","result":"Done.","session_id":"sess-42","total_cost_usd":0.1234,"duration_ms":2500,
         "usage":{"input_tokens":120,"output_tokens":45,"cache_creation_input_tokens":900,"cache_read_input_tokens":1800}}
        """#
        let event = try StreamEvent.parse(json)
        guard case .result(let payload) = event else {
            XCTFail("Expected result"); return
        }
        XCTAssertEqual(payload.sessionID, "sess-42")
        XCTAssertEqual(payload.costUSD, 0.1234, accuracy: 1e-9)
        XCTAssertEqual(payload.durationMs, 2500)
        XCTAssertEqual(payload.inputTokens, 120)
        XCTAssertEqual(payload.outputTokens, 45)
        XCTAssertEqual(payload.cacheCreationInputTokens, 900)
        XCTAssertEqual(payload.cacheReadInputTokens, 1800)
    }

    func testResultWithoutUsageDefaultsTokenCountsToZero() throws {
        let event = try StreamEvent.parse(#"{"type":"result","subtype":"success","result":"Done."}"#)
        guard case .result(let payload) = event else {
            XCTFail("Expected result"); return
        }
        XCTAssertEqual(payload.costUSD, 0)
        XCTAssertEqual(payload.durationMs, 0)
        XCTAssertEqual(payload.inputTokens, 0)
        XCTAssertEqual(payload.outputTokens, 0)
        XCTAssertEqual(payload.cacheCreationInputTokens, 0)
        XCTAssertEqual(payload.cacheReadInputTokens, 0)
        XCTAssertEqual(payload.sessionID, "")
        XCTAssertTrue(payload.permissionDenials.isEmpty)
    }

    /// The CLI has emitted `duration_ms` as a float; truncating beats dropping it.
    func testResultAcceptsFractionalDuration() throws {
        let event = try StreamEvent.parse(#"{"type":"result","result":"ok","duration_ms":1200.7}"#)
        guard case .result(let payload) = event else {
            XCTFail("Expected result"); return
        }
        XCTAssertEqual(payload.durationMs, 1200)
    }

    func testResultParsesPermissionDenials() throws {
        let json = #"""
        {"type":"result","subtype":"success","result":"Blocked.","permission_denials":[
          {"tool_name":"Bash","tool_input":{"command":"rm -rf /"}},
          {"tool_name":"Write","tool_input":{"file_path":"/etc/hosts"}},
          {"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}
        ]}
        """#
        let event = try StreamEvent.parse(json)
        guard case .result(let payload) = event else {
            XCTFail("Expected result"); return
        }
        XCTAssertEqual(payload.permissionDenials.count, 3)
        XCTAssertEqual(payload.permissionDenials[0].toolName, "Bash")
        XCTAssertEqual(payload.permissionDenials[0].detail, "rm -rf /")
        XCTAssertEqual(payload.permissionDenials[1].toolName, "Write")
        XCTAssertEqual(payload.permissionDenials[1].detail, "/etc/hosts")
        // No command/file_path to summarise — the tool name is all we surface.
        XCTAssertEqual(payload.permissionDenials[2].toolName, "WebFetch")
        XCTAssertEqual(payload.permissionDenials[2].detail, "")
    }

    func testParseErrorResultEvent() throws {
        let json = #"{"type":"result","subtype":"error_max_turns","result":"Reached max turns","total_cost_usd":0.5,"duration_ms":9000}"#
        let event = try StreamEvent.parse(json)
        guard case .result(let payload) = event else {
            XCTFail("Expected result"); return
        }
        XCTAssertEqual(payload.text, "Reached max turns")
        XCTAssertEqual(payload.costUSD, 0.5)
    }

    /// A leg the session's own `--max-turns` ended says so, with its count — the
    /// one thing that tells a worker which ran out of turns from one which finished.
    func testResultCarriesTheMaxTurnsSubtypeAndTurnCount() throws {
        let json = #"{"type":"result","subtype":"error_max_turns","num_turns":50,"result":"","duration_ms":9000}"#
        guard case .result(let payload) = try StreamEvent.parse(json) else {
            XCTFail("Expected result"); return
        }
        XCTAssertEqual(payload.subtype, "error_max_turns")
        XCTAssertEqual(payload.numTurns, 50)
        XCTAssertTrue(payload.endedOnTurnCap)
    }

    func testAFinishedResultIsNotReadAsCutShort() throws {
        let finished = try StreamEvent.parse(#"{"type":"result","subtype":"success","num_turns":12,"result":"ok"}"#)
        guard case .result(let payload) = finished else {
            XCTFail("Expected result"); return
        }
        XCTAssertEqual(payload.numTurns, 12)
        XCTAssertFalse(payload.endedOnTurnCap)

        guard case .result(let bare) = try StreamEvent.parse(#"{"type":"result","result":"ok"}"#) else {
            XCTFail("Expected result"); return
        }
        XCTAssertNil(bare.subtype)
        XCTAssertNil(bare.numTurns)
        XCTAssertFalse(bare.endedOnTurnCap)
    }

    // MARK: - hook / permission_request

    func testParseHookEvent() throws {
        let json = #"""
        {"type":"hook","hook_type":"PreToolUse","hook_name":"guard","tool_name":"Bash","output":"blocked","exit_code":2}
        """#
        let event = try StreamEvent.parse(json)
        guard case .hook(let payload) = event else {
            XCTFail("Expected hook event"); return
        }
        XCTAssertEqual(payload.hookType, "PreToolUse")
        XCTAssertEqual(payload.hookName, "guard")
        XCTAssertEqual(payload.toolName, "Bash")
        XCTAssertEqual(payload.output, "blocked")
        XCTAssertEqual(payload.exitCode, 2)
    }

    func testParseHookEventDefaultsMissingFields() throws {
        let event = try StreamEvent.parse(#"{"type":"hook"}"#)
        guard case .hook(let payload) = event else {
            XCTFail("Expected hook event"); return
        }
        XCTAssertEqual(payload.hookType, "")
        XCTAssertEqual(payload.hookName, "")
        XCTAssertEqual(payload.toolName, "")
        XCTAssertEqual(payload.output, "")
        XCTAssertEqual(payload.exitCode, 0)
    }

    /// Nothing routes a permission prompt to Kiteloop any more, so a line that
    /// claims to be one is just another line the app does not know.
    func testPermissionRequestLineIsNoLongerAnEvent() throws {
        let json = #"""
        {"type":"permission_request","request_id":"perm_1","tool_name":"Bash","tool_use_id":"tu_1",
         "description":"Run a shell command","input":{"command":"git status"}}
        """#
        guard case .unknown(let type) = try StreamEvent.parse(json) else {
            XCTFail("Expected an unknown event"); return
        }
        XCTAssertEqual(type, "permission_request")
    }

    // MARK: - unknown / malformed lines

    func testParseUnknownEventReturnsUnknown() throws {
        let json = #"{"type":"something_new","data":"whatever"}"#
        let event = try StreamEvent.parse(json)
        guard case .unknown(let type) = event else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertEqual(type, "something_new")
    }

    /// Unparseable text surfaces JSONSerialization's own error — `.invalidJSON`
    /// is reserved for valid JSON that isn't an object.
    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try StreamEvent.parse("not json at all")) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
    }

    func testTruncatedJSONLineThrows() {
        XCTAssertThrowsError(try StreamEvent.parse(#"{"type":"assistant","message":{"conte"#))
    }

    func testNonObjectJSONThrowsInvalidJSON() {
        XCTAssertThrowsError(try StreamEvent.parse("[1,2,3]")) { error in
            XCTAssertEqual(error as? StreamEventError, .invalidJSON)
        }
    }

    func testEmptyLineThrows() {
        XCTAssertThrowsError(try StreamEvent.parse(""))
    }

    func testMissingTypeThrows() {
        XCTAssertThrowsError(try StreamEvent.parse(#"{"message":{"content":[]}}"#)) { error in
            XCTAssertEqual(error as? StreamEventError, .missingType)
        }
    }

    func testNonStringTypeThrowsMissingType() {
        XCTAssertThrowsError(try StreamEvent.parse(#"{"type":7}"#)) { error in
            XCTAssertEqual(error as? StreamEventError, .missingType)
        }
    }

    // MARK: - whole-stream sequence

    /// A realistic turn: init → thinking → tool_use → tool_result → text → result.
    func testParsesRepresentativeTurnLineByLine() throws {
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s-9","tools":["Bash","Read"]}"#,
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"check the file"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Read","input":{"file_path":"/tmp/a.txt"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"hello"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"The file says hello."}]}}"#,
            #"{"type":"result","subtype":"success","result":"The file says hello.","session_id":"s-9","total_cost_usd":0.01,"duration_ms":800,"usage":{"input_tokens":10,"output_tokens":5}}"#
        ]

        let events = try lines.map { try StreamEvent.parse($0) }
        XCTAssertEqual(events.count, 6)

        guard case .system(let subtype, _) = events[0] else { XCTFail("0: expected system"); return }
        XCTAssertEqual(subtype, "init")

        guard case .thinking = events[1] else { XCTFail("1: expected thinking"); return }

        guard case .toolUse(let id, let name, _, _) = events[2] else { XCTFail("2: expected tool use"); return }
        XCTAssertEqual(id, "tu_1")
        XCTAssertEqual(name, "Read")

        guard case .toolResult(let resultID, let output, _) = events[3] else { XCTFail("3: expected tool result"); return }
        XCTAssertEqual(resultID, "tu_1")
        XCTAssertEqual(output, "hello")

        guard case .assistantText(let text, _) = events[4] else { XCTFail("4: expected assistant text"); return }
        XCTAssertEqual(text, "The file says hello.")

        guard case .result(let payload) = events[5] else { XCTFail("5: expected result"); return }
        XCTAssertEqual(payload.sessionID, "s-9")
        XCTAssertEqual(payload.inputTokens, 10)
        XCTAssertEqual(payload.outputTokens, 5)
    }
}
