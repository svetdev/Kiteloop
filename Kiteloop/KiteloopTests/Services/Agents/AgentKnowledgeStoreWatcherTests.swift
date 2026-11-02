import XCTest
import KiteloopCore
@testable import Kiteloop

/// `AgentKnowledgeStore` opens an `O_EVTONLY` descriptor on the project's
/// `knowledge/agents` directory in `init` and arms a dispatch source on it.
/// Nothing ever cancelled that source, and a resumed source is not deallocated
/// until it is cancelled — so every project open leaked one descriptor and one
/// live kevent registration for the life of the process, as did every test that
/// constructed a store.
///
/// "Closed once" is not readable off the code — the close happens in a cancel
/// handler, asynchronously and silently — so these tests count the closes
/// through the closer the store releases its descriptor with.
final class AgentKnowledgeStoreWatcherTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "agent-knowledge-store-watcher-test")
        try FileManager.default.createDirectory(
            at: tempDir.appending(path: "agents"),
            withIntermediateDirectories: true
        )
    }

    // MARK: - Descriptor ownership

    func testStopThenDeinitClosesTheDescriptorExactlyOnce() async throws {
        let closes = CloseRecorder()
        var store: AgentKnowledgeStore? = AgentKnowledgeStore(
            baseURL: tempDir,
            closeDescriptor: { closes.record($0) }
        )

        store?.stop()
        try await eventually("the cancel handler released the descriptor") { closes.count == 1 }
        XCTAssertEqual(closes.count, 1, "stop() must leave the close to the cancel handler")

        store = nil                         // deinit calls stop() again
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(closes.count, 1, "deinit after stop() must not close the fd a second time")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(closes.descriptors.first), 0, "a real descriptor was closed")
    }

    func testStopCalledTwiceClosesTheDescriptorExactlyOnce() async throws {
        let closes = CloseRecorder()
        let store = AgentKnowledgeStore(baseURL: tempDir, closeDescriptor: { closes.record($0) })
        defer { store.stop() }

        store.stop()
        store.stop()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(closes.count, 1)
    }

    /// `deinit` on its own is every caller that builds a store and drops it — a
    /// project switch, and every test that constructs one. The cancel handler
    /// runs after the store is gone, so it must not need it.
    func testDeinitWithoutStopClosesTheDescriptorExactlyOnce() async throws {
        let closes = CloseRecorder()
        var store: AgentKnowledgeStore? = AgentKnowledgeStore(
            baseURL: tempDir,
            closeDescriptor: { closes.record($0) }
        )

        store = nil
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(store)
        XCTAssertEqual(closes.count, 1, "the descriptor must not leak when only deinit releases the store")
    }

    /// `startWatching` returns early when `open` fails — a project with no
    /// `knowledge/agents` directory. There is no descriptor to release, and
    /// `stop()` must not release the `-1` that stands in for one.
    func testStoreThatNeverOpenedADescriptorClosesNothing() async throws {
        let closes = CloseRecorder()
        var store: AgentKnowledgeStore? = AgentKnowledgeStore(
            baseURL: tempDir.appending(path: "no-such-directory"),
            closeDescriptor: { closes.record($0) }
        )

        store?.stop()
        store = nil
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(closes.count, 0)
    }

    // MARK: - Watching

    /// The control for the test below: an unstopped store does see the write, so
    /// the silence after `stop()` is the cancel and not a test that watches
    /// nothing.
    func testWritingIntoTheWatchedDirectoryReloads() async throws {
        let store = AgentKnowledgeStore(baseURL: tempDir)
        defer { store.stop() }
        let initial = await agentNames(of: store)
        XCTAssertEqual(initial, [])

        try writeAgent(named: "Reviewer")

        try await eventually("the watcher reported the write") { await agentNames(of: store) == ["Reviewer"] }
        let namesAfterWrite = await agentNames(of: store)
        XCTAssertEqual(namesAfterWrite, ["Reviewer"], "the watcher never reported the write")
    }

    func testStopPreventsReload() async throws {
        let store = AgentKnowledgeStore(baseURL: tempDir)
        store.stop()

        try writeAgent(named: "Reviewer")
        try await Task.sleep(for: .milliseconds(300))

        let namesAfterWrite = await agentNames(of: store)
        XCTAssertEqual(namesAfterWrite, [], "a stopped store must not reload")
    }

    // MARK: - Project teardown

    /// Closing a project tab calls `shutdown()`; that is the one place the leak
    /// was reachable from in the app.
    @MainActor
    func testProjectSessionShutdownStopsTheKnowledgeStore() async throws {
        let closes = CloseRecorder()
        let project = KiteloopProject(rootURL: tempDir)
        try project.ensureDirectoryExists()

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: tempDir,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: tempDir),
            knowledgeStore: AgentKnowledgeStore(baseURL: tempDir, closeDescriptor: { closes.record($0) }),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: ProjectSessionContext(
                runtimeFactory: { MockAgentRuntime() },
                agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appending(path: "catalog.json")),
                packageResolver: nil,
                globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")),
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()
            )
        )

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(closes.count, 0, "the store holds its descriptor while the project is open")

        session.shutdown()
        try await eventually("shutdown() released the descriptor") { closes.count == 1 }

        XCTAssertEqual(closes.count, 1, "shutdown() must release the knowledge store's descriptor")
    }

    // MARK: - Helpers

    /// Writes a minimal knowledge package — a directory with a `profile.md`,
    /// which is all `loadAgent` needs to count it. Built outside the watched
    /// directory and moved in, so the one event the store sees is a package that
    /// is already complete: creating the directory first would let `reload()`
    /// run against it before the profile lands, and it would then see nothing.
    private func writeAgent(named name: String) throws {
        let staged = tempDir.appending(path: "staging/\(name.lowercased())")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try "---\nname: \(name)\n---\n\nA profile.\n"
            .write(to: staged.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(
            at: staged,
            to: tempDir.appending(path: "agents/\(name.lowercased())")
        )
    }

}

/// `agents` is written by the store's event handler on the main queue, so it is
/// read there too. A free function rather than a method: hopping to the main
/// actor from a test method would send the non-`Sendable` `XCTestCase` with it.
@MainActor
private func agentNames(of store: AgentKnowledgeStore) -> [String] {
    store.agents.map(\.name)
}

/// Thread-safe tally of the descriptors the store released. The closer runs on
/// the dispatch source's queue, and it really closes the fd so a test never
/// leaks one.
private final class CloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _descriptors: [Int32] = []

    var descriptors: [Int32] { lock.withLock { _descriptors } }
    var count: Int { lock.withLock { _descriptors.count } }

    func record(_ fd: Int32) {
        lock.withLock { _descriptors.append(fd) }
        close(fd)
    }
}
