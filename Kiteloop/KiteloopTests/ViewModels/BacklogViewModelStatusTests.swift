import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers the status mutations that drive the human gates: `updateItemStatus`,
/// `approve` (→ done) and `reject` (→ ready). Each must change the in-memory
/// model *and* land on disk — the backlog file is the source of truth the next
/// autopilot run reads back.
@MainActor
final class BacklogViewModelStatusTests: XCTestCase {
    private var tempDir: URL!
    private var backlogURL: URL!

    private let sampleBacklog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] task-1 | First task | ready
    - [ ] task-2 | Second task | awaiting-approval

    ## Epic: Later

    - [ ] task-3 | Third task | draft
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-status")
        backlogURL = tempDir.appending(path: "BACKLOG.md")
    }

    // MARK: - updateItemStatus

    func testUpdateItemStatusMutatesModelAndPersists() throws {
        let vm = try makeViewModel()

        vm.updateItemStatus(itemID: "task-1", newStatus: .active)

        XCTAssertEqual(inMemory(vm, "task-1")?.status, .active)
        XCTAssertEqual(try onDisk("task-1")?.status, .active)
    }

    func testUpdateItemStatusFindsItemsInAnySection() throws {
        let vm = try makeViewModel()

        vm.updateItemStatus(itemID: "task-3", newStatus: .inReview)

        XCTAssertEqual(inMemory(vm, "task-3")?.status, .inReview)
        XCTAssertEqual(try onDisk("task-3")?.status, .inReview)
        XCTAssertEqual(try onDisk("task-1")?.status, .ready, "Other items are untouched")
    }

    // MARK: - unblock

    /// Refuses anything that is not blocked, so a stale button cannot move an
    /// item that a run took in the meantime.
    func testUnblockRefusesAnItemThatIsNotBlocked() throws {
        let vm = try makeViewModel()

        XCTAssertFalse(vm.unblock(itemID: "task-1", to: .draft))
        XCTAssertEqual(try onDisk("task-1")?.status, .ready)
    }

    func testUnblockMovesABlockedItemAndPersists() throws {
        let vm = try makeViewModel()
        vm.updateItemStatus(itemID: "task-3", newStatus: .blocked)

        XCTAssertTrue(vm.unblock(itemID: "task-3", to: .ready))

        XCTAssertEqual(inMemory(vm, "task-3")?.status, .ready)
        XCTAssertEqual(try onDisk("task-3")?.status, .ready)
    }

    /// A line written `blocked:<reason>` — how autopilot blocks — must leave
    /// that token behind when the status moves; a reason left on the item made
    /// the serializer fall back to the old line, so nothing changed on disk.
    func testUpdateItemStatusOnABlockedItemWithAReasonLandsOnDisk() throws {
        let vm = try makeViewModel(backlog: backlogWithBlockedReason)

        vm.updateItemStatus(itemID: "task-3", newStatus: .ready)

        let content = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertTrue(content.contains("- [ ] task-3 | Third task | ready"), content)
        XCTAssertFalse(content.contains("blocked:"), content)
        XCTAssertEqual(try onDisk("task-3")?.status, .ready)
        XCTAssertNil(try onDisk("task-3")?.blockedReason)
    }

    func testApproveOnABlockedItemWithAReasonLandsOnDisk() throws {
        let vm = try makeViewModel(backlog: backlogWithBlockedReason)

        vm.approve(itemID: "task-3")

        let content = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertTrue(content.contains("- [x] task-3"), content)
        XCTAssertEqual(try onDisk("task-3")?.status, .done)
        XCTAssertNil(try onDisk("task-3")?.blockedReason)
    }

    func testUpdateItemStatusToBlockedKeepsTheReason() throws {
        let vm = try makeViewModel(backlog: backlogWithBlockedReason)

        vm.updateItemStatus(itemID: "task-3", newStatus: .blocked)

        XCTAssertEqual(try onDisk("task-3")?.status, .blocked)
        XCTAssertEqual(try onDisk("task-3")?.blockedReason, "waiting on creds")
    }

    /// The row menu's Set Status → Ready on a blocked item goes through
    /// `unblock`, which records the old reason in Notes.
    func testUnblockOnABlockedItemWithAReasonRecordsItAndLandsOnDisk() throws {
        let vm = try makeViewModel(backlog: backlogWithBlockedReason.replacingOccurrences(
            of: "task-3 | Third task | blocked:waiting on creds",
            with: "task-3 | Third task | blocked:waiting on creds → [detail](backlog/task-3.md)"))
        let dir = tempDir.appending(path: "backlog")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let detailURL = dir.appending(path: "task-3.md")
        try "## Notes".write(to: detailURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(vm.unblock(itemID: "task-3", to: .ready))

        XCTAssertEqual(try onDisk("task-3")?.status, .ready)
        XCTAssertNil(try onDisk("task-3")?.blockedReason)
        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(detail.contains("- \(today()) — unblocked by hand; was: waiting on creds"), detail)
    }

    private var backlogWithBlockedReason: String {
        sampleBacklog.replacingOccurrences(
            of: "- [ ] task-3 | Third task | draft",
            with: "- [ ] task-3 | Third task | blocked:waiting on creds"
        )
    }

    // MARK: - sendBackToDraft

    func testSendBackToDraftMovesTheItemAndPersists() throws {
        let vm = try makeViewModel()

        XCTAssertTrue(vm.sendBackToDraft(itemID: "task-1", reason: "cites `Nope.swift`, which is in no source file"))

        XCTAssertEqual(inMemory(vm, "task-1")?.status, .draft)
        XCTAssertEqual(try onDisk("task-1")?.status, .draft)
    }

    func testSendBackToDraftRecordsTheReasonInNotes() throws {
        let vm = try makeViewModel(backlog: backlogWithDetailLink)
        let detailURL = try writeDetail(body: "## Notes")

        vm.sendBackToDraft(itemID: "task-2", reason: "cites `Nope.swift`, which is in no source file")

        XCTAssertEqual(inMemory(vm, "task-2")?.status, .draft)
        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(
            detail.contains("- \(today()) — sent back to draft: cites `Nope.swift`, which is in no source file"),
            detail)
    }

    func testSendBackToDraftForUnknownIDLeavesFileUntouched() throws {
        let vm = try makeViewModel()
        let before = try String(contentsOf: backlogURL, encoding: .utf8)

        XCTAssertFalse(vm.sendBackToDraft(itemID: "nope", reason: "whatever"))

        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
    }

    func testUpdateItemStatusToDoneChecksTheBox() throws {
        let vm = try makeViewModel()

        vm.updateItemStatus(itemID: "task-1", newStatus: .done)

        XCTAssertEqual(inMemory(vm, "task-1")?.status, .done)
        let content = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertTrue(content.contains("- [x] task-1"), "Done items serialize as a checked box: \(content)")
    }

    func testUpdateItemStatusKeepsItemInItsSection() throws {
        let vm = try makeViewModel()

        vm.updateItemStatus(itemID: "task-2", newStatus: .ready)

        let file = try parseDisk()
        XCTAssertEqual(file.sections.map(\.name), ["Now", "Later"])
        XCTAssertEqual(file.sections[0].items.map(\.id), ["task-1", "task-2"])
        XCTAssertEqual(file.sections[1].items.map(\.id), ["task-3"])
    }

    func testUpdateItemStatusForUnknownIDLeavesFileUntouched() throws {
        let vm = try makeViewModel()
        let before = try String(contentsOf: backlogURL, encoding: .utf8)

        vm.updateItemStatus(itemID: "nope", newStatus: .active)

        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
        XCTAssertEqual(inMemory(vm, "task-1")?.status, .ready)
    }

    func testUpdateItemStatusIsANoOpWithoutALoadedBacklog() {
        let vm = BacklogViewModel(globalConfigStore: makeConfigStore())

        vm.updateItemStatus(itemID: "task-1", newStatus: .active)

        XCTAssertNil(vm.backlogFile)
    }

    // MARK: - An approval notice is a view of its gate

    /// The gate this project cleared itself, with nobody looking. The row says
    /// so — "auto-approved", not "approved" — because a morning that cannot tell
    /// the two apart is the whole reason the setting records itself.
    func testAutoApprovingAnItemResolvesItsNoticeAndSaysNobodyLooked() async throws {
        let inbox = makeInbox()
        await inbox.add(gateNotice("task-2"))
        let vm = try makeViewModel(notifications: inbox)

        vm.approve(itemID: "task-2", closure: .autoApproved)

        try await eventually("the summons to resolve itself") {
            await inbox.actionablePendingCount() == 0
        }
        let resolved = await inbox.resolved()
        XCTAssertEqual(resolved.first?.resolution, "auto-approved")
    }

    /// Sending an item back for rework closes its gate too — nobody is being
    /// summoned to an item a worker has taken back.
    func testRejectingAtTheGateResolvesItsNotice() async throws {
        let inbox = makeInbox()
        await inbox.add(gateNotice("task-2"))
        let vm = try makeViewModel(notifications: inbox)

        await vm.rejectAtGate(itemID: "task-2", reason: "AC 3 is unimplemented", projectRoot: tempDir)

        try await eventually("the summons to resolve itself") {
            await inbox.actionablePendingCount() == 0
        }
        let resolved = await inbox.resolved()
        XCTAssertEqual(resolved.first?.resolution, "rejected")
    }

    /// One item's gate is not another's: approving `task-2` must leave the
    /// summons about `task-1` exactly where it was.
    func testResolvingOneGateLeavesAnotherItemsSummonsStanding() async throws {
        let inbox = makeInbox()
        await inbox.add(gateNotice("task-1"))
        await inbox.add(gateNotice("task-2"))
        // Both summonses stand on items that are at the gate: loading the
        // backlog resolves a notice whose item is not awaiting approval.
        let vm = try makeViewModel(
            backlog: sampleBacklog.replacingOccurrences(of: "task-1 | First task | ready", with: "task-1 | First task | awaiting-approval"),
            notifications: inbox)

        vm.approve(itemID: "task-2")

        try await eventually("one of the two to resolve") {
            await inbox.actionablePendingCount() == 1
        }
        let pending = await inbox.pending()
        XCTAssertEqual(pending.first?.itemID, "task-1")
    }

    // MARK: - The backfill on load

    /// The 2,000 standing rows clear themselves on the first launch after this
    /// ships: loading a backlog sweeps the notices whose item has left the gate,
    /// and leaves the one still parked there alone.
    func testLoadingABacklogResolvesTheSummonsesWhoseGatesHaveClosed() async throws {
        let inbox = makeInbox()
        await inbox.add(gateNotice("task-1"))     // `ready` in the sample backlog
        await inbox.add(gateNotice("task-2"))     // still `awaiting-approval`
        await inbox.add(gateNotice("long-gone"))  // not in the backlog at all

        _ = try makeViewModel(notifications: inbox)

        try await eventually("the sweep to clear what has passed") {
            await inbox.actionablePendingCount() == 1
        }
        let pending = await inbox.pending()
        XCTAssertEqual(pending.first?.itemID, "task-2")
        let resolved = await inbox.resolved()
        XCTAssertEqual(Set(resolved.map(\.resolution)), ["the item is no longer at the approval gate"])
    }

    /// The sweep runs once. `reload()` fires on every file-watcher wake, and a
    /// second sweep would resolve a summons this launch raised for an item that
    /// reached the gate after the load.
    func testTheSweepDoesNotRunAgainOnAReload() async throws {
        let inbox = makeInbox()
        let vm = try makeViewModel(notifications: inbox)
        try await eventually("the first sweep to finish") { await inbox.pendingCount() == 0 }

        await inbox.add(gateNotice("task-1"))
        vm.reload()

        try await eventually("a reload to leave the new summons alone") {
            await inbox.actionablePendingCount() == 1
        }
    }

    // MARK: - approve

    func testApproveMarksDoneWithMetricsAndPersists() throws {
        let vm = try makeViewModel()

        vm.approve(itemID: "task-2", queries: 7, cost: 1.25)

        let approved = try XCTUnwrap(inMemory(vm, "task-2"))
        XCTAssertEqual(approved.status, .done)
        XCTAssertEqual(approved.queries, 7)
        XCTAssertEqual(approved.cost, 1.25)
        XCTAssertEqual(approved.completedDate, today())

        let persisted = try XCTUnwrap(try onDisk("task-2"))
        XCTAssertEqual(persisted.status, .done)
        XCTAssertEqual(persisted.queries, 7)
        XCTAssertEqual(persisted.cost, 1.25)
        XCTAssertEqual(persisted.completedDate, today())
    }

    func testApproveWithoutMetricsStillStampsCompletion() throws {
        let vm = try makeViewModel()

        vm.approve(itemID: "task-1")

        let persisted = try XCTUnwrap(try onDisk("task-1"))
        XCTAssertEqual(persisted.status, .done)
        XCTAssertNil(persisted.queries)
        XCTAssertNil(persisted.cost)
        XCTAssertEqual(persisted.completedDate, today())
    }

    func testApproveClearsTheAwaitingApprovalBadge() throws {
        let vm = try makeViewModel()
        XCTAssertEqual(vm.awaitingApprovalCount, 1)

        vm.approve(itemID: "task-2", queries: nil, cost: nil)

        XCTAssertEqual(vm.awaitingApprovalCount, 0)
    }

    func testApproveForUnknownIDLeavesFileUntouched() throws {
        let vm = try makeViewModel()
        let before = try String(contentsOf: backlogURL, encoding: .utf8)

        vm.approve(itemID: "nope", queries: 1, cost: 1)

        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
    }

    // MARK: - reject

    func testRejectReturnsItemToReadyAndPersists() throws {
        let vm = try makeViewModel()

        vm.reject(itemID: "task-2", reason: "verify failed")

        XCTAssertEqual(inMemory(vm, "task-2")?.status, .ready)
        XCTAssertEqual(try onDisk("task-2")?.status, .ready)
    }

    func testRejectKeepsTheItemListedRatherThanRemovingIt() throws {
        let vm = try makeViewModel()

        vm.reject(itemID: "task-2", reason: "scope creep")

        let file = try parseDisk()
        XCTAssertEqual(file.sections[0].items.map(\.id), ["task-1", "task-2"])
        XCTAssertEqual(vm.awaitingApprovalCount, 0)
    }

    func testRejectAppendsFeedbackUnderExistingNotesHeading() throws {
        let vm = try makeViewModel(backlog: backlogWithDetailLink)
        let detailURL = try writeDetail(body: """
        ## What

        Something.

        ## Notes
        """)

        vm.reject(itemID: "task-2", reason: "tests missing")

        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(
            detail.contains("- \(today()) — rejected: tests missing"),
            "Rejection feedback should land in the detail file: \(detail)"
        )
        XCTAssertEqual(detail.components(separatedBy: "## Notes").count - 1, 1, "No duplicate Notes heading")
    }

    func testRejectCreatesNotesSectionWhenDetailFileHasNone() throws {
        let vm = try makeViewModel(backlog: backlogWithDetailLink)
        let detailURL = try writeDetail(body: """
        ## What

        Something.
        """)

        vm.reject(itemID: "task-2", reason: "wrong approach")

        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(detail.contains("## Notes"), "Missing Notes heading: \(detail)")
        XCTAssertTrue(detail.contains("- \(today()) — rejected: wrong approach"), detail)
    }

    func testRejectWithBlankReasonStillReturnsItemToReady() throws {
        let vm = try makeViewModel(backlog: backlogWithDetailLink)
        let detailURL = try writeDetail(body: "## Notes")
        let before = try String(contentsOf: detailURL, encoding: .utf8)

        vm.reject(itemID: "task-2", reason: "   ")

        XCTAssertEqual(try onDisk("task-2")?.status, .ready)
        XCTAssertEqual(try String(contentsOf: detailURL, encoding: .utf8), before, "No empty note is appended")
    }

    /// The worse half of a blank rejection: a detail file with no Notes at all
    /// gets the whole heading manufactured for it, so the section a human reads
    /// for "why did this bounce" is created saying nothing.
    func testRejectWithBlankReasonCreatesNoNotesSection() throws {
        let vm = try makeViewModel(backlog: backlogWithDetailLink)
        let detailURL = try writeDetail(body: """
        ## What

        Something.
        """)
        let before = try String(contentsOf: detailURL, encoding: .utf8)

        vm.reject(itemID: "task-2", reason: " \n\t ")

        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertFalse(detail.contains("## Notes"), "Blank rejection invented a Notes heading: \(detail)")
        XCTAssertEqual(detail, before, "The detail file is left untouched")
        XCTAssertEqual(try onDisk("task-2")?.status, .ready)
    }

    /// Trimming the reason must not cost a real one its recording — only the
    /// surrounding whitespace goes.
    func testRejectRecordsAReasonPaddedWithWhitespace() throws {
        let vm = try makeViewModel(backlog: backlogWithDetailLink)
        let detailURL = try writeDetail(body: """
        ## What

        Something.

        ## Notes
        """)

        vm.reject(itemID: "task-2", reason: "  tests missing\n")

        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(
            detail.contains("- \(today()) — rejected: tests missing"),
            "Padded reason should be recorded trimmed: \(detail)"
        )
    }

    // MARK: - rejectAtGate

    /// The gate's own rejection does everything `reject` does — status to
    /// Ready, the reason in Notes — and on top of that records the outstanding
    /// rejection `GateRejection` reads back at the next pickup.
    func testRejectAtGateReturnsItemToReadyAndRecordsTheNoteAndTheLedger() async throws {
        let vm = try makeViewModel(backlog: backlogWithDetailLink)
        let detailURL = try writeDetail(body: "## Notes")

        await vm.rejectAtGate(itemID: "task-2", reason: "the gateCommand mismatch is still there",
                              projectRoot: tempDir)

        XCTAssertEqual(try onDisk("task-2")?.status, .ready)
        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(detail.contains("- \(today()) — rejected: the gateCommand mismatch is still there"), detail)

        let entries = GateRejection.read(from: GateRejection.url(projectPath: tempDir.path(percentEncoded: false)))
        let record = try XCTUnwrap(entries.last)
        XCTAssertEqual(record.itemID, "task-2")
        XCTAssertEqual(record.kind, .rejected)
        XCTAssertEqual(record.reason, "the gateCommand mismatch is still there")
    }

    /// A blank reason records nothing beyond what `reject` itself already
    /// skips — the same leniency `appendRejectionNote` applies to Notes.
    func testRejectAtGateWithBlankReasonRecordsNothingInTheLedger() async throws {
        let vm = try makeViewModel()

        await vm.rejectAtGate(itemID: "task-2", reason: "   ", projectRoot: tempDir)

        XCTAssertEqual(try onDisk("task-2")?.status, .ready)
        let entries = GateRejection.read(from: GateRejection.url(projectPath: tempDir.path(percentEncoded: false)))
        XCTAssertTrue(entries.isEmpty)
    }

    /// `tempDir` here is not a git repository, so there is no branch to tag —
    /// the record still lands, with no ref rather than a refusal.
    func testRejectAtGateRecordsNoRefWithoutAGitRepository() async throws {
        let vm = try makeViewModel()

        await vm.rejectAtGate(itemID: "task-2", reason: "still broken", projectRoot: tempDir)

        let entries = GateRejection.read(from: GateRejection.url(projectPath: tempDir.path(percentEncoded: false)))
        XCTAssertEqual(entries.last?.ref, nil)
    }

    // MARK: - Rejecting with a refused approval's evidence

    /// The reject-with-evidence control's payload: a refusal reason and the tail
    /// of the verify that produced it, handed to the next run as feedback. The
    /// output has to survive the trip into the detail file intact — that is the
    /// only reason to reject rather than retry.
    func testRejectRecordsMultiLineEvidenceInTheDetailFile() throws {
        let vm = try makeViewModel(backlog: backlogWithDetailLink)
        let detailURL = try writeDetail(body: """
        ## What

        Something.

        ## Notes
        """)

        vm.reject(itemID: "task-2", reason: GateRefusalEvidence.feedback(
            reason: "verify failed on merged tree",
            verifyOutput: "Compiling…\nBanner.swift:12: error: cannot find 'foo'\n** BUILD FAILED **"))

        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(detail.contains("- \(today()) — rejected: verify failed on merged tree"), detail)
        XCTAssertTrue(detail.contains("Banner.swift:12: error: cannot find 'foo'"),
                      "the failure itself did not make it into the note:\n\(detail)")
        // Every line after the first is indented, so the fenced block stays
        // inside the list item instead of ending the list at the first newline.
        let noteLines = detail.components(separatedBy: "\n")
        let start = try XCTUnwrap(noteLines.firstIndex { $0.hasPrefix("- \(today()) —") })
        for line in noteLines[(start + 1)...] where !line.isEmpty {
            XCTAssertTrue(line.hasPrefix("  "), "continuation line broke out of the list item: \(line)")
        }
    }

    /// A refusal that never ran a command — a dirty tree, a merge conflict — has
    /// no output, and must not get an empty code fence pretending otherwise.
    func testFeedbackWithoutOutputIsJustTheReason() {
        XCTAssertEqual(
            GateRefusalEvidence.feedback(reason: "working tree not clean (modified): README.md",
                                         verifyOutput: nil),
            "working tree not clean (modified): README.md")
        XCTAssertEqual(GateRefusalEvidence.feedback(reason: "merge conflict", verifyOutput: "  \n "),
                       "merge conflict")
    }

    /// A backlog detail file is read by a human, and the failure is at the end of
    /// the log — so a long capture is cut from the front, saying how much went.
    func testFeedbackKeepsTheEndOfALongOutputAndSaysWhatItDropped() {
        let output = (1...100).map { "line \($0)" }.joined(separator: "\n")

        let feedback = GateRefusalEvidence.feedback(reason: "verify failed on merged tree",
                                                    verifyOutput: output)

        XCTAssertTrue(feedback.contains("line 100"), feedback)
        XCTAssertFalse(feedback.contains("line 1\n"), "kept the start instead of the end:\n\(feedback)")
        XCTAssertTrue(feedback.contains("(60 earlier lines omitted)"), feedback)
        XCTAssertTrue(feedback.contains("```"), "output should be fenced:\n\(feedback)")
    }

    /// Short output is quoted whole — nothing to drop, and no omission notice
    /// implying there was.
    func testShortOutputIsKeptWhole() {
        let kept = GateRefusalEvidence.lastLines(of: "one\ntwo", limit: 40)

        XCTAssertEqual(kept, "one\ntwo")
    }

    func testRejectWithoutDetailFileStillReturnsItemToReady() throws {
        let vm = try makeViewModel()

        vm.reject(itemID: "task-2", reason: "no detail file exists for this item")

        XCTAssertEqual(inMemory(vm, "task-2")?.status, .ready)
        XCTAssertEqual(try onDisk("task-2")?.status, .ready)
    }

    func testRejectForUnknownIDLeavesFileUntouched() throws {
        let vm = try makeViewModel()
        let before = try String(contentsOf: backlogURL, encoding: .utf8)

        vm.reject(itemID: "nope", reason: "whatever")

        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
    }

    // MARK: - Helpers

    private var backlogWithDetailLink: String {
        sampleBacklog.replacingOccurrences(
            of: "- [ ] task-2 | Second task | awaiting-approval",
            with: "- [ ] task-2 | Second task | awaiting-approval → [detail](backlog/task-2.md)"
        )
    }

    // MARK: - Parse issues

    /// The panel can only warn about lines it's told about — an unreadable
    /// checkbox has to reach the view model, not just the log.
    func testParseIssuesAreExposedAfterLoad() throws {
        let vm = try makeViewModel(backlog: sampleBacklog + "\n- [X] task-4 | Typo'd checkbox\n")

        XCTAssertEqual(vm.parseIssues.count, 1)
        XCTAssertEqual(vm.parseIssues.first?.text, "- [X] task-4 | Typo'd checkbox")
        XCTAssertNil(inMemory(vm, "task-4"), "the malformed line is still skipped")
    }

    func testCleanBacklogReportsNoParseIssues() throws {
        let vm = try makeViewModel()

        XCTAssertEqual(vm.parseIssues, [])
    }

    /// Fixing the file clears the banner on the next read.
    func testParseIssuesClearOnReloadOfAFixedFile() throws {
        let vm = try makeViewModel(backlog: sampleBacklog + "\n- [X] task-4 | Typo'd checkbox\n")
        XCTAssertFalse(vm.parseIssues.isEmpty)

        try sampleBacklog.write(to: backlogURL, atomically: true, encoding: .utf8)
        vm.reload()

        XCTAssertEqual(vm.parseIssues, [])
    }

    // MARK: - Approving over work that never reached a branch

    /// The 2026-08-11 state: isolation on, the item's branch never created, and
    /// the project's checkout holding the work loose and uncommitted. Approving
    /// took the "nothing to merge" path and stamped the item **done** over
    /// files nobody had committed. It must not resolve at all.
    func testApprovingAnItemWhoseWorkNeverReachedABranchIsRefused() async throws {
        let vm = try makeViewModel()
        // Committed first, then modified: the refusal reads *tracked*
        // modifications only — an untracked file is ordinary checkout noise and
        // deliberately never refuses (`WorktreeManager.modifiedPaths`).
        try "original".write(to: tempDir.appending(path: "tracked.txt"),
                             atomically: true, encoding: .utf8)
        initGitRepo()
        try "the worker's edits".write(to: tempDir.appending(path: "tracked.txt"),
                                       atomically: true, encoding: .utf8)

        let outcome = await vm.resolveGate(
            itemID: "task-2", approve: true,
            autoMerge: false, verify: .resolve(projectCommand: nil, itemVerify: nil),
            projectRoot: tempDir, isolationExpected: true)

        guard case .workNotOnBranch(let why) = outcome else {
            return XCTFail("expected the approval to be refused, got \(outcome)")
        }
        XCTAssertTrue(why.contains("tracked.txt"), why)
        // Still at the gate, in memory and on disk: refusing has to mean the
        // item is not done, not merely that the caller was told something.
        XCTAssertEqual(inMemory(vm, "task-2")?.status, .awaitingApproval)
        XCTAssertEqual(try onDisk("task-2")?.status, .awaitingApproval)
    }

    /// A clean checkout holds nothing to be wrong about, so the ordinary
    /// "nothing to merge" approval is untouched.
    func testApprovingWithNoBranchAndACleanCheckoutStillResolves() async throws {
        let vm = try makeViewModel()
        initGitRepo()

        let outcome = await vm.resolveGate(
            itemID: "task-2", approve: true,
            autoMerge: false, verify: .resolve(projectCommand: nil, itemVerify: nil),
            projectRoot: tempDir, isolationExpected: true)

        guard case .approvedWithoutMerge = outcome else {
            return XCTFail("expected an ordinary approval, got \(outcome)")
        }
        XCTAssertEqual(try onDisk("task-2")?.status, .done)
    }

    /// With isolation off there is never a branch and the live tree is where
    /// the work is *meant* to be — refusing here would refuse every approval on
    /// every project that does not use worktrees.
    func testALiveTreeProjectApprovesOverItsOwnDirtyCheckout() async throws {
        let vm = try makeViewModel()
        initGitRepo()
        try "the worker's edits".write(to: tempDir.appending(path: "tracked.txt"),
                                       atomically: true, encoding: .utf8)

        let outcome = await vm.resolveGate(
            itemID: "task-2", approve: true,
            autoMerge: false, verify: .resolve(projectCommand: nil, itemVerify: nil),
            projectRoot: tempDir, isolationExpected: false)

        guard case .approvedWithoutMerge = outcome else {
            return XCTFail("expected an ordinary approval, got \(outcome)")
        }
        XCTAssertEqual(try onDisk("task-2")?.status, .done)
    }

    // MARK: - Overriding a blocking finding at the gate

    /// The item's last run was salvaged by its own `verify:` over a review that
    /// never cleared a blocking finding (`lastReviewBlockingFindingClasses`
    /// non-empty). A human approves it anyway — the strongest signal a project
    /// has that this class of finding is not worth blocking on — and that
    /// override lands in the project's ledger, ready for `RunKnowledgeDistiller`
    /// to read back.
    func testApprovingOverABlockingFindingRecordsAnOverride() async throws {
        let vm = try makeViewModel()
        initGitRepo()
        let store = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
            mergesURL: tempDir.appending(path: "task-merges.jsonl"))
        let projectPath = tempDir.path(percentEncoded: false)
        var record = TaskMetricRecord(
            projectPath: projectPath, projectName: "demo", itemID: "task-2", title: "Second task",
            epic: nil, declaredSize: nil, startedAt: Date(), completedAt: Date(), durationSeconds: 60,
            costUSD: 1, reviewerRetries: 2, outcome: "awaiting-approval",
            workerAgent: nil, reviewerAgent: nil, executionID: "exec-1", toolErrors: nil)
        record.lastReviewBlockingFindingClasses = ["blocking: swift missing tests"]
        store.append(record)
        vm.configureMergeOutcomeRecording(store: store, projectPath: projectPath, projectName: "demo")

        let outcome = await vm.resolveGate(
            itemID: "task-2", approve: true,
            autoMerge: false, verify: .resolve(projectCommand: nil, itemVerify: nil),
            projectRoot: tempDir, isolationExpected: true)

        guard case .approvedWithoutMerge = outcome else {
            return XCTFail("expected an ordinary approval, got \(outcome)")
        }
        let overrides = FindingOverrideLedger.read(from: FindingOverrideLedger.url(projectPath: projectPath))
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(overrides.first?.itemID, "task-2")
        XCTAssertEqual(overrides.first?.findingClass, "blocking: swift missing tests")
        XCTAssertNotNil(overrides.first?.at)
    }

    /// An ordinary approval — no run on record with a blocking finding on its
    /// last review — writes nothing. Every approval must not be read as an
    /// override.
    func testApprovingWithNoBlockingFindingOnRecordWritesNoOverride() async throws {
        let vm = try makeViewModel()
        initGitRepo()
        let store = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
            mergesURL: tempDir.appending(path: "task-merges.jsonl"))
        let projectPath = tempDir.path(percentEncoded: false)
        vm.configureMergeOutcomeRecording(store: store, projectPath: projectPath, projectName: "demo")

        let outcome = await vm.resolveGate(
            itemID: "task-2", approve: true,
            autoMerge: false, verify: .resolve(projectCommand: nil, itemVerify: nil),
            projectRoot: tempDir, isolationExpected: true)

        guard case .approvedWithoutMerge = outcome else {
            return XCTFail("expected an ordinary approval, got \(outcome)")
        }
        XCTAssertEqual(FindingOverrideLedger.read(from: FindingOverrideLedger.url(projectPath: projectPath)), [])
    }

    // MARK: - Ledger rows written under another spelling of this project's path

    /// The ledger carries the path the run recorded, which may end in a slash
    /// where the project was configured without one. Both name the same folder,
    /// so the item's newest merge is still the item's newest merge.
    func testLastMergeEventMatchesARowRecordedUnderASlashedPath() throws {
        let vm = try makeViewModel()
        let store = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
            mergesURL: tempDir.appending(path: "task-merges.jsonl"))
        let slashed = tempDir.path(percentEncoded: false) + "/"
        store.appendMergeEvent(ItemMergeEvent(
            projectPath: slashed, projectName: "demo", itemID: "task-2",
            merged: true, at: Date(), executionID: "exec-1"))
        vm.configureMergeOutcomeRecording(
            store: store, projectPath: KiteloopProject.canonicalPath(slashed), projectName: "demo")

        let event = try XCTUnwrap(vm.lastMergeEvent(for: "task-2"))
        XCTAssertTrue(event.merged)
        XCTAssertEqual(event.executionID, "exec-1")
    }

    /// The same for the run an approval reads its blocking findings off: a row
    /// recorded under the slashed spelling is this item's last run, so the
    /// override is written rather than silently skipped.
    func testApprovingOverABlockingFindingRecordedUnderASlashedPathStillRecordsAnOverride() async throws {
        let vm = try makeViewModel()
        initGitRepo()
        let store = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
            mergesURL: tempDir.appending(path: "task-merges.jsonl"))
        let slashed = tempDir.path(percentEncoded: false) + "/"
        let projectPath = KiteloopProject.canonicalPath(slashed)
        var record = TaskMetricRecord(
            projectPath: slashed, projectName: "demo", itemID: "task-2", title: "Second task",
            epic: nil, declaredSize: nil, startedAt: Date(), completedAt: Date(), durationSeconds: 60,
            costUSD: 1, reviewerRetries: 2, outcome: "awaiting-approval",
            workerAgent: nil, reviewerAgent: nil, executionID: "exec-1", toolErrors: nil)
        record.lastReviewBlockingFindingClasses = ["blocking: swift missing tests"]
        store.append(record)
        vm.configureMergeOutcomeRecording(store: store, projectPath: projectPath, projectName: "demo")

        let outcome = await vm.resolveGate(
            itemID: "task-2", approve: true,
            autoMerge: false, verify: .resolve(projectCommand: nil, itemVerify: nil),
            projectRoot: tempDir, isolationExpected: true)

        guard case .approvedWithoutMerge = outcome else {
            return XCTFail("expected an ordinary approval, got \(outcome)")
        }
        let overrides = FindingOverrideLedger.read(from: FindingOverrideLedger.url(projectPath: projectPath))
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(overrides.first?.findingClass, "blocking: swift missing tests")
    }

    // MARK: - Merge verify output on the ledger and in the item's Notes

    /// The defect this covers: a merged-tree verify failure used to leave only
    /// its reason on the ledger row and nothing at all in the item's Notes —
    /// the merged tree it ran against is a scratch worktree already gone by
    /// the time either is read. Now both carry the tail of what it printed,
    /// and which attempt printed it.
    func testAFailedMergeRecordsTheVerifyOutputOnTheLedgerAndInNotes() async throws {
        let vm = try makeViewModel(backlog: backlogWithDetailLink)
        let detailURL = try writeDetail(body: """
        ## What

        Something.

        ## Notes
        """)
        initGitRepo()
        createUnmergedBranch(named: "kiteloop/task-2")

        let store = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
            mergesURL: tempDir.appending(path: "task-merges.jsonl"))
        let projectPath = tempDir.path(percentEncoded: false)
        vm.configureMergeOutcomeRecording(store: store, projectPath: projectPath, projectName: "demo")

        let outcome = await vm.resolveGate(
            itemID: "task-2", approve: true, autoMerge: true,
            verify: .resolve(projectCommand: nil, itemVerify: "echo BOOM-not-compiling && false"),
            projectRoot: tempDir, isolationExpected: true)

        guard case .mergeFailed = outcome else {
            return XCTFail("expected the merge to be refused, got \(outcome)")
        }
        let recordedOutput = store.mergeEvents.last { $0.itemID == "task-2" }?.verifyOutput
        XCTAssertTrue(recordedOutput?.contains("BOOM-not-compiling") == true,
                      "the ledger row kept no output: \(recordedOutput ?? "nil")")
        XCTAssertTrue(recordedOutput?.contains("attempt 1 of 1") == true, recordedOutput ?? "nil")

        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(detail.contains("BOOM-not-compiling"), "the item's Notes kept no output:\n\(detail)")
    }

    /// A passing merge writes no verify output to the ledger or the Notes —
    /// no step ever needed a retry, so there is nothing to keep. The one
    /// Notes line it does write is the landing itself.
    func testAPassingMergeRecordsNoVerifyOutput() async throws {
        let vm = try makeViewModel(backlog: backlogWithDetailLink)
        let detailURL = try writeDetail(body: """
        ## What

        Something.

        ## Notes
        """)
        initGitRepo()
        createUnmergedBranch(named: "kiteloop/task-2")

        let store = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
            mergesURL: tempDir.appending(path: "task-merges.jsonl"))
        let projectPath = tempDir.path(percentEncoded: false)
        vm.configureMergeOutcomeRecording(store: store, projectPath: projectPath, projectName: "demo")

        let outcome = await vm.resolveGate(
            itemID: "task-2", approve: true, autoMerge: true,
            verify: .resolve(projectCommand: nil, itemVerify: "true"),
            projectRoot: tempDir, isolationExpected: true)

        guard case .approvedAndMerged = outcome else {
            return XCTFail("expected the merge to land, got \(outcome)")
        }
        XCTAssertNil(store.mergeEvents.last { $0.itemID == "task-2" }?.verifyOutput)
        let detail = try String(contentsOf: detailURL, encoding: .utf8)
        let notes = detail.components(separatedBy: "\n- ").dropFirst()
        XCTAssertEqual(notes.count, 1, "a clean merge writes the landing and nothing else:\n\(detail)")
        XCTAssertTrue(notes.first?.contains("Landed: merged as") == true, detail)
    }

    // MARK: - The merge gate's deadline is the caller's to set

    /// `resolveGate`'s `timeout` reaches the merge-verify step it gates: a
    /// project that raises it past a step's own running time gets a merge, not
    /// a refusal — the setting this item exists to make reachable.
    func testResolveGateTimeoutLongEnoughLetsASlowVerifyPass() async throws {
        let vm = try makeViewModel()
        initGitRepo()
        createUnmergedBranch(named: "kiteloop/task-2")

        let outcome = await vm.resolveGate(
            itemID: "task-2", approve: true, autoMerge: true,
            verify: .resolve(projectCommand: nil, itemVerify: "sleep 2"),
            projectRoot: tempDir, isolationExpected: true, timeout: 30)

        guard case .approvedAndMerged = outcome else {
            return XCTFail("expected the merge to land, got \(outcome)")
        }
    }

    /// The same slow step, with the deadline tighter than it needs: killed at
    /// the deadline and refused, naming the deadline actually configured — not
    /// a literal 900, which the setting stopped being.
    func testResolveGateTimeoutTooShortRefusesNamingItsOwnDeadline() async throws {
        let vm = try makeViewModel()
        initGitRepo()
        createUnmergedBranch(named: "kiteloop/task-2")

        let outcome = await vm.resolveGate(
            itemID: "task-2", approve: true, autoMerge: true,
            verify: .resolve(projectCommand: nil, itemVerify: "sleep 5"),
            projectRoot: tempDir, isolationExpected: true, timeout: 1)

        guard case .mergeFailed(let why, _) = outcome else {
            return XCTFail("expected the merge to be refused, got \(outcome)")
        }
        XCTAssertEqual(why, "verify timed out after 1s on merged tree (item verify: sleep 5)")
    }

    /// Checks out `branch` off the current tip, adds one commit nothing else
    /// has, and returns to whatever was checked out before — the shape
    /// `resolveGate`'s `hasUnmergedCommits` check needs to find work to merge.
    private func createUnmergedBranch(named branch: String) {
        for args in [["checkout", "-b", branch], ["commit", "--allow-empty", "-m", "item work"],
                     ["checkout", "-"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = tempDir
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// Makes `tempDir` a git repository with everything in it committed, so the
    /// only dirt a case sees is the dirt it wrote itself.
    private func initGitRepo() {
        for args in [["init"], ["config", "user.email", "test@test.com"],
                     ["config", "user.name", "Test"], ["add", "."], ["commit", "-m", "init"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = tempDir
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }

    private func makeConfigStore() -> GlobalConfigStore {
        GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
    }

    private func makeViewModel(backlog: String? = nil,
                               notifications: NotificationStore? = nil) throws -> BacklogViewModel {
        try (backlog ?? sampleBacklog).write(to: backlogURL, atomically: true, encoding: .utf8)
        let vm = BacklogViewModel(globalConfigStore: makeConfigStore(), notifications: notifications)
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }

    /// An inbox over a file of this test's own, so a case can read back what the
    /// gate did to it.
    private func makeInbox(_ name: String = "notifications") -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "\(name).log"))
    }

    /// The summons a run raises when an item reaches the gate.
    private func gateNotice(_ itemID: String) -> NotificationItem {
        NotificationItem(agentID: "worker", type: .approval, title: "Approval needed in demo",
                         body: "\(itemID) — needs sign-off", itemID: itemID)
    }

    /// Writes `backlog/task-2.md` next to the backlog file, matching the
    /// detail link in `backlogWithDetailLink`.
    private func writeDetail(body: String) throws -> URL {
        let dir = tempDir.appending(path: "backlog")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "task-2.md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func inMemory(_ vm: BacklogViewModel, _ id: String) -> BacklogItem? {
        vm.backlogFile?.sections.flatMap(\.items).first { $0.id == id }
    }

    private func parseDisk() throws -> BacklogFile {
        BacklogParser.parse(try String(contentsOf: backlogURL, encoding: .utf8))
    }

    private func onDisk(_ id: String) throws -> BacklogItem? {
        try parseDisk().sections.flatMap(\.items).first { $0.id == id }
    }

    private func today() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }
}

