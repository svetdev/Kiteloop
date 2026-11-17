import Foundation
import KiteloopCore

/// The `/v1/routines` endpoints, answered from the app's routine runner.
@MainActor
struct RoutineEndpoints {
    let routines: RoutineRunner

    func answer(_ route: ControlRoute, _ req: HTTPServer.Request) -> HTTPServer.Response {
        switch route {
        case .listRoutines: return listRoutines(project: req.query["project"])
        case .listRoutineRuns: return listRoutineRuns(query: req.query)
        case .putRoutine(let id): return putRoutine(id: id, body: req.body)
        case .deleteRoutine(let id): return deleteRoutine(id: id)
        case .runRoutine(let id):
            guard routines.runNow(id) != nil else { return Self.noRoutine(id) }
            return .json(["routine": id], status: 202)
        default: return KiteloopControlServer.notThisArea(route)
        }
    }

    private static func noRoutine(_ id: String) -> HTTPServer.Response {
        .error("No routine '\(id)'", status: 404)
    }

    private func listRoutines(project: String?) -> HTTPServer.Response {
        let listed = routines.routines.filter { project == nil || $0.project == project }
        return .json(["routines": listed.map(self.listed)])
    }

    /// A routine with what only the runner knows beside it: when it next
    /// falls and how it last went.
    private func listed(_ routine: Routine) -> [String: Any] {
        var out = routine.json
        out["when"] = routine.schedule?.words ?? ""
        out["next"] = routines.next(for: routine).map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        out["lastRun"] = routines.lastRun(of: routine.id)?.json ?? NSNull()
        return out
    }

    private func listRoutineRuns(query: [String: String]) -> HTTPServer.Response {
        let limit = query["limit"].flatMap(Int.init) ?? KiteloopControlServer.transcriptWindow
        let runs = routines.runs.filter { query["routine"] == nil || $0.routine == query["routine"] }
        return .json(["runs": runs.suffix(max(0, limit)).reversed().map(\.json)])
    }

    private func putRoutine(id: String, body: Data) -> HTTPServer.Response {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let existing = routines.routines.first { $0.id == id }
        switch Routine.parse(json, id: id, existing: existing) {
        case .failure(let refusal):
            return .error(refusal.reason, status: 400)
        case .success(let routine):
            do { try routines.put(routine) } catch { return Self.notWritten(error) }
            return .json(["routine": listed(routines.routines.first { $0.id == id } ?? routine)])
        }
    }

    private func deleteRoutine(id: String) -> HTTPServer.Response {
        do {
            guard try routines.remove(id) else { return Self.noRoutine(id) }
            return .json(["removed": id])
        } catch {
            return Self.notWritten(error)
        }
    }

    private static func notWritten(_ error: Error) -> HTTPServer.Response {
        .error("The routines file could not be written: \(error.localizedDescription)", status: 500)
    }
}

/// The `/v1/hooks` endpoints: an outside service firing a routine with its
/// hook's secret, and the control token minting and revoking hooks.
@MainActor
struct RoutineHookEndpoints {
    let routines: RoutineRunner?
    let hooks: RoutineHooks?

    /// The most a webhook call may send; a body over it fires nothing.
    static let bodyLimit = 64 * 1024
    static let secretHeader = "X-Kiteloop-Hook-Secret"

    func answer(_ route: ControlRoute, _ req: HTTPServer.Request) -> HTTPServer.Response {
        guard let routines, let hooks else { return .error("This Kiteloop keeps no routine hooks", status: 503) }
        switch route {
        case .fireHook(let name): return fire(name, req, routines: routines, hooks: hooks)
        case .mintHook: return mint(body: req.body, routines: routines, hooks: hooks)
        case .revokeHook(let name):
            guard hooks.revoke(name: name) else { return .error("No hook '\(name)'", status: 404) }
            return .json(["revoked": name])
        default: return KiteloopControlServer.notThisArea(route)
        }
    }

    /// One answer for a missing secret, a wrong one and a name nobody minted,
    /// so a caller without the secret learns nothing about which hooks exist.
    private static let unauthorized = HTTPServer.Response.error("Missing or invalid hook secret", status: 401)

