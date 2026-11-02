import XCTest
import KiteloopCore
@testable import Kiteloop

/// Looking into **one** project in full: every item by status, and the runs on
/// record with their outcomes, reasons, quality scores and cost.
///
/// The properties worth testing are the ones that separate an inspection from
/// the portfolio summary it complements. It is fetched by name, and a name that
/// isn't open is refused rather than resolved to the nearest project. A paused
/// project inspects like any other — pausing stops work, not questions. Its runs
/// are scoped to its own path, because records are global and keyed by item id.
/// And, like the summary, capturing one leaves every project exactly as it found
/// it.
@MainActor
final class ProjectInspectionTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "project-inspection")
        registry = ControlSessionRegistry()
    }

    override func tearDown() async throws {
        registry = nil
    }

    // MARK: - Every item, by status

    /// The headline difference from the summary, which names two statuses: an
    /// inspection names them all, in the order an item moves through them.
    func testInspectionNamesEveryItemOfEveryStatus() throws {
        let inspection = ProjectInspection.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("d1", .draft), ("r1", .ready), ("r2", .ready),
                                  ("b1", .blocked), ("done1", .done)])
        )

        XCTAssertEqual(inspection.groups.map(\.status), [.draft, .ready, .blocked, .done],
                       "statuses with no items contribute nothing at all")
        XCTAssertEqual(inspection.group(.ready)?.items.map(\.id), ["r1", "r2"])
        XCTAssertEqual(inspection.group(.ready)?.items.first?.title, "R1")
        XCTAssertEqual(inspection.group(.ready)?.items.first?.size, "S")
        XCTAssertEqual(inspection.totalItems, 5)
    }

    /// What "why is this project's blocked pile so big?" is actually answered
    /// from: the item's own annotation and what its last recorded run ended as,
    /// which are different claims and are kept apart.
    func testBlockedItemsCarryTheBacklogNoteAndTheLastRun() throws {
        let lookup = PortfolioSnapshot.lastRunLookup(
            metrics: metricStore([metric(itemID: "b1", projectPath: "/tmp/alpha",
                                         outcome: "blocked:verify_passed", quality: 0.4)]),
            projectPath: "/tmp/alpha"
        )

        let inspection = ProjectInspection.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: BacklogFile(project: "test", repo: nil, verifyDefault: nil, sections: [
                BacklogSection(name: "Epic", items: [
                    BacklogItem(id: "b1", title: "B1", verify: "true", status: .blocked,
                                type: .local, size: .m, blockedReason: "needs a decision"),
                    BacklogItem(id: "r1", title: "R1", verify: "true", status: .ready,
                                type: .local, size: .s, blockedReason: "stale note")
                ])
            ]),
            lastRun: lookup
        )

        let blocked = try XCTUnwrap(inspection.group(.blocked)?.items.first)
        XCTAssertEqual(blocked.blockedReason, "needs a decision")
        XCTAssertEqual(blocked.lastRun?.outcome, "blocked")
        XCTAssertEqual(blocked.lastRun?.reason, "verify_passed")
        XCTAssertEqual(blocked.lastRun?.qualityScore, 0.4)
        let ready = try XCTUnwrap(inspection.group(.ready)?.items.first)
        XCTAssertNil(ready.blockedReason, "only a blocked item is asked why it is blocked")
        XCTAssertNil(ready.lastRun, "the runs section is the fuller account for everything else")
    }

    /// An item nothing has ever run says exactly that. A guessed reason reads
    /// identically to a recorded one, which is what makes it worse than none.
    func testABlockedItemWithNothingOnRecordSaysSo() {
        let inspection = ProjectInspection.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: false,
            backlog: backlogFile([("b1", .blocked)])
        )

        XCTAssertNil(inspection.group(.blocked)?.items.first?.lastRun)
        XCTAssertTrue(inspection.promptSection.contains("b1 “B1” [S] — no recorded run"),
                      inspection.promptSection)
    }

    // MARK: - Runs

    /// The half the summary can't afford: what each run ended as, why, what the
    /// judge thought of it and what it cost.
    func testRunsAreNewestFirstWithOutcomeReasonQualityAndCost() throws {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let recent = Date(timeIntervalSince1970: 2_000_000)
        let inspection = ProjectInspection.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("b1", .blocked)]),
            records: [
                metric(itemID: "b1", projectPath: "/tmp/alpha", outcome: "blocked:verify failed",
                       quality: 0.35, cost: 1.25, completedAt: recent),
                metric(itemID: "a1", projectPath: "/tmp/alpha", outcome: "done",
                       cost: 0.5, completedAt: old)
            ]
        )

        XCTAssertEqual(inspection.runs.map(\.itemID), ["b1", "a1"])
        let newest = try XCTUnwrap(inspection.runs.first)
        XCTAssertEqual(newest.outcome, "blocked")
        XCTAssertEqual(newest.reason, "verify failed")
        XCTAssertEqual(newest.qualityScore, 0.35)
        XCTAssertEqual(newest.costUSD, 1.25, accuracy: 0.0001)
        XCTAssertNil(inspection.runs.last?.reason, "`done` carries no reason and none is invented")
        XCTAssertEqual(inspection.totalRuns, 2)
    }

    /// Records are global and keyed by item id, so an unscoped read would hand
    /// one project's runs to another project's identically-named item.
    func testRunsAreScopedToTheProjectBeingInspected() throws {
        let alpha = tempDir.appendingPathComponent("alpha", isDirectory: true)
            .path(percentEncoded: false)
        let beta = tempDir.appendingPathComponent("beta", isDirectory: true)
            .path(percentEncoded: false)
        try openProject(named: "alpha", items: [("shared", .blocked)])
        try openProject(named: "beta", items: [("shared", .blocked)])
        let store = metricStore([
            metric(itemID: "shared", projectPath: alpha, outcome: "blocked:alpha's reason"),
            metric(itemID: "shared", projectPath: beta, outcome: "blocked:beta's reason")
        ])

        let inspection = try XCTUnwrap(
            ProjectInspection.capture(registry: registry, projectNamed: "beta", metrics: store)
                .inspection
        )

        XCTAssertEqual(inspection.runs.map(\.reason), ["beta's reason"])
        XCTAssertEqual(inspection.group(.blocked)?.items.first?.lastRun?.reason, "beta's reason")
    }

    // MARK: - Bounds

    /// Deep is not unbounded: the result is prompt text, so both lists cap — and
    /// what a cap left out is counted rather than silently dropped.
    func testItemsAndRunsAreCappedAndSayWhatWasLeftOut() throws {
        let items = (1...30).map { ("b\($0)", BacklogItemStatus.blocked) }
        let records = (1...30).map {
            metric(itemID: "b\($0)", projectPath: "/tmp/alpha", outcome: "done",
                   completedAt: Date(timeIntervalSince1970: Double($0)))
        }

        let inspection = ProjectInspection.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile(items), records: records,
            itemLimit: 5, runLimit: 3
        )

        let blocked = try XCTUnwrap(inspection.group(.blocked))
        XCTAssertEqual(blocked.items.count, 5)
        XCTAssertEqual(blocked.omitted, 25)
        XCTAssertEqual(blocked.total, 30, "the total stays the truth; the list is a sample")
        XCTAssertEqual(inspection.runs.count, 3)
        XCTAssertEqual(inspection.runsOmitted, 27)
        let section = inspection.promptSection
        XCTAssertTrue(section.contains("blocked (5 of 30, 25 not shown)"), section)
        XCTAssertTrue(section.contains("Runs on record (3 of 30, newest first)"), section)
    }

    func testAWholeListSaysItIsWhole() {
        let section = ProjectInspection.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("r1", .ready), ("r2", .ready)]),
            records: [metric(itemID: "r0", projectPath: "/tmp/alpha", outcome: "done")]
        ).promptSection

        XCTAssertTrue(section.contains("ready (all 2)"), section)
        XCTAssertTrue(section.contains("Runs on record (all 1, newest first)"), section)
    }

    // MARK: - The prompt

    /// The answer has to be distinguishable from one built on the summary, and
    /// this heading is where that starts: the section says what it is and which
    /// project it is about.
    func testPromptSectionSaysWhatItIsAndCarriesTheDetail() throws {
        let lookup = PortfolioSnapshot.lastRunLookup(
            metrics: metricStore([metric(itemID: "b1", projectPath: "/tmp/alpha",
                                         outcome: "blocked:reviewer rejected twice")]),
            projectPath: "/tmp/alpha"
        )
        let inspection = ProjectInspection.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("r1", .ready), ("b1", .blocked)]),
            goal: "Ship the autonomy loop",
            records: [metric(itemID: "b1", projectPath: "/tmp/alpha",
                             outcome: "blocked:reviewer rejected twice",
                             quality: 0.42, cost: 1.2,
                             completedAt: Date(timeIntervalSince1970: 1_754_524_800))],
            lastRun: lookup
        )

        let section = inspection.promptSection

        XCTAssertTrue(section.hasPrefix("## Inspected: alpha"), section)
        XCTAssertTrue(section.contains("autopilot ready | goal: Ship the autonomy loop"),
                      section)
        XCTAssertFalse(section.contains("priority"), "the rank word is gone from the prompt: \(section)")
        XCTAssertTrue(section.contains("Items (2 in total)"), section)
        XCTAssertTrue(section.contains("ready (all 1):"), section)
        XCTAssertTrue(section.contains("- b1 “B1” [S] — last run blocked: reviewer rejected twice"),
                      section)
        XCTAssertTrue(section.contains("2025-08-07 b1 “B1”: blocked — reviewer rejected twice ($1.20, quality 0.42)"),
                      section)
        XCTAssertEqual(inspection.summaryLine, "alpha: 2 items, 1 run on record")
    }

    /// A project with nothing in it reports having nothing, which is a different
    /// answer from a project that could not be found.
    func testAnEmptyProjectInspectsHonestlyRatherThanEmptily() {
        let section = ProjectInspection.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: false, backlog: nil
        ).promptSection

        XCTAssertTrue(section.contains("(this project's backlog has no items)"), section)
        XCTAssertTrue(section.contains("(no run of this project has been recorded)"), section)
    }

    // MARK: - Paused

    /// Pausing stops work, not questions. A paused project inspects like any
    /// other and the section says it is paused — the hard stop is on *acting*,
    /// and it lives in `PortfolioSnapshot.selectableProjects` and the supervisor.
    func testAPausedProjectIsInspectedAndSaysItIsPaused() throws {
        try openProject(named: "travel", items: [("t1", .ready)], paused: true)

        let inspection = try XCTUnwrap(
            ProjectInspection.capture(registry: registry, projectNamed: "travel").inspection
        )

        XCTAssertTrue(inspection.isPaused)
        XCTAssertTrue(inspection.paused)
        XCTAssertEqual(inspection.group(.ready)?.items.map(\.id), ["t1"])
        XCTAssertTrue(inspection.promptSection.contains("This project is paused"),
                      inspection.promptSection)
        XCTAssertTrue(inspection.promptSection.contains("propose no work for it"),
                      inspection.promptSection)
    }

    // MARK: - Finding it by name

    func testCaptureFindsAProjectByItsNameOrItsPath() throws {
        try openProject(named: "alpha", items: [("a1", .ready)])
        let path = tempDir.appendingPathComponent("alpha", isDirectory: true)
            .path(percentEncoded: false)

        XCTAssertEqual(ProjectInspection.capture(registry: registry, projectNamed: "alpha")
            .inspectedName, "alpha")
        XCTAssertEqual(ProjectInspection.capture(registry: registry, projectNamed: "ALPHA")
            .inspectedName, "alpha", "a name is matched case-insensitively")
        XCTAssertEqual(ProjectInspection.capture(registry: registry, projectNamed: path)
            .inspectedName, "alpha")
    }

    /// The refusal this whole path exists for: a name nobody opened comes back
    /// as unknown, with the open ones listed — never as a confident inspection
    /// of the nearest match.
    func testAnUnknownNameIsRefusedAndTheOpenProjectsAreNamed() throws {
        try openProject(named: "alpha", items: [("a1", .ready)])
        try openProject(named: "beta", items: [("b1", .ready)])

        let outcome = ProjectInspection.capture(registry: registry, projectNamed: "alfa")

        XCTAssertNil(outcome.inspection)
        XCTAssertNil(outcome.inspectedName)
        let refusal = try XCTUnwrap(outcome.refusal)
        XCTAssertTrue(refusal.contains("alfa"), refusal)
        XCTAssertTrue(refusal.contains("isn't an open project"), refusal)
        XCTAssertTrue(refusal.contains("alpha, beta"), refusal)
    }

    func testAPrefixOfAnOpenNameIsStillUnknown() throws {
        try openProject(named: "kiteloop", items: [("a1", .ready)])

        XCTAssertNil(ProjectInspection.capture(registry: registry, projectNamed: "kite").inspection,
                     "no nearest-neighbour match — substituting a project is the failure to avoid")
        XCTAssertNil(ProjectInspection.capture(registry: registry, projectNamed: "").inspection)
    }

    func testAnUnknownNameWithNothingOpenSaysNothingIsOpen() throws {
        let refusal = try XCTUnwrap(
            ProjectInspection.capture(registry: registry, projectNamed: "alpha").refusal
        )

        XCTAssertTrue(refusal.contains("no project is open at all"), refusal)
    }

    // MARK: - Read-only

    /// The same promise the summary makes: inspecting must not file, edit or
    /// start anything.
    func testCapturingLeavesTheProjectUntouched() throws {
        let autopilot = try openProject(named: "alpha", items: [("a1", .ready), ("b1", .blocked)])
        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))
        let before = entry.session.backlogViewModel.backlogFile?.sections.flatMap(\.items) ?? []

        _ = ProjectInspection.capture(registry: registry, projectNamed: "alpha")
        _ = ProjectInspection.capture(registry: registry, projectNamed: "alpha")

        let after = entry.session.backlogViewModel.backlogFile?.sections.flatMap(\.items) ?? []
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.status), before.map(\.status))
        XCTAssertEqual(autopilot.status, .idle, "inspecting must not start a run")
        XCTAssertTrue(autopilot.runQueue.isEmpty)
        XCTAssertEqual(registry.entries.count, 1)
    }

    /// Captured, not cached — an item that moved since the last question shows
    /// up in the next inspection.
    func testCaptureReflectsAStatusChange() throws {
        try openProject(named: "alpha", items: [("a1", .ready)])
        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))

        entry.session.backlogViewModel.backlogFile = backlogFile([("a1", .blocked)])
        let after = try XCTUnwrap(
            ProjectInspection.capture(registry: registry, projectNamed: "alpha").inspection
        )

        XCTAssertNil(after.group(.ready))
        XCTAssertEqual(after.group(.blocked)?.items.map(\.id), ["a1"])
    }

    /// `autopilotReady` means the same thing here as everywhere else — both a
    /// worker and a reviewer.
    func testAutopilotReadyNeedsBothWorkerAndReviewer() throws {
        try openProject(named: "alpha", items: [("a1", .ready)]) { $0.reviewerAgentID = nil }

        XCTAssertEqual(ProjectInspection.capture(registry: registry, projectNamed: "alpha")
            .inspection?.autopilotReady, false)
    }

    // MARK: - Helpers

    private func metricStore(_ records: [TaskMetricRecord]) -> TaskMetricStore {
        let store = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("metrics-\(UUID().uuidString).jsonl"),
            estimatesURL: tempDir.appendingPathComponent("estimates-\(UUID().uuidString).jsonl")
        )
        records.forEach { store.append($0) }
        return store
    }

    private func metric(itemID: String, projectPath: String, outcome: String,
                        quality: Double? = nil, cost: Double = 0.1,
                        completedAt: Date = Date()) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: projectPath, projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
            itemID: itemID, title: itemID.uppercased(), epic: nil, declaredSize: "S",
            startedAt: completedAt, completedAt: completedAt, durationSeconds: 1, costUSD: cost,
            reviewerRetries: 0, outcome: outcome, workerAgent: nil, reviewerAgent: nil,
            executionID: nil
        )
        record.qualityScore = quality
        return record
    }

    private func backlogFile(_ items: [(String, BacklogItemStatus)]) -> BacklogFile {
        BacklogFile(project: "test", repo: nil, verifyDefault: nil, sections: [
            BacklogSection(name: "Epic", items: items.map {
                BacklogItem(id: $0.0, title: $0.0.uppercased(), verify: "true",
                            status: $0.1, type: .local, size: .s)
            })
        ])
    }

    /// Registers a project the way `MainWindow` does — a real session and a real
    /// autopilot — so an inspection is captured off the same registry the
    /// control API reads. No agents are started.
    @discardableResult
    private func openProject(named name: String,
                             items: [(String, BacklogItemStatus)] = [],
                             paused: Bool = false,
                             configure: (BacklogAutopilot) -> Void = { _ in }) throws -> BacklogAutopilot {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = KiteloopProject(rootURL: root)
        try project.ensureDirectoryExists()
        if paused { try project.setPaused(true, goal: nil) }

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: root,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: root),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: ProjectSessionContext(
                runtimeFactory: { MockAgentRuntime() },
                agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
                packageResolver: nil,
                globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()
            )
        )
        session.backlogViewModel.backlogFile = backlogFile(items)
        let autopilot = BacklogAutopilot()
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        configure(autopilot)
        registry.register(session: session, autopilot: autopilot)
        return autopilot
    }
}
