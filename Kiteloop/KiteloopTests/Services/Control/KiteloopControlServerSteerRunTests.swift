import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/runs/{runId}/note` — the operator note a headless driver can hand a
/// live run's worker, exercised over a real loopback socket.
///
/// Steering is the one mid-run intervention that is neither cancelling nor
/// waiting, and until this endpoint the only way to reach it was the Autopilot
/// tab's note field: a run watched through `GET /v1/runs/{id}/log` could be
/// abandoned or left to burn its cap, and nothing else. What is asserted here is
/// that the API reaches the *same* seam the tab does — `steerWorker`'s gate, its
/// refusals and its record — rather than a second, drifting copy of them.
@MainActor
final class KiteloopControlServerSteerRunTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var server: KiteloopControlServer { harness.server }
    private var records: RunRecordStore!
    private let token = "control-steer-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-steer")
        registry = ControlSessionRegistry()
        // Attached so the not-live refusal has a record to answer from — that is
        // the whole difference between "your run is over" and "your run never
        // existed".
        records = RunRecordStore(url: tempDir.appendingPathComponent("control-runs.jsonl"))
        harness = try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0, runRecords: records)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - The note reaching the worker

    /// The happy path: the worker of the run in flight has the note waiting for
    /// it, on the same queue `ChatViewModel` drains at the next turn boundary.
    func testANoteForARunningWorkerIsQueuedForThatWorker() async throws {
        let (autopilot, orchestrator) = try stageRunningWorker(project: "alpha", runId: "exec-alpha")

        let (status, body) = try await harness.post("/v1/runs/exec-alpha/note",
                                            ["note": "  the fix belongs in the parser  "])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["runId"] as? String, "exec-alpha")
        XCTAssertEqual(body["item"] as? String, "item-1")
        XCTAssertEqual(body["state"] as? String, "sent")
        // The note as it was queued — trimmed, so a caller can see what the
        // worker will actually be shown.
        XCTAssertEqual(body["note"] as? String, "the fix belongs in the parser")
        XCTAssertEqual(orchestrator.takeSteerNotes(for: "worker-agent"),
                       ["the fix belongs in the parser"])
        XCTAssertTrue(autopilot.canSteer, "steering must not end the run it steers")
    }

    /// Delivery is per agent, and the reviewer is not one of them: its
    /// independence is part of what its verdict is worth.
    func testTheReviewerIsNeverHandedTheNote() async throws {
        let (_, orchestrator) = try stageRunningWorker(project: "alpha", runId: "exec-alpha")

        let (status, _) = try await harness.post("/v1/runs/exec-alpha/note", ["note": "try the other branch"])

        XCTAssertEqual(status, 200)
        XCTAssertTrue(orchestrator.takeSteerNotes(for: "reviewer-agent").isEmpty)
    }

    /// A steer taken over the API leaves the record one taken in the app leaves:
    /// the run log and the item's `## Notes`. An unrecorded steer would make the
    /// run's outcome unattributable — nobody reading the merged diff could tell
    /// which of its decisions were the worker's own.
    func testTheSteerIsRecordedInTheRunLogAndTheItemsNotes() async throws {
        let (autopilot, _) = try stageRunningWorker(project: "alpha", runId: "exec-alpha")

        let (status, _) = try await harness.post("/v1/runs/exec-alpha/note", ["note": "look at the FIFO reader"])

        XCTAssertEqual(status, 200)
        XCTAssertTrue(
            autopilot.log.contains { $0.message == RunSteerNote.logLine("look at the FIFO reader") },
            "the run log must show the steer as a step the run took: \(autopilot.log.map(\.message))"
        )
        let detail = try String(contentsOf: detailURL(project: "alpha"), encoding: .utf8)
        XCTAssertTrue(detail.contains("steered ") && detail.contains("look at the FIFO reader"),
                      "the item's Notes must carry the steer: \(detail)")
    }

    // MARK: - Refusals

    /// The reviewer holds the run, so there is no worker to reach. The refusal is
    /// `steerWorker`'s own, not a second rule written here.
    func testARunHeldByTheReviewerIsRefusedWithTheAutopilotsReason() async throws {
        let (autopilot, orchestrator) = try stageRunningWorker(project: "alpha", runId: "exec-alpha")
        autopilot.stageRunForTesting(status: .reviewing(itemIndex: 0, total: 1, attempt: 1),
                                     queue: autopilot.runQueue)
        XCTAssertFalse(autopilot.canSteer)

        let (status, body) = try await harness.post("/v1/runs/exec-alpha/note", ["note": "approve it"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String,
                       "No worker running — a note can only be handed to a run in flight")
        XCTAssertTrue(orchestrator.takeSteerNotes(for: "worker-agent").isEmpty)
    }

    /// A note that sanitizes to nothing is refused rather than quietly accepted:
    /// a 200 here would tell a driver its correction had reached the worker.
    func testANoteThatSanitizesToNothingIsRefused() async throws {
        let (_, orchestrator) = try stageRunningWorker(project: "alpha", runId: "exec-alpha")

        let (status, body) = try await harness.post("/v1/runs/exec-alpha/note", ["note": "   \n  "])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Nothing to send")
        XCTAssertTrue(orchestrator.takeSteerNotes(for: "worker-agent").isEmpty)
    }

    /// An overlong note is truncated rather than refused — a paste that runs long
    /// still sends the part that fits — and the reply says what was queued.
    func testAnOverlongNoteIsQueuedTruncatedAndTheReplySaysSo() async throws {
        let (_, orchestrator) = try stageRunningWorker(project: "alpha", runId: "exec-alpha")
        let long = String(repeating: "x", count: RunSteerNote.maxLength + 200)

        let (status, body) = try await harness.post("/v1/runs/exec-alpha/note", ["note": long])

        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["note"] as? String)?.count, RunSteerNote.maxLength)
        XCTAssertEqual(orchestrator.takeSteerNotes(for: "worker-agent").first?.count,
                       RunSteerNote.maxLength)
    }

    /// A body with no note at all is the caller's mistake, not the run's state.
    func testABodyWithoutANoteIs400() async throws {
        let (_, orchestrator) = try stageRunningWorker(project: "alpha", runId: "exec-alpha")

        let (status, body) = try await harness.post("/v1/runs/exec-alpha/note", ["text": "wrong field"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"note\"")
        XCTAssertTrue(orchestrator.takeSteerNotes(for: "worker-agent").isEmpty)
    }

    /// A run that is only on record answers through the same not-live path
    /// `cancel` uses: a 409 naming the run and its state, because the id is real
    /// and telling a driver its run never existed is how a restart used to read.
    func testARunOnlyOnRecordIsNotLiveRatherThan404() async throws {
        try stageRunningWorker(project: "alpha", runId: "exec-alpha")
        // A run the server has no live entry for, but a record of: what a
        // restart leaves behind, and what the driver is still holding an id for.
        var record = PersistedRunRecord(
            runId: "exec-gone", projectID: "/tmp/alpha", itemID: "item-1",
            title: "Item one",
            startedAt: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded()))
        record.outcome = .done
        records.upsert(record)

        let (status, body) = try await harness.post("/v1/runs/exec-gone/note", ["note": "too late"])

        XCTAssertEqual(status, 409)
        let error = body["error"] as? String ?? ""
        XCTAssertTrue(error.contains("exec-gone"), "the refusal must name the run: \(error)")
        XCTAssertTrue(error.contains("not live"), error)
    }

    /// A stale runId must not steer whatever has taken its place: one project runs
    /// one item at a time, and its worker belongs to the current run, not to the
    /// one this caller is still holding.
    func testAStaleRunIdDoesNotSteerTheItemThatTookItsPlace() async throws {
        let (autopilot, orchestrator) = try stageRunningWorker(project: "alpha", runId: "exec-current")
        server.track(KiteloopControlServer.RunInfo(
            runId: "exec-stale",
            projectID: registry.entry(forProject: "alpha")!.session.project.id,
            itemId: "item-1", title: "Item one", startedAt: Date()
        ))

        let (status, body) = try await harness.post("/v1/runs/exec-stale/note", ["note": "go left"])

        XCTAssertEqual(status, 409)
        XCTAssertTrue((body["error"] as? String)?.contains("exec-stale") ?? false, "\(body)")
        XCTAssertTrue(orchestrator.takeSteerNotes(for: "worker-agent").isEmpty)
        XCTAssertTrue(autopilot.canSteer, "the run actually in flight is left alone")
    }

    func testUnknownRunIs404() async throws {
        try stageRunningWorker(project: "alpha", runId: "exec-alpha")

        let (status, body) = try await harness.post("/v1/runs/nope/note", ["note": "hello"])

        XCTAssertEqual(status, 404)
        XCTAssertEqual(body["error"] as? String, "Unknown run: nope")
    }

    /// A note reaches the worker of a run in flight, so it sits behind the token
    /// like every other write — and an unauthenticated call queues nothing.
    func testSteeringRequiresBearerToken() async throws {
        let (_, orchestrator) = try stageRunningWorker(project: "alpha", runId: "exec-alpha")

        let (status, body) = try await harness.post("/v1/runs/exec-alpha/note", ["note": "hello"], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertTrue(orchestrator.takeSteerNotes(for: "worker-agent").isEmpty)
    }

    // MARK: - Helpers

    /// Stages what a real run has reached by the time its worker is streaming: an
    /// execution in flight, the worker phase, a worker agent to reach, and the
    /// item under it — plus the tracked run the endpoint addresses it by.
    @discardableResult
    private func stageRunningWorker(project name: String, runId: String) throws
    -> (BacklogAutopilot, Orchestrator) {
        let (autopilot, orchestrator, session) = try registerProject(named: name)
        autopilot.workerAgentID = "worker-agent"
        autopilot.reviewerAgentID = "reviewer-agent"
        autopilot.stageExecutionIDForTesting(runId)
        autopilot.stageExecutingRunForTesting(true)
        let item = try XCTUnwrap(session.backlogViewModel.item(withID: "item-1"),
                                 "the staged backlog must hold the item the run is on")
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item])
        server.track(KiteloopControlServer.RunInfo(
            runId: runId,
            projectID: session.project.id,
            itemId: "item-1",
            title: "Item one",
            startedAt: Date()
        ))
        return (autopilot, orchestrator)
    }

    /// Builds a real `ProjectSession` over a throwaway directory holding a backlog
    /// and the item's detail file — the note is written to its `## Notes`, so the
    /// file has to exist for that half of the record to be observable.
    private func registerProject(named name: String) throws
    -> (BacklogAutopilot, Orchestrator, ProjectSession) {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("backlog", isDirectory: true),
                                                withIntermediateDirectories: true)
        try """
        # Backlog

        ## Epic: Now

        - [ ] item-1 | Item one | active → [detail](backlog/item-1.md)
        """.write(to: root.appendingPathComponent("BACKLOG.md"), atomically: true, encoding: .utf8)
        try "## What\n\nSomething.\n".write(to: detailURL(project: name), atomically: true, encoding: .utf8)

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
        autopilot.configure(orchestrator: orchestrator,
                            backlogViewModel: session.backlogViewModel,
                            configURL: nil)
        registry.register(session: session, autopilot: autopilot)
        return (autopilot, orchestrator, session)
    }

    private func detailURL(project name: String) -> URL {
        tempDir.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("backlog", isDirectory: true)
            .appendingPathComponent("item-1.md")
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
