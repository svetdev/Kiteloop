import Foundation
import KiteloopCore

/// Configuration changes an agent makes over the API: held until a person
/// answers, logged before they apply (`ConfigChangeGate`, `HeldConfigChanges`).
@MainActor
struct ConfigChangeEndpoints {
    let server: KiteloopControlServer

    /// Whether those changes wait on a person. On unless Settings says
    /// otherwise — a server with no settings store holds them too.
    var holdsAgentChanges: Bool {
        server.settings?.config.agentAPIChangesNeedApproval ?? true
    }

    /// Holds a configuration change made with the operator token or a scoped
    /// one until a person answers it, then answers for it: what `applying`
    /// answered once approved and logged, or the refusal, with nothing
    /// changed. Nil for a call that is not such a change — the caller goes on
    /// to its handler.
    ///
    /// The change does not depend on this request staying open. A caller that
    /// hangs up leaves its card, an approval applies it just the same, and
    /// what it answered is kept for `GET /v1/config-changes/{id}`.
    func held(_ route: ControlRoute, _ req: HTTPServer.Request, credential: ControlCredential?, caller: String,
              applying: @escaping @MainActor () async -> HTTPServer.Response) async -> HTTPServer.Response? {
        guard holdsAgentChanges,
              ConfigChangeGate.waitsOnAPerson(route: route, method: req.method, credential: credential) else {
            return nil
        }
        let change = HeldConfigChange(caller: caller, asker: server.configChangeReader(req).key,
                                      route: "\(req.method) \(req.path)",
                                      summary: ConfigChangeSummary.text(query: req.query, body: req.body),
                                      project: heldChangeProject(req), askedAt: Date())
        let held = server.configChanges
        req.whenClientGone? { Task { @MainActor in held.callerLeft(change.id) } }
        NotificationService.shared.notifyApprovalNeeded(
            headline: "\(caller) asks to change configuration", detail: change.route,
            gate: "config-change|\(change.id)")
        let outcome = await held.outcome(of: change) {
            let response = await applying()
            return ConfigChangeOutcome.Applied(status: response.status, headers: response.headers, body: response.body)
        }
        return Self.response(to: outcome, of: change)
    }

    /// What the held request itself is sent.
    private static func response(to outcome: HeldConfigChanges.Outcome,
                                 of change: HeldConfigChange) -> HTTPServer.Response {
        switch outcome {
        case .approved(let applied):
            return HTTPServer.Response(status: applied.status, headers: applied.headers, body: applied.body)
        case .declined:
            return .error("declined by the person", status: 403)
        case .callerGone:
            return .error("the caller hung up before a person answered; the change still waits — "
                          + "read GET /v1/config-changes/\(change.id)", status: 500)
        case .unrecorded(let reason):
            return .error("approved, but the decision could not be written to the change log, "
                          + "so nothing was changed: \(reason)", status: 500)
        case .abandoned:
            return .error("Kiteloop quit before a person answered; nothing was changed", status: 500)
        }
    }

    /// A person's answer to a held change — the app's card and
    /// `POST /v1/config-changes/{id}/answer` both come through here, so both
    /// write the same log line before anything applies.
    @discardableResult
    func answer(_ id: String, approve: Bool) -> HeldConfigChanges.Answer {
        server.configChanges.answer(id, approve: approve) { _, record in
            try ConfigChangeLog.append(record, to: logURL)
        }
    }

    /// The app is quitting: every card still waiting gets its `abandoned` line.
    func abandonWaiting() {
        server.configChanges.abandonWaiting { _, record in
            try ConfigChangeLog.append(record, to: logURL)
        }
    }

    /// `GET /v1/config-changes`: the changes this reader asked for — every
    /// one, for the person.
    func list(for reader: ConfigChangeReader) -> HTTPServer.Response {
        .json(ConfigChangeReport.list(server.configChanges.outcomes(for: reader)))
    }

    /// `GET /v1/config-changes/{id}`: what became of one. Another
    /// credential's change is as unknown as one that never was.
    func outcome(_ id: String, for reader: ConfigChangeReader) -> HTTPServer.Response {
        guard let outcome = server.configChanges.outcome(id, for: reader) else {
            return .error("No configuration change \(id) is held or kept for this credential", status: 404)
        }
        return .json(ConfigChangeReport.json(outcome))
    }

    /// `POST /v1/config-changes/{id}/answer`: `{"approve": true|false}`.
    /// Reached only by a person's credential — the route is a human gate.
    func answer(_ id: String, body: Data) -> HTTPServer.Response {
        guard let approve = KiteloopControlServer.jsonBody(body)["approve"] as? NSNumber,
              CFGetTypeID(approve) == CFBooleanGetTypeID() else {
            return .error("Body must include \"approve\": true or false", status: 400)
        }
        switch answer(id, approve: approve.boolValue) {
        case .approved: return .json(["id": id, "decision": ConfigChangeLog.Decision.approved.rawValue])
        case .declined: return .json(["id": id, "decision": ConfigChangeLog.Decision.denied.rawValue])
        case .unknown: return .error("No configuration change \(id) is waiting", status: 404)
        case .unrecorded(let reason):
            return .error("The approval could not be written to the change log, so the change was refused: \(reason)",
                          status: 500)
        }
    }

    /// Where every decision is logged: the app's own directory, whichever
    /// project a change names — the line carries the project.
    var logURL: URL { ConfigChangeLog.url(appDirectory: server.configChangeLogDirectory) }

    /// The open project a call names, in its query or its body.
    private func heldChangeProject(_ req: HTTPServer.Request) -> HeldConfigChange.Project? {
        guard let named = req.query["project"] ?? KiteloopControlServer.jsonBody(req.body)["project"] as? String,
              let project = server.registry.entry(forProject: named)?.session.project else { return nil }
        return .init(id: project.id, name: project.rootURL.lastPathComponent,
                     path: project.rootURL.path(percentEncoded: false))
    }
}
