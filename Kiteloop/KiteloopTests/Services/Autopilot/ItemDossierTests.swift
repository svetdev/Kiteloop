import XCTest
import KiteloopCore
@testable import Kiteloop

/// The three rules the item detail view turns on: where a ledger and git
/// disagree both are shown, the actions offered are the ones the item's state
/// actually permits — with a reason attached to every one that isn't — and the
/// Definition-of-Ready verdict is laid out clause by clause in the gate's own
/// words.
final class ItemDossierTests: XCTestCase {

    // MARK: - Disagreements

    /// The one that cost five items on 2026-08-09: marked Done, with the commits
    /// on a branch `main` had never seen.
    func testDoneOverAnUnmergedBranchIsADisagreement() {
        let conflicts = ItemDisagreements.detect(
            status: .done, latestRun: run(outcome: "done", merged: true),
            git: truth(presence: .present, merged: false, ahead: 4))

        XCTAssertEqual(conflicts.count, 2)
        XCTAssertEqual(conflicts[0].ledgerSays, "the item is Done")
        XCTAssertTrue(conflicts[0].gitSays.contains("is not merged"), conflicts[0].gitSays)
        XCTAssertEqual(conflicts[1].ledgerSays, "the last run recorded a merge")
    }

    /// Work recorded against a branch that no longer exists. The commits may be
    /// dangling rather than gone, and a reader has to be told to go looking.
    func testRecordedWorkWithNoBranchIsADisagreement() {
        let conflicts = ItemDisagreements.detect(
            status: .ready, latestRun: run(outcome: "blocked", changedFileCount: 6),
            git: truth(presence: .absent))

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].ledgerSays, "the last run recorded 6 changed files")
        XCTAssertTrue(conflicts[0].gitSays.contains("no branch"), conflicts[0].gitSays)
    }

    /// Done, no branch, and this item's commits still in the object store: the
    /// unmerged-branch case with the ref deleted out from under it. Teardown
    /// dropped the branch, and nothing has reached `HEAD`.
    func testDoneOverADroppedBranchWhoseCommitsSurviveIsADisagreement() {
        let conflicts = ItemDisagreements.detect(
            status: .done, latestRun: nil,
            git: truth(presence: .absent, orphaned: true))

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].ledgerSays, "the item is Done")
        XCTAssertEqual(conflicts[0].gitSays, "there is no branch kiteloop/item-1 — its "
                       + "commits are still in the object store, unreferenced")
    }

    /// A missing branch is not the finding — surviving commits are. An item that
    /// merged and had its branch tidied away is what done is supposed to look
    /// like, and so is one whose object store was never asked.
    func testDoneWithNoBranchAndNothingSurvivingIsNotADisagreement() {
        let tidied = ItemDisagreements.detect(
            status: .done, latestRun: nil, git: truth(presence: .absent, orphaned: false))
        let unasked = ItemDisagreements.detect(
            status: .done, latestRun: nil, git: truth(presence: .absent))

        XCTAssertTrue(tidied.isEmpty, "\(tidied)")
        XCTAssertTrue(unasked.isEmpty, "\(unasked)")
    }

    /// One absence, one sentence. When the run record has already reported the
    /// branch as gone, saying it again in different words would leave a reader
    /// looking for two findings where there is one condition — the surviving
    /// commits are in the view's header either way (`ItemGitTruth.summary`).
    func testAMissingBranchIsDescribedOnceWhenTheRunRecordAlreadySaidSo() {
        let conflicts = ItemDisagreements.detect(
            status: .done, latestRun: run(outcome: "done", changedFileCount: 6),
            git: truth(presence: .absent, orphaned: true))

        XCTAssertEqual(conflicts.count, 1, "\(conflicts)")
        XCTAssertEqual(conflicts[0].ledgerSays, "the last run recorded 6 changed files")
        XCTAssertEqual(conflicts[0].gitSays, "there is no branch kiteloop/item-1 now")
    }

    /// The mirror image, and the one a run log reports most confidently:
    /// "produced no work" over a branch that carries commits.
    func testAnEmptyRunOverACarryingBranchIsADisagreement() {
        let conflicts = ItemDisagreements.detect(
            status: .ready,
            latestRun: run(outcome: "blocked:\(RunWorkEvidence.noWorkPrefix) — no branch",
                           changedFileCount: 0),
            git: truth(presence: .present, merged: false, ahead: 2))

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].ledgerSays,
                       "the last run is recorded as having produced no work")
    }

    /// A run nobody could judge is not a run that produced nothing. Reporting
    /// one as "produced no work" puts a sentence in the ledger's mouth it never
    /// said, on every interrupted run over a branch that carries commits.
    ///
    /// This is the first of the two `.unknown` readings: an outcome that vetoes
    /// the file count because no verdict was ever routed.
    func testARunThatReachedNoVerdictOverACarryingBranchIsNotADisagreement() {
        for outcome in TaskMetricRecord.outcomesReachingNoVerdict {
            let conflicts = ItemDisagreements.detect(
                status: .ready,
                latestRun: run(outcome: outcome, changedFileCount: 6),
                git: truth(presence: .present, merged: false, ahead: 2))

            XCTAssertEqual(run(outcome: outcome, changedFileCount: 6).workEvidence, .unknown)
            XCTAssertTrue(conflicts.isEmpty, "\(outcome): \(conflicts)")
        }
    }

    /// The second reading: no file count was recorded at all, and the outcome
    /// answers neither way. Nobody measured, so the list says nothing.
    func testARunWithNothingMeasuredOverACarryingBranchIsNotADisagreement() {
        let unmeasured = run(outcome: "blocked:worker timed out")

        XCTAssertEqual(unmeasured.workEvidence, .unknown)
        XCTAssertTrue(ItemDisagreements.detect(
            status: .ready, latestRun: unmeasured,
            git: truth(presence: .present, merged: false, ahead: 2)).isEmpty)
    }

    /// Merged work under an item nobody moved on — the same defect from the
    /// other end.
    func testMergedWorkUnderAnUnfinishedItemIsADisagreement() {
        let conflicts = ItemDisagreements.detect(
            status: .ready, latestRun: nil,
            git: truth(presence: .present, merged: true, ahead: 0))

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].ledgerSays, "the item is Ready")
    }

    /// A project with no repository leaves every git question open. "Nobody
    /// could tell" is not a conflict, and reporting it as one would put a
    /// permanent false alarm on every non-git project.
    func testAnUnreadableRepoIsNotADisagreement() {
        let conflicts = ItemDisagreements.detect(
            status: .done, latestRun: run(outcome: "done", merged: true),
            git: .unreadable(branch: "kiteloop/i"))

        XCTAssertTrue(conflicts.isEmpty)
    }

    /// The ordinary case: done, merged, nothing left on the branch.
    func testAgreementProducesNothing() {
        let conflicts = ItemDisagreements.detect(
            status: .done, latestRun: run(outcome: "done", merged: true, changedFileCount: 3),
            git: truth(presence: .present, merged: true, ahead: 0))

        XCTAssertTrue(conflicts.isEmpty, "\(conflicts)")
    }

    // MARK: - Actions

    /// Every action is always offered — a hidden one is indistinguishable from
    /// one that does not exist — and the ones that can't be taken say why.
    func testEveryActionIsOfferedAndUnavailableOnesCarryAReason() {
        let actions = ItemActions.offered(context(status: .ready))

        XCTAssertEqual(actions.map(\.kind), ItemAction.Kind.allCases)
        XCTAssertEqual(actions.first { $0.kind == .unblock }?.unavailable,
                       "the item is Ready, not blocked")
        XCTAssertNil(ItemActions.offered(context(status: .blocked)).first { $0.kind == .unblock }?.unavailable,
                     "a blocked item is the one an Unblock is for")
        for action in actions where !action.isAvailable {
            XCTAssertFalse(action.unavailable?.isEmpty ?? true,
                           "\(action.kind) is unavailable with no reason")
        }
    }

    func testARunnableItemOffersRun() {
        let actions = ItemActions.offered(context(status: .ready))

        XCTAssertNil(actions.first { $0.kind == .run }?.unavailable)
    }

    /// The stage refusal names the stages autopilot actually starts from, so the
    /// reader knows what would have to change.
    func testAnItemOutsideAPickupStageCannotRunAndSaysWhichStagesDo() {
        let actions = ItemActions.offered(context(status: .done))

        let reason = actions.first { $0.kind == .run }?.unavailable
        XCTAssertEqual(reason, "autopilot starts items at Ready — this one is Done")
    }

    /// A run somewhere else in the project blocks this one, and says so by name
    /// — "one at a time per project" is the rule, not a mystery.
    func testARunInFlightElsewhereBlocksTheRunAndNamesIt() {
        let actions = ItemActions.offered(context(status: .ready, inFlight: "other-item"))

        XCTAssertEqual(actions.first { $0.kind == .run }?.unavailable,
                       "a run is already in flight on other-item — one at a time per project")
    }

    /// Cancel is about *this* item. Offering it from an item nobody is running
    /// would let a reader stop a run they were not looking at.
    func testCancelIsOnlyOfferedForTheItemInFlight() {
        let mine = ItemActions.offered(context(status: .active, inFlight: "item-1"))
        let theirs = ItemActions.offered(context(status: .ready, inFlight: "other-item"))
        let none = ItemActions.offered(context(status: .ready))

        XCTAssertNil(mine.first { $0.kind == .cancel }?.unavailable)
        XCTAssertEqual(theirs.first { $0.kind == .cancel }?.unavailable,
                       "the run in flight is on other-item, not this item")
        XCTAssertEqual(none.first { $0.kind == .cancel }?.unavailable,
                       "nothing is running for this item")
    }

    func testApproveAndRejectAreOnlyOfferedAtTheGate() {
        let gated = ItemActions.offered(context(status: .awaitingApproval))
        let notGated = ItemActions.offered(context(status: .ready))

        XCTAssertNil(gated.first { $0.kind == .approve }?.unavailable)
        XCTAssertNil(gated.first { $0.kind == .reject }?.unavailable)
        XCTAssertEqual(notGated.first { $0.kind == .approve }?.unavailable,
                       "the item is Ready, not at the approval gate")
    }

    /// Approving merges, so a project with no repository behind it cannot offer
    /// it — and says that rather than the stage reason, which would be wrong.
    func testApproveNeedsARepositoryToMergeFrom() {
        let actions = ItemActions.offered(context(status: .awaitingApproval, hasProjectRoot: false))

        XCTAssertEqual(actions.first { $0.kind == .approve }?.unavailable,
                       "no project root — there is no repository to merge from")
    }

    func testReleaseIsOnlyOfferedForARetiredItem() {
        let retired = ItemActions.offered(context(status: .ready, isRetired: true))
        let notRetired = ItemActions.offered(context(status: .ready))

        XCTAssertNil(retired.first { $0.kind == .release }?.unavailable)
        XCTAssertEqual(notRetired.first { $0.kind == .release }?.unavailable,
                       "not retired — the retry ceiling has nothing to release")
    }

    /// A retired item is refused at pickup, so Run says the thing that would fix
    /// it rather than the thing that is merely true.
    func testARetiredItemCannotRunAndIsToldToReleaseFirst() {
        let actions = ItemActions.offered(context(status: .ready, isRetired: true))

        XCTAssertEqual(actions.first { $0.kind == .run }?.unavailable,
                       "retired by the retry ceiling — release it before it runs again")
    }

    // MARK: - Actions: the Definition-of-Ready gate

    /// An ungroomed item is the one autopilot accepts and then drops at pickup,
    /// leaving "Started a run" on screen and the refusal in the run log. Run is
    /// disabled instead, naming every clause the gate found unmet.
    func testAnUngroomedItemCannotRunAndNamesTheUnmetClauses() {
        let verdict = DefinitionOfReady.evaluate(
            item: backlogItem(verify: nil, size: nil),
            detail: groomedDetail(what: nil, approach: nil, criteria: [], verify: []))
        let actions = ItemActions.offered(context(status: .ready, readiness: verdict))

        let reason = actions.first { $0.kind == .run }?.unavailable
        XCTAssertEqual(reason, "detail file has no What section; detail file has no How "
                       + "section; detail file has no Validation criteria; no verify: command "
                       + "— nothing objective for the run to pass; no size set — autopilot "
                       + "runs XS/S/M")
    }

    /// The reason is the gate's own summary rather than a second wording kept
    /// beside it — the two would drift, and the log and the button would then
    /// give different accounts of the same refusal.
    func testTheRunReasonIsTheGatesOwnSummary() {
        let refused: [(BacklogItem, BacklogItemDetail?)] = [
            (backlogItem(verify: nil), groomedDetail(verify: [])),
            (backlogItem(size: nil), groomedDetail()),
            (backlogItem(size: .xl), groomedDetail()),
            (backlogItem(), groomedDetail(criteria: [])),
            (backlogItem(), nil),
        ]
        for (item, detail) in refused {
            let verdict = DefinitionOfReady.evaluate(item: item, detail: detail)
            let actions = ItemActions.offered(context(status: .ready, readiness: verdict))

            XCTAssertFalse(verdict.isReady, "\(item.size?.rawValue ?? "-") should be refused")
            XCTAssertFalse(verdict.summary.isEmpty)
            XCTAssertEqual(actions.first { $0.kind == .run }?.unavailable, verdict.summary)
        }
    }

    /// An item whose `needs:` is unmet is withheld at pickup, so Run says which
    /// dependency and what state it is in — the fix is time, not an edit.
    func testAnItemWaitingOnADependencyCannotRunAndNamesIt() {
        let waiting = backlogItem(needs: ["schema-migration"])
        let dependencies = DefinitionOfReady.Dependencies(items: [
            waiting, backlogItem(id: "schema-migration", status: .active),
        ])
        let verdict = DefinitionOfReady.evaluate(item: waiting, detail: groomedDetail(),
                                                 dependencies: dependencies)
        let actions = ItemActions.offered(context(status: .ready, readiness: verdict))

        XCTAssertEqual(actions.first { $0.kind == .run }?.unavailable,
                       "needs schema-migration — not done (active)")
    }

    /// The gate agreeing changes nothing: a groomed item at a pickup stage, not
    /// retired, with both roles assigned still runs.
    func testAGroomedItemStillOffersRun() {
        let verdict = DefinitionOfReady.evaluate(item: backlogItem(), detail: groomedDetail())
        let actions = ItemActions.offered(context(status: .ready, readiness: verdict))

        XCTAssertTrue(verdict.isReady)
        XCTAssertNil(actions.first { $0.kind == .run }?.unavailable)
    }

    /// Readiness gates Run and nothing else. An item can be ungroomed and still
    /// be at the approval gate, retired, or worth re-grooming — and re-grooming
    /// is precisely what an ungroomed item needs offered.
    func testReadinessLeavesTheOtherActionsAlone() {
        let verdict = DefinitionOfReady.evaluate(item: backlogItem(verify: nil, size: nil),
                                                 detail: nil)
        let gated = ItemActions.offered(
            context(status: .awaitingApproval, isRetired: true,
                    readiness: verdict, inFlight: "item-1"))
        let ungated = ItemActions.offered(
            context(status: .awaitingApproval, isRetired: true, inFlight: "item-1"))

        XCTAssertFalse(verdict.isReady)
        for kind in ItemAction.Kind.allCases where kind != .run {
            XCTAssertEqual(gated.first { $0.kind == kind }?.unavailable,
                           ungated.first { $0.kind == kind }?.unavailable,
                           "\(kind) should not depend on readiness")
        }
    }

    /// A stage, in-flight or role refusal is the more actionable statement, and
    /// an unready item usually fails those too — so readiness does not shout
    /// over them.
    func testTheInFlightAndStageClausesStillSpeakFirst() {
        let verdict = DefinitionOfReady.evaluate(item: backlogItem(verify: nil), detail: nil)
        let elsewhere = ItemActions.offered(
            context(status: .ready, readiness: verdict, inFlight: "other-item"))
        let wrongStage = ItemActions.offered(context(status: .done, readiness: verdict))

        XCTAssertEqual(elsewhere.first { $0.kind == .run }?.unavailable,
                       "a run is already in flight on other-item — one at a time per project")
        XCTAssertEqual(wrongStage.first { $0.kind == .run }?.unavailable,
                       "autopilot starts items at Ready — this one is Done")
    }

    /// Nobody asked the gate — a caller with nothing to evaluate against — and
    /// the clause stays silent rather than inventing a refusal.
    func testReadinessNilOffersExactlyWhatItDidBefore() {
        XCTAssertNil(ItemActions.offered(context(status: .ready)).first { $0.kind == .run }?
            .unavailable)
    }

    func testRegroomNeedsADetailFile() {
        let without = ItemActions.offered(context(status: .ready, hasDetailFile: false))

        XCTAssertEqual(without.first { $0.kind == .regroom }?.unavailable,
                       "this item has no detail file to open")
    }

    /// Groom is for any Draft with a runner, whether or not it already has a
    /// detail file — a grooming pass files one with every draft it parks, so a
    /// refusal on that clause refused the action on every draft there was to
    /// groom. Only the status and the runner still gate it.
    func testGroomNeedsADraftWithARunner() {
        let withoutDetail = ItemActions.offered(context(status: .draft, hasDetailFile: false))
        let withDetail = ItemActions.offered(context(status: .draft, hasDetailFile: true))
        let notADraft = ItemActions.offered(context(status: .ready, hasDetailFile: false))

        XCTAssertNil(withoutDetail.first { $0.kind == .groom }?.unavailable)
        XCTAssertNil(withDetail.first { $0.kind == .groom }?.unavailable)
        XCTAssertEqual(notADraft.first { $0.kind == .groom }?.unavailable,
                       "the item is Ready, not Draft")
    }

    /// A surface with no agent runtime (the Autopilot queue, which never shows
    /// a draft) offers Groom disabled rather than hiding it — the same rule
    /// every other unavailable action follows.
    func testGroomNeedsAnAgentRuntime() {
        let actions = ItemActions.offered(
            context(status: .draft, hasDetailFile: false, hasGroomRunner: false))

        XCTAssertEqual(actions.first { $0.kind == .groom }?.unavailable,
                       "no agent runtime available from this panel")
    }

    /// Promote moves a draft to Ready once the Definition-of-Ready agrees —
    /// whether that came from a groom pass or a hand-groomed detail file — and
    /// says the gate's own reason when it does not.
    func testPromoteNeedsADraftThatMeetsTheDefinitionOfReady() {
        let verdict = DefinitionOfReady.evaluate(item: backlogItem(status: .draft),
                                                 detail: groomedDetail())
        let ready = ItemActions.offered(context(status: .draft, readiness: verdict))
        let unready = ItemActions.offered(
            context(status: .draft, readiness: DefinitionOfReady.evaluate(
                item: backlogItem(verify: nil, status: .draft), detail: nil)))
        let notADraft = ItemActions.offered(context(status: .ready, readiness: verdict))

        XCTAssertTrue(verdict.isReady)
        XCTAssertNil(ready.first { $0.kind == .promote }?.unavailable)
        XCTAssertFalse(unready.first { $0.kind == .promote }?.unavailable?.isEmpty ?? true)
        XCTAssertEqual(notADraft.first { $0.kind == .promote }?.unavailable,
                       "the item is Ready, not Draft")
    }

    // MARK: - Readiness checklist

    /// With no detail file the gate reports one clause, not four — the single
    /// fix is to write the file — and writing it clears the row it reported.
    func testAMissingDetailFileIsOneUnmetClauseAndWritingItClearsIt() {
        let draft = backlogItem(status: .draft)

        let without = checklist(item: draft, detail: nil)
        XCTAssertEqual(without.filter { !$0.isMet }.map(\.requirement), [.detail])
        XCTAssertEqual(without.first?.unmet, "no groomed detail file — write "
                       + "backlog/item-1.md with What/How/Validation")
        XCTAssertFalse(without.contains { [.what, .how, .validation].contains($0.requirement) },
                       "the sections the gate did not judge must not be shown as rows")

        let written = checklist(item: draft, detail: groomedDetail())
        XCTAssertTrue(written.allSatisfy(\.isMet), "\(written.filter { !$0.isMet })")
        XCTAssertEqual(written.map(\.requirement),
                       [.detail, .what, .how, .validation, .verify, .verifySeparator,
                        .titleSeparator, .size])
    }

    /// A groomed item at `ready` meets every clause, with the two the reader
    /// cannot see from the item line itself — its size, and what it waits for —
    /// saying what met them.
    func testAReadyItemMeetsEveryClause() {
        let item = backlogItem()
        let rows = checklist(item: item, detail: groomedDetail(),
                             dependencies: .init(items: [item]))

        XCTAssertTrue(rows.allSatisfy(\.isMet), "\(rows.filter { !$0.isMet })")
        XCTAssertEqual(rows.map(\.requirement),
                       [.detail, .what, .how, .validation, .verify, .verifySeparator,
                        .titleSeparator, .size, .dependency])
        XCTAssertEqual(rows.first { $0.requirement == .size }?.note, "sized M")
        XCTAssertEqual(rows.last?.note, "nothing to wait for")
    }

    /// An item groomed inline on its line has no detail file and is ready all
    /// the same, so the row says which way it was groomed rather than ticking a
    /// file that is not there.
    func testAnInlineGroomedItemSaysSoRatherThanNamingAFile() {
        let rows = checklist(item: backlogItem(title: "WHAT: dedupe HOW: key on id VALIDATE: no dupes"),
                             detail: nil)

        XCTAssertTrue(rows.allSatisfy(\.isMet), "\(rows.filter { !$0.isMet })")
        XCTAssertEqual(rows.first?.note, "groomed inline on the backlog line")
    }

    /// The clause the reader can do nothing about names what it is waiting for —
    /// one row per dependency, because "wait for one of these two" is not a
    /// thing an item can say.
    func testUnmetDependenciesGetARowEachAndNameTheIDs() {
        let waiting = backlogItem(needs: ["schema-migration", "ghost"])
        let rows = checklist(item: waiting, detail: groomedDetail(),
                             dependencies: .init(items: [
                                waiting, backlogItem(id: "schema-migration", status: .active),
                             ]))

        let dependencies = rows.filter { $0.requirement == .dependency }
        XCTAssertEqual(dependencies.map(\.unmet), ["needs schema-migration — not done (active)",
                                                   "needs ghost — no such item"])
        XCTAssertEqual(Set(dependencies.map(\.id)).count, 2, "two rows must not share an id")
    }

    /// Nobody asked the gate about sequencing, so the checklist says nothing
    /// about it. A ticked row would be a claim no evaluation made.
    func testAnUnjudgedDependencyClauseLeavesNoRow() {
        let rows = checklist(item: backlogItem(needs: ["ghost"]), detail: groomedDetail())

        XCTAssertFalse(rows.contains { $0.requirement == .dependency })
    }

    /// "No size set" and "size L is too large" are two clauses in the verdict
    /// because they need different words, and one question to whoever is
    /// grooming — so one row, carrying whichever answered.
    func testSizeIsOneRowHoweverItWasAnswered() {
        let unsized = checklist(item: backlogItem(size: nil), detail: groomedDetail())
        let tooLarge = checklist(item: backlogItem(size: .l), detail: groomedDetail())

        XCTAssertEqual(unsized.filter { $0.clause == "Size" }.map(\.unmet),
                       ["no size set — autopilot runs XS/S/M"])
        XCTAssertEqual(tooLarge.filter { $0.clause == "Size" }.map(\.unmet),
                       ["size L is too large for autopilot — break it down first"])
        XCTAssertEqual(tooLarge.first { $0.clause == "Size" }?.requirement, .sizeTooLarge)
    }

    /// The mapping adds no wording of its own: every unmet row carries the
    /// sentence the gate wrote, in the order the verdict lists them. A second
    /// wording of a refusal drifts from the one that actually decides, and then
    /// this screen and the run log say different things about the same item.
    func testEveryRefusalIsTheGatesOwnSentenceInTheGatesOwnOrder() {
        let item = BacklogItem(id: "item-1", title: "Deploy | fast", verify: "lint | test",
                               status: .ready, type: .local, size: .l,
                               detailPath: "backlog/item-1.md", needs: ["ghost"])
        let detail = groomedDetail(what: nil, criteria: [])
        let dependencies = DefinitionOfReady.Dependencies(items: [item])
        let verdict = DefinitionOfReady.evaluate(item: item, detail: detail,
                                                 dependencies: dependencies)
        let rows = ItemReadinessChecklist.rows(item: item, detail: detail, verdict: verdict,
                                               judgedDependencies: true)

        XCTAssertEqual(rows.compactMap(\.unmet), verdict.reasons)
        XCTAssertEqual(rows.filter { !$0.isMet }.map(\.requirement), verdict.unmet)
    }

    /// The gate governs pickup, so a shipped item is past it — a checklist there
    /// would only invite re-grooming work already delivered. Every other stage
    /// keeps it, `blocked` included: that is where someone is deciding what the
    /// item needs before it goes back to Ready.
    func testTheChecklistIsHiddenOnlyOnceTheItemIsDone() {
        XCTAssertFalse(ItemReadinessChecklist.isShown(for: .done))
        for status in BacklogItemStatus.allCases where status != .done {
            XCTAssertTrue(ItemReadinessChecklist.isShown(for: status), "\(status)")
        }
    }

    // MARK: - Fixtures

    /// The gate and the mapping, in the one order the view model uses them.
    private func checklist(item: BacklogItem,
                           detail: BacklogItemDetail?,
                           dependencies: DefinitionOfReady.Dependencies? = nil)
        -> [ItemReadinessRow] {
        ItemReadinessChecklist.rows(
            item: item, detail: detail,
            verdict: DefinitionOfReady.evaluate(item: item, detail: detail,
                                                dependencies: dependencies),
            judgedDependencies: dependencies != nil)
    }

    private func context(status: BacklogItemStatus,
                         pickupStages: [BacklogItemStatus] = [.ready],
                         isRetired: Bool = false,
                         hasWorkerAndReviewer: Bool = true,
                         readiness: DefinitionOfReady.Verdict? = nil,
                         inFlight: String? = nil,
                         hasDetailFile: Bool = true,
                         hasProjectRoot: Bool = true,
                         hasGroomRunner: Bool = true) -> ItemActions.Context {
        ItemActions.Context(itemID: "item-1", status: status, pickupStages: pickupStages,
                            isRetired: isRetired, hasWorkerAndReviewer: hasWorkerAndReviewer,
                            readiness: readiness, inFlightItemID: inFlight,
                            hasDetailFile: hasDetailFile, hasProjectRoot: hasProjectRoot,
                            hasGroomRunner: hasGroomRunner)
    }

    /// A backlog line, as the gate reads one.
    private func backlogItem(id: String = "item-1",
                             title: String = "Item",
                             verify: String? = "xcodebuild build",
                             size: ItemSize? = .m,
                             status: BacklogItemStatus = .ready,
                             needs: [String] = []) -> BacklogItem {
        BacklogItem(id: id, title: title, verify: verify, status: status, type: .local,
                    size: size, detailPath: "backlog/\(id).md", needs: needs)
    }

    /// A groomed detail file, as the gate reads one.
    private func groomedDetail(what: String? = "Dedupe the sync queue.",
                               approach: String? = "Key on the remote id.",
                               criteria: [String] = ["A duplicate push is dropped"],
                               verify: [BacklogItemDetail.VerifyCommand] =
                                   [.init(name: "build", cmd: "xcodebuild build", expect: nil)])
        -> BacklogItemDetail {
        BacklogItemDetail(id: "item-1", title: "Item", size: nil, verifyCommands: verify,
                          acceptanceCriteria: criteria, outOfScope: [],
                          what: what, approach: approach)
    }

    private func truth(presence: ItemGitTruth.Presence,
                       merged: Bool? = nil,
                       ahead: Int? = nil,
                       changed: Int? = nil,
                       orphaned: Bool? = nil) -> ItemGitTruth {
        ItemGitTruth(branch: "kiteloop/item-1", presence: presence, merged: merged,
                     commitsAhead: ahead, changedFiles: changed, worktreePath: nil,
                     orphanedCommits: orphaned)
    }

    private func run(outcome: String,
                     merged: Bool? = nil,
                     changedFileCount: Int? = nil) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: "/tmp/p", projectName: "p", itemID: "item-1", title: "Item",
            epic: nil, declaredSize: "M", startedAt: Date(timeIntervalSince1970: 1_770_000_000),
            completedAt: Date(timeIntervalSince1970: 1_770_000_600), durationSeconds: 600,
            costUSD: 1, reviewerRetries: 0, outcome: outcome, workerAgent: "Builder",
            reviewerAgent: "Reviewer", executionID: "exec-1")
        record.merged = merged
        record.changedFileCount = changedFileCount
        return record
    }
}
