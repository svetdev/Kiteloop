import KiteloopCore
import KiteloopTestSupport
import XCTest
@testable import Kiteloop

/// The loop that sends routines' prompts: what fires and when, what is
/// skipped, refused or left waiting, and what each firing leaves on record.
/// A clock that is set by hand and an agent that is a closure; 2026-11-16 is
/// a Monday.
@MainActor
final class RoutineRunnerTests: XCTestCase {

    private var store: RoutineStore!
    private var now = Date()
    private var sent: [String] = []
    private var busy = false
    private var turn = RoutineTurn(reply: "Three things today.\nFirst…", costUSD: 0.25)
    private var unreachable: String?
    private var charged: [Double] = []

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    override func setUp() async throws {
        store = RoutineStore(directory: try makeTemporaryDirectory(prefix: "routine-runner"))
        now = date(16, 6)
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func brief(armed: Bool = true, precheck: String? = nil) -> Routine {
        Routine(id: "brief", name: "Morning brief", project: "vault", agent: "Chief", prompt: "Write the brief.",
                trigger: .init(at: "07:00"), precheck: precheck, armed: armed)
    }

    /// A started runner holding `routines`, armed as of the clock's reading.
    private func runner(_ routines: [Routine]) throws -> RoutineRunner {
        let runner = RoutineRunner(store: store, clock: { [unowned self] in self.now },
                                   calendar: { [calendar] in calendar })
        runner.agent = { [unowned self] _ in
            if let unreachable { return .failure(Routine.Refusal(problems: [unreachable])) }
            return .success(RoutineAgent(
                folder: URL(fileURLWithPath: "/tmp/vault"),
                isBusy: { self.busy },
                send: { text in
                    self.sent.append(text)
                    return self.turn
                }))
        }
        runner.charge = { [unowned self] cost, _ in self.charged.append(cost) }
        runner.start()
        for routine in routines { try runner.put(routine) }
        return runner
    }

    // MARK: - Firing

    func testAnArmedRoutineFiresWhenItFallsAndRecordsTheTurn() async throws {
        let runner = try runner([brief()])
        XCTAssertEqual(runner.nextWake, date(16, 7))
        XCTAssertTrue(runner.look().isEmpty, "nothing is owed before it falls")

        now = date(16, 7)
        for firing in runner.look() { await firing.value }

        XCTAssertEqual(sent, ["Write the brief."])
        let run = try XCTUnwrap(runner.lastRun(of: "brief"))
        XCTAssertEqual(run.outcome, .started)
        XCTAssertEqual(run.scheduledFor, date(16, 7))
        XCTAssertEqual(run.finishedAt, date(16, 7))
        XCTAssertEqual(run.reply, "Three things today.")
        XCTAssertEqual(run.costUSD, 0.25)
        XCTAssertEqual(charged, [0.25])
        XCTAssertEqual(runner.nextWake, date(17, 7))
    }

    func testAnOccurrenceFiresOnce() async throws {
        let runner = try runner([brief()])
        now = date(16, 7)
        for firing in runner.look() { await firing.value }

        now = date(16, 9)
        for firing in runner.look() { await firing.value }

        XCTAssertEqual(sent.count, 1)
    }

    func testARoutineThatIsNotArmedNeverFires() async throws {
        let runner = try runner([brief(armed: false)])
        XCTAssertNil(runner.nextWake)

        now = date(16, 8)
        for firing in runner.look() { await firing.value }

        XCTAssertEqual(sent, [])
        XCTAssertEqual(runner.next(for: brief(armed: false)), date(17, 7), "it still says when it would fall")
    }

    func testABriefMissedWhileTheMacSleptRunsLateAndSaysWhenItWasDue() async throws {
        let runner = try runner([brief()])

        now = date(16, 15)
        for firing in runner.look() { await firing.value }

        let run = try XCTUnwrap(runner.lastRun(of: "brief"))
        XCTAssertEqual(run.scheduledFor, date(16, 7))
        XCTAssertEqual(run.at, date(16, 15))
    }

    func testAnOccurrenceAlreadyOnTheLedgerIsNotRepeatedAfterARelaunch() async throws {
        let first = try runner([brief()])
        now = date(16, 7)
        for firing in first.look() { await firing.value }

        let second = try runner([])
        now = date(16, 8)
        for firing in second.look() { await firing.value }

        XCTAssertEqual(second.routines.map(\.id), ["brief"])
        XCTAssertEqual(sent.count, 1)
    }

    func testATurnThatReportedNoCostChargesNothing() async throws {
        turn = RoutineTurn(reply: "", costUSD: 0)
        let runner = try runner([brief()])
        now = date(16, 7)

        for firing in runner.look() { await firing.value }

        XCTAssertEqual(charged, [])
        XCTAssertNil(runner.lastRun(of: "brief")?.costUSD)
        XCTAssertNil(runner.lastRun(of: "brief")?.reply)
    }

    // MARK: - Queued, refused, waiting

    func testAPromptForABusyAgentIsQueuedBehindItsTurn() async throws {
        busy = true
        let runner = try runner([brief()])
        now = date(16, 7)

        for firing in runner.look() { await firing.value }

        XCTAssertEqual(sent, ["Write the brief."])
        XCTAssertEqual(runner.lastRun(of: "brief")?.outcome, .queued)
        XCTAssertNil(runner.lastRun(of: "brief")?.finishedAt)
    }

    func testASpentBudgetRefusesAScheduledTurnAndTheOccurrenceIsNotRetried() async throws {
        let runner = try runner([brief()])
        runner.budgetRefusal = { _ in "daily budget $5.00 exhausted ($5.20 spent today)" }
        now = date(16, 7)
        for firing in runner.look() { await firing.value }

        runner.budgetRefusal = nil
        now = date(16, 9)
        for firing in runner.look() { await firing.value }

        XCTAssertEqual(sent, [])
        XCTAssertEqual(runner.runs.map(\.outcome), [.refused])
        XCTAssertEqual(runner.runs.first?.reason, "daily budget $5.00 exhausted ($5.20 spent today)")
    }

    func testAnOccurrenceWhoseProjectIsNotOpenWaitsOnceAndRunsWhenItOpens() async throws {
        unreachable = "project not open in Kiteloop: vault"
        let runner = try runner([brief()])
        now = date(16, 7)
        for firing in runner.look() { await firing.value }
        for firing in runner.look() { await firing.value }
        XCTAssertEqual(runner.runs.map(\.outcome), [.waiting], "one line however many looks find it stuck")
        XCTAssertEqual(runner.runs.first?.reason, "project not open in Kiteloop: vault")

        unreachable = nil
        now = date(16, 7, 20)
        for firing in runner.look() { await firing.value }

        XCTAssertEqual(sent, ["Write the brief."])
        XCTAssertEqual(runner.runs.map(\.outcome), [.waiting, .started])
        XCTAssertEqual(runner.runs.last?.scheduledFor, date(16, 7))
    }

    func testAWaitingOccurrenceIsStillOwedAfterARelaunch() async throws {
        unreachable = "project not open in Kiteloop: vault"
        let first = try runner([brief()])
        now = date(16, 7)
        for firing in first.look() { await firing.value }

        unreachable = nil
        _ = try runner([])

        // The look a launch takes is the one that finds it owed.
        try await eventually("the occurrence ran") { self.sent == ["Write the brief."] }
    }

    func testARunnerWithNowhereToLookForAgentsLeavesTheOccurrenceWaiting() async throws {
        let runner = try runner([brief()])
        runner.agent = nil
        now = date(16, 7)

        for firing in runner.look() { await firing.value }

        XCTAssertEqual(runner.runs.map(\.reason), ["Kiteloop has no projects open yet"])
    }

    // MARK: - The check

    func testACheckThatPrintsNothingSkipsTheTurn() async throws {
        let runner = try runner([brief(precheck: "gh pr list")])
        now = date(16, 7)

        try await withScriptedSubprocesses(ScriptedSubprocessRunner { _ in .init(output: "\n") }) {
            for firing in runner.look() { await firing.value }
        }

        XCTAssertEqual(sent, [])
        XCTAssertEqual(runner.lastRun(of: "brief")?.outcome, .skipped)
        XCTAssertEqual(runner.lastRun(of: "brief")?.reason, "its check found nothing")
    }

    func testWhatTheCheckPrintsGoesToTheAgentUnderThePrompt() async throws {
        let runner = try runner([brief(precheck: "gh pr list")])
        now = date(16, 7)
        let subprocesses = ScriptedSubprocessRunner { _ in .init(output: "#12 waiting 3d\n") }

        try await withScriptedSubprocesses(subprocesses) {
            for firing in runner.look() { await firing.value }
        }

        XCTAssertEqual(sent, ["Write the brief.\n\nOutput of this routine's check (`gh pr list`):\n\n```\n#12 waiting 3d\n```"])
        let call = try XCTUnwrap(subprocesses.calls.first)
        XCTAssertEqual(call.arguments, ["-lc", "gh pr list"])
        XCTAssertEqual(call.directory, URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertEqual(call.timeout, 24 * 60 * 60, "the check has until the routine next falls")
    }

    func testWhatACheckSaidDecidesWhetherThereIsAnythingToDo() {
        XCTAssertNil(RoutineRunner.check(status: 0, output: " found \n", timedOut: false).nothingToDo)
        XCTAssertEqual(RoutineRunner.check(status: 0, output: " found \n", timedOut: false).output, "found")
        XCTAssertEqual(RoutineRunner.check(status: 2, output: "x", timedOut: false).nothingToDo,
                       "its check failed (status 2)")
        XCTAssertEqual(RoutineRunner.check(status: -1, output: "", timedOut: true).nothingToDo,
                       "its check was still running when the routine next fell")
    }

    // MARK: - Run now

    func testRunNowSendsWithoutArmingBudgetOrAnythingFromTheCheck() async throws {
        let runner = try runner([brief(armed: false, precheck: "gh pr list")])
        runner.budgetRefusal = { _ in "spent" }

        try await withScriptedSubprocesses(ScriptedSubprocessRunner()) {
            await runner.runNow("brief")?.value
        }

        XCTAssertEqual(sent, ["Write the brief."])
        let run = try XCTUnwrap(runner.lastRun(of: "brief"))
        XCTAssertEqual(run.outcome, .started)
        XCTAssertNil(run.scheduledFor)
        XCTAssertNil(runner.runNow("nobody"))
    }

    func testRunNowWithNobodyToSendToIsRefusedAndSaysWhy() async throws {
        unreachable = "no agent 'Chief' in vault"
        let runner = try runner([brief()])

        await runner.runNow("brief")?.value

        XCTAssertEqual(runner.lastRun(of: "brief")?.outcome, .refused)
        XCTAssertEqual(runner.lastRun(of: "brief")?.reason, "no agent 'Chief' in vault")
    }

    // MARK: - Changing routines

    func testArmingStartsWhatIsOwedFromThatMoment() async throws {
        now = date(16, 9)
        let runner = try runner([brief(armed: false)])

        try runner.setArmed("brief", true)
        for firing in runner.look() { await firing.value }

        XCTAssertEqual(sent, [], "this morning's occurrence was before it was armed")
        XCTAssertEqual(runner.routines.first?.armedAt, date(16, 9))
        XCTAssertEqual(runner.nextWake, date(17, 7))
    }

    func testMovingAnArmedRoutinesTimeOwesNothingFromBeforeTheChange() async throws {
        let runner = try runner([brief()])
        now = date(16, 12)
        var moved = brief()
        moved.trigger = .init(at: "11:00")

        try runner.put(moved)
        for firing in runner.look() { await firing.value }

        XCTAssertEqual(sent, [])
        XCTAssertEqual(runner.nextWake, date(17, 11))
    }

    func testChangingAPromptKeepsWhenItWasArmed() throws {
        let runner = try runner([brief()])
        now = date(16, 12)
        var reworded = try XCTUnwrap(runner.routines.first)
        reworded.prompt = "Shorter."

        try runner.put(reworded)

        XCTAssertEqual(runner.routines.first?.armedAt, date(16, 6))
        XCTAssertEqual(store.routines().first?.prompt, "Shorter.")
    }

    func testRemovingARoutineForgetsItAndSaysWhetherThereWasOne() throws {
        let runner = try runner([brief()])

        XCTAssertTrue(try runner.remove("brief"))
        XCTAssertFalse(try runner.remove("brief"))
        XCTAssertEqual(store.routines(), [])
        XCTAssertNil(runner.nextWake)
    }

    func testARoutineArmedByEditingTheFileIsArmedAsOfLaunch() throws {
        try store.save([brief()])

        let runner = try runner([])

        XCTAssertEqual(runner.routines.first?.armedAt, date(16, 6))
        XCTAssertEqual(store.routines().first?.armedAt, date(16, 6))
    }
}
