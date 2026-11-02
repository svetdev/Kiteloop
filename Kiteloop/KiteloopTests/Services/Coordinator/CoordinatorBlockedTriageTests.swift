import XCTest
import KiteloopCore
@testable import Kiteloop

/// What `CoordinatorBlockedTriage` keys a project **by**.
///
/// The folder name is what a person reads, and it used to be what the retry
/// ledger was keyed by as well. Two open projects whose folders share a name —
/// a client checkout beside an OSS one, or a worktree beside its own repo —
/// are one string under that name and two under their paths, so they shared a
/// lifetime retry ceiling neither of them had spent.
///
/// These are the two halves, asserted together because separating them is the
/// whole change: everything a later pass has to **match** is keyed by the
/// canonical path, and everything a person **reads** still says the folder.
final class CoordinatorBlockedTriageTests: XCTestCase {

    // MARK: - Two projects, one folder name

    /// The ceiling is per project, not per folder name. Before this, the second
    /// project's first retry was refused by a ceiling the first project had spent.
    @MainActor
    func testSameNamedProjectsDoNotShareARetryCeiling() async throws {
        let portfolio = try Portfolio()
        defer { portfolio.tearDown() }
        portfolio.triage.policy.maxLifetimeRetries = 1

        let first = await portfolio.triage.triage(project: portfolio.first.key,
                                                  budget: QueueRefill.Budget(capUSD: 20))
        let second = await portfolio.triage.triage(project: portfolio.second.key,
                                                   budget: QueueRefill.Budget(capUSD: 20))

        XCTAssertEqual(first.plan.verdicts.first?.disposition, .retry)
        XCTAssertEqual(second.plan.verdicts.first?.disposition, .retry,
                       "the second project has retried nothing — the first one's "
                       + "spent ceiling is not its ceiling")
        XCTAssertEqual(portfolio.first.item(Portfolio.itemID)?.status, .ready)
        XCTAssertEqual(portfolio.second.item(Portfolio.itemID)?.status, .ready)

        XCTAssertEqual(portfolio.triage.ledger.retries(project: portfolio.first.key,
                                                       itemID: Portfolio.itemID), 1)
        XCTAssertEqual(portfolio.triage.ledger.retries(project: portfolio.second.key,
                                                       itemID: Portfolio.itemID), 1)
    }

    /// The other half, and the one that says the fix was not "the ceiling stopped
    /// applying": inside one project the count still accumulates and still bites.
    @MainActor
    func testTheCeilingStillBitesWithinOneProject() async throws {
        let portfolio = try Portfolio()
        defer { portfolio.tearDown() }
        portfolio.triage.policy.maxLifetimeRetries = 1

        let first = await portfolio.triage.triage(project: portfolio.first.key,
                                                  budget: QueueRefill.Budget(capUSD: 20))
        XCTAssertEqual(first.plan.verdicts.first?.disposition, .retry)

        // The retry put it back in the queue; the next run blocked it again.
        portfolio.first.block(Portfolio.itemID)
        let second = await portfolio.triage.triage(project: portfolio.first.key,
                                                   budget: QueueRefill.Budget(capUSD: 20))

        XCTAssertEqual(second.plan.verdicts.first?.disposition, .escalate)
        XCTAssertEqual(portfolio.first.item(Portfolio.itemID)?.status, .blocked)
        XCTAssertEqual(second.recovered, 0)
    }

    // MARK: - What a person reads

    /// The folder name is what the plan and both events say. Only the ledger — the
    /// thing a later pass matches on — carries the path.
    @MainActor
    func testThePlanAndTheEventsStillNameTheFolder() async throws {
        let portfolio = try Portfolio()
        defer { portfolio.tearDown() }

        let result = await portfolio.triage.triage(project: portfolio.first.key,
                                                   budget: QueueRefill.Budget(capUSD: 20))

        XCTAssertEqual(result.plan.project, Portfolio.folder)
        XCTAssertTrue(result.plan.summary.hasPrefix("\(Portfolio.folder):"), result.plan.summary)

        let applied = try await portfolio.first.event("a per-item triage event to reach the stream") {
            $0.payload["item"] != nil
        }
        XCTAssertEqual(applied.payload["kind"], "triage-applied")
        XCTAssertEqual(applied.payload["project"], Portfolio.folder)

        let pass = try await portfolio.first.event("the pass event to reach the stream") {
            $0.payload["kind"] == "blocked-triage"
        }
        XCTAssertEqual(pass.payload["project"], Portfolio.folder)

        let recorded = try XCTUnwrap(portfolio.triage.ledger
            .history(project: portfolio.first.key, itemID: Portfolio.itemID).last)
        XCTAssertEqual(recorded.project, portfolio.first.key,
                       "the ledger is the one that has to be matched, so it takes the path")
        XCTAssertEqual(recorded.disposition, "retry")
        XCTAssertTrue(recorded.applied)
    }

