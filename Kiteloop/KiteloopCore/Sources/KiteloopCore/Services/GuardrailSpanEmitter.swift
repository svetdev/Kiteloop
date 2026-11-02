import Foundation

package struct GuardrailSpanEmitter {

    package func makeSpanEvent(
        tool: String,
        decision: ScopeDecision,
        agentID: String,
        scope: ResolvedToolScope
    ) -> SpanEvent {
        var attributes: [String: AttributeValue] = [
            "tool": .string(tool),
            "agent_id": .string(agentID),
            "effective_scope_size": .int(scope.effective.count)
        ]

        switch decision {
        case .permitted:
            attributes["decision"] = .string("permitted")
        case .denied(let reason):
            attributes["decision"] = .string("denied")
            attributes["deny_reason"] = .string(reason.rawValue)
        }

        return SpanEvent(
            name: "guardrail.tool_access",
            timestamp: Date(),
            attributes: attributes
        )
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init() {
    
    }
}
