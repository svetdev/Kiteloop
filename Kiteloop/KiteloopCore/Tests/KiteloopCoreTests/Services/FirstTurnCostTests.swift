import XCTest
@testable import KiteloopCore

final class FirstTurnCostTests: XCTestCase {

    func testASectionIsMeasuredInBytesOfUTF8Text() {
        let cost = FirstTurnCost(sections: [(name: "prompt", text: "abcd"), (name: "memory", text: "é")])

        XCTAssertEqual(cost.sections, [.init(name: "prompt", bytes: 4), .init(name: "memory", bytes: 2)])
    }

    func testAnEmptySectionIsLeftOut() {
        let cost = FirstTurnCost(sections: [(name: "prompt", text: ""), (name: "memory", text: "a")])

        XCTAssertEqual(cost.sections.map(\.name), ["memory"])
    }

    func testTheTotalIsTheSumOfTheSections() {
        let cost = FirstTurnCost(sections: [(name: "prompt", text: "abc"), (name: "skill:review", text: "abcde")])

        XCTAssertEqual(cost.total, 8)
        XCTAssertEqual(FirstTurnCost(sections: []).total, 0)
    }

    func testTheJSONKeepsTheOrderTheSectionsWereGivenIn() throws {
        let cost = FirstTurnCost(sections: [
            (name: "prompt", text: "abc"), (name: "projectContext", text: ""), (name: "memory", text: "ab"),
            (name: "skill:b", text: "a"), (name: "skill:a", text: "a")
        ])

        let json = cost.json
        let sections = try XCTUnwrap(json["sections"] as? [[String: Any]])
        XCTAssertEqual(json["bytes"] as? Int, 7)
        XCTAssertEqual(sections.map { $0["name"] as? String }, ["prompt", "memory", "skill:b", "skill:a"])
        XCTAssertEqual(sections.map { $0["bytes"] as? Int }, [3, 2, 1, 1])
    }

    // MARK: - Measured, reported, unmeasured

    private func status(_ name: String, state: String = "connected", tools: [String] = [],
                        at seconds: TimeInterval = 0) -> ConnectorStatus {
        ConnectorStatus(name: name, state: state, tools: tools, reportedAt: Date(timeIntervalSince1970: seconds))
    }

    func testTheNoteAndTheToolDefinitionsAreSectionsLikeAnyOther() {
        let cost = FirstTurnCost(sections: [
            (name: "prompt", text: "abc"), (name: "operatorTools", text: "abcd"), (name: "kiteloopTools", text: "[{}]")
        ])

        XCTAssertEqual(cost.sections.map(\.name), ["prompt", "operatorTools", "kiteloopTools"])
        XCTAssertEqual(cost.total, 11)
    }

    func testAServerASessionReportedIsReportedWithWhatWasSaidAndWhen() {
        let seen = status("github", tools: ["create_issue", "search"], at: 1_000)
        let cost = FirstTurnCost(sections: [], servers: ["github"]) { $0 == "github" ? seen : nil }

        XCTAssertEqual(cost.reported, [.init(name: "mcp:github", state: "connected",
                                             tools: ["create_issue", "search"],
                                             reportedAt: Date(timeIntervalSince1970: 1_000))])
        XCTAssertEqual(cost.unmeasured, [FirstTurnCost.cli])
    }

    func testAServerNoSessionReportedIsUnmeasuredByName() {
        let cost = FirstTurnCost(sections: [], servers: ["linear", "github"]) { _ in nil }

        XCTAssertEqual(cost.reported, [])
        XCTAssertEqual(cost.unmeasured.map(\.name), ["mcp:linear", "mcp:github", "cli"])
        XCTAssertFalse(cost.unmeasured[0].reason.isEmpty)
    }

    func testAServerIsEitherReportedOrUnmeasuredNeverBoth() {
        let cost = FirstTurnCost(sections: [], servers: ["a", "b", "c"]) { [self] in $0 == "b" ? status("b") : nil }

        XCTAssertEqual(cost.reported.map(\.name), ["mcp:b"])
        XCTAssertEqual(cost.unmeasured.map(\.name), ["mcp:a", "mcp:c", "cli"])
    }

    func testAFailedServerIsReportedAsItWasSeen() {
        let cost = FirstTurnCost(sections: [], servers: ["jira"]) { [self] _ in status("jira", state: "needs-auth") }

        XCTAssertEqual(cost.reported.map(\.state), ["needs-auth"])
        XCTAssertEqual(cost.reported.first?.tools, [])
    }

    func testTheCLIIsUnmeasuredOnceWhateverTheAgentHas() {
        XCTAssertEqual(FirstTurnCost(sections: []).unmeasured, [FirstTurnCost.cli])
        XCTAssertEqual(FirstTurnCost(sections: [(name: "prompt", text: "a")], servers: ["a"]).unmeasured.filter { $0 == FirstTurnCost.cli }.count, 1)
    }

    func testAnAgentTheCLIDoesNotRunHasNoCLIShare() {
        XCTAssertEqual(FirstTurnCost(sections: [(name: "prompt", text: "a")], startedByCLI: false).unmeasured, [])
    }

    func testNothingReportedOrUnmeasuredIsInTheTotal() {
        let cost = FirstTurnCost(sections: [(name: "prompt", text: "abc")], servers: ["a", "b"]) { [self] in
            $0 == "a" ? status("a", tools: ["one", "two", "three"]) : nil
        }

        XCTAssertEqual(cost.total, 3)
        XCTAssertEqual(cost.json["bytes"] as? Int, 3)
    }

    func testTheJSONCarriesNoSizeForAReportedOrUnmeasuredPart() throws {
        let cost = FirstTurnCost(sections: [], servers: ["a", "b"]) { [self] in
            $0 == "a" ? status("a", tools: ["one"], at: 0) : nil
        }

        let reported = try XCTUnwrap(cost.json["reported"] as? [[String: Any]])
        let unmeasured = try XCTUnwrap(cost.json["unmeasured"] as? [[String: String]])
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(Set(reported[0].keys), ["name", "state", "tools", "reportedAt"])
        XCTAssertEqual(reported[0]["reportedAt"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(reported[0]["tools"] as? [String], ["one"])
        XCTAssertEqual(unmeasured.map { $0["name"] }, ["mcp:b", "cli"])
        XCTAssertEqual(unmeasured.map { Set($0.keys) }, [["name", "reason"], ["name", "reason"]])
    }
}
