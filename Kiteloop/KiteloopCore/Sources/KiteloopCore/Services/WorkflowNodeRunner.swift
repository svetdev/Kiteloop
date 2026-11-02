import Foundation

package struct NodeActivation: Sendable {
    package let executionID: String
    package let nodeID: String
    package let agentID: String?
    package let resolvedPrompt: String
    package let effectiveTools: Set<String>?
    package let maxTurns: Int?
    package let timeoutSeconds: Int?

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(executionID: String, nodeID: String, agentID: String?, resolvedPrompt: String, effectiveTools: Set<String>?, maxTurns: Int?, timeoutSeconds: Int?) {
        self.executionID = executionID
        self.nodeID = nodeID
        self.agentID = agentID
        self.resolvedPrompt = resolvedPrompt
        self.effectiveTools = effectiveTools
        self.maxTurns = maxTurns
        self.timeoutSeconds = timeoutSeconds
    }
}

package enum CircuitBreakerResult: Sendable, Equatable {
    case maxTurnsExceeded
    case timeoutExceeded
    case maxIterationsExceeded
}

package struct WorkflowNodeRunner: Sendable {
    package func prepareActivation(
        node: WorkflowNode,
        state: [String: AnyCodable],
        executionID: String,
        profileScope: ProfileToolScope? = nil
    ) -> NodeActivation {
        let templateResult = WorkflowStateTemplater.render(template: node.prompt, state: state)
        var resolvedPrompt = templateResult.rendered

        // Append unreferenced state as workflow context
        let unreferencedState = state.filter { !templateResult.referencedKeys.contains($0.key) }
        if !unreferencedState.isEmpty {
            var contextLines: [String] = ["\n\n--- Workflow Context ---"]
            for (key, value) in unreferencedState.sorted(by: { $0.key < $1.key }) {
                if let str = value.stringValue {
                    contextLines.append("\(key): \(str)")
                }
            }
            resolvedPrompt += contextLines.joined(separator: "\n")
        }

        let effectiveTools: Set<String>?
        if let profileScope = profileScope {
            effectiveTools = computeEffectiveScope(node: node, profileScope: profileScope)
        } else {
            effectiveTools = nil
        }

        return NodeActivation(
            executionID: executionID,
            nodeID: node.id,
            agentID: node.agentID,
            resolvedPrompt: resolvedPrompt,
            effectiveTools: effectiveTools,
            maxTurns: node.maxTurns,
            timeoutSeconds: node.timeoutSeconds
        )
    }

    package func computeEffectiveScope(node: WorkflowNode, profileScope: ProfileToolScope) -> Set<String> {
        var effective = profileScope.allowed

        if let nodeAllowed = node.toolScopeOverride?.allowed {
            effective = effective.intersection(nodeAllowed)
        }

        effective.subtract(profileScope.denied)
        effective.subtract(node.toolScopeOverride?.denied ?? [])

        return effective
    }

    package func checkCircuitBreaker(
        turnsElapsed: Int,
        maxTurns: Int?,
        elapsedSeconds: TimeInterval,
        timeoutSeconds: Int?
    ) -> CircuitBreakerResult? {
        if let max = maxTurns, turnsElapsed > max {
            return .maxTurnsExceeded
        }
        if let timeout = timeoutSeconds, elapsedSeconds > TimeInterval(timeout) {
            return .timeoutExceeded
        }
        return nil
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init() {
    
    }
}
