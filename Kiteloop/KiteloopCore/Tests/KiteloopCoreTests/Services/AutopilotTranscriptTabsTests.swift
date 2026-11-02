import XCTest
@testable import KiteloopCore

final class AutopilotTranscriptTabsTests: XCTestCase {
    private let agentlessNodes = ["clean", "harden", "done", "blocked", ""]

    func testTheWorkersStagesShowWorker() {
        for node in ["specify", "worker", "qa"] {
            XCTAssertEqual(AutopilotTranscriptTab.owner(ofNode: node), .worker, node)
        }
    }

    func testTheReviewersStagesShowReviewer() {
        for node in ["reviewer", "reviewer-clarify"] {
            XCTAssertEqual(AutopilotTranscriptTab.owner(ofNode: node), .reviewer, node)
        }
    }

    func testANodeNoAgentRunsOwnsNoTab() {
        for node in agentlessNodes {
            XCTAssertNil(AutopilotTranscriptTab.owner(ofNode: node), node)
        }
    }

    func testThePaneStartsOnWorkerWithNoDot() {
        let tabs = AutopilotTranscriptTabs()
        XCTAssertEqual(tabs.shown, .worker)
        XCTAssertFalse(tabs.isPinned)
        XCTAssertTrue(tabs.unseen.isEmpty)
    }

    func testThePaneFollowsAQAFlowRunThroughEveryStage() {
        var tabs = AutopilotTranscriptTabs()
        tabs.startRun()
        let expected: [(String, AutopilotTranscriptTab)] = [
            ("specify", .worker), ("worker", .worker), ("clean", .worker), ("harden", .worker),
            ("reviewer", .reviewer), ("reviewer-clarify", .reviewer), ("worker", .worker),
            ("reviewer", .reviewer), ("qa", .worker), ("done", .worker)
        ]
        for (node, tab) in expected {
            tabs.enter(node: node)
            XCTAssertEqual(tabs.shown, tab, "after entering \(node)")
        }
    }

    func testANodeNoAgentRunsLeavesTheReviewerShown() {
        for node in agentlessNodes {
            var tabs = AutopilotTranscriptTabs()
            tabs.enter(node: "reviewer")
            tabs.enter(node: node)
            XCTAssertEqual(tabs.shown, .reviewer, node)
        }
    }

    func testAPickDuringARunHoldsThroughEveryLaterStage() {
        for picked in AutopilotTranscriptTab.allCases {
            var tabs = AutopilotTranscriptTabs()
            tabs.startRun()
            tabs.enter(node: "worker")
            tabs.pick(picked, duringRun: true)
            for node in ["specify", "worker", "clean", "harden", "reviewer", "reviewer-clarify", "qa", "done"] {
                tabs.enter(node: node)
                XCTAssertEqual(tabs.shown, picked, "picked \(picked), entered \(node)")
            }
        }
    }

    func testPickingTheShownTabPinsIt() {
        var tabs = AutopilotTranscriptTabs()
        tabs.enter(node: "worker")
        tabs.pick(.worker, duringRun: true)
        tabs.enter(node: "reviewer")
        XCTAssertEqual(tabs.shown, .worker)
    }

    func testAPickWhileIdleSwitchesWithoutPinning() {
        var tabs = AutopilotTranscriptTabs()
        tabs.pick(.reviewer, duringRun: false)
        XCTAssertEqual(tabs.shown, .reviewer)
        XCTAssertFalse(tabs.isPinned)
        tabs.enter(node: "worker")
        XCTAssertEqual(tabs.shown, .worker)
    }

    func testThePinEndsWithTheRun() {
        var tabs = AutopilotTranscriptTabs()
        tabs.startRun()
        tabs.pick(.reviewer, duringRun: true)
        tabs.endRun()
        tabs.startRun()
        tabs.enter(node: "worker")
        XCTAssertEqual(tabs.shown, .worker)
    }

    func testEndingTheRunUnpinsThePaneBeforeAnotherStarts() {
        var tabs = AutopilotTranscriptTabs()
        tabs.startRun()
        tabs.pick(.reviewer, duringRun: true)
        tabs.endRun()
        XCTAssertFalse(tabs.isPinned)
        tabs.enter(node: "worker")
        XCTAssertEqual(tabs.shown, .worker)
    }

    func testANewRunClearsThePinItself() {
        var tabs = AutopilotTranscriptTabs()
        tabs.pick(.reviewer, duringRun: true)
        tabs.startRun()
        XCTAssertFalse(tabs.isPinned)
    }

    func testOutputOnTheHiddenTabCarriesADot() {
        var tabs = AutopilotTranscriptTabs()
        tabs.output(on: .reviewer, sameAgent: false)
        XCTAssertEqual(tabs.unseen, [.reviewer])
    }

    func testOutputOnTheShownTabCarriesNoDot() {
        var tabs = AutopilotTranscriptTabs()
        tabs.output(on: .worker, sameAgent: false)
        XCTAssertTrue(tabs.unseen.isEmpty)
    }

    func testOneAgentInBothRolesCarriesNoDot() {
        var tabs = AutopilotTranscriptTabs()
        tabs.output(on: .reviewer, sameAgent: true)
        XCTAssertTrue(tabs.unseen.isEmpty)
    }

    func testShowingATabByFollowingTheRunClearsItsDot() {
        var tabs = AutopilotTranscriptTabs()
        tabs.output(on: .reviewer, sameAgent: false)
        tabs.enter(node: "reviewer")
        XCTAssertTrue(tabs.unseen.isEmpty)
    }

    func testShowingATabByPickingItClearsItsDot() {
        var tabs = AutopilotTranscriptTabs()
        tabs.output(on: .reviewer, sameAgent: false)
        tabs.pick(.reviewer, duringRun: true)
        XCTAssertTrue(tabs.unseen.isEmpty)
    }

    func testAPinnedPaneStillDotsTheTabItHides() {
        var tabs = AutopilotTranscriptTabs()
        tabs.pick(.worker, duringRun: true)
        tabs.enter(node: "reviewer")
        tabs.output(on: .reviewer, sameAgent: false)
        XCTAssertEqual(tabs.unseen, [.reviewer])
    }

    func testANewRunClearsEveryDot() {
        var tabs = AutopilotTranscriptTabs()
        tabs.output(on: .reviewer, sameAgent: false)
        tabs.startRun()
        XCTAssertTrue(tabs.unseen.isEmpty)
    }
}
