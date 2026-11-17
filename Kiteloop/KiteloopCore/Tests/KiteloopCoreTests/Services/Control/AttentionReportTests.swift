import XCTest
@testable import KiteloopCore

/// `GET /v1/attention`'s payload: the waiting drawer's list, in its order, each
/// row naming the call that answers it.
final class AttentionReportTests: XCTestCase {

    private let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_100_000)

    // MARK: - Order

    /// Oldest first, and a gate whose notice is gone (`since` nil) above all of
    /// them — the order `WaitingOnYou.rows` already has.
    func testRowsComeOutInTheListsOrder() throws {
        let waiting = WaitingOnYou.capture(projects: [
            reading(gated: [.init(id: "item-gated", title: "Gated")],
                    stale: [stale("item-new", touched: later), stale("item-old", touched: earlier)])
        ])
        let rows = try rows(of: AttentionReport.payload(waiting))

        XCTAssertEqual(rows.map { $0["id"] as? String }, waiting.rows.map(\.id))
        XCTAssertEqual(rows.compactMap { $0["itemId"] as? String }, ["item-gated", "item-old", "item-new"])
        XCTAssertTrue(rows[0]["since"] is NSNull, "a row with no notice sorts to the top")
        XCTAssertEqual(rows[1]["since"] as? String, earlier.formatted(.iso8601))
    }

    // MARK: - Shape

    func testARowCarriesItsProjectAndFields() throws {
        let waiting = WaitingOnYou.capture(projects: [
            reading(gated: [.init(id: "item-1", title: "Needs sign-off", staleFileCount: 2, gateRefusal: "conflicts")])
        ])
        let row = try XCTUnwrap(rows(of: AttentionReport.payload(waiting)).first)

        XCTAssertEqual(row["kind"] as? String, "approval")
        XCTAssertEqual(row["title"] as? String, "Needs sign-off")
        XCTAssertEqual(row["gateRefusal"] as? String, "conflicts")
        XCTAssertEqual(row["staleFileCount"] as? Int, 2)
        XCTAssertTrue(row["agentId"] is NSNull)
        let project = try XCTUnwrap(row["project"] as? [String: Any])
        XCTAssertEqual(project["id"] as? String, "p-alpha")
        XCTAssertEqual(project["name"] as? String, "alpha")
        XCTAssertEqual(project["path"] as? String, "/tmp/alpha")
    }

    func testTheTopLevelCountsAndSummarises() {
        let waiting = WaitingOnYou.capture(projects: [
            reading(gated: [.init(id: "item-1", title: "One")], asking: [.init(id: "agent-1", name: "Ada")])
        ])
        let payload = AttentionReport.payload(waiting)
        XCTAssertEqual(payload["count"] as? Int, 2)
        XCTAssertEqual(payload["summary"] as? String, waiting.summary)
    }

    func testAnEmptyListSaysNothingIsWaiting() throws {
        let payload = AttentionReport.payload(WaitingOnYou.capture(projects: [reading()]))
        XCTAssertEqual(payload["count"] as? Int, 0)
        XCTAssertEqual(payload["summary"] as? String, "nothing is waiting on you")
        XCTAssertEqual(try rows(of: payload).count, 0)
    }

    // MARK: - Answers

    /// Every kind points at the call that clears it — an agent's row by what
    /// that agent is waiting on.
    func testEachKindNamesTheCallThatAnswersIt() throws {
        let waiting = WaitingOnYou.capture(projects: [
            reading(gated: [.init(id: "item-1", title: "Gated")],
                    asking: [.init(id: "asker", name: "A"), .init(id: "planner", name: "P"),
                             .init(id: "prompter", name: "Q")],
                    stale: [stale("item-2", touched: earlier)])
        ])
        let waits: [String: AttentionReport.AgentWait] = ["asker": .question, "planner": .plan, "prompter": .prompt]
        let payload = AttentionReport.payload(waiting) { row in
            guard case .question(let agentID) = row.gate else { return .question }
            return waits[agentID] ?? .question
        }
        var answers: [String: String] = [:]
        for row in try rows(of: payload) {
            let kind = try XCTUnwrap(row["kind"] as? String)
            let answer = try XCTUnwrap(row["answer"] as? [String: String])
            answers[kind] = "\(answer["method"] ?? "") \(answer["path"] ?? "")"
        }
        XCTAssertEqual(answers, [
            "approval": "POST /v1/backlog/approve",
            "question": "POST /v1/agents/answer",
            "plan": "POST /v1/agents/plan",
            "prompt": "POST /v1/agents/permission",
            "stale": "GET /v1/backlog/detail"
        ])
    }

    func testAnAgentRowIsAQuestionUnlessToldOtherwise() throws {
        let waiting = WaitingOnYou.capture(projects: [reading(asking: [.init(id: "agent-1", name: "Ada")])])
        let row = try XCTUnwrap(rows(of: AttentionReport.payload(waiting)).first)
        XCTAssertEqual(row["kind"] as? String, "question")
        XCTAssertEqual(row["agentId"] as? String, "agent-1")
        XCTAssertTrue(row["itemId"] is NSNull)
    }

    // MARK: - Helpers

    private func reading(gated: [WaitingOnYou.ProjectReading.GatedItem] = [],
                         asking: [WaitingOnYou.ProjectReading.AskingAgent] = [],
                         stale: [WaitingOnYou.ProjectReading.StaleItem] = []) -> WaitingOnYou.ProjectReading {
        .init(id: "p-alpha", name: "alpha", path: "/tmp/alpha",
              gatedItems: gated, askingAgents: asking, staleItems: stale)
    }

    private func stale(_ id: String, touched: Date) -> WaitingOnYou.ProjectReading.StaleItem {
        .init(id: id, title: id, status: .ready, lastTouched: touched)
    }

    private func rows(of payload: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(payload["rows"] as? [[String: Any]])
    }
}
