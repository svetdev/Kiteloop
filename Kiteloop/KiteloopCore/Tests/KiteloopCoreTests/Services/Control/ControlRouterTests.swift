import XCTest
@testable import KiteloopCore

/// The control API's routing table on its own — no socket, no open project. The
/// endpoint tests each cover one route end to end; this covers the table as a
/// whole: that every documented endpoint resolves to the handler it names, that
/// run ids are captured rather than mistaken for path segments, and that a miss
/// stays a miss.
final class ControlRouterTests: XCTestCase {

    // MARK: - Every documented endpoint

    func testEveryEndpointMatchesItsRoute() {
        let expected: [(String, String, ControlRoute)] = [
            ("GET",  "/health",                 .health),
            ("GET",  "/v1/projects",            .listProjects),
            ("POST", "/v1/projects/open",       .openProject),
            ("POST", "/v1/projects/reorder",    .reorderProjects),
            ("POST", "/v1/projects/ask",        .askAboutProject),
            ("POST", "/v1/agents",              .hireAgent),
            ("PATCH", "/v1/agents",             .updateAgent),
            ("DELETE", "/v1/agents",            .removeAgent),
            ("POST", "/v1/agents/start", .manage(.startAgent)),
            ("POST", "/v1/agents/stop", .manage(.stopAgent)),
            ("POST", "/v1/agents/restart", .manage(.restartAgent)),
            ("GET", "/v1/agents/chats", .manage(.listAgentChats)),
            ("POST", "/v1/agents/chats", .manage(.newAgentChat)),
            ("POST", "/v1/agents/chats/open", .manage(.openAgentChat)),
            ("DELETE", "/v1/agents/chats", .manage(.deleteAgentChat)),
            ("POST", "/v1/projects/close", .manage(.closeProject)),
            ("GET", "/v1/projects/settings", .manage(.getProjectSettings)),
            ("GET", "/v1/projects/setup", .manage(.exportProjectSetup)),
            ("PUT", "/v1/projects/settings", .manage(.setProjectSettings)),
            ("PATCH", "/v1/backlog/items", .manage(.updateBacklogItem)),
            ("DELETE", "/v1/backlog/items", .manage(.deleteBacklogItem)),
            ("GET", "/v1/memory", .manage(.getAgentMemory)),
            ("POST", "/v1/memory/facts", .manage(.addMemoryFact)),
            ("PUT", "/v1/memory/facts", .manage(.rewriteMemoryFact)),
            ("DELETE", "/v1/memory/facts", .manage(.archiveMemoryFact)),
            ("GET", "/v1/memory/shared", .manage(.getSharedMemory)),
            ("PUT", "/v1/memory/shared", .manage(.setSharedMemory)),
            ("GET", "/v1/memory/claude", .manage(.listClaudeMemory)),
            ("PUT", "/v1/memory/claude", .manage(.putClaudeMemoryNote)),
            ("DELETE", "/v1/memory/claude", .manage(.deleteClaudeMemoryNote)),
            ("GET", "/v1/knowledge", .manage(.listKnowledge)),
            ("GET", "/v1/knowledge/file", .manage(.getKnowledgeFile)),
            ("PUT", "/v1/knowledge/file", .manage(.putKnowledgeFile)),
            ("GET", "/v1/mcp-servers", .manage(.listMCPServers)),
            ("PUT", "/v1/mcp-servers/tracker", .manage(.putMCPServer(name: "tracker"))),
            ("DELETE", "/v1/mcp-servers/tracker", .manage(.deleteMCPServer(name: "tracker"))),
            ("GET", "/v1/settings", .manage(.getSettings)),
            ("PUT", "/v1/settings", .manage(.setSettings)),
            ("GET",  "/v1/backlog",             .listBacklog),
            ("GET",  "/v1/metrics",             .listMetrics),
            ("GET",  "/v1/estimates",           .listEstimates),
            ("GET",  "/v1/grooming",            .listGrooming),
            ("GET",  "/v1/report",              .portfolioReport),
            ("POST", "/v1/backlog/approve",     .approveBacklogItem),
            ("POST", "/v1/backlog/land",        .landBacklogItem),
            ("POST", "/v1/backlog/release",     .releaseBacklogItem),
            ("POST", "/v1/backlog/refresh",     .refreshBacklogItem),
            ("POST", "/v1/backlog/groom",       .groomBacklogItem),
            ("POST", "/v1/backlog/move",        .moveBacklogItem),
            ("POST", "/v1/backlog/lane",        .setBacklogItemLane),
            ("GET", "/v1/agents",               .listAgents),
            ("POST", "/v1/agents/message",      .messageAgent),
            ("GET", "/v1/agents/transcript",    .agentTranscript),
            ("GET", "/v1/agents/events",        .agentEvents),
            ("POST", "/v1/agents/interrupt",    .interruptAgent),
            ("GET", "/v1/workspace/changes",    .workspaceChanges),
            ("POST", "/v1/pair",                .claimPairingCode),
            ("GET",  "/v1/quick-replies",       .listQuickReplies),
            ("POST", "/v1/devices/push",        .registerPushDevice),
            ("POST", "/v1/devices/activity",    .registerLiveActivity),
            ("GET", "/v1/workspace/file",       .workspaceFile),
            ("GET", "/v1/preview/screenshot",   .previewScreenshot),
            ("POST", "/v1/agents/plan",         .answerAgentPlan),
            ("POST", "/v1/agents/answer",       .answerAgentQuestion),
            ("POST", "/v1/agents/permission",   .answerAgentPermission),
            ("POST", "/v1/agents/choices",      .answerAgentChoices),
            ("POST", "/v1/agents/mode",         .setAgentMode),
            ("GET",  "/v1/agents/tasks",        .listAgentTasks),
            ("POST", "/v1/agents/tasks/stop",   .stopAgentTask),
            ("GET", "/v1/backlog/detail",       .backlogItemDetail),
            ("GET", "/v1/backlog/diff",         .backlogItemDiff),
            ("GET",  "/v1/backlog/templates",   .listTemplates),
            ("POST", "/v1/backlog/templates/stamp", .stampTemplate),
            ("POST", "/v1/backlog/items",       .fileBacklogItem),
            ("GET",  "/v1/autopilot",           .getAutopilot),
            ("PUT",  "/v1/autopilot",           .setAutopilot),
            ("POST", "/v1/autopilot/reset",     .resetAutopilot),
            ("POST", "/v1/autopilot/pause",     .pauseAutopilot),
            ("POST", "/v1/autopilot/resume",    .resumeAutopilot),
            ("GET",  "/v1/autopilot/sitting-summary", .sittingSummary),
            ("GET",  "/v1/fleet/quiesce",       .fleetStatus),
            ("POST", "/v1/fleet/quiesce",       .quiesceFleet),
            ("POST", "/v1/fleet/resume",        .resumeFleet),
            ("GET",  "/v1/usage",               .usage),
            ("GET",  "/v1/spend",               .spend),
            ("GET",  "/v1/spend/forecast",      .spendForecast),
            ("GET",  "/v1/attention",           .attention),
            ("GET",  "/v1/events",              .appEvents),
            ("GET",  "/v1/memory/proposals",    .listMemoryProposals),
            ("POST", "/v1/memory/proposals/approve", .approveMemoryProposal),
            ("POST", "/v1/memory/proposals/reject",  .rejectMemoryProposal),
            ("GET",  "/v1/coordinator/refill",  .getCoordinatorRefill),
            ("PUT",  "/v1/coordinator/refill",  .setCoordinatorRefill),
            ("GET",  "/v1/coordinator/scheduling", .getCoordinatorScheduling),
            ("PUT",  "/v1/coordinator/scheduling", .setCoordinatorScheduling),
            ("GET",  "/v1/coordinator/proposals",         .listProposals),
            ("POST", "/v1/coordinator/proposals/approve", .approveProposal),
            ("POST", "/v1/coordinator/proposals/dismiss", .dismissProposal),
            ("GET",  "/v1/openapi.json",        .openAPIDocument),
            ("POST", "/v1/runs",                .startRun),
            ("GET",  "/v1/runs",                .listRuns),
            ("GET",  "/v1/runs/exec-1",         .runStatus(runID: "exec-1")),
            ("GET",  "/v1/runs/exec-1/result",  .runResult(runID: "exec-1")),
            ("GET",  "/v1/runs/exec-1/events",  .runEvents(runID: "exec-1")),
            ("GET",  "/v1/runs/exec-1/log",     .runLog(runID: "exec-1")),
            ("POST", "/v1/runs/exec-1/approve", .approveRun(runID: "exec-1")),
            ("POST", "/v1/runs/exec-1/cancel",  .cancelRun(runID: "exec-1")),
            ("POST", "/v1/runs/exec-1/note",    .steerRun(runID: "exec-1")),
            ("POST", "/v1/projects/pin",        .pinProjectDocument),
            ("GET",  "/v1/routines",            .listRoutines),
            ("GET",  "/v1/routines/runs",       .listRoutineRuns),
            ("PUT",  "/v1/routines/brief",      .putRoutine(id: "brief")),
            ("DELETE", "/v1/routines/brief",    .deleteRoutine(id: "brief")),
            ("POST", "/v1/routines/brief/run",  .runRoutine(id: "brief")),
            ("GET",  "/v1/tokens",              .listTokens),
            ("POST", "/v1/tokens",              .mintToken),
            ("DELETE", "/v1/tokens/tok-1",      .revokeToken(id: "tok-1")),
            ("POST", "/v1/hooks/deploys",       .fireHook(name: "deploys")),
            ("POST", "/v1/hooks",               .mintHook),
            ("DELETE", "/v1/hooks/deploys",     .revokeHook(name: "deploys"))
        ]
        for (method, path, route) in expected {
            XCTAssertEqual(ControlRouter.match(method: method, path: path), route,
                           "\(method) \(path) resolved to the wrong route")
        }
    }

