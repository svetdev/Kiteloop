import KiteloopTestSupport
import XCTest
@testable import KiteloopCore

/// Routines on file, the ledger of their runs, and a routine read from a
/// request body.
final class RoutineStoreTests: XCTestCase {

    private func store() throws -> RoutineStore {
        RoutineStore(directory: try makeTemporaryDirectory(prefix: "routines"))
    }

    private let brief = Routine(id: "morning-brief", name: "Morning brief", project: "vault", agent: "Chief",
                                prompt: "Write the brief.", trigger: .init(at: "07:00"), precheck: "true",
                                armed: true, armedAt: Date(timeIntervalSince1970: 1_800_000_000))

    // MARK: - Routines

    func testRoutinesReadBackAsWritten() throws {
        let store = try store()
        XCTAssertEqual(store.routines(), [])

        try store.save([brief])

        XCTAssertEqual(store.routines(), [brief])
    }

    func testARoutineSavedBeforeThereWasAChoiceContinuesItsChat() throws {
        let store = try store()
        let written = #"{"routines":[{"id":"old","name":"Old","project":"vault","agent":"Chief","prompt":"Go.","#
            + #""trigger":{"at":"07:00"},"armed":false}]}"#
        try Data(written.utf8).write(to: store.routinesURL)

        let routine = try XCTUnwrap(store.routines().first)

        XCTAssertNil(routine.conversation)
        XCTAssertFalse(routine.startsFresh)
        XCTAssertEqual(routine.json["conversation"] as? String, "continues")
    }

    func testAFreshRoutineSurvivesASaveAndReload() throws {
        let store = try store()
        var fresh = brief
        fresh.conversation = .fresh

        try store.save([fresh])

        XCTAssertEqual(store.routines(), [fresh])
        XCTAssertTrue(store.routines().first?.startsFresh ?? false)
    }

