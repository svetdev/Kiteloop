import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/autopilot/pause` and `POST /v1/autopilot/resume` — the headless
/// equivalent of the Autopilot tab's pause/resume buttons, exercised over a real
/// loopback socket. Before these, a driver could start a run through the API but
/// had to reach for the UI to hold the queue.
@MainActor
final class KiteloopControlServerPauseResumeTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private let token = "control-pause-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-pause")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Pause

    /// The happy path for a driver that wants the queue held: an autopilot that
    /// isn't idle answers 200 and reports the state it landed in.
    func testPauseHoldsAQueueThatIsNotIdle() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }

        let (status, body) = try await harness.post("/v1/autopilot/pause", ["project": "alpha"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        XCTAssertEqual(body["autopilot"] as? String, "paused")
        XCTAssertEqual(autopilot.status, .paused)
    }

    /// Retrying a pause after a dropped connection must not fail — the caller
    /// can't tell whether the first request landed, so the second is a no-op.
    func testPauseIsIdempotent() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        let logCountBefore = autopilot.log.count

        let (first, _) = try await harness.post("/v1/autopilot/pause", ["project": "alpha"])
        let (second, body) = try await harness.post("/v1/autopilot/pause", ["project": "alpha"])

        XCTAssertEqual(first, 200)
        XCTAssertEqual(second, 200)
        XCTAssertEqual(body["autopilot"] as? String, "paused")
        XCTAssertEqual(autopilot.status, .paused)
        // An already-paused autopilot isn't re-paused, so nothing is logged.
        XCTAssertEqual(autopilot.log.count, logCountBefore)
    }

    /// Pausing an idle autopilot is a caller mistake, not a silent success: there
    /// is no queue to hold, and a 200 here would read as "the run is stopped".
    func testPauseWhenIdleIs409() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.post("/v1/autopilot/pause", ["project": "alpha"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Autopilot is not running for this project")
        XCTAssertEqual(autopilot.status, .idle)
    }

    /// Pausing one project must not hold another open project's queue.
    func testPauseLeavesOtherProjectsRunning() async throws {
        try registerProject(named: "alpha") { $0.pause() }
        let beta = try registerProject(named: "beta", configure: { _ in })

        let (status, _) = try await harness.post("/v1/autopilot/pause", ["project": "alpha"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(beta.status, .idle)
    }

    // MARK: - Resume

    /// Resume answers 202 rather than 200: the remaining queue runs in the
    /// background, so the response says "picked up", not "finished".
    func testResumePicksTheQueueBackUp() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }

        let (status, body) = try await harness.post("/v1/autopilot/resume", ["project": "alpha"])

        XCTAssertEqual(status, 202)
        XCTAssertEqual(body["project"] as? String, "alpha")
        XCTAssertEqual(body["autopilot"] as? String, "resuming")
        // The work is kicked off after the response is written, so wait for the
        // autopilot to record that it resumed.
        try await eventually("the autopilot to log that it resumed") {
            await autopilot.log.contains { $0.message == "Resumed" }
        }
    }

    /// Only a paused autopilot can be resumed, and the error names the state the
    /// caller is actually in so a driver can decide what to do next.
    func testResumeWhenNotPausedIs409() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.post("/v1/autopilot/resume", ["project": "alpha"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(
            body["error"] as? String,
            "Autopilot is not paused for this project (status: idle)"
        )
    }

    /// Resuming one project must not restart another paused project's queue.
    func testResumeLeavesOtherProjectsPaused() async throws {
        try registerProject(named: "alpha") { $0.pause() }
        let beta = try registerProject(named: "beta") { $0.pause() }

        let (status, _) = try await harness.post("/v1/autopilot/resume", ["project": "alpha"])

        XCTAssertEqual(status, 202)
        XCTAssertEqual(beta.status, .paused)
        XCTAssertFalse(beta.log.contains { $0.message == "Resumed" })
    }

    /// The gap this item closes: a project held only by the fleet board's
    /// paused switch — the autopilot's own status is `idle`, so the old
    /// `status == .paused` guard 409'd forever, and nothing on the control API
    /// could clear the switch. There is no queue to pick back up here, so this
    /// answers 200 rather than 202, and a run started right after actually starts.
    func testResumeLiftsAProjectPausedOnTheFleetBoard() async throws {
        let autopilot = try registerProject(
            named: "alpha",
            items: ["- [ ] item-1 | Fully groomed | ready | size: S → [detail](backlog/item-1.md)"],
            details: ["backlog/item-1.md": groomedDetail(id: "item-1")],
            configure: { _ in }
        )
        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))
        try entry.session.project.setPaused(true, goal: nil)

        let (status, body) = try await harness.post("/v1/autopilot/resume", ["project": "alpha"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        XCTAssertEqual(body["resumed"] as? String, "paused")
        XCTAssertFalse(entry.session.project.isPaused)
        XCTAssertEqual(autopilot.status, .idle,
                       "the fleet board's switch alone never touches the autopilot's own status")

        try await startAgentSessions(forProject: "alpha")
        let (runStatus, runBody) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])
        XCTAssertEqual(runStatus, 202, "\(runBody)")
    }

    /// A project paused both ways is lifted both ways in the one call: the
    /// switch reads unpaused afterwards, and the autopilot's own queue picks
    /// back up too.
    func testResumeLiftsAProjectPausedBothWays() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))
        try entry.session.project.setPaused(true, goal: nil)

        let (status, body) = try await harness.post("/v1/autopilot/resume", ["project": "alpha"])

        XCTAssertEqual(status, 202)
        XCTAssertEqual(body["resumed"] as? String, "both")
        XCTAssertFalse(entry.session.project.isPaused)
        try await eventually("the autopilot to log that it resumed") {
            await autopilot.log.contains { $0.message == "Resumed" }
        }
    }

    /// The remedy `testRunIsRefusedForAProjectPausedOnTheFleetBoard` names now
    /// actually works, end to end: refused, resumed, then started.
    func testResumeAfterAPausedSwitchRefusalLetsTheRunStart() async throws {
        try registerProject(
            named: "alpha",
            items: ["- [ ] item-1 | Fully groomed | ready | size: S → [detail](backlog/item-1.md)"],
            details: ["backlog/item-1.md": groomedDetail(id: "item-1")],
            configure: { _ in }
        )
        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))
        try entry.session.project.setPaused(true, goal: nil)

        let (refusedStatus, refusedBody) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])
        XCTAssertEqual(refusedStatus, 409)
        let error = try XCTUnwrap(refusedBody["error"] as? String)
        XCTAssertTrue(error.contains("POST /v1/autopilot/resume"), error)

        let (resumeStatus, _) = try await harness.post("/v1/autopilot/resume", ["project": "alpha"])
        XCTAssertEqual(resumeStatus, 200)

        try await startAgentSessions(forProject: "alpha")
        let (runStatus, runBody) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])
        XCTAssertEqual(runStatus, 202, "\(runBody)")
    }

    // MARK: - POST /v1/runs refuses a paused project

    /// The gap this item closes: a held queue used to be no obstacle at all to
    /// `POST /v1/runs`, which never consulted the autopilot's status. Now
    /// pausing is one act, and the refusal names the way out the same sentence
    /// the fleet-wide quiesce refusal does.
    func testRunIsRefusedForAProjectWhoseAutopilotIsPaused() async throws {
        try registerProject(named: "alpha") { $0.pause() }

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409)
        let error = try XCTUnwrap(body["error"] as? String)
        XCTAssertTrue(error.contains("paused"), error)
        XCTAssertTrue(error.contains("POST /v1/autopilot/resume"), error)
    }

    /// The other cause of the same hard stop: a project a human parked with the
    /// paused switch on the fleet board, whose autopilot was never touched at
    /// all (still `idle`). `startRun` has to read both, not only its own status.
    func testRunIsRefusedForAProjectPausedOnTheFleetBoard() async throws {
        try registerProject(named: "alpha", configure: { _ in })
        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))
        try entry.session.project.setPaused(true, goal: nil)

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409)
        let error = try XCTUnwrap(body["error"] as? String)
        XCTAssertTrue(error.contains("paused"), error)
        XCTAssertTrue(error.contains("POST /v1/autopilot/resume"), error)
        XCTAssertEqual(entry.autopilot.status, .idle,
                       "the fleet board's switch alone never touches the autopilot's own status")
    }

    /// A project that has stated nothing, and whose autopilot is merely
    /// running, is not paused — the refusal must not fire on every project.
    func testRunIsNotRefusedForAnUnpausedProject() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertNotEqual(status, 409, "\(body)")
    }

    // MARK: - A human Run is refused the same way

    /// The Autopilot tab's Run button calls `BacklogAutopilot.start()` directly
    /// and never reaches this control server — so the gate has to live in
    /// `start()` too, refusing with the same substance: paused, and a resume is
    /// the way out.
    func testAHumanStartIsRefusedForAHeldQueue() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }

        await autopilot.start()

        let outcome = try XCTUnwrap(autopilot.lastStartOutcome)
        XCTAssertEqual(outcome.refusal, .paused)
        XCTAssertTrue(outcome.detail.contains("paused"), outcome.detail)
        XCTAssertTrue(outcome.detail.contains("resume"), outcome.detail)
        XCTAssertTrue(autopilot.log.contains { $0.message == "Cannot start: \(outcome.detail)" },
                      "the refusal is narrated as well as recorded")
    }

    /// And the fleet board's switch refuses a human start too —
    /// `isProjectPaused` is read fresh on every `start()`, since flipping the
    /// switch while the project sits idle never touches `status`.
    func testAHumanStartIsRefusedForAProjectPausedOnTheFleetBoard() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        autopilot.isProjectPaused = { true }

        await autopilot.start()

        let outcome = try XCTUnwrap(autopilot.lastStartOutcome)
        XCTAssertEqual(outcome.refusal, .paused)
        XCTAssertEqual(autopilot.status, .idle, "no execution was minted, so status is untouched")
    }

    // MARK: - The hold outlives the item it was taken over

    /// The bug a driver hit: pausing lands at the next item boundary, and for
    /// the one-item queues every scheduler start makes there is no next boundary
    /// — the finishing run wrote `idle` over the pause, so the hold lasted
    /// exactly as long as the item it was meant to outlive. Read back through
    /// `GET /v1/autopilot`, which is where a driver polls for it.
    func testAutopilotReadsPausedAfterTheItemInFlightFinishes() async throws {
        let autopilot = try registerProject(named: "alpha") { autopilot in
            autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [heldItem()])
            autopilot.stageExecutingRunForTesting(true)
        }

        let (pauseStatus, _) = try await harness.post("/v1/autopilot/pause", ["project": "alpha"])
        XCTAssertEqual(pauseStatus, 200)

        // The item in flight reaches its gate and the run loop ends.
        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        let (status, body) = try await harness.get("/v1/autopilot?project=alpha")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["paused"] as? Bool, true, "the hold outlives the run it interrupted")
        let run = try XCTUnwrap(body["run"] as? [String: Any])
        XCTAssertEqual(run["state"] as? String, "held")
        XCTAssertEqual(run["heldItems"] as? Int, 0)
    }

    /// And it is still a hard stop between items, not only during one: a run
    /// requested for the held project is refused, naming the resume.
    func testARunIsRefusedForAProjectHeldBetweenItems() async throws {
        let autopilot = try registerProject(
            named: "alpha",
            items: ["- [ ] item-1 | Fully groomed | ready | size: S → [detail](backlog/item-1.md)"],
            details: ["backlog/item-1.md": groomedDetail(id: "item-1")]
        ) { autopilot in
            autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [heldItem()])
            autopilot.stageExecutingRunForTesting(true)
            autopilot.pause()
        }
        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409)
        let error = try XCTUnwrap(body["error"] as? String)
        XCTAssertTrue(error.contains("POST /v1/autopilot/resume"), error)
    }

    /// The remedy, end to end: resume lifts the hold that outlived the run, and
    /// the project reads unheld again.
    func testResumeLiftsAHoldThatOutlivedItsRun() async throws {
        let autopilot = try registerProject(named: "alpha") { autopilot in
            autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [heldItem()])
            autopilot.stageExecutingRunForTesting(true)
            autopilot.pause()
        }
        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        let (status, body) = try await harness.post("/v1/autopilot/resume", ["project": "alpha"])

        XCTAssertEqual(status, 202)
        XCTAssertEqual(body["resumed"] as? String, "autopilot")
        try await eventually("the hold to be lifted") { await !autopilot.isHoldingQueue }
        let (_, after) = try await harness.get("/v1/autopilot?project=alpha")
        XCTAssertEqual(after["paused"] as? Bool, false)
    }

    /// An idle project is unheld, and `GET /v1/autopilot` says so — the field
    /// is always there, never omitted for the ordinary case.
    func testAutopilotReadsUnpausedForAnIdleProject() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["paused"] as? Bool, false)
    }

    // MARK: - GET /v1/projects reports `paused`

    /// `GET /v1/projects` is where a driver — or the fleet board — reads this
    /// state back, and it has to agree with what actually refuses a run.
    func testProjectsListReportsPausedForAHeldAutopilotQueue() async throws {
        try registerProject(named: "alpha") { $0.pause() }
        try registerProject(named: "beta", configure: { _ in })

        let (status, body) = try await harness.get("/v1/projects")
        let projects = try XCTUnwrap(body["projects"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: projects.map { ($0["name"] as? String ?? "", $0) })

        XCTAssertEqual(status, 200)
        XCTAssertEqual(byName["alpha"]?["paused"] as? Bool, true)
        XCTAssertEqual(byName["beta"]?["paused"] as? Bool, false)
    }

    /// And the fleet board's switch, which never touches the autopilot at all.
    func testProjectsListReportsPausedForAProjectPausedOnTheFleetBoard() async throws {
        try registerProject(named: "alpha", configure: { _ in })
        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))
        try entry.session.project.setPaused(true, goal: nil)

        let (_, body) = try await harness.get("/v1/projects")
        let projects = try XCTUnwrap(body["projects"] as? [[String: Any]])

        XCTAssertEqual(projects.first?["paused"] as? Bool, true)
    }

    // MARK: - Addressing

    /// The lookup is the shared registry one, so a full path addresses the same
    /// project as its folder name.
    func testResolvesProjectByPath() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        let path = try XCTUnwrap(registry.entry(forProject: "alpha")).session.project.id

        let (status, body) = try await harness.post("/v1/autopilot/pause", ["project": path])

        XCTAssertEqual(status, 409)   // idle — but the project was found
        XCTAssertEqual(body["error"] as? String, "Autopilot is not running for this project")
        XCTAssertEqual(autopilot.status, .idle)
    }

    // MARK: - Errors

    func testPauseWithoutProjectIs400() async throws {
        let (status, body) = try await harness.post("/v1/autopilot/pause", [:])
        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\"")
    }

    func testResumeWithoutProjectIs400() async throws {
        let (status, body) = try await harness.post("/v1/autopilot/resume", [:])
        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\"")
    }

    func testPauseUnknownProjectIs409() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.post("/v1/autopilot/pause", ["project": "beta"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: beta")
    }

    func testResumeUnknownProjectIs409() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.post("/v1/autopilot/resume", ["project": "beta"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: beta")
    }

    /// Both endpoints change what the app is doing, so they sit behind the token
    /// like every other write — and an unauthenticated call changes nothing.
    func testPauseRequiresBearerToken() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        let logCountBefore = autopilot.log.count

        let (status, body) = try await harness.post("/v1/autopilot/pause", ["project": "alpha"], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertEqual(autopilot.log.count, logCountBefore)
    }

    func testResumeRequiresBearerToken() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }

        let (status, body) = try await harness.post("/v1/autopilot/resume", ["project": "alpha"], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertEqual(autopilot.status, .paused)
        XCTAssertFalse(autopilot.log.contains { $0.message == "Resumed" })
    }

    // MARK: - Helpers

    /// Builds a real `ProjectSession` over a throwaway directory and registers it
    /// with a fresh autopilot, which `configure` can drive into the state under
    /// test (e.g. `pause()` for a held queue).
    ///
    /// `items` writes a `BACKLOG.md`, `details` writes the groomed detail files
    /// it links to, and — when either is given — the autopilot is wired to the
    /// real orchestrator and given a worker and reviewer, the same as
    /// `KiteloopControlServerStartRunTests` does: what lets `POST /v1/runs`
    /// actually reach the pickup gates instead of refusing for want of an
    /// orchestrator before it gets that far.
    /// `BacklogAutopilot` holds its orchestrator weakly and the run-start gate
    /// refuses without a live session for both agents, so the fixture keeps
    /// each project's orchestrator and root for `startAgentSessions`.
    private var orchestratorsByProject: [String: Orchestrator] = [:]
    private var projectRootsByName: [String: URL] = [:]

    /// The same wiring a person gets by opening the two agent chats — what
    /// lets `POST /v1/runs` pass the no-agent-session gate.
    private func startAgentSessions(forProject name: String) async throws {
        let orchestrator = try XCTUnwrap(orchestratorsByProject[name])
        let root = try XCTUnwrap(projectRootsByName[name])
        try await orchestrator.startAgent("worker", cwd: root)
        try await orchestrator.startAgent("reviewer", cwd: root)
    }

    @discardableResult
    private func registerProject(
        named name: String,
        items: [String] = [],
        details: [String: String] = [:],
        configure: (BacklogAutopilot) -> Void
    ) throws -> BacklogAutopilot {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        if !items.isEmpty {
            try "# \(name) Backlog\n\n## Now\n\n\(items.joined(separator: "\n"))\n"
                .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        }
        for (path, contents) in details {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )

        let autopilot = BacklogAutopilot()
        if !items.isEmpty {
            autopilot.configure(orchestrator: orchestrator, backlogViewModel: session.backlogViewModel, configURL: nil)
            autopilot.workerAgentID = "worker"
            autopilot.reviewerAgentID = "reviewer"
            for agentID in ["worker", "reviewer"] {
                orchestrator.addAgent(Agent(
                    id: agentID, name: agentID, model: "sonnet", systemPrompt: "",
                    tools: [], denied: [], permissionMode: "default", state: .idle))
            }
        }
        orchestratorsByProject[name] = orchestrator
        projectRootsByName[name] = rootURL
        configure(autopilot)
        registry.register(session: session, autopilot: autopilot)
        return autopilot
    }

    /// The single item a scheduler-started run has in its queue.
    private func heldItem() -> BacklogItem {
        BacklogItem(id: "item-1", title: "Item 1", verify: "true", status: .ready, type: .local, size: .s)
    }

    /// A backlog item groomed past every Definition-of-Ready clause — the same
    /// shape `KiteloopControlServerBacklogApproveTests` uses to prove an item
    /// reads `ready`.
    private func groomedDetail(id: String) -> String {
        """
        ---
        id: \(id)
        title: Fully groomed
        size: S
        verify:
          - name: build
            cmd: "true"
        ---

        ## What

        The outcome this item delivers.

        ## How

        Touch these files, follow this pattern.

        ## Validation

        - [ ] The observable behaviour that proves it works

        ## Out of Scope

        - Anything else
        """
    }

    /// All stores are pointed at the temp directory so the tests never read or
    /// write the developer's real global config.
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
