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
    private var attributions: [SpendAttribution] = []
    /// What the agent was asked to do, in order: `fresh` for a new chat,
    /// `send` for a prompt.
    private var calls: [String] = []
    /// The id each routine's agent goes by, and what happens inside its turn.
    private var agentIDs: [String: String] = [:]
    private var duringTurn: (() async -> Void)?

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

    private func brief(armed: Bool = true, precheck: String? = nil,
                       conversation: Routine.Conversation? = nil) -> Routine {
        Routine(id: "brief", name: "Morning brief", project: "vault", agent: "Chief", prompt: "Write the brief.",
                trigger: .init(at: "07:00"), precheck: precheck, armed: armed, conversation: conversation)
    }

    /// A started runner holding `routines`, armed as of the clock's reading.
    private func runner(_ routines: [Routine], feed: AppEventFeed = AppEventFeed()) throws -> RoutineRunner {
        let runner = RoutineRunner(store: store, clock: { [unowned self] in self.now },
                                   calendar: { [calendar] in calendar }, feed: feed)
        runner.agent = { [unowned self] routine in
            if let unreachable { return .failure(Routine.Refusal(problems: [unreachable])) }
            return .success(RoutineAgent(
                folder: URL(fileURLWithPath: "/tmp/vault"),
                isBusy: { self.busy },
                send: { text in
                    self.calls.append("send")
                    self.sent.append(text)
                    await self.duringTurn?()
                    return self.turn
                },
                startFresh: { self.calls.append("fresh") },
                agentID: self.agentIDs[routine.id]))
        }
        runner.charge = { [unowned self] cost, _, attribution in
            self.charged.append(cost)
            self.attributions.append(attribution)
        }
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

    func testATurnIsChargedToItsRoutineOnce() async throws {
        turn = RoutineTurn(reply: "Done.", costUSD: 0.4, agentID: "chief-1", model: "opus")
        let runner = try runner([brief()])
        now = date(16, 7)

        for firing in runner.look() { await firing.value }

        XCTAssertEqual(charged, [0.4])
        XCTAssertEqual(attributions, [SpendAttribution(source: .routine, agent: "chief-1",
                                                       routine: "brief", model: "opus")])
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

    // MARK: - A fresh chat

    func testAFreshRoutineStartsANewChatOnceBeforeSendingAndAContinuingOneNever() async throws {
        let runner = try runner([brief(conversation: .fresh)])
        now = date(16, 7)
        for firing in runner.look() { await firing.value }
        XCTAssertEqual(calls, ["fresh", "send"])

        calls = []
        try runner.put(brief(conversation: .continues))
        now = date(17, 7)
        for firing in runner.look() { await firing.value }
        XCTAssertEqual(calls, ["send"])
    }

    func testAFreshRunOpensWithTheLastRunsReplyAndTheFirstWithJustThePrompt() async throws {
        let runner = try runner([brief(conversation: .fresh)])
        now = date(16, 7)
        for firing in runner.look() { await firing.value }

        now = date(17, 7)
        for firing in runner.look() { await firing.value }

        XCTAssertEqual(sent, [
            "Write the brief.",
            "Last run (2026-11-16T07:00:00Z): Three things today.\n\nWrite the brief."
        ])
    }

    func testARunThatWasSkippedOrRefusedLeavesNoNote() {
        let at = date(16, 7)
        for outcome in [RoutineRun.Outcome.skipped, .refused, .queued] {
            XCTAssertNil(RoutineRunner.note(lastRun: RoutineRun(routine: "brief", scheduledFor: at, at: at,
                                                                outcome: outcome, reply: "Said something.")))
        }
        XCTAssertNil(RoutineRunner.note(lastRun: nil))
        XCTAssertNil(RoutineRunner.note(lastRun: RoutineRun(routine: "brief", scheduledFor: at, at: at,
                                                            outcome: .started, reply: "")))
    }

    func testAFreshRoutineAfterARefusedRunSendsOnlyThePrompt() async throws {
        let runner = try runner([brief(conversation: .fresh)])
        runner.budgetRefusal = { _ in "daily budget spent" }
        now = date(16, 7)
        for firing in runner.look() { await firing.value }

        runner.budgetRefusal = nil
        now = date(17, 7)
        for firing in runner.look() { await firing.value }

        XCTAssertEqual(sent, ["Write the brief."])
    }

    func testAFreshRoutineForABusyAgentIsQueuedInItsRunningChatWithNoNote() async throws {
        let runner = try runner([brief(conversation: .fresh)])
        now = date(16, 7)
        for firing in runner.look() { await firing.value }

        calls = []
        busy = true
        now = date(17, 7)
        for firing in runner.look() { await firing.value }

        XCTAssertEqual(calls, ["send"])
        XCTAssertEqual(sent.last, "Write the brief.")
        XCTAssertEqual(runner.lastRun(of: "brief")?.outcome, .queued)
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

    // MARK: - A webhook

    func testAHookFiringSendsARoutineThatIsNotArmedWithTheBodyUnderThePrompt() async throws {
        let runner = try runner([brief(armed: false)])

        await runner.runFromHook("brief", hook: "deploys", body: Data("{\"ref\":\"main\"}".utf8))?.value

        XCTAssertEqual(sent, ["Write the brief.\n\nBody of the webhook call that fired this routine:\n\n```\n{\"ref\":\"main\"}\n```"])
        let run = try XCTUnwrap(runner.lastRun(of: "brief"))
        XCTAssertEqual(run.outcome, .started)
        XCTAssertEqual(run.hook, "deploys")
        XCTAssertNil(run.scheduledFor)
        XCTAssertEqual(run.json["hook"] as? String, "deploys")
        XCTAssertNil(runner.runFromHook("nobody", hook: "deploys", body: Data()))
    }

    func testAHookFiringIsRefusedWhenTheDaysBudgetIsSpent() async throws {
        let runner = try runner([brief(armed: false)])
        runner.budgetRefusal = { _ in "daily budget $5.00 exhausted ($5.20 spent today)" }

        await runner.runFromHook("brief", hook: "deploys", body: Data())?.value

        XCTAssertEqual(sent, [])
        let run = try XCTUnwrap(runner.lastRun(of: "brief"))
        XCTAssertEqual(run.outcome, .refused)
        XCTAssertEqual(run.reason, "daily budget $5.00 exhausted ($5.20 spent today)")
        XCTAssertEqual(run.hook, "deploys")
    }

    func testAHookFiringIsSkippedByACheckThatFindsNothing() async throws {
        let runner = try runner([brief(armed: false, precheck: "gh pr list")])

        try await withScriptedSubprocesses(ScriptedSubprocessRunner { _ in .init(output: "") }) {
            await runner.runFromHook("brief", hook: "deploys", body: Data())?.value
        }

        XCTAssertEqual(sent, [])
        XCTAssertEqual(runner.lastRun(of: "brief")?.outcome, .skipped)
        XCTAssertEqual(runner.lastRun(of: "brief")?.hook, "deploys")
    }

    func testAHookFiringWithNobodyToSendToIsRefusedAndNamesTheHook() async throws {
        unreachable = "no agent 'Chief' in vault"
        let runner = try runner([brief()])

        await runner.runFromHook("brief", hook: "deploys", body: Data())?.value

        XCTAssertEqual(runner.lastRun(of: "brief")?.outcome, .refused)
        XCTAssertEqual(runner.lastRun(of: "brief")?.reason, "no agent 'Chief' in vault")
        XCTAssertEqual(runner.lastRun(of: "brief")?.hook, "deploys")
    }

    func testAHookBodyThatIsNotTextIsNotedAndAnEmptyOneSaysSo() {
        XCTAssertEqual(RoutineRunner.hookBody(Data([0xFF, 0xFE, 0x00])),
                       "The webhook call that fired this routine sent 3 bytes that are not UTF-8 text.")
        XCTAssertEqual(RoutineRunner.hookBody(Data()), "The webhook call that fired this routine sent no body.")
    }

    // MARK: - An event

    private func onError(precheck: String? = nil) -> Routine {
        Routine(id: "on-error", name: "On error", project: "vault", agent: "Chief", prompt: "Look at what failed.",
                trigger: .init(on: "error"), precheck: precheck, armed: true)
    }

    /// A runner on its own feed, listening, and the notice that feed publishes.
    private func publishError(to routines: [Routine]) async throws -> (RoutineRunner, AppEventFeed.Event) {
        let feed = AppEventFeed()
        let runner = try runner(routines, feed: feed)
        try await eventually("the runner to subscribe") { await feed.subscriberCount == 1 }
        let notice = NotificationItem(agentID: "worker", type: .error, title: "Run failed: fix-login", body: "",
                                      itemID: "fix-login", projectPath: "/tmp/vault")
        return (runner, await feed.publish(notice))
    }

    func testAMatchingEventSendsThePromptWithTheEventUnderIt() async throws {
        let (runner, event) = try await publishError(to: [onError()])

        try await eventually("the event's turn to finish") { runner.lastRun(of: "on-error")?.finishedAt != nil }

        let time = ISO8601DateFormatter().string(from: event.time)
        XCTAssertEqual(sent, ["Look at what failed.\n\nThe event that fired this routine:\n\n- kind: error\n"
                              + "- subject: fix-login\n- title: Run failed: fix-login\n- time: \(time)"])
        let run = try XCTUnwrap(runner.lastRun(of: "on-error"))
        XCTAssertEqual(run.outcome, .started)
        XCTAssertEqual(run.event, "error")
        XCTAssertNil(run.scheduledFor)
        XCTAssertEqual(run.json["event"] as? String, "error")
        XCTAssertNil(runner.nextWake, "an event routine sets no clock")
    }

    func testAnEventFiringIsRefusedWhenTheDaysBudgetIsSpent() async throws {
        let feed = AppEventFeed()
        let runner = try runner([onError()], feed: feed)
        runner.budgetRefusal = { _ in "daily budget $5.00 exhausted ($5.20 spent today)" }
        try await eventually("the runner to subscribe") { await feed.subscriberCount == 1 }

        await feed.publish(NotificationItem(agentID: "worker", type: .error, title: "Run failed", body: "",
                                            projectPath: "/tmp/vault"))
        try await eventually("the refusal on record") { runner.lastRun(of: "on-error") != nil }

        XCTAssertEqual(sent, [])
        let run = try XCTUnwrap(runner.lastRun(of: "on-error"))
        XCTAssertEqual(run.outcome, .refused)
        XCTAssertEqual(run.reason, "daily budget $5.00 exhausted ($5.20 spent today)")
        XCTAssertEqual(run.event, "error")
    }

    func testAnEventFiringIsSkippedByACheckThatFindsNothing() async throws {
        try await withScriptedSubprocesses(ScriptedSubprocessRunner { _ in .init(output: "") }) {
            let (runner, _) = try await publishError(to: [onError(precheck: "gh pr list")])
            try await eventually("the skip on record") { runner.lastRun(of: "on-error") != nil }

            XCTAssertEqual(sent, [])
            XCTAssertEqual(runner.lastRun(of: "on-error")?.outcome, .skipped)
            XCTAssertEqual(runner.lastRun(of: "on-error")?.event, "error")
        }
    }

    func testAnEventOfAnotherKindOrProjectFiresNothing() async throws {
        let feed = AppEventFeed()
        let runner = try runner([onError(), brief()], feed: feed)
        try await eventually("the runner to subscribe") { await feed.subscriberCount == 1 }

        let other = await feed.publish(NotificationItem(agentID: "w", type: .complete, title: "Done", body: "",
                                                        projectPath: "/tmp/vault"))
        let elsewhere = await feed.publish(NotificationItem(agentID: "w", type: .error, title: "Failed", body: "",
                                                            projectPath: "/tmp/other"))

        XCTAssertTrue(runner.fire(on: other).isEmpty)
        XCTAssertTrue(runner.fire(on: elsewhere).isEmpty)
        XCTAssertEqual(sent, [])
    }

    func testAnEventARoutinesOwnAgentRaisedDoesNotFireIt() async throws {
        agentIDs = ["on-error": "chief-1"]
        let feed = AppEventFeed()
        let runner = try runner([onError()], feed: feed)
        try await eventually("the runner to subscribe") { await feed.subscriberCount == 1 }

        await feed.publish(NotificationItem(agentID: "chief-1", type: .error, title: "Chief hit an error", body: "",
                                            projectPath: "/tmp/vault"))
        try await eventually("the refusal on record") { runner.lastRun(of: "on-error") != nil }

        XCTAssertEqual(sent, [])
        let run = try XCTUnwrap(runner.lastRun(of: "on-error"))
        XCTAssertEqual(run.outcome, .refused)
        XCTAssertEqual(run.reason, "the routine's own agent raised the event")
        XCTAssertEqual(run.event, "error")
    }

    func testAnEventRaisedInsideARoutinesTurnFiresNoRoutine() async throws {
        agentIDs = ["brief": "chief-1", "on-error": "scout-1"]
        let feed = AppEventFeed()
        let runner = try runner([brief(), onError()], feed: feed)
        try await eventually("the runner to subscribe") { await feed.subscriberCount == 1 }
        // The brief's turn spans the real moment its agent files a notice.
        now = Date().addingTimeInterval(-60)
        duringTurn = { [unowned self] in
            await feed.publish(NotificationItem(agentID: "chief-1", type: .error, title: "Chief hit an error",
                                                body: "", projectPath: "/tmp/vault"))
            self.now = Date().addingTimeInterval(60)
            self.duringTurn = nil
        }

        await runner.runNow("brief")?.value
        try await eventually("the refusal on record") { runner.lastRun(of: "on-error") != nil }

        XCTAssertEqual(sent, ["Write the brief."])
        let run = try XCTUnwrap(runner.lastRun(of: "on-error"))
        XCTAssertEqual(run.outcome, .refused)
        XCTAssertEqual(run.reason, "the event was raised inside a routine's turn")
    }

    func testARunWrittenBeforeHooksStillDecodes() throws {
        let line = #"{"id":"r1","routine":"brief","at":0,"outcome":"started"}"#
        let run = try JSONDecoder().decode(RoutineRun.self, from: Data(line.utf8))
        XCTAssertNil(run.hook)
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
