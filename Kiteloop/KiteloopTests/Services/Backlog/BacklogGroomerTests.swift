import XCTest
import KiteloopCore
@testable import Kiteloop

/// The groom pass's pure half: what it does with a one-shot reply, before any
/// UI or runtime is involved. `propose` takes only values and a runner
/// closure — the shape that kept two earlier attempts at this item from
/// reaching for `BacklogViewModel` directly — so every rule here is exercised
/// with a canned reply instead of a subprocess.
final class BacklogGroomerTests: XCTestCase {

    // MARK: - Fixtures

    private func item(id: String = "cache-index", verify: String? = nil,
                      size: ItemSize? = nil, needs: [String] = []) -> BacklogItem {
        BacklogItem(id: id, title: "Cache the index", verify: verify, status: .draft,
                    type: .local, size: size, needs: needs)
    }

    private func backlog(items: [BacklogItem] = []) -> BacklogFile {
        BacklogFile(project: "alpha", sections: [BacklogSection(name: "Now", items: items)])
    }

    /// A reply naming everything the gate needs, grounded against `groundedSources`.
    private let goodReply = """
        {"items": [{"id": "someone-elses-id", "title": "Someone else's title", "size": "s",
          "verify": "make test", "what": "The index is built once per run.",
          "how": "Hold it on the autopilot.",
          "validation": ["A queue of five items builds the index once"],
          "outOfScope": ["Persisting the index across launches"]}]}
        """

    private var groundedSources: GroundingCheck.Sources {
        GroundingCheck.Sources(pathExists: { _ in true }, definesSymbol: { _ in true },
                               resolvesExecutable: { _ in true })
    }

    private var ungroundedSources: GroundingCheck.Sources {
        GroundingCheck.Sources(pathExists: { _ in false }, definesSymbol: { _ in false },
                               resolvesExecutable: { _ in false })
    }

    /// A repo where no cited path or symbol exists, so a citation stands or
    /// falls on how it is worded; the `verify:` executable resolves.
    private var nothingExists: GroundingCheck.Sources {
        GroundingCheck.Sources(pathExists: { _ in false }, definesSymbol: { _ in false },
                               resolvesExecutable: { _ in true })
    }

    /// Cites a file that is not there as though it were.
    private let ungroundedReply = """
        {"items": [{"id": "a", "title": "t", "size": "s", "verify": "/bin/echo ok",
          "what": "Update `Services/NotAFile.swift` to do the thing.", "how": "Edit it.",
          "validation": ["It does the thing"]}]}
        """

    /// The same grooming with the file introduced as one the item creates.
    private let correctedReply = """
        {"items": [{"id": "a", "title": "t", "size": "s", "verify": "/bin/echo ok",
          "what": "Add `Services/NotAFile.swift` to do the thing.", "how": "Write it.",
          "validation": ["It does the thing"]}]}
        """

    /// A scripted `runOneShot`: answers its replies in order, the last one
    /// for every call past them, and records each prompt it was sent.
    @MainActor
    private final class Script {
        private let replies: [String]
        private(set) var prompts: [String] = []

        init(_ replies: [String]) { self.replies = replies }

        func reply(_ prompt: String) async throws -> String {
            prompts.append(prompt)
            return replies[min(prompts.count, replies.count) - 1]
        }
    }

    // MARK: - The id and title are the item's, never the model's

    /// A proposal for `cache-index` must never be mistaken for one about
    /// another item, however the model's reply spells its own id and title —
    /// this is what keeps a proposal from landing on the wrong item's page,
    /// the failure a rejected pass at this item shipped once already.
    @MainActor
    func testProposalIDAndTitleAreForcedOntoTheItemNeverTheModelsReply() async throws {
        let proposal = try await BacklogGroomer.propose(
            item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
            runOneShot: { _ in goodReply })

        XCTAssertEqual(proposal.itemID, "cache-index")
        XCTAssertEqual(proposal.draft.id, "cache-index")
        XCTAssertEqual(proposal.draft.title, "Cache the index")
    }

