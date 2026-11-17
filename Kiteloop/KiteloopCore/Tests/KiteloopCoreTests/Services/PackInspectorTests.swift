import XCTest
@testable import KiteloopCore

/// Inspecting a pack is what a person reads before letting it in, so it has to
/// say everything the pack could do, repeat no secret, and change nothing.
final class PackInspectorTests: XCTestCase {

    private static let secret = "sk-live-do-not-repeat-4f9a"
    private static let headerSecret = "Bearer do-not-repeat-77c1"

    private var pack: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try makeTemporaryDirectory(prefix: "pack-inspector")
    }

    override func tearDownWithError() throws {
        pack = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private func write(_ text: String, to path: String) throws {
        let url = pack.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func writeManifest(_ lists: String = """
        "agents": ["agents/scout"], "routines": ["routines/brief.json"],
        "connectors": ["connectors/tracker.json"], "templates": ["templates/standup.md"]
        """) throws {
        try write(#"{"name": "Morning desk", "version": "1.2.0", "description": "A daily brief.", \#(lists)}"#,
                  to: "pack.json")
    }

    private func writeFullPack() throws {
        try writeManifest()
        try write("""
            {"handle": "@scout", "version": "1.0.0",
             "template": {"name": "Scout", "model": "sonnet", "systemPrompt": "",
                          "permissionMode": "acceptEdits", "tools": ["Read", "Bash"],
                          "mcpServers": ["tracker"]},
             "knowledge": {"critical": [], "files": [], "imports": []}}
            """, to: "agents/scout/agent.json")
        try write("""
            {"id": "morning-brief", "name": "Morning brief", "project": "home", "agent": "Scout",
             "prompt": "Summarise what changed overnight.", "trigger": {"at": "08:30", "days": ["mon", "fri"]},
             "precheck": "git log --since=yesterday --oneline", "armed": false}
            """, to: "routines/brief.json")
        try write("""
            {"tracker": {"command": "npx", "args": ["-y", "tracker-mcp"],
                         "env": {"TRACKER_TOKEN": "\(Self.secret)"}},
             "search": {"type": "http", "url": "https://search.example/mcp",
                        "headers": {"Authorization": "\(Self.headerSecret)"}}}
            """, to: "connectors/tracker.json")
        try write("# Standup notes\n\nYesterday, today, blockers.\n", to: "templates/standup.md")
    }

    /// Every file under the pack: what it holds and when it was last written.
    private func snapshot() throws -> [String: String] {
        var out: [String: String] = [:]
        let files = FileManager.default.enumerator(at: pack, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let body = (try? Data(contentsOf: url))?.base64EncodedString() ?? "<directory>"
            out[url.path] = "\(modified) \(body)"
        }
        return out
    }

    private func inspectionError() -> PackInspectionError? {
        do {
            _ = try PackInspector().inspect(folder: pack)
            return nil
        } catch {
            return error as? PackInspectionError
        }
    }

    // MARK: - What a pack holds

    func testASecretWrittenIntoAConnectorsCommandLineOrURLIsNotRepeated() throws {
        try writeManifest(#""connectors": ["connectors/tracker.json"]"#)
        try write("""
            {"tracker": {"command": "npx", "args": ["-y", "tracker-mcp", "--api-key", "\(Self.secret)"]},
             "search": {"type": "http", "url": "https://ada:\(Self.secret)@search.example/mcp?v=2"}}
            """, to: "connectors/tracker.json")

        let inspection = try PackInspector().inspect(folder: pack)

        XCTAssertEqual(inspection.connectors.map(\.summary),
                       ["http: https://<redacted>@search.example/mcp?v=2", "npx -y tracker-mcp --api-key <redacted>"])
        XCTAssertFalse(inspection.account.contains(Self.secret))
    }

    func testAFullPackInspectsToExactlyItsFourKinds() throws {
        try writeFullPack()

        let inspection = try PackInspector().inspect(folder: pack)

        XCTAssertEqual(inspection.name, "Morning desk")
        XCTAssertEqual(inspection.version, "1.2.0")
        XCTAssertEqual(inspection.description, "A daily brief.")
        XCTAssertEqual(inspection.agents, [
            .init(path: "agents/scout", handle: "@scout", name: "Scout", permissionMode: "acceptEdits",
                  tools: ["Read", "Bash"], mcpServers: ["tracker"], operatorTools: false, controlAccess: nil)
        ])
        XCTAssertEqual(inspection.routines, [
            .init(path: "routines/brief.json", id: "morning-brief", name: "Morning brief", agent: "Scout",
                  trigger: "at 08:30 on mon, fri", precheck: "git log --since=yesterday --oneline", armed: false)
        ])
        XCTAssertEqual(inspection.connectors, [
            .init(path: "connectors/tracker.json", name: "search", summary: "http: https://search.example/mcp",
                  envNames: [], headerNames: ["Authorization"]),
            .init(path: "connectors/tracker.json", name: "tracker", summary: "npx -y tracker-mcp",
                  envNames: ["TRACKER_TOKEN"], headerNames: [])
        ])
        XCTAssertEqual(inspection.templates, [
            .init(path: "templates/standup.md", fileName: "standup.md", title: "Standup notes")
        ])
    }

    func testInspectingLeavesTheFolderAsItWas() throws {
        try writeFullPack()
        let before = try snapshot()

        _ = try PackInspector().inspect(folder: pack)

        XCTAssertEqual(try snapshot(), before)
        XCTAssertEqual(before.count, 10, "pack.json, four files and the five folders that hold them")
    }

    func testAPackThatListsNothingInspectsToNothing() throws {
        try write(#"{"name": "Empty", "version": "0.1.0"}"#, to: "pack.json")

        let inspection = try PackInspector().inspect(folder: pack)

        XCTAssertTrue(inspection.agents.isEmpty && inspection.routines.isEmpty)
        XCTAssertTrue(inspection.connectors.isEmpty && inspection.templates.isEmpty)
        XCTAssertEqual(inspection.permissions, [])
        XCTAssertEqual(inspection.account, "Empty 0.1.0")
    }

    // MARK: - What it would be allowed to do

    func testPermissionsNameTheModeTheToolsTheCommandLinesAndThePrecheck() throws {
        try writeFullPack()

        let permissions = try PackInspector().inspect(folder: pack).permissions

        XCTAssertEqual(permissions, [
            "Agent @scout (Scout) runs in permission mode acceptEdits with tools Read, Bash, "
                + "and uses connectors tracker.",
            "Connector search runs `http: https://search.example/mcp`; expects headers Authorization.",
            "Connector tracker runs `npx -y tracker-mcp`; expects env TRACKER_TOKEN.",
            "Routine morning-brief prompts agent Scout at 08:30 on mon, fri, "
                + "after running the shell command `git log --since=yesterday --oneline`."
        ])
    }

    func testAnAgentThatSetsNeitherModeNorToolsIsSaidToTakeTheDefaults() throws {
        try writeManifest(#""agents": ["agents/plain"]"#)
        try write(#"{"handle": "plain", "template": {"name": "Plain"}}"#, to: "agents/plain/agent.json")

        let permissions = try PackInspector().inspect(folder: pack).permissions

        XCTAssertEqual(permissions, [
            "Agent plain (Plain) runs in the app's default permission mode with the app's default tools."
        ])
    }

    func testAnArmedRoutineIsReportedAsArmed() throws {
        try writeManifest(#""routines": ["poll.json"]"#)
        try write("""
            {"id": "poll", "name": "Poll", "project": "home", "agent": "Scout", "prompt": "Check.",
             "trigger": {"every": 30, "from": "09:00", "until": "18:00"}, "armed": true}
            """, to: "poll.json")

        let inspection = try PackInspector().inspect(folder: pack)

        XCTAssertEqual(inspection.permissions, [
            "Routine poll prompts agent Scout every 30 min from 09:00 until 18:00; the pack marks it armed."
        ])
    }

    func testNoSecretValueAppearsAnywhereInTheInspection() throws {
        try writeFullPack()

        let inspection = try PackInspector().inspect(folder: pack)
        let everything = String(describing: inspection) + inspection.account
            + inspection.permissions.joined(separator: "\n")

        XCTAssertFalse(everything.contains(Self.secret))
        XCTAssertFalse(everything.contains(Self.headerSecret))
        XCTAssertFalse(everything.contains("do-not-repeat"))
        XCTAssertTrue(everything.contains("TRACKER_TOKEN"), "the name is what a person needs to supply it")
        XCTAssertTrue(everything.contains("Authorization"))
    }

    func testEnvNamesAreListedWhenEnvIsNotPlainStrings() throws {
        try writeManifest(#""connectors": ["c.json"]"#)
        try write(#"{"odd": {"command": "run", "env": {"PORT": 8080, "KEY": "\#(Self.secret)"}}}"#, to: "c.json")

        let inspection = try PackInspector().inspect(folder: pack)

        XCTAssertEqual(inspection.connectors.map(\.envNames), [["KEY", "PORT"]])
        XCTAssertFalse(String(describing: inspection).contains(Self.secret))
    }

    func testTheAccountListsEachKindAndThenThePermissions() throws {
        try writeFullPack()

        let account = try PackInspector().inspect(folder: pack).account

        XCTAssertTrue(account.hasPrefix("Morning desk 1.2.0\nA daily brief.\n\nAgents (1)\n• @scout — Scout\n"))
        XCTAssertTrue(account.contains("\nRoutines (1)\n• morning-brief — Morning brief\n"))
        XCTAssertTrue(account.contains("\nConnectors (2)\n• search\n• tracker\n"))
        XCTAssertTrue(account.contains("\nTemplates (1)\n• standup.md — Standup notes\n"))
        XCTAssertTrue(account.contains("\nWhat it would be allowed to do (4)\n• Agent @scout"))
    }

    // MARK: - Templates

    func testATemplateIsTitledByItsJSONNameOrElseItsFileName() throws {
        try writeManifest(#""templates": ["t/reviewer.json", "t/notes.txt"]"#)
        try write(#"{"name": "Reviewer", "model": "opus"}"#, to: "t/reviewer.json")
        try write("no heading here\n", to: "t/notes.txt")

        let templates = try PackInspector().inspect(folder: pack).templates

        XCTAssertEqual(templates.map(\.title), ["Reviewer", "notes"])
        XCTAssertEqual(templates.map(\.fileName), ["reviewer.json", "notes.txt"])
    }

    // MARK: - Refusals

    func testAFolderWithoutAManifestIsNotAPack() throws {
        XCTAssertEqual(inspectionError(), .missingManifest(folder: pack.path))
    }

    func testAManifestThatDoesNotDecodeNamesTheFileAndTheField() throws {
        try write(#"{"name": "No version"}"#, to: "pack.json")

        let error = inspectionError()

        XCTAssertEqual(error, .undecodable(file: "pack.json", field: "version", reason: "is missing"))
        XCTAssertEqual(error?.errorDescription, "pack.json: `version` is missing.")
    }

    func testAManifestThatIsNotJSONIsRefused() throws {
        try write("name: Morning desk", to: "pack.json")

        XCTAssertEqual(inspectionError(), .undecodable(file: "pack.json", field: nil, reason: "is not valid JSON"))
    }

    func testAListedFileThatDoesNotDecodeNamesThatFileAndItsField() throws {
        try writeManifest(#""agents": ["agents/scout"]"#)
        try write(#"{"handle": "@scout", "template": {"name": "Scout", "tools": "Bash"}}"#,
                  to: "agents/scout/agent.json")

        XCTAssertEqual(inspectionError(), .undecodable(file: "agents/scout/agent.json", field: "template.tools",
                                                       reason: "has the wrong type"))
    }

    func testAListedPathThatDoesNotExistIsRefused() throws {
        try writeManifest(#""routines": ["routines/gone.json"]"#)

        let error = inspectionError()

        XCTAssertEqual(error, .missingPath(path: "routines/gone.json", field: "routines"))
        XCTAssertEqual(error?.errorDescription,
                       "pack.json: `routines` lists routines/gone.json, which is not in the pack.")
    }

    func testAnAgentFolderWithoutAnAgentFileIsRefused() throws {
        try writeManifest(#""agents": ["agents/hollow"]"#)
        try FileManager.default.createDirectory(at: pack.appendingPathComponent("agents/hollow"),
                                                withIntermediateDirectories: true)

        XCTAssertEqual(inspectionError(), .missingPath(path: "agents/hollow/agent.json", field: "agents"))
    }

    func testAListedPathThatClimbsOutOfThePackIsRefused() throws {
        let outside = try makeTemporaryDirectory(prefix: "pack-inspector-outside")
        pack = outside.appendingPathComponent("pack")
        try write(#"{"tracker": {"command": "npx"}}"#, to: "../outside.json")
        try writeManifest(#""connectors": ["../outside.json"]"#)

        XCTAssertEqual(inspectionError(), .escapesPack(path: "../outside.json", field: "connectors"))
    }

    func testAnAbsolutePathIsRefused() throws {
        try writeManifest(#""templates": ["/etc/hosts"]"#)

        XCTAssertEqual(inspectionError(), .escapesPack(path: "/etc/hosts", field: "templates"))
    }

    func testAListedPathThatLeavesThePackThroughASymlinkIsRefused() throws {
        let outside = try makeTemporaryDirectory(prefix: "pack-inspector-outside")
        try Data(#"{"tracker": {"command": "npx"}}"#.utf8).write(to: outside.appendingPathComponent("real.json"))
        try writeManifest(#""connectors": ["link.json"]"#)
        try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("link.json"),
                                                   withDestinationURL: outside.appendingPathComponent("real.json"))

        XCTAssertEqual(inspectionError(), .escapesPack(path: "link.json", field: "connectors"))
    }
}
