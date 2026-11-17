import XCTest
@testable import KiteloopCore

/// The Routines page's editor holds a routine as a form does — a time as a
/// time, the days as a set — and writes it back as a routine keeps it.
final class RoutineDraftTests: XCTestCase {

    private func routine(_ trigger: Routine.Trigger, precheck: String? = nil, armed: Bool = true) -> Routine {
        Routine(id: "brief", name: "Morning brief", project: "vault", agent: "Claude", prompt: "Brief me.",
                trigger: trigger, precheck: precheck, armed: armed, armedAt: Date(timeIntervalSince1970: 100))
    }

    func testANewDraftIsWeekdaysAtNineAndNotArmed() {
        let draft = RoutineDraft(agent: "Claude")
        XCTAssertEqual(draft.trigger, Routine.Trigger(at: "09:00", days: ["mon", "tue", "wed", "thu", "fri"]))
        XCTAssertEqual(draft.scheduleWords, "Weekdays at 09:00")
        XCTAssertFalse(draft.armed)
        XCTAssertEqual(draft.agent, "Claude")
    }

    func testADailyRoutineIsReadAndWrittenBackUnchanged() {
        let daily = routine(Routine.Trigger(at: "07:30", days: ["mon", "fri"]), precheck: "git status --short")
        let draft = RoutineDraft(routine: daily)
        XCTAssertEqual(draft.pattern, .daily)
        XCTAssertEqual(draft.atMinute, 7 * 60 + 30)
        XCTAssertEqual(draft.days, [2, 6])
        XCTAssertEqual(draft.routine(id: "other", project: "elsewhere", existing: daily), daily)
    }

    func testAnIntervalRoutineIsReadAndWrittenBackUnchanged() {
        let poll = routine(Routine.Trigger(every: 20, from: "08:00", until: "18:00"), armed: false)
        let draft = RoutineDraft(routine: poll)
        XCTAssertEqual(draft.pattern, .interval)
        XCTAssertEqual([draft.everyMinutes, draft.fromMinute, draft.untilMinute], [20, 480, 1080])
        XCTAssertEqual(draft.days, RoutineDraft.everyDay)
        XCTAssertEqual(draft.routine(id: "other", project: "elsewhere", existing: poll), poll)
    }

    func testTheConversationChoiceSurvivesTheRoundTrip() {
        var fresh = routine(Routine.Trigger(at: "07:00"))
        fresh.conversation = .fresh
        let draft = RoutineDraft(routine: fresh)
        XCTAssertEqual(draft.conversation, .fresh)
        XCTAssertEqual(draft.routine(id: "brief", project: "vault", existing: fresh), fresh)

        let older = routine(Routine.Trigger(at: "07:00"))
        XCTAssertEqual(RoutineDraft(routine: older).conversation, .continues, "a routine with no choice continues")
        XCTAssertEqual(RoutineDraft(routine: older).routine(id: "brief", project: "vault", existing: older), older)

        var switched = RoutineDraft(routine: older)
        switched.conversation = .fresh
        XCTAssertTrue(switched.routine(id: "brief", project: "vault", existing: older).startsFresh)
    }

    /// An interval with no hours runs all day, and is written back with none.
    func testAnIntervalWithNoHoursKeepsTheWholeDay() {
        let poll = routine(Routine.Trigger(every: 60))
        let draft = RoutineDraft(routine: poll)
        XCTAssertEqual([draft.fromMinute, draft.untilMinute], [0, 1439])
        XCTAssertEqual(draft.trigger, Routine.Trigger(every: 60))
        XCTAssertEqual(draft.scheduleWords, "Every 60 min")
    }