    // MARK: - Scopes

    /// A route of each kind carries the scope a scoped token needs for it.
    func testEachKindOfRouteCarriesItsScope() {
        let expected: [(ControlRoute, ControlScope)] = [
            (.listBacklog, .read),
            (.attention, .read),
            (.sittingSummary, .read),
            (.runStatus(runID: "r"), .read),
            (.agentTranscript, .read),
            (.startRun, .operate),
            (.messageAgent, .operate),
            (.pauseAutopilot, .operate),
            (.setAutopilot, .configure),
            (.hireAgent, .configure),
            (.putRoutine(id: "r"), .configure),
            (.mintToken, .configure),
            (.manage(.getSettings), .read),
            (.manage(.exportProjectSetup), .read),
            (.manage(.startAgent), .operate),
            (.manage(.setSettings), .configure),
            // The human gates are operate, and still refused to every scoped token.
            (.approveBacklogItem, .operate),
            (.approveRun(runID: "r"), .operate),
            (.landBacklogItem, .operate)
        ]
        for (route, scope) in expected {
            XCTAssertEqual(route.scope, scope, "\(route)")
        }
    }

    /// Scopes nest: configure includes operate, which includes read.
    func testScopesNest() {
        XCTAssertTrue(ControlScope.configure.includes(.operate))
        XCTAssertTrue(ControlScope.configure.includes(.read))
        XCTAssertTrue(ControlScope.operate.includes(.read))
        XCTAssertFalse(ControlScope.read.includes(.operate))
        XCTAssertFalse(ControlScope.operate.includes(.configure))
    }

