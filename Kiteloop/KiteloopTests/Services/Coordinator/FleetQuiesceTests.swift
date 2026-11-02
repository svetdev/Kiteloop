import XCTest
import KiteloopCore
@testable import Kiteloop

/// `FleetQuiesce` on its own — no socket, no HTTP. The endpoint tests cover the
/// wire shape; this covers the decisions: which projects get held, which are left
/// alone, what the drained reading says, and that resuming restores exactly what
/// the quiesce took.
@MainActor
final class FleetQuiesceTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var fleet: FleetQuiesce!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "fleet-quiesce")
        registry = ControlSessionRegistry()
        fleet = FleetQuiesce(registry: registry)
    }

    override func tearDown() async throws {
        fleet = nil
        registry = nil
    }

    // MARK: - Quiesce

    /// The verb the item asks for: one call holds every queue that is advancing,
    /// across every open project.
    func testQuiesceHoldsEveryAdvancingProject() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 2), queue: [item("a1"), item("a2")])
            $0.stageExecutingRunForTesting(true)
        }
        let beta = try registerProject(named: "beta") {
            $0.stageRunForTesting(status: .reviewing(itemIndex: 0, total: 1, attempt: 1), queue: [item("b1")])
            $0.stageExecutingRunForTesting(true)
        }

        let reading = await fleet.quiesce()

        XCTAssertTrue(reading.quiesced)
        XCTAssertEqual(alpha.status, .paused)
        XCTAssertEqual(beta.status, .paused)
        XCTAssertEqual(action(reading, "alpha"), .held)
        XCTAssertEqual(action(reading, "beta"), .held)
    }

    /// The gate is what stops new work, so it closes even when there is not a
    /// single queue to hold — an idle fleet is exactly the one a driver would
    /// start a run into a second later.
    func testQuiesceClosesTheGateWithNothingToHold() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let reading = await fleet.quiesce()

        XCTAssertTrue(fleet.isQuiesced)
        XCTAssertTrue(reading.quiesced)
        XCTAssertTrue(reading.drained)
        XCTAssertEqual(action(reading, "alpha"), .idle)
    }

    /// An idle autopilot is left idle. Pausing one would manufacture the
    /// `inconsistent` state — a status claiming a run with nothing behind it — and
    /// leave a project holding a queue nobody can start, which is the one failure
    /// this verb must not introduce.
    func testQuiesceLeavesAnIdleProjectIdle() async throws {
        let alpha = try registerProject(named: "alpha", configure: { _ in })

        _ = await fleet.quiesce()

        XCTAssertEqual(alpha.status, .idle)
        let state = await alpha.runState()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(fleet.ledger.contains(projectID("alpha")))
    }

    /// A stale busy claim is reconciled rather than pinned. Left alone it would be
    /// paused into a queue with nothing behind it — a wedge the quiesce itself
    /// created.
    func testQuiesceReconcilesAStaleClaimInsteadOfPinningIt() async throws {
        // `running` with an empty queue and no execution: nothing is in flight, so
        // the status is a claim with nothing behind it.
        let alpha = try registerProject(named: "alpha") { $0.stageRunForTesting(status: .running(itemIndex: 0, total: 0), queue: []) }

        let reading = await fleet.quiesce()

        XCTAssertEqual(alpha.status, .idle, "a stale claim must be cleared, not paused")
        XCTAssertEqual(action(reading, "alpha"), .idle)
        XCTAssertFalse(fleet.ledger.contains(projectID("alpha")))
    }

    /// A project somebody else was already holding is left alone and stays out of
    /// the ledger, so resuming cannot start a queue the operator paused for their
    /// own reasons.
    func testQuiesceLeavesAnAlreadyPausedProjectOutOfTheLedger() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .paused, queue: [item("a1"), item("a2")])
        }

        let reading = await fleet.quiesce()

        XCTAssertEqual(alpha.status, .paused)
        XCTAssertEqual(action(reading, "alpha"), .alreadyHeld)
        XCTAssertFalse(fleet.ledger.contains(projectID("alpha")))
        XCTAssertFalse(reading.projects.first { $0.name == "alpha" }?.heldByQuiesce ?? true)
    }

    /// A driver retrying after a dropped connection must not widen what a later
    /// resume will start.
    func testQuiesceIsIdempotent() async throws {
        try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
            $0.stageExecutingRunForTesting(true)
        }

        _ = await fleet.quiesce()
        let ledgerAfterFirst = fleet.ledger
        let second = await fleet.quiesce()

        XCTAssertEqual(fleet.ledger, ledgerAfterFirst)
        // It was ours, and on the retry it reads as what it is: already held.
        XCTAssertEqual(action(second, "alpha"), .alreadyHeld)
        XCTAssertTrue(second.projects.first { $0.name == "alpha" }?.heldByQuiesce ?? false)
    }

    // MARK: - Drained

    /// The signal the operator was polling for, in one answer.
    func testDrainedIsFalseWhileARunIsInFlight() async throws {
        try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
            $0.stageExecutingRunForTesting(true)
        }
        try registerProject(named: "beta", configure: { _ in })

        let reading = await fleet.quiesce()

        XCTAssertFalse(reading.drained)
        XCTAssertEqual(reading.running, 1)
        XCTAssertEqual(reading.summary, "quiesced, 1 run(s) still finishing")
        XCTAssertEqual(reading.projects.first { $0.name == "alpha" }?.item, "a1")
    }

    /// A held queue is not a running one. The pause lands at the next item
    /// boundary, so the fleet reads drained once the item in flight has reached its
    /// gate and the run loop has returned — which is precisely when a restart is
    /// safe, even though two items are still queued behind it.
    func testDrainedIsTrueWhenOnlyHeldQueuesRemain() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 2), queue: [item("a1"), item("a2")])
            $0.stageExecutingRunForTesting(true)
        }

        _ = await fleet.quiesce()
        // The item in flight finishes and the run loop returns — what `pause()`
        // asked for. The queue behind it stays held.
        alpha.stageExecutingRunForTesting(false)
        let reading = await fleet.reading()

        XCTAssertEqual(alpha.status, .paused)
        XCTAssertTrue(reading.drained)
        XCTAssertEqual(reading.running, 0)
        XCTAssertEqual(reading.summary, "quiesced, drained")
        XCTAssertEqual(reading.projects.first { $0.name == "alpha" }?.heldItems, 2)
    }

    /// A reading taken before anyone has held anything says so, rather than
    /// reporting a hold nobody took.
    func testReadingBeforeAnyQuiesceIsNotQuiesced() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let reading = await fleet.reading()

        XCTAssertFalse(reading.quiesced)
        XCTAssertTrue(reading.drained)
        XCTAssertEqual(reading.summary, "not quiesced, drained")
        XCTAssertNil(reading.projects.first?.action, "a plain reading reports state, not a decision")
    }

    /// The bounded wait returns the moment there is nothing to wait for.
    func testAwaitDrainedReturnsImmediatelyWhenNothingIsRunning() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let drained = await fleet.awaitDrained(timeout: 5)

        XCTAssertTrue(drained)
    }

    /// A wait that runs out reports that it did. Answering "drained" here is the
    /// one outcome that costs something — it is the restart that strands an item.
    func testAwaitDrainedReportsATimeoutRatherThanClaimingDrained() async throws {
        try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
            $0.stageExecutingRunForTesting(true)
        }

        let drained = await fleet.awaitDrained(timeout: 0.2)

        XCTAssertFalse(drained)
    }

    // MARK: - Resume

    /// Exactly what the quiesce took, and nothing else.
    func testResumeRestoresOnlyWhatTheQuiesceHeld() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 2), queue: [item("a1"), item("a2")])
            $0.stageExecutingRunForTesting(true)
        }
        let beta = try registerProject(named: "beta") {
            $0.stageRunForTesting(status: .paused, queue: [item("b1"), item("b2")])
        }

        _ = await fleet.quiesce()
        // The held queue drains to nothing, so the resume has no items to execute
        // — this test is about which projects are picked up, not what they run.
        alpha.stageExecutingRunForTesting(false)
        alpha.stageRunForTesting(status: .paused, queue: [])
        let outcome = await fleet.resume()

        XCTAssertEqual(outcome.resumed, ["alpha"])
        XCTAssertFalse(fleet.isQuiesced)
        XCTAssertTrue(fleet.ledger.isEmpty)
        // Beta was already held when the quiesce arrived, so it stays held.
        XCTAssertEqual(beta.status, .paused)
        XCTAssertFalse(beta.log.contains { $0.message == "Resumed" })
        try await eventually("alpha to log that it resumed") { @MainActor in
            alpha.log.contains { $0.message == "Resumed" }
        }
    }

    /// The post-restart case. The ledger is in memory, so after the restart the
    /// quiesce was taken for there is nothing to pick up — and saying so is the
    /// right answer, not an error and not a silent success.
    func testResumeWithNothingHeldIsAnEmptySuccess() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let outcome = await fleet.resume()

        XCTAssertTrue(outcome.resumed.isEmpty)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertFalse(fleet.isQuiesced)
    }

    /// A ledgered project the restart already released is skipped with the reason
    /// rather than reported as resumed — resume reads the live status, so it never
    /// depends on the state a restart destroyed.
    func testResumeSkipsALedgeredProjectThatIsNoLongerPaused() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
            $0.stageExecutingRunForTesting(true)
        }
        _ = await fleet.quiesce()
        // What a relaunch leaves behind: the autopilot comes back idle.
        alpha.stageExecutingRunForTesting(false)
        alpha.stageRunForTesting(status: .idle, queue: [])

        let outcome = await fleet.resume()

        XCTAssertTrue(outcome.resumed.isEmpty)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertEqual(outcome.skipped.first?.project, "alpha")
        XCTAssertEqual(outcome.skipped.first?.reason,
                       "no longer paused (status: idle) — nothing to pick up")
        XCTAssertTrue(fleet.ledger.isEmpty)
    }

    /// A project closed while the fleet was held is named rather than silently
    /// dropped, and does not stop the rest of the ledger being resumed.
    func testResumeSkipsAProjectThatWasClosed() async throws {
        try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
            $0.stageExecutingRunForTesting(true)
        }
        _ = await fleet.quiesce()
        await registry.unregister(projectID: projectID("alpha"))

        let outcome = await fleet.resume()

        XCTAssertTrue(outcome.resumed.isEmpty)
        XCTAssertEqual(outcome.skipped.first?.reason, "project is no longer open")
    }

    /// Pausing and resuming must leave nothing holding a queue it cannot start.
    /// The session cost cap is the case that made that a risk — its ledger stays
    /// spent across runs — and the fleet verb inherits the fix by going through
    /// `resume()`, which opens a fresh session budget for exactly that queue.
    func testResumeOpensAFreshSessionForAQueueHeldByASpentCap() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 2), queue: [item("a1"), item("a2")])
            $0.stageExecutingRunForTesting(true)
            $0.stageSpentSessionForTesting(capUSD: 1, spentUSD: 5)
        }

        _ = await fleet.quiesce()
        XCTAssertEqual(alpha.status, .paused, "precondition: the quiesce must have held it")
        alpha.stageExecutingRunForTesting(false)
        _ = await fleet.resume()

        try await eventually("the resume to clear the spend holding the queue") { @MainActor in
            alpha.sessionCostSoFar == 0
        }
        XCTAssertNil(alpha.costGovernor.sessionPause,
                     "no project may be left holding a queue it cannot start")
    }

    // MARK: - Helpers

    private func action(_ reading: FleetQuiesce.Reading, _ name: String) -> FleetQuiesce.Action? {
        reading.projects.first { $0.name == name }?.action
    }

    private func projectID(_ name: String) -> String {
        registry.entry(forProject: name)?.session.project.id ?? ""
    }

    private func item(_ id: String) -> BacklogItem {
        BacklogItem(id: id, title: id.uppercased(), verify: "true", status: .ready, type: .local, size: .s)
    }

    @discardableResult
    private func registerProject(
        named name: String,
        configure: (BacklogAutopilot) -> Void
    ) throws -> BacklogAutopilot {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
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
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )

        let autopilot = BacklogAutopilot()
        configure(autopilot)
        registry.register(session: session, autopilot: autopilot)
        return autopilot
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
