import XCTest
@testable import KiteloopCore

final class WorkflowEdgeConditionTests: XCTestCase {
    func testEventTypeConditionRoundTrip() throws {
        let condition = EdgeCondition.eventType("research_complete")
        let data = try JSONEncoder().encode(condition)
        let decoded = try JSONDecoder().decode(EdgeCondition.self, from: data)
        if case .eventType(let t) = decoded {
            XCTAssertEqual(t, "research_complete")
        } else { XCTFail("Expected eventType") }
    }

    func testEventTypeConditionFromJSON() throws {
        let json = """
        {"type": "eventType", "value": "research_complete"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EdgeCondition.self, from: json)
        if case .eventType(let t) = decoded {
            XCTAssertEqual(t, "research_complete")
        } else { XCTFail("Expected eventType") }
    }

    func testOutputMatchConditionRoundTrip() throws {
        let condition = EdgeCondition.outputMatch(key: "status", value: "approved")
        let data = try JSONEncoder().encode(condition)
        let decoded = try JSONDecoder().decode(EdgeCondition.self, from: data)
        if case .outputMatch(let k, let v) = decoded {
            XCTAssertEqual(k, "status")
            XCTAssertEqual(v, "approved")
        } else { XCTFail("Expected outputMatch") }
    }

    func testAlwaysConditionRoundTrip() throws {
        let condition = EdgeCondition.always
        let data = try JSONEncoder().encode(condition)
        let decoded = try JSONDecoder().decode(EdgeCondition.self, from: data)
        if case .always = decoded { } else { XCTFail("Expected always") }
    }

    func testHumanApprovalCondition() throws {
        let json = """
        {"type": "humanApproval", "question": "Deploy?", "deniedEdge": "error_node"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EdgeCondition.self, from: json)
        if case .humanApproval(let q, let denied) = decoded {
            XCTAssertEqual(q, "Deploy?")
            XCTAssertEqual(denied, "error_node")
        } else { XCTFail("Expected humanApproval") }
    }

    func testHumanApprovalNilDeniedEdge() throws {
        let json = """
        {"type": "humanApproval", "question": "Proceed?"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EdgeCondition.self, from: json)
        if case .humanApproval(let q, let denied) = decoded {
            XCTAssertEqual(q, "Proceed?")
            XCTAssertNil(denied)
        } else { XCTFail("Expected humanApproval") }
    }

    func testAllOfCondition() throws {
        let json = """
        {"type": "allOf", "conditions": [
            {"type": "eventType", "value": "task_complete"},
            {"type": "outputMatch", "key": "quality", "value": "high"}
        ]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EdgeCondition.self, from: json)
        if case .allOf(let conds) = decoded {
            XCTAssertEqual(conds.count, 2)
        } else { XCTFail("Expected allOf") }
    }

    func testAnyOfCondition() throws {
        let json = """
        {"type": "anyOf", "conditions": [
            {"type": "always"},
            {"type": "eventType", "value": "error"}
        ]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EdgeCondition.self, from: json)
        if case .anyOf(let conds) = decoded {
            XCTAssertEqual(conds.count, 2)
        } else { XCTFail("Expected anyOf") }
    }

    func testWorkflowEdgeRoundTrip() throws {
        let edge = WorkflowEdge(
            from: "research",
            to: "write",
            condition: .always,
            priority: 0,
            carryForwardSource: .nodeOutput
        )
        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(WorkflowEdge.self, from: data)
        XCTAssertEqual(decoded.from, "research")
        XCTAssertEqual(decoded.to, "write")
        XCTAssertEqual(decoded.priority, 0)
        XCTAssertEqual(decoded.carryForwardSource, .nodeOutput)
    }

    func testCarryForwardSourceDefaultsFromConditionType() throws {
        // eventType → defaults to .eventPayload
        let json1 = """
        {"from": "a", "to": "b", "condition": {"type": "eventType", "value": "done"}}
        """.data(using: .utf8)!
        let edge1 = try JSONDecoder().decode(WorkflowEdge.self, from: json1)
        XCTAssertEqual(edge1.carryForwardSource, .eventPayload)

        // outputMatch → defaults to .nodeOutput
        let json2 = """
        {"from": "a", "to": "b", "condition": {"type": "outputMatch", "key": "s", "value": "ok"}}
        """.data(using: .utf8)!
        let edge2 = try JSONDecoder().decode(WorkflowEdge.self, from: json2)
        XCTAssertEqual(edge2.carryForwardSource, .nodeOutput)

        // always → defaults to .nodeOutput
        let json3 = """
        {"from": "a", "to": "b", "condition": {"type": "always"}}
        """.data(using: .utf8)!
        let edge3 = try JSONDecoder().decode(WorkflowEdge.self, from: json3)
        XCTAssertEqual(edge3.carryForwardSource, .nodeOutput)

        // humanApproval → defaults to .approvalPayload
        let json4 = """
        {"from": "a", "to": "b", "condition": {"type": "humanApproval", "question": "ok?"}}
        """.data(using: .utf8)!
        let edge4 = try JSONDecoder().decode(WorkflowEdge.self, from: json4)
        XCTAssertEqual(edge4.carryForwardSource, .approvalPayload)
    }

    func testCarryForwardSourceExplicitOverridesDefault() throws {
        let json = """
        {"from": "a", "to": "b", "condition": {"type": "eventType", "value": "done"}, "carryForwardSource": "nodeOutput"}
        """.data(using: .utf8)!
        let edge = try JSONDecoder().decode(WorkflowEdge.self, from: json)
        XCTAssertEqual(edge.carryForwardSource, .nodeOutput)
    }
}