    /// Only the /v1/tokens routes, and minting and revoking a routine's
    /// webhook, are kept to the full control token.
    func testOnlyTheTokenRoutesAreTokenManagement() {
        let managed = ControlRouter.endpoints.filter(\.route.isTokenManagement).map { "\($0.method) \($0.templatedPath)" }
        XCTAssertEqual(Set(managed), ["GET /v1/tokens", "POST /v1/tokens", "DELETE /v1/tokens/{id}",
                                      "POST /v1/hooks", "DELETE /v1/hooks/{name}"])
        XCTAssertEqual(ControlRouter.endpoints.first { $0.route == .mintToken }?.scope, .configure)
    }

    // MARK: - Run id capture

    /// Run ids are workflow execution ids (UUIDs today), but the router must not
    /// assume a shape — a capture is whatever the segment holds.
    func testRunIDIsCapturedVerbatim() {
        let id = UUID().uuidString
        XCTAssertEqual(ControlRouter.match(method: "GET", path: "/v1/runs/\(id)"),
                       .runStatus(runID: id))
        XCTAssertEqual(ControlRouter.match(method: "GET", path: "/v1/runs/\(id)/log"),
                       .runLog(runID: id))
    }

    /// A sub-path name in the id position is still an id: `/v1/runs/log` asks for
    /// the status of a run called "log", not for a log.
    func testSubPathNameInIDPositionIsAnID() {
        XCTAssertEqual(ControlRouter.match(method: "GET", path: "/v1/runs/log"),
                       .runStatus(runID: "log"))
    }

    /// Only the run collection takes an id; a stray segment elsewhere is a miss
    /// rather than being swallowed by a neighbouring route.
    func testDeeperPathsDoNotMatch() {
        for path in ["/v1/runs/exec-1/log/extra", "/v1/projects/exec-1", "/v1/autopilot/reset/now"] {
            XCTAssertNil(ControlRouter.match(method: "GET", path: path), "expected no route for \(path)")
        }
    }

    // MARK: - Misses

    func testUnknownPathHasNoRoute() {
        XCTAssertNil(ControlRouter.match(method: "GET", path: "/v1/does-not-exist"))
        XCTAssertNil(ControlRouter.match(method: "GET", path: "/"))
        XCTAssertNil(ControlRouter.match(method: "GET", path: "/v1"))
    }

    /// The right path under the wrong method is a miss, not a different route —
    /// the API answers 404, and has never distinguished 405.
    func testWrongMethodHasNoRoute() {
        XCTAssertNil(ControlRouter.match(method: "DELETE", path: "/v1/runs"))
        XCTAssertNil(ControlRouter.match(method: "POST", path: "/health"))
        XCTAssertNil(ControlRouter.match(method: "GET", path: "/v1/autopilot/reset"))
        XCTAssertNil(ControlRouter.match(method: "PUT", path: "/v1/projects"))
    }

