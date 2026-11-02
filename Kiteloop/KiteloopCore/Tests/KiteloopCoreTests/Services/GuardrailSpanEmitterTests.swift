import XCTest
@testable import KiteloopCore

final class GuardrailSpanEmitterTests: XCTestCase {

    func testEmitPermitDecision_createsSpanEvent() {
        let emitter = GuardrailSpanEmitter()
        let event = emitter.makeSpanEvent(
            tool: "Bash",
            decision: .permitted,
            agentID: "coder",
            scope: ResolvedToolScope(
                effective: Set(["Bash", "Read"]),
                base: Set(["Bash", "Read"]),
                denied: Set(),
                contributions: []
            )
        )
        XCTAssertEqual(event.name, "guardrail.tool_access")
        XCTAssertEqual(event.attributes["tool"], .string("Bash"))
        XCTAssertEqual(event.attributes["decision"], .string("permitted"))
        XCTAssertEqual(event.attributes["agent_id"], .string("coder"))
    }

    func testEmitDenyDecision_includesReason() {
        let emitter = GuardrailSpanEmitter()
        let event = emitter.makeSpanEvent(
            tool: "Write",
            decision: .denied(reason: .explicitDeny),
            agentID: "researcher",
            scope: ResolvedToolScope(
                effective: Set(["Read"]),
                base: Set(["Read", "Write"]),
                denied: Set(["Write"]),
                contributions: []
            )
        )
        XCTAssertEqual(event.attributes["decision"], .string("denied"))
        XCTAssertEqual(event.attributes["deny_reason"], .string("explicitDeny"))
        XCTAssertEqual(event.attributes["effective_scope_size"], .int(1))
    }

    func testEmitDenyNotInAllowed_reason() {
        let emitter = GuardrailSpanEmitter()
        let event = emitter.makeSpanEvent(
            tool: "Bash",
            decision: .denied(reason: .notInAllowed),
            agentID: "reader",
            scope: ResolvedToolScope(
                effective: Set(["Read", "Grep"]),
                base: Set(["Read", "Grep"]),
                denied: Set(),
                contributions: []
            )
        )
        XCTAssertEqual(event.attributes["deny_reason"], .string("notInAllowed"))
    }
}
