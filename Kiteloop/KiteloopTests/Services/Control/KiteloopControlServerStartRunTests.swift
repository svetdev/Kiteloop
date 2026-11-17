import XCTest
import KiteloopCore
@testable import Kiteloop

/// What `POST /v1/runs` answers: the run's id, or the reason there is no run.
///
/// It has been wrong twice, both times by letting a clock stand in for the
/// autopilot's decision. First it polled four seconds for an execution id and
/// then answered **422 "Run did not start"** with `autopilot.log.last` as the
/// reason — the status a driver correctly reads as permanent, and a reason that
/// four seconds into a start is the cost governor's *informational* cap line.
/// On 2026-08-10 two items were dropped from a headless queue that way, one of
/// them while it was executing. Then the same four seconds ended in **202
/// `starting`** with no id, which was true and no use: the driver still had to
/// find out by other means whether a run existed, and a gate that refused later
/// had nobody left to tell.
///
/// So the request is held until the autopilot has decided, however long that
/// takes, and there are two answers: an execution exists and this is its id, or
/// none will and this is why — in the deciding gate's own words, with 422 kept
/// for the pickup gates alone.
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
        // One test stages a run in flight; don't spend the production wait
        // getting to its refusal.
        KiteloopControlServer.busyWaitMilliseconds = 1_000
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        KiteloopControlServer.busyWaitMilliseconds = 30_000
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - A start that decides late

    /// The case the window got wrong: the queue is accepted, and the execution
    /// turns up only after the request has been waiting on it. The answer is
    /// that execution's id — never a 202 with no id in it.
    func testAnExecutionCreatedLateAnswersWithItsRunID() async throws {
        let autopilot = try registerConfiguredProject()
        autopilot.stageLogEntryForTesting(costCapLine, at: Date())
        let release = holdStart(of: autopilot,
                                first: { $0.stageStartOutcomeForTesting(refusal: nil, detail: "1 item(s) queued") },
                                thenDecide: { $0.stageStartedExecutionForTesting("exec-late") })

        let reply = try await postWhileUndecided(autopilot, release: release)

        XCTAssertEqual(reply.status, 202)
        XCTAssertEqual(reply.runID, "exec-late")
        XCTAssertEqual(reply.runStatus, "running", "a 202 is only ever a run that exists")
        XCTAssertNil(reply.error)
        let (_, runs) = try await harness.get("/v1/runs?project=alpha")
        let listed = (runs["runs"] as? [[String: Any]] ?? []).compactMap { $0["runId"] as? String }
        XCTAssertTrue(listed.contains("exec-late"), "the run is tracked under the id that was answered: \(listed)")
    }

    /// A pickup gate that decides late — the grounding check reads the tree —
    /// is still this request's answer: 422, with the gate's own detail.
    func testAPickupRefusalDecidedLateAnswers422InTheGatesWords() async throws {
        let autopilot = try registerConfiguredProject()
        autopilot.stageLogEntryForTesting(costCapLine, at: Date())
        let detail = "No runnable items selected (1 not grounded): item-1 cites `Services/Missing.swift`"
        let release = holdStart(of: autopilot, thenDecide: {
            $0.stageStartOutcomeForTesting(refusal: .noRunnableItems, detail: detail)
        })

        let reply = try await postWhileUndecided(autopilot, release: release)

        XCTAssertEqual(reply.status, 422)
        XCTAssertEqual(reply.error, "Run did not start: \(detail)")
        XCTAssertNil(reply.runID)
        XCTAssertNil(reply.runStatus, "a refusal is not a run in any state")
    }

    /// Every other late refusal is a condition of the moment: 409, come back.
    func testALateRefusalAboutTheMomentAnswers409() async throws {
        let autopilot = try registerConfiguredProject()
        for refusal: BacklogAutopilot.StartOutcome.Refusal in [.paused, .dailyBudget, .sessionCap] {
            let release = holdStart(of: autopilot, thenDecide: {
                $0.stageStartOutcomeForTesting(refusal: refusal, detail: "refused as \(refusal.rawValue)")
            })

            let reply = try await postWhileUndecided(autopilot, release: release)

            XCTAssertEqual(reply.status, 409, refusal.rawValue)
            XCTAssertEqual(reply.error, "Run did not start: refused as \(refusal.rawValue)")
        }
    }

    /// A queue that was accepted and then ended with no execution — the item
    /// failed before its workflow began — used to leave the request with
    /// nothing to find. The end of `start()` decides it: 409, saying that no
    /// execution was created, rather than a request left open.
    func testAnAcceptedStartThatEndsWithoutAnExecutionAnswers409() async throws {
        let autopilot = try registerConfiguredProject()
        let release = holdStart(of: autopilot, thenDecide: {
            $0.stageStartOutcomeForTesting(refusal: nil, detail: "1 item(s) queued")
        })

        let reply = try await postWhileUndecided(autopilot, release: release)

        XCTAssertEqual(reply.status, 409)
        XCTAssertEqual(reply.error, "Run did not start: the queue was accepted but the run ended "
                       + "before a workflow execution was created")
        XCTAssertNil(reply.runID)
        XCTAssertNil(autopilot.lastStartOutcome?.refusal,
                     "the queue was accepted — that outcome is what the scheduler reads, and it stands")
    }

    /// The reason the item ended blocked rides along, so the 409 says what
    /// stopped the run and not only that something did.
    func testTheNoExecutionRefusalCarriesTheItemsBlockedReason() async throws {
        let autopilot = try registerConfiguredProject()
        let release = holdStart(of: autopilot, thenDecide: {
            $0.stageStartOutcomeForTesting(refusal: nil, detail: "1 item(s) queued")
            $0.stageResultForTesting(.init(id: "item-1", title: "Ready to go",
                                           outcome: .blocked("worktree could not be created"), duration: 0))
        })

        let reply = try await postWhileUndecided(autopilot, release: release)

        XCTAssertEqual(reply.status, 409)
        XCTAssertEqual(reply.error, "Run did not start: the queue was accepted but the run ended "
                       + "before a workflow execution was created: worktree could not be created")
    }

    /// A `start()` that returns having said nothing at all is decided too, and
    /// the refusal becomes that start's recorded outcome.
    func testAStartThatReturnsHavingDecidedNothingIsRefusedRatherThanLeftOpen() async throws {
        let autopilot = try registerConfiguredProject()
        autopilot.stageStartForTesting { _ in }

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409)
        XCTAssertTrue((body["error"] as? String ?? "").contains("before a workflow execution was created"), "\(body)")
        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .workflowDidNotStart)
    }

    /// An outcome from an earlier start is not an answer about this request. The
    /// attempt counter is what tells them apart — a previous run's refusal would
    /// otherwise refuse the run that has just been asked for.
    func testARefusalFromAnEarlierStartIsNotThisRequestsAnswer() async throws {
        let autopilot = try registerConfiguredProject()
        autopilot.stageStartOutcomeForTesting(refusal: .noBacklog, detail: "no backlog loaded")
        let release = holdStart(of: autopilot,
                                first: { $0.stageStartOutcomeForTesting(refusal: nil, detail: "1 item(s) queued") },
                                thenDecide: { $0.stageStartedExecutionForTesting("exec-new") })

        let reply = try await postWhileUndecided(autopilot, release: release)

        XCTAssertEqual(reply.status, 202, "the old refusal was about the start before this one")
        XCTAssertEqual(reply.runID, "exec-new")
        XCTAssertNil(reply.error)
    }

    /// A second `start()` — the fleet's next look, the app's Run button — that
    /// arrives while this one is spinning up is told a run is already
    /// executing. That is its answer, not this request's: the run it was
    /// refused for is the one being waited on, and it is about to exist.
    func testAnotherStartRefusedWhileThisOneSpinsUpDoesNotAnswerThisRequest() async throws {
        let autopilot = try registerConfiguredProject()
        let release = holdStart(of: autopilot,
                                first: { $0.stageStartOutcomeForTesting(refusal: nil, detail: "1 item(s) queued") },
                                thenDecide: { $0.stageStartedExecutionForTesting("exec-mine") })

        let reply = try await postWhileUndecided(autopilot, release: release) {
            autopilot.stageStartOutcomeForTesting(refusal: .runInFlight,
                                                  detail: "a run is already executing for this project")
        }

        XCTAssertEqual(reply.status, 202)
        XCTAssertEqual(reply.runID, "exec-mine")
        XCTAssertNil(reply.error)
    }

    /// The same rule at the autopilot: a decision already made answers a
    /// caller that has not seen it, and never one that has.
    func testTheAutopilotsDecisionIsReadByAttempt() async throws {
        let autopilot = BacklogAutopilot()
        autopilot.stageStartOutcomeForTesting(refusal: .noBacklog, detail: "no backlog loaded")
        let seen = try XCTUnwrap(autopilot.lastStartOutcome?.attempt)

        let unseen = await autopilot.awaitStartDecision(afterAttempt: seen - 1)
        XCTAssertEqual(unseen, .refused(try XCTUnwrap(autopilot.lastStartOutcome)))

        let next = Task { await autopilot.awaitStartDecision(afterAttempt: seen) }
        try await eventually("the caller to be waiting") { autopilot.startDecisionWaiterCountForTesting == 1 }
        autopilot.stageStartOutcomeForTesting(refusal: nil, detail: "1 item(s) queued")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(autopilot.startDecisionWaiterCountForTesting, 1,
                       "an accepted queue has no execution to name yet, so it decides nothing")
        autopilot.stageStartedExecutionForTesting("exec-1")
        let decided = await next.value
        XCTAssertEqual(decided, .started(executionID: "exec-1"))
    }

    // MARK: - Refusals, in the refusing gate's words

    /// A gate that really did refuse says so itself. The reason is the one the
    /// refusing code knows — not the log's last line — and the status is 409,
    /// because an unconfigured project is a condition of the moment rather than a
    /// verdict on the item.
    func testARefusalCarriesTheRefusingGatesReasonAndIsNotA422() async throws {
        let autopilot = try registerConfiguredProject()
        autopilot.stageLogEntryForTesting(costCapLine, at: Date())

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409, "nothing about this item is permanently unrunnable")
        XCTAssertEqual(body["error"] as? String,
                       "Run did not start: orchestrator or backlogViewModel not configured")
        XCTAssertFalse((body["error"] as? String ?? "").contains("Cost cap"))
    }

    /// And the refusal 422 has always meant is untouched: the pickup gates taking
    /// every selected item — here an item with no groomed detail file, no
    /// `verify:` and no size — is a verdict on the item that stays true until
    /// somebody re-grooms it, which is exactly what a driver may drop it for.
    func testThePickupGatesStillAnswer422WithTheClausesThatFailed() async throws {
        let autopilot = try registerConfiguredProject(wireBacklog: true)
        _ = autopilot

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 422)
        let error = body["error"] as? String ?? ""
        XCTAssertTrue(error.hasPrefix("Run did not start: No runnable items selected"), error)
        XCTAssertTrue(error.contains("item-1"), "the refusal names the item and the clauses it failed: \(error)")
        XCTAssertFalse(error.contains("Cost cap"))
    }

    /// A spent session cost cap is one of the gates. It used to refuse nothing:
    /// the start was accepted, the queue loop met the cap and held at the first
    /// item having minted no execution, and this endpoint answered 202 for a run
    /// that did not exist. A driver on a spent budget got a queue of those
    /// instead of the one thing it needed to know.
    func testASpentSessionCapRefusesTheRun() async throws {
        let autopilot = try registerConfiguredProject(wireBacklog: true)
        autopilot.stageSpentSessionForTesting(capUSD: 5, spentUSD: 6.25)

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409, "a spent session budget is a condition of the moment")
        let error = body["error"] as? String ?? ""
        XCTAssertTrue(error.contains("Session cost cap $5.00 reached ($6.25)"),
                      "the refusal names the ceiling and the spend: \(error)")
        XCTAssertNil(body["runId"], "no run was started")
        XCTAssertNil(body["status"], "and nothing is reported as a run")
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
             .noBacklog, .noAgentSession, .fleetQuiesced, .paused, .workflowDidNotStart] {
            let outcome = BacklogAutopilot.StartOutcome(attempt: 1, refusal: refusal, detail: "…")
            XCTAssertEqual(KiteloopControlServer.httpStatus(for: outcome), 409,
                           "\(refusal.rawValue) is a condition of the moment, not a verdict on the item")
        }
    }

    // MARK: - Asking again

    /// "Ask again" must not mean "run it again". A retry that lands while the run
    /// is in flight is refused by the busy guard, which never reaches `start()` —
    /// so the attempt counter does not move.
    func testARetryWhileTheRunIsInFlightDoesNotBeginTheItemTwice() async throws {
        let autopilot = try registerConfiguredProject()
        let release = holdStart(of: autopilot,
                                first: { $0.stageStartOutcomeForTesting(refusal: nil, detail: "1 item(s) queued") },
                                thenDecide: { $0.stageStartedExecutionForTesting("exec-1") })
        let first = try await postWhileUndecided(autopilot, release: release)
        XCTAssertEqual(first.status, 202)
        let attemptsBefore = try XCTUnwrap(autopilot.lastStartOutcome?.attempt)

        // The run the first request started, now in flight — the state the
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

    // MARK: - A list of items

    /// A list is one run, walked in the order it was posted. `a` is first in
    /// the file and `c` is the only `now` item, so every order but the
    /// caller's would put one of them ahead of `b`.
    func testAListRunsInTheOrderItWasPosted() async throws {
        let autopilot = try registerListProject()
        var queued: [String] = []
        autopilot.stageStartForTesting { autopilot in
            await autopilot.admitSelectionForTesting()
            queued = autopilot.runQueue.map(\.id)
            autopilot.stageStartOutcomeForTesting(refusal: nil, detail: "3 item(s) queued")
            autopilot.stageStartedExecutionForTesting("exec-list")
        }

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "items": ["b", "a", "c"]])

        XCTAssertEqual(status, 202, "\(body)")
        XCTAssertEqual(queued, ["b", "a", "c"], "the queue the pickup pass built follows the list")
        XCTAssertEqual(body["runId"] as? String, "exec-list")
        XCTAssertEqual(body["items"] as? [String], ["b", "a", "c"], "the list is echoed as posted")
        XCTAssertEqual(body["item"] as? String, "b", "and the run is named after the item it begins with")
        XCTAssertEqual(body["title"] as? String, "Item b")
        XCTAssertNil(autopilot.requestedOrder, "the order was that start's alone")
    }

    /// A list leaves nothing behind: the single item posted after it is a
    /// plain start, with no order of its own, and its reply is the one a
    /// single item has always had.
    func testASingleItemAfterAListIsNotOrderedByIt() async throws {
        let autopilot = try registerListProject()
        var orders: [[String]?] = []
        autopilot.stageStartForTesting { autopilot in
            orders.append(autopilot.requestedOrder)
            autopilot.stageStartOutcomeForTesting(refusal: nil, detail: "queued")
            autopilot.stageStartedExecutionForTesting("exec-\(orders.count)")
        }

        _ = try await harness.post("/v1/runs", ["project": "alpha", "items": ["c", "b"]])
        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "a"])

        XCTAssertEqual(status, 202, "\(body)")
        XCTAssertEqual(orders, [["c", "b"], nil])
        XCTAssertEqual(autopilot.selectedItemIDs, ["a"])
        XCTAssertNil(body["items"], "a single item's reply is unchanged")
        XCTAssertEqual(body["item"] as? String, "a")
    }

    /// The order is dropped on the refusals too. Here the real `start()` gets
    /// as far as finding the agents have no session and refuses.
    func testARefusedListLeavesNoOrderBehind() async throws {
        let autopilot = try registerListProject()

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "items": ["b", "a"]])

        XCTAssertEqual(status, 409, "\(body)")
        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .noAgentSession)
        XCTAssertNil(autopilot.requestedOrder)
    }

    /// A list is checked whole before anything starts: none of these reaches
    /// `start()`, so the attempt counter never moves.
    func testAListThatCannotBeRunAsPostedStartsNothing() async throws {
        let autopilot = try registerListProject()
        let refused: [(body: [String: Any], status: Int, error: String)] = [
            (["project": "alpha", "item": "a", "items": ["b"]], 400, "Give either \"item\" or \"items\", not both"),
            (["project": "alpha", "items": [String]()], 400, "\"items\" is empty — name at least one backlog item"),
            (["project": "alpha", "items": ["a", "b", "a"]], 400, "\"items\" names 'a' more than once"),
            (["project": "alpha", "items": ["b", "ghost", "a"]], 404, "No backlog item 'ghost' in this project")
        ]

        for request in refused {
            let (status, body) = try await harness.post("/v1/runs", request.body)

            XCTAssertEqual(status, request.status, "\(request.body)")
            XCTAssertEqual(body["error"] as? String, request.error)
        }
        XCTAssertNil(autopilot.lastStartOutcome, "nothing was asked to start")
        XCTAssertNil(autopilot.requestedOrder)
        XCTAssertTrue(autopilot.selectedItemIDs.isEmpty, "and nothing was selected")
    }

    /// The run block says what the list is and how far the run has got.
    func testTheRunBlockReportsTheOrderAndThePositionInIt() async throws {
        let autopilot = try registerListProject()
        let queue = ["b", "a", "c"].map {
            BacklogItem(id: $0, title: "Item \($0)", verify: "true", status: .ready, type: .local, size: .s)
        }
        autopilot.stageRunForTesting(status: .running(itemIndex: 1, total: 3), queue: queue)
        autopilot.stageQueueIndexForTesting(1)
        autopilot.stageExecutingRunForTesting(true)

        let running = try await runBlock()

        XCTAssertEqual(running["order"] as? [String], ["b", "a", "c"])
        XCTAssertEqual(running["orderIndex"] as? Int, 1)
        XCTAssertEqual(running["item"] as? String, "a")

        autopilot.stageExecutingRunForTesting(false)
        autopilot.stageRunForTesting(status: .idle, queue: queue)
        let idle = try await runBlock()

        XCTAssertEqual(idle["order"] as? [String], ["b", "a", "c"], "the last run's queue stays readable")
        XCTAssertTrue(idle["orderIndex"] is NSNull, "nothing in flight has no position: \(idle)")
    }

    // MARK: - Helpers

    /// The `run` block `GET /v1/projects` reports for the one project open.
    private func runBlock() async throws -> [String: Any] {
        let (_, body) = try await harness.get("/v1/projects")
        let projects = try XCTUnwrap(body["projects"] as? [[String: Any]])
        return try XCTUnwrap(projects.first?["run"] as? [String: Any])
    }

    /// A project holding `a`, `b` and `c` — written in that order, `c` alone
    /// promoted to `now` — each groomed enough to pass every pickup gate, so
    /// the queue that comes out is the ordering and not the grooming.
    private func registerListProject() throws -> BacklogAutopilot {
        let details = tempDir.appendingPathComponent("alpha/backlog", isDirectory: true)
        try FileManager.default.createDirectory(at: details, withIntermediateDirectories: true)
        for id in ["a", "b", "c"] {
            try """
            ---
            id: \(id)
            title: Item \(id)
            status: ready
            size: S
            verify:
              - name: build
                cmd: "true"
            ---

            ## What

            Something small and self-contained.

            ## How

            Change it in place.

            ## Validation

            - [ ] It still works
            """.write(to: details.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        }
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] a | Item a | ready → [detail](backlog/a.md)",
            "- [ ] b | Item b | ready → [detail](backlog/b.md)",
            "- [ ] c | Item c | lane:now | ready → [detail](backlog/c.md)"
        ], wireBacklog: true)
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        return autopilot
    }


    /// The parts of a reply these tests read, as a value a task can hand back.
    private struct Reply: Sendable {
        let status: Int
        let runID: String?
        let runStatus: String?
        let error: String?
    }

    /// Replaces the autopilot's `start()` with one that does `first` on the way
    /// in, then stays undecided until the returned continuation is yielded to,
    /// then does `thenDecide` and returns. The real gates decide in microseconds
    /// on a test project; this is how a start gets to be slow.
    private func holdStart(of autopilot: BacklogAutopilot,
                           first: @escaping @MainActor (BacklogAutopilot) -> Void = { _ in },
                           thenDecide: @escaping @MainActor (BacklogAutopilot) -> Void) -> AsyncStream<Void>.Continuation {
        let (held, release) = AsyncStream<Void>.makeStream()
        autopilot.stageStartForTesting { autopilot in
            first(autopilot)
            for await _ in held { break }
            thenDecide(autopilot)
        }
        return release
    }

    /// Posts the run request and lets the held start go only once the request
    /// is seen waiting on the autopilot's decision — so the answer it gets was
    /// decided after it started waiting, not before.
    private func postWhileUndecided(_ autopilot: BacklogAutopilot,
                                    release: AsyncStream<Void>.Continuation,
                                    meanwhile: @MainActor () -> Void = {}) async throws -> Reply {
        let harness = try XCTUnwrap(self.harness)
        let request = Task { @MainActor in
            let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])
            return Reply(status: status, runID: body["runId"] as? String,
                         runStatus: body["status"] as? String, error: body["error"] as? String)
        }
        try await eventually("the request to be waiting on the autopilot's decision") {
            autopilot.startDecisionWaiterCountForTesting == 1
        }
        meanwhile()
        // Handing the main actor round changes nothing: only a decision answers.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(autopilot.startDecisionWaiterCountForTesting, 1, "answered before anything was decided")
        release.yield()
        return try await request.value
    }

    /// The project every test here posts `item-1` to, with a worker and a
    /// reviewer named so the request gets as far as asking for a start.
    private func registerConfiguredProject(wireBacklog: Bool = false) throws -> BacklogAutopilot {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready"
        ], wireBacklog: wireBacklog)
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        return autopilot
    }

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
