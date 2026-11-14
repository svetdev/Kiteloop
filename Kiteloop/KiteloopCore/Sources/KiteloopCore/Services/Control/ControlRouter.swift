import Foundation

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

    // Fleet-wide quiesce, for a restart that strands nothing
    case fleetStatus
    case quiesceFleet
    case resumeFleet
    /// `GET /v1/usage` — the agents' rate limits and the last day's spend per project.
    case usage

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

    /// `/health` is the liveness probe a driver hits before it has a token — or to
    /// find out whether the one it has is stale — and `POST /v1/pair` is how a
    /// phone gets one, its one-time code standing in for the token. Everything
    /// else under `/v1` is behind the bearer token.
    package var requiresAuth: Bool {
        switch self {
        case .health, .claimPairingCode: return false
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
        case .approveBacklogItem, .approveRun, .landBacklogItem: return true
        default: return false
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

        Row("GET",  "/v1/fleet/quiesce")        { _ in .fleetStatus },
        Row("POST", "/v1/fleet/quiesce")        { _ in .quiesceFleet },
        Row("POST", "/v1/fleet/resume")         { _ in .resumeFleet },
        Row("GET",  "/v1/usage")                { _ in .usage },

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
        Row("POST", "/v1/runs/:id/note")        { .steerRun(runID: $0[0]) }
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
