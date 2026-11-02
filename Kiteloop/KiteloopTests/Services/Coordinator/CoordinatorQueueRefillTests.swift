import XCTest
import KiteloopCore
@testable import Kiteloop

/// The refill loop end to end — the half `QueueRefillTests` deliberately doesn't
/// cover. These drive `runPass` against real `ProjectSession`s over real backlog
/// files on disk, with the model call stubbed, and assert on what ended up in
/// `BACKLOG.md` and `backlog/<id>.md` rather than on what the outcome said.
///
/// The properties worth going this far for are the ones a pure test can't
/// show: an exhausted budget refuses **before** the model is called, and a gap
/// already filled is not filled again on the next pass.
@MainActor
final class CoordinatorQueueRefillTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var ledgerURL: URL!
    /// Held here on purpose: `CoordinatorQueueRefill` keeps the config store
    /// weakly (the app owns it), so a store created inline in a helper would be
    /// gone before the pass ran and every pass would hold.
    private var globalConfigStore: GlobalConfigStore!
    /// Each registered project's bus, so a test can assert on the events a pass
    /// published rather than only on its return value.
    private var eventBuses: [String: EventBus] = [:]
    /// The grooming ledger every pass files into — a temp file, never the app's
    /// own `~/.kiteloop/grooming.jsonl`.
    private var groomingLedger: GroomingLedger!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "queue-refill-loop")
        registry = ControlSessionRegistry()
        ledgerURL = tempDir.appending(path: "ledger.jsonl")
        globalConfigStore = GlobalConfigStore(storageURL: globalConfigURL)
        groomingLedger = GroomingLedger(url: tempDir.appending(path: "grooming.jsonl"))
    }

    /// Where the settings the loop persists actually land, so a test can reopen
    /// them the way a relaunched app would.
    private var globalConfigURL: URL { tempDir.appending(path: "global.json") }

    override func tearDownWithError() throws {
        registry = nil
        globalConfigStore = nil
        groomingLedger = nil
    }

    // MARK: - Drafts the stub returns

    /// Cites `BACKLOG.md`, which every test project has — so it clears the
    /// grounding check and lands as `ready`.
    private let groundedDraft = """
    {"id":"summary-line","title":"Summarise the backlog at the top of the file",
     "size":"S","verify":"/bin/echo ok",
     "what":"The `BACKLOG.md` file gains a one-line summary of its open items.",
     "how":"Read `BACKLOG.md` and emit the counts above the first section.",
     "validation":["The summary line reports the open count"],
     "outOfScope":["Changing the item syntax"]}
    """

    /// Cites a file that is in no repo anywhere — the invention the grounding
    /// check exists to catch, so it must be parked as `draft`.
    private let ungroundedDraft = """
    {"id":"phantom-fix","title":"Repair the phantom service",
     "size":"S","verify":"/bin/echo ok",
     "what":"Fix `Services/NotAFileInThisRepo.swift` so it stops throwing.",
     "how":"Open `Services/NotAFileInThisRepo.swift` and correct the guard.",
     "validation":["It stops throwing"],
     "outOfScope":[]}
    """

    /// Grounded — every path it names is real — but its `verify:` holds the
    /// backlog line's own field separator, which is the one Definition-of-Ready
    /// clause a drafted item can still fail (`Draft.parse` drops anything
    /// missing a What, How, Validation, verify or size before the gate sees it).
    /// So it isolates a self-check refusal from a grounding one.
    private let unreadyDraft = """
    {"id":"spaced-pipe","title":"Print how many open items the backlog holds",
     "size":"S","verify":"/bin/echo ok | /bin/echo done",
     "what":"The `BACKLOG.md` file gains a printed count of its open items.",
     "how":"Read `BACKLOG.md` and print the count.",
     "validation":["The count is printed"],
     "outOfScope":[]}
    """

    /// Both gates at once: a file in no repo anywhere, and a `verify:` the line
    /// would truncate.
    private let doublyRefusedDraft = """
    {"id":"phantom-and-pipe","title":"Repair the phantom reporter",
     "size":"S","verify":"/bin/echo ok | /bin/echo done",
     "what":"Fix `Services/NotAFileInThisRepo.swift` so it stops throwing.",
     "how":"Open `Services/NotAFileInThisRepo.swift` and correct the guard.",
     "validation":["It stops throwing"],
     "outOfScope":[]}
    """

    private func itemsJSON(_ drafts: [String]) -> String {
        "{\"items\":[\(drafts.joined(separator: ","))]}"
    }

    /// A grounded draft — every path it names is real, so it clears both gates —
    /// parameterised on the two things the sequencing tests vary.
    private func draftJSON(id: String, title: String, needs: [String] = []) -> String {
        """
        {"id":"\(id)","title":"\(title)","size":"S","verify":"/bin/echo ok",
         "what":"The `BACKLOG.md` file gains \(title).",
         "how":"Read `BACKLOG.md` and write the line above the first section.",
         "validation":["\(title) is there"],"outOfScope":[],
         "needs":[\(needs.map { "\"\($0)\"" }.joined(separator: ","))]}
        """
    }

    // MARK: - Off, and unwired

    func testDisabledLoopNeitherCallsTheModelNorWrites() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, runtime) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = false

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .disabled)
        XCTAssertTrue(runtime.sentPrompts.isEmpty)
        XCTAssertEqual(openItemIDs(fixture), [])
    }

    func testUnconfiguredLoopHoldsRatherThanFailingOpen() async throws {
        let refill = CoordinatorQueueRefill(
            ledgerURL: ledgerURL,
            blockedTriage: CoordinatorBlockedTriage(
                ledgerURL: tempDir.appending(path: "coordinator-triage.jsonl")))
        refill.enabled = true
        let outcome = await refill.runPass()
        XCTAssertEqual(outcome, .held(.noEligibleProject))
    }

    // MARK: - The switch and the day’s ceiling

    /// The state a fresh install is in. An upgrade must never inherit a loop that
    /// files backlog items, so "nothing stored" has to read as off rather than
    /// as "no preference".
    func testNothingStoredIsOffAndUncapped() throws {
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))

        XCTAssertFalse(refill.enabled)
        XCTAssertNil(refill.budget.capUSD)

        refill.start()
        XCTAssertFalse(refill.isTimerRunning, "an off loop must not even hold a timer")
    }

    /// Switching it on is a choice, not a session setting: the next launch reads
    /// the same file and comes up running.
    func testTheSwitchSurvivesARestart() throws {
        let (first, _) = makeRefill(response: itemsJSON([groundedDraft]))
        first.enabled = true

        // A fresh store over the same file, then a fresh loop — what the app does
        // on relaunch.
        globalConfigStore = GlobalConfigStore(storageURL: globalConfigURL)
        let (second, _) = makeRefill(response: itemsJSON([groundedDraft]))

        XCTAssertTrue(second.enabled)
        second.start()
        XCTAssertTrue(second.isTimerRunning, "a loop stored as on comes back watching")
        second.stop()
    }

    /// Advisory mode retired, but configs written while it existed still carry
    /// its key. They have to load cleanly — and mean nothing: the switch is the
    /// whole choice, so a loop stored as on files gated drafts whatever mode
    /// the old key spells.
    func testAStoredModeKeyLoadsCleanlyAndMeansNothing() async throws {
        try """
        {"coordinatorRefillEnabled": true, "coordinatorRefillMode": "advisory"}
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        globalConfigStore = GlobalConfigStore(storageURL: globalConfigURL)
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))

        XCTAssertTrue(refill.enabled, "the switch loaded from around the retired key")
        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0),
                       "a stored \"advisory\" must not stop the loop filing")
        XCTAssertTrue(openItemIDs(fixture).contains("summary-line"))
    }

    /// The ceiling isn't only remembered — it is the number the pass is refused
    /// against, which is the only thing that makes setting it worth anything.
    func testTheStoredCeilingIsTheOneTheLoopEnforces() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (first, _) = makeRefill(response: itemsJSON([groundedDraft]))
        first.setBudgetLimits(capUSD: 5)

        globalConfigStore = GlobalConfigStore(storageURL: globalConfigURL)
        let (refill, runtime) = makeRefill(response: itemsJSON([groundedDraft]))
        XCTAssertEqual(refill.budget.capUSD, 5)
        refill.enabled = true
        refill.recordSpend(6)

        guard case .held(.budgetExhausted(let reason)) = await refill.runPass() else {
            return XCTFail("a day over the stored ceiling should have been refused")
        }
        XCTAssertTrue(reason.contains("5.00"), reason)
        XCTAssertTrue(runtime.sentPrompts.isEmpty)
        XCTAssertEqual(openItemIDs(fixture), [])
    }

    /// Off has to cost nothing. A timer that stays up and wakes every quarter
    /// hour only to return `.disabled` is the thing this switch exists to avoid.
    func testDisablingStopsTheTimerRatherThanSkippingPasses() throws {
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.start()
        XCTAssertFalse(refill.isTimerRunning)

        refill.enabled = true
        XCTAssertTrue(refill.isTimerRunning, "switching on while started begins watching")

        refill.enabled = false
        XCTAssertFalse(refill.isTimerRunning, "off means no timer, not a timer that refuses")
    }

    // MARK: - The cadence

    /// A new interval takes effect now. The running timer is already asleep for
    /// the old one, so shortening it and waiting the old sleep out — up to a
    /// quarter of an hour — looks exactly like the setting being ignored.
    func testChangingTheIntervalRestartsTheRunningTimer() throws {
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.start()
        refill.enabled = true
        defer { refill.stop() }
        let before = refill.timerGeneration

        refill.checkInterval = 120

        XCTAssertTrue(refill.isTimerRunning)
        XCTAssertGreaterThan(refill.timerGeneration, before)
    }

    /// Setting it to what it already is changes nothing — a driver that writes
    /// its whole config each pass would otherwise keep resetting the countdown
    /// and the loop would never reach a tick.
    func testResendingTheSameIntervalDoesNotRestartTheTimer() throws {
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.start()
        refill.enabled = true
        defer { refill.stop() }
        let unchanged = refill.checkInterval
        let before = refill.timerGeneration

        refill.checkInterval = unchanged

        XCTAssertEqual(refill.timerGeneration, before)
    }

    /// Off stays off. Pacing is not a switch, so setting it on a dormant loop
    /// must not conjure the timer `enabled` deliberately tore down.
    func testChangingTheIntervalWhileOffStartsNoTimer() throws {
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.start()

        refill.checkInterval = 120

        XCTAssertFalse(refill.isTimerRunning)
    }

    // MARK: - The budget refusal

    func testExhaustedBudgetRefusesThePassBeforeTheModelIsCalled() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, runtime) = makeRefill(
            response: itemsJSON([groundedDraft]),
            budget: QueueRefill.Budget(spentUSD: 25, capUSD: 20)
        )
        refill.enabled = true

        let outcome = await refill.runPass()
        guard case .held(.budgetExhausted(let reason)) = outcome else {
            return XCTFail("expected a budget refusal, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("25.00"), reason)
        XCTAssertTrue(runtime.sentPrompts.isEmpty, "exhausted means stop, not draft something cheaper")
        XCTAssertEqual(openItemIDs(fixture), [], "nothing filed on a refused pass")
        XCTAssertEqual(refill.budget.passes, 0, "a refused pass is not a pass")
    }

    func testAPassThatRunsIsChargedAgainstTheDay() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]),
                                     budget: QueueRefill.Budget(maxPasses: 1))
        refill.enabled = true

        _ = await refill.runPass()
        XCTAssertEqual(refill.budget.passes, 1)
        // Which spends the day's only pass — the next one is refused.
        guard case .held(.budgetExhausted) = await refill.runPass() else {
            return XCTFail("the second pass should have been refused")
        }
    }

    /// What the pass *cost* has to reach the budget, not just that it happened.
    /// While the drafter's cost was discarded, `spentUSD` only ever counted
    /// conversation: the day's ceiling bounded chat and nothing the loop did, and
    /// only `maxPasses` stood between a night's grooming and an unbounded spend.
    func testAPassIsChargedWhatItsDrafterCallCost() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]), costUSD: 1.25)
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        XCTAssertEqual(refill.budget.spentUSD, 1.25, accuracy: 0.0001)
        XCTAssertEqual(refill.budget.passes, 1, "the pass counter is unchanged by the charge")
    }

    /// The call happened whatever came back. A drafter that returns prose is
    /// wasted spend, and wasted spend is exactly what a day's ceiling is for.
    func testAPassThatDraftedNothingUsableIsStillCharged() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: "I couldn't find anything worth doing.", costUSD: 0.75)
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .noDrafts(project: "alpha"))
        XCTAssertEqual(refill.budget.spentUSD, 0.75, accuracy: 0.0001)
        XCTAssertEqual(refill.budget.passes, 1)
    }

    /// The whole point of charging it: the cost ceiling now actually stops the
    /// loop, rather than waiting for `maxPasses` to run out.
    func testSpendingPastTheCeilingRefusesTheNextPass() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, runtime) = makeRefill(response: itemsJSON([groundedDraft]), costUSD: 2,
                                           budget: QueueRefill.Budget(capUSD: 0.5))
        refill.enabled = true

        _ = await refill.runPass()
        XCTAssertEqual(runtime.sentPrompts.count, 1)

        guard case .held(.budgetExhausted(let reason)) = await refill.runPass() else {
            return XCTFail("a day already over the ceiling should have been refused")
        }
        XCTAssertTrue(reason.contains("daily grooming budget spent"), reason)
        XCTAssertEqual(runtime.sentPrompts.count, 1, "the second pass must not call the model")
        XCTAssertEqual(refill.budget.passes, 1, "a refused pass is not a pass")
    }

    // MARK: - Filing

    func testAPassFilesAGatedItemAsReadyWithItsDetailFile() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))

        let item = try XCTUnwrap(fixture.backlogFile?.sections.flatMap(\.items).first { $0.id == "summary-line" })
        XCTAssertEqual(item.status, .ready)
        XCTAssertEqual(item.size, .s)
        XCTAssertEqual(item.detailPath, "backlog/summary-line.md")
        XCTAssertEqual(item.verify, "/bin/echo ok")

        // And it is on disk, groomed enough for autopilot to pick it up.
        let detail = try XCTUnwrap(fixture.loadDetail(for: item))
        XCTAssertTrue(DefinitionOfReady.evaluate(item: item, detail: detail).isReady)
        XCTAssertTrue(try backlogContents("alpha").contains("summary-line"))
    }

    func testAnItemThatFailsTheGroundingCheckIsParkedAsDraftWithTheReason() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft, ungroundedDraft]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 1, refused: 0))

        let items = fixture.backlogFile?.sections.flatMap(\.items) ?? []
        XCTAssertEqual(items.first { $0.id == "summary-line" }?.status, .ready)
        let parked = try XCTUnwrap(items.first { $0.id == "phantom-fix" })
        XCTAssertEqual(parked.status, .draft, "an ungrounded item must never be runnable")

        let markdown = try String(contentsOf: URL(fileURLWithPath: detailPath("alpha", "phantom-fix")),
                                  encoding: .utf8)
        XCTAssertTrue(markdown.contains("grounding check failed"), markdown)
        XCTAssertTrue(markdown.contains("NotAFileInThisRepo.swift"), markdown)
    }

    // MARK: - Verify widened by the project's own map

    /// Validation: "A draft whose verify runs neither ... nor ..., filed
    /// against a map holding both against every path, is written to the
    /// backlog line and to its detail file's verify frontmatter with both
    /// commands appended." Both unconditional Swift rules the real
    /// `.kiteloop/verify-map.json` carries — the pair that has cost four
    /// blocked runs — with `groundedDraft`'s `verify: /bin/echo ok` gapping
    /// on both.
    func testADraftGapingOnBothUnconditionalRulesIsWidenedInTheLineAndTheDetail() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        // The grounding check reads a verify command's executable as a claim
        // about the repo, widened or not — real for both, so widening does
        // not itself invent an unrunnable command.
        try writeExecutableFile("quality/bin/check-complexity.sh", inProject: "alpha")
        try writeExecutableFile("quality/bin/check-layering.py", inProject: "alpha")
        try writeVerifyMap(#"""
        {"rules":[{"glob":"**/*.swift","command":"./quality/bin/check-complexity.sh"},
                   {"glob":"**/*.swift","command":"./quality/bin/check-layering.py"}]}
        """#, inProject: "alpha")
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        let item = try XCTUnwrap(fixture.backlogFile?.sections.flatMap(\.items).first { $0.id == "summary-line" })
        let line = item.verify ?? ""
        XCTAssertTrue(line.contains("/bin/echo ok"), line)
        XCTAssertTrue(line.contains("./quality/bin/check-complexity.sh"), line)
        XCTAssertTrue(line.contains("./quality/bin/check-layering.py"), line)

        let detail = try XCTUnwrap(BacklogParser.parseDetail(try detailContents("alpha", "summary-line")))
        let cmd = detail.verifyCommands.first?.cmd ?? ""
        XCTAssertTrue(cmd.contains("./quality/bin/check-complexity.sh"), cmd)
        XCTAssertTrue(cmd.contains("./quality/bin/check-layering.py"), cmd)

        let notes = try XCTUnwrap(detail.notes, "the widening is named, not silent")
        XCTAssertTrue(notes.contains("check-complexity.sh"), notes)
        XCTAssertTrue(notes.contains("check-layering.py"), notes)
    }

    /// Validation: "A draft whose How cites no path under any scoped rule is
    /// filed with exactly the verify it has today." `groundedDraft`'s How
    /// cites only `BACKLOG.md`, nowhere under the rule's tree, so the rule has
    /// nothing to say about it.
    func testADirectoryScopedRuleIsNotAppendedToADraftedVerify() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeVerifyMap(#"""
        {"rules":[{"glob":"Kiteloop/KiteloopTests/**","command":"./quality/bin/check-test-hygiene.py"}]}
        """#, inProject: "alpha")
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        let item = try XCTUnwrap(fixture.backlogFile?.sections.flatMap(\.items).first { $0.id == "summary-line" })
        XCTAssertEqual(item.verify, "/bin/echo ok", "a rule the How cites nothing under must not be guessed onto a draft")

        let detail = try XCTUnwrap(BacklogParser.parseDetail(try detailContents("alpha", "summary-line")))
        XCTAssertNil(detail.notes, "nothing was widened, so nothing is said")
    }

    /// Validation: "A draft whose How cites a file under
    /// `Kiteloop/KiteloopCore/Sources` is filed with
    /// `./scripts/run-core-tests.sh` in its verify; one citing a file under
    /// `Kiteloop/Kiteloop` gets the app build; one citing a file under
    /// `Kiteloop/KiteloopTests` gets the hygiene check" — and "the note names
    /// the cited path and the command it brought in."
    func testAScopedRuleWhoseTreeTheHowCitesIsAppendedToADraftedVerify() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeVerifyMap(#"""
        {"rules":[{"glob":"Kiteloop/KiteloopCore/**","command":"./scripts/run-core-tests.sh"},
                   {"glob":"Kiteloop/Kiteloop/**/*.swift","command":"xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop"},
                   {"glob":"Kiteloop/KiteloopTests/**","command":"./quality/bin/check-test-hygiene.py"}]}
        """#, inProject: "alpha")
        let citingDraft = """
        {"id":"summary-line","title":"Summarise the backlog at the top of the file",
         "size":"S","verify":"/bin/echo ok",
         "what":"The `BACKLOG.md` file gains a one-line summary of its open items.",
         "how":"Change `Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Summary.swift` to build the \
        summary, `Kiteloop/Kiteloop/Views/Backlog/BacklogView.swift` to show it, and cover both in \
        `Kiteloop/KiteloopTests/Views/Backlog/BacklogViewTests.swift`.",
         "validation":["The summary line reports the open count"],
         "outOfScope":["Changing the item syntax"]}
        """
        let (refill, _) = makeRefill(response: itemsJSON([citingDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        let item = try XCTUnwrap(fixture.backlogFile?.sections.flatMap(\.items).first { $0.id == "summary-line" })
        let line = item.verify ?? ""
        XCTAssertTrue(line.contains("./scripts/run-core-tests.sh"), line)
        XCTAssertTrue(line.contains("xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop"), line)
        XCTAssertTrue(line.contains("./quality/bin/check-test-hygiene.py"), line)

        let detail = try XCTUnwrap(BacklogParser.parseDetail(try detailContents("alpha", "summary-line")))
        let notes = try XCTUnwrap(detail.notes, "the widening is named, not silent")
        XCTAssertTrue(notes.contains("Summary.swift") && notes.contains("run-core-tests.sh"), notes)
        XCTAssertTrue(notes.contains("BacklogView.swift") && notes.contains("xcodebuild"), notes)
        XCTAssertTrue(notes.contains("BacklogViewTests.swift") && notes.contains("check-test-hygiene.py"), notes)
    }

    /// Validation: "Replaying the two drafts named in What through the
    /// widening produces verifies the verify-coverage gate would have
    /// accepted." `signal-drafted-id-skips-the-length-cap`'s How named
    /// `Kiteloop/Kiteloop/Services/CoordinatorQueueRefill.swift`, and was
    /// blocked for a verify that never ran the app build its own How already
    /// pointed at (`~/.kiteloop/task-metrics.jsonl`,
    /// 2026-09-05): "blocked:diff touches Kiteloop/Kiteloop/**/*.swift ...
    /// but verify never runs `xcodebuild -project Kiteloop.xcodeproj -scheme
    /// Kiteloop`".
    func testReplayingSignalDraftedIdSkipsTheLengthCapIsWidenedWithTheAppBuild() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeVerifyMap(#"""
        {"rules":[{"glob":"Kiteloop/Kiteloop/**/*.swift",
                    "command":"xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop",
                    "run":"cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination \"platform=macOS\" build-for-testing"}]}
        """#, inProject: "alpha")
        let replayed = """
        {"id":"summary-line","title":"A signal-drafted id has no length cap",
         "size":"S",
         "verify":"cd \\"$(git rev-parse --show-toplevel)\\" && ./scripts/run-core-tests.sh",
         "what":"The `BACKLOG.md` file gains a one-line summary of its open items.",
         "how":"`QueueRefill.Draft.slug` in `Kiteloop/Kiteloop/Services/QueueRefill.swift` ends at 64; \
        widen the skip in `CoordinatorQueueRefill.signalDrafts` (`Kiteloop/Kiteloop/Services/CoordinatorQueueRefill.swift`).",
         "validation":["An id already at or under 64 characters is unchanged"],
         "outOfScope":[]}
        """
        let (refill, _) = makeRefill(response: itemsJSON([replayed]))
        refill.enabled = true

        _ = await refill.runPass()

        let item = try XCTUnwrap(fixture.backlogFile?.sections.flatMap(\.items).first { $0.id == "summary-line" })
        let line = item.verify ?? ""
        XCTAssertTrue(line.contains("build-for-testing"),
                      "the gate that blocked this exact item's How must now be satisfied: \(line)")
    }

    /// Validation: "A draft whose verify already runs a rule's command is
    /// filed with that verify unchanged, with the command appearing once."
    func testADraftAlreadyRunningARulesCommandIsFiledUnchanged() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try writeExecutableFile("quality/bin/check-complexity.sh", inProject: "alpha")
        try writeVerifyMap(#"""
        {"rules":[{"glob":"**/*.swift","command":"./quality/bin/check-complexity.sh"}]}
        """#, inProject: "alpha")
        let alreadyCovering = """
        {"id":"summary-line","title":"Summarise the backlog at the top of the file",
         "size":"S","verify":"/bin/echo ok && ./quality/bin/check-complexity.sh",
         "what":"The `BACKLOG.md` file gains a one-line summary of its open items.",
         "how":"Read `BACKLOG.md` and emit the counts above the first section.",
         "validation":["The summary line reports the open count"],
         "outOfScope":["Changing the item syntax"]}
        """
        let (refill, _) = makeRefill(response: itemsJSON([alreadyCovering]))
        refill.enabled = true

        _ = await refill.runPass()

        let item = try XCTUnwrap(fixture.backlogFile?.sections.flatMap(\.items).first { $0.id == "summary-line" })
        let line = item.verify ?? ""
        XCTAssertEqual(line.components(separatedBy: "check-complexity.sh").count - 1, 1,
                       "the command must appear exactly once: \(line)")

        let detail = try XCTUnwrap(BacklogParser.parseDetail(try detailContents("alpha", "summary-line")))
        XCTAssertNil(detail.notes, "nothing was added, so nothing is said")
    }

    /// Validation: "A project whose verify map file is absent files each
    /// draft's verify exactly as drafted." No `writeVerifyMap` call at all —
    /// `VerifyCoverage.Map.load` reads the absence as `.none`.
    func testAProjectWithNoVerifyMapFilesTheDraftExactlyAsDrafted() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        let item = try XCTUnwrap(fixture.backlogFile?.sections.flatMap(\.items).first { $0.id == "summary-line" })
        XCTAssertEqual(item.verify, "/bin/echo ok")
    }

    private func writeVerifyMap(_ json: String, inProject name: String) throws {
        let url = try XCTUnwrap(registry.entry(forProject: name)?.session.project.verifyMapURL)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A real, executable file at `relativePath` under a fixture project's
    /// root — so a widened verify's command resolves for `GroundingCheck`,
    /// which reads every verify command's executable as a claim about the
    /// repo, widened or not.
    private func writeExecutableFile(_ relativePath: String, inProject name: String) throws {
        let url = tempDir.appending(path: "\(name)/\(relativePath)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path(percentEncoded: false))
    }

    // MARK: - The epic the drafter asked for

    /// The drafter named an epic this backlog has, so nothing was overridden and
    /// there is nothing to say: the line goes under it, the file names it.
    func testADraftNamingAnEpicTheBacklogHasIsFiledUnderItWithNoNote() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0, extraEpics: ["Later"])
        let (refill, _) = makeRefill(response: itemsJSON([epicDraft("Later")]))
        refill.enabled = true

        let outcome = await refill.runPass()
        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))

        let sections = try writtenSections("alpha")
        XCTAssertEqual(sections.first { $0.name == "Later" }?.items.map(\.id), ["summary-line"])

        let detail = try XCTUnwrap(BacklogParser.parseDetail(try detailContents("alpha", "summary-line")))
        XCTAssertEqual(detail.epic, "Later")
        XCTAssertNil(detail.notes, "nothing was overridden, so nothing is said")
    }

    /// The one this exists for: the line lands in the fallback, and both the
    /// file's `epic:` and its Notes say so rather than going on claiming an epic
    /// the backlog hasn't got.
    func testADraftNamingAnEpicTheBacklogLacksSaysWhereItLandedInstead() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([epicDraft("Platform")]))
        refill.enabled = true

        let outcome = await refill.runPass()
        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))

        let sections = try writtenSections("alpha")
        XCTAssertNil(sections.first { $0.name == "Platform" },
                     "the fallback exists so a section per item is never invented")
        XCTAssertEqual(sections.first { $0.name == "Now" }?.items.map(\.id), ["summary-line"])

        let detail = try XCTUnwrap(BacklogParser.parseDetail(try detailContents("alpha", "summary-line")))
        XCTAssertEqual(detail.epic, "Now", "the file names the section the line is actually under")
        let notes = try XCTUnwrap(detail.notes, "a silent override is what this reports")
        XCTAssertTrue(notes.contains("Platform"), notes)
        XCTAssertTrue(notes.contains("Now"), notes)
    }

    /// An unstated epic is not a mistake — the fallback is simply where the item
    /// goes — so it is named in the file and nothing is noted.
    func testADraftWithNoEpicIsFiledUnderTheFallbackWithoutANote() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        let detail = try XCTUnwrap(BacklogParser.parseDetail(try detailContents("alpha", "summary-line")))
        XCTAssertEqual(detail.epic, "Now")
        XCTAssertNil(detail.notes, "a draft that named no epic is not being corrected")
    }

    /// A drafted item is born `later`, whatever the section it is filed under —
    /// an epic named `Now` included — or planner-drafted work would run ahead
    /// of the items a person picked.
    func testADraftFiledUnderAnEpicNamedNowIsBornLater() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([epicDraft("Now")]))
        refill.enabled = true

        let outcome = await refill.runPass()
        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))

        let filed = try XCTUnwrap(try writtenSections("alpha").first { $0.name == "Now" }?
            .items.first { $0.id == "summary-line" })
        XCTAssertEqual(filed.lane, .later)
        let filedContents = try backlogContents("alpha")
        XCTAssertFalse(filedContents.contains("lane:now"), filedContents)
    }

    /// The epic note is written alongside the gates' notes, not instead of them:
    /// an item can be both ungrounded and filed somewhere other than it asked.
    func testAGateRefusalAndTheEpicNoteAreBothWritten() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([ungroundedDraftInAMissingEpic]))
        refill.enabled = true

        let outcome = await refill.runPass()
        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 0, drafts: 1, refused: 0))

        let detail = try XCTUnwrap(BacklogParser.parseDetail(try detailContents("alpha", "phantom-fix")))
        XCTAssertEqual(detail.epic, "Now")
        let notes = try XCTUnwrap(detail.notes)
        XCTAssertTrue(notes.contains("grounding check failed"), notes)
        XCTAssertTrue(notes.contains("Platform"), notes)
    }

    /// The grounded draft above, with the epic the drafter asked for.
    private func epicDraft(_ epic: String) -> String {
        """
        {"id":"summary-line","title":"Summarise the backlog at the top of the file",
         "size":"S","verify":"/bin/echo ok","epic":"\(epic)",
         "what":"The `BACKLOG.md` file gains a one-line summary of its open items.",
         "how":"Read `BACKLOG.md` and emit the counts above the first section.",
         "validation":["The summary line reports the open count"],
         "outOfScope":["Changing the item syntax"]}
        """
    }

    /// Ungrounded *and* naming an epic the backlog hasn't got, so one item
    /// carries a gate refusal and the epic note at once.
    private let ungroundedDraftInAMissingEpic = """
    {"id":"phantom-fix","title":"Repair the phantom service",
     "size":"S","verify":"/bin/echo ok","epic":"Platform",
     "what":"Fix `Services/NotAFileInThisRepo.swift` so it stops throwing.",
     "how":"Open `Services/NotAFileInThisRepo.swift` and correct the guard.",
     "validation":["It stops throwing"],
     "outOfScope":[]}
    """

    /// The sections as they are on disk, re-read rather than taken from the view
    /// model: which section a line landed under is a property of the file.
    private func writtenSections(_ project: String) throws -> [BacklogSection] {
        BacklogParser.parse(try backlogContents(project)).sections
    }

    private func detailContents(_ project: String, _ id: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: detailPath(project, id)), encoding: .utf8)
    }

    // MARK: - What was filed, for the portfolio report

    /// The grooming ledger is the denominator of the report's headline. A refill
    /// pass that files without recording it leaves `filed` at zero for ever, and
    /// merged ÷ filed silently degrades to merged ÷ run.
    func testAFiledDraftIsRecordedInTheGroomingLedger() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        XCTAssertEqual(groomingLedger.records.count, 1, "exactly one record per filing")
        let record = try XCTUnwrap(groomingLedger.records.first)
        XCTAssertEqual(record.itemID, "summary-line")
        XCTAssertEqual(record.event, .filedReady)
        XCTAssertEqual(record.projectName, "alpha")
        XCTAssertEqual(record.projectPath,
                       registry.entry(forProject: "alpha")?.session.project.rootURL
                        .path(percentEncoded: false))
    }

    /// The status that was written decides it. An ungrounded item is parked as
    /// `draft`, and the report has to be able to tell that from a runnable
    /// filing — "filed 2" says nothing until you know how many were groomed.
    func testAParkedItemIsRecordedAsADraftFiling() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft, ungroundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        XCTAssertEqual(groomingLedger.records.count { $0.event == .filedReady }, 1)
        XCTAssertEqual(groomingLedger.records.filter { $0.event == .filedDraft }.map(\.itemID),
                       ["phantom-fix"])
    }

    // MARK: - A draft the backlog wouldn't take

    /// A refused draft used to appear in neither count, so the pass reported a
    /// smaller number than it had groomed with nothing saying why. It is now the
    /// third number, and the summary says it out loud.
    func testABoundedPassReportsTheDraftTheBacklogRefused() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        try blockDetailWrites(inProject: "alpha")
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 0, drafts: 0, refused: 1))
        XCTAssertTrue(outcome.summary.contains("refused 1"), outcome.summary)
        XCTAssertEqual(outcome.kind, "filed")
        // And nothing was written or remembered — a refusal is a filing that
        // didn't happen, not one that happened badly.
        XCTAssertEqual(openItemIDs(fixture), [])
        XCTAssertTrue(groomingLedger.records.isEmpty)
    }

    /// The other half of the same number: a pass that filed everything it
    /// drafted says nothing about refusals, so the count only ever appears when
    /// there is something to report.
    func testAPassThatFiledEverythingReportsNoRefusals() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        XCTAssertFalse(outcome.summary.contains("refused"), outcome.summary)
    }

    /// A regular file where the `backlog/` directory would go, so writing
    /// `backlog/<id>.md` fails on a real filesystem rather than on a stub.
    private func blockDetailWrites(inProject name: String) throws {
        try "not a directory".write(to: tempDir.appending(path: "\(name)/backlog"),
                                    atomically: true, encoding: .utf8)
    }

    // MARK: - Which gate parked it

    /// "Filed 7, 4 as drafts" is a count, not a finding. The refusal is what a
    /// groomer can act on, so the gate's verdict is written down beside the
    /// filing rather than left as prose in the item's Notes.
    func testAParkedDraftRecordsWhichCheckRefusedItAndWhatItSaid() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([unreadyDraft]))
        refill.enabled = true

        let outcome = await refill.runPass()
        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 0, drafts: 1, refused: 0))

        XCTAssertEqual(groomingLedger.records.map(\.event), [.filedDraft, .checkFailed],
                       "the filing still happens, and now says why it was parked")
        let refusal = try XCTUnwrap(groomingLedger.records.last)
        XCTAssertEqual(refusal.itemID, "spaced-pipe")
        XCTAssertEqual(refusal.check, GroomingRecord.Check.definitionOfReady)
        XCTAssertEqual(refusal.projectName, "alpha")
        XCTAssertEqual(refusal.projectPath,
                       registry.entry(forProject: "alpha")?.session.project.rootURL
                        .path(percentEncoded: false))
        XCTAssertTrue(refusal.reason?.contains("field separator") == true,
                      "the verdict verbatim, not that something refused it: \(refusal.reason ?? "nil")")
    }

    func testADraftParkedForAnInventionIsAttributedToTheGroundingCheck() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([ungroundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        let refusal = try XCTUnwrap(groomingLedger.records.first { $0.event == .checkFailed })
        XCTAssertEqual(refusal.itemID, "phantom-fix")
        XCTAssertEqual(refusal.check, GroomingRecord.Check.grounding)
        XCTAssertTrue(refusal.reason?.contains("NotAFileInThisRepo.swift") == true,
                      refusal.reason ?? "nil")
    }

    /// Two refusals are two things to fix, so both are recorded — but the item
    /// was filed once and must be counted once.
    func testADraftThatFailsBothGatesRecordsOnePerCheckAndOneFiling() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([doublyRefusedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        XCTAssertEqual(groomingLedger.records.count { $0.event == .filedDraft }, 1)
        XCTAssertEqual(groomingLedger.records.filter { $0.event == .checkFailed }.map(\.check),
                       [GroomingRecord.Check.definitionOfReady, GroomingRecord.Check.grounding])
    }

    /// A clean draft has nothing to attribute. A check that recorded a passing
    /// verdict would make every filing look half-refused.
    func testADraftThatClearsBothGatesRecordsNoRefusal() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        XCTAssertEqual(groomingLedger.records.map(\.event), [.filedReady])
    }

    /// The whole point: the report can now say what the drafts were parked for,
    /// where before it could only count them.
    func testTheReportCountsAParkedDraftUnderSkippedByCheck() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft, ungroundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        let report = PortfolioReport.make(runs: [], grooming: groomingLedger.records,
                                          period: .last(hours: 24, endingAt: Date()))
        let row = try XCTUnwrap(report.rows.first { $0.projectName == "alpha" })
        XCTAssertEqual(row.filed, 2)
        XCTAssertEqual(row.draft, 1)
        XCTAssertEqual(row.skippedByCheck, 1)
    }

    /// The point of recording any of this: the report's headline is computed on
    /// merged ÷ filed rather than falling back to merged ÷ run.
    func testTheReportReadsTheFilingsOnTheFiledBasis() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        let report = PortfolioReport.make(runs: [], grooming: groomingLedger.records,
                                          period: .last(hours: 24, endingAt: Date()))
        let row = try XCTUnwrap(report.rows.first { $0.projectName == "alpha" })
        XCTAssertEqual(row.filed, 1)
        XCTAssertEqual(row.ready, 1)
        XCTAssertEqual(row.draft, 0)
        XCTAssertEqual(row.mergeRate.basis, .filed)
    }

    // MARK: - A filed needs: id names something

    /// Accepting a candidate can rename it, and the sibling that was told to wait
    /// for it wrote down the id the drafter chose. Following the rename is the
    /// whole point: left alone the id names the *existing* backlog item the
    /// collision was with — a real id, so nothing downstream notices, and the
    /// item is sequenced behind the wrong thing.
    func testASiblingIsFollowedToTheIdARenameGaveIt() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 1)
        let (refill, _) = makeRefill(response: itemsJSON([
            draftJSON(id: "existing-1", title: "Summarise the open items"),
            draftJSON(id: "second-half", title: "Print the summary in the header",
                      needs: ["existing-1"])
        ]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 2, drafts: 0, refused: 0))
        let items = fixture.backlogFile?.sections.flatMap(\.items) ?? []
        XCTAssertNotNil(items.first { $0.id == "existing-1-2" },
                        "the colliding candidate is renamed, as it always was")
        let sibling = try XCTUnwrap(items.first { $0.id == "second-half" })
        XCTAssertEqual(sibling.needs, ["existing-1-2"],
                       "it must wait for where its prerequisite landed, not for the item it collided with")
        XCTAssertTrue(try backlogContents("alpha").contains("needs:existing-1-2"))
    }

    /// The failure this exists for: an id that names nothing is `no such item` at
    /// every pickup, so the item is withheld for ever and nothing returns it to
    /// the groomer. Dropping it files a runnable item; writing the id down is
    /// what stops the drop being silent.
    func testAPhantomNeedsIdIsDroppedAndNamedInTheNotes() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([
            draftJSON(id: "summary-line", title: "Summarise the open items",
                      needs: ["a-thing-nobody-wrote"])
        ]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0),
                       "a phantom prerequisite is grooming's mistake, not the item's — it still files as ready")
        let item = try XCTUnwrap(fixture.backlogFile?.sections.flatMap(\.items)
            .first { $0.id == "summary-line" })
        XCTAssertTrue(item.needs.isEmpty, "an id naming nothing must not reach the line")
        XCTAssertFalse(try backlogContents("alpha").contains("needs:"))

        let markdown = try String(contentsOf: URL(fileURLWithPath: detailPath("alpha", "summary-line")),
                                  encoding: .utf8)
        XCTAssertTrue(markdown.contains("a-thing-nobody-wrote"),
                      "whoever opens the file has to learn what the drafter meant: \(markdown)")
    }

    /// The other half: a real prerequisite survives untouched. Grooming judges
    /// whether the id names an item, never whether that item is finished — an
    /// item filed behind one that isn't `done` yet is exactly what `needs:` is
    /// for, and waiting is the queue's job rather than the groomer's.
    func testANeedsIdNamingARealItemIsWrittenThroughUnchanged() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 1)
        let (refill, _) = makeRefill(response: itemsJSON([
            draftJSON(id: "summary-line", title: "Summarise the open items", needs: ["existing-1"])
        ]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        let items = fixture.backlogFile?.sections.flatMap(\.items) ?? []
        XCTAssertEqual(items.first { $0.id == "existing-1" }?.status, .ready,
                       "the prerequisite is open, not done — which must not cost the draft its needs:")
        XCTAssertEqual(items.first { $0.id == "summary-line" }?.needs, ["existing-1"])

        let markdown = try String(contentsOf: URL(fileURLWithPath: detailPath("alpha", "summary-line")),
                                  encoding: .utf8)
        XCTAssertFalse(markdown.contains("dropped needs:"), markdown)
    }

    // MARK: - Never groom the same gap twice

    func testAnAlreadyFiledItemIsNotRefiledOnTheNextPass() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        var outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        // The item was filed as `ready`, so a human rejecting it — or autopilot
        // blocking it — leaves the same gap open. The drafter, asked again,
        // returns the same idea; the ledger is what stops it landing twice.
        fixture.updateItemStatus(itemID: "summary-line", newStatus: .blocked)

        outcome = await refill.runPass()

        XCTAssertEqual(outcome, .noDrafts(project: "alpha"))
        XCTAssertEqual(openItemIDs(fixture).filter { $0 == "summary-line" }.count, 1)
    }

    /// The gap the ledger cannot see: an item **a human wrote** is on the board
    /// and in no ledger, so it passed every refusal there was, dodged the id
    /// collision by being renamed to `<id>-2`, and bought a whole
    /// worker/reviewer run for work already queued.
    func testAnItemAlreadyInTheBacklogIsNotReProposedByAnotherName() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 1)
        let (refill, _) = makeRefill(response: itemsJSON([
            draftJSON(id: "summarise-the-existing-work", title: "Existing work 1")
        ]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .noDrafts(project: "alpha"),
                       "the only candidate was already on the board — nothing was left to file")
        XCTAssertEqual(fixture.backlogFile?.sections.flatMap(\.items).map(\.id), ["existing-1"],
                       "not under its own id, and not under a suffixed one either")
    }

    /// And the refusal is per candidate, not per pass: the sibling that names a
    /// real gap is still filed. A duplicate that took the whole pass down with it
    /// would cost more than the run it saved.
    func testADuplicateCandidateDoesNotCostThePassItsOtherWork() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 1)
        let (refill, _) = makeRefill(response: itemsJSON([
            draftJSON(id: "work-again", title: "Existing work 1"),
            draftJSON(id: "summary-line", title: "Summarise the open items")
        ]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        XCTAssertEqual(fixture.backlogFile?.sections.flatMap(\.items).map(\.id),
                       ["existing-1", "summary-line"],
                       "the duplicate is gone and the real gap is filed")
    }

    /// The other half, and the behaviour that must survive: a bare id collision
    /// is still answered by renaming. The candidate names a gap of its own — only
    /// the id was taken — so refusing it would cost real work.
    func testACollidingIdWithItsOwnTitleIsStillRenamedRatherThanRefused() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 1)
        let (refill, _) = makeRefill(response: itemsJSON([
            draftJSON(id: "existing-1", title: "Summarise the open items")
        ]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        let items = fixture.backlogFile?.sections.flatMap(\.items) ?? []
        XCTAssertEqual(items.first { $0.id == "existing-1-2" }?.title, "Summarise the open items",
                       "renaming stays the answer to an id collision")
    }

    func testTheLedgerSurvivesARestartSoRejectedWorkIsNotReinvented() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (first, _) = makeRefill(response: itemsJSON([groundedDraft]))
        first.enabled = true
        _ = await first.runPass()

        // A fresh instance reading the same ledger file — what happens after the
        // app is relaunched.
        let (second, runtime) = makeRefill(response: itemsJSON([groundedDraft]))
        second.enabled = true
        fixture.updateItemStatus(itemID: "summary-line", newStatus: .blocked)

        let outcome = await second.runPass()

        XCTAssertEqual(outcome, .noDrafts(project: "alpha"))
        XCTAssertTrue(runtime.sentPrompts.first?.contains("never propose these again") ?? false,
                      "the prompt should say what was already groomed, not only the filter")
    }

    // MARK: - Selection, through the real loop

    func testPausedProjectIsNotGroomedForEvenWhenItIsTheEmptiest() async throws {
        let paused = try registerProject(named: "paused-project", readyItems: 0, paused: true)
        let normal = try registerProject(named: "zeta", readyItems: 1)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true
        refill.policy = QueueRefill.Policy(threshold: 2, targetDepth: 3, maxItemsPerPass: 3)

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "zeta", ready: 1, drafts: 0, refused: 0))
        XCTAssertEqual(openItemIDs(paused), [], "a paused project is never chosen")
        XCTAssertTrue(openItemIDs(normal).contains("summary-line"))
    }

    /// The measured failure, end to end: a pass that topped up one project made
    /// the grooming cadence divide by the fleet size, so on 2026-08-12 two of
    /// three autopilot-ready projects sat at `ready=0` while grooming had spent
    /// 1 of 150 passes and $3.85 of $350. One pass now leaves all three with
    /// work, and the emptiest queue is served first.
    func testOnePassLeavesEveryEmptyProjectWithWork() async throws {
        let alpha = try registerProject(named: "alpha", readyItems: 0)
        let beta = try registerProject(named: "beta", readyItems: 0)
        let gamma = try registerProject(named: "gamma", readyItems: 1)
        let (refill, runtime) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        XCTAssertTrue(openItemIDs(alpha).contains("summary-line"))
        XCTAssertTrue(openItemIDs(beta).contains("summary-line"))
        XCTAssertTrue(openItemIDs(gamma).contains("summary-line"),
                      "a project still below the threshold is served by the same pass")
        XCTAssertEqual(runtime.sentPrompts.count, 3, "one drafter call per project served")
    }

    /// The ceiling that stops grooming first is the pass count, so serving the
    /// fleet in one pass must not spend it faster than serving one project did.
    func testServingSeveralProjectsStillCostsOnePass() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        _ = try registerProject(named: "beta", readyItems: 0)
        _ = try registerProject(named: "gamma", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        XCTAssertEqual(refill.budget.passes, 1, "one pass, however much of the fleet it served")
    }

    /// One row per project, not one per pass: "filed 1 for alpha" and "the
    /// drafter returned nothing for beta" are different answers, and a single
    /// record could only carry one of them.
    func testEachProjectServedLeavesItsOwnPassRecord() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        _ = try registerProject(named: "beta", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        XCTAssertEqual(refill.passHistory.map(\.project), ["alpha", "beta"])
        XCTAssertEqual(Set(refill.passHistory.map(\.id)).count, 2,
                       "two projects served in one pass are two records, not one repeated")
    }

    /// The money ceiling is checked between projects, not only at the top of the
    /// pass: without that one pass could overrun the day's budget by the whole
    /// width of the fleet.
    func testAPassStopsFanningOutOnceTheDaysSpendIsGone() async throws {
        let alpha = try registerProject(named: "alpha", readyItems: 0)
        let beta = try registerProject(named: "beta", readyItems: 0)
        // A ceiling the first project's drafter call reaches exactly.
        let (refill, runtime) = makeRefill(response: itemsJSON([groundedDraft]), costUSD: 4,
                                           budget: QueueRefill.Budget(capUSD: 4))
        refill.enabled = true

        _ = await refill.runPass()

        XCTAssertEqual(runtime.sentPrompts.count, 1, "the second project must not draft on credit")
        XCTAssertTrue(openItemIDs(alpha).contains("summary-line"))
        XCTAssertEqual(openItemIDs(beta), [])
    }

    /// One project's drafter coming back with nothing is that project's outcome,
    /// not the pass's: the rest of the fleet is still owed its refill.
    func testAProjectThatDraftedNothingDoesNotStopTheRestOfThePass() async throws {
        let alpha = try registerProject(named: "alpha", readyItems: 0)
        let beta = try registerProject(named: "beta", readyItems: 0)
        // Alpha is served first and gets an unusable reply; beta's is fine.
        let runtime = StubHeadlessRuntime(behavior: .scripted([
            [.assistantText("I couldn't find anything worth doing.")],
            [.assistantText(itemsJSON([groundedDraft]))]
        ]))
        let refill = makeRefill(runtime: runtime)
        refill.enabled = true

        _ = await refill.runPass()

        XCTAssertEqual(refill.passHistory.map(\.outcome.kind), ["noDrafts", "filed"])
        XCTAssertEqual(openItemIDs(alpha), [])
        XCTAssertTrue(openItemIDs(beta).contains("summary-line"))
    }

    func testAProjectWithoutAWorkerAndReviewerIsSkipped() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0, autopilotReady: false)
        let (refill, runtime) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .held(.noEligibleProject))
        XCTAssertTrue(runtime.sentPrompts.isEmpty)
        XCTAssertEqual(openItemIDs(fixture), [])
    }

    func testAHealthyQueueIsLeftAloneWithoutAModelCall() async throws {
        _ = try registerProject(named: "alpha", readyItems: 4)
        let (refill, runtime) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .held(.queuesHealthy))
        XCTAssertTrue(runtime.sentPrompts.isEmpty, "an idle project with a full queue needs nothing")
    }

    // MARK: - The fill is bounded

    func testThePassStopsAtTheTargetDepthEvenWhenTheDrafterOffersMore() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 1)
        // Five plausible items on offer; the queue is one short of a target of two.
        let extras = (1...5).map { index in
            """
            {"id":"extra-\(index)","title":"Extra idea number \(index)","size":"S",
             "verify":"/bin/echo ok","what":"The `BACKLOG.md` file gains detail \(index).",
             "how":"Read `BACKLOG.md` first.","validation":["Detail \(index) is there"],"outOfScope":[]}
            """
        }
        let (refill, _) = makeRefill(response: itemsJSON(extras))
        refill.enabled = true
        refill.policy = QueueRefill.Policy(threshold: 2, targetDepth: 2, maxItemsPerPass: 3)

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        XCTAssertEqual(openItemIDs(fixture).filter { $0.hasPrefix("extra-") }, ["extra-1"],
                       "a loop that grooms whenever it can produces infinite plausible work")
    }

    func testGarbageFromTheDrafterFilesNothing() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: "I couldn't find anything worth doing.")
        refill.enabled = true

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .noDrafts(project: "alpha"))
        XCTAssertEqual(openItemIDs(fixture), [])
    }

    // MARK: - Pass visibility

    /// The failure this exists for: a loop that ran pass after pass filing
    /// nothing, with no way to tell whether it held, drafted nothing, or fell
    /// over. Each pass leaves a record, and a hold names its reason.
    func testEachPassIsRecordedWithItsOutcome() async throws {
        _ = try registerProject(named: "alpha", readyItems: 4)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        let healthy = try XCTUnwrap(refill.passHistory.last)
        XCTAssertEqual(healthy.outcome, .held(.queuesHealthy))
        XCTAssertEqual(healthy.outcome.hold?.kind, "queuesHealthy")
        XCTAssertEqual(healthy.outcome.hold?.reason, QueueRefill.Hold.queuesHealthy.reason)
        XCTAssertNil(healthy.project, "a hold chose no project")

        // A pass that files reports the project and the counts.
        _ = try registerProject(named: "beta", readyItems: 0)
        _ = await refill.runPass()

        let filed = try XCTUnwrap(refill.passHistory.last)
        XCTAssertEqual(filed.outcome, .filed(project: "beta", ready: 1, drafts: 0, refused: 0))
        XCTAssertEqual(filed.project, "beta")
        XCTAssertEqual(refill.passHistory.count, 2, "both passes are kept, oldest first")
    }

    /// `budgetExhausted` was already visible; the quiet holds must be too, or
    /// "nothing was groomed today" has no answer.
    func testEveryHoldIsRecordedNotJustTheBudgetRefusal() async throws {
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]),
                                     budget: QueueRefill.Budget(spentUSD: 25, capUSD: 20))
        refill.enabled = true

        // No project open at all: nothing eligible.
        _ = await refill.runPass()
        XCTAssertEqual(refill.passHistory.map(\.outcome.kind), ["held"])
        XCTAssertEqual(refill.passHistory.last?.outcome.hold?.kind, "budgetExhausted")
        XCTAssertTrue(refill.passHistory.last?.summary.contains("25.00") ?? false)
    }

    /// The timer keeps ticking while the loop is off. Recording those ticks would
    /// push the passes that did happen out of a bounded history.
    func testADisabledLoopDoesNotFillTheHistory() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = false

        for _ in 0..<5 { _ = await refill.runPass() }

        XCTAssertEqual(refill.lastOutcome, .disabled)
        XCTAssertTrue(refill.passHistory.isEmpty)
    }

    /// A long-running app must not accumulate passes without bound.
    func testHistoryIsBounded() async throws {
        _ = try registerProject(named: "alpha", readyItems: 4)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        for _ in 0..<(CoordinatorQueueRefill.maxPassHistory + 7) { _ = await refill.runPass() }

        XCTAssertEqual(refill.passHistory.count, CoordinatorQueueRefill.maxPassHistory)
    }

    /// Each pass reaches the event stream the Activity feed reads — including a
    /// hold, which is exactly the case that used to be silent.
    func testAPassIsPublishedToTheEventStream() async throws {
        _ = try registerProject(named: "alpha", readyItems: 4)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true

        _ = await refill.runPass()

        // `publishEvent` hands the event to the bus from an unstructured task, so
        // the assertion waits for it rather than assuming it has already landed.
        let bus = try XCTUnwrap(eventBuses["alpha"])
        let event = try await eventuallyValue("a refill-pass event on alpha's bus") {
            await bus.recentEvents().last(where: { $0.payload["kind"] == "refill-pass" })
        }
        XCTAssertEqual(event.source, "Coordinator")
        XCTAssertEqual(event.payload["outcome"], "held")
        XCTAssertEqual(event.payload["hold"], "queuesHealthy")
        XCTAssertEqual(event.payload["reason"], QueueRefill.Hold.queuesHealthy.reason)
        XCTAssertEqual(event.payload["detail"], QueueRefill.Hold.queuesHealthy.reason.isEmpty
                       ? nil : "held — \(QueueRefill.Hold.queuesHealthy.reason)")
    }

    // MARK: - A pass that never comes back

    /// The failure this whole group exists for. On 2026-08-12 a pass stopped
    /// answering, kept the in-flight flag, and that flag gated every later pass:
    /// grooming stopped for the whole fleet for 2h22m with 20 of 150 passes and
    /// $52.59 of $350 used, two projects drained to zero ready, and nothing
    /// anywhere saying so. Only a restart cleared it.
    /// The watchdog itself, on the wall clock: a pass that never answers is
    /// ended, and the flag it was holding — the one that gates every later pass —
    /// is down when the call returns.
    ///
    /// It asserts nothing about *where* the pass was stuck, because at this
    /// timescale that depends on how far it got before the deadline; the
    /// deterministic tests below are where the stage is pinned down.
    func testAPassThatNeverAnswersIsEndedAtItsDeadline() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeStallingRefill()
        refill.enabled = true
        refill.passDeadline = 0.5

        let outcome = await refill.runPass()

        guard case .abandoned(let project, _, _, let why) = outcome else {
            return XCTFail("a pass that never answers should have been ended, got \(outcome)")
        }
        XCTAssertEqual(project, "alpha")
        XCTAssertEqual(why, .deadline)
        XCTAssertFalse(refill.isPassing, "the flag is down — it is what gates every later pass")
        XCTAssertNil(refill.inFlightPass)
        XCTAssertEqual(refill.passHistory.map(\.outcome.kind), ["abandoned"],
                       "the ending is recorded, not just survived")
    }

    /// A pass reaped on the next attempt rather than at the deadline itself —
    /// the second net, for a pass whose watchdog went away with its caller.
    ///
    /// Driven by the clock the pass is judged against rather than by waiting, so
    /// it can play out the observed two hours in a millisecond. It is also the
    /// acceptance criterion in full: the ending is recorded with what the pass
    /// was doing, and the next pass runs.
    func testAStuckPassIsEndedWithItsStageAndTheNextPassRuns() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, runtime) = makeStallingRefill(thenAnswering: itemsJSON([groundedDraft]))
        refill.enabled = true
        refill.passDeadline = 3600

        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)  // pinned: see dayPinRationale
        // Waiting on the send rather than on the flag: the pass has to be inside
        // the call that hangs, not merely started, or which stage it is recorded
        // in would depend on how the two tasks interleaved.
        let stuck = Task { await refill.runPass(now: start) }
        try await eventually("one prompt to be sent") { runtime.sentPrompts.count == 1 }
        XCTAssertEqual(refill.inFlightPass?.stage, .drafting)

        // Two hours and change later, which is what the unattended night looked
        // like: the pass is still in flight and nothing has been groomed since.
        let recovered = await refill.runPass(now: start.addingTimeInterval(8520))

        let ending = try XCTUnwrap(refill.passHistory.first)
        XCTAssertEqual(ending.outcome.kind, "abandoned")
        XCTAssertEqual(ending.project, "alpha")
        XCTAssertTrue(ending.summary.contains("2h22m"), ending.summary)
        XCTAssertTrue(ending.summary.contains("outlived its deadline"), ending.summary)
        XCTAssertTrue(ending.summary.contains("waiting on the drafter"),
                      "which call it was in, so the next wedge is diagnosable: \(ending.summary)")

        // And the queue starts being refilled again — nothing short of a restart
        // could reach this before.
        XCTAssertEqual(recovered, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        XCTAssertEqual(runtime.sentPrompts.count, 2, "the next pass reached the drafter")
        XCTAssertTrue(openItemIDs(fixture).contains("summary-line"))
        stuck.cancel()
    }

    /// The recovery an operator reaches for first — and the one that returned a
    /// clean 200 twice and changed nothing, leaving a restart as the only way
    /// back to grooming.
    func testSwitchingTheLoopOffAndOnClearsAStuckFlag() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, runtime) = makeStallingRefill(thenAnswering: itemsJSON([groundedDraft]))
        refill.enabled = true
        // Long enough that nothing ends this pass on its own: the operator is
        // the one doing the clearing.
        refill.passDeadline = 3600

        let stuck = Task { await refill.runPass() }
        try await eventually("one prompt to be sent") { runtime.sentPrompts.count == 1 }

        refill.enabled = false
        XCTAssertFalse(refill.isPassing, "off means off, including the pass that is running")
        refill.enabled = true

        let recovered = await refill.runPass()
        XCTAssertEqual(recovered, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        guard case .abandoned(_, _, _, let why) = refill.passHistory.first?.outcome else {
            return XCTFail("switching off should have ended the pass and said so")
        }
        XCTAssertEqual(why, .switchedOff)
        stuck.cancel()
    }

    /// One pass gets one ending. A wedged pass that answers hours later — after
    /// its ending was recorded and a successor let through — is a bystander: it
    /// must not record a second outcome, and it must not file drafts into a
    /// backlog a later pass now owns.
    func testAPassThatComesBackAfterItsEndingRecordsNothingMore() async throws {
        let fixture = try registerProject(named: "alpha", readyItems: 0)
        let (refill, runtime) = makeStallingRefill(thenAnswering: itemsJSON([groundedDraft]))
        refill.enabled = true
        refill.passDeadline = 3600

        let stuck = Task { await refill.runPass() }
        try await eventually("one prompt to be sent") { runtime.sentPrompts.count == 1 }
        refill.enabled = false      // ends it, and cancels the work under it
        refill.enabled = true

        // Let the cancelled pass unwind and try to report.
        _ = await stuck.value

        XCTAssertEqual(refill.passHistory.count, 1, "one pass, one ending")
        XCTAssertEqual(refill.passHistory.map(\.outcome.kind), ["abandoned"])
        XCTAssertEqual(openItemIDs(fixture), [], "a bystander files nothing")
    }

    /// The ordinary path is untouched: the flag goes up for the pass and comes
    /// back down when it finishes, and nothing about it reads as a stall.
    func testAnOrdinaryPassTakesTheFlagAndGivesItBack() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]))
        refill.enabled = true
        XCTAssertFalse(refill.isPassing)

        let outcome = await refill.runPass()

        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        XCTAssertFalse(refill.isPassing)
        XCTAssertNil(refill.inFlightPass)
        XCTAssertNil(refill.stallNotice())
        XCTAssertEqual(refill.passHistory.map(\.outcome.kind), ["filed"])
    }

    /// A pass whose model call fell over rather than hung. It ends the ordinary
    /// way — the flag is not something only a healthy pass gives back.
    func testAPassWhoseModelCallFailsLeavesTheFlagDown() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let runtime = StubHeadlessRuntime(
            behavior: .startFailure(RuntimeError.processSpawnFailed("claude not found")))
        let refill = makeRefill(runtime: runtime)
        refill.enabled = true

        let outcome = await refill.runPass()
        XCTAssertEqual(outcome, .noDrafts(project: "alpha"))
        XCTAssertFalse(refill.isPassing)
        XCTAssertNil(refill.stallNotice())
    }

    // MARK: - Saying so where someone will see it

    /// The contradiction the app can detect and nobody could: a pass in flight
    /// since a timestamp hours old. The footer reads this, so a coordinator that
    /// has stopped grooming says so beside the ceilings that hadn't stopped it.
    func testAPassInFlightPastItsDeadlineReadsAsAStall() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, runtime) = makeStallingRefill()
        refill.enabled = true
        refill.passDeadline = 3600

        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)  // pinned: see dayPinRationale
        let stuck = Task { await refill.runPass(now: start) }
        try await eventually("one prompt to be sent") { runtime.sentPrompts.count == 1 }

        XCTAssertNil(refill.stallNotice(now: start.addingTimeInterval(600)),
                     "inside its deadline a running pass is not news")
        let notice = try XCTUnwrap(refill.stallNotice(now: start.addingTimeInterval(2 * 3600 + 1320)))
        XCTAssertTrue(notice.contains("alpha"), notice)
        XCTAssertTrue(notice.contains("2h22m"), notice)
        XCTAssertTrue(notice.contains("waiting on the drafter"), notice)
        stuck.cancel()
    }

    /// And it survives the pass being ended, so the news doesn't vanish the
    /// moment the loop recovers the flag — until a real pass replaces it.
    func testAnEndedPassKeepsSayingSoUntilTheNextOneRuns() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeStallingRefill(thenAnswering: itemsJSON([groundedDraft]))
        refill.enabled = true
        refill.passDeadline = 0.1

        _ = await refill.runPass()
        let notice = try XCTUnwrap(refill.stallNotice())
        XCTAssertTrue(notice.hasPrefix("Stalled — "), notice)
        XCTAssertTrue(notice.contains("outlived its deadline"), notice)

        // The 0.1s deadline was for the pass meant to stall; left in place, a
        // healthy pass on a loaded machine outlived it too and read as stalled.
        refill.passDeadline = 30
        _ = await refill.runPass()
        XCTAssertNil(refill.stallNotice(), "a pass that ran normally is the loop's answer")
    }

    /// The reading that outlives the recovery. `stallNotice` is right to go
    /// quiet once a healthy pass has run — the loop is not stalled now — but
    /// that left a night which hung repeatedly and self-healed every time
    /// reading exactly like one that never hung, the whole record being a line
    /// in a 50-entry history nobody opens.
    func testAnAbandonedPassIsStillCountedAfterTheLoopHasRecovered() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeStallingRefill(thenAnswering: itemsJSON([groundedDraft]))
        refill.enabled = true
        refill.passDeadline = 0.1
        XCTAssertEqual(refill.budget.abandonedPasses, 0, "zero, not nothing")

        _ = await refill.runPass()
        XCTAssertEqual(refill.budget.abandonedPasses, 1)
        XCTAssertNotNil(refill.stallNotice(), "and it is stalled right now, which is the other reading")

        // The recovery: the next pass files, the flag is down, the loop is
        // healthy — and the night still says it lost a pass to a stall. The
        // 100ms deadline above was the first pass's fixture — the recovery
        // must not race it, or a loaded suite host abandons this one too.
        refill.passDeadline = 30
        let recovered = await refill.runPass()
        XCTAssertEqual(recovered, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        XCTAssertNil(refill.stallNotice(), "`passStalled` still answers only for right now")
        XCTAssertEqual(refill.budget.abandonedPasses, 1,
                       "the count is what survives the recovery")
        XCTAssertEqual(refill.budget.passes, 2,
                       "both passes were spent — an abandoned one is not folded into the count")
        XCTAssertTrue(refill.budget.helpText.contains("1 pass abandoned today"),
                      refill.budget.helpText)
    }

    /// Two nets catch a stuck pass — the watchdog inside the pass and the
    /// reaper on the next attempt — and one pass gets one ending, so it must
    /// also get one count.
    func testEachStalledPassIsCountedOnceHoweverItWasEnded() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, runtime) = makeStallingRefill(thenAnswering: itemsJSON([groundedDraft]))
        refill.enabled = true
        refill.passDeadline = 3600

        // Pinned to local midday rather than `Date()`. The reap below is 8520s
        // (2h22m) after `start`, and `Budget.charged` rolls the day through
        // `rolled(to:)`, which zeroes `abandonedPasses` across a local midnight.
        // Started from the wall clock this test therefore fails for the last
        // 2h22m of every day and passes the rest of it — it did exactly that on
        // 2026-08-21: red at 23:35 local, green at 19:57 on the same commit,
        // and it fails at the last green commit too, so no change of ours broke
        // it. A day-scoped counter resetting on a new day is the intended
        // behaviour `abandonedAPass()` documents; "one ending, one count" only
        // means anything inside one day, so the test now says which day.
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let stuck = Task { await refill.runPass(now: start) }
        try await eventually("one prompt to be sent") { runtime.sentPrompts.count == 1 }

        // Reaped on the next attempt rather than at the deadline itself, and
        // then let the wedged pass unwind and try to report its own ending.
        _ = await refill.runPass(now: start.addingTimeInterval(8520))
        _ = await stuck.value

        XCTAssertEqual(refill.passHistory.filter { $0.outcome.kind == "abandoned" }.count, 1)
        XCTAssertEqual(refill.budget.abandonedPasses, 1, "one ending, one count")
    }

    /// Why these tests pin their clock instead of starting from `Date()`.
    ///
    /// A pass is advanced by 8520s (2h22m) to outlive its deadline, and
    /// `Budget.charged` rolls the day through `rolled(to:)` — which zeroes the
    /// day across a local midnight. Started from the wall clock, any such test
    /// fails for the last 2h22m of every day and passes the rest of it.
    ///
    /// That is not hypothetical twice over: it reddened
    /// `testEachStalledPassIsCountedOnceHoweverItWasEnded` at 23:23 local on
    /// 2026-08-21, and `testAStuckPassIsEndedWithItsStageAndTheNextPassRuns` at
    /// 23:00 the next night — the second because the first fix pinned only the
    /// test that happened to be failing and left its siblings on the wall clock.
    /// Local midday leaves 12 hours of headroom either side.
    private static let dayPinRationale = ()

    // MARK: - Surviving a relaunch

    /// The day's figures used to live in a property and nowhere else, so every
    /// relaunch put `passesUsed`, `spentUSD` and `abandonedPasses` back to zero.
    /// Seen twice on 2026-08-21: a Planner card reading `0 of 12 passes` at a
    /// moment when 37 items had been filed that day — not idle, forgotten — and
    /// a `maxPasses` of 12 that an app restarted three times honoured three
    /// times over.
    func testTodaysPassesAndSpendAreStillCountedAfterARelaunch() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]), costUSD: 1.25)
        refill.enabled = true
        _ = await refill.runPass()
        XCTAssertEqual(refill.budget.passes, 1)
        refill.stop()

        let relaunched = makeRefill(runtime: stubRuntime())
        defer { relaunched.stop() }

        XCTAssertEqual(relaunched.budget.passes, 1,
                       "the pass is on record, so a new process counts it too")
        XCTAssertEqual(relaunched.budget.spentUSD, 1.25, accuracy: 0.0001,
                       "and so is what it spent")
    }

    /// The consequence that made this worth fixing: a ceiling counted from
    /// memory is not a ceiling, because the counter and the process end
    /// together.
    func testThePassCeilingStillBindsAfterARelaunch() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]),
                                     budget: QueueRefill.Budget(maxPasses: 1))
        refill.enabled = true
        _ = await refill.runPass()
        refill.stop()

        let runtime = stubRuntime(answering: itemsJSON([groundedDraft]))
        let relaunched = makeRefill(runtime: runtime,
                                    budget: QueueRefill.Budget(maxPasses: 1))
        defer { relaunched.stop() }
        relaunched.enabled = true

        guard case .held(.budgetExhausted(let reason)) = await relaunched.runPass() else {
            return XCTFail("the day's only pass was spent before the relaunch")
        }
        XCTAssertTrue(reason.contains("daily grooming passes used (1 of 1)"), reason)
        XCTAssertTrue(runtime.sentPrompts.isEmpty,
                      "a restart must not hand the day its passes back")
    }

    /// An abandoned pass is the reading that outlives a recovery, so it is also
    /// the one a relaunch must not erase — a night that hung four times and
    /// self-healed four times has to be tellable in the morning from one that
    /// never hung.
    func testAnAbandonedPassIsStillCountedAfterARelaunch() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeStallingRefill()
        refill.enabled = true
        refill.passDeadline = 0.1

        _ = await refill.runPass()
        XCTAssertEqual(refill.budget.abandonedPasses, 1)
        refill.stop()

        let relaunched = makeRefill(runtime: stubRuntime())
        defer { relaunched.stop() }

        XCTAssertEqual(relaunched.budget.abandonedPasses, 1,
                       "the ending is on record, not only in the process that saw it")
        XCTAssertEqual(relaunched.budget.passes, 1,
                       "counted beside the passes spent, never folded into them")
    }

    /// The history comes back **whole**, not as a list of tags. Every reader of
    /// it — the Planner card, `GET /v1/coordinator/refill` — reads the
    /// associated values: how many items were filed, which hold, which stage a
    /// pass was stuck in. A tag alone would read back as a day of passes that
    /// did nothing anyone can name.
    func testTheDaysPassHistoryIsReadBackWithItsOutcomesWhole() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]),
                                     budget: QueueRefill.Budget(maxPasses: 1))
        refill.enabled = true
        _ = await refill.runPass()
        _ = await refill.runPass()
        refill.stop()

        let relaunched = makeRefill(runtime: stubRuntime(),
                                    budget: QueueRefill.Budget(maxPasses: 1))
        defer { relaunched.stop() }

        XCTAssertEqual(relaunched.passHistory.map(\.outcome), [
            .filed(project: "alpha", ready: 1, drafts: 0, refused: 0),
            .held(.budgetExhausted("daily grooming passes used (1 of 1)"))
        ], "the counts and the hold's own phrasing survive the round trip")
    }

    /// The ledger is not an audit log the day inherits: a new local day starts
    /// from zero, the same boundary `Budget.rolled(to:)` reads.
    func testANewLocalDayStartsFromZeroHoweverMuchTheLedgerHolds() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeRefill(response: itemsJSON([groundedDraft]), costUSD: 2)
        refill.enabled = true
        _ = await refill.runPass()
        refill.stop()

        let tomorrow = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: Date()))
        let next = makeRefill(runtime: stubRuntime(),
                              budget: QueueRefill.Budget(maxPasses: 12, day: tomorrow))
        defer { next.stop() }

        XCTAssertEqual(next.budget.passes, 0)
        XCTAssertEqual(next.budget.spentUSD, 0, accuracy: 0.0001)
        XCTAssertEqual(next.budget.abandonedPasses, 0)
        XCTAssertTrue(next.passHistory.isEmpty,
                      "yesterday's passes are not today's history either")
    }

    /// `Budget.abandonedAPass()` deliberately does not roll the day, because an
    /// abandonment is stamped with the deadline the pass outlived and that
    /// instant can sit ahead of the clock. Reading the count off a ledger has to
    /// preserve that rather than quietly normalise it, so the day an ending
    /// belongs to is written down beside the instant it happened.
    func testAnAbandonmentStampedInTomorrowIsCountedAgainstTheDayThePassRanIn() throws {
        let midday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let tomorrow = midday.addingTimeInterval(24 * 3600)

        var ledger = CoordinatorQueueRefill.PassLedger()
        ledger.append(.init(at: midday, event: .passStarted, project: "alpha"))
        ledger.append(.init(at: midday, event: .spend, costUSD: 4.37))
        ledger.append(.init(at: tomorrow, event: .outcome, project: "alpha",
                            outcome: .abandoned(project: "alpha", stage: .drafting,
                                                ranFor: 900, why: .deadline),
                            countsOn: midday))

        let today = ledger.budget(on: midday,
                                  startingFrom: QueueRefill.Budget(maxPasses: 12, day: midday))
        XCTAssertEqual(today.passes, 1)
        XCTAssertEqual(today.spentUSD, 4.37, accuracy: 0.0001,
                       "an ending stamped in tomorrow must not zero today's spend")
        XCTAssertEqual(today.abandonedPasses, 1, "it belongs to the day the pass ran in")

        let next = ledger.budget(on: tomorrow,
                                 startingFrom: QueueRefill.Budget(maxPasses: 12, day: tomorrow))
        XCTAssertEqual(next.abandonedPasses, 0,
                       "and not to the day its deadline happened to land in")
        XCTAssertEqual(next.passes, 0)
        XCTAssertEqual(next.spentUSD, 0, accuracy: 0.0001)
    }

    /// A kill that cuts a line inside a multi-byte character leaves the file
    /// invalid UTF-8. Read as one string, that loaded an empty day — the ceiling
    /// started again from zero — and handed `rewrite` nothing to put back.
    func testALineCutInsideAMultiByteCharacterCostsNeitherTheDayNorItself() throws {
        let url = tempDir.appending(path: "passes.jsonl")
        let midday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

        let missing = CoordinatorQueueRefill.PassLedger.load(from: url, now: midday)
        XCTAssertTrue(missing.ledger.entries.isEmpty, "a missing file is an empty ledger")
        XCTAssertTrue(missing.undecodable.isEmpty)

        CoordinatorQueueRefill.PassLedger.append(
            .init(at: midday, event: .passStarted, project: "alpha"), to: url)
        // The first two bytes of an em dash, then the newline a later append adds.
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"title\":\"a".utf8) + Data([0xE2, 0x80]) + Data("\n".utf8))
        try handle.close()
        CoordinatorQueueRefill.PassLedger.append(
            .init(at: midday, event: .passStarted, project: "beta"), to: url)

        let loaded = CoordinatorQueueRefill.PassLedger.load(from: url, now: midday)
        XCTAssertEqual(loaded.ledger.entries.map(\.project), ["alpha", "beta"])
        let budget = loaded.ledger.budget(
            on: midday, startingFrom: QueueRefill.Budget(maxPasses: 12, day: midday))
        XCTAssertEqual(budget.passes, 2, "the day's passes still count against its ceiling")
        XCTAssertEqual(loaded.undecodable, ["{\"title\":\"a\u{FFFD}"],
                       "the cut line comes back as lossy text")

        CoordinatorQueueRefill.PassLedger.rewrite(loaded.ledger, undecodable: loaded.undecodable, to: url)
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("{\"title\":\"a\u{FFFD}\n"), "the rewrite puts the line back")
        XCTAssertEqual(CoordinatorQueueRefill.PassLedger.load(from: url, now: midday)
            .ledger.entries.map(\.project), ["alpha", "beta"])
    }

    /// And that the loop actually writes it that way — the rule above is only
    /// worth having if `abandon` says which day the ending is counted against.
    func testAnAbandonmentRecordsTheDayItCountsAgainstNotOnlyItsDeadline() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let (refill, _) = makeStallingRefill()
        refill.enabled = true
        refill.passDeadline = 0.1
        let midday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

        _ = await refill.runPass(now: midday)

        let ending = try XCTUnwrap(refill.passLedger.entries.last { $0.event == .outcome })
        XCTAssertEqual(ending.outcome?.kind, "abandoned")
        XCTAssertEqual(ending.at.timeIntervalSince1970,
                       midday.addingTimeInterval(0.1).timeIntervalSince1970, accuracy: 0.001,
                       "stamped with the deadline it outlived")
        XCTAssertEqual(Calendar.current.startOfDay(for: try XCTUnwrap(ending.countsOn)),
                       Calendar.current.startOfDay(for: midday),
                       "and counted against the day it ran in")
    }

    /// Nothing on record is a day that has groomed nothing, which is the truth
    /// on every first launch. It must not be a reason to stop grooming.
    func testAMissingLedgerLeavesTheDayAtZeroAndTheLoopGroomable() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let missing = tempDir.appending(path: "no-such-passes.jsonl")
        let runtime = stubRuntime(answering: itemsJSON([groundedDraft]))
        let refill = makeRefill(runtime: runtime, passLedgerURL: missing)
        defer { refill.stop() }
        refill.enabled = true

        XCTAssertEqual(refill.budget.passes, 0)
        XCTAssertTrue(refill.passHistory.isEmpty)

        let outcome = await refill.runPass()
        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        XCTAssertEqual(refill.budget.passes, 1, "and the day starts counting from there")
    }

    func testAnEmptyLedgerReadsTheSameAsAMissingOne() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let empty = tempDir.appending(path: "empty-passes.jsonl")
        try Data().write(to: empty)
        let runtime = stubRuntime(answering: itemsJSON([groundedDraft]))
        let refill = makeRefill(runtime: runtime, passLedgerURL: empty)
        defer { refill.stop() }
        refill.enabled = true

        XCTAssertEqual(refill.budget.passes, 0)
        XCTAssertTrue(refill.passHistory.isEmpty)

        let outcome = await refill.runPass()
        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0))
        XCTAssertEqual(refill.budget.passes, 1)
    }

    /// A half-written last line — what a kill leaves behind — costs the line and
    /// nothing else. It is skipped rather than failing the load, and it is left
    /// in the file rather than deleted on the very launch that failed to read
    /// it: an unreadable line is still somebody's history.
    func testAnUndecodableLineCostsNeitherTheDayNorTheGrooming() async throws {
        _ = try registerProject(named: "alpha", readyItems: 0)
        let torn = tempDir.appending(path: "torn-passes.jsonl")
        try "{\"at\":\"2026-08-21T12:00:00Z\",\"event\":\"passSta".write(
            to: torn, atomically: true, encoding: .utf8)
        let runtime = stubRuntime(answering: itemsJSON([groundedDraft]))
        let refill = makeRefill(runtime: runtime, passLedgerURL: torn)
        defer { refill.stop() }
        refill.enabled = true

        XCTAssertEqual(refill.budget.passes, 0, "a line nobody can read counts as nothing")
        XCTAssertTrue(refill.passHistory.isEmpty)

        let outcome = await refill.runPass()
        XCTAssertEqual(outcome, .filed(project: "alpha", ready: 1, drafts: 0, refused: 0),
                       "an unreadable record is not a reason to stop grooming")
        XCTAssertEqual(refill.budget.passes, 1)
        XCTAssertTrue(try String(contentsOf: torn, encoding: .utf8).contains("\"event\":\"passSta"),
                      "and the torn line is still where it was found")
    }

    // MARK: - Fixtures

    /// A loop whose drafter hangs — the observed failure. `thenAnswering` is
    /// what every send *after* the first one replies with, so a test can show
    /// the loop recovering rather than only surviving.
    private func makeStallingRefill(thenAnswering response: String? = nil)
    -> (CoordinatorQueueRefill, StubHeadlessRuntime) {
        let runtime = StubHeadlessRuntime(
            behavior: .stallingFirst(1, then: response.map { [.assistantText($0)] } ?? []))
        return (makeRefill(runtime: runtime), runtime)
    }

    /// - Parameter costUSD: what the drafter's call reports having cost. Carried
    ///   on the `result` event, the way the real runtime reports it; the empty
    ///   result text leaves the streamed reply alone.
    private func makeRefill(response: String,
                            costUSD: Double = 0,
                            budget: QueueRefill.Budget = QueueRefill.Budget())
    -> (CoordinatorQueueRefill, StubHeadlessRuntime) {
        let runtime = StubHeadlessRuntime(behavior: .events([
            .assistantText(response),
            .result(.init(text: "", costUSD: costUSD, durationMs: 0,
                          inputTokens: 0, outputTokens: 0,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "stub-session", permissionDenials: []))
        ]))
        return (makeRefill(runtime: runtime, budget: budget), runtime)
    }

    /// The wiring every loop in this file gets, over whichever runtime the test
    /// needs — the scripted one, or one that hangs.
    ///
    /// - Parameter passLedgerURL: nil puts the day's figures beside `ledgerURL`,
    ///   which is in this test's own temp directory — so a loop built here never
    ///   writes passes into the developer's `~/.kiteloop`. Named only by the
    ///   cases that are *about* what is in that file.
    private func makeRefill(runtime: StubHeadlessRuntime,
                            budget: QueueRefill.Budget = QueueRefill.Budget(),
                            passLedgerURL: URL? = nil)
    -> CoordinatorQueueRefill {
        // A triage ledger in this test's own temp directory. The default is
        // `BlockedTriage.Ledger.defaultURL()` — `~/.kiteloop/coordinator-triage.jsonl`,
        // the developer's own — and a pass triages the blocked pile before it
        // grooms, so running the loop here wrote real records about a project
        // called "alpha" that lives in a temp folder. The grooming ledger beside
        // it was already injected for exactly this reason; this one was missed.
        //
        // `approvalsLedgerURL` gets the same treatment: every pass now reads it
        // for the escaped-defect signal, and an unstated one would read the
        // developer's real `~/.kiteloop/task-approvals.jsonl` on every test.
        let refill = CoordinatorQueueRefill(
            ledgerURL: ledgerURL,
            passLedgerURL: passLedgerURL,
            approvalsLedgerURL: tempDir.appending(path: "task-approvals.jsonl"),
            budget: budget,
            blockedTriage: CoordinatorBlockedTriage(
                ledgerURL: tempDir.appending(path: "coordinator-triage.jsonl")))
        refill.groomingLedger = groomingLedger
        refill.configure(registry: registry,
                         globalConfigStore: globalConfigStore,
                         runtimeFactory: { runtime })
        return refill
    }

    /// A runtime that answers with `response` once — what a relaunched loop is
    /// given when the test cares about what it *remembered* rather than what it
    /// goes on to draft.
    private func stubRuntime(answering response: String = "") -> StubHeadlessRuntime {
        StubHeadlessRuntime(behavior: .events(response.isEmpty ? [] : [.assistantText(response)]))
    }

    @discardableResult
    /// - Parameter extraEpics: further, empty sections after `Now`, for the tests
    ///   about which epic a draft is filed under. `Now` stays first, so it stays
    ///   the fallback `section(for:in:)` picks.
    private func registerProject(named name: String,
                                 readyItems: Int,
                                 paused: Bool = false,
                                 autopilotReady: Bool = true,
                                 extraEpics: [String] = []) throws -> BacklogViewModel {
        let root = tempDir.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        if paused { try project.setPaused(true, goal: nil) }

        // Groomed, not merely `ready`. A queue's health is measured by how many
        // of its items could actually *start* — `QueueHealth.startable`, which
        // runs `DefinitionOfReady` over each one — so a line with no `verify:`,
        // no `size:` and no detail file counts as ungroomed and leaves the queue
        // as hungry as an empty one. These fixtures existed to stand for a full,
        // healthy queue, and a bare line stopped standing for that the moment
        // refill began reading startability rather than the raw ready tally.
        let lines = (1...max(1, readyItems)).prefix(readyItems)
            .map { "- [ ] existing-\($0) | Existing work \($0) | verify: true | size:S | ready → [detail](backlog/existing-\($0).md)" }
        let epics = extraEpics.map { "\n## \($0)\n" }.joined()
        try "# \(name) Backlog\n\n## Now\n\n\(lines.joined(separator: "\n"))\n\(epics)"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        // Only when there are items to describe. `blockDetailWrites` simulates a
        // refused detail write by putting a *file* where this directory would
        // go, so creating it unconditionally would quietly disarm that test.
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
        eventBuses[name] = eventBus
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
        session.backlogViewModel.loadForProject(repoPath: rootURL.path(percentEncoded: false))

        let autopilot = BacklogAutopilot()
        if autopilotReady {
            autopilot.workerAgentID = "worker"
        autopilot.autonomousWorkEnabled = true
            autopilot.reviewerAgentID = "reviewer"
        }
        registry.register(session: session, autopilot: autopilot)
        return session.backlogViewModel
    }

    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appending(path: "catalog.json")),
            packageResolver: nil,
            globalConfigStore: globalConfigStore,
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }

    private func openItemIDs(_ backlog: BacklogViewModel) -> [String] {
        (backlog.backlogFile?.sections.flatMap(\.items) ?? [])
            .filter { !$0.id.hasPrefix("existing-") }
            .map(\.id)
    }

    private func detailPath(_ project: String, _ id: String) -> String {
        tempDir.appending(path: "\(project)/backlog/\(id).md").path(percentEncoded: false)
    }

    private func backlogContents(_ project: String) throws -> String {
        try String(contentsOf: tempDir.appending(path: "\(project)/BACKLOG.md"), encoding: .utf8)
    }

    // MARK: - The futility hold

    /// The scripted stream one drafting call gets — the same two events
    /// `makeRefill(response:)` builds, factored so `.scripted` behaviors can
    /// answer each pass differently.
    private func draftingEvents(_ response: String) -> [StreamEvent] {
        [.assistantText(response),
         .result(.init(text: "", costUSD: 0, durationMs: 0,
                       inputTokens: 0, outputTokens: 0,
                       cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                       sessionID: "stub-session", permissionDenials: []))]
    }

    /// Three passes that groom nothing runnable hold the project: the first
    /// files the ungrounded draft parked at `draft` (ready 0), and the next two
    /// find the same candidate already groomed and end `noDrafts`. The fourth
    /// pass must be held with the streak named — and must not call the model,
    /// which is the entire point of holding.
    func testThreeFutilePassesHoldTheProjectFromTheTimersPasses() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events(draftingEvents(itemsJSON([ungroundedDraft]))))
        let refill = makeRefill(runtime: runtime)
        refill.enabled = true
        try registerProject(named: "alpha", readyItems: 0)

        await refill.runPass()
        await refill.runPass()
        await refill.runPass()
        XCTAssertEqual(refill.groomingHeldProjects["alpha"], 3)

        let callsBefore = runtime.sentPrompts.count
        let outcome = await refill.runPass()
        XCTAssertEqual(outcome.hold?.kind, "groomingHeld")
        XCTAssertEqual(runtime.sentPrompts.count, callsBefore,
                       "a held pass must not reach the drafter")
    }

    /// A pass a human named ignores the hold — the override *is* the release
    /// path, so it grooms (and ends `noDrafts` here) rather than holding.
    func testAHumanNamedPassOverridesTheHold() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events(draftingEvents(itemsJSON([ungroundedDraft]))))
        let refill = makeRefill(runtime: runtime)
        refill.enabled = true
        try registerProject(named: "alpha", readyItems: 0)
        await refill.runPass()
        await refill.runPass()
        await refill.runPass()
        XCTAssertNotNil(refill.groomingHeldProjects["alpha"])

        let callsBefore = runtime.sentPrompts.count
        let outcome = await refill.runPass(forProject: "alpha")
        XCTAssertNil(outcome.hold, "a human-named pass must groom, not hold")
        XCTAssertGreaterThan(runtime.sentPrompts.count, callsBefore)
    }

    /// A pass that files something runnable resets the count: two futile
    /// passes, one that files `ready`, then two more futile — the next pass
    /// still grooms, which it could not if the five had accumulated.
    func testAReadyFilingResetsTheStreak() async throws {
        let runtime = StubHeadlessRuntime(behavior: .scripted([
            draftingEvents(itemsJSON([ungroundedDraft])),   // parked at draft — futile
            draftingEvents(itemsJSON([ungroundedDraft])),   // already groomed → noDrafts
            draftingEvents(itemsJSON([groundedDraft])),     // files ready — reset
            // Script exhausted: every later call repeats the grounded draft,
            // which is already filed, so each ends `noDrafts` — futile again.
        ]))
        let refill = makeRefill(runtime: runtime)
        refill.enabled = true
        try registerProject(named: "alpha", readyItems: 0)

        await refill.runPass()
        await refill.runPass()
        await refill.runPass()
        XCTAssertTrue(refill.groomingHeldProjects.isEmpty, "the ready filing must reset the streak")
        await refill.runPass()
        await refill.runPass()

        // Streak is 2, not 5 — so this one still grooms.
        let outcome = await refill.runPass()
        XCTAssertNil(outcome.hold)
    }

    /// The checks' complaints reach the next drafting prompt, reason and all —
    /// the correction loop that stops a refused mistake being re-made blind.
    func testRefusalReasonsReachTheDraftingPrompt() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events(draftingEvents(itemsJSON([groundedDraft]))))
        let refill = makeRefill(runtime: runtime)
        refill.enabled = true
        try registerProject(named: "alpha", readyItems: 0)
        let projectPath = tempDir.appending(path: "alpha").path(percentEncoded: false)
        groomingLedger.recordCheckFailure(itemID: "phantom-fix",
                                          projectPath: projectPath,
                                          projectName: "alpha",
                                          check: "grounding-check",
                                          reason: "cites Services/NotAFileInThisRepo.swift, which doesn't exist",
                                          at: Date())

        await refill.runPass()

        let prompt = try XCTUnwrap(runtime.sentPrompts.last)
        XCTAssertTrue(prompt.contains("Recently refused by the machine checks"))
        XCTAssertTrue(prompt.contains("cites Services/NotAFileInThisRepo.swift, which doesn't exist"))
    }

    /// A refusal recorded under a path ending in a slash is this project's
    /// refusal: the pass asks with the bare spelling, and the drafter still
    /// hears why the last attempt was turned away.
    func testRefusalsRecordedUnderASlashedPathStillReachTheDraftingPrompt() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events(draftingEvents(itemsJSON([groundedDraft]))))
        let refill = makeRefill(runtime: runtime)
        refill.enabled = true
        try registerProject(named: "alpha", readyItems: 0)
        let projectPath = tempDir.appending(path: "alpha").path(percentEncoded: false)
        groomingLedger.recordCheckFailure(itemID: "phantom-fix",
                                          projectPath: projectPath + "/",
                                          projectName: "alpha",
                                          check: "grounding-check",
                                          reason: "cites Services/NotAFileInThisRepo.swift, which doesn't exist",
                                          at: Date())

        await refill.runPass()

        let prompt = try XCTUnwrap(runtime.sentPrompts.last)
        XCTAssertTrue(prompt.contains("Recently refused by the machine checks"))
        XCTAssertTrue(prompt.contains("cites Services/NotAFileInThisRepo.swift, which doesn't exist"))
    }

    /// And with a clean ledger the section is absent — no empty scaffolding.
    func testACleanLedgerAddsNoRefusalSection() async throws {
        let runtime = StubHeadlessRuntime(behavior: .events(draftingEvents(itemsJSON([groundedDraft]))))
        let refill = makeRefill(runtime: runtime)
        refill.enabled = true
        try registerProject(named: "alpha", readyItems: 0)

        await refill.runPass()

        let prompt = try XCTUnwrap(runtime.sentPrompts.last)
        XCTAssertFalse(prompt.contains("Recently refused by the machine checks"))
    }
}
