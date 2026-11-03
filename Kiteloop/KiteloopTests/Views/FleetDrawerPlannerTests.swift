import AppKit
import SwiftUI
import XCTest
import KiteloopCore
@testable import Kiteloop

/// The Planner shares the Fleet drawer: each sidebar row opens it at its own
/// section, and the drawer draws the fleet, the Planner and one Projects table.
@MainActor
final class FleetDrawerPlannerTests: XCTestCase {
    func testEachRowOpensTheDrawerAtItsSectionAndClosesItWhenShowingIt() {
        let planner = FleetDrawer.afterAsking(for: .planner, open: nil, focus: .top)
        XCTAssertEqual(planner.open, .fleet)
        XCTAssertEqual(planner.focus, .planner)

        let moved = FleetDrawer.afterAsking(for: .top, open: .fleet, focus: .planner)
        XCTAssertEqual(moved.open, .fleet, "asking for the other section moves, it does not close")
        XCTAssertEqual(moved.focus, .top)

        XCTAssertNil(FleetDrawer.afterAsking(for: .planner, open: .fleet, focus: .planner).open)
        XCTAssertEqual(FleetDrawer.afterAsking(for: .top, open: .waiting, focus: .top).open, .fleet)
    }

    func testTheDrawerDrawsTheFleetThePlannerAndOneProjectsTable() async throws {
        let dir = try makeTemporaryDirectory(prefix: "fleet-drawer-planner")
        let reading = FleetQuiesce.Reading(quiesced: false, drained: true, running: 0, projects: [])
        let drawer = FleetDrawer(
            status: FleetQuiesceStatus(reading: reading),
            scheduler: CoordinatorRunScheduler(logURL: dir.appending(path: "starts.jsonl")),
            globalConfigStore: GlobalConfigStore(storageURL: dir.appending(path: "global.json")),
            registry: ControlSessionRegistry(),
            refill: CoordinatorQueueRefill(ledgerURL: dir.appending(path: "ledger.jsonl")),
            metricStore: TaskMetricStore(
                metricsURL: dir.appending(path: "task-metrics.jsonl"),
                estimatesURL: dir.appending(path: "task-estimates.jsonl"),
                approvalsURL: dir.appending(path: "task-approvals.jsonl"),
                mergesURL: dir.appending(path: "task-merges.jsonl")),
            groomingLedger: GroomingLedger(url: dir.appending(path: "grooming.jsonl")),
            focus: .planner,
            onQuiesce: {}, onResume: {}, onClose: {})
        let host = NSHostingView(rootView: drawer)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        try await eventually("the drawer is laid out") { host.fittingSize.height > 0 }
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
