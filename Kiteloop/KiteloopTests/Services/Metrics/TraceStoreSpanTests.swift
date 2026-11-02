import XCTest
import KiteloopCore
@testable import Kiteloop

final class TraceStoreSpanTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "trace-store-span")
    }

    func testLoadSpansFromJSONL() async throws {
        let traceID = OTelIDs.newTraceID()
        let rootSpan = Span(
            traceID: traceID,
            spanID: OTelIDs.newSpanID(),
            parentSpanID: nil,
            name: "session",
            spanType: .session,
            agentID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(10),
            status: .ok,
            attributes: ["kiteloop.session_id": .string("sess-1")],
            events: [],
            links: []
        )
        let childSpan = Span(
            traceID: traceID,
            spanID: OTelIDs.newSpanID(),
            parentSpanID: rootSpan.spanID,
            name: "turn-1",
            spanType: .turn,
            agentID: "agent-1",
            startTime: Date(),
            endTime: Date().addingTimeInterval(3),
            status: .ok,
            attributes: ["kiteloop.agent_id": .string("agent-1")],
            events: [],
            links: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let line1 = String(data: try encoder.encode(rootSpan), encoding: .utf8)!
        let line2 = String(data: try encoder.encode(childSpan), encoding: .utf8)!
        let content = line1 + "\n" + line2 + "\n"
        let fileURL = tempDir.appending(path: "2026-05-26-120000.jsonl")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = TraceStore(tracesURL: tempDir)
        let spans = await store.loadOTelSpans()
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].traceID, traceID)
        XCTAssertEqual(spans[1].parentSpanID, rootSpan.spanID)
    }

    func testLoadSpansForAgent() async throws {
        let span1 = Span(
            traceID: OTelIDs.newTraceID(),
            spanID: OTelIDs.newSpanID(),
            parentSpanID: nil,
            name: "turn",
            spanType: .turn,
            agentID: "agent-A",
            startTime: Date(),
            endTime: nil,
            status: .unset,
            attributes: [:],
            events: [],
            links: []
        )
        let span2 = Span(
            traceID: OTelIDs.newTraceID(),
            spanID: OTelIDs.newSpanID(),
            parentSpanID: nil,
            name: "turn",
            spanType: .turn,
            agentID: "agent-B",
            startTime: Date(),
            endTime: nil,
            status: .unset,
            attributes: [:],
            events: [],
            links: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let content = [span1, span2].map { try! String(data: encoder.encode($0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        let fileURL = tempDir.appending(path: "2026-05-26-130000.jsonl")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = TraceStore(tracesURL: tempDir)
        let agentASpans = await store.loadOTelSpans(for: "agent-A")
        XCTAssertEqual(agentASpans.count, 1)
        XCTAssertEqual(agentASpans[0].agentID, "agent-A")
    }
}
