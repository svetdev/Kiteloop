import XCTest
@testable import KiteloopMobile

/// The status card's table: one label, one detail, one action per state —
/// never a Pause and a Resume side by side.
final class ProjectStateTests: XCTestCase {

    private func autopilot(state: String?, item: String? = nil, title: String? = nil, step: String? = nil,
                           enabled: Bool = true, detail: String? = nil) -> AutopilotReply {
        AutopilotReply(run: AutopilotRun(state: state, item: item, itemTitle: title, detail: detail,
                                         phaseRail: step.map { PhaseRail(currentStep: $0) }),
                       autonomousWorkEnabled: enabled, sessionSpendUSD: 12, sessionCostCapUSD: 150)
    }

    func testARunningProjectSpinsNamesTheItemAndOffersPause() {
        let state = ProjectState(autopilot: autopilot(state: "running", item: "x", title: "The sitemap lists dining", step: "review"),
                                 project: nil)
        XCTAssertTrue(state.running)
        XCTAssertEqual(state.label, "Running")
        XCTAssertEqual(state.detail, "The sitemap lists dining — review")
        XCTAssertEqual(state.action, .init(title: "Pause after this item", resumes: false))
    }

    func testAHeldProjectOffersOnlyResume() {
        let state = ProjectState(autopilot: autopilot(state: "held", detail: "3 held items"), project: nil)
        XCTAssertFalse(state.running)
        XCTAssertEqual(state.label, "Paused")
        XCTAssertEqual(state.action?.resumes, true)
    }

    func testAnIdleProjectWithAutonomyOnOffersPauseAndOffOffersNothing() {
        let on = ProjectState(autopilot: autopilot(state: "idle", enabled: true), project: nil)
        XCTAssertEqual(on.label, "Idle")
        XCTAssertEqual(on.action?.resumes, false)
        let off = ProjectState(autopilot: autopilot(state: "idle", enabled: false), project: nil)
        XCTAssertEqual(off.label, "Off")
        XCTAssertNil(off.action)
    }

    func testAProjectPausedByPriorityReadsPausedEvenWhenTheAutopilotIsIdle() throws {
        let json = #"{"id": "/p/t", "name": "t", "paused": true}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        let state = ProjectState(autopilot: autopilot(state: "idle", enabled: true), project: project)
        XCTAssertEqual(state.label, "Paused")
        XCTAssertEqual(state.action?.resumes, true)
    }

    func testNoAnswerYetIsOffWithNoLever() {
        let state = ProjectState(autopilot: nil, project: nil)
        XCTAssertEqual(state.label, "Off")
        XCTAssertNil(state.action)
        XCTAssertFalse(state.running)
    }
}
