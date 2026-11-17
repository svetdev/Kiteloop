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
    /// one until a person answers it. Nil lets the call through to its
    /// handler: it is not such a change, or it was approved and logged.
    /// Otherwise the answer the caller gets, with nothing changed.
    func refusal(_ route: ControlRoute, _ req: HTTPServer.Request,
                 credential: ControlCredential?, caller: String) async -> HTTPServer.Response? {
        guard holdsAgentChanges,
              ConfigChangeGate.waitsOnAPerson(route: route, method: req.method, credential: credential) else {
            return nil
        }
        let change = HeldConfigChange(caller: caller, route: "\(req.method) \(req.path)",
                                      summary: ConfigChangeSummary.text(query: req.query, body: req.body),
                                      project: heldChangeProject(req), askedAt: Date())
        let held = server.configChanges
        req.whenClientGone? { Task { @MainActor in held.callerLeft(change.id) } }
        NotificationService.shared.notifyApprovalNeeded(
            headline: "\(caller) asks to change configuration", detail: change.route,
            gate: "config-change|\(change.id)")
        switch await held.outcome(of: change) {
        case .approved:
            return nil
        case .declined:
            return .error("declined by the person", status: 403)
        case .callerGone:
            return .error("the caller hung up before a person answered; nothing was changed", status: 500)
        case .unrecorded(let reason):
            return .error("approved, but the decision could not be written to the change log, "
                          + "so nothing was changed: \(reason)", status: 500)
        }
    }

    /// A person's answer to a held change — the app's card and
    /// `POST /v1/config-changes/{id}/answer` both come through here, so both
    /// write the same log line before anything applies.
    @discardableResult
    func answer(_ id: String, approve: Bool) -> HeldConfigChanges.Answer {
        server.configChanges.answer(id, approve: approve) { change, record in
            try ConfigChangeLog.append(record, to: logURL)
        }
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
        case .abandoned: return .json(["id": id, "decision": ConfigChangeLog.Decision.abandoned.rawValue])
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
