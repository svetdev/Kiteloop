import XCTest
@testable import Kiteloop

/// The context window a `result` line measured, read from `modelUsage` — the
/// only place a current CLI reports it; its `init` frame carries no size.
final class StreamEventContextWindowTests: XCTestCase {
    private func result(modelUsage: String) throws -> StreamEvent.ResultPayload {
        let json = """
        {"type":"result","result":"ok","total_cost_usd":0.01,"duration_ms":500,"usage":{},"session_id":"s1","modelUsage":\(modelUsage)}
        """
        guard case .result(let payload) = try StreamEvent.parse(json) else {
            throw XCTSkip("not a result event")
        }
        return payload
    }

    func testTheSessionModelsWindowIsReadFromModelUsage() throws {
        let payload = try result(modelUsage: """
        {"claude-opus-5-5":{"inputTokens":3,"contextWindow":1000000},"claude-haiku-5-5":{"inputTokens":9,"contextWindow":200000}}
        """)
        XCTAssertEqual(payload.contextWindow(for: "claude-opus-5-5"), 1_000_000)
        XCTAssertEqual(payload.contextWindow(for: "claude-opus-5-5[1m]"), 1_000_000, "a bracketed variant names the same model")
        XCTAssertNil(payload.contextWindow(for: "claude-sonnet-5-5"), "a subagent's window is not the session's")
    }

    func testTheOnlyEntryIsTheSessionsWhateverItsModelIsCalled() throws {
        let payload = try result(modelUsage: #"{"claude-opus-5-5":{"contextWindow":1000000}}"#)
        XCTAssertEqual(payload.contextWindow(for: "opus"), 1_000_000)
    }

    func testALineWithoutAWindowReportsNone() throws {
        let payload = try result(modelUsage: #"{"claude-opus-5-5":{"inputTokens":3,"contextWindow":0}}"#)
        XCTAssertTrue(payload.contextWindows.isEmpty)
        XCTAssertNil(payload.contextWindow(for: "claude-opus-5-5"))
    }
}
