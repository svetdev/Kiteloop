import XCTest
import KiteloopCore
@testable import Kiteloop

/// The signal half of the refill pass — `CoordinatorQueueRefillTests` covers
/// what the model drafts; these cover what the repo's own instruments do.
///
/// Each test rigs a project so `SignalSources.gather` finds one real thing: an
/// `ItemApprovalEvent` reopen in the approvals ledger (no subprocess needed),
/// or a working `scripts/run-unit-suite.sh` a test writes itself. What is
/// asserted is that the finding reaches the backlog through the same
/// `gate`/`fileDraft` path a model draft takes — deduped the same way,
/// gated the same way, and never let a hung instrument hold the pass past
/// its deadline.
@MainActor
final class CoordinatorQueueRefillSignalDraftingTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var ledgerURL: URL!
    private var approvalsLedgerURL: URL!
    private var globalConfigStore: GlobalConfigStore!
    private var groomingLedger: GroomingLedger!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "queue-refill-signals")
        registry = ControlSessionRegistry()
        ledgerURL = tempDir.appending(path: "ledger.jsonl")
        approvalsLedgerURL = tempDir.appending(path: "task-approvals.jsonl")
        globalConfigStore = GlobalConfigStore(storageURL: tempDir.appending(path: "global.json"))
        groomingLedger = GroomingLedger(url: tempDir.appending(path: "grooming.jsonl"))
    }

    override func tearDownWithError() throws {
        registry = nil
        globalConfigStore = nil
        groomingLedger = nil
    }

    // MARK: - Files instead of `.noDrafts`

    /// Validation: "A pass whose model reply drafts nothing but whose
    /// instruments report one flake files that item instead of returning
    /// `.noDrafts`." The escaped-defect signal needs only a ledger file
    /// rather than a real subprocess, so it is the cheapest instrument to
    /// stand in for "one finding" here; the flake instrument gets its own
    /// test below with a real script.
    func testAnEscapedDefectFindingFilesEvenWhenTheModelDraftsNothing() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeApprovalEvents([
            reopenedEvent(itemID: "old-item", projectPath: fixture.rootURL.path(percentEncoded: false))
        ])
        let (refill, runtime) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0),
                       "an instrument's own finding must not be silently dropped as .noDrafts")
        XCTAssertEqual(runtime.sentPrompts.count, 1, "the model was still asked — the signal is additive")
        let item = try XCTUnwrap(fixture.backlogViewModel.backlogFile?.sections.flatMap(\.items)
            .first { $0.id == "escaped-defect-old-item" })
        XCTAssertEqual(item.status, .ready)
    }

    /// The literal instrument the acceptance criterion names — a real
    /// `scripts/run-unit-suite.sh --flakes` this test writes, parsed the way
    /// `SignalSources` parses the real one.
    func testAFlakeFindingFilesTheItemInsteadOfReturningNoDrafts() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeFlakeScript(inProject: "alpha", testName: "FooTests.testBar")
        let (refill, _) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true

        let outcome = await refill.runPass()

        guard case .filed(let project, let ready, let drafts, let refused) = outcome else {
            return XCTFail("a flake finding must file rather than fall back to .noDrafts, got \(outcome)")
        }
        XCTAssertEqual(project, "alpha")
        XCTAssertEqual(ready + drafts, 1, "exactly the one flake finding was filed")
        XCTAssertEqual(refused, 0)
        XCTAssertTrue(fixture.backlogViewModel.backlogFile?.sections.flatMap(\.items)
            .contains { $0.id.hasPrefix("flaky-test-") } ?? false)
    }

    // MARK: - The pass never files past its own cap

    /// Validation: "A pass whose `Target.count` is N files at most N items
    /// however many findings the instruments report." The default policy's
    /// `targetDepth` leaves a shortfall of 3 against an empty queue; four
    /// reopens report four escaped-defect findings, one more than the pass may
    /// file — more approval-ledger reopens than the shortfall.
    func testAPassFilesAtMostItsTargetCountHoweverManyFindingsTheInstrumentsReport() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeApprovalEvents((1...4).map {
            reopenedEvent(itemID: "item-\($0)", projectPath: fixture.rootURL.path(percentEncoded: false))
        })
        let (refill, runtime) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 3, drafts: 0, refused: 0),
                       "the shortfall is 3 — the fourth finding must wait for the next pass")
        XCTAssertEqual(runtime.sentPrompts.count, 1, "the model was still asked — the signal is additive")
        let filedIDs = fixture.backlogViewModel.backlogFile?.sections.flatMap(\.items).map(\.id) ?? []
        XCTAssertEqual(filedIDs.count, 3, "the pass filed no more than it was asked for")
        for index in 1...3 {
            XCTAssertTrue(filedIDs.contains("escaped-defect-item-\(index)"), "\(filedIDs)")
        }
        XCTAssertFalse(filedIDs.contains("escaped-defect-item-4"),
                       "left over for the next pass, not filed past the cap")
    }

    /// Validation: "When the model's accepted drafts already reach N, no
    /// signal draft is filed and the count left over is logged." The model's
    /// own three drafts already fill the shortfall, so the one real finding
    /// waiting in the approvals ledger is left for the next pass rather than
    /// pushing the pass to four.
    func testNoSignalDraftIsFiledWhenTheModelsOwnDraftsAlreadyReachTheTarget() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeApprovalEvents([
            reopenedEvent(itemID: "old-item", projectPath: fixture.rootURL.path(percentEncoded: false))
        ])
        let modelReply = """
        {"items":[
          {"id":"model-one","title":"Model draft one","size":"S","verify":"/bin/echo ok",
           "what":"The `BACKLOG.md` file gains model draft one.",
           "how":"Read `BACKLOG.md` and write the line.",
           "validation":["model draft one is there"],"outOfScope":["Nothing else"]},
          {"id":"model-two","title":"Model draft two","size":"S","verify":"/bin/echo ok",
           "what":"The `BACKLOG.md` file gains model draft two.",
           "how":"Read `BACKLOG.md` and write the line.",
           "validation":["model draft two is there"],"outOfScope":["Nothing else"]},
          {"id":"model-three","title":"Model draft three","size":"S","verify":"/bin/echo ok",
           "what":"The `BACKLOG.md` file gains model draft three.",
           "how":"Read `BACKLOG.md` and write the line.",
           "validation":["model draft three is there"],"outOfScope":["Nothing else"]}
        ]}
        """
        let (refill, _) = makeRefill(response: modelReply)
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 3, drafts: 0, refused: 0),
                       "the model's own three drafts already fill the shortfall")
        let filedIDs = fixture.backlogViewModel.backlogFile?.sections.flatMap(\.items).map(\.id) ?? []
        XCTAssertEqual(Set(filedIDs), ["model-one", "model-two", "model-three"])
        XCTAssertFalse(filedIDs.contains("escaped-defect-old-item"),
                       "the finding is real but the pass is already full — it waits for the next pass")
    }

    // MARK: - No room means the instruments never run

    /// Validation: "On a pass whose drafter returns a full set of surviving
    /// drafts, neither instrument is spawned ... and the filed drafts are
    /// exactly the model's." Both instruments are rigged to touch a marker
    /// file when run, so this proves they were never spawned — not merely
    /// that whatever they found went unused.
    func testInstrumentsAreNotSpawnedWhenTheModelsDraftsAlreadyFillTheShortfall() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let marker = tempDir.appending(path: "instruments-ran.marker")
        try writeMarkerScript(inProject: "alpha", relativePath: "scripts/run-unit-suite.sh", marker: marker)
        try writeMarkerScript(inProject: "alpha", relativePath: "quality/bin/report-hotspots.py", marker: marker)
        let modelReply = """
        {"items":[
          {"id":"model-one","title":"Model draft one","size":"S","verify":"/bin/echo ok",
           "what":"The `BACKLOG.md` file gains model draft one.",
           "how":"Read `BACKLOG.md` and write the line.",
           "validation":["model draft one is there"],"outOfScope":["Nothing else"]},
          {"id":"model-two","title":"Model draft two","size":"S","verify":"/bin/echo ok",
           "what":"The `BACKLOG.md` file gains model draft two.",
           "how":"Read `BACKLOG.md` and write the line.",
           "validation":["model draft two is there"],"outOfScope":["Nothing else"]},
          {"id":"model-three","title":"Model draft three","size":"S","verify":"/bin/echo ok",
           "what":"The `BACKLOG.md` file gains model draft three.",
           "how":"Read `BACKLOG.md` and write the line.",
           "validation":["model draft three is there"],"outOfScope":["Nothing else"]}
        ]}
        """
        let (refill, _) = makeRefill(response: modelReply)
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 3, drafts: 0, refused: 0),
                       "the model's own three drafts already fill the shortfall")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)),
                       "no room was left for a signal finding — the instruments must not have run at all")
        let filedIDs = fixture.backlogViewModel.backlogFile?.sections.flatMap(\.items).map(\.id) ?? []
        XCTAssertEqual(Set(filedIDs), ["model-one", "model-two", "model-three"])
    }

    /// Validation: "On a pass whose drafter returns fewer drafts than the
    /// shortfall, the instruments still run ... unchanged from today." Same
    /// marker rig as above, but the model comes back with nothing, so the
    /// full shortfall is room for the instruments.
    func testInstrumentsAreStillSpawnedWhenTheModelLeavesRoom() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let marker = tempDir.appending(path: "instruments-ran.marker")
        try writeMarkerScript(inProject: "alpha", relativePath: "scripts/run-unit-suite.sh", marker: marker)
        let (refill, _) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true

        _ = await refill.runPass()

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)),
                      "the model left room — the flake instrument must still have run")
    }

    // MARK: - Never file the same gap twice

    /// Validation: "A finding whose derived id is already an item in the
    /// backlog... files nothing." The ledger can't see a hand-written line —
    /// only the backlog itself can — so this is the half `existingIDs`'s
    /// backlog union exists for.
    func testAFindingAlreadyInTheBacklogIsNotRefiled() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0, extraLines: [
            "- [ ] escaped-defect-old-item | Already on the board | verify: true | size:S | "
                + "ready → [detail](backlog/escaped-defect-old-item.md)"
        ])
        try writeApprovalEvents([
            reopenedEvent(itemID: "old-item", projectPath: fixture.rootURL.path(percentEncoded: false))
        ])
        let (refill, _) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .noDrafts(project: "alpha"),
                       "the finding's id is already on the board — nothing was left to file")
        XCTAssertEqual(fixture.backlogViewModel.backlogFile?.sections.flatMap(\.items).map(\.id),
                       ["escaped-defect-old-item"], "not refiled under a suffixed id either")
    }

    /// Validation: "...or already in `QueueRefill.Ledger` for that project,
    /// files nothing." The same finding is still sitting in the approvals
    /// ledger on the second pass — nothing here re-reads or clears it — so
    /// this is the ledger dedup rather than the backlog dedup above.
    func testAFindingAlreadyInTheRefillLedgerIsNotRefiledOnALaterPass() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeApprovalEvents([
            reopenedEvent(itemID: "old-item", projectPath: fixture.rootURL.path(percentEncoded: false))
        ])
        let (refill, _) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true

        let first = await refill.runPass()
        XCTAssertEqual(first, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))

        // The item was filed as ready; a human rejecting it leaves the same
        // gap open, and the instrument reports the very same finding again —
        // the refill ledger is what stops it landing twice.
        fixture.backlogViewModel.updateItemStatus(itemID: "escaped-defect-old-item", newStatus: .blocked)

        let second = await refill.runPass()

        XCTAssertEqual(second, .noDrafts(project: "alpha"))
        XCTAssertEqual(fixture.backlogViewModel.backlogFile?.sections.flatMap(\.items)
            .filter { $0.id == "escaped-defect-old-item" }.count, 1)
    }

    // MARK: - A signal draft is gated exactly like a model draft

    /// Validation: "A signal draft that fails a gate is parked at `draft`
    /// with its refusal recorded, exactly as a model draft is." A reopened
    /// item whose id carries the backlog's own field separator drafts a
    /// title that carries it too (`Escaped defect: weird | item`), which is
    /// the one Definition-of-Ready clause under a signal drafter's own
    /// control: `defaultVerify`, the size and the What/How/Validation shape
    /// are all fixed, but the title comes straight from the finding.
    func testASignalDraftThatFailsAGateIsParkedAsDraftWithItsRefusalRecorded() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeApprovalEvents([
            reopenedEvent(itemID: "weird | item", projectPath: fixture.rootURL.path(percentEncoded: false))
        ])
        let (refill, _) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 0, drafts: 1, refused: 0),
                       "a gate failure still lands the item — parked, not silently dropped")
        let item = try XCTUnwrap(fixture.backlogViewModel.backlogFile?.sections.flatMap(\.items)
            .first { $0.id == "escaped-defect-weird-item" })
        XCTAssertEqual(item.status, .draft, "an instrument's own finding must never skip the gate it came from")

        XCTAssertEqual(groomingLedger.records.map(\.event), [.filedDraft, .checkFailed],
                       "the filing still happens, and says why it was parked — same as a model draft")
        let refusal = try XCTUnwrap(groomingLedger.records.last)
        XCTAssertEqual(refusal.check, GroomingRecord.Check.definitionOfReady)
        XCTAssertTrue(refusal.reason?.contains("field separator") == true,
                      "the verdict verbatim: \(refusal.reason ?? "nil")")
    }

    // MARK: - A signal draft's kind shows in the filed detail

    /// Validation: "Planner drafting selects a kind and the filed detail
    /// shows the skeleton." A flake is a bug — never a claim of user value —
    /// so the filed `## What` carries the repro sentence
    /// `BacklogTemplate.ItemKind.bug` demands, picked from the finding
    /// itself rather than asked of a model.
    func testAFlakeFindingFilesWithTheBugSkeletonsRepro() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeFlakeScript(inProject: "alpha", testName: "FooTests.testBar")
        let (refill, _) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true

        _ = await refill.runPass()

        let item = try XCTUnwrap(fixture.backlogViewModel.backlogFile?.sections.flatMap(\.items)
            .first { $0.id.hasPrefix("flaky-test-") })
        let detail = try XCTUnwrap(fixture.backlogViewModel.loadDetail(for: item))
        let what = try XCTUnwrap(detail.what)
        XCTAssertTrue(BacklogTemplate.ItemKind.bug.carriesClause(what), what)
    }

    /// The same for a hotspot — an instrument's finding is internal work, so
    /// it is filed with the tooling skeleton's "Serves:" clause rather than
    /// as a bug.
    func testAHotspotFindingFilesWithTheToolingSkeletonsServesClause() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeHotspotScript(inProject: "alpha")
        let (refill, _) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true

        _ = await refill.runPass()

        let item = try XCTUnwrap(fixture.backlogViewModel.backlogFile?.sections.flatMap(\.items)
            .first { $0.id.hasPrefix("hotspot-") })
        let detail = try XCTUnwrap(fixture.backlogViewModel.loadDetail(for: item))
        let what = try XCTUnwrap(detail.what)
        XCTAssertTrue(BacklogTemplate.ItemKind.tooling.carriesClause(what), what)
    }

    // MARK: - Gathering is bounded

    /// Validation: "Gathering happens off the main actor and under a
    /// deadline: a pass whose instruments hang still ends at `passDeadline`
    /// rather than blocking the app." The model answers immediately; what
    /// hangs is `scripts/run-unit-suite.sh` itself, well past the deadline.
    func testAHungInstrumentEndsThePassAtItsDeadlineRatherThanBlocking() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        try writeSleepingScript(inProject: "alpha", seconds: 5)
        let (refill, _) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true
        refill.passDeadline = 0.3

        let start = Date()
        let outcome = await refill.runPass()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3, "a hung instrument must not hold the pass past its deadline")
        guard case .abandoned(let project, _, _, let why) = outcome else {
            return XCTFail("expected the pass to be abandoned at its deadline, got \(outcome)")
        }
        XCTAssertEqual(project, "alpha")
        XCTAssertEqual(why, .deadline)
        XCTAssertFalse(refill.isPassing, "the flag is down even though the instrument is still sleeping")
    }

    // MARK: - Helpers

    private struct ProjectFixture {
        let backlogViewModel: BacklogViewModel
        let rootURL: URL
    }

    @discardableResult
    private func registerProject(named name: String, readyItems: Int,
                                 extraLines: [String] = []) throws -> ProjectFixture {
        let root = tempDir.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        // `SignalDrafting.defaultVerify` cites these; `GroundingCheck` refuses
        // a draft whose verify names no executable, so the fixture carries
        // stubs where the real project carries the scripts.
        for stub in ["quality/bin/check-complexity.sh", "quality/bin/check-layering.py",
                     "quality/bin/check-test-hygiene.py", "scripts/run-core-tests.sh"] {
            let url = root.appending(path: stub)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path(percentEncoded: false))
        }

        let existingLines = (1...max(1, readyItems)).prefix(readyItems)
            .map { "- [ ] existing-\($0) | Existing work \($0) | verify: true | size:S | "
                + "ready → [detail](backlog/existing-\($0).md)" }
        try "# \(name) Backlog\n\n## Now\n\n\((existingLines + extraLines).joined(separator: "\n"))\n"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)

        let detailDir = root.appending(path: "backlog", directoryHint: .isDirectory)
        if readyItems > 0 {
            try FileManager.default.createDirectory(at: detailDir, withIntermediateDirectories: true)
        }
        for index in (1...max(1, readyItems)).prefix(readyItems) {
            try """
            ## What

            Existing work \(index), already groomed.

            ## How

            Whatever the item says; this fixture only needs the clauses present.

            ## Validation

            - [ ] It ran.
            """.write(to: detailDir.appending(path: "existing-\(index).md"),
                      atomically: true, encoding: .utf8)
        }

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
            context: ProjectSessionContext(
                runtimeFactory: { MockAgentRuntime() },
                agentCatalogStore: AgentCatalogStore(
                    storageURL: tempDir.appending(path: "catalog-\(name).json")),
                packageResolver: nil,
                globalConfigStore: globalConfigStore,
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()
            )
        )
        session.backlogViewModel.loadForProject(repoPath: rootURL.path(percentEncoded: false))

        let autopilot = BacklogAutopilot()
        autopilot.workerAgentID = "worker"
        autopilot.autonomousWorkEnabled = true
        autopilot.reviewerAgentID = "reviewer"
        // What every signal draft runs: the project's own merge-verify. A
        // project with none has its findings left undrafted.
        autopilot.autoMergeVerifyCommand = "true"
        registry.register(session: session, autopilot: autopilot)
        return ProjectFixture(backlogViewModel: session.backlogViewModel, rootURL: rootURL)
    }

    /// The wiring every loop in this file gets. `approvalsLedgerURL` is
    /// always this test's own temp file — never the developer's real
    /// `~/.kiteloop/task-approvals.jsonl` — the same reason `ledgerURL` is.
    private func makeRefill(response: String, costUSD: Double = 0)
    -> (CoordinatorQueueRefill, StubHeadlessRuntime) {
        let runtime = StubHeadlessRuntime(behavior: .events([
            .assistantText(response),
            .result(.init(text: "", costUSD: costUSD, durationMs: 0,
                          inputTokens: 0, outputTokens: 0,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "stub-session", permissionDenials: []))
        ]))
        let refill = CoordinatorQueueRefill(
            ledgerURL: ledgerURL,
            approvalsLedgerURL: approvalsLedgerURL,
            blockedTriage: CoordinatorBlockedTriage(
                ledgerURL: tempDir.appending(path: "coordinator-triage.jsonl")))
        refill.groomingLedger = groomingLedger
        refill.configure(registry: registry,
                         globalConfigStore: globalConfigStore,
                         runtimeFactory: { runtime })
        return (refill, runtime)
    }

    /// A `.reopened` transition — the shape `EscapedDefectReader` reads out of
    /// the approvals ledger `SignalSources.gather` is handed.
    private func reopenedEvent(itemID: String, projectPath: String) -> ItemApprovalEvent {
        ItemApprovalEvent(projectPath: projectPath, projectName: "alpha", itemID: itemID,
                          kind: .reopened, at: Date(timeIntervalSince1970: 1_700_100_000),
                          approvedAt: Date(timeIntervalSince1970: 1_700_000_000), toStatus: "ready")
    }

    private func writeApprovalEvents(_ events: [ItemApprovalEvent]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = try events.map { event in
            String(data: try encoder.encode(event), encoding: .utf8) ?? ""
        }
        try (lines.joined(separator: "\n") + "\n").write(to: approvalsLedgerURL,
                                                         atomically: true, encoding: .utf8)
    }

    /// A real `scripts/run-unit-suite.sh --flakes` this test writes, printing
    /// exactly the shape `FlakeLedgerReader` parses.
    private func writeFlakeScript(inProject name: String, testName: String) throws {
        let contents = "#!/bin/sh\n"
            + "cat <<'FLAKES'\n"
            + "run-unit-suite: flake ledger\n"
            + "  \(testName)\n"
            + "    3 flips at abc123, def456 — 2026-08-01T00:00:00Z .. 2026-08-10T00:00:00Z\n"
            + "FLAKES\n"
        try writeExecutableScript(contents, inProject: name)
    }

    /// A `scripts/run-unit-suite.sh` that outlives any reasonable
    /// `passDeadline` — the instrument this file's deadline test hangs on.
    private func writeSleepingScript(inProject name: String, seconds: Int) throws {
        try writeExecutableScript("#!/bin/sh\nsleep \(seconds)\nexit 0\n", inProject: name)
    }

    /// A script that touches `marker` when run and exits clean with no
    /// findings — proof an instrument was actually spawned, not merely that
    /// its (absent) output went unused.
    private func writeMarkerScript(inProject name: String, relativePath: String, marker: URL) throws {
        let url = tempDir.appending(path: "\(name)/\(relativePath)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch \(marker.path(percentEncoded: false))\nexit 0\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path(percentEncoded: false))
    }

    private func writeExecutableScript(_ contents: String, inProject name: String) throws {
        let scriptsDir = tempDir.appending(path: "\(name)/scripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let script = scriptsDir.appending(path: "run-unit-suite.sh")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path(percentEncoded: false))
    }

    /// A real `quality/bin/report-hotspots.py` this test writes, printing
    /// exactly the shape `HotspotReportReader` parses.
    private func writeHotspotScript(inProject name: String) throws {
        let contents = "#!/bin/sh\n"
            + "cat <<'HOTSPOTS'\n"
            + "1 function(s) measured, 1 touched in the last 90 day(s), top 1 by churn x complexity:\n"
            + "  Kiteloop/Foo.swift:12  hotspot 56 (churn 8 x cc 7)  func doThing()\n"
            + "HOTSPOTS\n"
        let dir = tempDir.appending(path: "\(name)/quality/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "report-hotspots.py")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path(percentEncoded: false))
    }
}