    // MARK: - The lines already on disk

    /// The ceiling is a lifetime count, and the lines written before this change
    /// carry a bare folder name. They keep counting, or every already-retried item
    /// in every project was handed a fresh allowance the day this shipped.
    @MainActor
    func testALedgerLineWrittenUnderABareFolderNameStillCountsAgainstTheCeiling() async throws {
        let portfolio = try Portfolio(legacyRetries: 1)
        defer { portfolio.tearDown() }
        portfolio.triage.policy.maxLifetimeRetries = 1

        let result = await portfolio.triage.triage(project: portfolio.first.key,
                                                   budget: QueueRefill.Budget(capUSD: 20))

        XCTAssertEqual(result.plan.verdicts.first?.disposition, .escalate)
        XCTAssertTrue(result.plan.verdicts.first?.reason.contains("retried 1 time(s)") ?? false,
                      result.plan.verdicts.first?.reason ?? "no verdict")
        XCTAssertEqual(portfolio.first.item(Portfolio.itemID)?.status, .blocked)
    }

    /// The reader accepts both spellings of a project, in one direction only: a
    /// legacy bare-name line counts for the project whose folder it names, and a
    /// line recorded under a path is never claimed by a bare name — which is the
    /// ambiguity keying by path removed.
    func testTheLegacyLedgerMatchRunsOneWayOnly() {
        var ledger = BlockedTriage.Ledger()
        ledger.record(project: "kiteloop", itemID: "stuck", disposition: "retry",
                      reason: "written before triage keyed by path", applied: true)
        ledger.record(project: "/Users/x/work/kiteloop", itemID: "stuck", disposition: "retry",
                      reason: "written since", applied: true)

        XCTAssertEqual(ledger.retries(project: "/Users/x/work/kiteloop", itemID: "stuck"), 2,
                       "its own line and the legacy one it can only be")
        XCTAssertEqual(ledger.retries(project: "/Users/x/oss/kiteloop", itemID: "stuck"), 1,
                       "the legacy line only — the other project's path line is not its own")
        XCTAssertEqual(ledger.retries(project: "kiteloop", itemID: "stuck"), 1,
                       "a bare name claims no line written under a path")
        XCTAssertEqual(ledger.history(project: "/Users/x/oss/kiteloop", itemID: "stuck").count, 1,
                       "history reads a project the same way retries does")
    }

    // MARK: - A coverage gap widens the verify before the item goes back

