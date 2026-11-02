import XCTest
@testable import Kiteloop
import KiteloopCore

/// The gate between a run and `.kiteloop/coordinator-knowledge.md`, the file
/// every grooming prompt is primed from.
///
/// Only the pure half is asserted here — `costAnomaly`, `isNotable`, `line(for:)`,
/// `notableLines` and `knowledgeURL` need no advisor, no orchestrator and no
/// project on disk. `write(_:to:)` joins them: it is static and takes its
/// destination, so both the landing and the failure can be driven against a
/// temporary directory. `run(events:)` itself is left mostly alone: it makes a
/// model call, and a double for the advisor would assert that the double works.
/// The one exception drives it with events that stay under `isNotable`, so the
/// advisor is never reached — what's under test there is the file it reads and
/// writes, not anything an LLM said.
///
/// A regression in any of these is silent. Loosen `isNotable` and every clean
/// marathon buys an LLM call it has nothing to learn from; tighten it and the
/// loop simply stops learning, with a knowledge file that quietly stops growing
/// as the only symptom.
@MainActor
final class RunKnowledgeDistillerTests: XCTestCase {

    /// A run that went the way runs are supposed to go: merged on the first
    /// review, at roughly what it was forecast to cost, judged well. Every
    /// notability test below is this event with exactly one fact changed, so a
    /// passing assertion names the trigger that fired.
    private func cleanEvent(
        itemID: String = "quiet-item",
        outcome: String = "merged",
        merged: Bool = true,
        mergeAttempted: Bool = true,
        costUSD: Double = 1.2,
        predictedCostUSD: Double? = 1.0,
        reviewerRetries: Int = 0,
        qualityScore: Double? = 0.9,
        stalled: Bool = false
    ) -> RunKnowledgeDistiller.Event {
        RunKnowledgeDistiller.Event(itemID: itemID, outcome: outcome, merged: merged,
                                    mergeAttempted: mergeAttempted, costUSD: costUSD,
                                    predictedCostUSD: predictedCostUSD,
                                    reviewerRetries: reviewerRetries,
                                    qualityScore: qualityScore, stalled: stalled)
    }

    // MARK: - Cost anomaly

    /// No forecast is not a cheap forecast. An item nobody predicted a cost for
    /// cannot overrun one, and treating the missing number as zero would make
    /// every unpredicted item surprising.
    func testNoPredictionIsNeverAnAnomaly() {
        XCTAssertFalse(RunKnowledgeDistiller.costAnomaly(actual: 500, predicted: nil))
        XCTAssertFalse(RunKnowledgeDistiller.costAnomaly(actual: 500, predicted: 0))
    }

    func testTheThresholdItselfIsNotAnAnomaly() {
        let predicted = 2.0
        let atThreshold = predicted * RunKnowledgeDistiller.costAnomalyFactor

        XCTAssertFalse(RunKnowledgeDistiller.costAnomaly(actual: atThreshold, predicted: predicted),
                       "the comparison is strictly greater than — exactly the factor is the budget met")
        XCTAssertTrue(RunKnowledgeDistiller.costAnomaly(actual: atThreshold + 0.01, predicted: predicted))
    }

    func testComingInUnderTheForecastIsNotAnAnomaly() {
        XCTAssertFalse(RunKnowledgeDistiller.costAnomaly(actual: 0.1, predicted: 4.0))
    }

    // MARK: - What is worth an LLM call

    func testACleanCheapMergedUnretriedItemTeachesNothing() {
        XCTAssertFalse(RunKnowledgeDistiller.isNotable(cleanEvent()))
    }

    func testABlockedOutcomeIsNotable() {
        XCTAssertTrue(RunKnowledgeDistiller.isNotable(cleanEvent(outcome: "Blocked: needs a decision")))
    }

    func testACancelledOutcomeIsNotable() {
        XCTAssertTrue(RunKnowledgeDistiller.isNotable(cleanEvent(outcome: "cancelled by operator")))
    }

