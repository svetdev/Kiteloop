import XCTest
@testable import Kiteloop

/// Choosing a knowledge repository in Settings wrote the path to the config and
/// nothing rescanned: `reload()` re-reads the scan paths the resolver already
/// holds, and the provider handed to `init(scanPathsProvider:)` runs exactly
/// once, so the chosen repository's packages first appeared after a relaunch and
/// the setting looked broken. These pin that `rescanPaths` re-resolves the paths
/// against a new repository and that the packages under it become available in
/// the same session.
final class PackageResolverRescanTests: XCTestCase {

    private var tempHome: URL!
    private var oldRepo: URL!
    private var newRepo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = try makeTemporaryDirectory(prefix: "package-resolver-rescan-home")
        oldRepo = try makeTemporaryDirectory(prefix: "package-resolver-rescan-old")
        newRepo = try makeTemporaryDirectory(prefix: "package-resolver-rescan-new")
    }

    override func tearDownWithError() throws {
        tempHome = nil
        oldRepo = nil
        newRepo = nil
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

    // MARK: - Rescanning

    /// The defect itself: a resolver bootstrapped over a repository with no
    /// packages has to offer the package under the newly chosen one without a
    /// relaunch. `reload()` is asserted first because it is what the code used to
    /// have — it rescans the original paths and finds nothing.
    @MainActor
    func testRescanningAgainstANewRepositoryMakesItsPackagesAvailable() async throws {
        // Unique so a bundled example package can never stand in for the one
        // this test wrote.
        let handle = "rescout-\(UUID().uuidString.prefix(8))".lowercased()
        try writePackage(at: newRepo, handle: handle)

        let resolver = PackageResolver(scanPaths: [AgentScanPath(url: oldRepo, source: .shared)])
        await resolver.ensureLoaded()
        XCTAssertFalse(resolver.availablePackages.contains { $0.package.handleNormalized == handle })

        await resolver.reload()
        XCTAssertFalse(resolver.availablePackages.contains { $0.package.handleNormalized == handle })

        await resolver.rescanPaths(configuredRepoPath: newRepo.path(percentEncoded: false),
                                   home: tempHome)

        XCTAssertTrue(resolver.availablePackages.contains { $0.package.handleNormalized == handle })
    }

    /// The chosen repository is the shared source, so a ref written `shared:<name>`
    /// resolves to it — a path resolved under any other source would still list
    /// the package but resolve refs differently.
    @MainActor
    func testRescanningPutsTheChosenRepositoryOnTheScanPathsAsShared() async throws {
        let resolver = PackageResolver(scanPaths: [AgentScanPath(url: oldRepo, source: .shared)])
        await resolver.ensureLoaded()

        await resolver.rescanPaths(configuredRepoPath: newRepo.path(percentEncoded: false),
                                   home: tempHome)

        let shared = resolver.scanPaths.filter { $0.source == .shared }
        XCTAssertEqual(shared.map { $0.url.standardizedFileURL },
                       [newRepo.standardizedFileURL])
    }
}
