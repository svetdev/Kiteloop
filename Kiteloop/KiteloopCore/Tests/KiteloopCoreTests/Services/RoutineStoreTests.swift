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
}