    /// Two spellings of the same fact, and both have to fire: a run can report a
    /// stall in its outcome text without the flag, and can set the flag while
    /// the outcome reads as something else.
    func testAStallIsNotableByOutcomeTextAndByFlag() {
        XCTAssertTrue(RunKnowledgeDistiller.isNotable(cleanEvent(outcome: "stalled waiting on review")))
        XCTAssertTrue(RunKnowledgeDistiller.isNotable(cleanEvent(stalled: true)))
    }

    /// Passing review and still not landing is the shape worth remembering — a
    /// merge conflict, a merge-verify failure, a gate nobody cleared.
    func testAnAttemptedMergeThatDidNotLandIsNotable() {
        XCTAssertTrue(RunKnowledgeDistiller.isNotable(cleanEvent(merged: false, mergeAttempted: true)))
    }

    func testACostAnomalyIsNotable() {
        XCTAssertTrue(RunKnowledgeDistiller.isNotable(cleanEvent(costUSD: 9.0, predictedCostUSD: 1.0)))
    }

    func testAQualityScoreBelowTheFloorIsNotable() {
        let bad = RunKnowledgeDistiller.qualityFloor - 0.01
        XCTAssertTrue(RunKnowledgeDistiller.isNotable(cleanEvent(qualityScore: bad)))
    }

    /// One retry, not several — needing the reviewer twice is already the signal.
    func testAnyReviewerRetryIsNotable() {
        XCTAssertTrue(RunKnowledgeDistiller.isNotable(cleanEvent(reviewerRetries: 1)))
    }

    func testAQualityScoreExactlyAtTheFloorIsNotNotable() {
        XCTAssertFalse(RunKnowledgeDistiller.isNotable(cleanEvent(qualityScore: RunKnowledgeDistiller.qualityFloor)),
                       "the floor is the lowest acceptable score, not the first bad one")
    }

    /// An item that never reached a merge did not fail to merge. Without the
    /// `mergeAttempted` guard every non-merging outcome — a review rejection, a
    /// dry run — would read as a failed landing.
    func testAMergeThatWasNeverAttemptedIsNotNotableHoweverItEnded() {
        XCTAssertFalse(RunKnowledgeDistiller.isNotable(cleanEvent(merged: false, mergeAttempted: false)))
        XCTAssertFalse(RunKnowledgeDistiller.isNotable(cleanEvent(merged: true, mergeAttempted: false)))
    }

    // MARK: - What the distiller is handed

    func testAnUneventfulRunIsHandedNothing() {
        let events = [cleanEvent(itemID: "a"), cleanEvent(itemID: "b"), cleanEvent(itemID: "c")]

        XCTAssertEqual(RunKnowledgeDistiller.notableLines(events), [],
                       "a marathon of clean items must cost no LLM call")
    }

    /// One bad item opens the whole run, not just itself: what blocked is
    /// explained by what the run was doing around it.
    func testOneNotableItemCarriesTheWholeRunThrough() {
        let events = [cleanEvent(itemID: "a"),
                      cleanEvent(itemID: "b", outcome: "blocked"),
                      cleanEvent(itemID: "c")]

        let lines = RunKnowledgeDistiller.notableLines(events)

        XCTAssertEqual(lines.count, 3, "the quiet items are context, not noise to be filtered")
        XCTAssertEqual(lines, events.map(RunKnowledgeDistiller.line(for:)))
    }

    func testNoEventsAtAllIsNothingToDistil() {
        XCTAssertEqual(RunKnowledgeDistiller.notableLines([]), [])
    }

    // MARK: - The line shape

    /// Absent and zero facts are left out rather than written as `predicted=nil`
    /// or `reviewerRetries=0` — the line is read by a model, and a field that is
    /// always present says nothing by being there.
    func testAnUnremarkableItemsLineCarriesOnlyItsIdOutcomeAndCost() {
        let line = RunKnowledgeDistiller.line(for: cleanEvent(itemID: "quiet", outcome: "merged",
                                                             mergeAttempted: false, costUSD: 0.5,
                                                             predictedCostUSD: nil, qualityScore: nil))

        XCTAssertEqual(line, "item=quiet outcome=merged cost=0.50")
    }

