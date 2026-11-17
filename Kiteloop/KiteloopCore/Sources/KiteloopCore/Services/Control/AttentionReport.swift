import Foundation

/// `GET /v1/attention`'s payload: a `WaitingOnYou` — the list the waiting
/// drawer draws — written out as JSON, each row naming the control call that
/// answers it.
///
/// Pure: it reads values and builds a dictionary, so the order and the answer
/// each kind points at are pinned without a server. The rows go out in
/// `WaitingOnYou.rows` order, which is the drawer's — longest-waiting first.
package enum AttentionReport {

    /// What an agent on a `.question` row is waiting on. `WaitingOnYou` keeps
    /// one gate for all three — the drawer opens the same chat for each — but
    /// each is answered by a different call.
    package enum AgentWait: Sendable {
        /// An unanswered `ask_human`.
        case question
        /// An open plan card.
        case plan
        /// An open permission or choices card.
        case prompt
    }

    /// A row's kind, as the payload names it.
    package enum Kind: String, Sendable {
        case approval, question, plan, prompt, stale, configChange
    }

    /// The call that answers a row of this kind.
    package static func answer(for kind: Kind) -> (method: String, path: String) {
        switch kind {
        case .approval: return ("POST", "/v1/backlog/approve")
        case .question: return ("POST", "/v1/agents/answer")
        case .plan: return ("POST", "/v1/agents/plan")
        case .prompt: return ("POST", "/v1/agents/permission")
        case .stale: return ("GET", "/v1/backlog/detail")
        case .configChange: return ("POST", "/v1/config-changes/{id}/answer")
        }
    }

    /// The call that answers `row`: its kind's, with a held configuration
    /// change's own id in the path.
    static func answer(for row: WaitingOnYou.Row, kind: Kind) -> (method: String, path: String) {
        guard case .configChange(let requestID) = row.gate else { return answer(for: kind) }
        return ("POST", "/v1/config-changes/\(requestID)/answer")
    }

    /// The whole payload: `count`, `summary` and `rows`, in the list's order.
    /// `agentWait` says what each question row's agent waits on; a row it is
    /// not asked about is a plain question.
    package static func payload(_ waiting: WaitingOnYou,
                                agentWait: (WaitingOnYou.Row) -> AgentWait = { _ in .question }) -> [String: Any] {
        [
            "count": waiting.rows.count,
            "summary": waiting.summary,
            "rows": waiting.rows.map { rowJSON($0, kind: kind(of: $0, agentWait: agentWait)) }
        ]
    }

    static func kind(of row: WaitingOnYou.Row, agentWait: (WaitingOnYou.Row) -> AgentWait) -> Kind {
        switch row.gate {
        case .approval: return .approval
        case .stale: return .stale
        case .configChange: return .configChange
        case .question:
            switch agentWait(row) {
            case .question: return .question
            case .plan: return .plan
            case .prompt: return .prompt
            }
        }
    }

    private static func rowJSON(_ row: WaitingOnYou.Row, kind: Kind) -> [String: Any] {
        let answer = answer(for: row, kind: kind)
        return [
            "id": row.id,
            "kind": kind.rawValue,
            "project": ["id": row.projectID, "name": row.projectName, "path": row.projectPath],
            "itemId": itemID(of: row) ?? NSNull(),
            "agentId": agentID(of: row) ?? NSNull(),
            "title": row.title,
            "detail": row.detail ?? NSNull(),
            "since": row.since.map { $0.formatted(.iso8601) } ?? NSNull(),
            "caller": caller(of: row) ?? NSNull(),
            "gateRefusal": row.gateRefusal ?? NSNull(),
            "staleFileCount": row.staleFileCount ?? NSNull(),
            "answer": ["method": answer.method, "path": answer.path]
        ]
    }

    private static func itemID(of row: WaitingOnYou.Row) -> String? {
        switch row.gate {
        case .approval(let itemID), .stale(let itemID): return itemID
        case .question, .configChange: return nil
        }
    }

    /// For a configuration change: the credential that asked for it.
    private static func caller(of row: WaitingOnYou.Row) -> String? {
        if case .configChange = row.gate { return row.agentName }
        return nil
    }

    private static func agentID(of row: WaitingOnYou.Row) -> String? {
        if case .question(let agentID) = row.gate { return agentID }
        return nil
    }
}
