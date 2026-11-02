import XCTest
import KiteloopCore
@testable import Kiteloop

/// The queue reading the Autopilot panel carries above its item list.
///
/// `QueueHealth` was written because a queue full of items that cannot run looks
/// exactly like a healthy one, and until now it was read only on the no-project
/// landing screen — with a project open, which is where anyone actually works,
/// the panel listed the items and said nothing about whether any of them could
/// start. So what is asserted here is that the open project has that reading at
/// all, that it is the *same* derivation the landing screen and
/// `GET /v1/projects` read rather than a second one, and that it moves when the
/// backlog does.
@MainActor
final class BacklogViewModelQueueHealthTests: XCTestCase {
    private var tempDir: URL!
    private var backlogURL: URL!

    /// One groomed and runnable item, one ready item nobody ever groomed, and a
    /// draft — so every count below is load-bearing rather than a pair of zeroes
    /// agreeing with each other.
    private let sampleBacklog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] groomed | Fully groomed | ready | size: S → [detail](backlog/groomed.md)
    - [ ] ungroomed | Never groomed | ready
    - [ ] idea | Just an idea | draft
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-queue-health")
        backlogURL = tempDir.appending(path: "BACKLOG.md")
    }

    // MARK: - The reading exists with a project open

    /// The whole point of the item: opening a project gives you the gap between
    /// how deep the queue is and how much of it could start, not just the depth.
    func testTheOpenProjectCarriesTheQueueReading() throws {
        let vm = try makeViewModel()

        XCTAssertEqual(vm.queueHealth.ready, 2)
        XCTAssertEqual(vm.queueHealth.runnable, 1)
        XCTAssertEqual(vm.queueHealth.startable, 1)
        XCTAssertEqual(vm.queueHealth.drafts, 1)
        XCTAssertEqual(vm.queueHealth.queueSummary, "2 ready, 1 can start — 1 not groomed")
    }

    /// AC: the counts agree with `GET /v1/projects` → `queue.runnable` for the
    /// same project. That endpoint filters the ready items by `DefinitionOfReady`
    /// with `loadDetail` resolving each one — the derivation re-run here item by
    /// item. Two derivations of "runnable" that can drift apart is the failure a
    /// screenshot and a `curl` taken at the same moment would show.
    func testTheReadingAgreesWithTheGateTheControlAPICountsRunnableOff() throws {
        let vm = try makeViewModel()
        let items = try XCTUnwrap(vm.backlogFile?.sections.flatMap(\.items))
        let dependencies = DefinitionOfReady.Dependencies(items: items)

        let runnable = items.filter { $0.status == .ready }.count { item in
            DefinitionOfReady.evaluate(item: item, detail: vm.loadDetail(for: item),
                                       dependencies: dependencies).isReady
        }

        XCTAssertEqual(vm.queueHealth.runnable, runnable)
        XCTAssertEqual(vm.queueHealth.ready, items.count { $0.status == .ready })
    }

    /// A backlog whose every ready item is groomed has nothing to explain, and
    /// says so without a held clause list.
    func testAQueueWithNothingHoldingItNamesNoClauses() throws {
        let vm = try makeViewModel(backlog: """
        ---
        project: demo
        verify_default: swift build
        ---

        # Demo Backlog

        ## Epic: Now

        - [ ] groomed | Fully groomed | ready | size: S → [detail](backlog/groomed.md)
        """)

        XCTAssertTrue(vm.queueHealth.withheld.isEmpty)
        XCTAssertFalse(vm.queueHealth.isStalled)
        XCTAssertEqual(vm.queueHealth.queueSummary, "1 ready, all runnable")
    }

    // MARK: - It moves with the backlog

    /// The panel refreshes with the reload it already performs, so a status
    /// changed in the app moves the line with it — a reading that only caught up
    /// when the file watcher next fired would contradict the list beside it.
    func testAnInAppStatusChangeMovesTheReading() throws {
        let vm = try makeViewModel()
        XCTAssertEqual(vm.queueHealth.ready, 2)

        vm.updateItemStatus(itemID: "ungroomed", newStatus: .done)

        XCTAssertEqual(vm.queueHealth.ready, 1)
        XCTAssertEqual(vm.queueHealth.queueSummary, "1 ready, all runnable")
    }

    /// A project with no backlog at all is not a queue with nothing in it, and
    /// the reading is the shape for the former.
    func testAProjectWithNoBacklogReadsAsTheEmptyQueue() throws {
        let empty = tempDir.appending(path: "no-backlog")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let vm = BacklogViewModel(globalConfigStore: makeConfigStore())

        vm.loadForProject(repoPath: empty.path(percentEncoded: false))

        XCTAssertTrue(vm.noBacklogFound)
        XCTAssertEqual(vm.queueHealth, .empty)
    }

    // MARK: - What the gates recorded

    /// `startable`, not `runnable`, is what the panel states — an item the
    /// grounding check refused at its last pickup is inside the
    /// Definition-of-Ready and still going nowhere.
    func testARecordedRefusalHoldsAnOtherwiseRunnableItem() throws {
        let ledger = GroomingLedger(url: tempDir.appending(path: "grooming.jsonl"))
        let vm = try makeViewModel(ledger: ledger)
        // Recorded only after the detail file exists: `recordedRefusals` reads
        // a refusal older than the groomed detail's last edit as cleared by
        // that regroom, so the order here is the scenario, not an accident.
        ledger.recordCheckFailure(
            itemID: "groomed",
            projectPath: tempDir.path(percentEncoded: false),
            projectName: "demo",
            check: GroomingRecord.Check.grounding,
            reason: "cites Services/Nope.swift, which doesn't exist")
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))

        XCTAssertEqual(vm.queueHealth.runnable, 1, "the gate itself still lets it through")
        XCTAssertEqual(vm.queueHealth.heldAtPickup, 1)
        XCTAssertEqual(vm.queueHealth.startable, 0)
        XCTAssertTrue(vm.queueHealth.isStalled)
        XCTAssertEqual(vm.queueHealth.queueSummary,
                       "2 ready, none can start — 1 not groomed, 1 not grounded")
    }

    /// A refusal recorded against a *different* project's item of the same id
    /// does not hold this one — ids are only unique within a project, and the
    /// ledger is portfolio-wide.
    func testARefusalRecordedForAnotherProjectDoesNotHoldThisOne() throws {
        let ledger = GroomingLedger(url: tempDir.appending(path: "grooming.jsonl"))
        ledger.recordCheckFailure(itemID: "groomed", projectPath: "/somewhere/else",
                                  projectName: "other", check: GroomingRecord.Check.grounding,
                                  reason: "not this project")

        let vm = try makeViewModel(ledger: ledger)

        XCTAssertEqual(vm.queueHealth.heldAtPickup, 0)
        XCTAssertEqual(vm.queueHealth.startable, 1)
    }

    /// Without a ledger the reading still says how much of the queue is groomed;
    /// it just cannot say what a gate last refused. Nothing is invented to fill
    /// the gap — an absent ledger must not read as "nothing refused".
    func testWithoutALedgerTheGroomingHalfIsStillReported() throws {
        let vm = try makeViewModel()

        XCTAssertNil(vm.groomingLedger)
        XCTAssertEqual(vm.queueHealth.runnable, 1)
        XCTAssertEqual(vm.queueHealth.heldAtPickup, 0)
        XCTAssertEqual(vm.queueHealth.withheld.map(\.clause), [.notGroomed])
    }

    // MARK: - Helpers

    private func makeViewModel(backlog: String? = nil,
                               ledger: GroomingLedger? = nil) throws -> BacklogViewModel {
        try (backlog ?? sampleBacklog).write(to: backlogURL, atomically: true, encoding: .utf8)
        try writeDetail(for: "groomed")
        let vm = BacklogViewModel(globalConfigStore: makeConfigStore())
        vm.groomingLedger = ledger
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }

    private func makeConfigStore() -> GlobalConfigStore {
        GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
    }

    /// A `backlog/<id>.md` with What, How and Validation — everything the gate
    /// asks for, so an item that is not runnable is so for the reason the test
    /// states.
    private func writeDetail(for id: String) throws {
        let dir = tempDir.appending(path: "backlog")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        id: \(id)
        title: Fully groomed
        verify:
          - name: build
            cmd: "swift build"
        ---

        ## What

        The outcome.

        ## How

        Touch these files.

        ## Validation

        - [ ] It works

        ## Out of Scope

        - Everything else
        """.write(to: dir.appending(path: "\(id).md"), atomically: true, encoding: .utf8)
    }
}
