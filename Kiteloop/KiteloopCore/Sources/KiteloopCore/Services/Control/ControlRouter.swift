import Foundation

/// What a scoped control token may do. Every route carries one. They nest:
/// `configure` includes `operate`, which includes `read` — a token that may
/// change how the team is set up may also drive it and look at it.
package enum ControlScope: String, Codable, Sendable, CaseIterable {
    /// Look, change nothing: lists, details, diffs, transcripts, events.
    case read
    /// Drive the work: message an agent, start a run, move an item, pause.
    case operate
    /// Set the team and project up: hire, settings, autopilot, routines.
    case configure

    private var rank: Int {
        switch self {
        case .read: return 0
        case .operate: return 1
        case .configure: return 2
        }
    }

    /// Whether a token of this scope may call a route that needs `needed`.
    package func includes(_ needed: ControlScope) -> Bool {
        rank >= needed.rank
    }
}

/// Every request the control API can answer, as a value. Only what the method and
/// path say — query and body stay on the request, since the handlers read them.
package enum ControlRoute: Equatable {

    case health

    // Projects + team
    case listProjects
    case openProject
    case reorderProjects
    case askAboutProject
    /// `POST /v1/projects/pin` — the file the phone shows first for a project.
    case pinProjectDocument
    case hireAgent
    /// `PATCH /v1/agents` — change an agent already on the team.
    case updateAgent
    /// `DELETE /v1/agents` — take an agent off the team.
    case removeAgent
    /// Setting a team and its project up: sessions, chats, project settings,
    /// backlog edits, memory, knowledge and the app's settings.
    case manage(ManagementRoute)

    // Backlog + history
    case listBacklog
    case listMetrics
    case listEstimates
    case listGrooming
    case portfolioReport
    case approveBacklogItem
    /// `POST /v1/backlog/land` — merge a done item's branch that never landed.
    case landBacklogItem
    case releaseBacklogItem
    case refreshBacklogItem
    case groomBacklogItem
    case moveBacklogItem
    case setBacklogItemLane
    case listAgents
    case messageAgent
    case agentTranscript
    /// `GET /v1/agents/events` — an agent's chat as it happens (SSE).
    case agentEvents
    /// `POST /v1/pair` — a phone trading the pairing QR's one-time code for its token.
    case claimPairingCode
    /// `GET /v1/quick-replies` — the one-tap replies the phone offers in a chat.
    case listQuickReplies
    /// `POST /v1/devices/push` — a phone asking to be told when something happens.
    case registerPushDevice
    /// `POST /v1/devices/activity` — a Live Activity's push token, for one turn.
    case registerLiveActivity
    /// `GET /v1/workspace/changes` — the project's uncommitted changes.
    case workspaceChanges
    /// `GET /v1/workspace/file` — one file or folder of the project, read-only.
    case workspaceFile
    /// `GET /v1/preview/screenshot` — the web preview as a PNG.
    case previewScreenshot
    /// `POST /v1/agents/interrupt` — stop the agent's running turn.
    case interruptAgent
    /// `POST /v1/agents/plan` — answer a plan card.
    case answerAgentPlan
    /// `POST /v1/agents/answer` — answer the question the agent is waiting on.
    case answerAgentQuestion
    /// `POST /v1/agents/permission` — allow or refuse a call the session
    /// stopped to ask leave for.
    case answerAgentPermission
    /// `POST /v1/agents/choices` — answer the model's own questions.
    case answerAgentChoices
    /// `POST /v1/agents/mode` — move the agent to a permission mode.
    case setAgentMode
    /// `GET /v1/agents/tasks` — the subagents and shells a session has running.
    case listAgentTasks
    /// `POST /v1/agents/tasks/stop` — stop one of them.
    case stopAgentTask
    case backlogItemDetail
    case backlogItemDiff
    case listTemplates
    case stampTemplate
    /// `POST /v1/backlog/items` — file one new item as a draft, groomed on request.
    case fileBacklogItem

    // Autopilot config + queue
    case getAutopilot
    case setAutopilot
    case resetAutopilot
    case pauseAutopilot
    case resumeAutopilot
    /// `GET /v1/autopilot/sitting-summary` — what a project's last sitting of
    /// runs landed, what stalled and what it spent.
    case sittingSummary

    // Fleet-wide quiesce, for a restart that strands nothing
    case fleetStatus
    case quiesceFleet
    case resumeFleet
    /// `GET /v1/usage` — the agents' rate limits and the last day's spend per project.
    case usage
    /// `GET /v1/spend` — the spend ledger over a window, grouped by agent,
    /// project, routine, model or day.
    case spend
    /// `GET /v1/spend/forecast` — what each routine's next run and each
    /// project's month will probably cost, read off the spend ledger.
    case spendForecast
    /// `GET /v1/attention` — everything waiting on a person across every open
    /// project, oldest first: the waiting drawer's list, each row naming the
    /// call that answers it.
    case attention
    /// `GET /v1/events` — every open project's inbox notices as one SSE stream.
    case appEvents
    /// `POST /v1/config-changes/{id}/answer` — approve or decline a
    /// configuration change an agent asked for over this API.
    case answerConfigChange(id: String)

    // Memory
    case listMemoryProposals
    case approveMemoryProposal
    case rejectMemoryProposal

    // Coordinator
    case getCoordinatorRefill
    case setCoordinatorRefill
    case getCoordinatorScheduling
    case setCoordinatorScheduling
    case listProposals
    case approveProposal
    case dismissProposal

    // Routines
    /// `GET /v1/routines` — every routine, when it next falls and how it last went.
    case listRoutines
    /// `GET /v1/routines/runs` — the ledger of firings.
    case listRoutineRuns
    /// `PUT /v1/routines/{id}` — add a routine, or replace the one with this id.
    case putRoutine(id: String)
    /// `DELETE /v1/routines/{id}`.
    case deleteRoutine(id: String)
    /// `POST /v1/routines/{id}/run` — send its prompt now.
    case runRoutine(id: String)

    // Description
    case openAPIDocument

    // Runs
    case startRun
    case listRuns
    case runStatus(runID: String)
    case runResult(runID: String)
    case runEvents(runID: String)
    case runLog(runID: String)
    case approveRun(runID: String)
    case cancelRun(runID: String)
    case steerRun(runID: String)

    // Scoped tokens
    /// `GET /v1/tokens` — the scoped tokens, never their hashes.
    case listTokens
    /// `POST /v1/tokens` — mint one; its plaintext is in this answer only.
    case mintToken
    /// `DELETE /v1/tokens/{id}` — revoke one.
    case revokeToken(id: String)

    // Routine webhooks
    /// `POST /v1/hooks/{name}` — an outside service firing a routine, its
    /// hook's secret standing in for the bearer token.
    case fireHook(name: String)
    /// `POST /v1/hooks` — give a routine a webhook; its secret is in this answer only.
    case mintHook
    /// `DELETE /v1/hooks/{name}` — revoke a webhook.
    case revokeHook(name: String)

    /// `/health` is the liveness probe a driver hits before it has a token — or to
    /// find out whether the one it has is stale — and `POST /v1/pair` is how a
    /// phone gets one, its one-time code standing in for the token, and
    /// `POST /v1/hooks/{name}` is how an outside service fires a routine, its
    /// hook's secret standing in for it. Everything else under `/v1` is behind
    /// the bearer token.
    package var requiresAuth: Bool {
        switch self {
        case .health, .claimPairingCode, .fireHook: return false
        default: return true
        }
    }

    /// Whether this route resolves a human gate — `POST /v1/backlog/approve`,
    /// `POST /v1/runs/{id}/approve` and `POST /v1/backlog/land`, which is the
    /// merge half of an approval taken later. The operator-scoped token
    /// authorizes everything else the API does; these stay a person's call,
    /// since an agent that could clear its own team's gate, or land its own
    /// branch, collapses the sandbox → PR → human-gate model (ADR-0001).
    package var isHumanGate: Bool {
        switch self {
        case .approveBacklogItem, .approveRun, .landBacklogItem, .answerConfigChange: return true
        default: return false
        }
    }

    /// Whether this route mints, lists or revokes scoped tokens or routine
    /// webhooks — which only the full control token may do, so no narrower
    /// credential can mint a wider one.
    package var isTokenManagement: Bool {
        switch self {
        case .listTokens, .mintToken, .revokeToken, .mintHook, .revokeHook: return true
        default: return false
        }
    }

    /// The scope a scoped token needs to call this route. Exhaustive with no
    /// `default:`, so a route added without a scope is a compile error.
    package var scope: ControlScope {
        switch self {
        case .health, .listProjects, .listAgents, .agentTranscript, .agentEvents,
             .listQuickReplies, .workspaceChanges, .workspaceFile, .previewScreenshot,
             .listAgentTasks, .backlogItemDetail, .backlogItemDiff, .listTemplates,
             .listBacklog, .listMetrics, .listEstimates, .listGrooming, .portfolioReport,
             .getAutopilot, .sittingSummary, .fleetStatus, .usage, .spend, .spendForecast, .attention, .appEvents, .listMemoryProposals,
             .getCoordinatorRefill, .getCoordinatorScheduling, .listProposals,
             .listRoutines, .listRoutineRuns, .openAPIDocument,
             .listRuns, .runStatus, .runResult, .runEvents, .runLog:
            return .read
        case .openProject, .askAboutProject, .messageAgent, .interruptAgent,
             .answerAgentPlan, .answerAgentQuestion, .answerAgentPermission, .answerAgentChoices,
             .setAgentMode, .stopAgentTask,
             .approveBacklogItem, .landBacklogItem, .releaseBacklogItem, .refreshBacklogItem,
             .groomBacklogItem, .moveBacklogItem, .setBacklogItemLane, .fileBacklogItem,
             .pauseAutopilot, .resumeAutopilot, .quiesceFleet, .resumeFleet,
             .approveMemoryProposal, .rejectMemoryProposal, .approveProposal, .dismissProposal,
             .runRoutine, .fireHook, .startRun, .approveRun, .cancelRun, .steerRun,
             .answerConfigChange:
            return .operate
        case .reorderProjects, .pinProjectDocument, .hireAgent, .updateAgent, .removeAgent,
             .claimPairingCode, .registerPushDevice, .registerLiveActivity, .stampTemplate,
             .setAutopilot, .resetAutopilot, .setCoordinatorRefill, .setCoordinatorScheduling,
             .putRoutine, .deleteRoutine, .listTokens, .mintToken, .revokeToken,
             .mintHook, .revokeHook:
            return .configure
        case .manage(let managed):
            return managed.scope
        }
    }
}