    func testANewRoutineTakesTheIdAndProjectItIsGivenAndTrimsWhatWasTyped() {
        var draft = RoutineDraft(agent: "Claude")
        draft.name = "  Friday review \n"
        draft.prompt = "\nReview the week.\n"
        draft.precheck = "   "
        let made = draft.routine(id: "friday-review", project: "vault")
        XCTAssertEqual(made, Routine(id: "friday-review", name: "Friday review", project: "vault", agent: "Claude",
                                     prompt: "Review the week.",
                                     trigger: Routine.Trigger(at: "09:00", days: ["mon", "tue", "wed", "thu", "fri"])))
        XCTAssertEqual(made.problems, [])
    }

    func testAnIdIsTheNameInLowercaseWordsNumberedWhenTaken() {
        XCTAssertEqual(RoutineDraft.id(forName: "Morning Brief!", taken: []), "morning-brief")
        XCTAssertEqual(RoutineDraft.id(forName: "Morning brief", taken: ["morning-brief"]), "morning-brief-2")
        XCTAssertEqual(RoutineDraft.id(forName: "Morning brief", taken: ["morning-brief", "morning-brief-2"]), "morning-brief-3")
        XCTAssertEqual(RoutineDraft.id(forName: "…", taken: []), "routine")
        XCTAssertTrue(Routine.isValidID(RoutineDraft.id(forName: "Über PR-poll №7", taken: [])))
    }

    func testAnEmptyDraftSaysEverythingThatIsMissingInTheOrderTheFormAsks() {
        var draft = RoutineDraft()
        draft.days = []
        XCTAssertEqual(draft.problems, [
            "Give the routine a name.", "Choose the agent the prompt goes to.",
            "Write the prompt to send.", "Choose at least one day."
        ])
    }

    func testAnIntervalSaysWhenItsNumbersCannotBeASchedule() {
        var draft = RoutineDraft(agent: "Claude")
        draft.name = "Poll"
        draft.prompt = "Look."
        draft.pattern = .interval
        XCTAssertEqual(draft.problems, [])
        draft.everyMinutes = 0
        draft.fromMinute = 19 * 60
        XCTAssertEqual(draft.problems, ["The interval is at least one minute.", "The hours end before they start."])
        XCTAssertNil(draft.scheduleWords)
    }

    /// A trigger nobody could have saved from the form still opens in it.
    func testATriggerThatDoesNotParseOpensOnTheDefaults() {
        let draft = RoutineDraft(routine: routine(Routine.Trigger(at: "soon", days: ["someday"])))
        XCTAssertEqual(draft.atMinute, 9 * 60)
        XCTAssertEqual(draft.days, [])
        XCTAssertEqual(draft.problems, ["Choose at least one day."])
    }

    // MARK: - The budget

    func testEditingARoutineKeepsItsBudgetIncludingWhatTheFormHasNoFieldFor() {
        var capped = routine(.init(at: "07:00"))
        capped.budget = SpendBudget(ceilingUSD: 5, period: .month, warnAtFraction: 0.5, consequence: .refuse)
        var draft = RoutineDraft(routine: capped)
        draft.prompt = "Shorter."

        XCTAssertTrue(draft.limitsSpend)
        XCTAssertEqual(draft.ceiling, "5.00")
        XCTAssertEqual(draft.period, .month)
        XCTAssertEqual(draft.routine(id: "ignored", project: "ignored", existing: capped).budget, capped.budget)
    }

    func testARoutineWithoutABudgetOpensWithNoneAndIsSavedWithNone() {
        let plain = routine(.init(at: "07:00"))
        let draft = RoutineDraft(routine: plain)
        XCTAssertFalse(draft.limitsSpend)
        XCTAssertNil(draft.budget)
        XCTAssertEqual(draft.routine(id: "brief", project: "vault", existing: plain), plain)
        XCTAssertNil(RoutineDraft(agent: "Claude").routine(id: "new", project: "vault").budget)
    }

