import XCTest
import SwiftUI
import KiteloopCore
@testable import Kiteloop

/// A project's routines on its Autopilot tab: which are its own, and what
/// each row says.
final class AutopilotRoutinesRowTests: XCTestCase {

    private func routine(_ id: String, project: String, armed: Bool = true) -> Routine {
        Routine(id: id, name: id, project: project, agent: "Chief", prompt: "x",
                trigger: .init(at: "07:00", days: ["mon", "tue", "wed", "thu", "fri"]), armed: armed)
    }

    func testARoutineBelongsToTheProjectItNamesByFolderOrByPath() {
        let root = URL(fileURLWithPath: "/tmp/work/vault")
        let all = [routine("a", project: "vault"), routine("b", project: "/tmp/work/vault"),
                   routine("c", project: "other"), routine("d", project: "/tmp/elsewhere/vault-2")]

        XCTAssertEqual(AutopilotRoutinesRow.routines(in: all, for: root).map(\.id), ["a", "b"])
    }

    func testAnArmedRoutineSaysWhenItNextFallsAndAnUnarmedOneDoesNot() {
        let next = Date().addingTimeInterval(3 * 60 * 60 + 60)

        let armed = AutopilotRoutinesRow.line(for: routine("a", project: "vault"), next: next, last: nil)
        let unarmed = AutopilotRoutinesRow.line(for: routine("a", project: "vault", armed: false), next: next, last: nil)

        XCTAssertTrue(armed.hasPrefix("Chief · Weekdays at 07:00 · next "), armed)
        XCTAssertEqual(unarmed, "Chief · Weekdays at 07:00")
    }

    func testTheLastRunReadsAsWhatHappenedAndWhy() {
        let at = Date()
        func run(_ outcome: RoutineRun.Outcome, reason: String? = nil, finished: Bool = false) -> RoutineRun {
            RoutineRun(routine: "a", scheduledFor: at, at: at, outcome: outcome, reason: reason,
                       finishedAt: finished ? at : nil)
        }

        XCTAssertEqual(AutopilotRoutinesRow.outcome(of: run(.started)), "last run in progress")
        XCTAssertEqual(AutopilotRoutinesRow.outcome(of: run(.started, finished: true)), "last run finished")
        XCTAssertEqual(AutopilotRoutinesRow.outcome(of: run(.queued)), "last prompt queued behind a turn")
        XCTAssertEqual(AutopilotRoutinesRow.outcome(of: run(.skipped, reason: "its check failed (status 1)")),
                       "last skipped — its check failed (status 1)")
        XCTAssertEqual(AutopilotRoutinesRow.outcome(of: run(.skipped)), "last skipped — its check found nothing")
        XCTAssertEqual(AutopilotRoutinesRow.outcome(of: run(.refused, reason: "daily budget spent")),
                       "last refused — daily budget spent")
        XCTAssertEqual(AutopilotRoutinesRow.outcome(of: run(.refused)), "last refused — no reason given")
        XCTAssertEqual(AutopilotRoutinesRow.outcome(of: run(.waiting, reason: "project not open in Kiteloop: vault")),
                       "waiting — project not open in Kiteloop: vault")
        XCTAssertEqual(AutopilotRoutinesRow.outcome(of: run(.waiting)), "waiting — its agent cannot be reached")
        XCTAssertTrue(AutopilotRoutinesRow.line(for: routine("a", project: "vault", armed: false), next: nil,
                                                last: run(.queued)).hasSuffix(" · last prompt queued behind a turn"))
    }

    /// A project with routines draws a row for each; one with none draws nothing.
    @MainActor
    func testTheRowDrawsForAProjectsRoutinesAndNotAtAllWithNone() async throws {
        let home = try makeTemporaryDirectory(prefix: "routines-row")
        let runner = RoutineRunner(store: RoutineStore(directory: home))
        let root = URL(fileURLWithPath: "/tmp/work/vault")
        let empty = try await drawnHeight(of: AutopilotRoutinesRow(runner: runner, projectRoot: root))

        try runner.put(routine("brief", project: "vault"))
        try runner.put(routine("review", project: "vault", armed: false))
        let two = try await drawnHeight(of: AutopilotRoutinesRow(runner: runner, projectRoot: root))

        XCTAssertEqual(empty, 0, accuracy: 1)
        XCTAssertGreaterThan(two, 20)
    }

    @MainActor
    private func drawnHeight(of view: some View) async throws -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 640))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
