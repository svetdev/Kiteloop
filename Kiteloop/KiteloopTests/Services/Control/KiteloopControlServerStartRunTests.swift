import XCTest
import KiteloopCore
@testable import Kiteloop

/// What `POST /v1/runs` answers between asking the autopilot to start and the
/// workflow naming itself.
///
/// It used to poll four seconds for an execution id and then answer **422 "Run
/// did not start"** — with `autopilot.log.last` as the reason. Neither half was
/// true. The status said "this request will never be processed as it stands",
/// which a driver correctly reads as permanent and drops the item for; and the
/// reason was whatever the log happened to say, which four seconds into a start
/// is the cost governor's *informational* cap line, so a run that was starting
/// normally read as `Run did not start: Cost cap: $8.00`. On 2026-08-10 two items
/// were dropped from a headless queue that way, one of them while it was
/// executing.
///
/// So: a refusal is reported only when a gate actually refused, in that gate's
/// own words, and only the pickup gates are worth a 422.
@MainActor
final class KiteloopControlServerStartRunTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var server: KiteloopControlServer { harness.server }
    private let token = "control-startrun-token-" + UUID().uuidString

    /// The line that used to be handed back as a cause. It is a budget statement
    /// logged before each item runs — the ceiling the run is *allowed* to spend,
    /// not something that stopped it.
    private let costCapLine = "Cost cap: $8.00 (flat cap; size band p50 $1.73 × 1.5 margin was lower)"

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-startrun")
        registry = ControlSessionRegistry()
        // These tests are about what is answered at the ends of the two waits, so
        // don't spend the production ones getting there.
        KiteloopControlServer.busyWaitMilliseconds = 1_000
        KiteloopControlServer.startPollMilliseconds = 2_000
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        KiteloopControlServer.busyWaitMilliseconds = 30_000
        KiteloopControlServer.startPollMilliseconds = 4_000
        KiteloopControlServer.pendingWatchMilliseconds = 120_000
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - The slow spin-up

    /// The bug, at the level the driver saw it: the poll window closes with no
    /// execution id and the log's last line is the cost cap. Nothing refused
    /// anything, so nothing may be reported as refused — and least of all with a
    /// 422, which is what took the item out of the queue for good.
    func testASlowSpinUpIsReportedAsStartingRatherThanAsARefusal() async throws {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready"
        ])
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        autopilot.stageLogEntryForTesting(costCapLine, at: Date())
        // The window closed before the request was made: the answer is decided
        // without waiting on anything, so this lands on the slow-spin-up path
        // whatever the machine is doing.
        KiteloopControlServer.startPollMilliseconds = 0

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 202, "a start still spinning up has not been refused")
        XCTAssertEqual(body["status"] as? String, "starting")
        XCTAssertEqual(body["item"] as? String, "item-1")
        XCTAssertNil(body["error"], "nothing refused this run")
        XCTAssertNil(body["runId"], "there is no id yet — that is the whole situation")
        XCTAssertFalse((body["detail"] as? String ?? "").contains("Cost cap"),
                       "the cost cap is a log line, never a cause")
    }

    /// The same window, from the inside: while a start is undecided the answer is
    /// `pending` — not a refusal built out of whatever the log last said.
    func testAnUndecidedStartResolvesToPendingEvenWithACostCapLineInTheLog() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageLogEntryForTesting(costCapLine, at: Date())

        let resolution = await server.awaitStart(autopilot: autopilot, priorExecutionID: nil,
                                                 priorAttempt: 0, timeoutMilliseconds: 200)

        XCTAssertEqual(resolution, .pending)
    }

    /// An id that arrives *after* the window is still this run's id. The window is
    /// how long one request will wait, not a deadline the run has to meet.
    func testAnExecutionIDArrivingAfterTheWindowStillNamesTheRun() async {
        let autopilot = BacklogAutopilot()

        let tooEarly = await server.awaitStart(autopilot: autopilot, priorExecutionID: nil,
                                               priorAttempt: 0, timeoutMilliseconds: 100)
        XCTAssertEqual(tooEarly, .pending, "nothing had happened yet")

        autopilot.stageExecutionIDForTesting("exec-late")
        let afterwards = await server.awaitStart(autopilot: autopilot, priorExecutionID: nil,
                                                 priorAttempt: 0, timeoutMilliseconds: 100)

        XCTAssertEqual(afterwards, .started(runID: "exec-late"))
    }

    /// A run that was accepted but has not spun up yet is `pending`, not
    /// `started`: there is no id to hand back, and it is certainly not refused.
    func testAnAcceptedStartWithNoExecutionYetIsPending() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageStartOutcomeForTesting(refusal: nil, detail: "1 item(s) queued")

        let resolution = await server.awaitStart(autopilot: autopilot, priorExecutionID: nil,
                                                 priorAttempt: 0, timeoutMilliseconds: 100)

        XCTAssertEqual(resolution, .pending)
    }

    /// An outcome from an earlier start is not an answer about this request. The
    /// attempt counter is what tells them apart — a previous run's refusal would
    /// otherwise refuse the run that has just been asked for.
    func testARefusalFromAnEarlierStartIsNotThisRequestsAnswer() async throws {
        let autopilot = BacklogAutopilot()
        autopilot.stageStartOutcomeForTesting(refusal: .noBacklog, detail: "no backlog loaded")
        let priorAttempt = try XCTUnwrap(autopilot.lastStartOutcome?.attempt)

        let resolution = await server.awaitStart(autopilot: autopilot, priorExecutionID: nil,
                                                 priorAttempt: priorAttempt,
                                                 timeoutMilliseconds: 100)

        XCTAssertEqual(resolution, .pending)
    }

    // MARK: - Refusals, in the refusing gate's words

    /// A gate that really did refuse says so itself. The reason is the one the
    /// refusing code knows — not the log's last line — and the status is 409,
    /// because an unconfigured project is a condition of the moment rather than a
    /// verdict on the item.
    func testARefusalCarriesTheRefusingGatesReasonAndIsNotA422() async throws {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready"
        ])
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        autopilot.stageLogEntryForTesting(costCapLine, at: Date())

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409, "nothing about this item is permanently unrunnable")
        XCTAssertEqual(body["error"] as? String,
                       "Run did not start: orchestrator or backlogViewModel not configured")
        XCTAssertFalse((body["error"] as? String ?? "").contains("Cost cap"))
    }

    /// A refusal that lands after the `starting` reply used to go to the metrics
    /// ledger and nowhere a driver reads: no run record, no note, no status
    /// change, and the reason appeared only when the item was posted again
    /// (2026-09-03, a grounding refusal after the window). Now the watch the
    /// reply leaves behind closes a did-not-run record and writes the item's
    /// Notes with the gate's own words.
    func testARefusalAfterTheStartingReplyLeavesADidNotRunRecordAndANote() async throws {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready → [detail](backlog/item-1.md)"
        ], wireBacklog: true)
        let detail = tempDir.appendingPathComponent("alpha/backlog/item-1.md")
        try FileManager.default.createDirectory(at: detail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "## What\n\nAn outcome.\n".write(to: detail, atomically: true, encoding: .utf8)
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        // The reply's window is already closed; the watch behind it is not.
        KiteloopControlServer.startPollMilliseconds = 0
        KiteloopControlServer.pendingWatchMilliseconds = 5_000

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 202)
        XCTAssertEqual(body["status"] as? String, "starting")
        XCTAssertTrue((body["detail"] as? String ?? "").contains("did-not-run"), "the reply says where a late refusal lands")
        try await eventually(timeout: .seconds(5), "a did-not-run record for the refused start") {
            let (_, runs) = try await self.harness.get("/v1/runs?project=alpha")
            let listed = runs["runs"] as? [[String: Any]] ?? []
            return listed.contains { ($0["item"] as? String) == "item-1" && ($0["runId"] as? String ?? "").hasPrefix("did-not-run-") }
        }
        let (_, runs) = try await harness.get("/v1/runs?project=alpha")
        let run = try XCTUnwrap((runs["runs"] as? [[String: Any]])?.first { ($0["item"] as? String) == "item-1" })
        let (_, result) = try await harness.get("/v1/runs/\(run["runId"] as? String ?? "")/result")
        XCTAssertEqual(result["outcome"] as? String, "did_not_run", "\(result)")
        XCTAssertTrue((result["reason"] as? String ?? "").contains("item-1"), "the gate's own words: \(result)")
        let notes = try String(contentsOf: detail, encoding: .utf8)
        XCTAssertTrue(notes.contains("run did not start:"), notes)
    }

    /// And the refusal 422 has always meant is untouched: the pickup gates taking
    /// every selected item — here an item with no groomed detail file, no
    /// `verify:` and no size — is a verdict on the item that stays true until
    /// somebody re-grooms it, which is exactly what a driver may drop it for.
    func testThePickupGatesStillAnswer422WithTheClausesThatFailed() async throws {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready"
        ], wireBacklog: true)
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 422)
        let error = body["error"] as? String ?? ""
        XCTAssertTrue(error.hasPrefix("Run did not start: No runnable items selected"), error)
        XCTAssertTrue(error.contains("item-1"), "the refusal names the item and the clauses it failed: \(error)")
        XCTAssertFalse(error.contains("Cost cap"))
    }

    /// A spent session cost cap is one of those gates. It used to refuse nothing:
    /// the start was accepted, the queue loop met the cap and held at the first
    /// item having minted no execution, and this endpoint — finding neither an id
    /// nor a refusal — waited its whole window out and answered 202 `starting`
    /// for a run that did not exist. A driver on a spent budget got a queue of
    /// those instead of the one thing it needed to know.
    func testASpentSessionCapRefusesTheRunInsteadOfReportingItAsStarting() async throws {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready"
        ], wireBacklog: true)
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        autopilot.stageSpentSessionForTesting(capUSD: 5, spentUSD: 6.25)
        // Long enough that an answer which waited it out could not be mistaken for
        // one that was decided: the refusal is known before the first item begins.
        KiteloopControlServer.startPollMilliseconds = 5_000

        let asked = Date()
        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])
        let waited = Date().timeIntervalSince(asked)

        XCTAssertEqual(status, 409, "a spent session budget is a condition of the moment")
        let error = body["error"] as? String ?? ""
        XCTAssertTrue(error.contains("Session cost cap $5.00 reached ($6.25)"),
                      "the refusal names the ceiling and the spend: \(error)")
        XCTAssertNil(body["runId"], "no run was started")
        XCTAssertNotEqual(body["status"] as? String, "starting")
        XCTAssertLessThan(waited, 2.0, "the refusal is visible on the first poll, not at the window's end")
        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .sessionCap,
                       "and what refused it is readable afterwards")
    }

    /// Every pickup refusal is worth a 422, and nothing else is. This is the line
    /// that was erased when a timeout started answering 422 too: a driver reading
    /// it as permanent is *right*, so only the verdicts that really are permanent
    /// may be spelled that way.
    func testOnlyThePickupGatesAreWorthA422() {
        let permanent = BacklogAutopilot.StartOutcome(attempt: 1, refusal: .noRunnableItems,
                                                      detail: "No runnable items selected")
        XCTAssertEqual(KiteloopControlServer.httpStatus(for: permanent), 422)

        for refusal: BacklogAutopilot.StartOutcome.Refusal in
            [.runInFlight, .dailyBudget, .sessionCap, .notConfigured, .noWorkerOrReviewer,
             .noBacklog, .noAgentSession] {
            let outcome = BacklogAutopilot.StartOutcome(attempt: 1, refusal: refusal, detail: "…")
            XCTAssertEqual(KiteloopControlServer.httpStatus(for: outcome), 409,
                           "\(refusal.rawValue) is a condition of the moment, not a verdict on the item")
        }
    }

    // MARK: - Asking again

    /// "Ask again" must not mean "run it again". A retry that lands while the run
    /// is in flight is refused by the busy guard, which never reaches `start()` —
    /// so the attempt counter does not move.
    func testARetryAfterASlowStartDoesNotBeginTheItemTwice() async throws {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready"
        ])
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        KiteloopControlServer.startPollMilliseconds = 0

        let (first, _) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])
        XCTAssertEqual(first, 202)

        // The response went out before the start had decided anything — that is
        // the path under test — so wait for the start it asked for to land before
        // counting attempts, or the count would be of nothing.
        let attemptsBefore = try await eventuallyValue("the first request's start to decide anything") {
            await autopilot.lastStartOutcome?.attempt
        }

        // The run the first request kicked off, now in flight — the state the
        // driver's retry arrives into.
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1),
                                     queue: [BacklogItem(id: "item-1", title: "ITEM-1", verify: "true",
                                                         status: .ready, type: .local, size: .s)])
        autopilot.stageExecutingRunForTesting(true)

        let (second, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(second, 409)
        XCTAssertEqual(body["error"] as? String,
                       "Autopilot is still busy for this project — running item-1 (ITEM-1)")
        XCTAssertEqual(autopilot.lastStartOutcome?.attempt, attemptsBefore,
                       "the retry must not have entered start() a second time")
    }

    // MARK: - Helpers

    /// Builds a real `ProjectSession` over a throwaway directory with a BACKLOG.md
    /// the run request can resolve its item against, and returns its autopilot.
    ///
    /// `wireBacklog` is what lets `start()` get as far as the pickup gates: without
    /// it the autopilot has no orchestrator or backlog and refuses earlier, which
    /// is its own test above.
    @discardableResult
    private func registerProject(named name: String, items: [String],
                                 wireBacklog: Bool = false) throws -> BacklogAutopilot {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        try "# \(name) Backlog\n\n## Now\n\n\(items.joined(separator: "\n"))\n"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)

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
        if wireBacklog {
            autopilot.configure(orchestrator: orchestrator,
                                backlogViewModel: session.backlogViewModel,
                                configURL: nil)
        }
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
