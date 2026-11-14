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
            ("GET",  "/v1/fleet/quiesce",       .fleetStatus),
            ("POST", "/v1/fleet/quiesce",       .quiesceFleet),
            ("POST", "/v1/fleet/resume",        .resumeFleet),
            ("GET",  "/v1/usage",               .usage),
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
            ("POST", "/v1/routines/brief/run",  .runRoutine(id: "brief"))
        ]
        for (method, path, route) in expected {
            XCTAssertEqual(ControlRouter.match(method: method, path: path), route,
                           "\(method) \(path) resolved to the wrong route")
        }
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
        for path in ["/v1/projects", "/v1/backlog", "/v1/runs/exec-1"] {
            XCTAssertTrue(ControlRouter.requiresAuth(method: "GET", path: path),
                          "\(path) must be behind the bearer token")
        }
        XCTAssertTrue(ControlRouter.requiresAuth(method: "GET", path: "/v1/pair"))
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
            .getAutopilot, .setAutopilot, .resetAutopilot, .pauseAutopilot, .resumeAutopilot,
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
