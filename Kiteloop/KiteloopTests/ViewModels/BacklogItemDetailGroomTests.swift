import XCTest
import KiteloopCore
@testable import Kiteloop

/// Groom on a draft's page, then Apply: what the approval writes.
///
/// A groom pass only proposes; `applyGroom()` is the human's approval, and it
/// writes the detail file, the line's `verify:` and its size — never the title
/// or the status. A draft a grooming pass already parked keeps the `## Notes`
/// saying which gate parked it, and a write that does not land says so rather
/// than claiming the item groomed. Driven through `groom()` with a scripted
/// one-shot, so the proposal applied is one the page could really show.
@MainActor
final class BacklogItemDetailGroomTests: XCTestCase {

    private var tempDir: URL!

    private let sampleBacklog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] task-1 | First task | draft
    - [ ] task-2 | Second task | draft → [detail](backlog/task-2.md)
    """

    /// Every path it cites is `BACKLOG.md`, which the fixture has, so the
    /// proposal clears the grounding check.
    private let proposal = """
    {"items":[{"id":"ignored","title":"Ignored","size":"s","verify":"/bin/echo groomed",
     "what":"The `BACKLOG.md` file gains a summary line.",
     "how":"Read `BACKLOG.md` and write the line above the first section.",
     "validation":["The summary line is there"],
     "outOfScope":["Changing the item syntax"]}]}
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "item-detail-groom")
    }

    /// A draft groomed for the first time gets a detail file, linked from its
    /// line, holding the proposal — plus the proposal's `verify:` and size.
    func testApplyingAFirstGroomingFilesTheDetailAndTheLine() async throws {
        let backlog = try makeBacklog()
        let model = try await reviewedModel(itemID: "task-1", backlog: backlog)

        model.applyGroom()

        let item = try XCTUnwrap(backlog.item(withID: "task-1"))
        XCTAssertEqual(item.detailPath, "backlog/task-1.md")
        XCTAssertEqual(item.verify, "/bin/echo groomed")
        XCTAssertEqual(item.size, .s)
        XCTAssertEqual(item.title, "First task", "grooming never renames the item")
        XCTAssertEqual(item.status, .draft, "promotion is its own step")
        let detail = try String(contentsOf: tempDir.appending(path: "backlog/task-1.md"), encoding: .utf8)
        XCTAssertTrue(detail.contains("The `BACKLOG.md` file gains a summary line."), detail)
        XCTAssertEqual(model.groomPhase, .idle)
        XCTAssertTrue(model.actionNote?.hasPrefix("Groomed task-1 — ") == true, model.actionNote ?? "nil")
    }

    /// A draft a grooming pass parked keeps the Notes recording why, through
    /// the overwrite of its detail file.
    func testApplyingOverAParkedDraftKeepsItsNotes() async throws {
        let backlog = try makeBacklog()
        let model = try await reviewedModel(itemID: "task-2", backlog: backlog)

        model.applyGroom()

        let detail = try String(contentsOf: tempDir.appending(path: "backlog/task-2.md"), encoding: .utf8)
        XCTAssertTrue(detail.contains("The `BACKLOG.md` file gains a summary line."), detail)
        XCTAssertTrue(detail.contains("Parked by the grounding check"), "the parking note survives: \(detail)")
        XCTAssertEqual(backlog.item(withID: "task-2")?.verify, "/bin/echo groomed")
        XCTAssertTrue(model.actionNote?.hasPrefix("Groomed task-2") == true, model.actionNote ?? "nil")
    }

    /// A detail file that cannot be written leaves the item as it was and says
    /// so — not "Groomed" over a line that never changed.
    func testADetailFileThatCannotBeWrittenSaysTheItemWasNotGroomed() async throws {
        let backlog = try makeBacklog()
        let model = try await reviewedModel(itemID: "task-2", backlog: backlog)
        // A directory where the detail file belongs: the write cannot replace it.
        let detailURL = tempDir.appending(path: "backlog/task-2.md")
        try FileManager.default.removeItem(at: detailURL)
        try FileManager.default.createDirectory(at: detailURL, withIntermediateDirectories: true)
        try "x".write(to: detailURL.appending(path: "occupied"), atomically: true, encoding: .utf8)

        model.applyGroom()

        let note = try XCTUnwrap(model.actionNote)
        XCTAssertTrue(note.hasPrefix("task-2 was not groomed — "), note)
        XCTAssertNotEqual(backlog.item(withID: "task-2")?.verify, "/bin/echo groomed",
                          "nothing on the line changes when the detail file did not land")
    }

    /// A proposed verify holding the line's field separator is refused before
    /// anything is written: the serializer would put the old line back, so
    /// "Groomed" would sit over a verify and size that never changed.
    func testAProposedVerifyHoldingTheFieldSeparatorIsRefusedAndNothingIsWritten() async throws {
        let backlog = try makeBacklog()
        let detailURL = tempDir.appending(path: "backlog/task-2.md")
        let detailBefore = try String(contentsOf: detailURL, encoding: .utf8)
        let lineBefore = try XCTUnwrap(backlog.item(withID: "task-2"))
        let model = try await reviewedModel(
            itemID: "task-2", backlog: backlog,
            proposal: proposal.replacingOccurrences(of: "/bin/echo groomed", with: "ls | wc -l"))

        model.applyGroom()

        let item = try XCTUnwrap(backlog.item(withID: "task-2"))
        XCTAssertEqual(item.verify, lineBefore.verify)
        XCTAssertEqual(item.size, lineBefore.size)
        XCTAssertEqual(try String(contentsOf: detailURL, encoding: .utf8), detailBefore)
        if case .review = model.groomPhase {} else {
            XCTFail("the proposal stays open: \(model.groomPhase)")
        }
        let note = try XCTUnwrap(model.actionNote)
        XCTAssertFalse(note.hasPrefix("Groomed"), note)
        XCTAssertTrue(note.contains("“ | ”"), note)
        XCTAssertTrue(note.contains("field separator"), note)
    }

    /// A blank verify is refused the same way. The groomer's parser already
    /// drops a draft with none, so it is asserted on the check Apply runs.
    func testABlankProposedVerifyIsRefused() throws {
        let refusal = try XCTUnwrap(BacklogItemDetailViewModel.groomVerifyRefusal("   "))
        XCTAssertTrue(refusal.contains("empty"), refusal)
        XCTAssertNil(BacklogItemDetailViewModel.groomVerifyRefusal("ls|wc -l"))
    }

    /// A first grooming whose detail file cannot be created says so, and the
    /// line keeps its verify and size.
    func testAFirstDetailFileThatCannotBeCreatedSaysTheItemWasNotGroomed() async throws {
        let backlog = try makeBacklog()
        let lineBefore = try XCTUnwrap(backlog.item(withID: "task-1"))
        let model = try await reviewedModel(itemID: "task-1", backlog: backlog)
        let detailURL = tempDir.appending(path: "backlog/task-1.md")
        try FileManager.default.createDirectory(at: detailURL, withIntermediateDirectories: true)
        try "x".write(to: detailURL.appending(path: "occupied"), atomically: true, encoding: .utf8)

        model.applyGroom()

        let note = try XCTUnwrap(model.actionNote)
        XCTAssertTrue(note.hasPrefix("task-1 was not groomed — "), note)
        let item = try XCTUnwrap(backlog.item(withID: "task-1"))
        XCTAssertEqual(item.verify, lineBefore.verify)
        XCTAssertEqual(item.size, lineBefore.size)
        XCTAssertNil(item.detailPath)
    }

    // MARK: - Helpers

    private func makeBacklog() throws -> BacklogViewModel {
        try FileManager.default.createDirectory(at: tempDir.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        try "## What\n\nSecond task.\n\n## Notes\n\n- Parked by the grounding check\n"
            .write(to: tempDir.appending(path: "backlog/task-2.md"), atomically: true, encoding: .utf8)
        try sampleBacklog.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let backlog = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        )
        backlog.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        return backlog
    }

    /// The page for `itemID` with a groom pass run and its proposal on screen.
    private func reviewedModel(itemID: String, backlog: BacklogViewModel,
                               proposal: String? = nil) async throws
    -> BacklogItemDetailViewModel {
        let runtime = StubHeadlessRuntime(behavior: .events([
            .assistantText(proposal ?? self.proposal),
            .result(.init(text: "", costUSD: 0, durationMs: 0,
                          inputTokens: 0, outputTokens: 0,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "stub-session", permissionDenials: []))
        ]))
        let globalConfigStore = GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        let orchestrator = Orchestrator(runtime: runtime)
        let autopilot = BacklogAutopilot()
        autopilot.configure(orchestrator: orchestrator, backlogViewModel: backlog,
                            configURL: tempDir.appending(path: "autopilot.json"),
                            projectPath: tempDir.path(percentEncoded: false), projectName: "demo")
        let model = BacklogItemDetailViewModel(
            item: try XCTUnwrap(backlog.item(withID: itemID)),
            projectPath: tempDir.path(percentEncoded: false),
            projectName: "demo",
            isRetired: false,
            backlog: backlog,
            autopilot: autopilot,
            metricIndex: MetricIndex(sources: .standard(in: tempDir)),
            metricStore: TaskMetricStore(
                metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
                estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
                approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
                mergesURL: tempDir.appending(path: "task-merges.jsonl")),
            groomingLedger: GroomingLedger(url: tempDir.appending(path: "grooming.jsonl")),
            runRecords: RunRecordStore(url: tempDir.appending(path: "runs.jsonl")),
            aiEditor: BacklogAIEditor(runtimeFactory: { runtime }, globalConfigStore: globalConfigStore))
        await model.load()
        await model.groom()
        if case .review = model.groomPhase {} else {
            XCTFail("the groom pass should leave a proposal to apply: \(model.groomPhase)")
        }
        retained.append(orchestrator)
        return model
    }

    /// The orchestrators the autopilots were configured with, held for the test.
    private var retained: [Orchestrator] = []
}