    /// Methods are matched exactly: HTTP verbs are uppercase, and a lowercase one
    /// must not slip past the table.
    func testMethodMatchIsCaseSensitive() {
        XCTAssertNil(ControlRouter.match(method: "get", path: "/v1/projects"))
    }

    // MARK: - Path shape

    /// Empty segments are ignored, which is what the server did when it matched on
    /// `path.split(separator: "/")` inline.
    func testEmptySegmentsAreIgnored() {
        for path in ["/v1/projects/", "//v1//projects", "/v1/projects//"] {
            XCTAssertEqual(ControlRouter.match(method: "GET", path: path), .listProjects,
                           "expected \(path) to reach /v1/projects")
        }
    }

    // MARK: - Auth policy

    /// The liveness probe, and the pairing claim whose one-time code stands
    /// in for a token the phone does not have yet.
    func testOnlyHealthAndThePairingClaimAreUnauthenticated() {
        XCTAssertFalse(ControlRouter.requiresAuth(method: "GET", path: "/health"))
        XCTAssertFalse(ControlRouter.requiresAuth(method: "POST", path: "/v1/pair"))
        for path in ["/v1/projects", "/v1/backlog", "/v1/runs/exec-1", "/v1/attention"] {
            XCTAssertTrue(ControlRouter.requiresAuth(method: "GET", path: path),
                          "\(path) must be behind the bearer token")
        }
        XCTAssertTrue(ControlRouter.requiresAuth(method: "GET", path: "/v1/pair"))
    }

    /// A webhook's secret stands in for the bearer on firing it, and only
    /// there: minting and revoking hooks stay behind the token.
    func testFiringAHookIsTheOnlyHookRouteWithoutTheBearer() {
        XCTAssertFalse(ControlRouter.requiresAuth(method: "POST", path: "/v1/hooks/x"))
        XCTAssertTrue(ControlRouter.requiresAuth(method: "POST", path: "/v1/hooks"))
        XCTAssertTrue(ControlRouter.requiresAuth(method: "DELETE", path: "/v1/hooks/x"))
        XCTAssertTrue(ControlRouter.requiresAuth(method: "GET", path: "/v1/hooks/x"))
        XCTAssertEqual(ControlRoute.fireHook(name: "x").scope, .operate)
        XCTAssertEqual(ControlRoute.mintHook.scope, .configure)
        XCTAssertEqual(ControlRoute.revokeHook(name: "x").scope, .configure)
    }

    /// An unmatched path requires auth too, so an anonymous caller gets a flat 401
    /// instead of a 404 that would let them map out the API.
    func testUnmatchedPathsRequireAuth() {
        XCTAssertTrue(ControlRouter.requiresAuth(method: "GET", path: "/v1/does-not-exist"))
        XCTAssertTrue(ControlRouter.requiresAuth(method: "POST", path: "/health"))
    }

    // MARK: - Human gate

    /// Exactly the routes that resolve a human gate — the two approves, and
    /// landing a done item's branch, which is an approval's merge taken
    /// later — everything else in the table is fair game for the
    /// operator-scoped token.
    func testOnlyTheApproveAndLandRoutesAreTheHumanGate() {
        XCTAssertTrue(ControlRoute.approveBacklogItem.isHumanGate)
        XCTAssertTrue(ControlRoute.approveRun(runID: "exec-1").isHumanGate)
        XCTAssertTrue(ControlRoute.landBacklogItem.isHumanGate)

        let everythingElse: [ControlRoute] = [
            .health, .listProjects, .openProject, .reorderProjects, .hireAgent, .listBacklog,
            .listMetrics, .listEstimates, .listGrooming, .portfolioReport,
            .releaseBacklogItem, .refreshBacklogItem, .listTemplates, .stampTemplate,
            .getAutopilot, .setAutopilot, .resetAutopilot, .pauseAutopilot, .resumeAutopilot, .sittingSummary,
            .fleetStatus, .quiesceFleet, .resumeFleet,
            .getCoordinatorRefill, .setCoordinatorRefill,
            .getCoordinatorScheduling, .setCoordinatorScheduling,
            .listProposals, .approveProposal, .dismissProposal,
            .openAPIDocument, .startRun, .listRuns,
            .runStatus(runID: "exec-1"), .runResult(runID: "exec-1"),
            .runEvents(runID: "exec-1"), .runLog(runID: "exec-1"),
            .cancelRun(runID: "exec-1"), .steerRun(runID: "exec-1")
        ]
        for route in everythingElse {
            XCTAssertFalse(route.isHumanGate, "\(route) must not be the human gate")
        }
    }
}