    /// The whole loop, end to end: a run record naming the gap, a map naming the
    /// runnable spelling, and an item whose line **and** detail list come back
    /// running the command — so the next run's diff is covered instead of
    /// refused again.
    @MainActor
    func testACoverageGapWidensTheLineAndTheDetailBeforeReadying() async throws {
        let portfolio = try Portfolio(
            outcome: "blocked:diff touches Kiteloop/Kiteloop/**/*.swift (1 file: A.swift) but verify "
                + "never runs `xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop`")
        defer { portfolio.tearDown() }
        let run = "cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop build-for-testing"
        try portfolio.first.writeVerifyMap(#"""
        {"rules":[{"glob":"Kiteloop/Kiteloop/**/*.swift",
                   "command":"xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop",
                   "run":"\#(run)"}]}
        """#)

        let result = await portfolio.triage.triage(project: portfolio.first.key,
                                                   budget: QueueRefill.Budget(capUSD: 20))

        XCTAssertEqual(result.plan.verdicts.first?.failure, .verifyUncovered)
        let item = try XCTUnwrap(portfolio.first.item(Portfolio.itemID))
        XCTAssertEqual(item.status, .ready)
        XCTAssertEqual(item.verify, "cd \"$(git rev-parse --show-toplevel)\" && " + run,
                       "the line carried no verify of its own, so it is now just the command")
        let detail = try XCTUnwrap(portfolio.first.detail(Portfolio.itemID))
        XCTAssertEqual(detail.verifyCommands.map(\.cmd),
                       ["true", "cd \"$(git rev-parse --show-toplevel)\" && " + run],
                       "the list a run executes gained the command too")
        XCTAssertTrue(detail.notes?.contains("now also runs") == true, detail.notes ?? "no notes")
    }

    // MARK: - The window moves

    /// The defect this file exists to catch: a pile bigger than one pass' bound
    /// used to have the same head read forever, and everything past the bound
    /// was never triaged at all. Two passes over an unchanged pile now read
    /// disjoint windows.
    @MainActor
    func testTwoConsecutivePassesOverAnUnchangedPileTriageDisjointWindows() async throws {
        let pile = try WindowPile(itemCount: 5, maxItemsPerPass: 2)
        defer { pile.tearDown() }

        let first = await pile.triage.triage(project: pile.project.key,
                                             budget: QueueRefill.Budget(capUSD: 20))
        let second = await pile.triage.triage(project: pile.project.key,
                                              budget: QueueRefill.Budget(capUSD: 20))

        let firstIDs = Set(first.plan.verdicts.map(\.itemID))
        let secondIDs = Set(second.plan.verdicts.map(\.itemID))
        XCTAssertEqual(firstIDs.count, 2)
        XCTAssertEqual(secondIDs.count, 2)
        XCTAssertTrue(firstIDs.isDisjoint(with: secondIDs),
                      "the second pass reread the first pass' window: "
                      + "\(firstIDs) vs \(secondIDs)")
        XCTAssertEqual(first.plan.untriaged, 3)
        XCTAssertEqual(second.plan.untriaged, 3)
    }

    /// The other half of the same fact: it is not just that the windows differ,
    /// it is that enough passes cover the whole pile — nothing past the bound
    /// is permanently unreachable any more.
    @MainActor
    func testEnoughPassesReadEveryBlockedItemAtLeastOnce() async throws {
        let pile = try WindowPile(itemCount: 5, maxItemsPerPass: 2)
        defer { pile.tearDown() }

        var seen = Set<String>()
        for _ in 0..<5 {
            let result = await pile.triage.triage(project: pile.project.key,
                                                   budget: QueueRefill.Budget(capUSD: 20))
            seen.formUnion(result.plan.verdicts.map(\.itemID))
        }
        XCTAssertEqual(seen, Set(pile.itemIDs))
    }

    /// A pile at or under the bound is unaffected: read whole on every pass,
    /// exactly as it was before the cursor existed, with nothing left over.
    @MainActor
    func testAPileAtOrUnderTheBoundIsStillReadWholeEveryPass() async throws {
        let pile = try WindowPile(itemCount: 3, maxItemsPerPass: 12)
        defer { pile.tearDown() }

        let first = await pile.triage.triage(project: pile.project.key,
                                             budget: QueueRefill.Budget(capUSD: 20))
        let second = await pile.triage.triage(project: pile.project.key,
                                              budget: QueueRefill.Budget(capUSD: 20))

        XCTAssertEqual(Set(first.plan.verdicts.map(\.itemID)), Set(pile.itemIDs))
        XCTAssertEqual(Set(second.plan.verdicts.map(\.itemID)), Set(pile.itemIDs))
        XCTAssertEqual(first.plan.untriaged, 0)
        XCTAssertEqual(second.plan.untriaged, 0)
    }

    /// The pure windowing rule the pass above relies on, isolated: resuming
    /// after a given id, wrapping at the end, restarting at the head when the
    /// cursor no longer names a blocked item, and leaving a pile that already
    /// fits alone.
    func testWindowResumesAfterTheGivenID() {
        let items = Self.stubItems(0..<5)
        XCTAssertEqual(CoordinatorBlockedTriage.window(over: items, maxItemsPerPass: 2,
                                                       after: "1").map(\.id), ["2", "3"])
    }

    func testWindowWrapsAroundTheEndOfThePile() {
        let items = Self.stubItems(0..<5)
        XCTAssertEqual(CoordinatorBlockedTriage.window(over: items, maxItemsPerPass: 2,
                                                       after: "4").map(\.id), ["0", "1"])
    }

    /// A cursor naming an id that is no longer blocked — recovered, or edited
    /// out of the backlog entirely — restarts at the head instead of reading
    /// nothing, the same as a pile triaged for the first time.
    func testWindowRestartsAtTheHeadWhenTheCursorIDIsNoLongerBlocked() {
        let items = Self.stubItems(0..<5)
        XCTAssertEqual(CoordinatorBlockedTriage.window(over: items, maxItemsPerPass: 2,
                                                       after: "recovered").map(\.id), ["0", "1"])
        XCTAssertEqual(CoordinatorBlockedTriage.window(over: items, maxItemsPerPass: 2,
                                                       after: nil).map(\.id), ["0", "1"])
    }

    func testWindowReturnsTheWholePileWhenItAlreadyFitsTheBound() {
        let items = Self.stubItems(0..<3)
        XCTAssertEqual(CoordinatorBlockedTriage.window(over: items, maxItemsPerPass: 12,
                                                       after: "1").map(\.id), ["0", "1", "2"])
    }

    private static func stubItems(_ ids: Range<Int>) -> [BacklogItem] {
        ids.map { BacklogItem(id: "\($0)", title: "item \($0)", status: .blocked, type: .local) }
    }

    // MARK: - Fixture

    /// Two real projects on disk whose folders share a name, one registry, and the
    /// single `CoordinatorBlockedTriage` the app runs across a whole portfolio —
    /// which is what makes the shared-key defect reachable at all. Everything lives
    /// in a temp directory, so no test reads or writes the developer's own
    /// `~/.kiteloop`.
    @MainActor
    private final class Portfolio {
        /// The folder name both projects answer to, and the item id stuck in both.
        static let folder = "kiteloop"
        static let itemID = "groomed-item"

        let triage: CoordinatorBlockedTriage
        let first: Project
        let second: Project

        private let tempDir: URL
        private let registry: ControlSessionRegistry
        private let metrics: TaskMetricStore

        /// `legacyRetries` seeds the ledger file with applied retries recorded the
        /// old way — under the bare folder name — before triage loads it, which is
        /// the state every existing installation starts this change in.
        private let outcome: String

        init(legacyRetries: Int = 0,
             outcome: String = "blocked:stalled: no progress for 20 min on worker") throws {
            self.outcome = outcome
            tempDir = try TemporaryDirectory.make(prefix: "coordinator-triage")
            registry = ControlSessionRegistry()
            metrics = TaskMetricStore(
                metricsURL: tempDir.appendingPathComponent("metrics.jsonl"),
                estimatesURL: tempDir.appendingPathComponent("estimates.jsonl"),
                approvalsURL: tempDir.appendingPathComponent("approvals.jsonl"))

            // Same folder name, different parents — the whole point.
            first = try Project(root: tempDir.appendingPathComponent("work", isDirectory: true)
                                    .appendingPathComponent(Self.folder, isDirectory: true),
                                supportDir: tempDir, registry: registry)
            second = try Project(root: tempDir.appendingPathComponent("oss", isDirectory: true)
                                     .appendingPathComponent(Self.folder, isDirectory: true),
                                 supportDir: tempDir, registry: registry)

            let ledgerURL = tempDir.appendingPathComponent("triage.jsonl")
            for _ in 0..<legacyRetries {
                BlockedTriage.Ledger.append(
                    BlockedTriage.Ledger.Entry(at: Date(), project: Self.folder,
                                               itemID: Self.itemID, disposition: "retry",
                                               reason: "recorded under the bare folder name",
                                               applied: true),
                    to: ledgerURL)
            }

            triage = CoordinatorBlockedTriage(ledgerURL: ledgerURL)
            triage.configure(registry: registry, metrics: metrics)
            for project in [first, second] { recordBlockedRun(in: project) }
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: tempDir)
        }

        /// Close a project the way `MainWindow` does when its tab goes away.
        func close(_ project: Project) async {
            await registry.unregister(projectID: project.key)
        }

        /// One blocked run on record for the stuck item, long and expensive enough
        /// that it isn't read as the dead-session signature, and stalled — which is
        /// environmental, so the classification asks for a retry and the lifetime
        /// ceiling is what decides whether it gets one.
        private func recordBlockedRun(in project: Project) {
            metrics.append(TaskMetricRecord(
                projectPath: project.key, projectName: project.name,
                itemID: Self.itemID, title: "Fully groomed", epic: nil, declaredSize: "S",
                startedAt: Date(), completedAt: Date(), durationSeconds: 1_500, costUSD: 5,
                reviewerRetries: 0,
                outcome: outcome,
                workerAgent: nil, reviewerAgent: nil, executionID: nil))
        }
    }

    /// One open project: a BACKLOG.md with a groomed blocked item, a session in the
    /// registry, and the event bus that session publishes to.
    @MainActor
    private final class Project {
        /// The canonical path — the registry's own key, and the ledger's.
        let key: String
        let kiteloop: KiteloopProject
        /// The folder, which is what a person reads.
        let name: String

        private let backlog: BacklogViewModel
        private let eventBus: EventBus

        /// `itemIDs` defaults to the single stuck item every existing test reads;
        /// the window tests pass a longer pile to make the bound in
        /// `CoordinatorBlockedTriage.maxItemsPerPass` bite.
        init(root: URL, supportDir: URL, registry: ControlSessionRegistry,
             itemIDs: [String] = [Portfolio.itemID]) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let lines = itemIDs.map {
                "- [ ] \($0) | Fully groomed | blocked | size: S → [detail](backlog/\($0).md)"
            }.joined(separator: "\n")
            try """
            # \(root.lastPathComponent) Backlog

            ## Now

            \(lines)
            """
                .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
            for id in itemIDs {
                let detail = root.appending(path: "backlog/\(id).md")
                try FileManager.default.createDirectory(at: detail.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Self.groomedDetail(id: id).write(to: detail, atomically: true, encoding: .utf8)
            }

            let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false),
                              isDirectory: false)
            let project = KiteloopProject(rootURL: rootURL)
            try project.ensureDirectoryExists()
            key = project.id
            kiteloop = project
            name = rootURL.lastPathComponent

            eventBus = EventBus(eventsURL: project.eventsURL)
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
                        storageURL: supportDir.appendingPathComponent("catalog.json")),
                    packageResolver: nil,
                    globalConfigStore: GlobalConfigStore(
                        storageURL: supportDir.appendingPathComponent("global.json")),
                    orgManifestLoader: OrgManifestLoader(),
                    repoCloneService: RepoCloneService()
                )
            )
            backlog = session.backlogViewModel
            registry.register(session: session, autopilot: BacklogAutopilot())
        }

        func item(_ id: String) -> BacklogItem? { backlog.item(withID: id) }

        func detail(_ id: String) -> BacklogItemDetail? {
            item(id).flatMap(backlog.loadDetail(for:))
        }

        func writeVerifyMap(_ json: String) throws {
            try json.write(to: kiteloop.verifyMapURL, atomically: true, encoding: .utf8)
        }

        /// Put an item back where the next failed run would leave it.
        func block(_ id: String) {
            backlog.updateItemStatus(itemID: id, newStatus: .blocked)
        }

        /// The first matching event, once the orchestrator's detached publish has
        /// reached this project's bus.
        func event(_ what: String,
                   file: StaticString = #filePath, line: UInt = #line,
                   _ matching: @Sendable (KiteloopEvent) -> Bool) async throws -> KiteloopEvent {
            try await eventuallyValue(what, file: file, line: line) {
                await eventBus.recentEvents().last(where: matching)
            }
        }

        /// What the pickup gate reads out of a detail file: What, How, Validation
        /// and a `verify:`. Without it every disposition is withheld as an
        /// escalation and nothing here would ever reach the ledger as a retry.
        private static func groomedDetail(id: String) -> String {
            """
            ---
            id: \(id)
            title: Fully groomed
            size: S
            verify:
              - name: build
                cmd: "true"
            ---

            ## What

            The outcome this item delivers.

            ## How

            Touch these files, follow this pattern.

            ## Validation

            - [ ] The observable behaviour that proves it works

            ## Out of Scope

            - Anything else
            """
        }
    }

    /// One project with a blocked pile of a given size and no metric records at
    /// all — every item classifies as "no blocked run on record" and escalates,
    /// which writes nothing to the backlog. That keeps the pile unchanged across
    /// passes, which is what the windowing tests need: they are asserting which
    /// ids a pass *reads*, not what triage decides to do about them.
    @MainActor
    private final class WindowPile {
        let project: Project
        let triage: CoordinatorBlockedTriage
        let itemIDs: [String]

        // `CoordinatorBlockedTriage.registry` is weak — `Portfolio` keeps its
        // registry alive as a stored property for the same reason this does.
        // Without a strong reference here, the registry a local variable built
        // is deallocated the moment `init` returns and every `triage()` call
        // finds no open project.
        private let registry: ControlSessionRegistry
        private let tempDir: URL

        init(itemCount: Int, maxItemsPerPass: Int) throws {
            itemIDs = (0..<itemCount).map { "item-\($0)" }
            tempDir = try TemporaryDirectory.make(prefix: "coordinator-triage-window")
            registry = ControlSessionRegistry()
            project = try Project(root: tempDir.appendingPathComponent("kiteloop", isDirectory: true),
                                  supportDir: tempDir, registry: registry, itemIDs: itemIDs)
            triage = CoordinatorBlockedTriage(
                ledgerURL: tempDir.appendingPathComponent("triage.jsonl"))
            triage.maxItemsPerPass = maxItemsPerPass
            triage.configure(registry: registry, metrics: nil)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }
}