/// Where a note actually lands in the detail file.
///
/// `appendNote` used to find its section with an unanchored substring search for
/// `"## Notes"`, so a heading that merely *starts* with those characters — or a
/// mention of them in prose — swallowed the entry. `BacklogParser` splits on
/// lines beginning `## ` and matches the section name exactly, so the write went
/// somewhere the reader never looks: `loadDetail(for:)` came back without the
/// line just written, and `RetryCeiling.needsNote(existingNotes:)` duly wrote the
/// same retirement note again at the next pickup. These pin the write to the
/// heading the parser reads back.
@MainActor
final class BacklogViewModelNotesHeadingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-notes-heading")
    }

    /// The heading that started the bug: it is not a Notes section, so it keeps
    /// its own text and the entry goes into a real one.
    func testAHeadingThatMerelyStartsWithNotesIsNotTheNotesSection() throws {
        let vm = try loadProject(detail: """
        ## What

        Serve the control API's own spec.

        ## Notes for the reviewer

        The OpenAPI document is generated, not hand-written.
        """)

        vm.appendNote(itemID: "control-openapi", "blocked (review did not pass)")

        let content = try detailContents()
        XCTAssertTrue(content.contains("## Notes for the reviewer\n\nThe OpenAPI document is generated, not hand-written."),
                      "the reviewer's heading was spliced into: \(content)")
        let notes = try XCTUnwrap(vm.loadDetail(for: try item(vm))?.notes,
                                  "no Notes section the parser reads back: \(content)")
        XCTAssertTrue(notes.contains("- \(today()) — blocked (review did not pass)"), notes)
    }

    /// `## Notes` written inside an earlier section — prose about the section, or
    /// a fenced example of one — is not a heading, and must not take the entry
    /// from the real section below it.
    func testNotesMentionedInProseDoesNotTakeTheEntry() throws {
        let vm = try loadProject(detail: """
        ## How

        A passing review writes its advisory findings to the item's `## Notes`.

        ## Notes

        - 2026-08-08 — rejected: tests missing
        """)

        vm.appendNote(itemID: "control-openapi", "retired: 3 attempts in a row produced no work")

        let content = try detailContents()
        XCTAssertTrue(content.contains("A passing review writes its advisory findings to the item's `## Notes`.\n\n## Notes"),
                      "the prose line was written into: \(content)")
        let notes = try XCTUnwrap(vm.loadDetail(for: try item(vm))?.notes, content)
        XCTAssertTrue(notes.contains("- \(today()) — retired: 3 attempts in a row produced no work"), notes)
        XCTAssertTrue(notes.contains("- 2026-08-08 — rejected: tests missing"),
                      "the entry that was already there is gone: \(notes)")
    }

    /// The ordinary case, unchanged: newest-first, directly under the heading.
    func testAPlainNotesSectionStillTakesEntriesNewestFirst() throws {
        let vm = try loadProject(detail: """
        ## Notes

        - 2026-08-08 — rejected: tests missing
        """)

        vm.appendNote(itemID: "control-openapi", "blocked (verify failed)")

        let notes = try XCTUnwrap(vm.loadDetail(for: try item(vm))?.notes)
        XCTAssertEqual(notes, """
        - \(today()) — blocked (verify failed)

        - 2026-08-08 — rejected: tests missing
        """)
        XCTAssertEqual(try detailContents().components(separatedBy: "## Notes").count - 1, 1,
                       "a second Notes heading was invented")
    }

    /// A file with no Notes section at all still gets one, at the end.
    func testAFileWithNoNotesSectionGetsOneAppended() throws {
        let vm = try loadProject(detail: """
        ## What

        Serve the control API's own spec.
        """)

        vm.appendNote(itemID: "control-openapi", "blocked (verify failed)")

        let content = try detailContents()
        XCTAssertTrue(content.hasSuffix("## Notes\n\n- \(today()) — blocked (verify failed)\n"),
                      "the section should be appended at the end: \(content)")
        let notes = try XCTUnwrap(vm.loadDetail(for: try item(vm))?.notes)
        XCTAssertEqual(notes, "- \(today()) — blocked (verify failed)")
    }

    // MARK: - Fixtures

    private var detailURL: URL {
        tempDir.appending(path: "kiteloop/backlog/control-openapi.md")
    }

    private func detailContents() throws -> String {
        try String(contentsOf: detailURL, encoding: .utf8)
    }

    private func loadProject(detail: String) throws -> BacklogViewModel {
        let repo = tempDir.appending(path: "kiteloop")
        try FileManager.default.createDirectory(at: repo.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        try """
        ---
        project: kiteloop
        verify_default: swift build
        ---

        # Kiteloop Backlog

        ## Epic: Now

        - [ ] control-openapi | Publish an OpenAPI spec | ready → [detail](backlog/control-openapi.md)
        """.write(to: repo.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        try detail.write(to: detailURL, atomically: true, encoding: .utf8)

        let store = GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        let vm = BacklogViewModel(globalConfigStore: store)
        vm.loadForProject(repoPath: repo.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }

    private func item(_ vm: BacklogViewModel) throws -> BacklogItem {
        try XCTUnwrap(vm.backlogFile?.sections.flatMap(\.items).first { $0.id == "control-openapi" })
    }

    private func today() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }
}

/// What happens when the note does not reach the detail file.
///
/// `## Notes` is what a rejection reason, a retirement note and a "returned to
/// ready" explanation are written into, and it is what the next worker run is
/// handed as context — but the read and the write were a `try?` apiece, so a note
/// nobody could write read exactly like a run that had nothing to say. These pin
/// the report each failure now files, and that the two states which are not
/// failures stay silent.
@MainActor
final class BacklogViewModelNoteFailureTests: XCTestCase {
    private var tempDir: URL!

    private var repoURL: URL { tempDir.appending(path: "kiteloop") }
    private var backlogDirURL: URL { repoURL.appending(path: "backlog") }
    private var detailURL: URL { backlogDirURL.appending(path: "control-openapi.md") }
    private var detailPath: String { detailURL.path(percentEncoded: false) }

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-note-failure")
        try FileManager.default.createDirectory(at: backlogDirURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A case that made the directory read-only has to hand it back, or the
        // tree it sits in cannot be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: backlogDirURL.path(percentEncoded: false))
    }

    /// A detail file in a directory nothing can write to: the read succeeds and
    /// the rename cannot happen, which is the ordinary shape of a note that is
    /// lost.
    func testAWriteThatFailsIsReportedNamingTheDetailFile() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let vm = try loadProject(detail: "## Notes\n", reporter: reporter)
        try makeBacklogDirectoryReadOnly()

        let wrote = vm.appendNote(itemID: "control-openapi", "rejected: AC 3 is unimplemented")
        await reporter.drain()

        XCTAssertFalse(wrote)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not write Item notes")
        XCTAssertEqual(pending.first?.body.contains(detailPath), true,
                       "the row does not name the file: \(pending.first?.body ?? "")")
    }

    func testAWriteThatFailsWritesADiagnosticsLine() async throws {
        let reporter = StoreProblemReporter(notifications: makeInbox())
        let vm = try loadProject(detail: "## Notes\n", reporter: reporter)
        try makeBacklogDirectoryReadOnly()

        vm.appendNote(itemID: "control-openapi", "rejected: AC 3 is unimplemented")
        await reporter.drain()

        let lines = KiteloopFileLogger.shared.snapshot()
            .filter { $0.category == StoreProblemReporter.logCategory && $0.message.contains(detailPath) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.levelTag, "ERROR")
        XCTAssertEqual(lines.first?.message.contains("could not write"), true, lines.first?.message ?? "")
    }

    /// A detail file that cannot be read — a directory standing where it belongs
    /// — is reported for the read, and nothing is written in its place: what
    /// could not be read is as easily lost by writing over it.
    func testAReadThatFailsIsReportedAndWritesNothingInItsPlace() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let vm = try loadProject(detail: nil, reporter: reporter)
        try FileManager.default.createDirectory(at: detailURL, withIntermediateDirectories: true)

        let wrote = vm.appendNote(itemID: "control-openapi", "retired: 3 attempts produced no work")
        await reporter.drain()

        XCTAssertFalse(wrote)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not read Item notes")
        XCTAssertEqual(pending.first?.body.contains(detailPath), true,
                       "the row does not name the file: \(pending.first?.body ?? "")")

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: detailPath, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "a file was written where the unreadable one was")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: detailPath), [])
    }

    /// An item that names no detail file has nowhere to write and nothing to
    /// report — a legitimate state, not a failure of this file.
    func testAnItemWithNoDetailFileWritesNothingAndReportsNothing() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let vm = try loadProject(detail: nil, linked: false, reporter: reporter)

        let wrote = vm.appendNote(itemID: "control-openapi", "blocked (verify failed)")
        await reporter.drain()

        XCTAssertFalse(wrote)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backlogDirURL.path(percentEncoded: false)), [],
                       "a detail file was created for an item that has none")
    }

    /// The ordinary case, unchanged: the entry lands under the heading and
    /// nothing is reported.
    func testANoteThatLandsReportsNothing() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let vm = try loadProject(detail: """
        ## Notes

        - 2026-08-08 — rejected: tests missing
        """, reporter: reporter)

        let wrote = vm.appendNote(itemID: "control-openapi", "blocked (verify failed)")
        await reporter.drain()

        XCTAssertTrue(wrote)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
        let item = try XCTUnwrap(vm.backlogFile?.sections.flatMap(\.items).first { $0.id == "control-openapi" })
        let notes = try XCTUnwrap(vm.loadDetail(for: item)?.notes)
        XCTAssertEqual(notes, """
        - \(today()) — blocked (verify failed)

        - 2026-08-08 — rejected: tests missing
        """)
    }

    // MARK: - Fixtures

    private func makeInbox() -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "inbox.log"))
    }

    private func makeBacklogDirectoryReadOnly() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: backlogDirURL.path(percentEncoded: false))
    }

    /// A project whose one item links `backlog/control-openapi.md`. `detail` nil
    /// leaves that file uncreated, so a case can put something else there;
    /// `linked` false drops the link, which is the item with no detail file.
    private func loadProject(detail: String?,
                             linked: Bool = true,
                             reporter: StoreProblemReporter) throws -> BacklogViewModel {
        let link = linked ? " → [detail](backlog/control-openapi.md)" : ""
        try """
        ---
        project: kiteloop
        verify_default: swift build
        ---

        # Kiteloop Backlog

        ## Epic: Now

        - [ ] control-openapi | Publish an OpenAPI spec | ready\(link)
        """.write(to: repoURL.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        if let detail {
            try detail.write(to: detailURL, atomically: true, encoding: .utf8)
        }

        let store = GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        let vm = BacklogViewModel(globalConfigStore: store, reporter: reporter)
        vm.loadForProject(repoPath: repoURL.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }

    private func today() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }
}
