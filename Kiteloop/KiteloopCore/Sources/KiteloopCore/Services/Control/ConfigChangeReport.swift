import Foundation

/// `GET /v1/config-changes` and `GET /v1/config-changes/{id}`'s payloads: what
/// became of the configuration changes a credential asked for
/// (`ConfigChangeOutcome`), written out as JSON.
///
/// Pure, so the shape is pinned without a server. Nothing here is a secret
/// the reader did not already hold: `summary` is the redacted one the card
/// shows, and `response` is what the held request itself would have been sent
/// — `HeldConfigChanges` hands an outcome only to the credential that asked,
/// or to the person.
package enum ConfigChangeReport {

    /// The state's name in the payload.
    package static func name(of state: ConfigChangeOutcome.State) -> String {
        switch state {
        case .waiting: return "waiting"
        case .approved: return "approved"
        case .declined: return "declined"
        case .unrecorded: return "unrecorded"
        }
    }

    /// Every outcome a reader may see, in the order given.
    package static func list(_ outcomes: [ConfigChangeOutcome]) -> [String: Any] {
        ["count": outcomes.count, "changes": outcomes.map(json)]
    }

    /// One change and what became of it.
    package static func json(_ outcome: ConfigChangeOutcome) -> [String: Any] {
        let change = outcome.change
        return [
            "id": change.id,
            "state": name(of: outcome.state),
            "caller": change.caller,
            "route": change.route,
            "summary": change.summary,
            "project": change.project?.name ?? NSNull(),
            "askedAt": change.askedAt.formatted(.iso8601),
            "response": response(of: outcome.state) ?? NSNull(),
            "reason": reason(of: outcome.state) ?? NSNull()
        ]
    }

    /// What an approved call answered: its status, and its body as JSON when
    /// it is JSON, else as text. Nil until it has run, and for every other state.
    private static func response(of state: ConfigChangeOutcome.State) -> [String: Any]? {
        guard case .approved(let applied?) = state else { return nil }
        let body = (try? JSONSerialization.jsonObject(with: applied.body, options: [.fragmentsAllowed]))
            ?? String(decoding: applied.body, as: UTF8.self)
        return ["status": applied.status, "body": body]
    }

    /// Why an approved change was not applied.
    private static func reason(of state: ConfigChangeOutcome.State) -> String? {
        guard case .unrecorded(let reason) = state else { return nil }
        return "approved, but the decision could not be written to the change log, so nothing was changed: \(reason)"
    }
}
