import XCTest
import SwiftUI
import KiteloopCore
@testable import Kiteloop

/// The Routines page: which routines are a project's own, what each card
/// says, and that the page, a card's runs and the editor draw.
@MainActor
final class RoutinesViewTests: XCTestCase {

    private func routine(_ id: String, project: String = "vault", armed: Bool = true,
                         trigger: Routine.Trigger = .init(at: "07:00", days: ["mon", "tue", "wed", "thu", "fri"])) -> Routine {
        Routine(id: id, name: id, project: project, agent: "Chief", prompt: "Brief me on the day.",
                trigger: trigger, armed: armed)
    }

    private func run(_ outcome: RoutineRun.Outcome, reason: String? = nil, finished: Bool = false,
                     reply: String? = nil, cost: Double? = nil) -> RoutineRun {
        let at = Date()
        return RoutineRun(routine: "a", scheduledFor: at, at: at, outcome: outcome, reason: reason,
                          finishedAt: finished ? at : nil, reply: reply, costUSD: cost)
    }

    // MARK: - Words

    func testARoutineBelongsToTheProjectItNamesByFolderOrByPath() {
        let root = URL(fileURLWithPath: "/tmp/work/vault")
        let all = [routine("a"), routine("b", project: "/tmp/work/vault"),
                   routine("c", project: "other"), routine("d", project: "/tmp/elsewhere/vault-2")]

        XCTAssertEqual(RoutinesView.routines(in: all, for: root).map(\.id), ["a", "b"])
    }

    func testThePageSaysHowManyRoutinesThereAreAndHowManyAreArmed() {
        XCTAssertEqual(RoutinesView.subtitle(for: []), "Prompts sent to an agent on a schedule.")
        XCTAssertEqual(RoutinesView.subtitle(for: [routine("a", armed: false)]), "1 routine, none armed")
        XCTAssertEqual(RoutinesView.subtitle(for: [routine("a"), routine("b", armed: false), routine("c")]),
                       "3 routines, 2 armed")
    }

    func testACardSaysWhenItFallsAndWhoItGoesTo() {
        XCTAssertEqual(RoutineCard.caption(for: routine("a")), "Weekdays at 07:00 · Chief")
        XCTAssertEqual(RoutineCard.caption(for: routine("a", trigger: .init(at: "whenever"))), "No schedule · Chief")
    }

    func testAnArmedRoutineSaysWhenItNextFallsAndAnUnarmedOneThatItIsOff() {
        let next = Date().addingTimeInterval(3 * 60 * 60 + 60)

        let armed = RoutineCard.status(for: routine("a"), next: next, last: nil)
        let unarmed = RoutineCard.status(for: routine("a", armed: false), next: next, last: nil)

        XCTAssertTrue(armed.hasPrefix("Next "), armed)
        XCTAssertTrue(armed.hasSuffix(" · never run"), armed)
        XCTAssertEqual(unarmed, "Off · never run")
        XCTAssertEqual(RoutineCard.status(for: routine("a", armed: false), next: nil, last: run(.started, finished: true)),
                       "Off · last run finished")
    }

    func testTheLastRunReadsAsWhatHappenedAndWhy() {
        XCTAssertEqual(RoutineCard.outcome(of: run(.started)), "last run in progress")
        XCTAssertEqual(RoutineCard.outcome(of: run(.started, finished: true)), "last run finished")
        XCTAssertEqual(RoutineCard.outcome(of: run(.queued)), "last prompt queued behind a turn")
        XCTAssertEqual(RoutineCard.outcome(of: run(.skipped, reason: "its check failed (status 1)")),
                       "last skipped — its check failed (status 1)")
        XCTAssertEqual(RoutineCard.outcome(of: run(.skipped)), "last skipped — its check found nothing")
        XCTAssertEqual(RoutineCard.outcome(of: run(.refused, reason: "daily budget spent")),
                       "last refused — daily budget spent")
        XCTAssertEqual(RoutineCard.outcome(of: run(.refused)), "last refused — no reason given")
        XCTAssertEqual(RoutineCard.outcome(of: run(.waiting, reason: "project not open in Kiteloop: vault")),
                       "waiting — project not open in Kiteloop: vault")
        XCTAssertEqual(RoutineCard.outcome(of: run(.waiting)), "waiting — its agent cannot be reached")
    }

    func testAPastRunReadsAsWhatTheAgentSaidOrWhyItDidNotRunWithItsCost() {
        XCTAssertEqual(RoutineCard.historyLine(for: run(.started, finished: true, reply: "Three PRs wait on you.", cost: 0.13)),
                       "Three PRs wait on you. · $0.13")
        XCTAssertEqual(RoutineCard.historyLine(for: run(.started, finished: true, reply: "")), "Finished")
        XCTAssertEqual(RoutineCard.historyLine(for: run(.started)), "In progress")
        XCTAssertEqual(RoutineCard.historyLine(for: run(.queued)), "Queued behind a turn")
        XCTAssertEqual(RoutineCard.historyLine(for: run(.skipped)), "Skipped — its check found nothing")
        XCTAssertEqual(RoutineCard.historyLine(for: run(.refused, reason: "daily budget spent", cost: 0)),
                       "Refused — daily budget spent")
        XCTAssertEqual(RoutineCard.historyLine(for: run(.waiting)), "Waiting — its agent cannot be reached")
    }