    private func fire(_ name: String, _ req: HTTPServer.Request,
                      routines: RoutineRunner, hooks: RoutineHooks) -> HTTPServer.Response {
        guard let secret = req.header(Self.secretHeader), let hook = hooks.hook(named: name, secret: secret) else {
            return Self.unauthorized
        }
        guard req.body.count <= Self.bodyLimit else {
            return .error("A hook's body may be at most \(Self.bodyLimit / 1024) KB", status: 413)
        }
        guard routines.runFromHook(hook.routine, hook: hook.name, body: req.body) != nil else {
            return .error("Hook '\(name)' fires routine '\(hook.routine)', which no longer exists", status: 404)
        }
        return .json(["routine": hook.routine, "hook": hook.name], status: 202)
    }

    /// `POST /v1/hooks`: `{name, routine}`, answered with the secret this once.
    private func mint(body: Data, routines: RoutineRunner, hooks: RoutineHooks) -> HTTPServer.Response {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let name = json["name"] as? String ?? ""
        let routine = json["routine"] as? String ?? ""
        guard routines.routines.contains(where: { $0.id == routine }) else {
            return .error("No routine '\(routine)'", status: 400)
        }
        switch hooks.mint(name: name, routine: routine) {
        case .failure(.invalidName):
            return .error("\"name\" must be lowercase letters, digits and hyphens", status: 400)
        case .failure(.nameTaken):
            return .error("A hook is already named '\(name)'", status: 400)
        case .success(let (secret, hook)):
            return .json(["name": hook.name, "routine": hook.routine, "secret": secret,
                          "createdAt": ISO8601DateFormatter().string(from: hook.createdAt)])
        }
    }
}

/// How a routine reaches the agent it names, and what the day lets it spend.
extension KiteloopControlServer {

    /// The agent `routine` names, or what stands between the routine and it:
    /// a fleet being held for a restart, a project that is not open, an agent
    /// nobody hired.
    func routineAgent(for routine: Routine) -> Result<RoutineAgent, Routine.Refusal> {
        if fleet.isQuiesced { return .failure(.init(problems: ["the fleet is being held for a restart"])) }
        guard let entry = registry.entry(forProject: routine.project) else {
            return .failure(.init(problems: ["project not open in Kiteloop: \(routine.project)"]))
        }
        guard let agent = Self.agent(in: entry, idOrName: routine.agent) else {
            return .failure(.init(problems: ["no agent '\(routine.agent)' in \(routine.project)"]))
        }
        let chat = entry.session.chatViewModel(for: agent.id)
        let project = entry.session.project.rootURL
        // Sent as a person typing it would. A turn it started tells the phone
        // when it ends, as a turn started from the phone does — unless it
        // stopped on a question or a plan, whose own notice says so.
        return .success(RoutineAgent(
            folder: project,
            isBusy: { chat.isStreaming },
            send: { text in
                let wasStreaming = chat.isStreaming
                let countBefore = chat.messages.count
                let costBefore = chat.costUSD
                chat.inputText = text
                await chat.send()
                guard !wasStreaming else { return RoutineTurn(reply: "", costUSD: 0) }
                let reply = Self.lastAgentReply(in: chat.messages, since: countBefore)
                if chat.waitingStatus == nil {
                    PushRelay.shared.turnFinished(project: project.lastPathComponent, agentID: agent.id,
                                                  agentName: agent.name, reply: reply)
                }
                return RoutineTurn(reply: reply, costUSD: max(0, chat.costUSD - costBefore))
            },
            startFresh: { await chat.startNewChat() }
        ))
    }

    /// Why the day's budget refuses an autonomous turn in `folder`; nil when it
    /// does not. Both ceilings apply, as they do to an autonomous run: the
    /// project's own and the portfolio's.
    func routineBudgetRefusal(folder: URL, ledger: DailySpendLedger, portfolioBudgetUSD: Double?) -> String? {
        let path = folder.path(percentEncoded: false)
        let own = registry.entry(forProject: path)?.autopilot.dailyBudgetUSD
        let budget = ProjectDailyBudget(
            project: ledger.budget(own, inProject: path, named: folder.lastPathComponent),
            portfolio: ledger.budget(portfolioBudgetUSD))
        guard case .refuse(let refusal) = budget.decision(for: .autonomous) else { return nil }
        return refusal.eventReason
    }
}
