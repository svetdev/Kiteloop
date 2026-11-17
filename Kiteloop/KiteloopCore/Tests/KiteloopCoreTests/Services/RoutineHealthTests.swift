import XCTest
@testable import KiteloopCore

/// Which routines `GET /health` lists, and at what severity.
final class RoutineHealthTests: XCTestCase {

    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func routine(_ id: String) -> Routine {
        Routine(id: id, name: id, project: "vault", agent: "Chief", prompt: "Go.", trigger: .init(at: "07:00"))
    }

    private func entries(_ outcomes: [String: RoutineRun.Outcome], reasons: [String: String] = [:],
                         routines ids: [String]) -> [RoutineHealth.Entry] {
        RoutineHealth.attention(routines: ids.map(routine)) { id in
            outcomes[id].map { RoutineRun(routine: id, scheduledFor: nil, at: self.at, outcome: $0, reason: reasons[id]) }
        }
    }

    func testRefusedIsAnErrorWithItsReason() throws {
        let list = entries(["brief": .refused], reasons: ["brief": "the day's budget is spent"], routines: ["brief"])

        let entry = try XCTUnwrap(list.first)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(entry.severity, .error)
        XCTAssertEqual(entry.outcome, .refused)
        XCTAssertEqual(entry.reason, "the day's budget is spent")
        XCTAssertEqual(entry.routine, "brief")
        XCTAssertEqual(entry.project, "vault")
        XCTAssertEqual(entry.at, at)
    }

    func testWaitingIsAWarningAndSkippedIsInfo() {
        let list = entries(["owed": .waiting, "quiet": .skipped], routines: ["owed", "quiet"])

        XCTAssertEqual(list.map(\.routine), ["owed", "quiet"])
        XCTAssertEqual(list.map(\.severity), [.warning, .info])
    }

    func testStartedQueuedAndNeverRunAreNotListed() {
        let list = entries(["ran": .started, "behind": .queued], routines: ["ran", "behind", "never"])

        XCTAssertTrue(list.isEmpty)
    }

    func testJSONCarriesEveryFieldAndReasonOnlyWhenThereIsOne() {
        let list = entries(["lost": .refused, "owed": .waiting], reasons: ["lost": "nobody to send it to"],
                           routines: ["lost", "owed"])

        let lost = list[0].json
        XCTAssertEqual(lost["routine"] as? String, "lost")
        XCTAssertEqual(lost["project"] as? String, "vault")
        XCTAssertEqual(lost["outcome"] as? String, "refused")
        XCTAssertEqual(lost["severity"] as? String, "error")
        XCTAssertEqual(lost["reason"] as? String, "nobody to send it to")
        XCTAssertEqual(lost["at"] as? String, ISO8601DateFormatter().string(from: at))
        XCTAssertNil(list[1].json["reason"])
        XCTAssertEqual(list[1].json["severity"] as? String, "warning")
    }
}
