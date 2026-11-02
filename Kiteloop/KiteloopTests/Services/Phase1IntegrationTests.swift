import XCTest
import KiteloopCore
@testable import Kiteloop

final class Phase1IntegrationTests: XCTestCase {
    func testScopeResolutionProducesSpanEvent() {
        let profile = ProfileToolScope(
            allowed: ["Bash", "Edit", "Write"],
            denied: ["Write"],
            policyVersion: "v1"
        )
        let taskLayer = LayerToolScope(
            allowed: ["Bash", "Edit"],
            denied: [],
            policyVersion: "v1",
            source: .taskHint(taskID: "task-42")
        )

        let resolved = ToolScopeResolver.resolve(profile: profile, layers: [taskLayer])
        XCTAssertEqual(resolved.effective, ["Bash", "Edit"])

        let decision = ToolInterceptor.checkScope(tool: "Write", scope: resolved)
        XCTAssertEqual(decision, .denied(reason: .explicitDeny))

        let spanEvent = SpanEvent(
            name: "policy_decision",
            timestamp: Date(),
            attributes: [
                "tool": .string("Write"),
                "decision": .string("denied"),
                "reason": .string("explicit_deny"),
                "scope_source": .string("profile")
            ]
        )
        XCTAssertEqual(spanEvent.name, "policy_decision")
        if case .string(let v) = spanEvent.attributes["decision"] {
            XCTAssertEqual(v, "denied")
        } else {
            XCTFail("Expected string attribute")
        }
    }

    func testSpanHierarchyWithParentChild() {
        let traceID = OTelIDs.newTraceID()
        let sessionSpanID = OTelIDs.newSpanID()

        let sessionSpan = Span(
            traceID: traceID,
            spanID: sessionSpanID,
            parentSpanID: nil,
            name: "freeform-session",
            spanType: .session,
            agentID: nil,
            startTime: Date(),
            endTime: nil,
            status: .unset,
            attributes: ["kiteloop.session_id": .string("sess-abc")],
            events: [],
            links: []
        )

        let turnSpan = Span(
            traceID: traceID,
            spanID: OTelIDs.newSpanID(),
            parentSpanID: sessionSpanID,
            name: "user-message",
            spanType: .turn,
            agentID: "researcher",
            startTime: Date(),
            endTime: nil,
            status: .unset,
            attributes: ["kiteloop.agent_id": .string("researcher")],
            events: [],
            links: []
        )

        XCTAssertEqual(sessionSpan.traceID, turnSpan.traceID)
        XCTAssertEqual(turnSpan.parentSpanID, sessionSpan.spanID)
        XCTAssertNil(sessionSpan.parentSpanID)
    }

    func testScopeContributionsProvideAuditTrail() {
        let profile = ProfileToolScope(
            allowed: ["Bash", "Edit", "Write", "Read"],
            denied: [],
            policyVersion: "v1"
        )
        let task = LayerToolScope(
            allowed: ["Bash", "Edit", "Write"],
            denied: ["Write"],
            policyVersion: "v2",
            source: .taskHint(taskID: "code-review")
        )
        let workflow = LayerToolScope(
            allowed: ["Bash", "Edit"],
            denied: [],
            policyVersion: "v1",
            source: .workflowNode(graphID: "review-flow", nodeID: "lint-node")
        )

        let resolved = ToolScopeResolver.resolve(profile: profile, layers: [task, workflow])

        XCTAssertEqual(resolved.effective, ["Bash", "Edit"])
        XCTAssertEqual(resolved.denied, ["Write"])
        XCTAssertEqual(resolved.base, ["Bash", "Edit", "Write", "Read"])
        XCTAssertEqual(resolved.contributions.count, 3)
        XCTAssertEqual(resolved.contributions[0].source, .profile)
        XCTAssertEqual(resolved.contributions[1].source, .taskHint(taskID: "code-review"))
        XCTAssertEqual(resolved.contributions[2].source, .workflowNode(graphID: "review-flow", nodeID: "lint-node"))
    }
}