    func testABudgetIsSetChangedAndCleared() {
        var capped = routine(.init(at: "07:00"))
        var draft = RoutineDraft(routine: capped)
        draft.limitsSpend = true
        draft.ceiling = " 2,50 "
        draft.period = .month
        XCTAssertEqual(draft.budgetProblems, [])
        capped = draft.routine(id: "brief", project: "vault", existing: capped)
        XCTAssertEqual(capped.budget, SpendBudget(ceilingUSD: 2.5, period: .month, consequence: .refuse))
        XCTAssertEqual(capped.budgetWords, "up to $2.50 a month")

        draft = RoutineDraft(routine: capped)
        draft.ceiling = "0.125"
        XCTAssertEqual(draft.routine(id: "brief", project: "vault", existing: capped).budget?.ceilingUSD, 0.125)
        XCTAssertEqual(RoutineDraft(routine: draft.routine(id: "brief", project: "vault", existing: capped)).ceiling, "0.125")

        draft.limitsSpend = false
        let cleared = draft.routine(id: "brief", project: "vault", existing: capped)
        XCTAssertNil(cleared.budget)
        XCTAssertNil(cleared.budgetWords)
    }

    /// The form refuses a ceiling in the words the API refuses it in.
    func testACeilingThatIsNotAboveZeroIsRefusedAsTheAPIRefusesIt() {
        var draft = RoutineDraft(agent: "Claude")
        draft.name = "Brief"
        draft.prompt = "Brief me."
        draft.limitsSpend = true
        for typed in ["", "0", "-3", "a lot"] {
            draft.ceiling = typed
            let api = SpendBudget.parse(["ceilingUSD": Double(typed) ?? 0]).problems
            XCTAssertEqual(draft.budgetProblems, api, typed)
            XCTAssertEqual(draft.problems, api, typed)
        }
        draft.ceiling = "3"
        XCTAssertEqual(draft.problems, [])
        draft.ceiling = ""
        draft.limitsSpend = false
        XCTAssertEqual(draft.problems, [], "a budget switched off is not checked")
    }

    // MARK: - An event

    func testAnEventRoutineIsReadAndWrittenBackUnchanged() {
        let onError = routine(Routine.Trigger(on: "error"))
        let draft = RoutineDraft(routine: onError)
        XCTAssertEqual(draft.kind, .event)
        XCTAssertEqual(draft.event, "error")
        XCTAssertEqual(draft.trigger, Routine.Trigger(on: "error"))
        XCTAssertEqual(draft.routine(id: "ignored", project: "ignored", existing: onError), onError)
        XCTAssertEqual(draft.problems, [])
        XCTAssertEqual(draft.scheduleWords, "When something fails")
    }

    func testChoosingAnEventWritesOnlyTheEvent() {
        var draft = RoutineDraft(routine: routine(Routine.Trigger(every: 20, from: "08:00", days: ["mon"])))
        draft.kind = .event
        draft.event = "question"
        XCTAssertEqual(draft.trigger, Routine.Trigger(on: "question"))
        draft.kind = .clock
        XCTAssertEqual(draft.trigger, Routine.Trigger(every: 20, from: "08:00", days: ["mon"]),
                       "the schedule is still there to go back to")
    }

    /// The kinds offered are the feed's own, each with words of its own.
    func testTheEventKindsOfferedAreTheOnesTheFeedPublishes() {
        let kinds = NotificationItem.NotificationType.allCases.map(\.rawValue)
        XCTAssertEqual(RoutineDraft.eventKinds, kinds)
        XCTAssertEqual(RoutineDraft.eventChoices(current: "error"), kinds)
        XCTAssertEqual(Set(kinds.map(RoutineDraft.eventLabel)).count, kinds.count)
        XCTAssertEqual(RoutineDraft.eventLabel("approval"), "An approval is needed")
        for kind in kinds {
            var draft = RoutineDraft()
            draft.kind = .event
            draft.event = kind
            XCTAssertEqual(draft.triggerProblems, [], kind)
            XCTAssertNotNil(draft.scheduleWords, kind)
        }
        XCTAssertEqual(RoutineDraft().event, kinds.first)
    }