    func testEveryFactPresentIsWrittenInOrderAtTwoDecimalPlaces() {
        let line = RunKnowledgeDistiller.line(for: cleanEvent(itemID: "loud", outcome: "blocked",
                                                             merged: false, mergeAttempted: true,
                                                             costUSD: 12.5, predictedCostUSD: 1.0,
                                                             reviewerRetries: 2, qualityScore: 0.25,
                                                             stalled: true))

        XCTAssertEqual(line, "item=loud outcome=blocked cost=12.50 predicted=1.00 merged=false"
                       + " reviewerRetries=2 quality=0.25 stalled=true")
    }

    /// `merged` is written whenever the merge was attempted, including when it
    /// succeeded — the distiller reads the successful landings as the baseline
    /// the failed ones are surprising against.
    func testAnAttemptedMergeIsWrittenEitherWayItWent() {
        XCTAssertTrue(RunKnowledgeDistiller.line(for: cleanEvent(merged: true, mergeAttempted: true))
            .contains(" merged=true"))
        XCTAssertTrue(RunKnowledgeDistiller.line(for: cleanEvent(merged: false, mergeAttempted: true))
            .contains(" merged=false"))
        XCTAssertFalse(RunKnowledgeDistiller.line(for: cleanEvent(merged: false, mergeAttempted: false))
            .contains("merged="))
    }

    func testZeroRetriesAndACalmRunAreOmittedRatherThanWrittenAsZero() {
        let line = RunKnowledgeDistiller.line(for: cleanEvent(reviewerRetries: 0, stalled: false))

        XCTAssertFalse(line.contains("reviewerRetries"))
        XCTAssertFalse(line.contains("stalled"))
    }

    // MARK: - What the override ledger teaches

    private func override(_ findingClass: String, itemID: String = "task-1", at: Date = Date())
        -> FindingOverrideLedger.Record {
        FindingOverrideLedger.Record(itemID: itemID, findingClass: findingClass, at: at)
    }

    /// A class overridden 6 of 7 times clears both thresholds (6 ≥ 5, 6/7 ≈
    /// 86% ≥ 60%); a class overridden once out of the same 7 clears neither —
    /// only the first gets a line.
    func testAClassOverBothThresholdsGetsExactlyOneLineNamingItAndTheCount() {
        let sixOfOneClass = (1...6).map { override("blocking: md missing changelog", itemID: "task-\($0)") }
        let oneOfAnother = [override("blocking: swift unrelated nit", itemID: "task-7")]

        let lines = RunKnowledgeDistiller.overrideLines(sixOfOneClass + oneOfAnother, existingKnowledge: "")

        XCTAssertEqual(lines.count, 1, "only the class over threshold gets a line")
        XCTAssertTrue(lines[0].contains("blocking: md missing changelog"), lines[0])
        XCTAssertTrue(lines[0].contains("6 of 7"), lines[0])
    }

    /// Four overrides of the only class in the ledger fail the count threshold
    /// even though the rate is 100% — the count has to clear 5 on its own.
    func testFourOverridesOfOneClassWritesNothing() {
        let overrides = (1...4).map { override("blocking: md missing changelog", itemID: "task-\($0)") }

        XCTAssertEqual(RunKnowledgeDistiller.overrideLines(overrides, existingKnowledge: ""), [])
    }

    /// No overrides at all is the ordinary case, not an error.
    func testAnEmptyLedgerWritesNothing() {
        XCTAssertEqual(RunKnowledgeDistiller.overrideLines([], existingKnowledge: ""), [])
    }

    /// The rate is against the ledger's own total, not against some external
    /// count of how often the class was raised: five overrides in a ledger of
    /// twenty (25%) never crosses the 60% floor, however many times the class
    /// itself recurred.
    func testACountAboveThresholdWithARateBelowItWritesNothing() {
        let fiveOfOneClass = (1...5).map { override("blocking: md missing changelog", itemID: "task-\($0)") }
        let fifteenOfAnother = (6...20).map { override("blocking: swift nit \($0)", itemID: "task-\($0)") }

        let lines = RunKnowledgeDistiller.overrideLines(fiveOfOneClass + fifteenOfAnother, existingKnowledge: "")

        XCTAssertEqual(lines, [], "5 of 20 is 25% — under the 60% rate floor despite clearing the count")
    }