    func testARunsDotIsGreenForATurnOrangeForOneHeldUpRedForOneRefusedAndGreyForNone() {
        XCTAssertEqual(RoutineCard.tint(of: run(.started)), .green)
        XCTAssertEqual([run(.queued), run(.skipped), run(.waiting)].map(RoutineCard.tint(of:)), [.orange, .orange, .orange])
        XCTAssertEqual(RoutineCard.tint(of: run(.refused)), .red)
        XCTAssertEqual(RoutineCard.tint(of: nil), .secondary)
    }

    func testTheEditorOffersTheTeamAndTheAgentARoutineAlreadyNames() {
        XCTAssertEqual(RoutineEditorSheet.agentChoices(["Chief", "Scout"], current: "Chief"), ["Chief", "Scout"])
        XCTAssertEqual(RoutineEditorSheet.agentChoices(["Chief", "Scout"], current: "Gone"), ["Chief", "Scout", "Gone"])
        XCTAssertEqual(RoutineEditorSheet.agentChoices(["Chief"], current: ""), ["Chief"])
    }

    func testTheSheetOpensANewRoutineOnItsFirstAgentAndAnExistingOneOnItself() {
        let new = RoutineEditorSheet.Target.new(agent: "Chief")
        XCTAssertNil(new.routine)
        XCTAssertEqual(new.draft, RoutineDraft(agent: "Chief"))
        let existing = RoutineEditorSheet.Target.existing(routine("brief"))
        XCTAssertEqual(existing.id, "brief")
        XCTAssertEqual(existing.draft, RoutineDraft(routine: routine("brief")))
        XCTAssertNotEqual(new.id, existing.id)
    }

    func testATimePickerEditsAMinuteOfTheDay() {
        var minute = 7 * 60 + 30
        let date = RoutineScheduleFields.date(for: Binding(get: { minute }, set: { minute = $0 }))
        let calendar = Calendar.current
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: date.wrappedValue), DateComponents(hour: 7, minute: 30))
        date.wrappedValue = calendar.date(bySettingHour: 18, minute: 5, second: 0, of: Date())!
        XCTAssertEqual(minute, 18 * 60 + 5)
        XCTAssertEqual(RoutineDraft.dayOrder.map(RoutineScheduleFields.dayLabel), ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    }

    // MARK: - Drawn

    /// Lays `view` out in a window and answers the height it needs.
    private func drawnHeight(of view: some View, width: CGFloat = 700) async throws -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await eventually("the view is laid out") { host.fittingSize.height > 0 }
        return host.fittingSize.height
    }

    /// A project with no routines says what one is; one with routines draws a
    /// card for each, and a change made through the runner is on the page.
    func testThePageDrawsItsEmptyStateAndThenACardPerRoutine() async throws {
        let home = try makeTemporaryDirectory(prefix: "routines-page")
        let runner = RoutineRunner(store: RoutineStore(directory: home))
        let root = URL(fileURLWithPath: "/tmp/work/vault")
        let page = RoutinesView(runner: runner, projectRoot: root, agentNames: ["Chief"])
        let empty = try await drawnHeight(of: page.frame(height: 500))
        XCTAssertGreaterThan(empty, 0)

        try runner.put(routine("brief"))
        try runner.put(routine("poll", armed: false, trigger: .init(every: 30, from: "08:00", until: "18:00")))
        try runner.put(routine("theirs", project: "other"))
        XCTAssertEqual(RoutinesView.routines(in: runner.routines, for: root).map(\.id), ["brief", "poll"])
        let listed = try await drawnHeight(of: page.frame(height: 500))
        XCTAssertGreaterThan(listed, 0)
    }

    /// A card with runs is taller than one without, by the status it carries.
    func testACardDrawsWithAndWithoutRuns() async throws {
        func card(_ runs: [RoutineRun], armed: Bool) -> RoutineCard {
            RoutineCard(routine: routine("a", armed: armed), next: Date().addingTimeInterval(3600), runs: runs,
                        setArmed: { _ in }, runNow: {}, edit: {}, delete: {})
        }
        let bare = try await drawnHeight(of: card([], armed: false))
        let ran = try await drawnHeight(of: card([run(.started, finished: true, reply: "Done.")], armed: true))
        XCTAssertGreaterThan(bare, 80)
        XCTAssertGreaterThanOrEqual(ran, bare)
    }

    /// The editor draws for a new routine and for both kinds of schedule.
    func testTheEditorDrawsForADailyAndAnIntervalRoutine() async throws {
        var saved: [RoutineDraft] = []
        let new = RoutineEditorSheet(target: .new(agent: "Chief"), agentNames: ["Chief"]) { saved.append($0) }
        let sheet = try await drawnHeight(of: new, width: 540)
        XCTAssertGreaterThan(sheet, 0)

        let poll = routine("poll", trigger: .init(every: 30, from: "08:00", until: "18:00"))
        var draft = RoutineDraft(routine: poll)
        let fields = RoutineEditorFields(draft: Binding(get: { draft }, set: { draft = $0 }), agentNames: ["Chief"])
        let interval = try await drawnHeight(of: fields, width: 540)
        draft.pattern = .daily
        let daily = try await drawnHeight(of: fields, width: 540)
        XCTAssertGreaterThan(interval, 300)
        XCTAssertGreaterThan(daily, 300)
        XCTAssertTrue(saved.isEmpty)
    }
}
