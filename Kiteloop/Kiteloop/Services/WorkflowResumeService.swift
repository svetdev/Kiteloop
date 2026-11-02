import Foundation
import KiteloopCore

/// Represents a workflow execution found incomplete at launch,
/// surfaced by the resume service for user decision (resume vs dismiss).
struct IncompleteExecution: Identifiable, Sendable {
    let id: String
    let graphID: String
    let graphName: String
    let currentNode: String
    let status: ExecutionStatus
    /// When the run stopped — the time of the checkpoint it is parked on.
    let interruptedAt: Date
    let traceID: String
    let state: [String: AnyCodable]
    /// The backlog item the run was working, when it carries one. Every
    /// autopilot run shares the "Backlog Item Execution" graph, so the item —
    /// not the graph name — is what tells one row from another.
    let itemID: String?
    let itemTitle: String?
    /// Which project's checkpoints this came from, so a row still identifies
    /// itself when several projects are open.
    let projectName: String
    /// How many of the run's nodes finished before it stopped. Zero means the
    /// run left nothing behind and is better restarted than resumed.
    let completedStepCount: Int

    /// What names this run to a human: the item's title, then its id, and only
    /// then the graph name — the last for a workflow that isn't a backlog run.
    var displayName: String {
        if let itemTitle, !itemTitle.isEmpty { return itemTitle }
        if let itemID, !itemID.isEmpty { return itemID }
        return graphName
    }
}

/// Why a Resume could not do anything. Every case is reported to the user: a
/// resume that changed nothing must never be indistinguishable from one that
/// worked.
enum WorkflowResumeError: Error, LocalizedError, Equatable {
    case noCheckpoint(executionID: String)
    case alreadyFinished(status: ExecutionStatus)
    case atTerminalNode(node: String)

    var errorDescription: String? {
        switch self {
        case .noCheckpoint(let id):
            return "no checkpoint was found for execution \(id), so there is nothing to continue from."
        case .alreadyFinished(let status):
            return "it already finished (\(status.rawValue)), so there is nothing to continue."
        case .atTerminalNode(let node):
            return "it already reached its final node \"\(node)\", so there is nothing to continue."
        }
    }
}

/// Scans for incomplete workflow executions at launch and provides
/// resume/dismiss functionality so interrupted workflows can be continued.
actor WorkflowResumeService {
    private let checkpointStore: WorkflowCheckpointStore
    private let engine: WorkflowEngine
    private let eventBridge: WorkflowEventBridge
    private let projectName: String

    init(
        checkpointStore: WorkflowCheckpointStore,
        engine: WorkflowEngine,
        eventBridge: WorkflowEventBridge,
        projectName: String
    ) {
        self.checkpointStore = checkpointStore
        self.engine = engine
        self.eventBridge = eventBridge
        self.projectName = projectName
    }

    /// Returns the executions that could genuinely be continued, newest first.
    /// One parked on a terminal node has nothing left to run and is left out
    /// rather than offered with its Resume greyed.
    func scanForIncomplete() async -> [IncompleteExecution] {
        guard let checkpoints = try? await checkpointStore.listIncompleteExecutions() else {
            return []
        }
        return checkpoints
            .map { cp in
                IncompleteExecution(
                    id: cp.executionID,
                    graphID: cp.executionSnapshot.graphID,
                    graphName: cp.graphName,
                    currentNode: cp.executionSnapshot.currentNode,
                    status: cp.executionSnapshot.status,
                    interruptedAt: cp.checkpointedAt,
                    traceID: cp.traceID,
                    state: cp.executionSnapshot.state,
                    itemID: cp.executionSnapshot.state["itemID"]?.stringValue,
                    itemTitle: cp.executionSnapshot.state["title"]?.stringValue,
                    projectName: projectName,
                    completedStepCount: cp.executionSnapshot.steps.filter { $0.completedAt != nil }.count
                )
            }
            .sorted { $0.interruptedAt > $1.interruptedAt }
    }

    /// Drops checkpoints no resume could use. Delegates the safety rule to the
    /// store: only settled executions, which are exactly the ones
    /// `scanForIncomplete` never returns. Returns how many were removed.
    @discardableResult
    func pruneSettledCheckpoints() async -> Int {
        (try? await checkpointStore.pruneSettledExecutions()) ?? 0
    }

    /// Resumes an incomplete execution from its latest checkpoint, throwing a
    /// `WorkflowResumeError` when there is nothing to resume. It never returns
    /// without having either restarted the execution or said why it could not.
    func resume(executionID: String) async throws {
        guard let checkpoint = try await checkpointStore.latestCheckpoint(executionID: executionID) else {
            throw WorkflowResumeError.noCheckpoint(executionID: executionID)
        }
        guard !checkpoint.executionSnapshot.status.isTerminal else {
            throw WorkflowResumeError.alreadyFinished(status: checkpoint.executionSnapshot.status)
        }
        guard !checkpoint.graphSnapshot.terminalNodes.contains(checkpoint.executionSnapshot.currentNode) else {
            throw WorkflowResumeError.atTerminalNode(node: checkpoint.executionSnapshot.currentNode)
        }

        await engine.register(graph: checkpoint.graphSnapshot)

        let preamble = buildResumePreamble(checkpoint: checkpoint)

        await engine.resumeExecution(
            id: checkpoint.executionID,
            graph: checkpoint.graphSnapshot,
            currentNode: checkpoint.executionSnapshot.currentNode,
            state: checkpoint.executionSnapshot.state,
            traceID: checkpoint.traceID,
            preamble: preamble
        )

        await eventBridge.workflowStarted(executionID: executionID, graphID: checkpoint.graphSnapshot.id)
    }

    /// Dismisses an incomplete execution by deleting its checkpoints, throwing
    /// when the store could not remove them.
    ///
    /// Dismiss means "I am not continuing this run", and resume is the only
    /// reader a checkpoint has — so keeping a cancelled marker on disk buys
    /// nothing and is half of why they accumulated without limit. A delete the
    /// file system refused must not read as one that landed: the run would come
    /// back at the next launch with no account of where it went.
    func dismiss(executionID: String) async throws {
        try await checkpointStore.deleteCheckpoints(executionID: executionID)
    }

    /// Returns the resume preamble string for a given execution (for UI preview).
    func statePreamble(for executionID: String) async -> String? {
        guard let checkpoint = try? await checkpointStore.latestCheckpoint(executionID: executionID) else {
            return nil
        }
        return buildResumePreamble(checkpoint: checkpoint)
    }

    // MARK: - Private

    private func buildResumePreamble(checkpoint: WorkflowCheckpoint) -> String {
        var lines: [String] = []
        lines.append("[RESUMED] You are resuming workflow \"\(checkpoint.graphName)\" from node \"\(checkpoint.executionSnapshot.currentNode)\".")

        let stateEntries = checkpoint.executionSnapshot.state.map { "\($0.key): \($0.value)" }
        if !stateEntries.isEmpty {
            lines.append("Prior state: \(stateEntries.joined(separator: ", "))")
        }

        let completedSteps = checkpoint.executionSnapshot.steps.filter { $0.completedAt != nil }
        if let lastStep = completedSteps.last {
            lines.append("Last completed node: \(lastStep.nodeID)")
        }

        lines.append("Continue from where you left off.")
        return lines.joined(separator: "\n")
    }
}
