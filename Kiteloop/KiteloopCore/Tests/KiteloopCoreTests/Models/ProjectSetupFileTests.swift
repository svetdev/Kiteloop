import XCTest
@testable import KiteloopCore

/// The setup file: what `make` takes from a project and what it leaves on
/// the Mac.
final class ProjectSetupFileTests: XCTestCase {

    private func ref(_ id: String, servers: [String]?) -> PackageAgentRef {
        PackageAgentRef(id: id, ref: "shared:\(id)", version: nil,
                        overrides: servers.map { AgentOverrides(mcpServers: $0) })
    }

    private func routine(_ id: String, armed: Bool) -> Routine {
        Routine(id: id, name: id, project: "alpha", agent: "chief", prompt: "Go.",
                trigger: Routine.Trigger(at: "07:00"), armed: armed,
                armedAt: armed ? Date(timeIntervalSince1970: 1_800_000_000) : nil)
    }

    private func settledConfig() -> ProjectConfig {
        var config = ProjectConfig(model: "opus", permissionMode: "plan", deniedTools: ["Bash"],
                                   agentSessionIDs: ["chief": "session-secret-id"], claudeCodeVersion: "9.9.9",
                                   effort: "high", maxBudgetUSD: 4.5,
                                   observability: OTLPConfig(enabled: true, endpoint: "https://otel.example/v1",
                                                             headers: ["x-api-key": "otel-secret-key"],
                                                             batchSize: 10, flushIntervalSeconds: 5),
                                   paused: true, goal: "Ship.", extraExecutablePaths: ["/opt/private/bin"],
                                   buildEnvironment: ["DEPLOY_TOKEN": "build-secret-value"])
        var bedrock = BedrockConfig.default
        bedrock.profile = "bedrock-secret-profile"
        bedrock.roleARN = "arn:aws:iam::123456789012:role/secret"
        config.bedrock = bedrock
        config.pinnedDocument = "docs/brief.md"
        config.companions = [CompanionRepo(name: "site", path: "../site", baseBranch: "main")]
        return config
    }

    func testEveryRoutineIsDisarmed() {
        let file = ProjectSetupFile.make(config: .default, team: nil,
                                         routines: [routine("a", armed: true), routine("b", armed: false)])

        XCTAssertEqual(file.routines.map(\.id), ["a", "b"])
        XCTAssertTrue(file.routines.allSatisfy { !$0.armed && $0.armedAt == nil })
        XCTAssertEqual(file.routines.first?.prompt, "Go.", "the rest of the routine travels")
    }

    func testItKeepsTheSixSettingsAndThePinnedDocument() throws {
        let file = ProjectSetupFile.make(config: settledConfig(), team: nil, routines: [])

        XCTAssertEqual(file.settings, ProjectSetupFile.Settings(
            model: "opus", permissionMode: "plan", effort: "high", maxBudgetUSD: 4.5, goal: "Ship.",
            companions: [CompanionRepo(name: "site", path: "../site", baseBranch: "main")]))
        XCTAssertEqual(file.pinnedDocument, "docs/brief.md")
        XCTAssertEqual(file.format, 1)

        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(file.settings)) as? [String: Any])
        XCTAssertEqual(Set(settings.keys), ["model", "permissionMode", "effort", "maxBudgetUSD", "goal", "companions"])
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any])
        XCTAssertEqual(Set(top.keys), ["format", "team", "routines", "settings", "pinnedDocument", "connectors"])
    }

    func testConnectorsAreTheSortedUnionOfTheAgentsServers() {
        let team = PackageTeamConfig(agents: [
            ref("chief", servers: ["linear", "github"]),
            ref("builder", servers: ["github", "sentry"]),
            ref("writer", servers: nil),
            ref("quiet", servers: [])
        ])

        let file = ProjectSetupFile.make(config: .default, team: team, routines: [])

        XCTAssertEqual(file.connectors, ["github", "linear", "sentry"])
        XCTAssertEqual(file.team, team)
    }

    func testNothingMachineBoundOrSecretIsInTheFile() throws {
        let file = ProjectSetupFile.make(config: settledConfig(), team: nil, routines: [])
        let json = try XCTUnwrap(String(data: file.encoded(), encoding: .utf8))

        for key in ["bedrock", "observability", "buildEnvironment", "agentSessionIDs", "extraExecutablePaths",
                    "deniedTools", "claudeCodeVersion", "paused"] {
            XCTAssertFalse(json.contains("\"\(key)\""), "\(key) is in the file")
        }
        for value in ["bedrock-secret-profile", "arn:aws:iam", "otel-secret-key", "otel.example",
                      "build-secret-value", "DEPLOY_TOKEN", "session-secret-id", "/opt/private/bin"] {
            XCTAssertFalse(json.contains(value), "\(value) is in the file")
        }
    }

    func testTheFileReadsBackEqual() throws {
        let team = PackageTeamConfig(agents: [ref("chief", servers: ["github"])])
        let file = ProjectSetupFile.make(config: settledConfig(), team: team, routines: [routine("brief", armed: true)])

        XCTAssertEqual(try ProjectSetupFile.decoded(from: file.encoded()), file)

        let empty = ProjectSetupFile.make(config: .default, team: nil, routines: [])
        XCTAssertEqual(try ProjectSetupFile.decoded(from: empty.encoded()), empty)
    }
}
