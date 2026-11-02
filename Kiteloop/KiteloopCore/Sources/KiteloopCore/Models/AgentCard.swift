import Foundation
import CryptoKit

package struct AgentCard: Codable, Sendable, Identifiable {
    package var id: String {
        switch agentRef.scope {
        case .global: return "global:\(agentRef.id)"
        case .project(let projectID): return "project:\(projectID):\(agentRef.id)"
        }
    }
    package let agentRef: AgentRef
    package let name: String
    package let description: String
    package let capabilities: [String]
    package let knowledgeDomains: [String]
    package let toolsUsed: [String]
    package let inputSchema: AgentIOSchema?
    package let outputEvents: [String]
    package let model: String
    package let sourceFingerprint: String

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(agentRef: AgentRef, name: String, description: String, capabilities: [String], knowledgeDomains: [String], toolsUsed: [String], inputSchema: AgentIOSchema?, outputEvents: [String], model: String, sourceFingerprint: String) {
        self.agentRef = agentRef
        self.name = name
        self.description = description
        self.capabilities = capabilities
        self.knowledgeDomains = knowledgeDomains
        self.toolsUsed = toolsUsed
        self.inputSchema = inputSchema
        self.outputEvents = outputEvents
        self.model = model
        self.sourceFingerprint = sourceFingerprint
    }
}

package struct AgentRef: Codable, Sendable, Hashable {
    package let id: String
    package let scope: AgentScope

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: String, scope: AgentScope) {
        self.id = id
        self.scope = scope
    }
}

package enum AgentScope: Codable, Sendable, Hashable {
    case global
    case project(id: String)

    package enum CodingKeys: String, CodingKey {
        case type, projectID
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode("global", forKey: .type)
        case .project(let id):
            try container.encode("project", forKey: .type)
            try container.encode(id, forKey: .projectID)
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "project":
            let projectID = try container.decode(String.self, forKey: .projectID)
            self = .project(id: projectID)
        default:
            self = .global
        }
    }
}

package struct AgentIOSchema: Codable, Sendable {
    package let requiredInputs: [String]
    package let optionalInputs: [String]
    package let outputFormat: String?

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(requiredInputs: [String], optionalInputs: [String], outputFormat: String?) {
        self.requiredInputs = requiredInputs
        self.optionalInputs = optionalInputs
        self.outputFormat = outputFormat
    }
}

package struct DiscoveredAgent: Codable, Sendable {
    package let agentRef: AgentRef
    package let name: String
    package let description: String
    package let matchedCapabilities: [String]
    package let knowledgeDomains: [String]
    package let canMessage: Bool

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(agentRef: AgentRef, name: String, description: String, matchedCapabilities: [String], knowledgeDomains: [String], canMessage: Bool) {
        self.agentRef = agentRef
        self.name = name
        self.description = description
        self.matchedCapabilities = matchedCapabilities
        self.knowledgeDomains = knowledgeDomains
        self.canMessage = canMessage
    }
}
