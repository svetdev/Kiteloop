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
}
