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

    /// One Projects table: each project once, its last day in its own column
    /// with the reasons its runs were rejected.
    func testTheProjectsTableDrawsEachProjectsLastDay() async throws {
        let dir = try makeTemporaryDirectory(prefix: "fleet-board-last-day")
        let root = dir.appending(path: "alpha")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = KiteloopProject(rootURL: root)
        try project.ensureDirectoryExists()
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        let session = ProjectSession(
            project: project, projectURL: root, orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: root),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: ProjectSessionContext(
                runtimeFactory: { MockAgentRuntime() },
                agentCatalogStore: AgentCatalogStore(storageURL: dir.appending(path: "catalog.json")),
                packageResolver: nil,
                globalConfigStore: GlobalConfigStore(storageURL: dir.appending(path: "global.json")),
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()))
        let registry = ControlSessionRegistry()
        registry.register(session: session, autopilot: BacklogAutopilot())
        let row = PortfolioReport.Row(
            projectName: "alpha", filed: 2, ready: 1, draft: 0, run: 2, merged: 1, rejected: 1,
            awaitingApproval: 0, skippedByCheck: 0, spendUSD: 1.5, idle: 0,
            mergeRate: .init(merged: 1, of: 2, basis: .filed),
            causes: [.init(label: "verify failed", count: 1, example: nil)])

        let host = NSHostingView(rootView: FleetBoard(registry: registry, lastDay: ["alpha": row]))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        try await eventually("the table is laid out") { host.fittingSize.height > 0 }
        XCTAssertFalse(row.isQuiet)
    }
}
