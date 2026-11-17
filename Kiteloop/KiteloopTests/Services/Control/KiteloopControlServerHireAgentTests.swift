import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/agents` — the endpoint a headless driver uses to put a worker or a
/// reviewer on an open project before configuring autopilot. Driven over a real
/// loopback socket so the whole path (body parsing → project lookup → the agent
/// landing on the session's orchestrator) is covered.
///
/// The behaviour worth pinning down is `select`: it defaults to **false**, so a
/// headless hire never yanks the human's selected agent out from under them
/// mid-conversation. The default is asserted against the session, not just the
/// status code — a flipped default would still return 201.
@MainActor
final class KiteloopControlServerHireAgentTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private let token = "control-hire-agent-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-hire-agent")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Hiring

    /// The response promises an agent that exists: the id it returns has to
    /// resolve on the project's roster, so a handler that answered 201 while
    /// adding nothing fails here.
    func testHireReturns201AndAddsTheAgentToTheProject() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "model": "sonnet"]
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["name"] as? String, "Builder")
        XCTAssertEqual(body["model"] as? String, "sonnet")
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        XCTAssertFalse(agentID.isEmpty)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.name, "Builder")
        XCTAssertEqual(agent.model, "sonnet")
    }

    func testHireTakesTheAgentsAlwaysAskRulesAndItsMCPServers() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/agents", [
            "project": "alpha", "name": "Desk", "askFirst": ["Bash(gh pr comment:*)"], "mcpServers": ["chat"]
        ])

        XCTAssertEqual(status, 201)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == body["agentId"] as? String })
        XCTAssertEqual(agent.askFirst, ["Bash(gh pr comment:*)"])
        XCTAssertEqual(agent.mcpServers, ["chat"])
    }

    // MARK: - The project's pinned document

    func testPinningAFileIsKeptInTheProjectsSettingsAndListedWithTheProject() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/projects/pin", ["project": "alpha", "path": " Briefs/today.md "])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["pinned"] as? String, "Briefs/today.md", "a file that does not exist yet can be pinned")
        XCTAssertEqual(projectSession.project.loadConfig().pinnedDocument, "Briefs/today.md")
        let (_, listed) = try await harness.get("/v1/projects")
        XCTAssertEqual((listed["projects"] as? [[String: Any]])?.first?["pinned"] as? String, "Briefs/today.md")
    }

    func testAnEmptyOrNullPathUnpins() async throws {
        let projectSession = try registerProject(named: "alpha")
        _ = try await harness.post("/v1/projects/pin", ["project": "alpha", "path": "Briefs/today.md"])

        let (status, body) = try await harness.post("/v1/projects/pin", ["project": "alpha", "path": NSNull()])

        XCTAssertEqual(status, 200)
        XCTAssertTrue(body["pinned"] is NSNull)
        XCTAssertNil(projectSession.project.loadConfig().pinnedDocument)
    }

    func testAPathThatLeavesTheProjectIsRefusedAndNothingIsPinned() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (outside, _) = try await harness.post("/v1/projects/pin", ["project": "alpha", "path": "../secrets.md"])
        let (absolute, _) = try await harness.post("/v1/projects/pin", ["project": "alpha", "path": "/etc/hosts"])
        let (noProject, _) = try await harness.post("/v1/projects/pin", ["path": "a.md"])
        let (notOpen, _) = try await harness.post("/v1/projects/pin", ["project": "beta", "path": "a.md"])

        XCTAssertEqual(outside, 400)
        XCTAssertEqual(absolute, 400)
        XCTAssertEqual(noProject, 400)
        XCTAssertEqual(notOpen, 409)
        XCTAssertNil(projectSession.project.loadConfig().pinnedDocument)
    }

    func testAnAsideMustAskAboutWhatItsSourceMust() async throws {
        let projectSession = try registerProject(named: "alpha")
        let (_, body) = try await harness.post("/v1/agents", [
            "project": "alpha", "name": "Desk", "askFirst": ["mcp__chat__post"]
        ])
        let agentID = try XCTUnwrap(body["agentId"] as? String)

        let aside = try await projectSession.orchestrator.forkAside(
            of: agentID, cwd: projectSession.project.rootURL, sourceSessionID: "session-1")

        XCTAssertEqual(aside.askFirst, ["mcp__chat__post"])
    }

    /// The hire answers before the agent's process is up, and a driver may
    /// message the agent at once. The chat that message makes and runs its
    /// turn in is the agent's chat from then on — the hire finishing does not
    /// put an empty one in its place, which left the turn in a chat nothing
    /// read and the transcript blank.
    func testAChatMadeByAMessageSentAtOnceIsKeptWhenTheHireFinishes() async throws {
        let projectSession = try registerProject(named: "alpha")
        let (_, body) = try await harness.post("/v1/agents", ["project": "alpha", "name": "Builder", "model": "sonnet"])
        let agentID = try XCTUnwrap(body["agentId"] as? String)

        let early = projectSession.chatViewModel(for: agentID)

        try await eventually("the hire to finish starting the agent") { projectSession.orchestrator.hasSession(for: agentID) }
        // One more turn of the main actor, for the hire's own continuation.
        try await eventually("the hire's task to settle") { projectSession.chatViewModels[agentID] != nil }
        await Task.yield()
        XCTAssertTrue(projectSession.chatViewModels[agentID] === early)
    }

    /// A driver that only knows the name it wants gets the app's defaults for
    /// everything else, and the response reports the model it actually got.
    func testHireWithoutModelUsesTheDefaultModelAndPermissionMode() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["model"] as? String, ModelCatalog.defaultModelID)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.model, ModelCatalog.defaultModelID)
        XCTAssertEqual(agent.permissionMode, "auto")
    }

    /// A hire that names no model takes the one Project Settings gives the
    /// project — here `haiku`, over an app default of `sonnet` — and the
    /// response reports it.
    func testHireWithoutModelUsesTheProjectsConfiguredModel() async throws {
        let projectSession = try registerProject(named: "alpha", appDefaultModel: "sonnet")
        var config = ProjectConfig.default
        config.model = "haiku"
        try projectSession.project.saveConfig(config)

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["model"] as? String, "haiku")
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.model, "haiku")
    }

    /// With no project model, a model-less hire takes Settings → Default Model.
    func testHireWithoutModelFallsBackToTheAppDefaultModel() async throws {
        try registerProject(named: "alpha", appDefaultModel: "sonnet")

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["model"] as? String, "sonnet")
    }

    /// A model the request names wins over the project's and the app's.
    func testHireWithAnExplicitModelKeepsIt() async throws {
        let projectSession = try registerProject(named: "alpha", appDefaultModel: "sonnet")
        var config = ProjectConfig.default
        config.model = "haiku"
        try projectSession.project.saveConfig(config)

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "model": "opus"]
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["model"] as? String, "opus")
    }

    /// A hire that names no mode takes the one Project Settings gives new
    /// agents in that project — here `plan`, so an app default would fail it.
    func testHireWithoutModeUsesTheProjectsConfiguredMode() async throws {
        let projectSession = try registerProject(named: "alpha")
        var config = ProjectConfig.default
        config.permissionMode = "plan"
        try projectSession.project.saveConfig(config)

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.permissionMode, "plan")
    }

    /// A mode the request names wins over the project's.
    func testHireWithAnExplicitModeKeepsIt() async throws {
        let projectSession = try registerProject(named: "alpha")
        var config = ProjectConfig.default
        config.permissionMode = "plan"
        try projectSession.project.saveConfig(config)

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "permissionMode": "acceptEdits"]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.permissionMode, "acceptEdits")
    }

    /// The project can be addressed by path as well as by name — the same
    /// lookup every other route uses.
    func testHireResolvesTheProjectByPath() async throws {
        let projectSession = try registerProject(named: "alpha")
        let path = projectSession.project.rootURL.path(percentEncoded: false)

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": path, "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        XCTAssertNotNil(projectSession.orchestrator.agents.first { $0.id == agentID })
    }

    // MARK: - Selection

    /// The point of the endpoint's `select` default: a headless hire adds the
    /// agent but leaves the human looking at whatever they were looking at.
    func testHireWithoutSelectLeavesThePriorSelectionAlone() async throws {
        let projectSession = try registerProject(named: "alpha")
        let incumbent = addAgent(named: "Incumbent", to: projectSession)
        projectSession.selectedAgentID = incumbent

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        try await waitUntilStarted(agentID, in: projectSession)
        XCTAssertEqual(projectSession.selectedAgentID, incumbent,
                       "an API hire must not steal the user's selection")
    }

    /// `select: false` spelled out is the same as omitting it — no caller gets a
    /// different answer for being explicit.
    func testHireWithSelectFalseLeavesThePriorSelectionAlone() async throws {
        let projectSession = try registerProject(named: "alpha")
        let incumbent = addAgent(named: "Incumbent", to: projectSession)
        projectSession.selectedAgentID = incumbent

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "select": false]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        try await waitUntilStarted(agentID, in: projectSession)
        XCTAssertEqual(projectSession.selectedAgentID, incumbent)
    }

    /// Opting in is what a caller does when it *wants* the view to follow — a
    /// setup wizard hiring the agent the human is about to talk to.
    func testHireWithSelectTrueSelectsTheNewAgent() async throws {
        let projectSession = try registerProject(named: "alpha")
        let incumbent = addAgent(named: "Incumbent", to: projectSession)
        projectSession.selectedAgentID = incumbent

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "select": true]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        try await eventually("the new agent to be selected") { await projectSession.selectedAgentID == agentID }
        XCTAssertEqual(projectSession.selectedAgentID, agentID)
    }

    /// `select` is a boolean, and JSON hands a boolean and a number back as the
    /// same `NSNumber` — so `select: 1` used to bridge to `true` and steal the
    /// human's selection from a caller that never asked for it. Rejected rather
    /// than guessed at, and nobody is hired on the way to the 400.
    func testHireWithANumericSelectIs400() async throws {
        let projectSession = try registerProject(named: "alpha")
        let incumbent = addAgent(named: "Incumbent", to: projectSession)
        projectSession.selectedAgentID = incumbent

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "select": 1]
        )

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "\"select\" must be true or false")
        XCTAssertEqual(projectSession.orchestrator.agents.map(\.name), ["Incumbent"])
        XCTAssertEqual(projectSession.selectedAgentID, incumbent)
    }

    // MARK: - Bad requests

    func testHireWithoutProjectIs400() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/agents", ["name": "Builder"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"name\"")
        XCTAssertTrue(projectSession.orchestrator.agents.isEmpty)
    }

    func testHireWithoutNameIs400() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/agents", ["project": "alpha"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"name\"")
        XCTAssertTrue(projectSession.orchestrator.agents.isEmpty)
    }

    /// An empty name would produce an unaddressable agent — `PUT /v1/autopilot`
    /// resolves workers by name — so it's rejected rather than hired.
    func testHireWithEmptyNameIs400() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": ""]
        )

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"name\"")
        XCTAssertTrue(projectSession.orchestrator.agents.isEmpty)
    }

    /// A project Kiteloop hasn't opened is a 409, not a 400: the request is
    /// well-formed, and what the caller has to do is open the project — not fix
    /// its body.
    func testHireIntoUnopenedProjectIs409() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "beta", "name": "Builder"]
        )

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: beta")
        XCTAssertTrue(projectSession.orchestrator.agents.isEmpty)
    }

    /// Hiring starts a process, so it's a write: the token gates it and an
    /// unauthorized request must not reach the session at all.
    func testHireRequiresBearerToken() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/agents", ["project": "alpha", "name": "Builder"], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertTrue(projectSession.orchestrator.agents.isEmpty)
    }

    // MARK: - Listing and chatting

    /// `GET /v1/agents` answers the roster as the sidebar shows it — the id it
    /// returns is the one the message and transcript endpoints take.
    func testListAgentsShowsAHiredAgentWithItsState() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)

        let (status, body) = try await harness.get("/v1/agents?project=alpha")

        XCTAssertEqual(status, 200)
        let agents = try XCTUnwrap(body["agents"] as? [[String: Any]])
        let builder = try XCTUnwrap(agents.first { ($0["id"] as? String) == agentID })
        XCTAssertEqual(builder["name"] as? String, "Builder")
        XCTAssertEqual(builder["model"] as? String, "sonnet")
        XCTAssertEqual(builder["state"] as? String, "idle")
        // No chat view model yet, so the context figure is unknown and absent, not null.
        XCTAssertNil(builder["contextTokens"])
        XCTAssertNil(builder["contextWindow"])
    }

    func testListAgentsWithoutProjectIs400AndUnknownProjectIs409() async throws {
        let (missing, _) = try await harness.get("/v1/agents")
        XCTAssertEqual(missing, 400)
        let (unknown, _) = try await harness.get("/v1/agents?project=nope")
        XCTAssertEqual(unknown, 409)
    }

    /// An agent that has never spoken answers an empty transcript, not an
    /// error — the phone opens the chat before the first message exists.
    func testTranscriptOfANeverChattedAgentIsEmpty() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)

        let (status, body) = try await harness.get("/v1/agents/transcript?project=alpha&agent=\(agentID)")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["agent"] as? String, agentID)
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 0)
    }

    /// Both chat endpoints resolve the agent by name too, case-insensitively —
    /// a phone types "builder", not a UUID.
    func testTranscriptResolvesTheAgentByNameCaseInsensitively() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)

        let (status, body) = try await harness.get("/v1/agents/transcript?project=alpha&agent=builder")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["agent"] as? String, agentID, "answers with the id, whatever was asked by")
    }

    func testTranscriptOfAnUnknownAgentIs404() async throws {
        try registerProject(named: "alpha")
        let (status, _) = try await harness.get("/v1/agents/transcript?project=alpha&agent=nobody")
        XCTAssertEqual(status, 404)
    }

    func testMessageWithoutAMessageIs400AndUnknownAgentIs404() async throws {
        let projectSession = try registerProject(named: "alpha")
        addAgent(named: "Builder", to: projectSession)

        let (missing, _) = try await harness.post("/v1/agents/message",
                                                  ["project": "alpha", "agent": "Builder"])
        XCTAssertEqual(missing, 400)
        let (blank, _) = try await harness.post("/v1/agents/message",
                                                ["project": "alpha", "agent": "Builder", "message": "  "])
        XCTAssertEqual(blank, 400, "an all-whitespace message would start an empty turn")
        let (unknown, _) = try await harness.post("/v1/agents/message",
                                                  ["project": "alpha", "agent": "nobody", "message": "hi"])
        XCTAssertEqual(unknown, 404)
    }

    // MARK: - Changing an agent

    func testAnEditReplacesTheNamedFieldsLeavesTheRestAndWritesTheTeamFile() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)

        let (status, body) = try await patch([
            "project": "alpha", "agent": "builder", "name": " Shipwright ", "model": "opus",
            "systemPrompt": "Build boats.", "tools": ["Read"], "askFirst": ["Bash(gh pr comment:*)"]
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["agent"] as? String, agentID)
        XCTAssertEqual(body["name"] as? String, "Shipwright")
        XCTAssertEqual(body["model"] as? String, "opus")
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.name, "Shipwright")
        XCTAssertEqual(agent.systemPrompt, "Build boats.")
        XCTAssertEqual(agent.tools, ["Read"])
        XCTAssertEqual(agent.askFirst, ["Bash(gh pr comment:*)"])
        XCTAssertEqual(agent.permissionMode, "acceptEdits", "a field the edit did not name stays")
        XCTAssertEqual(try savedTeamNames(projectSession), ["Shipwright"], "the edit outlives a restart")
    }

    /// `applies` is the driver's only way to know whether the session it is
    /// about to message already runs with the new values.
    func testAnEditSaysWhenItReachesTheSession() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)

        let (_, renamed) = try await patch(["project": "alpha", "agent": agentID, "name": "Wright"])
        let (_, stopped) = try await patch(["project": "alpha", "agent": agentID, "model": "opus"])
        try await projectSession.orchestrator.startAgent(agentID, cwd: projectSession.project.rootURL)
        let (_, same) = try await patch(["project": "alpha", "agent": agentID, "model": "opus"])
        let (_, idle) = try await patch(["project": "alpha", "agent": agentID, "model": "haiku"])
        try await eventually("the restart to bring the session back") { projectSession.orchestrator.hasSession(for: agentID) }
        projectSession.orchestrator.updateAgent(id: agentID) { $0.state = .working }
        let (_, busy) = try await patch(["project": "alpha", "agent": agentID, "model": "sonnet"])

        XCTAssertEqual(renamed["applies"] as? String, "now", "a name is not read at spawn")
        XCTAssertEqual(stopped["applies"] as? String, "nextStart", "no session to restart")
        XCTAssertEqual(same["applies"] as? String, "now", "a value it already had restarts nothing")
        XCTAssertEqual(idle["applies"] as? String, "restarted")
        XCTAssertEqual(busy["applies"] as? String, "nextStart", "a turn in flight is left alone")
        XCTAssertTrue(projectSession.orchestrator.hasSession(for: agentID))
    }

    func testARenameIsCarriedIntoATeammatesCrossAgentAccess() async throws {
        let projectSession = try registerProject(named: "alpha")
        let builder = addAgent(named: "Builder", to: projectSession)
        let lead = addAgent(named: "Lead", to: projectSession)
        _ = try await patch(["project": "alpha", "agent": lead, "crossAgentAccess": ["Builder"]])

        _ = try await patch(["project": "alpha", "agent": builder, "name": "Shipwright"])

        XCTAssertEqual(projectSession.orchestrator.agents.first { $0.id == lead }?.crossAgentAccess, ["Shipwright"])
    }

    func testAnEditThatCannotBeMadeIsRefusedAndChangesNothing() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)
        addAgent(named: "Reviewer", to: projectSession)
        let before = projectSession.orchestrator.agents

        let (taken, _) = try await patch(["project": "alpha", "agent": agentID, "name": "reviewer"])
        let (blank, _) = try await patch(["project": "alpha", "agent": agentID, "name": "  "])
        let (nothing, _) = try await patch(["project": "alpha", "agent": agentID])
        let (mistyped, _) = try await patch(["project": "alpha", "agent": agentID, "tools": "Read"])
        let (mode, _) = try await patch(["project": "alpha", "agent": agentID, "permissionMode": "plan"])
        let (unknown, _) = try await patch(["project": "alpha", "agent": "nobody", "name": "X"])
        let (notOpen, _) = try await patch(["project": "beta", "agent": agentID, "name": "X"])

        XCTAssertEqual(taken, 409)
        XCTAssertEqual(blank, 400)
        XCTAssertEqual(nothing, 400)
        XCTAssertEqual(mistyped, 400)
        XCTAssertEqual(mode, 400, "the mode has its own endpoint, which moves a live session")
        XCTAssertEqual(unknown, 404)
        XCTAssertEqual(notOpen, 409)
        XCTAssertEqual(projectSession.orchestrator.agents, before)
    }

    func testAnEditSetsAnAgentsSkillsEffortThinkingAndBudget() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)

        let (status, _) = try await patch([
            "project": "alpha", "agent": agentID, "skills": ["review"], "effort": "high",
            "thinkingBudget": 8000, "maxBudgetUSD": 2.5
        ])

        XCTAssertEqual(status, 200)
        var agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.skills, ["review"])
        XCTAssertEqual(agent.effort, "high")
        XCTAssertTrue(agent.thinkingEnabled, "a budget turns thinking on")
        XCTAssertEqual(agent.thinkingBudget, 8000)
        XCTAssertEqual(agent.maxBudgetUSD, 2.5)

        _ = try await patch(["project": "alpha", "agent": agentID, "thinking": false, "maxBudgetUSD": NSNull()])
        agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertFalse(agent.thinkingEnabled)
        XCTAssertNil(agent.thinkingBudget)
        XCTAssertNil(agent.maxBudgetUSD, "null lifts the ceiling")

        let (effort, _) = try await patch(["project": "alpha", "agent": agentID, "effort": "extreme"])
        let (thinking, _) = try await patch(["project": "alpha", "agent": agentID, "thinking": 1])
        let (tokens, _) = try await patch(["project": "alpha", "agent": agentID, "thinkingBudget": 0])
        let (budget, _) = try await patch(["project": "alpha", "agent": agentID, "maxBudgetUSD": "lots"])
        XCTAssertEqual([effort, thinking, tokens, budget], [400, 400, 400, 400])
        XCTAssertEqual(projectSession.orchestrator.agents.first { $0.id == agentID }?.effort, "high")
    }

    /// The reply measures the prompt the saved agent will be given, so a skill
    /// the edit just set is in it and the keys a driver already reads are not moved.
    func testAnEditReportsWhatTheAgentsConfigurationPutsInItsFirstTurn() async throws {
        let skillsDir = tempDir.appending(path: "skills")
        let skillDir = skillsDir.appending(path: "review")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skill = "---\nname: review\ndescription: Reads a diff\n---\nRead the diff twice.\n"
        try skill.write(to: skillDir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let skills = SkillRegistry(scanPaths: [skillsDir])
        await skills.reload()
        let projectSession = try registerProject(named: "alpha", skillRegistry: skills)
        let agentID = addAgent(named: "Builder", to: projectSession)

        let (status, body) = try await patch([
            "project": "alpha", "agent": agentID, "systemPrompt": "Build boats.", "skills": ["review"]
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["agent"] as? String, agentID)
        XCTAssertEqual(body["name"] as? String, "Builder")
        XCTAssertEqual(body["model"] as? String, "sonnet")
        XCTAssertNotNil(body["applies"] as? String)
        let firstTurn = try XCTUnwrap(body["firstTurn"] as? [String: Any])
        let sections = try XCTUnwrap(firstTurn["sections"] as? [[String: Any]])
        let sizes = sections.compactMap { $0["bytes"] as? Int }
        XCTAssertEqual(sections.compactMap { $0["name"] as? String }, ["prompt", "skill:review"])
        XCTAssertEqual(sizes.first, "Build boats.".utf8.count)
        XCTAssertEqual(firstTurn["bytes"] as? Int, sizes.reduce(0, +))
        let saved = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        let composed = await projectSession.orchestrator.memoryManager
            .composeSystemContext(agent: saved, skillRegistry: skills)
        let separators = (sections.count - 1) * "\n\n---\n\n".utf8.count
        XCTAssertEqual(firstTurn["bytes"] as? Int, composed.utf8.count - separators,
                       "the sections are the composed prompt, less what joins them")
    }

    // MARK: - What the tools and servers add to the first turn

    /// The note and the bridge's definitions are measured as the text the
    /// runtime hands over; the CLI's own share is named, never sized.
    func testTheListMeasuresTheOperatorNoteAndKiteloopsOwnToolDefinitions() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agent = Agent(name: "Desk", model: "sonnet", systemPrompt: "Answer.", tools: ["Read", "message_agent"],
                          denied: [], permissionMode: "acceptEdits", operatorToolsEnabled: true)
        projectSession.orchestrator.addAgent(agent)

        let (status, body) = try await harness.get("/v1/agents?project=alpha")

        XCTAssertEqual(status, 200)
        let row = try XCTUnwrap((body["agents"] as? [[String: Any]])?.first)
        let firstTurn = try XCTUnwrap(row["firstTurn"] as? [String: Any])
        let sections = try XCTUnwrap(firstTurn["sections"] as? [[String: Any]])
        let sizes = Dictionary(uniqueKeysWithValues: sections.compactMap { section in
            (section["name"] as? String).flatMap { name in (section["bytes"] as? Int).map { (name, $0) } }
        })
        XCTAssertEqual(sections.compactMap { $0["name"] as? String }, ["prompt", "operatorTools", "kiteloopTools"])
        XCTAssertEqual(sizes["operatorTools"], OperatorToolsKnowledge.note.utf8.count)
        XCTAssertEqual(sizes["kiteloopTools"], KiteloopToolSchemas.toolDefinitionsJSON(for: agent)?.utf8.count)
        XCTAssertEqual(firstTurn["bytes"] as? Int, sizes.values.reduce(0, +))
        let unmeasured = try XCTUnwrap(firstTurn["unmeasured"] as? [[String: String]])
        XCTAssertEqual(unmeasured.map { $0["name"] }, ["cli"])
        XCTAssertEqual((firstTurn["reported"] as? [[String: Any]])?.count, 0)
    }

    func testAnAgentHoldingTheReadTokenIsMeasuredWithTheReadOnlyNote() async throws {
        let projectSession = try registerProject(named: "alpha")
        var agent = Agent(name: "Desk", model: "sonnet", systemPrompt: "", tools: [],
                          denied: [], permissionMode: "acceptEdits", operatorToolsEnabled: true)
        agent.controlAccess = .readOnly
        projectSession.orchestrator.addAgent(agent)

        let (_, body) = try await harness.get("/v1/agents?project=alpha")

        let row = try XCTUnwrap((body["agents"] as? [[String: Any]])?.first)
        let sections = try XCTUnwrap((row["firstTurn"] as? [String: Any])?["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.compactMap { $0["name"] as? String }, ["operatorTools"])
        XCTAssertEqual(sections.first?["bytes"] as? Int, OperatorToolsKnowledge.readOnlyNote.utf8.count)
    }

    /// A server a session has started is reported as it was seen; one none
    /// has is named and left unsized.
    func testAServerIsReportedOnceASessionHasSeenItAndUnmeasuredUntilThen() async throws {
        let projectSession = try registerProject(named: "alpha")
        let config = tempDir.appending(path: "agent-mcp.json")
        try #"{"mcpServers": {"github": {"command": "gh-mcp"}, "linear": {"command": "linear-mcp"}}}"#
            .write(to: config, atomically: true, encoding: .utf8)
        let agent = Agent(name: "Desk", model: "sonnet", systemPrompt: "", tools: [], denied: [],
                          permissionMode: "acceptEdits", mcpConfigPath: config.path(percentEncoded: false))
        projectSession.orchestrator.addAgent(agent)
        projectSession.orchestrator.recordConnectorStatuses([
            ConnectorStatus(name: "github", state: "connected", tools: ["search"], reportedAt: Date(timeIntervalSince1970: 0))
        ])

        let (_, body) = try await harness.get("/v1/agents?project=alpha")

        let row = try XCTUnwrap((body["agents"] as? [[String: Any]])?.first)
        let firstTurn = try XCTUnwrap(row["firstTurn"] as? [String: Any])
        let reported = try XCTUnwrap(firstTurn["reported"] as? [[String: Any]])
        XCTAssertEqual(reported.map { $0["name"] as? String }, ["mcp:github"])
        XCTAssertEqual(reported.first?["tools"] as? [String], ["search"])
        XCTAssertEqual(reported.first?["reportedAt"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertNil(reported.first?["bytes"])
        let unmeasured = try XCTUnwrap(firstTurn["unmeasured"] as? [[String: String]])
        XCTAssertEqual(unmeasured.map { $0["name"] }, ["mcp:linear", "cli"])
        XCTAssertEqual(firstTurn["bytes"] as? Int, 0)
    }

    func testAHireAnswersWithWhatTheNewAgentsConfigurationPutsInItsFirstTurn() async throws {
        _ = try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/agents", [
            "project": "alpha", "name": "Builder", "systemPrompt": "Build boats.", "tools": ["Read"]
        ])

        XCTAssertEqual(status, 201)
        let firstTurn = try XCTUnwrap(body["firstTurn"] as? [String: Any])
        let sections = try XCTUnwrap(firstTurn["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.compactMap { $0["name"] as? String }, ["prompt"])
        XCTAssertEqual(firstTurn["bytes"] as? Int, "Build boats.".utf8.count)
        // No turn has run, so there is no token figure to put beside it.
        XCTAssertNil(body["contextTokens"])
    }

    // MARK: - Removing an agent

    func testRemovingAnAgentStopsItAndTakesItOffTheTeamFile() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)
        addAgent(named: "Reviewer", to: projectSession)
        projectSession.persistTeamConfig()
        try await projectSession.orchestrator.startAgent(agentID, cwd: projectSession.project.rootURL)

        let (status, body) = try await remove("project=alpha&agent=builder")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["removed"] as? String, agentID)
        XCTAssertEqual(body["name"] as? String, "Builder")
        XCTAssertEqual(projectSession.orchestrator.agents.map(\.name), ["Reviewer"])
        XCTAssertFalse(projectSession.orchestrator.hasSession(for: agentID))
        XCTAssertEqual(try savedTeamNames(projectSession), ["Reviewer"])
        let (again, _) = try await remove("project=alpha&agent=builder")
        XCTAssertEqual(again, 404)
    }

    func testAnAgentInTheMiddleOfSomethingIsNotRemoved() async throws {
        let projectSession = try registerProject(named: "alpha")
        let busy = addAgent(named: "Builder", to: projectSession)
        let reviewer = addAgent(named: "Reviewer", to: projectSession)
        projectSession.orchestrator.updateAgent(id: busy) { $0.state = .working }
        let autopilot = try XCTUnwrap(registry.entry(forProject: "alpha")?.autopilot)
        autopilot.reviewerAgentID = reviewer
        autopilot.stageRunForTesting(status: .paused, queue: [])

        let (midTurn, _) = try await remove("project=alpha&agent=\(busy)")
        let (staffed, _) = try await remove("project=alpha&agent=\(reviewer)")
        let (missing, _) = try await remove("project=alpha")

        XCTAssertEqual(midTurn, 409)
        XCTAssertEqual(staffed, 409, "the run would lose its reviewer")
        XCTAssertEqual(missing, 400)
        XCTAssertEqual(projectSession.orchestrator.agents.count, 2)

        autopilot.stageRunForTesting(status: .idle, queue: [])
        let (afterTheRun, _) = try await remove("project=alpha&agent=\(reviewer)")
        XCTAssertEqual(afterTheRun, 200)
    }

    /// The names in the project's team file, as a relaunch would read them.
    private func savedTeamNames(_ projectSession: ProjectSession) throws -> [String] {
        let data = try Data(contentsOf: projectSession.project.teamConfigURL)
        return try JSONDecoder().decode([AgentTemplate].self, from: data).map(\.name)
    }

    private func patch(_ body: [String: Any]) async throws -> (Int, [String: Any]) {
        try await harness.send("/v1/agents", method: "PATCH", body: body, bearer: token)
    }

    private func remove(_ query: String) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: harness.url("/v1/agents?\(query)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await harness.send(request)
    }

    // MARK: - Helpers

    /// Builds a real `ProjectSession` over a throwaway directory and registers it,
    /// which is all any control route needs to resolve the project.
    @discardableResult
    private func registerProject(named name: String, appDefaultModel: String? = nil,
                                 skillRegistry: SkillRegistry = SkillRegistry(scanPaths: [])) throws -> ProjectSession {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project),
            skillRegistry: skillRegistry
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext(appDefaultModel: appDefaultModel)
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
        return session
    }

    /// Puts an already-hired agent on the roster — the selection an API hire
    /// must not disturb.
    @discardableResult
    private func addAgent(named name: String, to projectSession: ProjectSession) -> String {
        let agent = Agent(
            name: name,
            model: "sonnet",
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "acceptEdits"
        )
        projectSession.orchestrator.addAgent(agent)
        return agent.id
    }

    /// `addAgent` decides the selection asynchronously, right after registering
    /// the new agent's chat view model. Waiting on that view model is therefore
    /// the point where "selection was skipped" becomes an assertable fact rather
    /// than a race.
    private func waitUntilStarted(
        _ agentID: String,
        in projectSession: ProjectSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await eventually("a chat view model for \(agentID)", file: file, line: line) {
            await projectSession.chatViewModels[agentID] != nil
        }
    }

    /// All stores are pointed at the temp directory so the tests never read or
    /// write the developer's real global config.
    private func makeContext(appDefaultModel: String? = nil) -> ProjectSessionContext {
        let globalConfigStore = GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json"))
        globalConfigStore.setDefaultModel(appDefaultModel)
        return ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: globalConfigStore,
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
