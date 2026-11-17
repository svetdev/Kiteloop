import Foundation

/// Who a request came as — which of the credentials the control API accepts
/// its bearer token is.
package enum ControlCredential: Equatable, Sendable {
    /// The control token: the person's own credential.
    case full
    /// A paired phone's token: the person, from their phone.
    case paired
    /// The operator token, handed to an agent with operator tools.
    case operatorToken
    /// A token minted over `/v1/tokens`, holding one scope.
    case scoped(ControlScope)

    /// Whether the person holds it. A human gate opens for these and no other:
    /// the operator token is an agent's, and a scoped token is minted to be
    /// handed to something else.
    package var isThePersons: Bool {
        switch self {
        case .full, .paired: return true
        case .operatorToken, .scoped: return false
        }
    }
}

/// What each credential may call, decided from the routing table alone so the
/// rule is tested without a server. The server answers 403 with whatever
/// `refusal` returns, ahead of every handler.
package enum ControlAccess {

    /// Why `credential` may not call `route`, or nil when it may. `request`
    /// is the method and path as received, for the message that names them.
    package static func refusal(of credential: ControlCredential, calling route: ControlRoute,
                                as request: String) -> String? {
        if credential == .operatorToken, route.isHumanGate {
            return "the human gate takes the operator's own token (scope: approve)"
        }
        if route.isTokenManagement, credential != .full {
            return "managing scoped tokens takes the control token itself"
        }
        guard case .scoped(let held) = credential else { return nil }
        if route.isHumanGate {
            return "the human gate takes the operator's own token; no scoped token resolves it"
        }
        guard held.includes(route.scope) else {
            return "this token's scope is \(held.rawValue); \(request) needs \(route.scope.rawValue)"
        }
        return nil
    }

    /// Why `credential` may not send `message` to an agent, or nil when it
    /// may. A message is run as typed, and `/mode <name>` typed into a chat
    /// moves the agent to that permission mode — the change
    /// `POST /v1/agents/mode` makes, so it is the same gate.
    package static func messageRefusal(of credential: ControlCredential, sending message: String) -> String? {
        guard !credential.isThePersons, switchesPermissionMode(message) else { return nil }
        return refusal(of: credential, calling: .setAgentMode, as: "POST /v1/agents/mode")
    }

    /// Whether a chat reads `message` as `/mode` with a mode to move to. The
    /// chat trims the message, lowercases its first word and takes the rest
    /// as the argument; bare `/mode` only reports the mode.
    package static func switchesPermissionMode(_ message: String) -> Bool {
        let typed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.prefix(while: { $0 != " " }).lowercased() == "/mode" else { return false }
        return !typed.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces).isEmpty
    }
}
