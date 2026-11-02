import XCTest
@testable import KiteloopCore

/// `KiteloopEvent` is a persistence *and* wire format: `EventBus` appends one JSON
/// object per line to `events.jsonl` and reloads it on the next launch, the control
/// server streams the same shape to headless clients, and `EventType` raw values show
/// up as plain strings in agent `subscriptions`, template configs and `publish_event`
/// tool calls. These tests pin the round-trip guarantees and the raw-value contract
/// that older event logs and existing configs depend on.
final class KiteloopEventCodableTests: XCTestCase {

    // MARK: - Helpers

    /// Mirrors `EventBus`'s coder configuration — the one that actually touches disk.
    private func busEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func busDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func roundTrip(
        _ event: KiteloopEvent,
        encoder: JSONEncoder,
        decoder: JSONDecoder
    ) throws -> KiteloopEvent {
        try decoder.decode(KiteloopEvent.self, from: encoder.encode(event))
    }

    // MARK: - Round-trip

    func testRoundTripPreservesAllFields() throws {
        var event = KiteloopEvent(
            source: "coder",
            type: .prReady,
            payload: ["branch": "feature/auth", "url": "https://example.com/pr/1"]
        )
        event.deliveredTo = ["reviewer", "manager"]

        let decoded = try roundTrip(event, encoder: busEncoder(), decoder: busDecoder())

        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.source, "coder")
        XCTAssertEqual(decoded.type, .prReady)
        XCTAssertEqual(decoded.payload, event.payload)
        XCTAssertEqual(decoded.deliveredTo, ["reviewer", "manager"])
    }

    func testRoundTripPreservesEmptyPayloadAndDeliveredTo() throws {
        let event = KiteloopEvent(source: "sentinel", type: .custom)

        let decoded = try roundTrip(event, encoder: busEncoder(), decoder: busDecoder())

        XCTAssertEqual(decoded.payload, [:])
        XCTAssertEqual(decoded.deliveredTo, [])
    }

    func testRoundTripPreservesTimestampToTheSecondUnderISO8601() throws {
        // `.iso8601` drops fractional seconds, so replay ordering is only second-accurate.
        let event = KiteloopEvent(source: "coder", type: .taskComplete)

        let decoded = try roundTrip(event, encoder: busEncoder(), decoder: busDecoder())

        XCTAssertLessThan(abs(decoded.timestamp.timeIntervalSince(event.timestamp)), 1.0)
    }

    func testRoundTripPreservesSubSecondTimestampUnderDefaultStrategy() throws {
        // Callers that keep the default (`.deferredToDate`) coders get full precision back.
        let event = KiteloopEvent(source: "coder", type: .taskComplete)

        let decoded = try roundTrip(event, encoder: JSONEncoder(), decoder: JSONDecoder())

        XCTAssertEqual(
            decoded.timestamp.timeIntervalSinceReferenceDate,
            event.timestamp.timeIntervalSinceReferenceDate,
            accuracy: 0.000_001
        )
    }

    func testRoundTripPreservesUnicodeAndPunctuationInPayload() throws {
        let payload = [
            "summary": "café ☕️ — done",
            "quote": #"he said "ship it" \ now"#,
            "": "empty key"
        ]
        let event = KiteloopEvent(source: "researcher", type: .researchComplete, payload: payload)

        let decoded = try roundTrip(event, encoder: busEncoder(), decoder: busDecoder())

        XCTAssertEqual(decoded.payload, payload)
    }

    func testRoundTripIsStableAcrossRepeatedEncodes() throws {
        var event = KiteloopEvent(source: "coder", type: .reviewComplete, payload: ["verdict": "approve"])
        event.deliveredTo = ["manager"]

        let once = try roundTrip(event, encoder: busEncoder(), decoder: busDecoder())
        let twice = try roundTrip(once, encoder: busEncoder(), decoder: busDecoder())

        XCTAssertEqual(twice.id, once.id)
        XCTAssertEqual(twice.timestamp, once.timestamp)
        XCTAssertEqual(twice.payload, once.payload)
        XCTAssertEqual(twice.deliveredTo, once.deliveredTo)
    }

    func testDeliveredToDeduplicatesOnDecode() throws {
        let json = """
        {"id":"e1","timestamp":"2026-08-04T12:00:00Z","source":"coder","type":"pr_ready",\
        "payload":{},"deliveredTo":["reviewer","reviewer","manager"]}
        """

        let decoded = try busDecoder().decode(KiteloopEvent.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.deliveredTo, ["reviewer", "manager"])
    }

    // MARK: - On-disk JSONL format

    func testEncodedEventUsesExpectedKeys() throws {
        let event = KiteloopEvent(source: "coder", type: .prReady, payload: ["branch": "main"])

        let data = try busEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            ["id", "timestamp", "source", "type", "payload", "deliveredTo"]
        )
        XCTAssertEqual(object["type"] as? String, "pr_ready")
        XCTAssertEqual(object["source"] as? String, "coder")
        XCTAssertEqual(object["payload"] as? [String: String], ["branch": "main"])
    }

    func testEncodedEventFitsOnOneJSONLLine() throws {
        // `EventBus.persistEvent` appends "\n" and `loadEvents` splits on newlines, so a
        // literal newline anywhere in the encoded event would corrupt the log.
        let event = KiteloopEvent(
            source: "coder",
            type: .error,
            payload: ["stderr": "line one\nline two\r\nline three"]
        )

        let data = try busEncoder().encode(event)
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))

        let decoded = try busDecoder().decode(KiteloopEvent.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.payload["stderr"], "line one\nline two\r\nline three")
    }

    func testDecodesHandWrittenLogLine() throws {
        // A line as it appears in an existing `.kiteloop/events.jsonl`.
        let json = """
        {"id":"9C7F4E1A-0000-0000-0000-000000000001","timestamp":"2026-08-04T12:34:56Z",\
        "source":"example-coder","type":"task_complete","payload":{"task":"build"},\
        "deliveredTo":["example-reviewer"]}
        """

        let decoded = try busDecoder().decode(KiteloopEvent.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, "9C7F4E1A-0000-0000-0000-000000000001")
        XCTAssertEqual(decoded.source, "example-coder")
        XCTAssertEqual(decoded.type, .taskComplete)
        XCTAssertEqual(decoded.payload["task"], "build")
        XCTAssertEqual(decoded.deliveredTo, ["example-reviewer"])
        XCTAssertEqual(
            decoded.timestamp,
            Date(timeIntervalSince1970: 1_785_846_896) // 2026-08-04T12:34:56Z
        )
    }

    func testDecodeRejectsUnknownEventType() {
        // Nothing coerces here — `ToolInterceptor` maps unknown strings to `.custom`
        // *before* constructing the event precisely because decoding would fail.
        let json = """
        {"id":"e1","timestamp":"2026-08-04T12:00:00Z","source":"coder","type":"not_a_real_type",\
        "payload":{},"deliveredTo":[]}
        """

        XCTAssertThrowsError(try busDecoder().decode(KiteloopEvent.self, from: Data(json.utf8)))
    }

    func testDecodeRejectsMissingRequiredField() {
        let json = """
        {"id":"e1","timestamp":"2026-08-04T12:00:00Z","type":"pr_ready","payload":{},"deliveredTo":[]}
        """

        XCTAssertThrowsError(try busDecoder().decode(KiteloopEvent.self, from: Data(json.utf8)))
    }

    // MARK: - EventType.allCases

    func testEveryCaseRoundTripsThroughCodable() throws {
        let encoder = busEncoder()
        let decoder = busDecoder()

        for type in KiteloopEvent.EventType.allCases {
            let event = KiteloopEvent(source: "coder", type: type, payload: ["k": "v"])
            let decoded = try roundTrip(event, encoder: encoder, decoder: decoder)
            XCTAssertEqual(decoded.type, type, "\(type.rawValue) did not survive a round-trip")
        }
    }

    func testEveryCaseRoundTripsThroughRawValue() {
        // `SubscriptionEngine`, `ChatViewModel` and `ToolInterceptor` all rebuild the enum
        // from a config/tool-supplied string.
        for type in KiteloopEvent.EventType.allCases {
            XCTAssertEqual(
                KiteloopEvent.EventType(rawValue: type.rawValue),
                type,
                "\(type.rawValue) is not recoverable from its raw value"
            )
        }
    }

    func testRawValuesAreUnique() {
        let rawValues = KiteloopEvent.EventType.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count, "duplicate raw values collapse event kinds")
    }

    func testKnownRawValuesAreStable() {
        // Renaming or dropping any of these silently breaks existing `events.jsonl` files
        // and every `subscriptions: [...]` entry in team/template configs. New cases may be
        // added freely; these must keep decoding.
        let pinned: Set<String> = [
            "pr_ready",
            "review_complete",
            "task_complete",
            "memory_proposed",
            "error",
            "custom",
            "research_complete",
            "data_complete",
            "prd_complete",
            "wireframe_complete",
            "engineering_complete",
            "test_complete",
            "ops_complete",
            "workflow_started",
            "workflow_transitioned",
            "workflow_completed",
            "workflow_failed",
            "workflow_cancelled",
            "workflow_approval_required",
            "workflow_approval_resolved",
            "workflow_resume_offered",
            "workflow_resumed",
            "knowledge_recalled",
            "agent_card_generated",
            "agent_discovered",
            "template_reloaded"
        ]
        let actual = Set(KiteloopEvent.EventType.allCases.map(\.rawValue))

        XCTAssertTrue(
            pinned.isSubset(of: actual),
            "removed or renamed event types: \(pinned.subtracting(actual).sorted())"
        )
    }

    func testRawValuesAreLowerSnakeCase() {
        // Config files and the `publish_event` tool schema advertise this shape.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz_")
        for type in KiteloopEvent.EventType.allCases {
            XCTAssertTrue(
                type.rawValue.unicodeScalars.allSatisfy(allowed.contains),
                "\(type.rawValue) is not lower_snake_case"
            )
        }
    }

    func testWorkflowPrefixMatchesExactlyTheWorkflowCases() {
        // `WorkflowEventBridge.startInboundBridge` subscribes to everything *except*
        // `workflow_`-prefixed types to avoid feeding its own output back in.
        let prefixed = Set(
            KiteloopEvent.EventType.allCases
                .filter { $0.rawValue.hasPrefix("workflow_") }
        )
        let expected: Set<KiteloopEvent.EventType> = [
            .workflowStarted,
            .workflowTransitioned,
            .workflowCompleted,
            .workflowFailed,
            .workflowCancelled,
            .workflowApprovalRequired,
            .workflowApprovalResolved,
            .workflowResumeOffered,
            .workflowResumed
        ]

        XCTAssertEqual(prefixed, expected)
    }
}
