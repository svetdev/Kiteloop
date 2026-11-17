import XCTest
@testable import KiteloopCore

/// Installing a pack lets someone else's setup into a project, so the plan
/// has to say everything it would write, arm nothing, carry no secret, link
/// to nothing and overwrite nothing.
final class PackInstallPlanTests: XCTestCase {

    private static let secret = "sk-live-do-not-repeat-4f9a"
    private static let headerSecret = "Bearer do-not-repeat-77c1"

    private var pack: URL!
    private var project: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try makeTemporaryDirectory(prefix: "pack-install-pack")
        project = try makeTemporaryDirectory(prefix: "pack-install-project")
    }

    override func tearDownWithError() throws {
        pack = nil
        project = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private func write(_ text: String, to path: String, in root: URL? = nil) throws {
        let url = (root ?? pack).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func writeManifest(_ lists: String = """
        "agents": ["agents/scout"], "routines": ["routines/brief.json"],
        "connectors": ["connectors/tracker.json"], "templates": ["templates/standup.md"]
        """) throws {
        try write(#"{"name": "Morning desk", "version": "1.2.0", \#(lists)}"#, to: "pack.json")
    }

    private func writeAgent(_ extra: String = "", handle: String = "@scout", at path: String = "agents/scout") throws {
        try write("""
            {"handle": "\(handle)", "version": "1.0.0",
             "template": {"name": "Scout", "model": "sonnet", "systemPrompt": "Look around." \(extra)},
             "knowledge": {"critical": [], "files": [], "imports": []}}
            """, to: "\(path)/agent.json")
        try write("# Scout\n", to: "\(path)/knowledge/profile.md")
    }

    private func writeRoutine(armed: Bool = true, id: String = "morning-brief") throws {
        try write("""
            {"id": "\(id)", "name": "Morning brief", "project": "someone-elses", "agent": "Scout",
             "prompt": "Summarise what changed overnight.", "trigger": {"at": "08:30"},
             "armed": \(armed), "armedAt": "2026-01-01T00:00:00Z"}
            """, to: "routines/brief.json")
    }

    private func writeFullPack() throws {
        try writeManifest()
        try writeAgent()
        try writeRoutine()
        try write("""
            {"tracker": {"command": "npx", "args": ["-y", "tracker-mcp"],
                         "env": {"TRACKER_TOKEN": "\(Self.secret)"}},
             "search": {"type": "http", "url": "https://search.example/mcp",
                        "headers": {"Authorization": "\(Self.headerSecret)"}}}
            """, to: "connectors/tracker.json")
        try write("# Standup notes\n", to: "templates/standup.md")
    }

    private func target(agentNames: [String] = ["Coder"], routineIDs: [String] = [],
                        connectorNames: [String] = [], mode: String = "auto") -> PackInstallTarget {
        PackInstallTarget(projectName: "desk", defaultPermissionMode: mode,
                          permissionModes: ["auto", "acceptEdits", "plan", "bypassPermissions"],
                          agentsDirectory: project.appendingPathComponent(".kiteloop/agents"),
                          templatesDirectory: project.appendingPathComponent("templates"),
                          templateSearchDirectories: [project.appendingPathComponent("templates")],
                          agentNames: agentNames, routineIDs: routineIDs, connectorNames: connectorNames)
    }

    private func plan(_ target: PackInstallTarget? = nil) throws -> PackInstallPlan {
        try PackInstallPlan.make(folder: pack, target: target ?? self.target())
    }

    private func files(under root: URL) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
    }

    // MARK: - What would be written

    func testThePlanNamesEverythingItWouldWriteAndWritesNothing() throws {
        try writeFullPack()

        let plan = try plan()

        XCTAssertTrue(plan.canInstall, "\(plan.refusals)")
        XCTAssertEqual(plan.agents.map(\.handle), ["scout"])
        XCTAssertEqual(plan.agents.first?.files.map(\.destination.path), [
            project.appendingPathComponent(".kiteloop/agents/scout/agent.json").path,
            project.appendingPathComponent(".kiteloop/agents/scout/knowledge/profile.md").path
        ])
        XCTAssertEqual(plan.routines.map(\.id), ["morning-brief"])
        XCTAssertEqual(plan.connectors.keys.sorted(), ["search", "tracker"])
        XCTAssertEqual(plan.templates.map(\.destination.path),
                       [project.appendingPathComponent("templates/standup.md").path])
        XCTAssertEqual(plan.added,
                       "agents Scout; routines morning-brief; connectors search, tracker; templates standup.md")
        XCTAssertEqual(try files(under: project), [], "planning writes nothing")
    }

    func testTheAccountCarriesTheInspectionAndHowItIsInstalled() throws {
        try writeFullPack()

        let plan = try plan()
        let account = plan.account

        XCTAssertTrue(account.contains(plan.pack.account))
        XCTAssertTrue(account.hasPrefix("Install into desk:"))
        XCTAssertTrue(account.contains("Nothing is started and nothing is armed."))
        XCTAssertFalse(account.contains("Refused"))
    }

    // MARK: - Routines are never armed

    func testARoutineThePackMarksArmedIsInstalledDisarmedAndTheAccountSaysSo() throws {
        try writeFullPack()

        let plan = try plan()

        XCTAssertEqual(plan.routines.map(\.armed), [false])
        XCTAssertNil(plan.routines.first?.armedAt)
        XCTAssertEqual(plan.routines.first?.project, "desk", "a routine is installed into the target project")
        XCTAssertTrue(plan.account.contains(
            "Routine morning-brief is marked armed by the pack; that is ignored and it is installed disarmed."))
    }

    func testARoutineThePackLeavesDisarmedGetsNoArmedLine() throws {
        try writeFullPack()
        try writeRoutine(armed: false)

        XCTAssertFalse(try plan().callouts.contains { $0.contains("marked armed") })
    }

    func testARoutineThatCouldNotBeKeptIsRefusedWithItsProblem() throws {
        try writeFullPack()
        try writeRoutine(id: "Morning Brief")

        let plan = try plan()

        XCTAssertFalse(plan.canInstall)
        XCTAssertTrue(plan.refusals.contains { $0.contains("the id takes lowercase letters, digits and hyphens") })
    }

    func testARoutineForAnAgentNobodyHasIsCalledOut() throws {
        try writeManifest(#""routines": ["routines/brief.json"]"#)
        try writeRoutine()

        let plan = try plan()

        XCTAssertTrue(plan.canInstall)
        XCTAssertTrue(plan.callouts.contains {
            $0 == "Routine morning-brief prompts agent Scout, which is neither in the pack nor on the team."
        })
    }

    // MARK: - No secret is taken

    func testNoConnectorValueIsTakenFromThePack() throws {
        try writeFullPack()

        let plan = try plan()

        XCTAssertEqual(plan.connectors["tracker"]?.env, ["TRACKER_TOKEN": ""])
        XCTAssertEqual(plan.connectors["tracker"]?.command, "npx")
        XCTAssertEqual(plan.connectors["search"]?.extras["headers"], .dictionary(["Authorization": .string("")]))
        XCTAssertEqual(plan.connectors["search"]?.extras["url"], .string("https://search.example/mcp"))
        let written = String(decoding: try JSONEncoder().encode(plan.connectors), as: UTF8.self)
        for secret in [Self.secret, "do-not-repeat-77c1"] {
            XCTAssertFalse(written.contains(secret))
            XCTAssertFalse(plan.account.contains(secret))
            XCTAssertFalse(plan.logRecord(at: Date()).after.contains(secret))
        }
        XCTAssertTrue(plan.callouts.contains { $0.hasPrefix("Connector tracker expects TRACKER_TOKEN: the values are not") })
    }

    func testAnEnvOfAnotherShapeKeepsItsNamesAndLosesItsValues() throws {
        let entry = ClaudeMCPServerEntry(command: "run", extras: [
            "env": .dictionary(["TOKEN": .dictionary(["value": .string(Self.secret)])]),
            "headers": .string(Self.headerSecret)
        ])

        let emptied = PackInstallPlan.withoutSecretValues(entry)

        XCTAssertEqual(emptied.env, ["TOKEN": ""])
        XCTAssertNil(emptied.extras["env"])
        XCTAssertNil(emptied.extras["headers"])
    }

    // MARK: - What an agent is allowed is called out

    func testAnAgentAskingForOperatorToolsIsCalledOutOnItsOwnLine() throws {
        try writeFullPack()
        try writeAgent(#", "operatorToolsEnabled": true"#)

        let plan = try plan()

        XCTAssertTrue(plan.callouts.contains(
            "Agent Scout asks for Operator tools: it would hold the control API's operator token."))
        XCTAssertTrue(plan.account.contains("• Agent Scout asks for Operator tools"))
    }

    func testAnAgentAskingForReadOnlyOperatorToolsSaysWhichCredential() throws {
        try writeFullPack()
        try writeAgent(#", "operatorToolsEnabled": true, "controlAccess": "read""#)

        XCTAssertTrue(try plan().callouts.contains(
            "Agent Scout asks for Operator tools: it would hold a read-only control API token."))
    }

    func testAnAgentAskingForAModeThatIsNotTheProjectsIsCalledOut() throws {
        try writeFullPack()
        try writeAgent(#", "permissionMode": "bypassPermissions""#)

        let plan = try plan()

        XCTAssertEqual(plan.agents.first?.permissionMode, "bypassPermissions")
        XCTAssertTrue(plan.callouts.contains(
            "Agent Scout asks for permission mode bypassPermissions; this project's default is auto."))
    }

    func testAnAgentThatNamesNoModeTakesTheProjectsAndIsNotCalledOut() throws {
        try writeFullPack()

        let plan = try plan(target(mode: "plan"))

        XCTAssertEqual(plan.agents.first?.permissionMode, "plan")
        XCTAssertFalse(plan.callouts.contains { $0.hasPrefix("Agent") })
    }

    func testAnAgentAskingForTheProjectsOwnModeIsNotCalledOut() throws {
        try writeFullPack()
        try writeAgent(#", "permissionMode": "auto""#)

        XCTAssertFalse(try plan().callouts.contains { $0.contains("permission mode") })
    }

    func testAModeTheAppDoesNotKnowIsRefused() throws {
        try writeFullPack()
        try writeAgent(#", "permissionMode": "anything-goes""#)

        XCTAssertEqual(try plan().refusals, ["Agent Scout asks for a permission mode the app does not know."])
    }

    // MARK: - Nothing is overwritten

    func testANameTheProjectAlreadyHasIsRefusedAndNothingIsCopied() throws {
        try writeFullPack()
        try write("# Mine\n", to: "templates/Standup.md", in: project)
        try write("{}", to: ".kiteloop/agents/scout/agent.json", in: project)
        let before = try files(under: project)

        let plan = try plan(target(agentNames: ["scout"], routineIDs: ["morning-brief"], connectorNames: ["tracker"]))

        XCTAssertEqual(plan.refusals, [
            "The project already holds an agent package named scout.",
            "The project's team already has an agent named Scout.",
            "A routine with the id morning-brief already exists.",
            "An MCP server named tracker already exists.",
            "The project already has a template named standup."
        ])
        XCTAssertTrue(plan.account.contains("Nothing is installed while an entry is refused."))
        XCTAssertThrowsError(try plan.copyFiles()) { error in
            XCTAssertEqual(error as? PackInstallError, .refused(plan.refusals))
        }
        XCTAssertEqual(try files(under: project), before)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("templates/Standup.md"), encoding: .utf8),
                       "# Mine\n")
    }

    func testANameThePackGivesTwiceIsRefused() throws {
        try writeFullPack()
        try writeManifest(#""agents": ["agents/scout", "agents/scout-two"]"#)
        try writeAgent(at: "agents/scout-two")

        XCTAssertEqual(try plan().refusals, ["The pack names the agent @scout more than once."])
    }

    func testATemplateThatIsNotMarkdownIsRefused() throws {
        try writeManifest(#""templates": ["templates/standup.json"]"#)
        try write(#"{"title": "Standup"}"#, to: "templates/standup.json")

        XCTAssertEqual(try plan().refusals,
                       ["Template templates/standup.json is not a .md file, which is what a project's templates are."])
    }

    // MARK: - Paths stay inside the pack

    func testAHandleThatWouldLeaveTheAgentsFolderIsRefused() throws {
        try writeFullPack()
        try writeAgent(handle: "../../outside")

        let plan = try plan()

        XCTAssertEqual(plan.refusals, ["Agent Scout (agents/scout) has a handle that cannot name a folder."])
        XCTAssertThrowsError(try plan.copyFiles())
        XCTAssertEqual(try files(under: project), [])
    }

    func testAListedPathThatLeavesThePackIsRefusedAsInspectionRefusesIt() throws {
        try writeFullPack()
        let outside = try makeTemporaryDirectory(prefix: "pack-install-outside")
        try write("# Elsewhere\n", to: "notes.md", in: outside)
        try FileManager.default.removeItem(at: pack.appendingPathComponent("templates/standup.md"))
        try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("templates/standup.md"),
                                                   withDestinationURL: outside.appendingPathComponent("notes.md"))

        XCTAssertThrowsError(try plan()) { error in
            XCTAssertEqual(error as? PackInspectionError,
                           .escapesPack(path: "templates/standup.md", field: "templates"))
        }
    }

    func testALinkInsideAnAgentPackageThatLeavesThePackIsRefused() throws {
        try writeFullPack()
        let outside = try makeTemporaryDirectory(prefix: "pack-install-outside")
        try write("private\n", to: "secrets.md", in: outside)
        try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("agents/scout/knowledge/more.md"),
                                                   withDestinationURL: outside.appendingPathComponent("secrets.md"))

        let plan = try plan()

        XCTAssertEqual(plan.refusals, ["agents/scout/knowledge/more.md is a link that leaves the pack folder."])
        XCTAssertFalse(plan.agents.first?.files.contains { $0.destination.lastPathComponent == "more.md" } ?? true)
    }

    // MARK: - Copying

    func testCopyingWritesFilesOfItsOwnAndNeverALinkToThePack() throws {
        try writeFullPack()
        try write("shared\n", to: "shared/house-style.md")
        try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("agents/scout/knowledge/style.md"),
                                                   withDestinationURL: pack.appendingPathComponent("shared/house-style.md"))

        let plan = try plan()
        try plan.copyFiles()

        XCTAssertEqual(try files(under: project), [
            ".kiteloop", ".kiteloop/agents", ".kiteloop/agents/scout", ".kiteloop/agents/scout/agent.json",
            ".kiteloop/agents/scout/knowledge", ".kiteloop/agents/scout/knowledge/profile.md",
            ".kiteloop/agents/scout/knowledge/style.md", "templates", "templates/standup.md"
        ])
        let style = project.appendingPathComponent(".kiteloop/agents/scout/knowledge/style.md")
        XCTAssertEqual(try style.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
        XCTAssertEqual(try String(contentsOf: style, encoding: .utf8), "shared\n")

        try FileManager.default.removeItem(at: pack)
        XCTAssertEqual(try String(contentsOf: style, encoding: .utf8), "shared\n",
                       "the copy stands without the pack folder")
    }

    func testACopyThatFailsPartWayTakesBackWhatItCopiedAndLeavesTheRestAlone() throws {
        try writeFullPack()
        let plan = try plan()
        try write("# Arrived since\n", to: "templates/standup.md", in: project)

        XCTAssertThrowsError(try plan.copyFiles()) { error in
            XCTAssertEqual(error as? PackInstallError,
                           .destinationExists(project.appendingPathComponent("templates/standup.md").path))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".kiteloop/agents/scout").path))
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("templates/standup.md"), encoding: .utf8),
                       "# Arrived since\n")
    }

    func testTakingAnInstallBackRemovesWhatWasCopied() throws {
        try writeFullPack()
        let plan = try plan()
        try plan.copyFiles()

        plan.removeCopiedFiles()

        XCTAssertEqual(try files(under: project), [".kiteloop", ".kiteloop/agents", "templates"])
    }

    // MARK: - The record

    func testTheLogLineNamesThePackItsFolderAndWhatWasAdded() throws {
        try writeFullPack()
        let moment = Date(timeIntervalSince1970: 1_800_000_000)

        let record = try plan().logRecord(at: moment)

        XCTAssertEqual(record, ConfigChangeLog.Record(
            requestedBy: "person", kind: "pack", tool: "Install Pack", before: "",
            after: "Morning desk 1.2.0 from \(pack.path): agents Scout; routines morning-brief; "
                + "connectors search, tracker; templates standup.md",
            decision: .approved, at: moment))
    }

    // MARK: - Inspection says what an agent would hold

    func testInspectionNamesOperatorToolsInWhatAnAgentIsAllowed() throws {
        try writeFullPack()
        try writeAgent(#", "operatorToolsEnabled": true"#)

        let line = try PackInspector().inspect(folder: pack).agents.first?.permissionLine

        XCTAssertEqual(line, "Agent @scout (Scout) runs in the app's default permission mode with the app's default "
                       + "tools, and holds Operator tools (the control API's operator token).")
    }
}