    /// The class already has a bullet in the knowledge file — matched on the
    /// stable lead-in, not the whole sentence, whose counts move on every run.
    /// Re-filing it would evict something else the auto section holds every
    /// time this class stays over threshold.
    func testAClassAlreadyCarriedInTheKnowledgeFileWritesNothing() {
        let sevenOfOneClass = (1...7).map { override("blocking: swift missing tests", itemID: "task-\($0)") }
        let existing = "## Learned (auto)\n"
            + "- `blocking: swift missing tests` findings were overridden 5 of 6 times since 2026-09-01\n"

        let lines = RunKnowledgeDistiller.overrideLines(sevenOfOneClass, existingKnowledge: existing)

        XCTAssertEqual(lines, [], "the file already carries this class's lesson, however stale its counts")
    }

    /// A class the file has never mentioned still gets its line even when the
    /// file already carries a bullet for some other class.
    func testAnUnmentionedClassStillGetsALineWhenTheFileCarriesOthers() {
        let sixOfOneClass = (1...6).map { override("blocking: md missing changelog", itemID: "task-\($0)") }
        let existing = "## Learned (auto)\n- `blocking: swift missing tests` findings were overridden 5 of 6 times"
            + " since 2026-09-01\n"

        let lines = RunKnowledgeDistiller.overrideLines(sixOfOneClass, existingKnowledge: existing)

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("blocking: md missing changelog"), lines[0])
    }

    /// `since` is this class's own earliest override, not the ledger-wide
    /// minimum — a class whose overrides are all from today is not reported as
    /// running since another class's much older first override.
    func testSinceIsTheClasssOwnEarliestOverrideNotTheLedgersMinimum() {
        let calendar = Calendar(identifier: .gregorian)
        let today = Date()
        let fortyDaysAgo = calendar.date(byAdding: .day, value: -40, to: today)!
        let oldClass = (1...2).map { override("blocking: swift unrelated nit", itemID: "old-\($0)", at: fortyDaysAgo) }
        let newClass = (1...6).map { override("blocking: swift missing tests", itemID: "new-\($0)", at: today) }

        let lines = RunKnowledgeDistiller.overrideLines(oldClass + newClass, existingKnowledge: "")

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")

        let newClassLine = lines.first { $0.contains("blocking: swift missing tests") }
        XCTAssertNotNil(newClassLine)
        XCTAssertTrue(newClassLine!.contains("since \(dayFormatter.string(from: today))"), newClassLine!)
        XCTAssertFalse(newClassLine!.contains(dayFormatter.string(from: fortyDaysAgo)), newClassLine!)
    }

    /// The end-to-end shape the bug was about: a class over threshold on one
    /// run, still over threshold with a fatter ledger the next, must leave the
    /// merged file with one bullet for it rather than a new one alongside the
    /// stale first.
    func testTwoConsecutiveDistillerPassesOverAGrowingLedgerLeaveOneBulletForTheClass() {
        let firstLedger = (1...6).map { override("blocking: swift missing tests", itemID: "task-\($0)") }
        let firstLines = RunKnowledgeDistiller.overrideLines(firstLedger, existingKnowledge: "")
        let afterFirst = CoordinatorKnowledge.merge(existing: "", newLearnings: firstLines)

        let secondLedger = firstLedger + [override("blocking: swift missing tests", itemID: "task-7")]
        let secondLines = RunKnowledgeDistiller.overrideLines(secondLedger, existingKnowledge: afterFirst)
        let afterSecond = CoordinatorKnowledge.merge(existing: afterFirst, newLearnings: secondLines)

        XCTAssertEqual(CoordinatorKnowledge.bulletCount(in: afterSecond), 1,
                       "the second pass's restated counts must not read as a new bullet")
    }

    /// The shape this item was reopened over: the first fix stopped a *read*
    /// that was blind to the class's own bullet from making it look unfiled.
    /// It missed the *write* side of the same failure — `CoordinatorKnowledge
    /// .merge`'s cap ages bullets out oldest-first with no regard for which one
    /// is a ledger-backed lesson, so a long enough run of unrelated learnings
    /// (exactly what a busy project produces) evicts it exactly as the capped
    /// read once did, and the very next pass sees a file that has never
    /// mentioned the class and re-derives the identical line.
    func testAnOverrideLessonSurvivesAFloodOfUnrelatedLearningsPastTheCap() {
        let ledger = (1...6).map { override("blocking: swift missing tests", itemID: "task-\($0)") }
        var knowledge = CoordinatorKnowledge.merge(
            existing: "", newLearnings: RunKnowledgeDistiller.overrideLines(ledger, existingKnowledge: ""))
        XCTAssertTrue(knowledge.contains("blocking: swift missing tests"))

        for i in 0..<(CoordinatorKnowledge.maxAutoEntries * 2) {
            let refiled = RunKnowledgeDistiller.overrideLines(ledger, existingKnowledge: knowledge)
            XCTAssertEqual(refiled, [], "pass \(i): the class's bullet is still on file, so this must stay quiet")
            knowledge = CoordinatorKnowledge.merge(existing: knowledge,
                                                   newLearnings: refiled + ["distinct unrelated learning number \(i)"])
        }

        XCTAssertTrue(knowledge.contains("blocking: swift missing tests"),
                      "the override lesson must outlast the flood, not get evicted and silently re-filed")
    }

    /// The end-to-end shape the escaped defect was about: `overrideLines`'s own
    /// dedup only ever saw what a test handed it directly, never a knowledge file
    /// read the way `run(events:)` actually reads one — through
    /// `CoordinatorAdvisor.loadKiteloopFile`, which caps at
    /// `CoordinatorAdvisor.readBudget` and drops whole bullets from the oldest
    /// end. A file whose auto section has grown past that budget, with the
    /// override class's own bullet among the dropped, made the capped read look
    /// exactly like a file that had never mentioned the class — so the dedup
    /// guard let it through and `run` filed a second bullet, and the write that
    /// followed carried only the capped text back to disk, permanently losing
    /// whatever the cap had dropped. Reading the file raw for the dedup check and
    /// the merge, capped only for the prompt, is what closes both holes.
    func testARunOverAKnowledgeFileGrownPastTheReadBudgetDoesNotRefileAnAgedOutOverrideLesson() async throws {
        let project = try temporaryDirectory().appending(path: "repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let findingClass = "blocking: swift missing tests"

        // The override class's own bullet sits right after the header — the
        // oldest position, and so the first a budget-capped read would drop —
        // followed by enough padding bullets to push the file past readBudget.
        var contents = "# Coordinator knowledge\n\n\(CoordinatorKnowledge.autoHeader)\n"
        contents += "- `\(findingClass)` findings were overridden 5 of 6 times since 2026-08-01\n"
        for i in 0..<200 { contents += "- padding learning number \(i) fills out the rest of the file\n" }
        let knowledgeURL = project.appending(path: ".kiteloop/coordinator-knowledge.md")
        try FileManager.default.createDirectory(at: knowledgeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: knowledgeURL, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(contents.count, CoordinatorAdvisor.readBudget)
        XCTAssertFalse(CoordinatorAdvisor.loadKiteloopFile(projectPath: project.path,
                                                           name: CoordinatorKnowledge.fileName)!.contains(findingClass),
                       "the capped read must be the one that has already lost the class's bullet")

        // The class is still over both thresholds — the ledger alone would tell
        // `overrideLines` to file it again.
        let ledgerURL = FindingOverrideLedger.url(projectPath: project.path)
        for i in 1...6 {
            try FindingOverrideLedger.append(.init(itemID: "task-\(i)", findingClass: findingClass, at: Date()),
                                             to: ledgerURL)
        }

        let tempConfig = try temporaryDirectory().appending(path: "global.json")
        let advisor = CoordinatorAdvisor(runtimeFactory: { MockAgentRuntime() },
                                         globalConfigStore: GlobalConfigStore(storageURL: tempConfig))
        let distiller = RunKnowledgeDistiller(advisor: advisor, projectPath: project.path)

        // No notable event: the advisor is never called, only the override path runs.
        let learned = await distiller.run(events: [cleanEvent()])

        XCTAssertEqual(learned, [], "the file already carries this class's lesson, however the read cut it off")
        let written = try XCTUnwrap(try? String(contentsOf: knowledgeURL, encoding: .utf8))
        let classBullets = written.components(separatedBy: "\n").filter { $0.contains(findingClass) }
        XCTAssertEqual(classBullets.count, 1, "exactly one bullet for the class, not a second one alongside the first")
        XCTAssertTrue(written.contains("padding learning number 0 "),
                      "the write must not have truncated the rest of the file down to the read budget")
    }

    // MARK: - Where the notes live

    func testTheKnowledgeFileSitsInTheProjectsKiteloopDirectory() {
        let url = RunKnowledgeDistiller.knowledgeURL(projectPath: "/Users/someone/code/demo")

        XCTAssertEqual(url.path, "/Users/someone/code/demo/.kiteloop/coordinator-knowledge.md")
    }

    // MARK: - Whether the notes landed

    /// A directory that dies with the test, so a case can build a project — or a
    /// deliberately broken one — on disk.
    private func temporaryDirectory() throws -> URL {
        try makeTemporaryDirectory(prefix: "RunKnowledgeDistillerTests")
    }

    /// The `.kiteloop` directory is made on the way, so a project whose first run
    /// is also its first notable one still gets its notes.
    func testAWriteToAFreshProjectMakesTheDirectoryAndLeavesTheContent() throws {
        let project = try temporaryDirectory().appending(path: "repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let url = RunKnowledgeDistiller.knowledgeURL(projectPath: project.path)
        let merged = "# Coordinator knowledge\n\n## Learned (auto)\n- the reviewer stage is effectively uncapped\n"

        try RunKnowledgeDistiller.write(merged, to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), merged)
    }

    /// A second run overwrites rather than appends — the merge happened before
    /// the write, and what it produced is the whole file.
    func testAWriteReplacesWhatWasThereBefore() throws {
        let project = try temporaryDirectory()
        let url = RunKnowledgeDistiller.knowledgeURL(projectPath: project.path)

        try RunKnowledgeDistiller.write("first", to: url)
        try RunKnowledgeDistiller.write("second", to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second")
    }

    /// The directory can't be made because the project path is a file. Both
    /// swallowed `try?`s used to make this look exactly like a run that landed,
    /// so the caller announced learnings over a file that never changed.
    func testAWriteBeneathAFileIsReportedRatherThanSwallowed() throws {
        let root = try temporaryDirectory()
        let notADirectory = root.appending(path: "repo")
        try Data("I am a file".utf8).write(to: notADirectory)
        let url = RunKnowledgeDistiller.knowledgeURL(projectPath: notADirectory.path)

        XCTAssertThrowsError(try RunKnowledgeDistiller.write("learnings", to: url),
                             "the .kiteloop directory cannot be made under a regular file")
    }

    /// The other half of the same failure: the directory is fine and the write
    /// itself is what cannot land. Asserted separately because these were two
    /// distinct `try?`s, and reporting one while swallowing the other would leave
    /// the same lie in place for half the cases.
    func testAWriteOntoAnUnwritableDestinationIsReportedRatherThanSwallowed() throws {
        let project = try temporaryDirectory()
        let url = RunKnowledgeDistiller.knowledgeURL(projectPath: project.path)
        // A directory standing where the file goes: the enclosing `.kiteloop` is
        // made without complaint, and only the write fails.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        XCTAssertThrowsError(try RunKnowledgeDistiller.write("learnings", to: url),
                             "data cannot be written over a directory")
    }
}