    func testTheRoutinesFileIsReadableByItsOwnerAlone() throws {
        let store = try store()
        try store.save([brief])

        let attributes = try FileManager.default.attributesOfItem(atPath: store.routinesURL.path(percentEncoded: false))
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    // MARK: - The ledger

    func testARunsLastLineStands() throws {
        let store = try store()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var run = RoutineRun(id: "a", routine: "morning-brief", scheduledFor: at, at: at, outcome: .started)
        store.append(run)
        store.append(RoutineRun(id: "b", routine: "pr-watch", scheduledFor: nil, at: at, outcome: .skipped,
                                reason: "the check found nothing"))
        run.finishedAt = at.addingTimeInterval(60)
        run.reply = "Three things today."
        store.append(run)

        let runs = store.runs(now: at)

        XCTAssertEqual(runs.map(\.id), ["a", "b"])
        XCTAssertEqual(runs.first?.reply, "Three things today.")
        XCTAssertEqual(runs.last?.reason, "the check found nothing")
    }

    func testTheLedgerIsReadableByItsOwnerAlone() throws {
        let store = try store()
        store.append(RoutineRun(routine: "x", scheduledFor: nil, at: .now, outcome: .skipped))

        let attributes = try FileManager.default.attributesOfItem(atPath: store.runsURL.path(percentEncoded: false))
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testRunsPastTheLedgersAgeAndCountAreNotReadBack() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = RoutineRun(id: "old", routine: "x", scheduledFor: nil,
                             at: now.addingTimeInterval(-RoutineStore.retentionAge - 1), outcome: .skipped)
        let recent = (0..<RoutineStore.retentionLimit + 2).map {
            RoutineRun(id: "r\($0)", routine: "x", scheduledFor: nil, at: now, outcome: .skipped)
        }

        let kept = RoutineStore.fold([old] + recent, now: now)

        XCTAssertEqual(kept.count, RoutineStore.retentionLimit)
        XCTAssertEqual(kept.first?.id, "r2")
    }

    // MARK: - Reading a routine from a request

    func testABodyBecomesARoutineOffUntilArmed() throws {
        let body: [String: Any] = ["name": "PR watch", "project": "reviews", "agent": "Reviewer",
                                   "prompt": "Look at these.", "precheck": "gh pr list",
                                   "trigger": ["every": 30, "from": "08:00", "until": "18:00", "days": ["mon"]]]

        let routine = try Routine.parse(body, id: "pr-watch", existing: nil).get()

        XCTAssertEqual(routine.name, "PR watch")
        XCTAssertEqual(routine.trigger, .init(every: 30, from: "08:00", until: "18:00", days: ["mon"]))
        XCTAssertEqual(routine.precheck, "gh pr list")
        XCTAssertFalse(routine.armed)
    }

    func testReplacingARoutineKeepsItsNameAndArmingWhenTheBodyIsSilent() throws {
        let body: [String: Any] = ["project": "vault", "agent": "Chief", "prompt": "Shorter.", "trigger": ["at": "06:30"]]

        let routine = try Routine.parse(body, id: brief.id, existing: brief).get()

        XCTAssertEqual(routine.name, "Morning brief")
        XCTAssertTrue(routine.armed)
        XCTAssertEqual(routine.armedAt, brief.armedAt)
        XCTAssertNil(routine.precheck)
    }

    func testABodyChoosesTheConversationAndASilentOneKeepsTheExistingChoice() throws {
        let body: [String: Any] = ["project": "vault", "agent": "Chief", "prompt": "Go.", "trigger": ["at": "07:00"]]
        var withChoice = body
        withChoice["conversation"] = "fresh"

        let fresh = try Routine.parse(withChoice, id: brief.id, existing: nil).get()
        XCTAssertEqual(fresh.conversation, .fresh)
        XCTAssertTrue(fresh.startsFresh)

        let kept = try Routine.parse(body, id: brief.id, existing: fresh).get()
        XCTAssertEqual(kept.conversation, .fresh)
        XCTAssertNil(try Routine.parse(body, id: brief.id, existing: nil).get().conversation)
    }

    func testAConversationThatIsNeitherChoiceIsRefusedByName() {
        let body: [String: Any] = ["project": "vault", "agent": "Chief", "prompt": "Go.", "trigger": ["at": "07:00"],
                                   "conversation": "sometimes"]

        guard case .failure(let refusal) = Routine.parse(body, id: brief.id, existing: nil) else {
            return XCTFail("parsed")
        }

        XCTAssertEqual(refusal.problems, ["\"conversation\" is \"continues\" or \"fresh\""])
    }

    func testEveryProblemWithABodyIsNamedAtOnce() {
        guard case .failure(let refusal) = Routine.parse(["agent": " "], id: "Bad Id", existing: nil) else {
            return XCTFail("parsed")
        }

        XCTAssertEqual(refusal.problems, [
            "the id takes lowercase letters, digits and hyphens",
            "\"project\" is required", "\"agent\" is required", "\"prompt\" is required",
            "the trigger takes either \"at\" or \"every\""
        ])
        XCTAssertEqual(refusal.reason.components(separatedBy: "; ").count, 5)
    }

    func testARoutineIsWrittenOutAsItWasTaken() {
        let json = brief.json

        XCTAssertEqual(json["id"] as? String, "morning-brief")
        XCTAssertEqual((json["trigger"] as? [String: Any])?["at"] as? String, "07:00")
        XCTAssertEqual(json["armed"] as? Bool, true)
        XCTAssertEqual(json["precheck"] as? String, "true")
        XCTAssertNil(json["armedAt"])
    }

    func testARunIsWrittenOutWithOnlyWhatItHas() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let bare = RoutineRun(id: "a", routine: "x", scheduledFor: nil, at: at, outcome: .refused, reason: "no agent").json
        let full = RoutineRun(id: "b", routine: "x", scheduledFor: at, at: at, outcome: .started, finishedAt: at,
                              reply: "Done.", costUSD: 0.4).json

        XCTAssertEqual(bare["outcome"] as? String, "refused")
        XCTAssertEqual(bare["reason"] as? String, "no agent")
        XCTAssertNil(bare["scheduledFor"])
        XCTAssertEqual(full["scheduledFor"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(full["reply"] as? String, "Done.")
        XCTAssertEqual(full["costUSD"] as? Double, 0.4)
        XCTAssertNotNil(full["finishedAt"])
    }

    // MARK: - What a routine owes

    func testNothingIsOwedBeforeARoutineWasArmedOrWhileItIsNot() {
        let calendar = Calendar(identifier: .gregorian)
        let armedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var routine = brief
        routine.armedAt = armedAt
        let dayLater = armedAt.addingTimeInterval(24 * 60 * 60)

        XCTAssertNil(routine.owed(at: armedAt.addingTimeInterval(60), lastHandled: nil, calendar: calendar))
        XCTAssertNotNil(routine.owed(at: dayLater, lastHandled: nil, calendar: calendar))
        routine.armed = false
        XCTAssertNil(routine.owed(at: dayLater, lastHandled: nil, calendar: calendar))
    }

    func testARoutineWithNoArmingOnRecordOwesNothingFromBeforeNow() {
        var routine = brief
        routine.armedAt = nil

        XCTAssertNil(routine.owed(at: .now, lastHandled: nil, calendar: Calendar(identifier: .gregorian)))
    }

    // MARK: - A routine an event fires

    private let onError = Routine(id: "on-error", name: "On error", project: "/p/vault", agent: "Chief",
                                  prompt: "Look at what failed.", trigger: .init(on: "error"),
                                  armed: true, armedAt: Date(timeIntervalSince1970: 1_800_000_000))

    private func event(_ kind: String = "error", project: String? = "/p/vault",
                       time: Date = Date(timeIntervalSince1970: 1_800_000_060)) -> AppEventFeed.Event {
        AppEventFeed.Event(seq: 1, project: project, kind: kind, subject: "item-1", title: "Run failed", time: time)
    }

    func testABodyNamingAnEventKindIsTakenAndWrittenBack() throws {
        let body: [String: Any] = ["project": "vault", "agent": "Chief", "prompt": "Look.", "trigger": ["on": "error"]]

        let routine = try Routine.parse(body, id: "on-error", existing: nil).get()

        XCTAssertEqual(routine.trigger, .init(on: "error"))
        XCTAssertEqual((routine.json["trigger"] as? [String: Any])?["on"] as? String, "error")
        XCTAssertNil(routine.schedule)
        XCTAssertNil(routine.owed(at: .distantFuture, lastHandled: nil, calendar: Calendar(identifier: .gregorian)))
    }

    func testAnEventRoutineSurvivesASaveAndReload() throws {
        let store = try store()
        try store.save([onError])

        XCTAssertEqual(store.routines(), [onError])
    }

    func testARoutineWrittenBeforeEventsStillRunsOnItsSchedule() throws {
        let store = try store()
        let written = #"{"routines":[{"id":"old","name":"Old","project":"vault","agent":"Chief","prompt":"Go.","#
            + #""trigger":{"at":"07:00"},"armed":true}]}"#
        try Data(written.utf8).write(to: store.routinesURL)

        let routine = try XCTUnwrap(store.routines().first)

        XCTAssertNil(routine.trigger.on)
        XCTAssertNotNil(routine.schedule)
        XCTAssertNil((routine.json["trigger"] as? [String: Any])?["on"])
    }

    func testAnEventKindTheFeedDoesNotPublishIsRefusedByName() {
        let body: [String: Any] = ["project": "vault", "agent": "Chief", "prompt": "Go.", "trigger": ["on": "crash"]]

        guard case .failure(let refusal) = Routine.parse(body, id: "x", existing: nil) else { return XCTFail("parsed") }

        XCTAssertEqual(refusal.problems, ["\"on\" is one of approval, question, complete, error, event"])
    }

    func testAnEventBesideAScheduleIsRefusedByName() {
        for trigger: [String: Any] in [["on": "error", "at": "07:00"], ["on": "error", "every": 30]] {
            let body: [String: Any] = ["project": "vault", "agent": "Chief", "prompt": "Go.", "trigger": trigger]

            guard case .failure(let refusal) = Routine.parse(body, id: "x", existing: nil) else {
                return XCTFail("parsed \(trigger)")
            }

            XCTAssertEqual(refusal.problems,
                           ["\"on\" takes neither \"at\" nor \"every\": a routine fires on an event or on a schedule"])
        }
    }

    func testAnEventFiresAnArmedRoutineOfItsKindInItsProject() {
        XCTAssertTrue(onError.matches(event()))
        XCTAssertTrue(onError.matches(event(project: "/p/vault/")))
        var byName = onError
        byName.project = "vault"
        XCTAssertTrue(byName.matches(event()))
    }

    func testAnEventDoesNotFireAnUnarmedRoutineOrOneOfAnotherKindProjectOrTime() {
        var unarmed = onError
        unarmed.armed = false
        XCTAssertFalse(unarmed.matches(event()))
        XCTAssertFalse(onError.matches(event("complete")))
        XCTAssertFalse(onError.matches(event(project: "/p/other")))
        XCTAssertFalse(onError.matches(event(project: nil)))
        XCTAssertFalse(onError.matches(event(time: Date(timeIntervalSince1970: 1_799_999_999))))
        XCTAssertFalse(brief.matches(event()))
    }

    func testARunAnEventFiredNamesItsKind() {
        let run = RoutineRun(id: "a", routine: "on-error", scheduledFor: nil, at: .now, outcome: .started,
                             event: "error")

        XCTAssertEqual(run.json["event"] as? String, "error")
        XCTAssertNil(RoutineRun(id: "b", routine: "x", scheduledFor: nil, at: .now, outcome: .started).json["event"])
    }
}
