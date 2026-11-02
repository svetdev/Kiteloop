import XCTest
@testable import KiteloopCore

/// The reading behind the waiting-on-you list: which gates become rows, what
/// each row says, and the order they come back in.
///
/// All of it is over plain readings, so a case can state a portfolio — three
/// projects, two gates, a question nobody answered — that would take a night of
/// runs to reach for real.
///
/// The load-bearing case is `testAnItemThatLeftTheGateLosesItsRow`: the inbox is
/// never told a gate has closed, so a list built from notices alone keeps naming
/// finished work.
final class WaitingOnYouTests: XCTestCase {

    // MARK: - Which gates become rows

    /// Both kinds, across projects, in one list — the whole point of the
    /// surface.
    func testEveryOpenGateAcrossEveryProjectIsListed() {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")]),
            project("beta", asking: [("ada", "Ada")]),
        ])

        XCTAssertEqual(waiting.rows.count, 2)
        XCTAssertEqual(waiting.approvals, 1)
        XCTAssertEqual(waiting.questions, 1)
        XCTAssertEqual(Set(waiting.rows.map(\.projectName)), ["alpha", "beta"])
    }

    /// The row exists because the gate does. An approval notice the inbox is
    /// still holding for an item that has since been approved names work that is
    /// finished — and nothing ever marks that notice resolved, so this is the
    /// ordinary state of the inbox rather than an edge case.
    func testAnItemThatLeftTheGateLosesItsRow() {
        let notice = notification(type: .approval, title: "Waiting for approval",
                                  body: "a1 is ready for you", agentID: "builder", itemID: "a1")

        let atTheGate = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")], pending: [notice]),
        ])
        let approved = WaitingOnYou.capture(projects: [
            project("alpha", pending: [notice]),
        ])

        XCTAssertEqual(atTheGate.rows.count, 1)
        XCTAssertTrue(approved.isEmpty, "The notice outlives the gate; the row must not")
    }

    /// The same in the other direction: an agent that has been answered is no
    /// longer holding anything, however loudly its notice is still sitting in
    /// the inbox.
    func testAnAnsweredQuestionLosesItsRow() {
        let notice = notification(type: .question, title: "Ada needs input",
                                  body: "Which branch?", agentID: "ada")

        let asking = WaitingOnYou.capture(projects: [
            project("alpha", asking: [("ada", "Ada")], pending: [notice]),
        ])
        let answered = WaitingOnYou.capture(projects: [
            project("alpha", pending: [notice]),
        ])

        XCTAssertEqual(asking.rows.count, 1)
        XCTAssertTrue(answered.isEmpty)
    }

    /// And the converse, which is what keeps the list honest the other way: a
    /// human dismissing the notice does not clear the gate, so the row stays.
    func testAGateWhoseNoticeWasDismissedKeepsItsRow() {
        var dismissed = notification(type: .approval, title: "Waiting for approval",
                                     body: "a1 is ready", agentID: "builder", itemID: "a1")
        dismissed.status = .dismissed

        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")], pending: [dismissed]),
        ])

        XCTAssertEqual(waiting.rows.count, 1)
        XCTAssertNil(waiting.rows[0].since, "A dismissed notice is not a clock this row can read")
        XCTAssertNil(waiting.rows[0].detail)
    }

    /// A notice about some other item does not dress this one. The join is the
    /// item id, and a run that gates two items raises a notice for each.
    func testANoticeAboutAnotherItemDoesNotDressThisRow() {
        let other = notification(type: .approval, title: "Waiting for approval",
                                 body: "a2 is ready", agentID: "builder", itemID: "a2")

        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")], pending: [other]),
        ])

        XCTAssertEqual(waiting.rows.count, 1)
        XCTAssertNil(waiting.rows[0].detail)
    }

    /// Nothing but the two actionable kinds. A finished run and an error are
    /// both inbox items, and neither is a gate: one is news, the other is
    /// somebody else's job to retry.
    func testCompletionsAndErrorsAreNotGates() {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", pending: [
                notification(type: .complete, title: "Done", body: "", agentID: "builder"),
                notification(type: .error, title: "Build failed", body: "", agentID: "builder"),
                notification(type: .event, title: "Something happened", body: "", agentID: "builder"),
            ]),
        ])

        XCTAssertTrue(waiting.isEmpty)
    }

    // MARK: - What a row says

    /// An approval row is titled with the item's own title, and addressed by the
    /// id and project a person needs to recognise it — the notice's title is a
    /// sentence about a run, and what is being decided is the item.
    func testAnApprovalRowNamesTheItemAndItsProject() throws {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")],
                    pending: [notification(type: .approval, title: "Waiting for approval",
                                           body: "verify passed", agentID: "builder", itemID: "a1")]),
        ])

        let row = try XCTUnwrap(waiting.rows.first)
        XCTAssertEqual(row.title, "Ship the thing")
        XCTAssertEqual(row.subtitle, "a1 · alpha")
        XCTAssertEqual(row.detail, "verify passed")
        XCTAssertEqual(row.gate, .approval(itemID: "a1"))
    }

    /// The item's own defect, at the drawer: a gate item whose branch no
    /// longer merges cleanly says so in its subtitle, with the file count —
    /// discoverable before anyone clicks Approve.
    func testAStaleApprovalRowNamesTheFileCount() throws {
        let waiting = WaitingOnYou.capture(projects: [
            WaitingOnYou.ProjectReading(
                id: "id-alpha", name: "alpha", path: "/tmp/alpha",
                gatedItems: [.init(id: "a1", title: "Ship the thing", staleFileCount: 3)]),
        ])

        let row = try XCTUnwrap(waiting.rows.first)
        XCTAssertEqual(row.subtitle, "a1 · alpha · stale · 3 files")
    }

    /// A gate that already ran and refused is not a decision waiting on a
    /// person: the row says so, carries the refusal where the summons was, and
    /// the drawer counts it apart from the approvals still waiting.
    func testARefusedGateRowSaysSoAndCarriesTheRefusal() throws {
        let waiting = WaitingOnYou.capture(projects: [
            WaitingOnYou.ProjectReading(
                id: "id-alpha", name: "alpha", path: "/tmp/alpha",
                gatedItems: [
                    .init(id: "a1", title: "Ship the thing",
                          gateRefusal: "verify failed on merged tree (merge-verify: gate.py)"),
                    .init(id: "a2", title: "Waiting one"),
                ]),
        ])

        let refused = try XCTUnwrap(waiting.rows.first { $0.gate == .approval(itemID: "a1") })
        XCTAssertEqual(refused.subtitle, "a1 · alpha · refused at the gate")
        XCTAssertEqual(refused.detail, "verify failed on merged tree (merge-verify: gate.py)")
        let waitingRow = try XCTUnwrap(waiting.rows.first { $0.gate == .approval(itemID: "a2") })
        XCTAssertEqual(waitingRow.subtitle, "a2 · alpha")
        XCTAssertNil(waitingRow.gateRefusal)
        XCTAssertEqual(waiting.approvals, 2)
        XCTAssertEqual(waiting.refusedAtGate, 1)
    }

    /// A single conflicting file reads in the singular.
    func testAStaleApprovalRowWithOneFileReadsSingular() throws {
        let waiting = WaitingOnYou.capture(projects: [
            WaitingOnYou.ProjectReading(
                id: "id-alpha", name: "alpha", path: "/tmp/alpha",
                gatedItems: [.init(id: "a1", title: "Ship the thing", staleFileCount: 1)]),
        ])

        let row = try XCTUnwrap(waiting.rows.first)
        XCTAssertEqual(row.subtitle, "a1 · alpha · stale · 1 file")
    }

    /// A clean or unchecked branch reads exactly as it did before this field
    /// existed — no "stale" wording invented for a gate item nothing found
    /// wrong with.
    func testACleanApprovalRowSubtitleIsUnchanged() throws {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")]),
        ])

        let row = try XCTUnwrap(waiting.rows.first)
        XCTAssertEqual(row.subtitle, "a1 · alpha")
    }

    /// A question row is titled with the notice's headline, because that is the
    /// only place the question was ever written down as one.
    func testAQuestionRowNamesTheAgentAndCarriesTheQuestion() throws {
        let waiting = WaitingOnYou.capture(projects: [
            project("beta", asking: [("ada", "Ada")],
                    pending: [notification(type: .question, title: "Ada needs input",
                                           body: "Which branch?", agentID: "ada")]),
        ])

        let row = try XCTUnwrap(waiting.rows.first)
        XCTAssertEqual(row.title, "Ada needs input")
        XCTAssertEqual(row.subtitle, "Ada · beta")
        XCTAssertEqual(row.detail, "Which branch?")
        XCTAssertEqual(row.gate, .question(agentID: "ada"))
    }

    /// The subtitle names the agent by the name it was given, while the gate
    /// and the row's identity keep the id the chat is opened by.
    func testAQuestionRowSubtitleNamesTheAgentButTheGateKeepsItsID() throws {
        let waiting = WaitingOnYou.capture(projects: [project("myproject", asking: [("ada-2", "Ada")])])

        let row = try XCTUnwrap(waiting.rows.first)
        XCTAssertEqual(row.subtitle, "Ada · myproject")
        XCTAssertFalse(row.subtitle.contains("ada-2"))
        XCTAssertEqual(row.gate, .question(agentID: "ada-2"))
        XCTAssertEqual(row.id, "id-myproject#question:ada-2")
    }

    /// With no notice left, the row still has to say who is waiting.
    func testAQuestionWithNoNoticeStillNamesItsAgent() {
        let waiting = WaitingOnYou.capture(projects: [project("beta", asking: [("ada", "Ada")])])

        XCTAssertEqual(waiting.rows.first?.title, "Ada needs input")
    }

    /// A gate re-raised after a rejection has two notices; the run waiting now
    /// is the one that just spoke.
    func testTheNewestNoticeDressesTheRow() {
        let old = notification(type: .approval, title: "Waiting for approval", body: "first pass",
                               agentID: "builder", itemID: "a1", at: .init(timeIntervalSince1970: 1_000))
        let new = notification(type: .approval, title: "Waiting for approval", body: "second pass",
                               agentID: "builder", itemID: "a1", at: .init(timeIntervalSince1970: 2_000))

        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")], pending: [old, new]),
        ])

        XCTAssertEqual(waiting.rows.first?.detail, "second pass")
        XCTAssertEqual(waiting.rows.first?.since, .init(timeIntervalSince1970: 2_000))
    }

    /// A notice with nothing in its body leaves the row without a detail line,
    /// rather than with an empty one.
    func testAnEmptyBodyIsNoDetailAtAll() {
        let waiting = WaitingOnYou.capture(projects: [
            project("beta", asking: [("ada", "Ada")],
                    pending: [notification(type: .question, title: "Ada needs input",
                                           body: "", agentID: "ada")]),
        ])

        XCTAssertNil(waiting.rows.first?.detail)
    }

    /// Row ids are the gate's, not the notice's — a notice can be dismissed out
    /// from under a gate that is still open, and a row whose identity changed
    /// underneath it is one SwiftUI redraws from scratch mid-scroll.
    func testARowKeepsItsIdentityWhenItsNoticeGoes() {
        let notice = notification(type: .approval, title: "Waiting for approval", body: "ready",
                                  agentID: "builder", itemID: "a1")
        let withNotice = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")], pending: [notice]),
        ])
        let without = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")]),
        ])

        XCTAssertEqual(withNotice.rows.first?.id, without.rows.first?.id)
    }

    /// Two projects can each have an item called `a1`; the rows must not
    /// collide.
    func testRowIdsAreUniqueAcrossProjects() {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")]),
            project("beta", gated: [("a1", "Ship a different thing")]),
        ])

        XCTAssertEqual(Set(waiting.rows.map(\.id)).count, 2)
    }

    // MARK: - Order

    /// Longest-waiting first: the one ranking somebody scanning this list is
    /// already applying in their head.
    func testTheLongestWaitingGateComesFirst() {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Newer")],
                    pending: [notification(type: .approval, title: "t", body: "", agentID: "builder",
                                           itemID: "a1", at: .init(timeIntervalSince1970: 3_000))]),
            project("beta", gated: [("b1", "Older")],
                    pending: [notification(type: .approval, title: "t", body: "", agentID: "builder",
                                           itemID: "b1", at: .init(timeIntervalSince1970: 1_000))]),
        ])

        XCTAssertEqual(waiting.rows.map(\.title), ["Older", "Newer"])
    }

    /// A gate with no notice left has outlived it, so it has been there longer
    /// than anything that still has a timestamp.
    func testAGateWithNoNoticeSortsAheadOfTimestampedOnes() {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Timestamped")],
                    pending: [notification(type: .approval, title: "t", body: "", agentID: "builder",
                                           itemID: "a1", at: .init(timeIntervalSince1970: 1_000))]),
            project("beta", gated: [("b1", "No notice")]),
        ])

        XCTAssertEqual(waiting.rows.map(\.title), ["No notice", "Timestamped"])
    }

    /// A refresh that changes nothing redraws the same order.
    func testTiesBreakDeterministically() {
        let projects = [
            project("beta", gated: [("b1", "Beta")]),
            project("alpha", gated: [("a1", "Alpha"), ("a2", "Alpha two")]),
        ]

        let once = WaitingOnYou.capture(projects: projects)
        let twice = WaitingOnYou.capture(projects: projects)

        XCTAssertEqual(once.rows.map(\.id), twice.rows.map(\.id))
        XCTAssertEqual(once.rows.map(\.title), ["Alpha", "Alpha two", "Beta"])
    }

    // MARK: - Stale flags

    /// A flagged item becomes a row named for itself — its own title, its own
    /// id in the subtitle, its status in the detail line — the same shape an
    /// approval row takes, since it is read the same way off the drawer.
    func testAStaleItemBecomesARowNamedForItself() throws {
        let touched = Date(timeIntervalSince1970: 1_000)
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", stale: [("a1", "Ship the thing", .ready, touched)]),
        ])

        let row = try XCTUnwrap(waiting.rows.first)
        XCTAssertEqual(row.title, "Ship the thing")
        XCTAssertEqual(row.subtitle, "a1 · alpha")
        XCTAssertEqual(row.gate, .stale(itemID: "a1"))
        XCTAssertEqual(row.since, touched)
        XCTAssertEqual(row.detail, "still ready — nothing has touched it")
    }

    /// No notice ever dresses a stale row — there is no run and no inbox
    /// entry behind one — so a pending notice about the same item is not
    /// mistaken for the flag's own words.
    func testAPendingNoticeDoesNotDressAStaleRow() throws {
        let notice = notification(type: .approval, title: "Waiting for approval",
                                  body: "unrelated", agentID: "builder", itemID: "a1")
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", stale: [("a1", "Ship the thing", .ready, Date(timeIntervalSince1970: 1_000))],
                    pending: [notice]),
        ])

        // The item is flagged but not at the gate, so the row is the flag's
        // own — and it does not borrow the leftover notice's words.
        let staleRow = try XCTUnwrap(waiting.rows.first { if case .stale = $0.gate { true } else { false } })
        XCTAssertEqual(staleRow.detail, "still ready — nothing has touched it")
    }

    /// `staleFlags` counts apart from approvals and questions, and joins the
    /// summary line the same way they do.
    func testStaleFlagsAreCountedApartAndJoinTheSummary() {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "One")], asking: [("ada", "Ada")],
                    stale: [("s1", "Stale one", .ready, Date(timeIntervalSince1970: 1_000)),
                            ("s2", "Stale two", .active, Date(timeIntervalSince1970: 2_000))]),
        ])

        XCTAssertEqual(waiting.staleFlags, 2)
        XCTAssertEqual(waiting.approvals, 1)
        XCTAssertEqual(waiting.questions, 1)
        XCTAssertEqual(waiting.summary, "1 approval · 1 question · 2 stale")
    }

    /// A stale row's clock is when git last saw the item touched, not when the
    /// row was built — so it sorts among approvals and questions by the same
    /// "longest waiting first" rule, rather than always trailing or leading.
    func testAStaleRowSortsByItsLastTouchedDateAmongTheOtherKinds() {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Newer approval")],
                    stale: [("s1", "Oldest flag", .ready, .init(timeIntervalSince1970: 1_000))],
                    pending: [notification(type: .approval, title: "t", body: "", agentID: "builder",
                                           itemID: "a1", at: .init(timeIntervalSince1970: 3_000))]),
        ])

        XCTAssertEqual(waiting.rows.map(\.title), ["Oldest flag", "Newer approval"])
    }

    /// One item is one row. `StaleItemSweep.openStatuses` counts
    /// `awaiting-approval` as open, so an item left at the gate for longer
    /// than the sweep's window is returned by the sweep *and* is a gate item —
    /// and it is still one thing waiting on one person. The approval row wins:
    /// it is the gate a person can actually clear.
    func testAnItemBothGatedAndFlaggedStaleIsOneApprovalRow() throws {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")],
                    stale: [("a1", "Ship the thing", .awaitingApproval, Date(timeIntervalSince1970: 1_000))]),
        ])

        XCTAssertEqual(waiting.rows.count, 1)
        let row = try XCTUnwrap(waiting.rows.first)
        XCTAssertEqual(row.gate, .approval(itemID: "a1"))
    }

    /// And it is counted once, by the kind of thing it is: the footer says one
    /// approval, with no stale entry beside it.
    func testAnItemBothGatedAndFlaggedStaleIsCountedOnce() {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")],
                    stale: [("a1", "Ship the thing", .awaitingApproval, Date(timeIntervalSince1970: 1_000))]),
        ])

        XCTAssertEqual(waiting.approvals, 1)
        XCTAssertEqual(waiting.staleFlags, 0)
        XCTAssertEqual(waiting.summary, "1 approval")
    }

    /// Only the duplicate goes. A flagged item that is at no gate keeps its
    /// own row beside the gates in the same project.
    func testAFlaggedItemNotAtTheGateKeepsItsRow() throws {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "At the gate")],
                    stale: [("a1", "At the gate", .awaitingApproval, Date(timeIntervalSince1970: 1_000)),
                            ("s1", "Just sitting", .ready, Date(timeIntervalSince1970: 2_000))]),
        ])

        XCTAssertEqual(waiting.rows.count, 2)
        XCTAssertEqual(waiting.staleFlags, 1)
        let flagged = try XCTUnwrap(waiting.rows.first { if case .stale = $0.gate { true } else { false } })
        XCTAssertEqual(flagged.gate, .stale(itemID: "s1"))
        XCTAssertEqual(flagged.detail, "still ready — nothing has touched it")
    }

    /// A duplicate is only a duplicate inside one project. The same id gated
    /// in one project and flagged in another names two different items, and
    /// both rows stay.
    func testTheSameIDGatedInOneProjectAndFlaggedInAnotherKeepsBothRows() {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "In alpha")]),
            project("beta", stale: [("a1", "In beta", .ready, Date(timeIntervalSince1970: 1_000))]),
        ])

        XCTAssertEqual(waiting.rows.count, 2)
        XCTAssertEqual(waiting.approvals, 1)
        XCTAssertEqual(waiting.staleFlags, 1)
    }

    /// Two projects can each flag an item called `s1`; the rows must not
    /// collide, the same guarantee gate and question rows already carry.
    func testStaleRowIdsAreUniqueAcrossProjects() {
        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", stale: [("s1", "In alpha", .ready, Date(timeIntervalSince1970: 1_000))]),
            project("beta", stale: [("s1", "In beta", .ready, Date(timeIntervalSince1970: 1_000))]),
        ])

        XCTAssertEqual(Set(waiting.rows.map(\.id)).count, 2)
    }

    // MARK: - The summary line

    /// The footer's line counts the two kinds apart: they are cleared in
    /// different places and take different amounts of a person.
    func testTheSummaryCountsTheKindsApart() {
        let both = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "One"), ("a2", "Two")], asking: [("ada", "Ada")]),
        ])
        let onlyApprovals = WaitingOnYou.capture(projects: [project("alpha", gated: [("a1", "One")])])
        let onlyQuestions = WaitingOnYou.capture(projects: [project("alpha", asking: [("ada", "Ada")])])

        XCTAssertEqual(both.summary, "2 approvals · 1 question")
        XCTAssertEqual(onlyApprovals.summary, "1 approval")
        XCTAssertEqual(onlyQuestions.summary, "1 question")
    }

    /// Said plainly, because it is the answer the surface gives most of the
    /// time and it is worth reading without opening anything.
    func testNothingWaitingSaysSo() {
        let waiting = WaitingOnYou.capture(projects: [project("alpha")])

        XCTAssertTrue(waiting.isEmpty)
        XCTAssertEqual(waiting.summary, "nothing is waiting on you")
    }

    /// A window with no project open has no gates, and does not crash reaching
    /// for one.
    func testNoProjectsIsAnEmptyList() {
        XCTAssertTrue(WaitingOnYou.capture(projects: []).isEmpty)
    }

    // MARK: - Which notice may dress a gate

    /// Only an approval notice dresses an approval row. A question the same run
    /// asked about the same item is a different gate with its own row; if it
    /// lent the approval row its words and clock, the row would say "Which
    /// branch?" about a decision that is not a question at all.
    func testAQuestionNoticeDoesNotDressAnApprovalRow() throws {
        let question = notification(type: .question, title: "Builder needs input",
                                    body: "Which branch?", agentID: "builder", itemID: "a1")

        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")], pending: [question]),
        ])

        let row = try XCTUnwrap(waiting.rows.first)
        XCTAssertEqual(row.gate, .approval(itemID: "a1"))
        XCTAssertNil(row.detail, "a question is not this gate's words")
        XCTAssertNil(row.since, "nor its clock")
    }

    /// A question row is dressed only by a question notice *from this agent*:
    /// not by this agent's own approval notice, and not by another agent's
    /// question. Both halves of the join have to hold, or a busy inbox puts
    /// somebody else's words under Ada's name.
    func testOnlyThisAgentsOwnQuestionNoticeDressesItsRow() throws {
        let adasApproval = notification(type: .approval, title: "Waiting for approval",
                                        body: "verify passed", agentID: "ada", itemID: "a1")
        let bobsQuestion = notification(type: .question, title: "Bob needs input",
                                        body: "Which branch?", agentID: "bob")

        let waiting = WaitingOnYou.capture(projects: [
            project("beta", asking: [("ada", "Ada")], pending: [adasApproval, bobsQuestion]),
        ])

        let row = try XCTUnwrap(waiting.rows.first)
        XCTAssertEqual(row.gate, .question(agentID: "ada"))
        XCTAssertEqual(row.title, "Ada needs input", "with no notice of its own, the row still says who")
        XCTAssertNil(row.detail)
        XCTAssertNil(row.since)
    }

    /// Two notices stamped in the same second — the inbox's clock has no finer
    /// resolution — are a tie, and the tie goes to the one recorded first. Pinned
    /// so that a row re-read from the same inbox reads the same notice, and so
    /// that changing which one wins is a decision rather than an accident.
    func testNoticesRaisedInTheSameSecondDressTheRowWithTheFirstRecorded() {
        let instant = Date(timeIntervalSince1970: 2_000)
        let first = notification(type: .approval, title: "Waiting for approval", body: "first recorded",
                                 agentID: "builder", itemID: "a1", at: instant)
        let second = notification(type: .approval, title: "Waiting for approval", body: "second recorded",
                                  agentID: "builder", itemID: "a1", at: instant)

        let waiting = WaitingOnYou.capture(projects: [
            project("alpha", gated: [("a1", "Ship the thing")], pending: [first, second]),
        ])

        XCTAssertEqual(waiting.rows.first?.detail, "first recorded")
    }

    // MARK: - Order, by the name on screen

    /// Among gates that have waited equally long, the tie breaks on the project
    /// as it is *named on screen*, not on its internal id: a person scanning
    /// the list sees folder names, and two projects whose ids sort the other
    /// way round from their names must still come out alphabetical.
    func testTiesBreakOnTheProjectNameNotItsID() {
        let waiting = WaitingOnYou.capture(projects: [
            WaitingOnYou.ProjectReading(id: "p2", name: "alpha", path: "/tmp/alpha",
                                        gatedItems: [.init(id: "x1", title: "In alpha")]),
            WaitingOnYou.ProjectReading(id: "p1", name: "zulu", path: "/tmp/zulu",
                                        gatedItems: [.init(id: "x1", title: "In zulu")]),
        ])

        XCTAssertEqual(waiting.rows.map(\.projectName), ["alpha", "zulu"])
    }

    // MARK: - Fixtures

    private func project(_ name: String,
                         gated: [(String, String)] = [],
                         asking: [(String, String)] = [],
                         stale: [(String, String, BacklogItemStatus, Date)] = [],
                         pending: [NotificationItem] = []) -> WaitingOnYou.ProjectReading {
        WaitingOnYou.ProjectReading(
            id: "id-\(name)",
            name: name,
            path: "/tmp/\(name)",
            gatedItems: gated.map { .init(id: $0.0, title: $0.1) },
            askingAgents: asking.map { .init(id: $0.0, name: $0.1) },
            staleItems: stale.map { .init(id: $0.0, title: $0.1, status: $0.2, lastTouched: $0.3) },
            pending: pending
        )
    }

    /// A notification with a timestamp of the case's choosing.
    ///
    /// Through `Codable` rather than the initialiser, which stamps `Date()`: the
    /// order these come back in is the whole of two cases above, and a fixture
    /// that cannot say when a notice was raised cannot state them. It is the
    /// same decoding `NotificationStore` does when it reads its log.
    private func notification(type: NotificationItem.NotificationType,
                              title: String,
                              body: String,
                              agentID: String,
                              itemID: String? = nil,
                              at: Date = .init(timeIntervalSince1970: 1_700_000_000)) -> NotificationItem {
        var fields: [String: Any] = [
            "id": UUID().uuidString,
            "timestamp": ISO8601DateFormatter().string(from: at),
            "agentID": agentID,
            "type": type.rawValue,
            "title": title,
            "body": body,
            "status": NotificationItem.Status.pending.rawValue,
        ]
        if let itemID { fields["itemID"] = itemID }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(NotificationItem.self, from: data)
    }
}
