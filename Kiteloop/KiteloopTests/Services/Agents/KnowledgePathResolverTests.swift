import XCTest
import KiteloopCore
@testable import Kiteloop

/// The setup wizard copies a chosen knowledge repo to ~/.kiteloop/knowledge and
/// reports it installed, but no scan path used to cover that directory — the
/// agent list stayed empty forever after. These pin that `resolveScanPaths`
/// covers both user-sourced directories, and that a package under either one
/// resolves, with a handle present in both counted once.
final class KnowledgePathResolverTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = try makeTemporaryDirectory(prefix: "knowledge-path-resolver")
    }

    override func tearDownWithError() throws {
        tempHome = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func writePackage(at scanRoot: URL, handle: String) throws {
        let dir = scanRoot.appending(path: "agents/\(handle)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {
          "handle": "@\(handle)",
          "version": "1.0.0",
          "template": {
            "name": "\(handle.capitalized)",
            "model": "claude-opus-5",
            "systemPrompt": "You are \(handle)."
          },
          "knowledge": { "critical": [], "files": [], "imports": [] }
        }
        """
        try Data(json.utf8).write(to: dir.appending(path: "agent.json"))
    }

    // MARK: - resolveScanPaths

    func testResolveScanPathsIncludesBothTheDotKiteloopAndTheKnowledgeRepoPaths() {
        let paths = KnowledgePathResolver.resolveScanPaths(configuredRepoPath: nil, home: tempHome)

        let userPaths = paths.filter { $0.source == .user }
        let userURLs = Set(userPaths.map { $0.url.standardizedFileURL })
        XCTAssertTrue(userURLs.contains(tempHome.appending(path: ".kiteloop").standardizedFileURL))
        XCTAssertTrue(userURLs.contains(tempHome.appending(path: ".kiteloop/knowledge").standardizedFileURL))
    }

    /// An isolated home never reaches into the source checkout — on a QA run
    /// that read sat behind a Documents-access prompt nobody was there to answer.
    func testAnIsolatedHomeScansNoSharedPathFromTheCheckout() {
        let paths = KnowledgePathResolver.resolveScanPaths(
            configuredRepoPath: nil, home: tempHome,
            environment: [KiteloopHome.variable: tempHome.path(percentEncoded: false)])
        XCTAssertFalse(paths.contains { $0.source == .shared })
    }

    // MARK: - Scanning both paths

    /// A package written where the wizard actually copies to — <home>/.kiteloop/knowledge —
    /// has to show up, or the wizard's "knowledge installed" state is a dead end.
    @MainActor
    func testAPackageUnderTheKnowledgeRepoDirectoryResolves() async throws {
        let knowledgeRoot = tempHome.appending(path: ".kiteloop/knowledge")
        try writePackage(at: knowledgeRoot, handle: "scout")

        let paths = KnowledgePathResolver.resolveScanPaths(configuredRepoPath: nil, home: tempHome)
        let resolver = PackageResolver(scanPaths: paths)
        await resolver.ensureLoaded()

        XCTAssertTrue(resolver.availablePackages.contains { $0.package.handleNormalized == "scout" })
    }

    /// The existing ~/.kiteloop/agents path must keep working alongside the new one.
    @MainActor
    func testAPackageUnderTheDotKiteloopAgentsDirectoryStillResolves() async throws {
        let userRoot = tempHome.appending(path: ".kiteloop")
        try writePackage(at: userRoot, handle: "reviewer")

        let paths = KnowledgePathResolver.resolveScanPaths(configuredRepoPath: nil, home: tempHome)
        let resolver = PackageResolver(scanPaths: paths)
        await resolver.ensureLoaded()

        XCTAssertTrue(resolver.availablePackages.contains { $0.package.handleNormalized == "reviewer" })
    }

    /// A handle present under both user-sourced paths is listed once, with the
    /// entry under ~/.kiteloop/agents winning — the existing dedup order is
    /// preserved rather than disturbed by the new path.
    @MainActor
    func testAHandlePresentUnderBothUserPathsIsListedOnce() async throws {
        let userRoot = tempHome.appending(path: ".kiteloop")
        let knowledgeRoot = tempHome.appending(path: ".kiteloop/knowledge")
        try writePackage(at: userRoot, handle: "scout")
        try writePackage(at: knowledgeRoot, handle: "scout")

        let paths = KnowledgePathResolver.resolveScanPaths(configuredRepoPath: nil, home: tempHome)
        let resolver = PackageResolver(scanPaths: paths)
        await resolver.ensureLoaded()

        let matches = resolver.availablePackages.filter { $0.package.handleNormalized == "scout" }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.packageURL.standardizedFileURL,
                        userRoot.appending(path: "agents/scout").standardizedFileURL)
    }
}
