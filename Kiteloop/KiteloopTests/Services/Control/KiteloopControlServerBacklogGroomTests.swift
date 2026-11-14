import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/backlog/release` — the way out of the retry ceiling.
///
/// The ceiling stops autopilot from starting an item that has produced nothing
/// three times running, and for a while that was a one-way door: a retired item
/// cannot run, and only a run could clear the count, so the note telling a human
/// to re-groom it described something that could not happen. This endpoint is the
/// half that was missing, so what is asserted here is that it *actually releases*
/// — the ceiling's own verdict flips — and that it says so on the record.
///
/// Exercised over a real loopback socket with a real `BacklogViewModel` on disk,
/// like the other control-API tests.
@MainActor
final class KiteloopControlServerBacklogGroomTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var ledger: GroomingLedger!
    private var metrics: TaskMetricStore!
    private var harness: ControlServerHarness!
    private var extraHarnesses: [ControlServerHarness] = []
    private let token = "control-release-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-release")
        registry = ControlSessionRegistry()
        // Both stores live in the temp directory, so no test ever appends to the
        // developer's real ~/.kiteloop ledgers.
        ledger = GroomingLedger(url: tempDir.appendingPathComponent("grooming.jsonl"))
        metrics = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl")
        )
        harness = try await startServer(groomingLedger: ledger, metricStore: metrics)
    }

    override func tearDown() async throws {
        harness?.stop()
        extraHarnesses.forEach { $0.stop() }
        extraHarnesses = []
        harness = nil
        registry = nil
        ledger = nil
        metrics = nil
    }

    // MARK: - Releasing


    // MARK: - Filing from the phone

    func testFilingAddsADraftWithTheNoteAsItsWhat() async throws {
        let root = try registerProject(named: "alpha")

        let (code, body) = try await harness.post("/v1/backlog/items", [
            "project": "alpha", "title": "Refunds round to the cent", "note": "Seen on the order page."
        ])

        XCTAssertEqual(code, 201, "\(body)")
        XCTAssertEqual(body["item"] as? String, "refunds-round-to-the-cent")
        XCTAssertEqual(body["epic"] as? String, "Inbox")
        XCTAssertEqual(body["grooming"] as? String, "not asked")
        XCTAssertEqual(status(of: "refunds-round-to-the-cent", project: root), "draft")
        let detail = try XCTUnwrap(try detailNotes("refunds-round-to-the-cent", in: root))
        XCTAssertTrue(detail.contains("## What\n\nSeen on the order page."), detail)
    }

    func testTheSameTitleTwiceGetsItsOwnID() async throws {
        try registerProject(named: "alpha")
        _ = try await harness.post("/v1/backlog/items", ["project": "alpha", "title": "Fix login", "epic": "Now"])

        let (code, body) = try await harness.post("/v1/backlog/items", ["project": "alpha", "title": "Fix login", "epic": "Now"])

        XCTAssertEqual(code, 201)
        XCTAssertEqual(body["item"] as? String, "fix-login-2")
    }

    func testAKeyedFilingIsFiledOnceAndASecondSightingAnswersWithTheItemThere() async throws {
        let root = try registerProject(named: "alpha")
        let sighting: [String: Any] = ["project": "alpha", "title": "Review PR 12", "key": "PR 12 review"]

        let (first, filed) = try await harness.post("/v1/backlog/items", sighting)
        let (second, seen) = try await harness.post("/v1/backlog/items", sighting)

        XCTAssertEqual(first, 201, "\(filed)")
        XCTAssertEqual(filed["item"] as? String, "pr-12-review")
        XCTAssertEqual(second, 200, "\(seen)")
        XCTAssertEqual(seen["item"] as? String, "pr-12-review")
        XCTAssertEqual(seen["existing"] as? Bool, true)
        XCTAssertEqual(seen["status"] as? String, "draft")
        let backlog = try String(contentsOf: URL(fileURLWithPath: root).appending(path: "BACKLOG.md"), encoding: .utf8)
        XCTAssertEqual(backlog.components(separatedBy: "pr-12-review").count - 1, 1, "one line, not two")
    }

    func testAKeyedItemThatHasLeftTheBacklogIsAnsweredAsClosed() async throws {
        let root = try registerProject(named: "alpha")
        let details = URL(fileURLWithPath: root).appending(path: "backlog")
        try FileManager.default.createDirectory(at: details, withIntermediateDirectories: true)
        try "## What\n\nDone long ago.\n".write(to: details.appending(path: "pr-9-review.md"), atomically: true, encoding: .utf8)

        let (code, body) = try await harness.post("/v1/backlog/items",
                                                  ["project": "alpha", "title": "Review PR 9", "key": "pr-9-review"])

        XCTAssertEqual(code, 200, "\(body)")
        XCTAssertEqual(body["status"] as? String, "closed")
    }

    func testAKeyWithNoLetterOrDigitIsRefused() async throws {
        try registerProject(named: "alpha")

        let (code, _) = try await harness.post("/v1/backlog/items", ["project": "alpha", "title": "x", "key": "--"])

        XCTAssertEqual(code, 400)
    }

    func testAMissingTitleOrOneHoldingTheSeparatorIsRefusedAndNothingIsWritten() async throws {
        let root = try registerProject(named: "alpha")
        let before = try String(contentsOf: URL(fileURLWithPath: root).appending(path: "BACKLOG.md"), encoding: .utf8)

        let (blank, _) = try await harness.post("/v1/backlog/items", ["project": "alpha", "title": "  "])
        let (piped, _) = try await harness.post("/v1/backlog/items", ["project": "alpha", "title": "a | b"])

        XCTAssertEqual(blank, 400)
        XCTAssertEqual(piped, 400)
        let after = try String(contentsOf: URL(fileURLWithPath: root).appending(path: "BACKLOG.md"), encoding: .utf8)
        XCTAssertEqual(after, before)
    }

    func testGroomingWritesTheProposalAndLeavesTheItemADraft() async throws {
        let root = try registerProject(named: "alpha")
        harness.server.groomOneShot = { _, _, _, _ in
            #"{"items":[{"id":"x","title":"x","size":"S","verify":"swift build","what":"Refunds lose a cent.","how":"Round half up.","validation":["A refund of 0.005 rounds to 0.01"]}]}"#
        }

        let (code, body) = try await harness.post("/v1/backlog/items", [
            "project": "alpha", "title": "Refunds round to the cent", "groom": true
        ])

        XCTAssertEqual(code, 201)
        XCTAssertEqual(body["grooming"] as? String, "started")
        try await eventually("the grooming was written") {
            ((try? self.detailNotes("refunds-round-to-the-cent", in: root)) ?? "").contains("Round half up.")
        }
        XCTAssertEqual(status(of: "refunds-round-to-the-cent", project: root), "draft", "promotion stays a person's step")
    }

    func testWithoutAModelRunnerTheItemIsFiledAndGroomingSaysWhyNot() async throws {
        try registerProject(named: "alpha")

        let (code, body) = try await harness.post("/v1/backlog/items", ["project": "alpha", "title": "Idea", "groom": true])

        XCTAssertEqual(code, 201)
        XCTAssertTrue((body["grooming"] as? String ?? "").hasPrefix("unavailable"), "\(body)")
    }

    // MARK: - Promoting

    /// The move the API had no verb for. 92 drafts sat in this repo's backlog,
    /// most already groomed, and the only way to advance one was the app's list.
    func testPromotingADraftMakesItReady() async throws {
        let root = try registerProject(named: "alpha")
        XCTAssertEqual(status(of: "item-2", project: root), "draft", "Precondition")

        let (code, body) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "item-2"
        ])

        XCTAssertEqual(code, 200)
        XCTAssertEqual(body["was"] as? String, "draft")
        XCTAssertEqual(body["status"] as? String, "ready")
        XCTAssertEqual(body["changed"] as? Bool, true)
        XCTAssertEqual(status(of: "item-2", project: root), "ready",
                       "the backlog itself has to agree, not just the response")
    }

    /// Promoting an item the Definition-of-Ready would refuse at pickup is
    /// refused here instead, with the same clauses — the queue must not gain
    /// an item nothing can start.
    func testPromotingAnUngroomedDraftIsRefusedNamingTheClauses() async throws {
        let root = try registerProject(named: "alpha")

        let (code, body) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "item-4"
        ])

        XCTAssertEqual(code, 422)
        let reasons = try XCTUnwrap(body["notReady"] as? [String], "\(body)")
        XCTAssertTrue(reasons.contains { $0.contains("no groomed detail file") }, "\(reasons)")
        XCTAssertTrue((body["error"] as? String ?? "").contains("force"), "\(body)")
        XCTAssertEqual(status(of: "item-4", project: root), "draft", "a refused promotion moves nothing")
    }

    /// A groomed draft whose `needs:` is not done yet is promoted: the
    /// dependency decides when it runs, which pickup judges, not whether it is
    /// groomed.
    func testPromotingAGroomedDraftWhoseDependencyIsNotDoneSucceeds() async throws {
        let root = try registerProject(named: "alpha")

        let (code, body) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "item-5"
        ])

        XCTAssertEqual(code, 200, "\(body)")
        XCTAssertEqual(status(of: "item-5", project: root), "ready")
    }

    /// `force: true` is the caller taking responsibility — the promotion goes
    /// through, and pickup still judges the item as it always has.
    func testForcePromotesAnUngroomedDraftAnyway() async throws {
        let root = try registerProject(named: "alpha")

        let (code, body) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "item-4", "force": true
        ])

        XCTAssertEqual(code, 200)
        XCTAssertEqual(body["status"] as? String, "ready")
        XCTAssertEqual(status(of: "item-4", project: root), "ready")
    }

    /// `ready` is the default because promoting is what this is for; the other
    /// direction is how a promotion is taken back.
    func testStatusDraftSendsAReadyItemBack() async throws {
        let root = try registerProject(named: "alpha")

        let (code, body) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "item-1", "status": "draft"
        ])

        XCTAssertEqual(code, 200)
        XCTAssertEqual(body["was"] as? String, "ready")
        XCTAssertEqual(body["changed"] as? Bool, true)
        XCTAssertEqual(status(of: "item-1", project: root), "draft")
        // Not silent: three items were back at draft on 2026-09-20 with
        // nothing on them saying who moved them.
        let notes = try XCTUnwrap(detailNotes("item-1", in: root))
        XCTAssertTrue(notes.contains("sent back to draft: over the control API"), notes)
    }

    /// Asking for the status it already holds is not an error — a driver looping
    /// over a night's drafts should not have to check first — but it says plainly
    /// that nothing moved.
    func testPromotingAnAlreadyReadyItemChangesNothing() async throws {
        let root = try registerProject(named: "alpha")

        let (code, body) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "item-1"
        ])

        XCTAssertEqual(code, 200)
        XCTAssertEqual(body["changed"] as? Bool, false)
        XCTAssertEqual(status(of: "item-1", project: root), "ready")
    }

    // MARK: - Lifting a block

    /// `blocked` was reachable from every stage and left through none: groom
    /// moved draft and ready only, so a block was cleared by editing BACKLOG.md
    /// by hand — which lost the reason. Groom now lifts it, and the reason goes
    /// to the Notes first.
    func testABlockedItemIsLiftedToDraftWithItsReasonKeptInTheNotes() async throws {
        let root = try registerProject(named: "alpha")
        XCTAssertEqual(status(of: "item-3", project: root), "blocked", "Precondition")

        let (code, body) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "item-3", "status": "draft"
        ])

        XCTAssertEqual(code, 200)
        XCTAssertEqual(body["was"] as? String, "blocked")
        XCTAssertEqual(body["status"] as? String, "draft")
        XCTAssertEqual(status(of: "item-3", project: root), "draft")
        let notes = try String(contentsOf: URL(fileURLWithPath: root).appending(path: "backlog/item-3.md"),
                               encoding: .utf8)
        XCTAssertTrue(notes.contains("unblocked by hand; was: the verify never ran"), notes)
    }

    /// Ready is the default target here too — the item was groomed before it
    /// was blocked, and the pickup gates still judge it.
    func testABlockedItemIsLiftedToReadyByDefault() async throws {
        let root = try registerProject(named: "alpha")

        let (code, body) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "item-3"
        ])

        XCTAssertEqual(code, 200)
        XCTAssertEqual(body["was"] as? String, "blocked")
        XCTAssertEqual(body["changed"] as? Bool, true)
        XCTAssertEqual(status(of: "item-3", project: root), "ready")
    }

    // MARK: - What it refuses

    /// Every other transition belongs to the machinery that earns it — a run
    /// moves an item to `active`, an approval to `done`. A general status setter
    /// here would be a way to stamp those from outside the gate that grants them.
    func testAnItemInAnotherStatusIsRefused() async throws {
        try registerProject(named: "alpha")
        await setStatus("item-1", to: .awaitingApproval, project: "alpha")

        let (code, body) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "item-1"
        ])

        XCTAssertEqual(code, 409)
        XCTAssertTrue((body["error"] as? String ?? "").contains("awaiting-approval"),
                      "the refusal has to name the status it would not move: \(body)")
    }

    func testAStatusOtherThanReadyOrDraftIsRefused() async throws {
        try registerProject(named: "alpha")

        let (code, _) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "item-1", "status": "done"
        ])

        XCTAssertEqual(code, 400)
    }

    func testAnUnknownItemIs404() async throws {
        try registerProject(named: "alpha")

        let (code, _) = try await harness.post("/v1/backlog/groom", [
            "project": "alpha", "item": "no-such-item"
        ])

        XCTAssertEqual(code, 404)
    }

    func testAProjectThatIsNotOpenIs409() async throws {
        try registerProject(named: "alpha")

        let (code, _) = try await harness.post("/v1/backlog/groom", [
            "project": "beta", "item": "item-1"
        ])

        XCTAssertEqual(code, 409)
    }

    func testAMissingItemFieldIs400() async throws {
        try registerProject(named: "alpha")

        let (code, _) = try await harness.post("/v1/backlog/groom", ["project": "alpha"])

        XCTAssertEqual(code, 400)
    }

    // MARK: - Reading the backlog back

    private func status(of itemID: String, project root: String) -> String? {
        let text = (try? String(contentsOf: URL(fileURLWithPath: root)
            .appending(path: "BACKLOG.md"), encoding: .utf8)) ?? ""
        guard let line = text.split(separator: "\n").first(where: { $0.contains(itemID) })
        else { return nil }
        return BacklogParser.parseItemLine(String(line), verifyDefault: nil)?.status.rawValue
    }

    /// Through the view model, not the file: the server reads the backlog it has
    /// already loaded, so rewriting `BACKLOG.md` underneath it changes nothing
    /// this request will see.
    @MainActor
    private func setStatus(_ itemID: String, to status: BacklogItemStatus, project name: String) {
        registry.entry(forProject: name)?.session.backlogViewModel
            .updateItemStatus(itemID: itemID, newStatus: status)
    }


    private func detailNotes(_ itemID: String, in root: String) throws -> String? {
        let url = URL(fileURLWithPath: root).appending(path: "backlog/\(itemID).md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A project with one groomed item that has a detail file to write notes into.
    @discardableResult
    // MARK: - The gate's diff

    /// `GET /v1/backlog/diff` — what a human at the gate reads before
    /// approving. Git is scripted, so the assertion is about the commands the
    /// handler asks and how it reports their answers, without needing a repo.
    func testDiffAnswersStatAndPatchForTheItemsBranch() async throws {
        try registerProject(named: "alpha")
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.contains("rev-parse") { return .init(status: 0, output: "abc123\n") }
            if call.arguments.contains("--stat") { return .init(output: " a.swift | 2 +-\n 1 file changed\n") }
            if call.arguments.contains("diff") { return .init(output: "diff --git a/a.swift b/a.swift\n+new\n") }
            return .init()
        }
        let (status, body): (Int, [String: Any]) = try await withScriptedSubprocesses(runner) {
            try await self.harness.get("/v1/backlog/diff?project=alpha&item=item-1")
        }

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["branch"] as? String, "kiteloop/item-1")
        XCTAssertEqual(body["stat"] as? String, " a.swift | 2 +-\n 1 file changed\n")
        XCTAssertEqual(body["patch"] as? String, "diff --git a/a.swift b/a.swift\n+new\n")
        XCTAssertEqual(body["truncated"] as? Bool, false)
        let diffCall = runner.calls.first { $0.arguments.contains("HEAD...kiteloop/item-1") }
        XCTAssertNotNil(diffCall, "three-dot against HEAD: only the branch's own work shows")
    }

    /// No branch is an honest 404, not an empty diff — an empty diff would read
    /// as "nothing to review" over work that simply never had a branch.
    func testDiffWithoutABranchIs404() async throws {
        try registerProject(named: "alpha")
        let runner = ScriptedSubprocessRunner { call in
            call.arguments.contains("rev-parse") ? .init(status: 1) : .init()
        }
        let (status, _): (Int, [String: Any]) = try await withScriptedSubprocesses(runner) {
            try await self.harness.get("/v1/backlog/diff?project=alpha&item=item-1")
        }
        XCTAssertEqual(status, 404)
    }

    /// A git that never exits must not hang the endpoint, and must not answer
    /// a 200 carrying an empty patch — the timed-out call reports as an error
    /// naming the timeout, not as a diff of nothing.
    func testDiffTimingOutIsAnErrorNotAnEmptyPatch() async throws {
        try registerProject(named: "alpha")
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.contains("rev-parse") { return .init(status: 0, output: "abc123\n") }
            if call.arguments.contains("--stat") { return .init(timedOut: true) }
            return .init()
        }
        let (status, body): (Int, [String: Any]) = try await withScriptedSubprocesses(runner) {
            try await self.harness.get("/v1/backlog/diff?project=alpha&item=item-1")
        }
        XCTAssertEqual(status, 504)
        XCTAssertEqual(body["truncated"] as? Bool, nil, "a timeout answers an error, not a diff body")
        let message = try XCTUnwrap(body["error"] as? String)
        XCTAssertTrue(message.contains("timed out"), "expected a timeout message, got: \(message)")
        let statCall = try XCTUnwrap(runner.calls.first { $0.arguments.contains("--stat") })
        XCTAssertNotNil(statCall.timeout, "each git the endpoint runs must be on a deadline")
        // The patch's own diff must never run: the stat call already timed out.
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("HEAD...kiteloop/item-1") && !$0.arguments.contains("--stat") })
    }

    // MARK: - Drilling into an item

    /// `GET /v1/backlog/detail` — the phone's item screen: line fields plus the
    /// groomed detail file, read as the gates read it.
    func testDetailAnswersTheLineFieldsAndTheGroomedSections() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.get("/v1/backlog/detail?project=alpha&item=item-1")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["id"] as? String, "item-1")
        XCTAssertEqual(body["title"] as? String, "An item")
        XCTAssertEqual(body["status"] as? String, "ready")
        XCTAssertEqual(body["size"] as? String, "S")
        XCTAssertEqual(body["verify"] as? String, "swift build")
        XCTAssertEqual(body["what"] as? String, "The outcome this item delivers.")
        XCTAssertEqual(body["acceptanceCriteria"] as? [String], ["It works"])
    }

    func testDetailOfAnUnknownItemIs404AndAMissingQueryIs400() async throws {
        try registerProject(named: "alpha")
        let (unknown, _) = try await harness.get("/v1/backlog/detail?project=alpha&item=nope")
        XCTAssertEqual(unknown, 404)
        let (missing, _) = try await harness.get("/v1/backlog/detail?project=alpha")
        XCTAssertEqual(missing, 400)
    }

    private func registerProject(named name: String) throws -> String {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        try """
        # \(name) Backlog

        ## Now

        - [ ] item-1 | An item | ready | size: S → [detail](backlog/item-1.md)
        - [ ] item-2 | A groomed draft | draft | size: S → [detail](backlog/item-1.md)
        - [ ] item-3 | A blocked item | blocked:the verify never ran | size: S → [detail](backlog/item-3.md)
        - [ ] item-4 | An ungroomed draft | draft | size: S
        - [ ] item-5 | A groomed draft waiting on another item | needs:item-1 | draft | size: S → [detail](backlog/item-1.md)
        """.write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        try """
        ## What

        A blocked item's outcome.

        ## Validation

        - [ ] It works
        """.write(to: root.appending(path: "backlog/item-3.md"), atomically: true, encoding: .utf8)
        try """
        ---
        id: item-1
        title: An item
        size: S
        verify:
          - name: build
            cmd: "swift build"
        ---

        ## What

        The outcome this item delivers.

        ## How

        The way it is delivered.

        ## Validation

        - [ ] It works
        """.write(to: root.appending(path: "backlog/item-1.md"), atomically: true, encoding: .utf8)

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
        registry.register(session: session, autopilot: BacklogAutopilot())
        return rootURL.path(percentEncoded: false)
    }

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

    private func startServer(groomingLedger: GroomingLedger?,
                             metricStore: TaskMetricStore?) async throws -> ControlServerHarness {
        try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0,
                                  metricStore: metricStore,
                                  groomingLedger: groomingLedger)
        }
    }
}
