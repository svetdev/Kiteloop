import XCTest
import KiteloopCore
@testable import Kiteloop

/// A project's autopilot run history belongs to that project. Before this,
/// `historyURL` was one static path under `~/.kiteloop/`, so whichever of two
/// open projects finished a run last overwrote the other's history — and an
/// autopilot configured with no project (four tests did exactly that) read
/// and wrote the developer's real home file. Covers the fix: history now
/// lives at `<project>/.kiteloop/autopilot-history.json`, and an autopilot
/// with no project root touches no file at all.
@MainActor
final class BacklogAutopilotHistoryTests: XCTestCase {

    private func makeAutopilot(
        projectPath: String?,
        reporter: StoreProblemReporter = .shared
    ) -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(storageURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("global-config-\(UUID().uuidString).json"))
            ),
            configURL: nil,
            projectPath: projectPath,
            projectName: "proj",
            reporter: reporter
        )
        return autopilot
    }

    private func record(id: String, outcomes: [String]) -> BacklogAutopilot.RunRecord {
        BacklogAutopilot.RunRecord(
            id: id,
            startedAt: Date(),
            completedAt: nil,
            items: outcomes.enumerated().map { index, outcome in
                BacklogAutopilot.RunRecord.ItemRecord(
                    id: "\(id)-\(index)", title: "Item \(index)", outcome: outcome,
                    duration: 10, executionID: nil
                )
            },
            workerAgentName: "worker",
            reviewerAgentName: "reviewer"
        )
    }

    // MARK: - Per-project isolation

    func testTwoProjectsKeepSeparateHistoryFiles() throws {
        let projectA = try makeTemporaryDirectory(prefix: "autopilot-history-a")
        let projectB = try makeTemporaryDirectory(prefix: "autopilot-history-b")

        let autopilotA = makeAutopilot(projectPath: projectA.path(percentEncoded: false))
        autopilotA.stageCurrentRunRecordForTesting(record(id: "run-a", outcomes: ["done"]))
        autopilotA.finalizeRunRecordForTesting()

        let autopilotB = makeAutopilot(projectPath: projectB.path(percentEncoded: false))
        autopilotB.stageCurrentRunRecordForTesting(record(id: "run-b", outcomes: ["blocked"]))
        autopilotB.finalizeRunRecordForTesting()

        let reloadedA = makeAutopilot(projectPath: projectA.path(percentEncoded: false))
        reloadedA.reloadHistoryForTesting()
        let reloadedB = makeAutopilot(projectPath: projectB.path(percentEncoded: false))
        reloadedB.reloadHistoryForTesting()

        XCTAssertEqual(reloadedA.runHistory.map(\.id), ["run-a"])
        XCTAssertEqual(reloadedB.runHistory.map(\.id), ["run-b"])

        let fileA = KiteloopProject(rootURL: projectA).autopilotHistoryURL
        let fileB = KiteloopProject(rootURL: projectB).autopilotHistoryURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileA.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path(percentEncoded: false)))
        XCTAssertNotEqual(try Data(contentsOf: fileA), try Data(contentsOf: fileB))
    }

    // MARK: - No project, no file

    func testNoProjectPathTouchesNoFile() throws {
        let legacyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kiteloop/autopilot-history.json")
        let existedBefore = FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false))
        let attributesBefore = try? FileManager.default.attributesOfItem(
            atPath: legacyURL.path(percentEncoded: false))
        let mtimeBefore = attributesBefore?[.modificationDate] as? Date

        let autopilot = makeAutopilot(projectPath: nil)
        autopilot.stageCurrentRunRecordForTesting(record(id: "run-homeless", outcomes: ["done"]))
        autopilot.finalizeRunRecordForTesting()
        autopilot.reloadHistoryForTesting()

        XCTAssertEqual(autopilot.runHistory.map(\.id), ["run-homeless"],
                       "with no project root, history lives in memory only — the save is a no-op, not a failure")

        let existedAfter = FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false))
        let attributesAfter = try? FileManager.default.attributesOfItem(
            atPath: legacyURL.path(percentEncoded: false))
        let mtimeAfter = attributesAfter?[.modificationDate] as? Date

        XCTAssertEqual(existedBefore, existedAfter, "the legacy shared file must not be created")
        XCTAssertEqual(mtimeBefore, mtimeAfter, "the legacy shared file must not be written to")
    }

    // MARK: - Round trip

    func testHistoryRoundTripsNewestFirstCappedAtThirty() throws {
        let project = try makeTemporaryDirectory(prefix: "autopilot-history-roundtrip")
        let autopilot = makeAutopilot(projectPath: project.path(percentEncoded: false))

        for index in 0..<32 {
            autopilot.stageCurrentRunRecordForTesting(record(id: "run-\(index)", outcomes: ["done"]))
            autopilot.finalizeRunRecordForTesting()
        }

        XCTAssertEqual(autopilot.runHistory.count, 30)
        XCTAssertEqual(autopilot.runHistory.first?.id, "run-31", "the most recently finalized run leads")
        XCTAssertEqual(autopilot.runHistory.last?.id, "run-2", "the oldest two runs fell off the 30-cap")

        let reloaded = makeAutopilot(projectPath: project.path(percentEncoded: false))
        reloaded.reloadHistoryForTesting()

        XCTAssertEqual(reloaded.runHistory.map(\.id), autopilot.runHistory.map(\.id))
    }

    // MARK: - Durable writes and quarantine on read

    private func quarantined(besides url: URL) throws -> [URL] {
        let prefix = "\(url.lastPathComponent).unreadable-"
        return try FileManager.default
            .contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// A history file the decoder refuses is moved aside, not overwritten by the
    /// next finalized run — the same instinct `GlobalConfigStore` already has for
    /// its own config file.
    func testUnreadableHistoryIsQuarantinedRatherThanOverwritten() async throws {
        let project = try makeTemporaryDirectory(prefix: "autopilot-history-quarantine")
        let historyURL = KiteloopProject(rootURL: project).autopilotHistoryURL
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ not valid history".utf8)
        try original.write(to: historyURL)

        let inbox = NotificationStore(notificationsURL: project.appendingPathComponent("inbox.log"))
        let reporter = StoreProblemReporter(notifications: inbox)
        let autopilot = makeAutopilot(projectPath: project.path(percentEncoded: false), reporter: reporter)
        await reporter.drain()

        XCTAssertTrue(autopilot.runHistory.isEmpty, "starting fresh is still all a refused file leaves the store")
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not read \(BacklogAutopilot.historyStoreName)")

        autopilot.stageCurrentRunRecordForTesting(record(id: "run-fresh", outcomes: ["done"]))
        autopilot.finalizeRunRecordForTesting()

        let aside = try quarantined(besides: historyURL)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(aside.first)), original,
                       "the quarantined file still holds the bytes the decoder refused")
        XCTAssertEqual(autopilot.runHistory.map(\.id), ["run-fresh"],
                       "the fresh history holds only the new run, not a resurrection of the refused one")
    }

    /// A save that cannot land — a directory sits where the history file
    /// belongs — is reported through the history's own store name, and the run
    /// just finished stays in memory: the panel keeps showing it even though the
    /// write failed.
    func testASaveThatCannotLandIsReportedAndHistoryIsUnchangedInMemory() async throws {
        let project = try makeTemporaryDirectory(prefix: "autopilot-history-blocked")
        let historyURL = KiteloopProject(rootURL: project).autopilotHistoryURL

        let inbox = NotificationStore(notificationsURL: project.appendingPathComponent("inbox.log"))
        let reporter = StoreProblemReporter(notifications: inbox)
        let autopilot = makeAutopilot(projectPath: project.path(percentEncoded: false), reporter: reporter)

        // Blocked only now, after the clean initial load: a directory in the
        // history file's place would also fail the *read*, and this test is
        // about the write path alone.
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)

        autopilot.stageCurrentRunRecordForTesting(record(id: "run-blocked", outcomes: ["done"]))
        autopilot.finalizeRunRecordForTesting()
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not write \(BacklogAutopilot.historyStoreName)")
        XCTAssertEqual(autopilot.runHistory.map(\.id), ["run-blocked"],
                       "reporting the failure is all this does — the run just finished is not rolled back")
    }
}
