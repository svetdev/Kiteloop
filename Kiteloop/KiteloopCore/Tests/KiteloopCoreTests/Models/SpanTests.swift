import XCTest
@testable import KiteloopCore

final class SpanTests: XCTestCase {
    func testSpanIdentifiableUsesSpanID() {
        let span = Span(
            traceID: OTelIDs.newTraceID(),
            spanID: "abcdef0123456789",
            parentSpanID: nil,
            name: "test-session",
            spanType: .session,
            agentID: nil,
            startTime: Date(),
            endTime: nil,
            status: .unset,
            attributes: [:],
            events: [],
            links: []
        )
        XCTAssertEqual(span.id, "abcdef0123456789")
    }

    func testSpanCodableRoundTrip() throws {
        let now = Date()
        let span = Span(
            traceID: OTelIDs.newTraceID(),
            spanID: OTelIDs.newSpanID(),
            parentSpanID: OTelIDs.newSpanID(),
            name: "tool-call",
            spanType: .toolCall,
            agentID: "agent-1",
            startTime: now,
            endTime: now.addingTimeInterval(1.5),
            status: .ok,
            attributes: [
                "kiteloop.session_id": .string("sess-123"),
                "tool.name": .string("Bash"),
                "tool.duration_ms": .int(150),
                "tool.success": .bool(true)
            ],
            events: [
                SpanEvent(
                    name: "policy_decision",
                    timestamp: now,
                    attributes: [
                        "tool": .string("Bash"),
                        "decision": .string("permitted")
                    ]
                )
            ],
            links: [
                SpanLink(
                    traceID: OTelIDs.newTraceID(),
                    spanID: OTelIDs.newSpanID(),
                    attributes: ["relationship": .string("caused_by")]
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(span)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Span.self, from: data)

        XCTAssertEqual(decoded.traceID, span.traceID)
        XCTAssertEqual(decoded.spanID, span.spanID)
        XCTAssertEqual(decoded.parentSpanID, span.parentSpanID)
        XCTAssertEqual(decoded.name, "tool-call")
        XCTAssertEqual(decoded.spanType, .toolCall)
        XCTAssertEqual(decoded.agentID, "agent-1")
        XCTAssertEqual(decoded.status, .ok)
        XCTAssertEqual(decoded.attributes.count, 4)
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.events[0].name, "policy_decision")
        XCTAssertEqual(decoded.links.count, 1)
    }

    func testAttributeValueAllTypes() throws {
        let values: [String: AttributeValue] = [
            "s": .string("hello"),
            "i": .int(42),
            "d": .double(3.14),
            "b": .bool(true)
        ]
        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([String: AttributeValue].self, from: data)
        if case .string(let v) = decoded["s"] { XCTAssertEqual(v, "hello") } else { XCTFail() }
        if case .int(let v) = decoded["i"] { XCTAssertEqual(v, 42) } else { XCTFail() }
        if case .double(let v) = decoded["d"] { XCTAssertEqual(v, 3.14, accuracy: 0.001) } else { XCTFail() }
        if case .bool(let v) = decoded["b"] { XCTAssertTrue(v) } else { XCTFail() }
    }

    func testKiteloopSpanTypeAllCases() {
        let cases: [KiteloopSpanType] = [.workflowExecution, .nodeExecution, .session, .turn, .toolCall]
        XCTAssertEqual(cases.count, 5)
        for type in cases {
            XCTAssertFalse(type.rawValue.isEmpty)
        }
    }

    func testSpanStatusValues() throws {
        for status in [SpanStatus.unset, .ok, .error] {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(SpanStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }
}
