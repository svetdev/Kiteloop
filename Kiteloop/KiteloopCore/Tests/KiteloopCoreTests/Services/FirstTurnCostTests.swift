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
}