    /// The model is not asked which repositories the item spans; a groom
    /// keeps what the item already named, or the rewrite would drop it.
    @MainActor
    func testAGroomKeepsTheRepositoriesTheItemAlreadyNamed() async throws {
        let spanning = BacklogItemDetail(id: "cache-index", title: "Cache the index", verifyCommands: [],
                                         acceptanceCriteria: [], outOfScope: [], repos: ["library"])

        let proposal = try await BacklogGroomer.propose(
            item: item(), detail: spanning, backlog: backlog(), sources: groundedSources,
            runOneShot: { _ in goodReply })

        XCTAssertEqual(proposal.draft.repos, ["library"])
        XCTAssertTrue(proposal.draft.detailMarkdown().contains("\nrepos: library\n"))
    }

    // MARK: - A reply with nothing usable is refused, not previewed

    @MainActor
    func testAnEmptyReplyThrows() async {
        do {
            _ = try await BacklogGroomer.propose(
                item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
                runOneShot: { _ in "   " })
            XCTFail("an empty reply must not produce a proposal")
        } catch let error as BacklogGroomer.GroomError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    @MainActor
    func testAReplyWithNoUsableDraftThrows() async {
        do {
            _ = try await BacklogGroomer.propose(
                item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
                runOneShot: { _ in "{\"items\": []}" })
            XCTFail("a reply with no draft must not produce a proposal")
        } catch let error as BacklogGroomer.GroomError {
            XCTAssertEqual(error, .noDraft)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    @MainActor
    func testAReplyMissingWhatTheDefinitionOfReadyNeedsThrowsNoDraft() async {
        let missingValidation = """
            {"items": [{"id": "a", "title": "t", "size": "s", "verify": "make",
              "what": "w", "how": "h", "validation": []}]}
            """
        do {
            _ = try await BacklogGroomer.propose(
                item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
                runOneShot: { _ in missingValidation })
            XCTFail("a draft missing Validation is not usable")
        } catch let error as BacklogGroomer.GroomError {
            XCTAssertEqual(error, .noDraft)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Readiness and grounding are judged on the groomed item

    @MainActor
    func testAWellFormedGroundedProposalMeetsBothGates() async throws {
        let proposal = try await BacklogGroomer.propose(
            item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
            runOneShot: { _ in goodReply })

        XCTAssertTrue(proposal.readiness.isReady, proposal.readiness.summary)
        XCTAssertTrue(proposal.grounding.isGrounded, proposal.grounding.summary)
    }

    /// The original item's own `needs:` still governs readiness — a draft that
    /// says nothing about dependencies must not silently clear one the line
    /// already carried.
    @MainActor
    func testAnUnmetDependencyOnTheOriginalItemLeavesTheProposalUnready() async throws {
        let waiting = item(needs: ["schema-migration"])
        let file = backlog(items: [waiting, item(id: "schema-migration")])

        let proposal = try await BacklogGroomer.propose(
            item: waiting, detail: nil, backlog: file, sources: groundedSources,
            runOneShot: { _ in goodReply })

        XCTAssertFalse(proposal.readiness.isReady)
        XCTAssertTrue(proposal.readiness.summary.contains("schema-migration"),
                      proposal.readiness.summary)
    }

    /// A model that never rewords the citation still gets a proposal back to
    /// preview — the last one, with the verdict that refuses it.
    @MainActor
    func testAnUngroundedProposalFailsTheGroundingCheckButStillPreviews() async throws {
        let script = Script([ungroundedReply])

        let proposal = try await BacklogGroomer.propose(
            item: item(), detail: nil, backlog: backlog(), sources: nothingExists,
            runOneShot: script.reply)

        XCTAssertFalse(proposal.grounding.isGrounded)
        XCTAssertTrue(proposal.grounding.summary.contains("NotAFile.swift"),
                      proposal.grounding.summary)
        XCTAssertEqual(script.prompts.count, 1 + BacklogGroomer.maxGroundingCorrections)
    }

    // MARK: - A refused citation goes back to the groomer to reword

    /// The grounding check's refusal reaches the model that wrote the
    /// citation, in the check's own words, and the pass ends at the first
    /// proposal the check accepts.
    @MainActor
    func testAnUngroundedProposalIsHandedBackWithTheVerdictAndTheCorrectionIsReturned() async throws {
        let script = Script([ungroundedReply, correctedReply])

        let proposal = try await BacklogGroomer.propose(
            item: item(), detail: nil, backlog: backlog(), sources: nothingExists,
            runOneShot: script.reply)

        XCTAssertTrue(proposal.grounding.isGrounded, proposal.grounding.summary)
        XCTAssertTrue(proposal.draft.what.hasPrefix("Add `Services/NotAFile.swift`"), proposal.draft.what)
        XCTAssertEqual(proposal.draft.id, "cache-index", "a correction is forced onto the item like the first reply")
        XCTAssertEqual(proposal.draft.title, "Cache the index")
        XCTAssertEqual(script.prompts.count, 2)
        let refused = try await BacklogGroomer.propose(
            item: item(), detail: nil, backlog: backlog(), sources: nothingExists,
            runOneShot: Script([ungroundedReply, "   "]).reply)
        XCTAssertFalse(refused.grounding.summary.isEmpty)
        XCTAssertTrue(script.prompts[1].contains(refused.grounding.summary), script.prompts[1])
        XCTAssertTrue(script.prompts[1].hasPrefix(script.prompts[0]), "the original request is asked again")
        XCTAssertTrue(script.prompts[1].contains("Update `Services/NotAFile.swift` to do the thing."),
                      "the refused proposal is quoted back")
    }

    /// The rounds are bounded: a model that never fixes the citation is asked
    /// once, then `maxGroundingCorrections` more times, and no more.
    @MainActor
    func testCorrectionRoundsStopAtTheBoundAndTheLastVerdictIsReturned() async throws {
        let script = Script([ungroundedReply,
                             ungroundedReply.replacingOccurrences(of: "NotAFile", with: "StillNotAFile")])

        let proposal = try await BacklogGroomer.propose(
            item: item(), detail: nil, backlog: backlog(), sources: nothingExists,
            runOneShot: script.reply)

        XCTAssertEqual(script.prompts.count, 1 + BacklogGroomer.maxGroundingCorrections)
        XCTAssertFalse(proposal.grounding.isGrounded)
        XCTAssertTrue(proposal.grounding.summary.contains("StillNotAFile.swift"),
                      "the verdict is the last proposal's: \(proposal.grounding.summary)")
    }

    @MainActor
    func testAGroundedFirstReplyMakesOneModelCall() async throws {
        let script = Script([goodReply])

        let proposal = try await BacklogGroomer.propose(
            item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
            runOneShot: script.reply)

        XCTAssertTrue(proposal.grounding.isGrounded, proposal.grounding.summary)
        XCTAssertEqual(script.prompts.count, 1)
    }

    /// A correction that comes back empty or with nothing usable ends the
    /// rounds and keeps the proposal there was — it is not an error to show
    /// instead of the preview.
    @MainActor
    func testACorrectionReplyWithNoUsableDraftKeepsTheLastProposal() async throws {
        for unusable in ["   ", "{\"items\": []}"] {
            let script = Script([ungroundedReply, unusable])

            let proposal = try await BacklogGroomer.propose(
                item: item(), detail: nil, backlog: backlog(), sources: nothingExists,
                runOneShot: script.reply)

            XCTAssertEqual(script.prompts.count, 2, "no further round after \(unusable.debugDescription)")
            XCTAssertFalse(proposal.grounding.isGrounded)
            XCTAssertTrue(proposal.draft.what.hasPrefix("Update `Services/NotAFile.swift`"), proposal.draft.what)
        }
    }

    // MARK: - A draft the Planner's bulk grooming wrote is reworded the same way

    private func plannerDraft() -> QueueRefill.Draft {
        QueueRefill.Draft(id: "cache-index", title: "Cache the index", size: "M", verify: "make test",
                          what: "Update `Services/NotAFile.swift` to do the thing.", how: "Edit it.",
                          validation: ["It does the thing"], outOfScope: [], epic: "Now",
                          from: "parent-item", needs: ["first-piece"])
    }

    /// A rewording changes what the correction asked for and nothing else:
    /// where the draft is filed, what it came from and what it waits for are
    /// the draft's own, whatever the reply echoed.
    func testARewordingKeepsTheDraftsIdentityAndPlacement() throws {
        let reworded = try XCTUnwrap(BacklogGroomer.reworded(plannerDraft(), by: goodReply))

        XCTAssertEqual(reworded.id, "cache-index")
        XCTAssertEqual(reworded.title, "Cache the index")
        XCTAssertEqual(reworded.epic, "Now")
        XCTAssertEqual(reworded.from, "parent-item")
        XCTAssertEqual(reworded.needs, ["first-piece"])
        XCTAssertEqual(reworded.what, "The index is built once per run.")
        XCTAssertEqual(reworded.how, "Hold it on the autopilot.")
        XCTAssertEqual(reworded.verify, "make test")
        XCTAssertEqual(reworded.outOfScope, ["Persisting the index across launches"])
    }

    /// A reply answering for several items is read for the one being reworded.
    func testARewordingIsReadFromTheReplysItemWithTheDraftsId() throws {
        let reply = """
            {"items": [{"id": "another-item", "title": "Another", "size": "S", "verify": "make test",
              "what": "Something else.", "how": "Elsewhere.", "validation": ["It works"], "outOfScope": []},
             {"id": "cache-index", "title": "Cache the index", "size": "S", "verify": "make test",
              "what": "The index is cached.", "how": "Cache it.", "validation": ["It is cached"],
              "outOfScope": []}]}
            """
        let reworded = try XCTUnwrap(BacklogGroomer.reworded(plannerDraft(), by: reply))
        XCTAssertEqual(reworded.what, "The index is cached.")
        XCTAssertEqual(reworded.size, "S")
    }

    func testAReplyWithNoUsableDraftRewordsNothing() {
        XCTAssertNil(BacklogGroomer.reworded(plannerDraft(), by: "I could not find the file."))
    }

    /// The correction asks about the one draft, with the turn history, the
    /// refused draft and the check's summary.
    func testThePlannersCorrectionPromptNamesTheDraftTheTurnBudgetAndTheRefusal() {
        let turns = BacklogGroomer.TurnHistory(budget: 50, rows: [])
        let prompt = BacklogGroomer.correctionPrompt(redrafting: plannerDraft(), backlog: backlog(),
                                                     turns: turns, summary: "cites a path that does not exist")

        XCTAssertTrue(prompt.contains("Item id: cache-index"), prompt)
        XCTAssertTrue(prompt.contains("A worker gets 50 turns"), prompt)
        XCTAssertTrue(prompt.contains("Update `Services/NotAFile.swift` to do the thing."), prompt)
        XCTAssertTrue(prompt.contains("cites a path that does not exist"), prompt)
        XCTAssertTrue(prompt.contains("refused by the grounding check"), prompt)
    }

    // MARK: - The prompt carries an existing detail's Out of Scope and Premise

    /// A re-groom must not silently drop what the file already stated: only
    /// What, How and Validation were ever echoed back into the prompt, so a
    /// draft parked with an Out of Scope list or a Premise had both vanish the
    /// moment it was re-groomed.
    func testBuildPromptIncludesExistingOutOfScopeAndPremise() {
        let detail = BacklogItemDetail(
            id: "cache-index", title: "Cache the index", verifyCommands: [],
            acceptanceCriteria: ["It builds once"],
            outOfScope: ["Persisting the index across launches"],
            what: "The index is built once per run.", approach: "Hold it on the autopilot.",
            premise: ["The index is rebuilt on every run today"])

        let prompt = BacklogGroomer.buildPrompt(item: item(), detail: detail, backlog: backlog())

        XCTAssertTrue(prompt.contains("Existing Out of Scope:\n- Persisting the index across launches"),
                      prompt)
        XCTAssertTrue(prompt.contains("Existing Premise:\n- The index is rebuilt on every run today"),
                      prompt)
    }

    // MARK: - The worker's turn budget and what each size took

    private func run(size: String? = "S", turns: Int? = 30, cutShort: Bool? = nil,
                     project: String = "/tmp/alpha") -> TaskMetricRecord {
        let end = Date(timeIntervalSince1970: 1_780_000_000)
        var record = TaskMetricRecord(
            projectPath: project, projectName: "alpha", itemID: "cache-index", title: "Cache the index",
            epic: nil, declaredSize: size, startedAt: end.addingTimeInterval(-600),
            completedAt: end, durationSeconds: 600, costUSD: 0, reviewerRetries: 0,
            outcome: "done", workerAgent: "worker", reviewerAgent: "reviewer",
            executionID: "e-1", toolErrors: nil)
        record.workerTurns = turns
        record.workerCutShort = cutShort
        return record
    }

    func testTurnHistoryHasOneRowPerDeclaredSizeOfThisProjectsRuns() {
        let history = BacklogGroomer.TurnHistory(records: [
            run(size: "M", turns: 50, cutShort: true), run(size: "S", turns: 31, cutShort: false),
            run(size: "S", turns: 12), run(size: "M", turns: 44, cutShort: false),
            run(size: "S", turns: 48), run(size: "M", turns: 50, cutShort: true),
        ], projectPath: "/tmp/alpha", budget: 50)

        XCTAssertEqual(history.budget, 50)
        XCTAssertEqual(history.rows, [
            GroomingTurnHistory.Row(size: "S", runs: 3, median: 31, most: 48, cutShort: 0),
            GroomingTurnHistory.Row(size: "M", runs: 3, median: 50, most: 50, cutShort: 2),
        ])
    }

    func testTurnHistoryLeavesOutAnotherProjectAndRunsMissingTurnsOrASize() {
        let history = BacklogGroomer.TurnHistory(records: [
            run(size: "S", turns: 20),
            run(size: "S", turns: 90, cutShort: true, project: "/tmp/beta"),
            run(size: "S", turns: nil, cutShort: true),
            run(size: nil, turns: 70, cutShort: true),
        ], projectPath: "/tmp/alpha", budget: 50)

        XCTAssertEqual(history.rows, [
            GroomingTurnHistory.Row(size: "S", runs: 1, median: 20, most: 20, cutShort: 0),
        ])
    }

    func testTurnHistoryForNoProjectHasTheBudgetAndNoRows() {
        let history = BacklogGroomer.TurnHistory(records: [run()], projectPath: nil, budget: 50)

        XCTAssertEqual(history.budget, 50)
        XCTAssertTrue(history.rows.isEmpty)
    }

    func testBuildPromptStatesTheTurnBudgetWhatEachSizeTookAndToSplitWhatWillNotFit() {
        let turns = BacklogGroomer.TurnHistory(
            records: [run(size: "S", turns: 31), run(size: "M", turns: 50, cutShort: true)],
            projectPath: "/tmp/alpha", budget: 50)

        let prompt = BacklogGroomer.buildPrompt(item: item(), detail: nil, backlog: backlog(), turns: turns)

        XCTAssertTrue(prompt.contains("A worker gets 50 turns on one item"), prompt)
        XCTAssertTrue(prompt.contains("S: 1 run, median 31, most 31, 0 cut short at the turn limit"), prompt)
        XCTAssertTrue(prompt.contains("M: 1 run, median 50, most 50, 1 cut short at the turn limit"), prompt)
        XCTAssertTrue(prompt.contains("propose a first slice that does"), prompt)
        XCTAssertTrue(prompt.contains("list the rest under Out of Scope"), prompt)
        XCTAssertTrue(prompt.contains("Return ONLY JSON"), prompt)
    }

    func testBuildPromptWithNoMeasuredRunsStillStatesTheBudget() {
        let turns = BacklogGroomer.TurnHistory(records: [], projectPath: "/tmp/alpha", budget: 50)

        let prompt = BacklogGroomer.buildPrompt(item: item(), detail: nil, backlog: backlog(), turns: turns)

        XCTAssertTrue(prompt.contains("A worker gets 50 turns on one item"), prompt)
        XCTAssertTrue(prompt.contains("no measured runs yet"), prompt)
    }

    func testBuildPromptWithoutTurnsSaysNothingAboutABudget() {
        let plain = BacklogGroomer.buildPrompt(item: item(), detail: nil, backlog: backlog())

        XCTAssertEqual(plain, BacklogGroomer.buildPrompt(item: item(), detail: nil, backlog: backlog(),
                                                         turns: nil))
        XCTAssertFalse(plain.contains("turns on one item"), plain)
        XCTAssertFalse(plain.contains("first slice"), plain)
    }

    @MainActor
    func testProposeSendsTheTurnHistoryInItsPrompt() async throws {
        let script = Script([goodReply])
        let turns = BacklogGroomer.TurnHistory(records: [], projectPath: "/tmp/alpha", budget: 50)

        _ = try await BacklogGroomer.propose(item: item(), detail: nil, backlog: backlog(),
                                             sources: groundedSources, turns: turns,
                                             runOneShot: script.reply)

        XCTAssertEqual(script.prompts.count, 1)
        XCTAssertTrue(script.prompts[0].contains("A worker gets 50 turns on one item"), script.prompts[0])
    }
}
