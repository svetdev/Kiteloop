import XCTest
import KiteloopCore
@testable import Kiteloop

/// `StreamEvent.parse` over a stream `claude` 2.1.281 really wrote: a subagent
/// listing files, a shell sent to the background, an empty thinking block and
/// the session notices around them.
final class StreamEventSubagentFixtureTests: XCTestCase {

    static let agentCallID = "toolu_01RRgdR6YB5fCRQe3GK3hZ8A"

    /// The fixture's lines, as the runtime reads them off stdout.
    static func fixtureLines(
        named name: String = "cli-2.1.281-subagent-background-thinking",
        file: StaticString = #filePath
    ) throws -> [String] {
        let url = RepositoryRoot.of(file: file).appending(
            path: "Kiteloop/KiteloopCore/Tests/Fixtures/stream-json/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// The same kind of prompt from a CLI spawned with `--forward-subagent-text`:
    /// the subagent's thinking and text come through, tagged with its `Agent`
    /// call.
    static let forwardedTextFixture = "cli-2.1.281-forward-subagent-text"
    static let forwardedAgentCallID = "toolu_011cCGAVEDpfAewYvxuwMVxH"

    static func forwardedTextEvents() throws -> [StreamEvent] {
        try fixtureLines(named: forwardedTextFixture).map(StreamEvent.parse)
    }

    static func fixtureEvents() throws -> [StreamEvent] {
        try fixtureLines().map(StreamEvent.parse)
    }

    func testEveryLineParses() throws {
        let lines = try Self.fixtureLines()
        XCTAssertEqual(lines.count, 34)
        for (index, line) in lines.enumerated() {
            XCTAssertNoThrow(try StreamEvent.parse(line), "line \(index + 1)")
        }
    }

    func testTheSubagentsCallsAndResultsCarryTheAgentCallAsParent() throws {
        var calls: [(name: String, parent: String?)] = []
        var resultParents: [String?] = []
        for event in try Self.fixtureEvents() {
            if case .toolUse(_, let name, _, let parent) = event { calls.append((name, parent)) }
            if case .toolResult(_, _, let parent) = event { resultParents.append(parent) }
        }
        XCTAssertEqual(calls.map(\.name), ["Agent", "Bash", "SubagentHandback", "Bash", "Bash"])
        XCTAssertEqual(calls.map(\.parent), [nil, Self.agentCallID, Self.agentCallID, nil, nil])
        XCTAssertEqual(resultParents, [Self.agentCallID, Self.agentCallID, nil, nil, nil],
                       "the subagent's two results, then the Agent call's own and the two shells'")
    }

    func testTheEmptyThinkingBlockParsesAsEmptyThinking() throws {
        let thoughts = try Self.fixtureEvents().compactMap { event -> String? in
            if case .thinking(let text, _) = event { return text }
            return nil
        }
        XCTAssertEqual(thoughts, [""])
    }

    /// The rate-limit notice is a top-level line of its own; it rides the
    /// `system` case under its type, where `AgentActivityEvent` reads it.
    func testTheRateLimitLineIsASystemNoticeTheActivityParserReads() throws {
        let notices = try Self.fixtureEvents().compactMap { event -> AgentActivityEvent? in
            guard case .system(let subtype, let payload) = event else { return nil }
            return AgentActivityEvent.parse(subtype: subtype, payload: payload)
        }
        XCTAssertEqual(notices.count, 13, "2 thinking estimates, the rate limit, 2 starts, 2 progresses, 2 updates, 2 notifications, 2 listings")
        XCTAssertTrue(notices.contains { if case .rateLimit = $0 { return true } else { return false } })
    }

    // MARK: - --forward-subagent-text

    /// With the flag the subagent's closing thought and its report arrive as
    /// assistant lines carrying the `Agent` call's id; the agent's own summary
    /// after it carries none.
    func testForwardedSubagentTextAndThinkingCarryTheAgentCallAsParent() throws {
        var texts: [(text: String, parent: String?)] = []
        var thoughts: [String?] = []
        for event in try Self.forwardedTextEvents() {
            if case .assistantText(let text, let parent) = event { texts.append((text, parent)) }
            if case .thinking(_, let parent) = event { thoughts.append(parent) }
        }
        XCTAssertEqual(thoughts, [Self.forwardedAgentCallID])
        XCTAssertEqual(texts.map(\.parent), [Self.forwardedAgentCallID, nil])
        XCTAssertTrue(texts[0].text.hasPrefix("The directory holds only two files."))
        XCTAssertTrue(texts[1].text.hasPrefix("The directory holds only two small files."))
    }

    func testEveryForwardedLineParses() throws {
        let lines = try Self.fixtureLines(named: Self.forwardedTextFixture)
        XCTAssertEqual(lines.count, 31)
        for (index, line) in lines.enumerated() {
            XCTAssertNoThrow(try StreamEvent.parse(line), "line \(index + 1)")
        }
    }

    func testARecordingKeepsTheTextsParentAndAnOldRecordingLoadsWithout() throws {
        let event = StreamEvent.assistantText("found two files", parentToolUseID: "a")
        let recorded = try JSONDecoder().decode(CodableStreamEvent.self,
                                                from: JSONEncoder().encode(CodableStreamEvent.from(event)))
        guard case .assistantText(let text, let parent) = recorded.toStreamEvent() else { return XCTFail("not text") }
        XCTAssertEqual(text, "found two files")
        XCTAssertEqual(parent, "a")

        let old = #"{"thinking":{"_0":"hmm"}}"#
        guard case .thinking(let thought, let none) = try JSONDecoder().decode(CodableStreamEvent.self, from: Data(old.utf8))
            .toStreamEvent() else { return XCTFail("an old recording's thinking did not load") }
        XCTAssertEqual(thought, "hmm")
        XCTAssertNil(none)
    }

    func testARecordingKeepsTheParentAndAnOldRecordingLoadsWithout() throws {
        let event = StreamEvent.toolUse(id: "b", name: "Bash", input: "{}", parentToolUseID: "a")
        let recorded = try JSONDecoder().decode(CodableStreamEvent.self,
                                                from: JSONEncoder().encode(CodableStreamEvent.from(event)))
        guard case .toolUse(_, _, _, let parent) = recorded.toStreamEvent() else { return XCTFail("not a tool use") }
        XCTAssertEqual(parent, "a")

        let old = #"{"toolUse":{"id":"b","name":"Bash","input":"{}"}}"#
        guard case .toolUse(_, _, _, let none) = try JSONDecoder().decode(CodableStreamEvent.self, from: Data(old.utf8))
            .toStreamEvent() else { return XCTFail("an old recording's tool use did not load") }
        XCTAssertNil(none)
    }
}
