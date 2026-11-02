import Foundation

/// Structural validation for a decoded `WorkflowGraph` — decoding only proves the
/// JSON matched the schema, not that the graph it describes is runnable.
package enum WorkflowGraphValidator {
    /// Every failing rule's message, not just the first.
    package static func validate(_ graph: WorkflowGraph) -> [String] {
        var errors: [String] = []

        if graph.nodes[graph.entryNode] == nil {
            errors.append("entryNode '\(graph.entryNode)' does not exist in nodes")
        }

        for terminal in graph.terminalNodes where graph.nodes[terminal] == nil {
            errors.append("terminalNode '\(terminal)' does not exist in nodes")
        }

        for edge in graph.edges {
            if graph.nodes[edge.from] == nil {
                errors.append("edge references non-existent source node '\(edge.from)'")
            }
            if graph.nodes[edge.to] == nil {
                errors.append("edge references non-existent target node '\(edge.to)'")
            }
        }

        for (nodeID, node) in graph.nodes where node.agentID == nil && node.subGraphID == nil {
            errors.append("node '\(nodeID)' has neither agentID nor subGraphID")
        }

        return errors
    }
}
