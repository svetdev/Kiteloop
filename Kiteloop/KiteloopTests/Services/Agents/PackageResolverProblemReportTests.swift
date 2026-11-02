import XCTest
import KiteloopCore
@testable import Kiteloop

/// A package whose `agent.json` would not decode used to be indistinguishable
/// from a directory that never had one: both fell through the same `try?` and
/// the agent simply never appeared — not in the sidebar, not in the team config,
/// not in any hire. These pin the split: the unreadable one is reported, the
/// directory that is not a package stays silent, and either way the scan
/// finishes and the other packages resolve.
final class PackageResolverProblemReportTests: XCTestCase {

    /// Records what reached the inbox without keeping a file around: these tests
    /// care about which rows were filed, not how they are persisted.
    private actor StubNotificationStore: NotificationStoring {
        private var items: [NotificationItem] = []
        private var resolvedItems: [NotificationItem] = []

        func add(_ item: NotificationItem) async { items.append(item) }

        func markResolved(id: String) async {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            resolvedItems.append(items.remove(at: index))
        }

        func resolveApprovals(itemID: String, closure: GateClosure) async -> Int { 0 }

        func resolveQuestions(agentID: String, closure: GateClosure) async -> Int { 0 }

        func backfillPassedNotices(itemsAtGate: Set<String>) async -> Int { 0 }

        func dismiss(id: String) async { items.removeAll { $0.id == id } }

        func dismissAllPending(actionable: Bool) async { items.removeAll() }

        func pending() async -> [NotificationItem] { items }

        func resolved() async -> [NotificationItem] { resolvedItems }

        func pendingCount() async -> Int { items.count }

        func actionablePendingCount() async -> Int { items.count }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "package-resolver")
    }

    override func tearDownWithError() throws {
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A package the resolver can read, so a scan has something to still return
    /// alongside the one that fails.
    private func writePackage(handle: String) throws -> URL {
        let dir = tempDir.appending(path: "agents/\(handle)")
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
        return dir
    }

    @discardableResult
    private func writeUndecodablePackage(handle: String, contents: String = "{ not json") throws -> URL {
        let dir = tempDir.appending(path: "agents/\(handle)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "agent.json")
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func writeDirectoryWithoutAgentJSON(named name: String) throws {
        let dir = tempDir.appending(path: "agents/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: dir.appending(path: "README.md"))
    }

    @MainActor
    private func scannedPackages(reporter: StoreProblemReporter) async -> [SourcedPackage] {
        let resolver = PackageResolver(scanPaths: [AgentScanPath(url: tempDir, source: .shared)],
                                       reporter: reporter)
        await resolver.ensureLoaded()
        return resolver.availablePackages
    }

    // MARK: - Reporting

    /// The failure this is for: one typo in a hand-written package and the agent
    /// is gone with nothing said. The row has to name the file and the error, and
    /// the rest of the scan has to survive it.
    @MainActor
    func testAnUndecodableAgentJSONIsReportedAndTheOtherPackagesStillResolve() async throws {
        let inbox = StubNotificationStore()
        let reporter = StoreProblemReporter(notifications: inbox)
        let broken = try writeUndecodablePackage(handle: "broken")
        _ = try writePackage(handle: "scout")
        _ = try writePackage(handle: "reviewer")

        let packages = await scannedPackages(reporter: reporter)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not read Agent packages")
        XCTAssertEqual(pending.first?.body.contains(broken.path(percentEncoded: false)), true)
        // The decode error itself, not a "could not be completed" placeholder.
        XCTAssertEqual(pending.first?.body.contains("dataCorrupted"), true)

        XCTAssertEqual(packages.map { $0.package.handleNormalized }, ["reviewer", "scout"])
    }

    /// The Diagnostics line stands beside the row, so someone reading the log has
    /// the same file and the same error without opening the inbox.
    @MainActor
    func testAnUndecodableAgentJSONWritesADiagnosticsLine() async throws {
        let reporter = StoreProblemReporter(notifications: StubNotificationStore())
        let marker = "handle-\(UUID().uuidString.prefix(8))"
        let broken = try writeUndecodablePackage(handle: String(marker))

        _ = await scannedPackages(reporter: reporter)
        await reporter.drain()

        let lines = KiteloopFileLogger.shared.snapshot()
            .filter { $0.category == StoreProblemReporter.logCategory && $0.message.contains(marker) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.levelTag, "ERROR")
        XCTAssertEqual(lines.first?.message.contains("Agent packages"), true)
        XCTAssertEqual(lines.first?.message.contains("read"), true)
        XCTAssertEqual(lines.first?.message.contains(broken.path(percentEncoded: false)), true)
    }

    /// A file present but unreadable — not a decode failure — is the same problem
    /// from the human's side, and is reported the same way.
    @MainActor
    func testAnUnreadableAgentJSONIsReported() async throws {
        let inbox = StubNotificationStore()
        let reporter = StoreProblemReporter(notifications: inbox)
        // A directory where `agent.json` should be: it exists, and reading it fails.
        let dir = tempDir.appending(path: "agents/unreadable/agent.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        _ = await scannedPackages(reporter: reporter)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.body.contains(dir.path(percentEncoded: false)), true)
    }

    // MARK: - Silence

    /// A directory with no `agent.json` is not a package. Reporting every stray
    /// folder under `agents/` would bury the one report that matters.
    @MainActor
    func testADirectoryWithoutAnAgentJSONIsSilent() async throws {
        let inbox = StubNotificationStore()
        let reporter = StoreProblemReporter(notifications: inbox)
        let marker = "stray-\(UUID().uuidString.prefix(8))"
        try writeDirectoryWithoutAgentJSON(named: String(marker))
        _ = try writePackage(handle: "scout")

        let packages = await scannedPackages(reporter: reporter)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
        let lines = KiteloopFileLogger.shared.snapshot()
            .filter { $0.category == StoreProblemReporter.logCategory && $0.message.contains(marker) }
        XCTAssertEqual(lines.count, 0)
        XCTAssertEqual(packages.map { $0.package.handleNormalized }, ["scout"])
    }

    /// Two broken packages are one problem — "your packages will not read" — and
    /// the reporter keys on store and operation, so they share the one row.
    @MainActor
    func testTwoUndecodablePackagesLeaveASingleRow() async throws {
        let inbox = StubNotificationStore()
        let reporter = StoreProblemReporter(notifications: inbox)
        try writeUndecodablePackage(handle: "broken-one")
        try writeUndecodablePackage(handle: "broken-two", contents: "{\"handle\": \"@two\"}")

        _ = await scannedPackages(reporter: reporter)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
    }

    /// Reporting is all this does: the package is skipped, not defaulted or
    /// substituted, so the roster is exactly what it was before the report.
    @MainActor
    func testTheBrokenPackageIsSkippedRatherThanSubstituted() async throws {
        let reporter = StoreProblemReporter(notifications: StubNotificationStore())
        try writeUndecodablePackage(handle: "broken")
        _ = try writePackage(handle: "scout")

        let packages = await scannedPackages(reporter: reporter)

        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages.first?.package.handleNormalized, "scout")
        XCTAssertEqual(packages.first?.package.template.name, "Scout")
    }

    /// A scan that finds nothing wrong says nothing at all.
    @MainActor
    func testAScanOfGoodPackagesReportsNothing() async throws {
        let inbox = StubNotificationStore()
        let reporter = StoreProblemReporter(notifications: inbox)
        _ = try writePackage(handle: "scout")

        let packages = await scannedPackages(reporter: reporter)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
        XCTAssertEqual(packages.count, 1)
    }
}
