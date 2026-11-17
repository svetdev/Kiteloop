import XCTest
import KiteloopCore
@testable import Kiteloop

/// The endpoints that set a team and its project up — sessions, chats,
/// project settings, backlog edits, memory, knowledge and the app's settings.
/// Each is driven over a real loopback socket and asserted against what it
/// left behind: the session, the file on disk, the store.
@MainActor
final class KiteloopControlServerManagementTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var settings: GlobalConfigStore!
    private var connectorSecrets: InMemoryConnectorSecretStore!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-management")
        registry = ControlSessionRegistry()
        connectorSecrets = InMemoryConnectorSecretStore()
        settings = GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json"),
                                     secretStore: connectorSecrets)
        defaultsName = "control-management-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let settings = settings, defaults = defaults, registry = registry
        harness = try await ControlServerHarness.start { token in
            let server = KiteloopControlServer(registry: registry!, token: token)
            server.settings = settings
            server.defaults = defaults!
            return server
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
        defaults?.removePersistentDomain(forName: defaultsName)
    }

    // MARK: - An agent's session

    func testStartingStoppingAndRestartingAnAgentsSession() async throws {
        let session = try registerProject()
        let agentID = addAgent(named: "Builder", to: session)

        let (_, started) = try await harness.post("/v1/agents/start", ["project": "alpha", "agent": "builder"])
        let (_, again) = try await harness.post("/v1/agents/start", ["project": "alpha", "agent": agentID])
        XCTAssertEqual(started["started"] as? Bool, true)
        XCTAssertEqual(again["started"] as? Bool, false, "a running agent is left alone")
        XCTAssertTrue(session.orchestrator.hasSession(for: agentID))

        let (restart, _) = try await harness.post("/v1/agents/restart", ["project": "alpha", "agent": agentID])
        XCTAssertEqual(restart, 200)
        XCTAssertTrue(session.orchestrator.hasSession(for: agentID))

        let (_, stopped) = try await harness.post("/v1/agents/stop", ["project": "alpha", "agent": agentID])
        let (_, idle) = try await harness.post("/v1/agents/stop", ["project": "alpha", "agent": agentID])
        XCTAssertEqual(stopped["stopped"] as? Bool, true)
        XCTAssertEqual(idle["stopped"] as? Bool, false)
        XCTAssertFalse(session.orchestrator.hasSession(for: agentID))
    }

    func testASessionSomethingDependsOnIsNotStoppedOrRestarted() async throws {
        let session = try registerProject()
        let worker = addAgent(named: "Builder", to: session)
        let busy = addAgent(named: "Writer", to: session)
        try await session.orchestrator.startAgent(worker, cwd: session.project.rootURL)
        try await session.orchestrator.startAgent(busy, cwd: session.project.rootURL)
        session.orchestrator.updateAgent(id: busy) { $0.state = .working }
        let autopilot = try XCTUnwrap(registry.entry(forProject: "alpha")?.autopilot)
        autopilot.workerAgentID = worker
        autopilot.stageRunForTesting(status: .paused, queue: [])

        let (staffedStop, _) = try await harness.post("/v1/agents/stop", ["project": "alpha", "agent": worker])
        let (staffedRestart, _) = try await harness.post("/v1/agents/restart", ["project": "alpha", "agent": worker])
        let (midTurn, _) = try await harness.post("/v1/agents/restart", ["project": "alpha", "agent": busy])
        let (unknown, _) = try await harness.post("/v1/agents/start", ["project": "alpha", "agent": "nobody"])
        let (notOpen, _) = try await harness.post("/v1/agents/start", ["project": "beta", "agent": worker])
        let (missing, _) = try await harness.post("/v1/agents/start", ["project": "alpha"])

        XCTAssertEqual([staffedStop, staffedRestart, midTurn], [409, 409, 409])
        XCTAssertEqual([unknown, notOpen, missing], [404, 409, 400])
        XCTAssertTrue(session.orchestrator.hasSession(for: worker))
        XCTAssertTrue(session.orchestrator.hasSession(for: busy))
    }

    // MARK: - An agent's chats

    func testANewChatBecomesTheCurrentOneAndAnEarlierOneCanBeOpenedAgain() async throws {
        let session = try registerProject()
        let agentID = addAgent(named: "Builder", to: session)
        let (_, before) = try await harness.get("/v1/agents/chats?project=alpha&agent=builder")
        let first = try XCTUnwrap((before["chats"] as? [[String: Any]])?.first?["id"] as? String)

        let (created, made) = try await harness.post("/v1/agents/chats", ["project": "alpha", "agent": agentID])
        let second = try XCTUnwrap((made["chat"] as? [String: Any])?["id"] as? String)

        XCTAssertEqual(created, 201)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(session.chatViewModel(for: agentID).currentSession?.id.uuidString, second)
        let afterNew = try await currentChat(of: agentID)
        XCTAssertEqual(afterNew, second)

        let (opened, _) = try await harness.post("/v1/agents/chats/open", ["project": "alpha", "agent": agentID, "chat": first])
        XCTAssertEqual(opened, 200)
        let afterOpen = try await currentChat(of: agentID)
        XCTAssertEqual(afterOpen, first)
    }

    func testDeletingAChatRemovesItAndAChangeOfChatWaitsForTheTurn() async throws {
        let session = try registerProject()
        let agentID = addAgent(named: "Builder", to: session)
        let (_, made) = try await harness.post("/v1/agents/chats", ["project": "alpha", "agent": agentID])
        let current = try XCTUnwrap((made["chat"] as? [String: Any])?["id"] as? String)
        let other = try XCTUnwrap(session.sessionStore.sessions(for: agentID).first { $0.id.uuidString != current }?.id.uuidString)

        let (deleted, _) = try await remove("/v1/agents/chats?project=alpha&agent=\(agentID)&chat=\(other)")
        let (gone, _) = try await remove("/v1/agents/chats?project=alpha&agent=\(agentID)&chat=\(other)")
        XCTAssertEqual(deleted, 200)
        XCTAssertEqual(gone, 404)
        XCTAssertEqual(session.sessionStore.sessions(for: agentID).map(\.id.uuidString), [current])

        session.orchestrator.updateAgent(id: agentID) { $0.state = .working }
        let (newMidTurn, _) = try await harness.post("/v1/agents/chats", ["project": "alpha", "agent": agentID])
        let (deleteMidTurn, _) = try await remove("/v1/agents/chats?project=alpha&agent=\(agentID)&chat=\(current)")
        XCTAssertEqual([newMidTurn, deleteMidTurn], [409, 409], "either would cut the turn off")
        XCTAssertEqual(session.sessionStore.sessions(for: agentID).map(\.id.uuidString), [current])
    }

    private func currentChat(of agentID: String) async throws -> String? {
        let (_, body) = try await harness.get("/v1/agents/chats?project=alpha&agent=\(agentID)")
        return (body["chats"] as? [[String: Any]])?.first { $0["current"] as? Bool == true }?["id"] as? String
    }

    // MARK: - Projects

    func testClosingAProjectAsksTheWindowAndWaitsForARunToEnd() async throws {
        let session = try registerProject()
        let (noWindow, _) = try await harness.post("/v1/projects/close", ["project": "alpha"])
        XCTAssertEqual(noWindow, 503)

        var closed: [String] = []
        registry.closeProject = { [registry] id in
            closed.append(id)
            await registry?.unregister(projectID: id)
        }
        let autopilot = try XCTUnwrap(registry.entry(forProject: "alpha")?.autopilot)
        autopilot.stageExecutingRunForTesting(true)
        let (running, _) = try await harness.post("/v1/projects/close", ["project": "alpha"])
        XCTAssertEqual(running, 409)
        XCTAssertEqual(closed, [])

        autopilot.stageExecutingRunForTesting(false)
        let (status, body) = try await harness.post("/v1/projects/close", ["project": "alpha"])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["closed"] as? String, session.project.id)
        XCTAssertEqual(closed, [session.project.id])
        let (again, _) = try await harness.post("/v1/projects/close", ["project": "alpha"])
        XCTAssertEqual(again, 409, "it is no longer open")
    }

    func testProjectSettingsAreReadChangedAndCleared() async throws {
        let session = try registerProject()

        let (status, body) = try await harness.put("/v1/projects/settings", [
            "project": "alpha", "model": "opus", "permissionMode": "plan", "effort": "high",
            "maxBudgetUSD": 12.5, "goal": " Ship the thing. ",
            "companions": [["name": "site", "path": "../site", "base": "main"]]
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["model"] as? String, "opus")
        let saved = session.project.loadConfig()
        XCTAssertEqual(saved.model, "opus")
        XCTAssertEqual(saved.permissionMode, "plan")
        XCTAssertEqual(saved.effort, "high")
        XCTAssertEqual(saved.maxBudgetUSD, 12.5)
        XCTAssertEqual(saved.goal, "Ship the thing.")
        XCTAssertEqual(saved.companions, [CompanionRepo(name: "site", path: "../site", baseBranch: "main")])

        _ = try await harness.put("/v1/projects/settings", ["project": "alpha", "model": NSNull(), "maxBudgetUSD": NSNull(), "companions": []])
        let (_, read) = try await harness.get("/v1/projects/settings?project=alpha")
        XCTAssertTrue(read["model"] is NSNull)
        XCTAssertTrue(read["maxBudgetUSD"] is NSNull)
        XCTAssertEqual((read["companions"] as? [Any])?.count, 0)
        XCTAssertEqual(read["effort"] as? String, "high", "a field the change did not name stays")
    }

    func testProjectSettingsThatCannotBeTakenChangeNothing() async throws {
        let session = try registerProject()
        _ = try await harness.put("/v1/projects/settings", ["project": "alpha", "goal": "Ship."])
        let before = try Data(contentsOf: session.project.configURL)

        let (effort, _) = try await harness.put("/v1/projects/settings", ["project": "alpha", "model": "opus", "effort": "extreme"])
        let (mode, _) = try await harness.put("/v1/projects/settings", ["project": "alpha", "permissionMode": "yolo"])
        let (budget, _) = try await harness.put("/v1/projects/settings", ["project": "alpha", "maxBudgetUSD": -1])
        let (companion, _) = try await harness.put("/v1/projects/settings", ["project": "alpha", "companions": [["name": "site"]]])
        let (nothing, _) = try await harness.put("/v1/projects/settings", ["project": "alpha"])

        XCTAssertEqual([effort, mode, budget, companion, nothing], [400, 400, 400, 400, 400])
        XCTAssertEqual(try Data(contentsOf: session.project.configURL), before, "the model beside a refused effort is not written")
    }

    func testAProjectsSpaceIsSetReportedAndCleared() async throws {
        let session = try registerProject()

        let (status, body) = try await harness.put("/v1/projects/settings", ["project": "alpha", "space": "Work"])
        let (_, read) = try await harness.get("/v1/projects/settings?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["space"] as? String, "work")
        XCTAssertEqual(read["space"] as? String, "work")
        XCTAssertEqual(session.project.loadConfig().space, .work)

        _ = try await harness.put("/v1/projects/settings", ["project": "alpha", "space": NSNull()])
        let (_, cleared) = try await harness.get("/v1/projects/settings?project=alpha")
        XCTAssertTrue(cleared["space"] is NSNull)
        XCTAssertNil(session.project.loadConfig().space)
    }

    func testAnUnknownSpaceIsRefusedAndChangesNothing() async throws {
        let session = try registerProject()
        _ = try await harness.put("/v1/projects/settings", ["project": "alpha", "space": "personal"])
        let before = try Data(contentsOf: session.project.configURL)

        let (unknown, refusal) = try await harness.put("/v1/projects/settings", ["project": "alpha", "goal": "Ship.", "space": "office"])
        let (mistyped, _) = try await harness.put("/v1/projects/settings", ["project": "alpha", "space": 3])

        XCTAssertEqual([unknown, mistyped], [400, 400])
        let message = try XCTUnwrap(refusal["error"] as? String)
        XCTAssertTrue(message.contains("work, personal"), message)
        XCTAssertEqual(try Data(contentsOf: session.project.configURL), before, "the goal beside a refused space is not written")
    }

    // MARK: - The setup file

    func testAProjectsSetupIsExportedAsOneFileWithItsRoutinesDisarmed() async throws {
        let session = try registerProject()
        var config = session.project.loadConfig()
        config.goal = "Ship."
        config.pinnedDocument = "docs/brief.md"
        var bedrock = BedrockConfig.default
        bedrock.profile = "secret-profile"
        config.bedrock = bedrock
        try session.project.saveConfig(config)
        let team = PackageTeamConfig(agents: [
            PackageAgentRef(id: "chief", ref: "shared:chief", version: nil,
                            overrides: AgentOverrides(mcpServers: ["linear", "github"]))
        ])
        try JSONEncoder().encode(team).write(to: session.project.teamConfigURL)
        let routines = RoutineRunner(store: RoutineStore(directory: tempDir.appendingPathComponent("home")))
        harness.server.routines = routines
        try routines.put(Routine(id: "brief", name: "Brief", project: "alpha", agent: "chief", prompt: "Write it.",
                                 trigger: Routine.Trigger(at: "07:00"), armed: true, armedAt: Date()))
        try routines.put(Routine(id: "other", name: "Other", project: "elsewhere", agent: "chief", prompt: "No.",
                                 trigger: Routine.Trigger(at: "08:00")))

        let (status, body) = try await harness.get("/v1/projects/setup?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["format"] as? Int, 1)
        XCTAssertEqual(body["pinnedDocument"] as? String, "docs/brief.md")
        XCTAssertEqual(body["connectors"] as? [String], ["github", "linear"])
        XCTAssertEqual((body["settings"] as? [String: Any])?["goal"] as? String, "Ship.")
        let agents = try XCTUnwrap((body["team"] as? [String: Any])?["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.map { $0["ref"] as? String }, ["shared:chief"])
        let exported = try XCTUnwrap(body["routines"] as? [[String: Any]])
        XCTAssertEqual(exported.map { $0["id"] as? String }, ["brief"], "only this project's routines")
        XCTAssertEqual(exported.first?["armed"] as? Bool, false)
        XCTAssertNil(body["teamShape"])
        XCTAssertNil(body["bedrock"])
        let raw = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("secret-profile"), raw)
    }

    func testATemplateTeamIsNamedNotExportedAndNoRunnerMeansNoRoutines() async throws {
        let session = try registerProject()
        let template = AgentTemplate(name: "Builder")
        try JSONEncoder().encode([template]).write(to: session.project.teamConfigURL)

        let (status, body) = try await harness.get("/v1/projects/setup?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertTrue(body["team"] is NSNull)
        XCTAssertEqual(body["teamShape"] as? String, "templates")
        XCTAssertEqual((body["routines"] as? [Any])?.count, 0)
        XCTAssertEqual(body["connectors"] as? [String], [])
        XCTAssertTrue(body["pinnedDocument"] is NSNull)
    }

    func testASetupExportNamesAnOpenProjectAndNeedsAToken() async throws {
        try registerProject()

        let (missing, _) = try await harness.get("/v1/projects/setup")
        let (closed, _) = try await harness.get("/v1/projects/setup?project=nowhere")
        let (anonymous, _) = try await harness.get("/v1/projects/setup?project=alpha", bearer: nil)

        XCTAssertEqual([missing, closed, anonymous], [400, 409, 401])
        XCTAssertEqual(ControlRoute.manage(.exportProjectSetup).scope, .read)
    }

    func testProjectsAreListedBySpace() async throws {
        let alpha = try registerProject()
        _ = try registerProject(named: "beta")
        var config = alpha.project.loadConfig()
        config.space = .work
        try alpha.project.saveConfig(config)

        let (_, everything) = try await harness.get("/v1/projects")
        let (_, work) = try await harness.get("/v1/projects?space=work")
        let (_, unassigned) = try await harness.get("/v1/projects?space=unassigned")
        let (_, personal) = try await harness.get("/v1/projects?space=personal")
        let (unknown, _) = try await harness.get("/v1/projects?space=office")

        let all = try XCTUnwrap(everything["projects"] as? [[String: Any]])
        XCTAssertEqual(all.map { $0["name"] as? String }, ["alpha", "beta"])
        XCTAssertEqual(all.first?["space"] as? String, "work")
        XCTAssertTrue(all.last?["space"] is NSNull, "an unassigned project carries the field, as null")
        XCTAssertEqual(Self.names(work), ["alpha"])
        XCTAssertEqual(Self.names(unassigned), ["beta"])
        XCTAssertEqual(Self.names(personal), [])
        XCTAssertEqual(unknown, 400)
    }

    private static func names(_ body: [String: Any]) -> [String] {
        (body["projects"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    // MARK: - Backlog items

    func testAnItemsLineAndDetailAreChanged() async throws {
        let session = try registerProject()

        let (status, body) = try await patch("/v1/backlog/items", [
            "project": "alpha", "item": "item-1", "title": "A better title", "verify": "swift test",
            "size": "m", "detail": "## What\n\nRewritten.\n"
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["title"] as? String, "A better title")
        XCTAssertEqual(Set(body["changed"] as? [String] ?? []), ["title", "verify", "size", "detail"])
        let line = try XCTUnwrap(backlogText(session).split(separator: "\n").first { $0.contains("item-1") })
        XCTAssertTrue(line.contains("A better title"))
        XCTAssertTrue(line.contains("swift test"))
        XCTAssertTrue(line.contains("size:M"))
        let detail = try String(contentsOf: session.project.rootURL.appending(path: "backlog/item-1.md"), encoding: .utf8)
        XCTAssertEqual(detail, "## What\n\nRewritten.\n")
    }

    func testAnItemChangeThatCannotBeMadeLeavesTheLineAsItWas() async throws {
        let session = try registerProject()
        let before = try backlogText(session)

        let (size, _) = try await patch("/v1/backlog/items", ["project": "alpha", "item": "item-1", "title": "Changed", "size": "huge"])
        let (blank, _) = try await patch("/v1/backlog/items", ["project": "alpha", "item": "item-1", "title": "  "])
        let (separator, _) = try await patch("/v1/backlog/items", ["project": "alpha", "item": "item-1", "title": "a | b"])
        let (nothing, _) = try await patch("/v1/backlog/items", ["project": "alpha", "item": "item-1"])
        let (noDetail, _) = try await patch("/v1/backlog/items", ["project": "alpha", "item": "item-2", "detail": "x"])
        let (unknown, _) = try await patch("/v1/backlog/items", ["project": "alpha", "item": "nope", "title": "x"])
        let (running, _) = try await patch("/v1/backlog/items", ["project": "alpha", "item": "item-3", "title": "x"])

        XCTAssertEqual([size, blank, separator, nothing, noDetail], [400, 400, 400, 400, 400])
        XCTAssertEqual(unknown, 404)
        XCTAssertEqual(running, 409, "the line is the run's to write")
        XCTAssertEqual(try backlogText(session), before)
    }

    func testAnItemIsRemovedUnlessARunOrAGateHasIt() async throws {
        let session = try registerProject()

        let (removed, body) = try await remove("/v1/backlog/items?project=alpha&item=item-2")
        let (again, _) = try await remove("/v1/backlog/items?project=alpha&item=item-2")
        let (running, _) = try await remove("/v1/backlog/items?project=alpha&item=item-3")
        let (atGate, _) = try await remove("/v1/backlog/items?project=alpha&item=item-4")

        XCTAssertEqual(removed, 200)
        XCTAssertEqual(body["removed"] as? String, "item-2")
        XCTAssertEqual([again, running, atGate], [404, 409, 409])
        let text = try backlogText(session)
        XCTAssertFalse(text.contains("item-2"))
        XCTAssertTrue(text.contains("item-3") && text.contains("item-4"))
    }

    private func backlogText(_ session: ProjectSession) throws -> String {
        try String(contentsOf: session.project.rootURL.appending(path: "BACKLOG.md"), encoding: .utf8)
    }

    // MARK: - Memory

    func testAFactIsAddedRewrittenAndArchived() async throws {
        let session = try registerProject()
        let agentID = addAgent(named: "Builder", to: session)

        let (added, body) = try await harness.post("/v1/memory/facts", [
            "project": "alpha", "agent": "builder", "content": "The staging database is reset every Sunday night."
        ])
        let topic = try XCTUnwrap((body["facts"] as? [[String: Any]])?.first?["topic"] as? String)
        XCTAssertEqual(added, 201)

        let (rewritten, _) = try await harness.put("/v1/memory/facts", [
            "project": "alpha", "agent": agentID, "topic": topic, "content": "The staging database is reset every Monday morning."
        ])
        XCTAssertEqual(rewritten, 200)
        let (_, read) = try await harness.get("/v1/memory?project=alpha&agent=\(agentID)")
        XCTAssertTrue((read["index"] as? String ?? "").contains("Monday"))
        XCTAssertEqual((read["facts"] as? [[String: Any]])?.count, 1)

        let (archived, _) = try await remove("/v1/memory/facts?project=alpha&agent=\(agentID)&topic=\(topic)")
        XCTAssertEqual(archived, 200)
        let (_, after) = try await harness.get("/v1/memory?project=alpha&agent=\(agentID)")
        XCTAssertEqual((after["facts"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((after["archived"] as? [[String: Any]])?.first?["topic"] as? String, topic)
        XCTAssertFalse((after["index"] as? String ?? "").contains("Monday"), "an archived fact leaves what the agent is shown")
    }

    func testAMemoryWriteThatNamesNothingIsRefused() async throws {
        let session = try registerProject()
        addAgent(named: "Builder", to: session)

        let (blank, _) = try await harness.post("/v1/memory/facts", ["project": "alpha", "agent": "Builder", "content": "  "])
        let (noFact, _) = try await harness.put("/v1/memory/facts", ["project": "alpha", "agent": "Builder", "topic": "nope", "content": "x"])
        let (noArchive, _) = try await remove("/v1/memory/facts?project=alpha&agent=Builder&topic=nope")
        let (noAgent, _) = try await harness.get("/v1/memory?project=alpha&agent=nobody")

        XCTAssertEqual([blank, noFact, noArchive, noAgent], [400, 404, 404, 404])
    }

    func testTheSharedContextIsReplacedAndReadBack() async throws {
        let session = try registerProject()

        let (status, _) = try await harness.put("/v1/memory/shared", ["project": "alpha", "content": "We deploy on Thursdays."])
        let (_, read) = try await harness.get("/v1/memory/shared?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(read["content"] as? String, "We deploy on Thursdays.")
        XCTAssertEqual(try String(contentsOf: session.project.contextURL, encoding: .utf8), "We deploy on Thursdays.")
    }

    // MARK: - Claude's notes

    func testClaudesNotesAreWrittenListedAndDeletedWithTheirIndexLine() async throws {
        let session = try registerProject()
        let folder = session.claudeMemoryViewModel.store.directory
        XCTAssertTrue(folder.path(percentEncoded: false).hasPrefix(tempDir.path(percentEncoded: false)), "never the real ~/.claude")

        _ = try await harness.put("/v1/memory/claude", [
            "project": "alpha", "note": "deploys",
            "text": "---\nname: deploys\ndescription: When we deploy\nmetadata:\n  type: project\n---\n\nThursdays.\n"
        ])
        _ = try await harness.put("/v1/memory/claude", ["project": "alpha", "note": "MEMORY", "text": "- [Deploys](deploys.md) — Thursdays\n"])
        let (_, listed) = try await harness.get("/v1/memory/claude?project=alpha")
        let notes = try XCTUnwrap(listed["notes"] as? [[String: Any]])

        XCTAssertEqual(notes.map { $0["id"] as? String }, ["MEMORY", "deploys"])
        XCTAssertEqual(notes.last?["summary"] as? String, "When we deploy")
        XCTAssertEqual(notes.last?["kind"] as? String, "project")

        let (deleted, _) = try await remove("/v1/memory/claude?project=alpha&note=deploys")
        XCTAssertEqual(deleted, 200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "deploys.md").path(percentEncoded: false)))
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "MEMORY.md"), encoding: .utf8), "")
    }

    func testANoteNameCannotLeaveTheFolderAndTheIndexIsNotDeleted() async throws {
        try registerProject()
        _ = try await harness.put("/v1/memory/claude", ["project": "alpha", "note": "MEMORY", "text": "index"])

        let (outside, _) = try await harness.put("/v1/memory/claude", ["project": "alpha", "note": "../../escape", "text": "x"])
        let (index, _) = try await remove("/v1/memory/claude?project=alpha&note=MEMORY")
        let (unknown, _) = try await remove("/v1/memory/claude?project=alpha&note=nope")

        XCTAssertEqual([outside, index, unknown], [400, 400, 404])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appending(path: "claude/projects/escape.md").path(percentEncoded: false)))
    }

    // MARK: - Knowledge packages

    func testAKnowledgeFileIsListedReadAndWrittenInsideItsPackage() async throws {
        let session = try registerProject()
        let package = session.project.knowledgeURL.appending(path: "agents/reviewer")
        try FileManager.default.createDirectory(at: package.appending(path: "knowledge"), withIntermediateDirectories: true)
        try "---\nname: Reviewer\ndescription: Reads diffs\n---\nYou review.".write(to: package.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        try "Be specific.".write(to: package.appending(path: "knowledge/rubric.md"), atomically: true, encoding: .utf8)

        let (_, listed) = try await harness.get("/v1/knowledge?project=alpha")
        let row = try XCTUnwrap((listed["packages"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["id"] as? String, "reviewer")
        XCTAssertEqual(row["name"] as? String, "Reviewer")
        XCTAssertEqual(row["files"] as? [String], ["profile.md", "knowledge/rubric.md"])

        let (_, read) = try await harness.get("/v1/knowledge/file?project=alpha&package=reviewer&path=knowledge/rubric.md")
        XCTAssertEqual(read["content"] as? String, "Be specific.")

        let (written, _) = try await harness.put("/v1/knowledge/file", [
            "project": "alpha", "package": "reviewer", "path": "knowledge/style/tone.md", "content": "Plain words."
        ])
        XCTAssertEqual(written, 200)
        XCTAssertEqual(try String(contentsOf: package.appending(path: "knowledge/style/tone.md"), encoding: .utf8), "Plain words.")

        let (outside, _) = try await harness.put("/v1/knowledge/file", [
            "project": "alpha", "package": "reviewer", "path": "../../escaped.md", "content": "x"
        ])
        let (noPackage, _) = try await harness.get("/v1/knowledge/file?project=alpha&package=nope&path=profile.md")
        let (noFile, _) = try await harness.get("/v1/knowledge/file?project=alpha&package=reviewer&path=knowledge/nope.md")
        XCTAssertEqual([outside, noPackage, noFile], [400, 404, 404])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.project.knowledgeURL.appending(path: "escaped.md").path(percentEncoded: false)))
    }

    // MARK: - The app

    func testAnMCPServerIsAddedListedWithoutItsSecretsAndRemoved() async throws {
        let (status, _) = try await harness.put("/v1/mcp-servers/tracker", [
            "command": "npx", "args": ["-y", "tracker-mcp"], "env": ["TRACKER_TOKEN": "s3cret"]
        ])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(settings.config.mcpServers?["tracker"]?.env, ["TRACKER_TOKEN": ""])
        XCTAssertFalse(try String(contentsOf: tempDir.appendingPathComponent("global.json"), encoding: .utf8)
            .contains("s3cret"), "the settings file keeps the name, not the value")
        let tokenKey = ConnectorSecretKey(server: "tracker", kind: .env, name: "TRACKER_TOKEN")
        XCTAssertEqual(connectorSecrets.value(for: tokenKey), "s3cret")

        var request = URLRequest(url: harness.url("/v1/mcp-servers"))
        request.setValue("Bearer \(harness.token)", forHTTPHeaderField: "Authorization")
        let (_, raw) = try await harness.raw(request)
        let listed = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(listed.contains("TRACKER_TOKEN"))
        XCTAssertFalse(listed.contains("s3cret"), "a credential is not handed back to whoever asks")

        let (removed, _) = try await remove("/v1/mcp-servers/tracker")
        let (again, _) = try await remove("/v1/mcp-servers/tracker")
        let (empty, _) = try await harness.put("/v1/mcp-servers/tracker", [:])
        let (mistyped, _) = try await harness.put("/v1/mcp-servers/tracker", ["command": "npx", "args": "tracker"])
        XCTAssertEqual([removed, again, empty, mistyped], [200, 404, 400, 400])
        XCTAssertNil(settings.config.mcpServers)
        XCTAssertNil(connectorSecrets.value(for: tokenKey))
    }

    func testAnMCPServerListsWhatTheLastSessionReportedOfIt() async throws {
        _ = try await harness.put("/v1/mcp-servers/tracker", ["command": "npx", "env": ["TRACKER_TOKEN": "s3cret"]])
        let session = try registerProject()

        let (_, before) = try await harness.get("/v1/mcp-servers")
        let unreported = try XCTUnwrap((before["servers"] as? [[String: Any]])?.first)
        XCTAssertEqual(unreported["status"] as? String, "unknown")
        XCTAssertEqual(unreported["tools"] as? [String], [])
        XCTAssertTrue(unreported["reportedAt"] is NSNull)

        session.orchestrator.recordConnectorStatuses([
            ConnectorStatus(name: "tracker", state: "needs-auth", tools: ["create", "search"], reportedAt: Date())
        ])
        var request = URLRequest(url: harness.url("/v1/mcp-servers"))
        request.setValue("Bearer \(harness.token)", forHTTPHeaderField: "Authorization")
        let (_, raw) = try await harness.raw(request)
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let reported = try XCTUnwrap((listed["servers"] as? [[String: Any]])?.first)
        XCTAssertEqual(reported["status"] as? String, "needs-auth")
        XCTAssertEqual(reported["tools"] as? [String], ["create", "search"])
        XCTAssertNotNil(reported["reportedAt"] as? String)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("s3cret"), "env values stay out of the list")
    }

    func testTheAppsSettingsAreReadAndChanged() async throws {
        let (status, body) = try await harness.put("/v1/settings", ["defaultModel": "opus", "defaultEffort": "high", "soundTheme": "silent"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["soundTheme"] as? String, "silent")
        XCTAssertNil(body["automaticUpdateChecks"], "no updater is attached to say")
        XCTAssertEqual(settings.config.defaultModel, "opus")
        XCTAssertEqual(settings.config.defaultEffort, "high")
        XCTAssertEqual(defaults.string(forKey: SoundTheme.defaultsKey), "silent")

        let (theme, _) = try await harness.put("/v1/settings", ["defaultModel": "sonnet", "soundTheme": "loud"])
        let (effort, _) = try await harness.put("/v1/settings", ["defaultEffort": "extreme"])
        let (nothing, _) = try await harness.put("/v1/settings", [:])
        let (noUpdater, _) = try await harness.put("/v1/settings", ["automaticUpdateChecks": true])
        XCTAssertEqual([theme, effort, nothing, noUpdater], [400, 400, 400, 503])
        XCTAssertEqual(settings.config.defaultModel, "opus", "the model beside a refused theme is not written")

        _ = try await harness.put("/v1/settings", ["defaultModel": NSNull()])
        let (_, read) = try await harness.get("/v1/settings")
        XCTAssertTrue(read["defaultModel"] is NSNull)
        XCTAssertEqual(read["defaultEffort"] as? String, "high")
    }

    func testAServerWithNoSettingsStoreSaysSo() async throws {
        let bare = try await ControlServerHarness.start(registry: ControlSessionRegistry())
        defer { bare.stop() }
        let (settings, _) = try await bare.get("/v1/settings")
        let (servers, _) = try await bare.get("/v1/mcp-servers")
        XCTAssertEqual([settings, servers], [503, 503])
    }

    // MARK: - Helpers

    private func patch(_ path: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
        try await harness.send(path, method: "PATCH", body: body, bearer: harness.token)
    }

    private func remove(_ path: String) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: harness.url(path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(harness.token)", forHTTPHeaderField: "Authorization")
        return try await harness.send(request)
    }

    @discardableResult
    private func addAgent(named name: String, to session: ProjectSession) -> String {
        let agent = Agent(name: name, model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "acceptEdits")
        session.orchestrator.addAgent(agent)
        return agent.id
    }

    /// A real `ProjectSession` over a throwaway directory named `alpha`, with a
    /// four-item backlog: ready, draft with no detail file, active, and one
    /// waiting at its gate.
    @discardableResult
    private func registerProject(named name: String = "alpha") throws -> ProjectSession {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appending(path: "backlog"), withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        try """
        # alpha Backlog

        ## Now

        - [ ] item-1 | An item | ready | size: S → [detail](backlog/item-1.md)
        - [ ] item-2 | A draft | draft | size: S
        - [ ] item-3 | In a run | active | size: S
        - [ ] item-4 | At its gate | awaiting-approval | size: S
        """.write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        try "## What\n\nThe outcome.\n".write(to: root.appending(path: "backlog/item-1.md"), atomically: true, encoding: .utf8)

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        var context = ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: settings,
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
        context.claudeConfigDirectory = tempDir.appending(path: "claude")
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: context
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
        return session
    }
}
