// Kiteloop/KiteloopTests/ViewModels/ProjectSessionShutdownTests.swift
import XCTest
import KiteloopCore
@testable import Kiteloop

/// Closing a project tab used to release the knowledge store and nothing else.
/// Every agent stayed subscribed — `stopAgent(_:)` doesn't unsubscribe — so the
/// watch task, the engine it strongly references and the `EventBus` behind it
/// all outlived the tab, one set per open, for the life of the process.
///
/// This pins the seam that fixes it: `shutdown()` reaches the orchestrator's
/// stop-subscriptions entry point, and an event published on the closed
/// project's bus afterwards reaches nobody.
final class ProjectSessionShutdownTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "project-session-shutdown-test")
    }

    @MainActor
    func testShutdownDropsSubscriptionsSoAClosedProjectFiresNoTrigger() async throws {
        let rootURL = tempDir.appending(path: "repo")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        let triggered = expectation(description: "should not trigger after the tab closes")
        triggered.isInverted = true

        let eventBus = EventBus(eventsURL: project.eventsURL)
        // The handler goes on the engine directly rather than through
        // `setupSubscriptions()`: what a live trigger reaches is the
        // orchestrator's own notification path, and this test is about whether
        // it is reached at all.
        let engine = SubscriptionEngine(eventBus: eventBus) { _, _ in
            triggered.fulfill()
        }
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: engine,
            memoryManager: MemoryManager(project: project)
        )
        orchestrator.addAgent(
            Agent(
                id: "watcher-1",
                name: "Watcher",
                model: "sonnet",
                systemPrompt: "",
                tools: [],
                denied: [],
                permissionMode: "default",
                subscriptions: ["pr_ready"],
                state: .idle
            )
        )

        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )

        // Both the subscribe and the unsubscribe are kicked off in background
        // tasks, so neither is observable the instant the call that starts it
        // returns; the bus is polled for each.
        try await eventually("the agent should be watched while the project is open") {
            await eventBus.hasSubscription(agentID: "watcher-1")
        }

        session.shutdown()

        try await eventually("shutdown() left the agent subscribed — it never reached stopSubscriptions()") {
            await !eventBus.hasSubscription(agentID: "watcher-1")
        }

        await eventBus.publish(KiteloopEvent(source: "coder", type: .prReady))
        await fulfillment(of: [triggered], timeout: 0.5)
    }

    /// All stores are pointed at the temp directory so the test never reads or
    /// writes the developer's real global config.
    @MainActor
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appending(path: "catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
