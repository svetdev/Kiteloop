import XCTest
import KiteloopCore
@testable import Kiteloop

/// Whole runs, driven through `start()` and the real workflow engine: the
/// worker's and the reviewer's turns are the only thing stood in for, by
/// handing the engine the event their sessions would have produced.
///
/// What they pin is the pre-review gate (`allowReviewerToRun`) in the loop it
/// guards — an empty run, a red verify and a worker that ran out of turns each
/// end the item before the reviewer is ever triggered, and each ending is
/// carried through the rest of the item's exit path to the status and the
/// Notes a person reads. A run that clears the gate and passes review reaches
/// the approval gate. And, before any of it, the base's own health check
/// (`noteBaseHealth`), which a start runs once per base tip.
@MainActor
final class BacklogAutopilotPreReviewGateRunTests: XCTestCase {

    private var root: URL!
    private var orchestrator: Orchestrator!
    /// Retained here: the autopilot holds its view model weakly.
    private var backlog: BacklogViewModel!
    /// Every agent `triggerAgent` woke for this project, in order.
    private let triggers = TriggerLog()
    private var triggered: [String] { triggers.agentIDs }
    private var observer: NSObjectProtocol?

    override func tearDown() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        super.tearDown()
    }

    // MARK: - The gate closes, and the reviewer is never triggered

    /// A live-tree run whose own `verify:` is red ends at the gate: blocked on
    /// the verify's signal, never reviewed, and back to nobody's queue.
    func testARedVerifyEndsTheRunBeforeTheReviewer() async throws {
        let autopilot = try await makeProject(verify: "false", git: false)

        let result = try await runOneItem(autopilot) { execID in
            self.complete("worker", in: execID, output: [:])
        }

        guard case .blocked(let reason) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(reason, "verify failed (exit 1)")
        XCTAssertEqual(autopilot.closedReviewGateSignalForTesting, reason)
        XCTAssertEqual(backlog.item(withID: "item-1")?.status, .blocked)
        XCTAssertFalse(triggered.contains("reviewer"), "the gate closed; the reviewer must not run: \(triggered)")
        XCTAssertTrue(autopilot.log.contains { $0.message == "Skipping review — \(reason); ending the run here" })
    }

    /// A worker that spent its whole turn budget handed off unfinished work:
    /// that is what the run ends saying — not a verify failure, and not a diff
    /// for the reviewer — and the item's Notes say it too.
    func testAWorkerCutShortEndsTheRunOnItsTurnBudget() async throws {
        let autopilot = try await makeProject(verify: "false", git: false)

        let result = try await runOneItem(autopilot) { execID in
            self.complete("worker", in: execID, output: [
                StreamEvent.ResultPayload.turnsOutputKey: .int(50),
                StreamEvent.ResultPayload.turnCapOutputKey: .bool(true),
            ])
        }

        let cutShort = BacklogAutopilot.workerCutShortReason(turns: 50)
        guard case .blocked(let reason) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(reason, cutShort)
        XCTAssertFalse(autopilot.log.contains { $0.message.hasPrefix("Verifying item-1") },
                       "a cut-short worker's tree is not verified")
        XCTAssertFalse(triggered.contains("reviewer"))
        XCTAssertTrue(try notes().contains(cutShort))
    }

    /// An isolated run whose worker wrote nothing: git says so before the
    /// reviewer is bought, and the item goes back to Ready — nothing was
    /// attempted, so this is not a verdict on the work.
    func testAnIsolatedRunThatWroteNothingReturnsTheItemToReady() async throws {
        let autopilot = try await makeProject(verify: "true", git: true)

        let result = try await runOneItem(autopilot) { execID in
            self.complete("worker", in: execID, output: [:])
        }

        guard case .blocked(let reason) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(autopilot.closedReviewGateSignalForTesting, reason)
        XCTAssertEqual(backlog.item(withID: "item-1")?.status, .ready)
        XCTAssertFalse(triggered.contains("reviewer"), "\(triggered)")
        XCTAssertTrue(try notes().contains("returned to Ready"))
        XCTAssertTrue(autopilot.log.contains { $0.message.hasPrefix("Skipping review — \(reason)") })
    }

    // MARK: - The gate opens

    /// Green verify, a review that passes: the item reaches the approval gate
    /// with its verify measured on the run's record.
    func testAGreenRunThatPassesReviewAwaitsApproval() async throws {
        let autopilot = try await makeProject(verify: "true", git: false)

        let result = try await runOneItem(autopilot) { execID in
            self.complete("worker", in: execID, output: [:])
            try await eventually("the gate to let the reviewer in") { self.triggered.contains("reviewer") }
            self.complete("reviewer", in: execID, output: ["passed": .string("true"), "reason": .string("fine")])
        }

        guard case .awaitingApproval = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertNil(autopilot.closedReviewGateSignalForTesting)
        XCTAssertEqual(autopilot.lastVerifyVerdictForTesting?.passed, true)
        XCTAssertEqual(backlog.item(withID: "item-1")?.status, .awaitingApproval)
        XCTAssertTrue(autopilot.log.contains { $0.message == "Verify passed for item-1 — letting the review run" })
    }

    /// "Runs I start land themselves": unattended runs off, the gate at
    /// `land`. A run started by hand that passes review is approved and merged
    /// — who starts runs and what happens to a passed one are separate values.
    func testAHandStartedRunWithUnattendedRunsOffLandsWhenTheGateIsLand() async throws {
        let autopilot = try await makeProject(verify: "true", git: true)
        autopilot.autonomousWorkEnabled = false
        autopilot.approvalGate = .land
        autopilot.autoMergeVerifyCommand = "true"
        XCTAssertEqual(autopilot.autonomy, .off, "the fleet never starts this project")

        let result = try await runOneItem(autopilot) { execID in
            let worktree = WorktreeSession.worktreesRoot(projectRoot: self.root).appending(path: "item-1")
            try "work\n".write(to: worktree.appending(path: "work.txt"), atomically: true, encoding: .utf8)
            self.complete("worker", in: execID, output: [:])
            try await eventually("the gate to let the reviewer in") { self.triggered.contains("reviewer") }
            self.complete("reviewer", in: execID, output: ["passed": .string("true"), "reason": .string("fine")])
        }

        XCTAssertEqual(result.merged, true, "\(result.outcome)")
        XCTAssertEqual(backlog.item(withID: "item-1")?.status, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "work.txt").path(percentEncoded: false)),
                      "the branch landed on the checked-out base")
    }

    /// A config file written while `protectedPaths` was still a setting holds
    /// its key. The key is ignored, not an error: the rest of the file still
    /// loads, and a run that changes a path the file named is not refused for
    /// it — it reaches the reviewer and the approval gate like any other.
    func testAConfigStillNamingProtectedPathsLoadsAndRunsWithoutRefusing() async throws {
        let autopilot = try await makeProject(
            verify: "true", git: false,
            config: #"{"maxRetries": 5, "protectedPaths": ["docs/suite-status.md", "Secrets/"]}"#)
        XCTAssertEqual(autopilot.maxRetries, 5, "the file around the retired key was not loaded")

        let result = try await runOneItem(autopilot) { execID in
            try FileManager.default.createDirectory(at: self.root.appending(path: "docs"),
                                                    withIntermediateDirectories: true)
            try "| row |\n".write(to: self.root.appending(path: "docs/suite-status.md"),
                                  atomically: true, encoding: .utf8)
            self.complete("worker", in: execID, output: [:])
            try await eventually("the gate to let the reviewer in") { self.triggered.contains("reviewer") }
            self.complete("reviewer", in: execID, output: ["passed": .string("true"), "reason": .string("fine")])
        }

        guard case .awaitingApproval = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertNil(autopilot.closedReviewGateSignalForTesting)
        XCTAssertEqual(backlog.item(withID: "item-1")?.status, .awaitingApproval)
    }

    // MARK: - No reviewer: the worker hands straight to the gates

    /// A project with no reviewer runs worker → done: a run that did work
    /// and whose verify is green lands, and no reviewer is ever woken or
    /// given a session.
    func testWithNoReviewerAGreenRunEndsDoneWithoutAReviewerSession() async throws {
        let autopilot = try await makeProject(verify: "true", git: true, reviewer: false)
        autopilot.approvalGate = .land
        autopilot.autoMergeVerifyCommand = "true"
        XCTAssertTrue(autopilot.canStart, "a worker alone is enough to start")

        let result = try await runOneItem(autopilot) { execID in
            let worktree = WorktreeSession.worktreesRoot(projectRoot: self.root).appending(path: "item-1")
            try "work\n".write(to: worktree.appending(path: "work.txt"), atomically: true, encoding: .utf8)
            self.complete("worker", in: execID, output: [:])
        }

        guard case .done = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(backlog.item(withID: "item-1")?.status, .done)
        XCTAssertFalse(triggered.contains("reviewer"), "\(triggered)")
        XCTAssertFalse(orchestrator.hasSession(for: "reviewer"))
    }

    /// With no reviewer there is no pre-review gate to stop an empty run, and
    /// it is still turned back: the post-run evidence check refuses it as
    /// empty and returns the item to Ready.
    func testWithNoReviewerAnEmptyRunIsStillRefusedAsEmpty() async throws {
        let autopilot = try await makeProject(verify: "true", git: true, reviewer: false)

        let result = try await runOneItem(autopilot) { execID in
            self.complete("worker", in: execID, output: [:])
        }

        guard case .blocked = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(backlog.item(withID: "item-1")?.status, .ready)
        XCTAssertFalse(triggered.contains("reviewer"), "\(triggered)")
        XCTAssertTrue(try notes().contains("returned to Ready"))
    }

    // MARK: - The base's health, once per tip

    /// A red base is a warning, not a refusal, and it is asked once per tip: a
    /// second start while the first check is still running waits on that check
    /// rather than starting a second merge-verify in the same scratch worktree,
    /// and a later start reads the cached answer.
    func testTheBaseIsCheckedOncePerTipAndASecondStartWaitsOnTheFirst() async throws {
        let autopilot = try await makeProject(verify: "true", git: true, startSessions: false)
        autopilot.approvalGate = .land
        autopilot.autoMergeVerifyCommand = "sleep 2; exit 1"
        let checking = "Checking the base HEAD at "

        let first = Task { await autopilot.start() }
        try await eventually(timeout: .seconds(20), "the first start to begin checking the base") {
            autopilot.log.contains { $0.message.hasPrefix(checking) }
        }
        autopilot.selectedItemIDs = ["item-1"]
        await autopilot.start()
        await first.value
        autopilot.selectedItemIDs = ["item-1"]
        await autopilot.start()

        let messages = autopilot.log.map(\.message)
        XCTAssertEqual(messages.filter { $0.hasPrefix(checking) }.count, 1, "\(messages)")
        XCTAssertEqual(messages.filter { $0.contains("is still being checked against the merge-verify") }.count, 1,
                       "\(messages)")
        let warnings = messages.filter { $0.hasPrefix("Warning: the base HEAD at ") }
        XCTAssertEqual(warnings.count, 3, "every start says the base is red: \(messages)")
        XCTAssertTrue(warnings.allSatisfy { $0.contains("fails the project's merge-verify") }, "\(warnings)")
        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .noAgentSession, "a red base never refuses the start")
    }

    // MARK: - Fixture

    /// Drives one start to the end of its one item: `act` plays the agents'
    /// part once the item's workflow is running.
    private func runOneItem(
        _ autopilot: BacklogAutopilot,
        _ act: @escaping @MainActor (String) async throws -> Void
    ) async throws -> BacklogAutopilot.ItemResult {
        var finished = false
        autopilot.onRunFinished = { finished = true }
        let run = Task { await autopilot.start() }
        let execID = try await eventuallyValue(timeout: .seconds(20), "the item's workflow to start") {
            autopilot.currentExecutionID
        }
        try await eventually(timeout: .seconds(10), "the worker to be triggered") {
            self.triggered.contains("worker")
        }
        try await act(execID)
        try await eventually(timeout: .seconds(30), "the run to finish") { finished }
        await run.value
        return try XCTUnwrap(autopilot.results.last)
    }

    /// The event the agent's session would have sent when its turn ended.
    private func complete(_ nodeID: String, in execID: String, output: [String: AnyCodable]) {
        orchestrator.handleWorkflowEvent(WorkflowEvent(
            executionID: execID, nodeID: nodeID, agentID: nodeID, type: .nodeCompleted, output: output))
    }

    private func notes() throws -> String {
        try String(contentsOf: root.appending(path: "backlog/item-1.md"), encoding: .utf8)
    }

    /// A project with one groomed, ready item whose `verify:` is `verify`, a
    /// worker and a reviewer with live sessions (unless `startSessions` is
    /// off), and an autopilot with that item selected. `git` makes the project
    /// a repository, which is what turns worktree isolation on; `config` is an
    /// autopilot config file already on disk when the autopilot loads.
    /// `reviewer` off leaves the reviewer agent unassigned and sessionless.
    private func makeProject(verify: String, git: Bool, startSessions: Bool = true,
                             config: String? = nil, reviewer: Bool = true) async throws -> BacklogAutopilot {
        root = try makeTemporaryDirectory(prefix: "pre-review-gate-run")
        try writeBacklog(verify: verify)
        if git { try commitEverything() }
        if let config {
            try FileManager.default.createDirectory(at: root.appending(path: ".kiteloop"),
                                                    withIntermediateDirectories: true)
            try config.write(to: root.appending(path: ".kiteloop/autopilot-config.json"),
                             atomically: true, encoding: .utf8)
        }

        orchestrator = Orchestrator(runtime: MockAgentRuntime())
        observer = NotificationCenter.default.addObserver(
            forName: .agentTriggered, object: orchestrator, queue: nil
        ) { [triggers] note in
            guard let agentID = note.userInfo?["agentID"] as? String else { return }
            triggers.append(agentID)
        }
        for agentID in ["worker", "reviewer"] {
            orchestrator.addAgent(Agent(id: agentID, name: agentID, model: "sonnet", systemPrompt: "",
                                        tools: [], denied: [], permissionMode: "default", state: .idle))
            if startSessions, reviewer || agentID == "worker" { try await orchestrator.startAgent(agentID, cwd: root) }
        }
        backlog = BacklogViewModel(globalConfigStore: GlobalConfigStore(
            storageURL: root.appendingPathComponent(".kiteloop/global-config.json")))
        backlog.loadForProject(repoPath: root.path(percentEncoded: false))

        let autopilot = BacklogAutopilot()
        autopilot.configure(orchestrator: orchestrator, backlogViewModel: backlog,
                            configURL: root.appendingPathComponent(".kiteloop/autopilot-config.json"),
                            projectPath: root.path(percentEncoded: false), projectName: "demo")
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = reviewer ? "reviewer" : nil
        autopilot.selectedItemIDs = ["item-1"]
        XCTAssertEqual(autopilot.useWorktree, git, "isolation follows whether the project is a repository")
        return autopilot
    }

    private func writeBacklog(verify: String) throws {
        try "# Demo Backlog\n\n## Now\n\n- [ ] item-1 | Fully groomed | ready | size: S → [detail](backlog/item-1.md)\n"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let detail = root.appending(path: "backlog/item-1.md")
        try FileManager.default.createDirectory(at: detail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        ---
        id: item-1
        title: Fully groomed
        size: S
        verify:
          - name: build
            cmd: "\(verify)"
        ---

        ## What

        The outcome this item delivers.

        ## How

        Touch these files, follow this pattern.

        ## Validation

        - [ ] The observable behaviour that proves it works

        ## Out of Scope

        - Anything else
        """.write(to: detail, atomically: true, encoding: .utf8)
    }

    /// The project as a repository with everything written so far committed,
    /// and the app's own state directory ignored.
    private func commitEverything() throws {
        try ".kiteloop/\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        for args in [["init"], ["config", "user.email", "test@test.com"], ["config", "user.name", "Test"],
                     ["add", "."], ["commit", "-m", "init"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
        }
    }
}

/// The agents `triggerAgent` announced, written from the notification's
/// callback and read by the test.
private final class TriggerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var agentIDs: [String] { lock.withLock { recorded } }

    func append(_ agentID: String) { lock.withLock { recorded.append(agentID) } }
}
