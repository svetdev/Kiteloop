import XCTest
import KiteloopCore
@testable import Kiteloop

/// A project whose `team.json` names agent packages boots with each package's
/// template, a workspace per agent, the package's `mcp.json` when it has one,
/// and its repos registered — and with the predefined team when no package in
/// the file resolves.
@MainActor
final class ProjectSessionPackageBootTeamTests: XCTestCase {
    private var tempDir: URL!
    private var knowledgeURL: URL!
    private var project: KiteloopProject!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "project-session-package-boot-team")
        knowledgeURL = tempDir.appending(path: "knowledge")
        let rootURL = tempDir.appending(path: "repo")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
    }

    // MARK: - Fixtures

    /// An agent package under the shared knowledge root, optionally with repos
    /// and an `mcp.json` beside its `agent.json`.
    private func writePackage(_ handle: String, repos: [String]? = nil, withMCP: Bool = false) throws {
        let dir = knowledgeURL.appending(path: "agents/\(handle)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reposField = repos.map { ", \"repos\": [\($0.map { "\"\($0)\"" }.joined(separator: ", "))]" } ?? ""
        let json = """
        {
          "handle": "@\(handle)",
          "version": "1.0.0",
          "template": { "name": "\(handle.capitalized)", "model": "sonnet", "systemPrompt": "You are \(handle)." },
          "knowledge": { "critical": [], "files": [], "imports": [] }\(reposField)
        }
        """
        try Data(json.utf8).write(to: dir.appending(path: "agent.json"))
        if withMCP {
            try Data(#"{"mcpServers": {}}"#.utf8).write(to: dir.appending(path: "mcp.json"))
        }
    }

    private func loadedResolver() async -> PackageResolver {
        let resolver = PackageResolver(scanPaths: [AgentScanPath(url: knowledgeURL, source: .shared)])
        await resolver.ensureLoaded()
        return resolver
    }

    private func team(_ handles: [String]) -> PackageTeamConfig {
        PackageTeamConfig(agents: handles.map {
            PackageAgentRef(id: $0, ref: "shared:\($0)", version: nil, overrides: nil)
        })
    }

    private func repoStore() -> RepoStatusStore {
        RepoStatusStore(cloneService: RepoCloneService(), linksURL: tempDir.appending(path: "repo-links.json"))
    }

    // MARK: - Tests

    func testEachPackageBootsWithItsTemplateWorkspaceMCPConfigAndRepos() async throws {
        let scout = "scout-\(UUID().uuidString.prefix(8))".lowercased()
        let plain = "plain-\(UUID().uuidString.prefix(8))".lowercased()
        try writePackage(scout, repos: ["acme/widgets"], withMCP: true)
        try writePackage(plain)
        let repos = repoStore()

        let booted = ProjectSession.packageBootTeam(
            config: team([scout, plain]), resolver: await loadedResolver(), project: project,
            bootSessionID: "boot-1", repoStatusStore: repos)

        XCTAssertEqual(Set(booted.templates.map(\.id)), [scout, plain])
        XCTAssertNotNil(booted.workspacePaths[scout])
        XCTAssertNotNil(booted.workspacePaths[plain])
        XCTAssertEqual(booted.mcpConfigPaths.keys.sorted(), [scout], "only the package with an mcp.json names one")
        XCTAssertTrue(try XCTUnwrap(booted.mcpConfigPaths[scout]).hasSuffix("agents/\(scout)/mcp.json"))
        XCTAssertEqual(repos.agentRepos[scout], ["acme/widgets"])
        XCTAssertNil(repos.agentRepos[plain], "a package with no repos registers none")
    }

    func testATeamWhosePackagesResolveToNothingBootsThePredefinedAgents() async throws {
        let booted = ProjectSession.packageBootTeam(
            config: team(["nowhere-\(UUID().uuidString.prefix(8))".lowercased()]),
            resolver: await loadedResolver(), project: project,
            bootSessionID: "boot-1", repoStatusStore: repoStore())

        XCTAssertEqual(booted.templates.map(\.id), AgentTemplate.predefined.map(\.id))
        XCTAssertTrue(booted.workspacePaths.isEmpty)
        XCTAssertTrue(booted.mcpConfigPaths.isEmpty)
    }
}
