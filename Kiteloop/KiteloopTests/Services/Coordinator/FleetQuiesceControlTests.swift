import XCTest
import KiteloopCore
@testable import Kiteloop

/// The app's caller of the fleet-wide hold, over a real `FleetQuiesce` and real
/// autopilots — no window, no AppKit.
///
/// What is being asserted is that the control *is* a caller and not a second
/// implementation: pressing Quiesce leaves the fleet in the state the endpoint
/// leaves it in, and the drain a pending quit waits out is the seam's, watched
/// rather than driven.
@MainActor
final class FleetQuiesceControlTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var fleet: FleetQuiesce!
    private var control: FleetQuiesceControl!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "fleet-control")
        registry = ControlSessionRegistry()
        fleet = FleetQuiesce(registry: registry)
        control = FleetQuiesceControl(fleet: fleet)
    }

    override func tearDown() async throws {
        control = nil
        fleet = nil
        registry = nil
    }

    /// Nothing is drawn before the first reading. An unread fleet is not a fleet
    /// taking work, and saying so would be a state nobody is in.
    func testThereIsNoStatusBeforeTheFirstReading() {
        XCTAssertNil(control.status)
    }

    func testRefreshTakesAReadingWithoutHoldingAnything() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
            $0.stageExecutingRunForTesting(true)
        }

        await control.refresh()

        XCTAssertEqual(control.status?.state, .takingWork)
        XCTAssertEqual(control.status?.stillRunning, "alpha (a1)")
        XCTAssertEqual(alpha.status, .running(itemIndex: 0, total: 1), "a reading must start and stop nothing")
    }

    /// The control's own acceptance criterion: pressing it holds every project's
    /// queue and closes the gate that refuses new starts.
    func testQuiesceHoldsEveryQueueAndGatesNewStarts() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 2), queue: [item("a1"), item("a2")])
            $0.stageExecutingRunForTesting(true)
        }
        let beta = try registerProject(named: "beta") {
            $0.stageRunForTesting(status: .reviewing(itemIndex: 0, total: 1, attempt: 1), queue: [item("b1")])
            $0.stageExecutingRunForTesting(true)
        }

        control.quiesce()
        try await eventually("the control to report the hold") { await self.control.status?.action == .resume }

        XCTAssertTrue(fleet.isQuiesced)
        XCTAssertEqual(alpha.status, .paused)
        XCTAssertEqual(beta.status, .paused)
        XCTAssertEqual(control.status?.state, .draining)
    }

    /// The drain is watched, not driven: the count falls as runs reach their own
    /// gates, and the control only re-reads.
    func testTheDrainStateFollowsRunsFinishing() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 2), queue: [item("a1"), item("a2")])
            $0.stageExecutingRunForTesting(true)
        }
        control.quiesce()
        try await eventually("the control to report draining") { await self.control.status?.state == .draining }

        alpha.stageExecutingRunForTesting(false)
        await control.refresh()

        XCTAssertEqual(control.status?.state, .held)
        XCTAssertNil(control.status?.stillRunning)
    }

    /// Resume releases the hold, so the fleet takes work again.
    func testResumeLiftsTheHold() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 2), queue: [item("a1"), item("a2")])
            $0.stageExecutingRunForTesting(true)
        }
        control.quiesce()
        try await eventually("the control to report the hold") { await self.control.status?.action == .resume }
        alpha.stageExecutingRunForTesting(false)
        alpha.stageRunForTesting(status: .paused, queue: [])

        control.resume()
        try await eventually("the control to report the release") { await self.control.status?.action == .quiesce }

        XCTAssertFalse(fleet.isQuiesced)
        XCTAssertEqual(control.status?.state, .takingWork)
    }

    // MARK: - The quit waiting on the drain

    /// The quit offer's first choice, end to end: hold now, quit when the last
    /// run has reached its gate — not before.
    func testQuitWhenDrainedWaitsForTheRunToFinish() async throws {
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
            $0.stageExecutingRunForTesting(true)
        }
        var quit = false
        control.onDrainedForQuit = { quit = true }

        control.quiesceAndQuitWhenDrained()
        try await eventually("the control to report draining") { await self.control.status?.state == .draining }

        XCTAssertFalse(quit, "a run was still in flight — quitting there is the interruption this avoids")
        XCTAssertEqual(control.status?.quitNotice, "quitting once it's quiet")

        alpha.stageExecutingRunForTesting(false)
        try await eventually("the quit to fire once the fleet drained") { @MainActor in quit }
    }

    /// A fleet already drained when the choice is made does not wait for a run
    /// that is not there.
    func testQuitWhenDrainedFiresImmediatelyOnAnIdleFleet() async throws {
        try registerProject(named: "alpha", configure: { _ in })
        var quit = false
        control.onDrainedForQuit = { quit = true }

        control.quiesceAndQuitWhenDrained()
        try await eventually("the quit to fire on an already-drained fleet") { @MainActor in quit }

        XCTAssertTrue(fleet.isQuiesced)
    }

    /// Resume calls the pending quit off. Asking the fleet to take work again is
    /// the opposite of leaving, and a quit that fired anyway once the last run
    /// landed would be a shutdown nobody asked for.
    func testResumeCancelsAQuitWaitingOnTheDrain() async throws {
        // The queue is empty behind the run in flight, so the resume has nothing
        // to execute — this case is about the pending quit, not what runs next.
        let alpha = try registerProject(named: "alpha") {
            $0.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [])
            $0.stageExecutingRunForTesting(true)
        }
        var quit = false
        control.onDrainedForQuit = { quit = true }
        control.quiesceAndQuitWhenDrained()
        try await eventually("the control to report draining") { await self.control.status?.state == .draining }

        control.resume()
        XCTAssertFalse(control.isQuittingWhenDrained)
        XCTAssertNil(control.status?.quitNotice)
        try await eventually("the control to report the release") { await self.control.status?.action == .quiesce }

        // The run finishes anyway. Nothing may quit on the back of it. Nothing
        // says "the cancelled wait has exited", so this is a window: that task
        // wakes from its drain poll within `drainPollMilliseconds`, and a quit
        // that was going to fire would have fired by then.
        alpha.stageExecutingRunForTesting(false)
        try await Task.sleep(for: .milliseconds(FleetQuiesce.drainPollMilliseconds + 100))

        XCTAssertFalse(quit, "a cancelled quit must not fire when the fleet later drains")
    }

    // MARK: - Helpers

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

    /// Every store points at the temp directory, so the tests never read or write
    /// the developer's real global config.
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
