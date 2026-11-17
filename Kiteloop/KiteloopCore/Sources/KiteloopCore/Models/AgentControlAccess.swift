import Foundation

/// Which control API credential an agent with Operator tools on is spawned
/// with — `controlAccess` in an agent package's template and on the agent.
/// It decides nothing for an agent whose Operator tools are off: that agent
/// carries no credential at all.
package enum AgentControlAccess: String, Codable, Sendable, CaseIterable {
    /// The operator token: the whole API except the human gates and token
    /// management. What every agent had before the key existed, so it is what
    /// an agent or a package that says nothing gets.
    case operatorToken = "operator"
    /// A read-scoped token the app keeps for the purpose (`AgentReadToken`):
    /// the `GET` routes a `read` scoped token may call, and nothing else.
    case readOnly = "read"

    /// What an agent or package that carries no `controlAccess` gets.
    package static let whenUnstated = AgentControlAccess.operatorToken

    /// A value this build does not know decodes as the narrowest access: a
    /// misspelt `"read"` must not be the reason an agent holds the operator
    /// token.
    package init(from decoder: Decoder) throws {
        let stated = try decoder.singleValueContainer().decode(String.self)
        self = AgentControlAccess(rawValue: stated) ?? .readOnly
    }

    /// The bearer token a spawn carries: the operator token, or the read
    /// token — and nothing when the read token cannot be had, never the
    /// operator token in its place.
    package func token(operatorToken: () -> String, readToken: () -> String?) -> String? {
        switch self {
        case .operatorToken: return operatorToken()
        case .readOnly: return readToken()
        }
    }

    /// The note appended to the agent's system prompt, of the two the app
    /// builds from the routing table (`OperatorToolsKnowledge`).
    package func note(operatorNote: String, readOnlyNote: String) -> String {
        switch self {
        case .operatorToken: return operatorNote
        case .readOnly: return readOnlyNote
        }
    }
}