    /// A kind the feed does not publish — written in the file by hand — is
    /// kept, offered, and refused in the words the API refuses it in.
    func testAnUnknownEventKindIsKeptAndRefusedAsTheAPIRefusesIt() throws {
        let odd = routine(Routine.Trigger(on: "deploy"))
        let draft = RoutineDraft(routine: odd)
        XCTAssertEqual(draft.event, "deploy")
        XCTAssertEqual(RoutineDraft.eventChoices(current: "deploy").last, "deploy")
        XCTAssertEqual(RoutineDraft.eventLabel("deploy"), "deploy (not an event kind)")
        XCTAssertNil(draft.scheduleWords)

        let body: [String: Any] = ["project": "vault", "agent": "Claude", "prompt": "Brief me.", "trigger": ["on": "deploy"]]
        guard case .failure(let refusal) = Routine.parse(body, id: "brief", existing: nil) else {
            return XCTFail("the API takes an unknown event kind")
        }
        XCTAssertEqual(draft.triggerProblems, refusal.problems)
        XCTAssertEqual(draft.problems, refusal.problems)
    }

    // MARK: - A folder

    func testAWatchedRoutineIsReadAndWrittenBackUnchanged() {
        let watched = routine(Routine.Trigger(watch: "notes/inbox"))
        var draft = RoutineDraft(routine: watched)
        draft.prompt = "File what arrived."

        XCTAssertEqual(draft.kind, .folder)
        XCTAssertEqual(draft.watch, "notes/inbox")
        XCTAssertEqual(draft.trigger, Routine.Trigger(watch: "notes/inbox"))
        XCTAssertEqual(draft.routine(id: "ignored", project: "ignored", existing: watched).trigger,
                       Routine.Trigger(watch: "notes/inbox"))
        XCTAssertEqual(draft.problems, [])
        XCTAssertEqual(draft.scheduleWords, "When the folder notes/inbox changes")
        XCTAssertEqual(RoutineDraft(routine: routine(.init(at: "07:00"))).kind, .clock)
    }

    /// A folder outside the project, or none, is refused in the words the API
    /// refuses it in — and a new routine can be given one.
    func testAFolderOutsideTheProjectIsRefusedAsTheAPIRefusesIt() throws {
        var draft = RoutineDraft(agent: "Claude")
        draft.name = "Inbox"
        draft.prompt = "File what arrived."
        draft.kind = .folder
        for outside in ["", "/etc", "~/notes", "notes/../../elsewhere"] {
            draft.watch = outside
            let body: [String: Any] = ["project": "vault", "agent": "Claude", "prompt": "File.", "trigger": ["watch": outside]]
            guard case .failure(let refusal) = Routine.parse(body, id: "inbox", existing: nil) else {
                return XCTFail("the API takes the folder \(outside)")
            }
            XCTAssertEqual(draft.triggerProblems, refusal.problems, outside)
            XCTAssertEqual(draft.problems, refusal.problems, outside)
            XCTAssertNil(draft.scheduleWords, outside)
        }
        draft.watch = " notes/inbox "
        XCTAssertEqual(draft.problems, [])
        let made = draft.routine(id: "inbox", project: "vault")
        XCTAssertEqual(made.trigger, Routine.Trigger(watch: "notes/inbox"))
        XCTAssertEqual(made.problems, [])
    }

    /// Days left unchosen on the schedule do not stop an event or a folder.
    func testAScheduleProblemDoesNotStopAnotherKindOfTrigger() {
        var draft = RoutineDraft(agent: "Claude")
        draft.name = "Inbox"
        draft.prompt = "File what arrived."
        draft.days = []
        XCTAssertEqual(draft.problems, ["Choose at least one day."])
        draft.kind = .event
        XCTAssertEqual(draft.problems, [])
    }
}
