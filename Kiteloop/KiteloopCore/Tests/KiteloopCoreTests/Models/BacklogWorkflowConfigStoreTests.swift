import XCTest
@testable import KiteloopCore

/// A `backlog-workflow.json` the decoder refused used to read as a project
/// that never had one: `load()` answered the built-in defaults exactly as it
/// does for no file at all, and the next save from Project Settings →
/// Backlog Flow wrote those defaults over the bytes for good. These pin the
/// replacement: the file is moved aside and reported, a project with no file
/// stays silent, and a valid file still loads and normalizes exactly as before.
final class BacklogWorkflowConfigStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try redirectSharedLoggerToTemporaryDirectory(prefix: "backlog-workflow-config-log")
        tempDir = try makeTemporaryDirectory(prefix: "backlog-workflow-config")
    }

    override func tearDownWithError() throws {
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makeInbox(_ name: String = "inbox") -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "\(name).log"))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func quarantined(besides url: URL) throws -> [URL] {
        let prefix = "\(url.lastPathComponent).unreadable-"
        return try FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func testAnUndecodableFileIsKeptAsideAndTheStoreStartsOnDefaults() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "backlog-workflow.json")
        let original = Data(#"{"newItemStage": "draft", "autopilotPickup"#.utf8)
        try original.write(to: url)

        let store = BacklogWorkflowConfigStore(url: url, reporter: reporter)
        let loaded = store.load()
        await reporter.drain()

        XCTAssertEqual(loaded, .default)
        // The point of the whole thing: the bytes the decoder refused are not
        // where the next save would overwrite them, and they are intact beside it.
        XCTAssertFalse(exists(url))
        let aside = try quarantined(besides: url)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(aside.first)), original)
    }

    func testAnUndecodableFileReportsAReadProblemForTheStore() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "backlog-workflow.json")
        try Data("not json at all".utf8).write(to: url)

        let store = BacklogWorkflowConfigStore(url: url, reporter: reporter)
        _ = store.load()
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not read Backlog Flow")
    }

    func testAProjectWithNoConfigFileReportsAndMovesNothing() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "backlog-workflow.json")

        let store = BacklogWorkflowConfigStore(url: url, reporter: reporter)
        let loaded = store.load()
        await reporter.drain()

        XCTAssertEqual(loaded, .default)
        XCTAssertEqual(try quarantined(besides: url).count, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    func testAValidFileStillLoadsAndIsSanitized() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "backlog-workflow.json")
        // Not sanitized as written: the pickup stage names one the flow drops.
        let written = BacklogWorkflowConfig(
            newItemStage: .draft,
            autopilotPickupStages: [.inReview],
            useReviewStage: false,
            requireHumanApproval: true,
            useDraftStage: true
        )
        try JSONEncoder().encode(written).write(to: url)

        let store = BacklogWorkflowConfigStore(url: url, reporter: reporter)
        let loaded = store.load()
        await reporter.drain()

        XCTAssertEqual(loaded, written.sanitized())
        XCTAssertEqual(try quarantined(besides: url).count, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    // MARK: - Stages no agent may pull from

    /// Writes a config file as raw JSON, which is how one gets hand-edited: the
    /// point of these cases is a pickup list the app's own controls cannot
    /// produce, so they must not go through the encoder's idea of a valid one.
    private func writeConfig(pickupStages: [String],
                             requireHumanApproval: Bool = true,
                             useDraftStage: Bool = true,
                             useReviewStage: Bool = true) throws -> URL {
        let url = tempDir.appending(path: "backlog-workflow.json")
        let stages = pickupStages.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {
          "newItemStage": "draft",
          "autopilotPickupStages": [\(stages)],
          "useReviewStage": \(useReviewStage),
          "requireHumanApproval": \(requireHumanApproval),
          "useDraftStage": \(useDraftStage)
        }
        """
        try Data(json.utf8).write(to: url)
        return url
    }

    /// `done` and `awaiting-approval` are both *active* stages, so the old
    /// filter — active stages only — let a hand-edited file point autopilot at
    /// finished work and at work parked on a person.
    func testPickupFromDoneAndAwaitingApprovalIsDroppedOnLoad() throws {
        let url = try writeConfig(pickupStages: ["ready", "done", "awaiting-approval"])

        let loaded = BacklogWorkflowConfigStore(url: url).load()

        XCTAssertEqual(loaded.autopilotPickupStages, [.ready])
    }

    /// And when the file names nothing else, the existing fallback answers —
    /// an empty pickup list is not a project autopilot may pull anything from.
    func testAPickupListOfOnlyUnpickableStagesFallsBackToReady() throws {
        let url = try writeConfig(pickupStages: ["done", "awaiting-approval"])

        let loaded = BacklogWorkflowConfigStore(url: url).load()

        XCTAssertEqual(loaded.autopilotPickupStages, [.ready])
    }

    /// `draft` is human-only — the settings tab has never offered it, and a file
    /// that names it anyway is normalized to what the tab could have written.
    func testPickupFromDraftIsDroppedOnLoad() throws {
        let url = try writeConfig(pickupStages: ["draft", "active"])

        let loaded = BacklogWorkflowConfigStore(url: url).load()

        XCTAssertEqual(loaded.autopilotPickupStages, [.active])
    }

    /// The filter is not a blanket one: a list the tab could have produced comes
    /// back exactly as written, order included.
    func testAPickableListLoadsUnchanged() throws {
        let url = try writeConfig(pickupStages: ["ready", "active", "in-review"])

        let loaded = BacklogWorkflowConfigStore(url: url).load()

        XCTAssertEqual(loaded.autopilotPickupStages, [.ready, .active, .inReview])
    }

    /// A save of the same over-broad list writes the sanitized one, so the file
    /// stops naming the stage rather than being re-normalized on every load.
    func testSaveWritesThePickupListWithUnpickableStagesRemoved() throws {
        let url = tempDir.appending(path: "backlog-workflow.json")
        let config = BacklogWorkflowConfig(
            newItemStage: .ready,
            autopilotPickupStages: [.ready, .awaitingApproval, .done],
            useReviewStage: true,
            requireHumanApproval: true,
            useDraftStage: false
        )

        try BacklogWorkflowConfigStore(url: url).save(config)

        let written = try JSONDecoder().decode(BacklogWorkflowConfig.self,
                                               from: try Data(contentsOf: url))
        XCTAssertEqual(written.autopilotPickupStages, [.ready])
    }

    /// The one definition: what the Backlog Flow tab offers as checkboxes is the
    /// same list `sanitized()` filters against, so the two cannot drift.
    func testThePickableListIsWhatSanitizedKeeps() {
        for approval in [true, false] {
            for draft in [true, false] {
                for review in [true, false] {
                    let config = BacklogWorkflowConfig(
                        newItemStage: .ready,
                        autopilotPickupStages: BacklogItemStatus.allCases,
                        useReviewStage: review,
                        requireHumanApproval: approval,
                        useDraftStage: draft
                    )
                    XCTAssertEqual(config.sanitized().autopilotPickupStages,
                                   config.pickableStages,
                                   "approval:\(approval) draft:\(draft) review:\(review)")
                    XCTAssertFalse(config.pickableStages.contains(.done))
                    XCTAssertFalse(config.pickableStages.contains(.awaitingApproval))
                    XCTAssertFalse(config.pickableStages.contains(.draft))
                }
            }
        }
    }

    func testSaveStillWritesTheSameJSONAsBefore() throws {
        let url = tempDir.appending(path: "backlog-workflow.json")
        let store = BacklogWorkflowConfigStore(url: url)
        let config = BacklogWorkflowConfig(
            newItemStage: .ready,
            autopilotPickupStages: [.ready],
            useReviewStage: true,
            requireHumanApproval: false,
            useDraftStage: false
        )

        try store.save(config)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let expected = try encoder.encode(config.sanitized())
        XCTAssertEqual(try Data(contentsOf: url), expected)
    }
}