/// The control API's routing table, split out of `KiteloopControlServer` so that
/// matching is a pure function of method and path: testable without binding a
/// port, opening a project or touching app state. The server keeps the handlers
/// and switches on what this returns.
///
/// Paths are compared segment by segment, so empty segments — a trailing slash,
/// `//v1//projects` — are ignored.
package enum ControlRouter {

    /// The control API's version as a whole number, reported by `/health` so a
    /// phone can tell a Mac that lacks what it calls from a broken one. Raised
    /// whenever an endpoint the phone calls is added or changes shape — the
    /// same change that adds or edits a row in `KiteloopMobile/README.md` —
    /// and the phone's `APICompatibility.phoneVersion` raised with it.
    package static let apiVersion = 3

    /// The route for a request, or `nil` when nothing matches (the server answers
    /// 404). A path that exists under another method is a miss like any other:
    /// the API has never distinguished 405 from 404.
    package static func match(method: String, path: String) -> ControlRoute? {
        let parts = segments(path)
        for row in table where row.method == method {
            if let captures = row.captures(parts) { return row.make(captures) }
        }
        return nil
    }

    /// Whether a request must carry the bearer token. Unmatched paths require it
    /// too, so an anonymous caller gets a flat 401 rather than a 404 that would
    /// let them map out which routes exist.
    package static func requiresAuth(method: String, path: String) -> Bool {
        match(method: method, path: path)?.requiresAuth ?? true
    }

    // MARK: - The table as data

    /// One endpoint of the API, as the table declares it. This is what lets the
    /// OpenAPI document in `ControlAPISpec` be *derived* from the routing table
    /// rather than written alongside it: a second hand-maintained list of paths
    /// would drift from this one, which is the whole failure a machine-readable
    /// description is meant to prevent.
    package struct Endpoint: Sendable {
        /// The HTTP method, uppercase, exactly as the table matches it.
        package let method: String
        /// The pattern as written in the table, with `:name` capture segments —
        /// e.g. `/v1/runs/:id`.
        package let path: String
        /// The route this row builds. Capture segments are filled with their own
        /// parameter names, so the *case* is meaningful (it carries the auth
        /// policy) while the associated value is a placeholder, not a real id.
        package let route: ControlRoute

        /// The path with capture segments in OpenAPI's templating — `/v1/runs/{id}`.
        package var templatedPath: String {
            "/" + ControlRouter.segments(path)
                .map { $0.hasPrefix(":") ? "{\($0.dropFirst())}" : $0 }
                .joined(separator: "/")
        }

        /// The names of the capture segments, in the order they appear.
        package var pathParameters: [String] {
            ControlRouter.segments(path).filter { $0.hasPrefix(":") }.map { String($0.dropFirst()) }
        }

        package var requiresAuth: Bool { route.requiresAuth }

        /// The scope a scoped token needs to call this endpoint.
        package var scope: ControlScope { route.scope }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(method: String, path: String, route: ControlRoute) {
            self.method = method
            self.path = path
            self.route = route
        }
    }

    /// Every endpoint the API answers, in table order.
    package static var endpoints: [Endpoint] { table.map(\.endpoint) }

    // MARK: - Table

    private static let table: [Row] = [
        Row("GET",  "/health")                  { _ in .health },

        Row("GET",  "/v1/projects")             { _ in .listProjects },
        Row("POST", "/v1/projects/open")        { _ in .openProject },
        Row("POST", "/v1/projects/reorder")     { _ in .reorderProjects },
        Row("POST", "/v1/projects/ask")         { _ in .askAboutProject },
        Row("POST", "/v1/projects/pin")         { _ in .pinProjectDocument },
        Row("POST", "/v1/agents")               { _ in .hireAgent },
        Row("GET", "/v1/agents")                { _ in .listAgents },
        Row("PATCH", "/v1/agents")              { _ in .updateAgent },
        Row("DELETE", "/v1/agents")             { _ in .removeAgent },
        Row("POST", "/v1/agents/message")       { _ in .messageAgent },
        Row("GET", "/v1/agents/transcript")     { _ in .agentTranscript },
        Row("GET", "/v1/agents/events")         { _ in .agentEvents },
        Row("POST", "/v1/agents/interrupt")     { _ in .interruptAgent },
        Row("GET", "/v1/workspace/changes")     { _ in .workspaceChanges },
        Row("POST", "/v1/pair")                 { _ in .claimPairingCode },
        Row("GET",  "/v1/quick-replies")        { _ in .listQuickReplies },
        Row("POST", "/v1/devices/push")         { _ in .registerPushDevice },
        Row("POST", "/v1/devices/activity")     { _ in .registerLiveActivity },
        Row("GET", "/v1/workspace/file")        { _ in .workspaceFile },
        Row("GET", "/v1/preview/screenshot")    { _ in .previewScreenshot },
        Row("POST", "/v1/agents/plan")          { _ in .answerAgentPlan },
        Row("POST", "/v1/agents/answer")        { _ in .answerAgentQuestion },
        Row("POST", "/v1/agents/permission")    { _ in .answerAgentPermission },
        Row("POST", "/v1/agents/choices")       { _ in .answerAgentChoices },
        Row("POST", "/v1/agents/mode")          { _ in .setAgentMode },
        Row("GET",  "/v1/agents/tasks")         { _ in .listAgentTasks },
        Row("POST", "/v1/agents/tasks/stop")    { _ in .stopAgentTask },
        Row("GET", "/v1/backlog/detail")        { _ in .backlogItemDetail },
        Row("GET", "/v1/backlog/diff")          { _ in .backlogItemDiff },

        Row("GET",  "/v1/backlog")              { _ in .listBacklog },
        Row("GET",  "/v1/metrics")              { _ in .listMetrics },
        Row("GET",  "/v1/estimates")            { _ in .listEstimates },
        Row("GET",  "/v1/grooming")             { _ in .listGrooming },
        Row("GET",  "/v1/report")               { _ in .portfolioReport },
        Row("POST", "/v1/backlog/approve")      { _ in .approveBacklogItem },
        Row("POST", "/v1/backlog/land")         { _ in .landBacklogItem },
        Row("POST", "/v1/backlog/release")      { _ in .releaseBacklogItem },
        Row("POST", "/v1/backlog/refresh")      { _ in .refreshBacklogItem },
        Row("POST", "/v1/backlog/move")         { _ in .moveBacklogItem },
        Row("POST", "/v1/backlog/lane")         { _ in .setBacklogItemLane },
        Row("POST", "/v1/backlog/groom")        { _ in .groomBacklogItem },
        Row("GET",  "/v1/backlog/templates")    { _ in .listTemplates },
        Row("POST", "/v1/backlog/templates/stamp") { _ in .stampTemplate },
        Row("POST", "/v1/backlog/items")        { _ in .fileBacklogItem },

        Row("GET",  "/v1/autopilot")            { _ in .getAutopilot },
        Row("PUT",  "/v1/autopilot")            { _ in .setAutopilot },
        Row("POST", "/v1/autopilot/reset")      { _ in .resetAutopilot },
        Row("POST", "/v1/autopilot/pause")      { _ in .pauseAutopilot },
        Row("POST", "/v1/autopilot/resume")     { _ in .resumeAutopilot },
        Row("GET",  "/v1/autopilot/sitting-summary") { _ in .sittingSummary },

        Row("GET",  "/v1/fleet/quiesce")        { _ in .fleetStatus },
        Row("POST", "/v1/fleet/quiesce")        { _ in .quiesceFleet },
        Row("POST", "/v1/fleet/resume")         { _ in .resumeFleet },
        Row("GET",  "/v1/usage")                { _ in .usage },
        Row("GET",  "/v1/spend")                { _ in .spend },
        Row("GET",  "/v1/spend/forecast")       { _ in .spendForecast },
        Row("GET",  "/v1/attention")            { _ in .attention },
        Row("GET",  "/v1/events")               { _ in .appEvents },
        Row("POST", "/v1/config-changes/:id/answer") { .answerConfigChange(id: $0[0]) },

        Row("GET",  "/v1/memory/proposals")             { _ in .listMemoryProposals },
        Row("POST", "/v1/memory/proposals/approve")     { _ in .approveMemoryProposal },
        Row("POST", "/v1/memory/proposals/reject")      { _ in .rejectMemoryProposal },

        Row("GET",  "/v1/coordinator/refill")   { _ in .getCoordinatorRefill },
        Row("PUT",  "/v1/coordinator/refill")   { _ in .setCoordinatorRefill },
        Row("GET",  "/v1/coordinator/scheduling") { _ in .getCoordinatorScheduling },
        Row("PUT",  "/v1/coordinator/scheduling") { _ in .setCoordinatorScheduling },
        Row("GET",  "/v1/coordinator/proposals")         { _ in .listProposals },
        Row("POST", "/v1/coordinator/proposals/approve") { _ in .approveProposal },
        Row("POST", "/v1/coordinator/proposals/dismiss") { _ in .dismissProposal },

        Row("POST", "/v1/agents/start") { _ in .manage(.startAgent) },
        Row("POST", "/v1/agents/stop") { _ in .manage(.stopAgent) },
        Row("POST", "/v1/agents/restart") { _ in .manage(.restartAgent) },
        Row("GET", "/v1/agents/chats") { _ in .manage(.listAgentChats) },
        Row("POST", "/v1/agents/chats") { _ in .manage(.newAgentChat) },
        Row("POST", "/v1/agents/chats/open") { _ in .manage(.openAgentChat) },
        Row("DELETE", "/v1/agents/chats") { _ in .manage(.deleteAgentChat) },
        Row("POST", "/v1/projects/close") { _ in .manage(.closeProject) },
        Row("GET", "/v1/projects/settings") { _ in .manage(.getProjectSettings) },
        Row("GET", "/v1/projects/setup") { _ in .manage(.exportProjectSetup) },
        Row("PUT", "/v1/projects/settings") { _ in .manage(.setProjectSettings) },
        Row("PATCH", "/v1/backlog/items") { _ in .manage(.updateBacklogItem) },
        Row("DELETE", "/v1/backlog/items") { _ in .manage(.deleteBacklogItem) },
        Row("GET", "/v1/memory") { _ in .manage(.getAgentMemory) },
        Row("POST", "/v1/memory/facts") { _ in .manage(.addMemoryFact) },
        Row("PUT", "/v1/memory/facts") { _ in .manage(.rewriteMemoryFact) },
        Row("DELETE", "/v1/memory/facts") { _ in .manage(.archiveMemoryFact) },
        Row("GET", "/v1/memory/shared") { _ in .manage(.getSharedMemory) },
        Row("PUT", "/v1/memory/shared") { _ in .manage(.setSharedMemory) },
        Row("GET", "/v1/memory/claude") { _ in .manage(.listClaudeMemory) },
        Row("PUT", "/v1/memory/claude") { _ in .manage(.putClaudeMemoryNote) },
        Row("DELETE", "/v1/memory/claude") { _ in .manage(.deleteClaudeMemoryNote) },
        Row("GET", "/v1/knowledge") { _ in .manage(.listKnowledge) },
        Row("GET", "/v1/knowledge/file") { _ in .manage(.getKnowledgeFile) },
        Row("PUT", "/v1/knowledge/file") { _ in .manage(.putKnowledgeFile) },
        Row("GET", "/v1/mcp-servers") { _ in .manage(.listMCPServers) },
        Row("PUT", "/v1/mcp-servers/:name") { .manage(.putMCPServer(name: $0[0])) },
        Row("DELETE", "/v1/mcp-servers/:name") { .manage(.deleteMCPServer(name: $0[0])) },
        Row("GET", "/v1/settings") { _ in .manage(.getSettings) },
        Row("PUT", "/v1/settings") { _ in .manage(.setSettings) },

        Row("GET",  "/v1/routines")             { _ in .listRoutines },
        Row("GET",  "/v1/routines/runs")        { _ in .listRoutineRuns },
        Row("PUT",  "/v1/routines/:id")         { .putRoutine(id: $0[0]) },
        Row("DELETE", "/v1/routines/:id")       { .deleteRoutine(id: $0[0]) },
        Row("POST", "/v1/routines/:id/run")     { .runRoutine(id: $0[0]) },

        Row("GET",  "/v1/openapi.json")         { _ in .openAPIDocument },

        Row("POST", "/v1/runs")                 { _ in .startRun },
        Row("GET",  "/v1/runs")                 { _ in .listRuns },
        Row("GET",  "/v1/runs/:id")             { .runStatus(runID: $0[0]) },
        Row("GET",  "/v1/runs/:id/result")      { .runResult(runID: $0[0]) },
        Row("GET",  "/v1/runs/:id/events")      { .runEvents(runID: $0[0]) },
        Row("GET",  "/v1/runs/:id/log")         { .runLog(runID: $0[0]) },
        Row("POST", "/v1/runs/:id/approve")     { .approveRun(runID: $0[0]) },
        Row("POST", "/v1/runs/:id/cancel")      { .cancelRun(runID: $0[0]) },
        Row("POST", "/v1/runs/:id/note")        { .steerRun(runID: $0[0]) },

        Row("GET",  "/v1/tokens")               { _ in .listTokens },
        Row("POST", "/v1/tokens")               { _ in .mintToken },
        Row("DELETE", "/v1/tokens/:id")         { .revokeToken(id: $0[0]) },

        Row("POST", "/v1/hooks/:name")          { .fireHook(name: $0[0]) },
        Row("POST", "/v1/hooks")                { _ in .mintHook },
        Row("DELETE", "/v1/hooks/:name")        { .revokeHook(name: $0[0]) }
    ]

    /// One row of the table: a method, a path pattern whose `:` segments capture,
    /// and how to build the route from those captures. Order between rows doesn't
    /// matter — no two rows match the same request.
    private struct Row: Sendable {
        let method: String
        let path: String
        let pattern: [String]
        let make: @Sendable ([String]) -> ControlRoute

        init(_ method: String, _ path: String, _ make: @escaping @Sendable ([String]) -> ControlRoute) {
            self.method = method
            self.path = path
            self.pattern = ControlRouter.segments(path)
            self.make = make
        }

        /// The row as data. The route is built with each capture set to its own
        /// parameter name — nothing reads those values, and building the route is
        /// how the endpoint gets its auth policy from the same source `match` does.
        var endpoint: Endpoint {
            Endpoint(method: method, path: path,
                     route: make(pattern.filter { $0.hasPrefix(":") }.map { String($0.dropFirst()) }))
        }

        /// The captured segments when `parts` fits this pattern, else `nil`.
        func captures(_ parts: [String]) -> [String]? {
            guard parts.count == pattern.count else { return nil }
            var captured: [String] = []
            for (expected, actual) in zip(pattern, parts) {
                if expected.hasPrefix(":") {
                    captured.append(actual)
                } else if expected != actual {
                    return nil
                }
            }
            return captured
        }
    }

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}
