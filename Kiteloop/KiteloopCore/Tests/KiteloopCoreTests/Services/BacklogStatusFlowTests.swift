import XCTest
@testable import KiteloopCore

final class BacklogStatusFlowTests: XCTestCase {
    func testItemWithNoStatusTokenDefaultsToReady() {
        let item = BacklogParser.parseItemLine("- [ ] task-1 | Just a title", verifyDefault: nil)
        XCTAssertEqual(item?.status, .ready)
    }

    func testStageTokensRoundTrip() {
        for stage in [BacklogItemStatus.draft, .ready, .active, .inReview, .awaitingApproval] {
            let line = "- [ ] t-1 | Title | \(stage.rawValue)"
            let parsed = BacklogParser.parseItemLine(line, verifyDefault: nil)
            XCTAssertEqual(parsed?.status, stage, "parse \(stage.rawValue)")
            let reserialized = BacklogSerializer.serializeItem(parsed!)
            XCTAssertTrue(reserialized.contains(stage.rawValue), "serialize \(stage.rawValue): got \(reserialized)")
        }
    }

    func testDetailLinkSurvivesRoundTrip() {
        let line = "- [ ] task-1 | Title | ready → [detail](backlog/task-1.md)"
        let item = BacklogParser.parseItemLine(line, verifyDefault: nil)
        XCTAssertEqual(item?.detailPath, "backlog/task-1.md")
        XCTAssertTrue(BacklogSerializer.serializeItem(item!).contains("→ [detail](backlog/task-1.md)"))
    }

    func testEpicHeadingsAndDescriptionsRoundTrip() {
        let md = """
        ---
        project: demo
        verify_default: swift build
        ---

        # Demo Backlog

        ## Epic: Onboarding

        Everything a new user sees on first launch.

        - [ ] demo-001 | Welcome screen | ready
        - [ ] demo-002 | Account setup | ready

        ## Epic: Billing

        - [x] demo-003 | Stripe integration
        """

        let file = BacklogParser.parse(md)
        XCTAssertEqual(file.sections.map(\.name), ["Onboarding", "Billing"])
        XCTAssertEqual(file.sections[0].description, "Everything a new user sees on first launch.")
        XCTAssertNil(file.sections[1].description)
        XCTAssertEqual(file.sections[0].items.map(\.id), ["demo-001", "demo-002"])

        // parse → serialize → parse must be stable, including the epic description.
        let reparsed = BacklogParser.parse(BacklogSerializer.serialize(file))
        XCTAssertEqual(reparsed.sections.map(\.name), ["Onboarding", "Billing"])
        XCTAssertEqual(reparsed.sections[0].description, "Everything a new user sees on first launch.")
        XCTAssertNil(reparsed.sections[1].description)
        XCTAssertEqual(reparsed.sections[0].items.map(\.id), ["demo-001", "demo-002"])
        XCTAssertEqual(reparsed.sections[1].items.first?.status, .done)
    }

    func testApprovalGateSendsWorkToAwaitingApproval() {
        var config = BacklogWorkflowConfig.default
        XCTAssertEqual(config.stageAfterAgentReview, .awaitingApproval)
        config.requireHumanApproval = false
        XCTAssertEqual(config.stageAfterAgentReview, .done)
    }

    func testDraftsAreNotAutopilotPickable() {
        let config = BacklogWorkflowConfig.default
        XCTAssertFalse(config.autopilotPickupStages.contains(.draft))
        XCTAssertTrue(config.autopilotPickupStages.contains(.ready))
        XCTAssertEqual(config.effectiveNewItemStage, .draft)
    }
}
