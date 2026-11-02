import XCTest
import KiteloopCore
@testable import Kiteloop

/// The registry the local control API resolves `?project=` against. The lookup
/// is deliberately forgiving (canonical path, raw path, folder name), so these
/// tests pin down both what it accepts and what it must not confuse.
@MainActor
final class ControlSessionRegistryTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "control-session-registry")
        registry = ControlSessionRegistry()
    }

    override func tearDownWithError() throws {
        registry = nil
        try super.tearDownWithError()
    }

    // MARK: - register / unregister

    func testRegisterKeysEntryByProjectID() throws {
        let session = try makeSession(named: "alpha")
        registry.register(session: session, autopilot: BacklogAutopilot())

        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertNotNil(registry.entries[session.project.id])
    }

    func testRegisterStoresBothSessionAndAutopilot() throws {
        let session = try makeSession(named: "alpha")
        let autopilot = BacklogAutopilot()
        registry.register(session: session, autopilot: autopilot)

        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))
        XCTAssertTrue(entry.session === session)
        XCTAssertTrue(entry.autopilot === autopilot)
    }

    /// Re-opening the same project must replace the entry rather than accumulate,
    /// otherwise the control API could drive a stale autopilot.
    func testRegisteringSameProjectTwiceReplacesEntry() throws {
        let session = try makeSession(named: "alpha")
        let first = BacklogAutopilot()
        let second = BacklogAutopilot()
        registry.register(session: session, autopilot: first)
        registry.register(session: session, autopilot: second)

        XCTAssertEqual(registry.entries.count, 1)
        let entry = try XCTUnwrap(registry.entries[session.project.id])
        XCTAssertTrue(entry.autopilot === second)
    }

    func testUnregisterRemovesEntryFromEveryLookupForm() async throws {
        let session = try makeSession(named: "alpha")
        registry.register(session: session, autopilot: BacklogAutopilot())
        await registry.unregister(projectID: session.project.id)

        XCTAssertTrue(registry.entries.isEmpty)
        XCTAssertNil(registry.entry(forProject: session.project.id))
        XCTAssertNil(registry.entry(forProject: session.project.id + "/"))
        XCTAssertNil(registry.entry(forProject: "alpha"))
        XCTAssertTrue(registry.openProjects.isEmpty)
    }

    func testUnregisterUnknownProjectIsNoOp() async throws {
        let session = try makeSession(named: "alpha")
        registry.register(session: session, autopilot: BacklogAutopilot())

        await registry.unregister(projectID: "/nowhere/beta")

        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertNotNil(registry.entry(forProject: "alpha"))
    }

    func testUnregisterLeavesOtherProjectsRegistered() async throws {
        let alpha = try makeSession(named: "alpha")
        let beta = try makeSession(named: "beta")
        registry.register(session: alpha, autopilot: BacklogAutopilot())
        registry.register(session: beta, autopilot: BacklogAutopilot())

        await registry.unregister(projectID: alpha.project.id)

        XCTAssertNil(registry.entry(forProject: "alpha"))
        XCTAssertTrue(try XCTUnwrap(registry.entry(forProject: "beta")).session === beta)
    }

    // MARK: - entry(forProject:) — canonical path

    func testEntryResolvesByCanonicalPath() throws {
        let session = try makeSession(named: "alpha")
        registry.register(session: session, autopilot: BacklogAutopilot())

        let entry = try XCTUnwrap(registry.entry(forProject: session.project.id))
        XCTAssertTrue(entry.session === session)
    }

    /// NSOpenPanel hands back directory URLs with a trailing slash while recents
    /// and the control API usually don't — both spellings must find the project.
    func testEntryResolvesTrailingSlashPathToCanonicalKey() throws {
        let session = try makeSession(named: "alpha", trailingSlash: true)
        registry.register(session: session, autopilot: BacklogAutopilot())

        let canonical = KiteloopProject.canonicalPath(
            session.project.rootURL.path(percentEncoded: false)
        )
        XCTAssertFalse(canonical.hasSuffix("/"))
        XCTAssertNotNil(registry.entries[canonical], "entries must be keyed by the canonical path")
        XCTAssertNotNil(registry.entry(forProject: canonical))
        XCTAssertNotNil(registry.entry(forProject: canonical + "/"))
        XCTAssertNotNil(registry.entry(forProject: canonical + "///"))
    }

    // MARK: - entry(forProject:) — raw path

    /// `POST /v1/runs` resolves a freshly opened project by `url.path(...)`, so
    /// the raw path of the registering URL has to find it — whether or not that
    /// spelling matches the canonical key.
    func testEntryResolvesByRawPath() throws {
        // No trailing slash: the raw path is the stored key.
        let plain = try makeSession(named: "alpha")
        registry.register(session: plain, autopilot: BacklogAutopilot())
        let plainRaw = plain.project.rootURL.path(percentEncoded: false)
        XCTAssertFalse(plainRaw.hasSuffix("/"))
        XCTAssertTrue(try XCTUnwrap(registry.entry(forProject: plainRaw)).session === plain)

        // Trailing slash (how a directory URL from NSOpenPanel spells it): the
        // raw path differs from the stored key and must still resolve.
        let slashed = try makeSession(named: "beta", trailingSlash: true)
        registry.register(session: slashed, autopilot: BacklogAutopilot())
        let slashedRaw = slashed.project.rootURL.path(percentEncoded: false)
        XCTAssertTrue(slashedRaw.hasSuffix("/"))
        XCTAssertTrue(try XCTUnwrap(registry.entry(forProject: slashedRaw)).session === slashed)
    }

    // MARK: - entry(forProject:) — trailing folder name

    func testEntryResolvesByTrailingFolderName() throws {
        let session = try makeSession(named: "alpha")
        registry.register(session: session, autopilot: BacklogAutopilot())

        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))
        XCTAssertTrue(entry.session === session)
    }

    func testEntryResolvesByTrailingFolderNameAmongSeveralProjects() throws {
        let alpha = try makeSession(named: "alpha")
        let beta = try makeSession(named: "beta")
        registry.register(session: alpha, autopilot: BacklogAutopilot())
        registry.register(session: beta, autopilot: BacklogAutopilot())

        XCTAssertTrue(try XCTUnwrap(registry.entry(forProject: "alpha")).session === alpha)
        XCTAssertTrue(try XCTUnwrap(registry.entry(forProject: "beta")).session === beta)
        XCTAssertTrue(try XCTUnwrap(registry.entry(forProject: beta.project.id)).session === beta)
    }

    /// The name fallback compares the last path component only — a full path that
    /// merely ends in a registered project's folder name is a different project
    /// and must not resolve.
    func testEntryDoesNotResolveSameFolderNameUnderDifferentParent() throws {
        let session = try makeSession(named: "alpha")
        registry.register(session: session, autopilot: BacklogAutopilot())

        XCTAssertNil(registry.entry(forProject: "/somewhere/else/alpha"))
    }

    func testEntryReturnsNilWhenNothingRegistered() {
        XCTAssertNil(registry.entry(forProject: "alpha"))
        XCTAssertNil(registry.entry(forProject: "/tmp/alpha"))
        XCTAssertTrue(registry.entries.isEmpty)
    }

    func testEntryReturnsNilForUnknownProject() throws {
        let session = try makeSession(named: "alpha")
        registry.register(session: session, autopilot: BacklogAutopilot())

        XCTAssertNil(registry.entry(forProject: "beta"))
        XCTAssertNil(registry.entry(forProject: "/tmp/beta"))
        XCTAssertNil(registry.entry(forProject: ""))
    }

    // MARK: - registeredEntry(projectID:)

    /// A reopened window adopts the live session through this lookup, so it has
    /// to hand back the very instances registered — and nothing once unregistered.
    func testRegisteredEntryReturnsSameInstancesUntilUnregistered() async throws {
        let session = try makeSession(named: "alpha")
        let autopilot = BacklogAutopilot()
        registry.register(session: session, autopilot: autopilot)

        let entry = try XCTUnwrap(registry.registeredEntry(projectID: session.project.id))
        XCTAssertTrue(entry.session === session)
        XCTAssertTrue(entry.autopilot === autopilot)

        await registry.unregister(projectID: session.project.id)
        XCTAssertNil(registry.registeredEntry(projectID: session.project.id))
    }

    /// Unlike `entry(forProject:)`, no folder-name fallback: a different path
    /// ending in a registered project's folder name must not adopt its session.
    func testRegisteredEntryMatchesOnlyTheExactProjectID() throws {
        let session = try makeSession(named: "alpha")
        registry.register(session: session, autopilot: BacklogAutopilot())

        let other = tempDir.appendingPathComponent("elsewhere/alpha").path(percentEncoded: false)
        XCTAssertNotNil(registry.entry(forProject: "alpha"))
        XCTAssertNil(registry.registeredEntry(projectID: "alpha"))
        XCTAssertNil(registry.registeredEntry(projectID: KiteloopProject.canonicalPath(other)))
    }

    // MARK: - What opening a project in the window does with it

    /// A project already open in this window is refreshed in place — the same
    /// session, not a second one.
    func testOpeningAProjectAlreadyOpenRefreshesItsSession() throws {
        let session = try makeSession(named: "alpha")
        registry.register(session: session, autopilot: BacklogAutopilot())

        let attachment = MainWindow.sessionAttachment(
            for: session.project.id, open: [session.project.id: session], registry: registry)

        guard case .refresh(let refreshed) = attachment else {
            return XCTFail("an open project is refreshed, got \(attachment)")
        }
        XCTAssertTrue(refreshed === session)
    }

    /// Reopening the main window after the last one closed: the window holds
    /// nothing, the app still holds the project's live session and autopilot,
    /// and those are what the window takes over — not a freshly booted copy.
    func testReopeningTheWindowAdoptsTheLiveSessionAndAutopilot() throws {
        let session = try makeSession(named: "alpha")
        let autopilot = BacklogAutopilot()
        registry.register(session: session, autopilot: autopilot)

        let attachment = MainWindow.sessionAttachment(for: session.project.id, open: [:], registry: registry)

        guard case .adopt(let entry) = attachment else {
            return XCTFail("a registered project is adopted, got \(attachment)")
        }
        XCTAssertTrue(entry.session === session)
        XCTAssertTrue(entry.autopilot === autopilot)
    }

    /// A project nothing holds is booted — including one that merely shares a
    /// registered project's folder name.
    func testAProjectNothingHoldsIsBootstrapped() throws {
        let session = try makeSession(named: "alpha")
        registry.register(session: session, autopilot: BacklogAutopilot())
        let other = KiteloopProject.canonicalPath(
            tempDir.appendingPathComponent("elsewhere/alpha").path(percentEncoded: false))

        let attachment = MainWindow.sessionAttachment(for: other, open: [:], registry: registry)

        guard case .bootstrap = attachment else {
            return XCTFail("a project nothing holds is booted, got \(attachment)")
        }
    }

    // MARK: - openProjects

    func testOpenProjectsIsSortedByFolderName() throws {
        let charlie = try makeSession(named: "charlie")
        let alpha = try makeSession(named: "alpha")
        let beta = try makeSession(named: "beta")
        for session in [charlie, alpha, beta] {
            registry.register(session: session, autopilot: BacklogAutopilot())
        }

        XCTAssertEqual(
            registry.openProjects.map { $0.session.project.rootURL.lastPathComponent },
            ["alpha", "beta", "charlie"]
        )
    }

    // MARK: - Helpers

    /// Builds a real `ProjectSession` over a throwaway directory, skipping
    /// `bootstrap` so no agent is started — the registry only ever reads the
    /// session's project identity.
    private func makeSession(named name: String, trailingSlash: Bool = false) throws -> ProjectSession {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = trailingSlash
            ? URL(fileURLWithPath: root.path(percentEncoded: false) + "/", isDirectory: true)
            : URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )

        return ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
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
