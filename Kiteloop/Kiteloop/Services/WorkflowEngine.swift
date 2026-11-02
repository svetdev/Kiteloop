import Foundation
import KiteloopCore

enum WorkflowEngineError: Error, LocalizedError {
    case graphNotFound(String)
    case executionNotFound(String)
    case agentOverlap(agents: Set<String>, existingExecution: String)
    case eventCorrelation(String)
    case notAwaitingApproval
    case invalidEdgeIndex

    var errorDescription: String? {
        switch self {
        case .graphNotFound(let id): return "Graph '\(id)' not found"
        case .executionNotFound(let id): return "Execution '\(id)' not found"
        case .agentOverlap(let agents, let exec): return "Agents \(agents) already reserved by execution '\(exec)'"
        case .eventCorrelation(let msg): return "Event correlation failed: \(msg)"
        case .notAwaitingApproval: return "Execution not in awaitingApproval state"
        case .invalidEdgeIndex: return "Invalid edge index for approval resolution"
        }
    }
}

actor WorkflowEngine {
    private var registeredGraphs: [String: WorkflowGraph] = [:]
    private var executions: [String: WorkflowExecution] = [:]
    private var executionGraphSnapshots: [String: WorkflowGraph] = [:]
    private var agentReservations: [String: String] = [:]  // agentID → executionID
    private var pendingApprovals: [String: Int] = [:]  // executionID → edgeIndex
    /// execID → nodeID → turns taken on that node. Keyed by node, like
    /// `nodeVisitCounts`, because `maxTurns` is declared per node: counting the
    /// whole execution's turns would judge the reviewer's cap of 20 against the
    /// worker's 50 turns and end the run the moment the reviewer was entered.
    private var turnCounts: [String: [WorkflowGraph.NodeID: Int]] = [:]
    private var nodeVisitCounts: [String: [WorkflowGraph.NodeID: Int]] = [:]  // execID → nodeID → visit count
    /// execID → when the execution's current node was entered. The per-node
    /// `timeoutSeconds` is measured from here rather than from
    /// `execution.startedAt`, so a node entered into an already-long execution
    /// gets its whole declared budget instead of the remainder of someone
    /// else's. `graph.globalTimeout` still measures from `startedAt`.
    private var nodeEnteredAt: [String: Date] = [:]

    private let reservationQueue = WorkflowReservationQueue()
    private let queueTimeout: TimeInterval
    private var eventBridge: WorkflowEventBridge?
    private var checkpointStore: WorkflowCheckpointStore?

    init(queueTimeout: TimeInterval = 30.0, eventBridge: WorkflowEventBridge? = nil) {
        self.queueTimeout = queueTimeout
        self.eventBridge = eventBridge
    }

    func setCheckpointStore(_ store: WorkflowCheckpointStore?) {
        checkpointStore = store
    }

    private func writeCheckpoint(executionID: String, reason: CheckpointReason) async {
        guard let store = checkpointStore,
              let execution = executions[executionID],
              let graph = executionGraphSnapshots[executionID] else { return }
        let checkpoint = WorkflowCheckpoint(
            executionID: executionID,
            graphSnapshot: graph,
            executionSnapshot: execution,
            reason: reason
        )
        try? await store.write(checkpoint)
    }

    // MARK: - Registration

    func register(graph: WorkflowGraph) {
        registeredGraphs[graph.id] = graph
    }

    func registeredGraph(id: String) -> WorkflowGraph? {
        registeredGraphs[id]
    }

    // MARK: - Execution Lifecycle

    func start(graphID: String, initialState: [String: AnyCodable]) async throws -> String {
        guard let graph = registeredGraphs[graphID] else {
            throw WorkflowEngineError.graphNotFound(graphID)
        }

        let graphAgents = Set(graph.nodes.values.compactMap { $0.agentID })
        let execID = UUID().uuidString

        // Queue-based reservation: waits if agents are busy
        _ = try await reservationQueue.acquire(agents: graphAgents, executionID: execID, timeout: queueTimeout)

        // Update local reservation map for fast routingMode lookups
        for agent in graphAgents {
            agentReservations[agent] = execID
        }

        executionGraphSnapshots[execID] = graph
        let execution = WorkflowExecution(
            id: execID,
            graphID: graphID,
            graphVersion: graph.version,
            traceID: OTelIDs.newTraceID(),
            currentNode: graph.entryNode,
            status: .running,
            state: initialState
        )
        executions[execID] = execution
        nodeEnteredAt[execID] = execution.startedAt

        await eventBridge?.workflowStarted(executionID: execID, graphID: graphID)
        await writeCheckpoint(executionID: execID, reason: .started)

        return execID
    }

    func startSubExecution(
        graphID: String,
        initialState: [String: AnyCodable],
        parentExecutionID: String,
        parentNodeID: WorkflowGraph.NodeID
    ) throws -> String {
        guard let graph = registeredGraphs[graphID] else {
            throw WorkflowEngineError.graphNotFound(graphID)
        }

        let execID = UUID().uuidString

        // Sub-workflows do NOT reserve agents globally (parent already holds them or they're disjoint)
        executionGraphSnapshots[execID] = graph
        let execution = WorkflowExecution(
            id: execID,
            graphID: graphID,
            currentNode: graph.entryNode,
            status: .running,
            state: initialState,
            parentExecutionID: parentExecutionID,
            parentNodeID: parentNodeID
        )
        executions[execID] = execution
        nodeEnteredAt[execID] = execution.startedAt

        return execID
    }

    // MARK: - Resume from Checkpoint

    func resumeExecution(
        id: String,
        graph: WorkflowGraph,
        currentNode: WorkflowGraph.NodeID,
        state: [String: AnyCodable],
        traceID: String,
        preamble: String
    ) {
        let graphAgents = Set(graph.nodes.values.compactMap { $0.agentID })
        for agent in graphAgents {
            agentReservations[agent] = id
        }
        executionGraphSnapshots[id] = graph

        var execution = WorkflowExecution(
            id: id,
            graphID: graph.id,
            graphVersion: graph.version,
            traceID: traceID,
            currentNode: currentNode,
            status: .running,
            state: state
        )
        execution.state["_resumePreamble"] = .string(preamble)
        executions[id] = execution
        // The resumed node starts running now: the wall-clock a checkpointed run
        // spent stopped is not time this node was given.
        nodeEnteredAt[id] = Date()
    }

    // MARK: - Queries

    func execution(id: String) -> WorkflowExecution? {
        executions[id]
    }

    /// Writes `updates` into a running execution's state — for a caller that
    /// has computed something a node's prompt needs *before* that node's own
    /// turn produces output to merge in the ordinary way (`handleEvent` below).
    /// `BacklogAutopilot`'s `nodeActivationGate` is the one caller: it runs
    /// right before the reviewer node activates and has, by then, already read
    /// the diff to decide whether the gate opens — this is what lets it hand
    /// what it read to the prompt instead of computing it twice.
    ///
    /// Silently a no-op for an execution that has already ended or was never
    /// started, the same as every other query here keyed by an id that may not
    /// resolve.
    func mergeState(executionID: String, updates: [String: AnyCodable]) {
        guard var execution = executions[executionID] else { return }
        for (key, value) in updates { execution.state[key] = value }
        executions[executionID] = execution
    }

    func executionIDs() -> [String] {
        Array(executions.keys)
    }

    func childExecutions(parentID: String) -> [WorkflowExecution] {
        executions.values.filter { $0.parentExecutionID == parentID }
    }

    func routingMode(for agentID: String) -> RoutingMode {
        if let execID = agentReservations[agentID] {
            // Verify execution is still active
            if let execution = executions[execID], isActive(execution.status) {
                return .graphControlled(executionID: execID)
            }
        }
        return .freeform
    }

    func nodeVisits(executionID: String, nodeID: WorkflowGraph.NodeID) -> Int {
        nodeVisitCounts[executionID]?[nodeID] ?? 0
    }

    func currentNodeForAgent(_ agentID: String) -> (executionID: String, nodeID: WorkflowGraph.NodeID, node: WorkflowNode)? {
        guard let execID = agentReservations[agentID],
              let execution = executions[execID],
              isActive(execution.status),
              let graph = executionGraphSnapshots[execID],
              let node = graph.nodes[execution.currentNode] else { return nil }
        return (execID, execution.currentNode, node)
    }

    func canRoute(from agentID: String, to targetAgentID: String) -> Bool {
        let mode = routingMode(for: agentID)
        switch mode {
        case .freeform:
            return true
        case .graphControlled(let execID):
            guard let graph = executionGraphSnapshots[execID],
                  let execution = executions[execID],
                  let node = graph.nodes[execution.currentNode] else { return false }
            // allowFreeform only permits routing to agents NOT in this graph
            let graphAgents = Set(graph.nodes.values.compactMap { $0.agentID })
            return node.allowFreeform && !graphAgents.contains(targetAgentID)
        }
    }

    // MARK: - Event Handling

    /// A shell node has no agent, and its completion arrives with an empty
    /// agent id (`Orchestrator.executeShellNode`), so the agent check reads a
    /// missing agent as "" — telling nil from "" refused every shell node's result.
    func handleEvent(_ event: WorkflowEvent) async throws -> TransitionResult {
        guard var execution = executions[event.executionID] else {
            throw WorkflowEngineError.executionNotFound(event.executionID)
        }
        guard let graph = executionGraphSnapshots[event.executionID] else {
            throw WorkflowEngineError.executionNotFound(event.executionID)
        }

        // Event correlation: nodeID must match current node
        guard event.nodeID == execution.currentNode else {
            throw WorkflowEngineError.eventCorrelation(
                "Event nodeID '\(event.nodeID)' does not match current node '\(execution.currentNode)'"
            )
        }

        // Event correlation: agentID must match current node's agent
        let currentNode = graph.nodes[execution.currentNode]
        guard (currentNode?.agentID ?? "") == event.agentID else {
            throw WorkflowEngineError.eventCorrelation(
                "Event agentID '\(event.agentID)' does not match node agent '\(currentNode?.agentID ?? "nil")'"
            )
        }

        // An event on a node is a turn that node took. Recorded before anything
        // routes, so the caps below are judged against the turn that just
        // happened rather than the one before it.
        recordTurn(executionID: event.executionID, nodeID: event.nodeID)

        // Record step
        let step = ExecutionStep(
            nodeID: event.nodeID,
            agentID: event.agentID,
            spanID: nil,
            startedAt: execution.startedAt,
            completedAt: Date(),
            output: event.output
        )
        execution.steps.append(step)

        // Merge output into state (carry-forward)
        if let output = event.output {
            for (key, value) in output {
                execution.state[key] = value
            }
        }

        // Check if current node is terminal
        if graph.terminalNodes.contains(execution.currentNode) {
            execution.status = .completed
            executions[event.executionID] = execution
            releaseReservations(executionID: event.executionID)
            await eventBridge?.workflowCompleted(executionID: event.executionID, graphID: execution.graphID)
            await writeCheckpoint(executionID: event.executionID, reason: .completed)

            // If this is a sub-workflow completing, advance the parent
            if let parentExecID = execution.parentExecutionID,
               let parentNodeID = execution.parentNodeID {
                try await advanceParentAfterSubWorkflow(
                    parentExecutionID: parentExecID,
                    parentNodeID: parentNodeID,
                    childState: execution.state
                )
            }
            return .terminal
        }

        // Circuit breakers, consulted before routing: a node that ran past the
        // `maxTurns` or `timeoutSeconds` its graph declares ends the execution
        // here rather than being handed on to the next node. Stored first so the
        // breaker — and the checkpoint it writes — read the state this event
        // produced.
        executions[event.executionID] = execution
        if let trip = circuitBreakerTrip(executionID: event.executionID) {
            return try await endForCircuitBreaker(trip, executionID: event.executionID)
        }

        return try await routeFromCurrentNode(execution: execution, executionID: event.executionID, graph: graph, event: event)
    }

    /// Evaluates `graph`'s outgoing edges from `execution.currentNode` against
    /// its state, following the first one whose condition is satisfied —
    /// transitioning, pausing for a human approval, or leaving the execution
    /// where it stood if nothing matched. Split out of `handleEvent` so a
    /// flagged node's timeout fallback (`resolveTimeoutFallback`) can route
    /// through the same edges a normal completion would, with no new turn
    /// recorded and no step appended — only the state it patched before
    /// calling in.
    private func routeFromCurrentNode(
        execution: WorkflowExecution,
        executionID: String,
        graph: WorkflowGraph,
        event: WorkflowEvent
    ) async throws -> TransitionResult {
        var execution = execution
        let outgoingEdges = graph.edges.filter { $0.from == execution.currentNode }
            .sorted { $0.priority < $1.priority }

        for (index, edge) in outgoingEdges.enumerated() {
            switch evaluateCondition(edge.condition, state: execution.state, event: event) {
            case .satisfied:
                return try await applySatisfiedEdge(edge, execution: execution, executionID: executionID, graph: graph)
            case .awaitingApproval(let question):
                execution.status = .awaitingApproval
                executions[executionID] = execution
                pendingApprovals[executionID] = index
                await eventBridge?.workflowApprovalRequired(executionID: executionID, question: question, nodeID: execution.currentNode)
                await writeCheckpoint(executionID: executionID, reason: .paused)
                return .awaitingApproval(question: question, edgeID: index)
            case .notSatisfied:
                continue
            }
        }

        // No matching edge
        executions[executionID] = execution
        return .noMatchingEdge
    }

    /// Follows a single edge `routeFromCurrentNode` found satisfied: the
    /// iteration-limit check, the transition itself, the agentless-terminal
    /// finalize, and a sub-workflow's auto-start. Split out so the loop that
    /// picks the edge stays small enough to read as "first match wins."
    private func applySatisfiedEdge(
        _ edge: WorkflowEdge,
        execution: WorkflowExecution,
        executionID: String,
        graph: WorkflowGraph
    ) async throws -> TransitionResult {
        var execution = execution
        nodeVisitCounts[executionID, default: [:]][edge.to, default: 0] += 1
        if let max = graph.maxIterations,
           let visits = nodeVisitCounts[executionID]?[edge.to],
           visits > max {
            execution.status = .failed
            execution.state["_failureReason"] = .string("Max iterations (\(max)) exceeded for node '\(edge.to)'")
            executions[executionID] = execution
            releaseReservations(executionID: executionID)
            await eventBridge?.workflowFailed(executionID: executionID, reason: "iteration_limit")
            await writeCheckpoint(executionID: executionID, reason: .failed)
            return .terminal
        }

        let fromNode = execution.currentNode
        execution.currentNode = edge.to
        executions[executionID] = execution
        nodeEnteredAt[executionID] = Date()
        await eventBridge?.workflowTransitioned(executionID: executionID, from: fromNode, to: edge.to)

        // A terminal marker node with no agent/shell can never run to report
        // completion — finalize now instead of hanging forever. Terminal
        // nodes that DO carry an agent (e.g. a pipeline's final real step)
        // still run and complete via the check at the top of `handleEvent`.
        if try await completeIfAgentlessTerminal(nodeID: edge.to, executionID: executionID, graph: graph) {
            return .terminal
        }

        execution.status = .running
        executions[executionID] = execution
        await writeCheckpoint(executionID: executionID, reason: .nodeTransition)

        // Auto-start child execution if transitioning to a sub-workflow node
        if let newNode = graph.nodes[edge.to], let subGraphID = newNode.subGraphID {
            _ = try? startSubExecution(
                graphID: subGraphID,
                initialState: execution.state,
                parentExecutionID: executionID,
                parentNodeID: edge.to
            )
        }

        return .transitioned(toNode: edge.to)
    }

    // MARK: - Human Approval Resolution

    func resolveHumanApproval(
        executionID: String,
        edgeIndex: Int,
        approved: Bool,
        reason: String?
    ) async throws -> TransitionResult {
        guard var execution = executions[executionID] else {
            throw WorkflowEngineError.executionNotFound(executionID)
        }
        guard execution.status == .awaitingApproval else {
            throw WorkflowEngineError.notAwaitingApproval
        }
        guard let graph = executionGraphSnapshots[executionID] else {
            throw WorkflowEngineError.executionNotFound(executionID)
        }

        let outgoingEdges = graph.edges.filter { $0.from == execution.currentNode }
            .sorted { $0.priority < $1.priority }
        guard edgeIndex < outgoingEdges.count else {
            throw WorkflowEngineError.invalidEdgeIndex
        }

        let edge = outgoingEdges[edgeIndex]

        if approved {
            execution.currentNode = edge.to
            if let reason = reason {
                execution.state["_approvalReason"] = .string(reason)
            }
            executions[executionID] = execution
            nodeEnteredAt[executionID] = Date()
            pendingApprovals.removeValue(forKey: executionID)
            await eventBridge?.workflowApprovalResolved(executionID: executionID, approved: true, reason: reason)
            if try await completeIfAgentlessTerminal(nodeID: edge.to, executionID: executionID, graph: graph) {
                return .terminal
            }
            execution.status = .running
            executions[executionID] = execution
            await writeCheckpoint(executionID: executionID, reason: .nodeTransition)
            return .transitioned(toNode: edge.to)
        } else {
            // Denied — route to deniedEdge if available
            if case .humanApproval(_, let deniedEdge) = edge.condition, let denied = deniedEdge {
                execution.currentNode = denied
                if let reason = reason {
                    execution.state["_denialReason"] = .string(reason)
                }
                executions[executionID] = execution
                nodeEnteredAt[executionID] = Date()
                pendingApprovals.removeValue(forKey: executionID)
                await eventBridge?.workflowApprovalResolved(executionID: executionID, approved: false, reason: reason)
                if try await completeIfAgentlessTerminal(nodeID: denied, executionID: executionID, graph: graph) {
                    return .terminal
                }
                execution.status = .running
                executions[executionID] = execution
                await writeCheckpoint(executionID: executionID, reason: .nodeTransition)
                return .transitioned(toNode: denied)
            } else {
                // No denied edge — fail the execution
                execution.status = .failed
                executions[executionID] = execution
                pendingApprovals.removeValue(forKey: executionID)
                releaseReservations(executionID: executionID)
                await eventBridge?.workflowApprovalResolved(executionID: executionID, approved: false, reason: reason)
                await writeCheckpoint(executionID: executionID, reason: .failed)
                return .noMatchingEdge
            }
        }
    }

    // MARK: - Private Helpers

    private func isActive(_ status: ExecutionStatus) -> Bool {
        !status.isTerminal
    }

    private func releaseReservations(executionID: String) {
        agentReservations = agentReservations.filter { $0.value != executionID }
        Task { await reservationQueue.release(executionID: executionID) }
    }

    /// A terminal marker node with no agent and no shell command (e.g. the
    /// autopilot graph's `done`/`blocked` nodes) can never run to report its own
    /// completion. When a transition lands on such a node, finalize the execution
    /// immediately instead of leaving it `running` forever. Returns true when it
    /// finalized; terminal nodes that carry an agent or shell command return
    /// false and still run to completion via the terminal check in `handleEvent`.
    private func completeIfAgentlessTerminal(
        nodeID: WorkflowGraph.NodeID,
        executionID: String,
        graph: WorkflowGraph
    ) async throws -> Bool {
        guard graph.terminalNodes.contains(nodeID),
              graph.nodes[nodeID]?.agentID == nil,
              graph.nodes[nodeID]?.shellCommand == nil,
              var execution = executions[executionID] else { return false }
        execution.status = .completed
        executions[executionID] = execution
        releaseReservations(executionID: executionID)
        await eventBridge?.workflowCompleted(executionID: executionID, graphID: execution.graphID)
        await writeCheckpoint(executionID: executionID, reason: .completed)
        if let parentExecID = execution.parentExecutionID,
           let parentNodeID = execution.parentNodeID {
            try await advanceParentAfterSubWorkflow(
                parentExecutionID: parentExecID,
                parentNodeID: parentNodeID,
                childState: execution.state
            )
        }
        return true
    }

    private func advanceParentAfterSubWorkflow(
        parentExecutionID: String,
        parentNodeID: WorkflowGraph.NodeID,
        childState: [String: AnyCodable]
    ) async throws {
        guard var parentExec = executions[parentExecutionID],
              let parentGraph = executionGraphSnapshots[parentExecutionID] else { return }

        // Merge child state into parent
        for (key, value) in childState {
            parentExec.state[key] = value
        }

        // Record step for the sub-workflow node
        let step = ExecutionStep(
            nodeID: parentNodeID,
            agentID: nil,
            spanID: nil,
            startedAt: parentExec.startedAt,
            completedAt: Date(),
            output: childState
        )
        parentExec.steps.append(step)

        // Evaluate outgoing edges from the sub-workflow node
        let outgoingEdges = parentGraph.edges.filter { $0.from == parentNodeID }
            .sorted { $0.priority < $1.priority }

        for edge in outgoingEdges {
            let fakeEvent = WorkflowEvent(
                executionID: parentExecutionID,
                nodeID: parentNodeID,
                agentID: "",
                type: .subWorkflowCompleted,
                output: childState
            )
            let evalResult = evaluateCondition(edge.condition, state: parentExec.state, event: fakeEvent)
            if case .satisfied = evalResult {
                let fromNode = parentExec.currentNode
                parentExec.currentNode = edge.to
                parentExec.status = .running
                executions[parentExecutionID] = parentExec
                nodeEnteredAt[parentExecutionID] = Date()
                await eventBridge?.workflowTransitioned(executionID: parentExecutionID, from: fromNode, to: edge.to)
                return
            }
        }

        // No matching edge — store state anyway
        executions[parentExecutionID] = parentExec
    }

    // MARK: - Turn Tracking (Circuit Breakers)

    func recordTurn(executionID: String) {
        guard let nodeID = executions[executionID]?.currentNode else { return }
        recordTurn(executionID: executionID, nodeID: nodeID)
    }

    private func recordTurn(executionID: String, nodeID: WorkflowGraph.NodeID) {
        turnCounts[executionID, default: [:]][nodeID, default: 0] += 1
    }

    func turns(executionID: String, nodeID: WorkflowGraph.NodeID) -> Int {
        turnCounts[executionID]?[nodeID] ?? 0
    }

    func checkCircuitBreaker(executionID: String) -> CircuitBreakerResult? {
        circuitBreakerTrip(executionID: executionID)?.result
    }

    /// A cap that has been exceeded, carrying the sentence that names it. The
    /// reason is built here rather than by the caller because
    /// `CircuitBreakerResult` cannot tell a node's timeout from the graph's —
    /// both are `.timeoutExceeded`, and a run that ended has to say which.
    private struct BreakerTrip {
        let result: CircuitBreakerResult
        /// Machine token for the event bus, alongside `iteration_limit`.
        let event: String
        /// What the execution records as its failure reason.
        let reason: String
    }

    private func circuitBreakerTrip(executionID: String) -> BreakerTrip? {
        guard let execution = executions[executionID],
              let graph = executionGraphSnapshots[executionID] else { return nil }

        let nodeID = execution.currentNode
        let node = graph.nodes[nodeID]

        // Per-node maxTurns, counted against this node's own turns.
        if let maxTurns = node?.maxTurns, turns(executionID: executionID, nodeID: nodeID) > maxTurns {
            return BreakerTrip(
                result: .maxTurnsExceeded,
                event: "max_turns",
                reason: "Max turns (\(maxTurns)) exceeded for node '\(nodeID)'"
            )
        }

        // Per-node timeout, measured from when this node was entered.
        let nodeElapsed = Date().timeIntervalSince(nodeEnteredAt[executionID] ?? execution.startedAt)
        if let timeout = node?.timeoutSeconds, nodeElapsed > TimeInterval(timeout) {
            return BreakerTrip(
                result: .timeoutExceeded,
                event: "node_timeout",
                reason: "Node timeout (\(timeout)s) exceeded for node '\(nodeID)'"
            )
        }

        // Global timeout, measured from when the execution started.
        let elapsedSeconds = Date().timeIntervalSince(execution.startedAt)
        if let globalTimeout = graph.globalTimeout, elapsedSeconds > TimeInterval(globalTimeout) {
            return BreakerTrip(
                result: .timeoutExceeded,
                event: "global_timeout",
                reason: "Global timeout (\(globalTimeout)s) exceeded"
            )
        }

        return nil
    }

    /// Ends an execution a breaker tripped on, the way `cancel(executionID:)`
    /// ends a cancelled one: status, reservations, event bridge, checkpoint —
    /// with the cap that tripped recorded in `_failureReason`, so a run that was
    /// cut short says which one rather than only that it stopped.
    ///
    /// A node's own `timeoutSeconds` trip is the one exception: a node carrying
    /// `timeoutFallback` (the reviewer's follow-up ask) is not failed by it —
    /// see `resolveTimeoutFallback`. `maxTurns` and the graph's `globalTimeout`
    /// still end the execution here regardless of that flag; only its own clock
    /// running out is what the flag is about.
    private func endForCircuitBreaker(_ trip: BreakerTrip, executionID: String) async throws -> TransitionResult {
        guard var execution = executions[executionID] else { return .terminal }
        if trip.event == "node_timeout",
           let graph = executionGraphSnapshots[executionID],
           let fallback = graph.nodes[execution.currentNode]?.timeoutFallback {
            return try await resolveTimeoutFallback(fallback, execution: execution, executionID: executionID, graph: graph)
        }
        execution.status = trip.result == .maxTurnsExceeded ? .failed : .timedOut
        execution.state["_failureReason"] = .string(trip.reason)
        executions[executionID] = execution
        releaseReservations(executionID: executionID)
        await eventBridge?.workflowFailed(executionID: executionID, reason: trip.event)
        await writeCheckpoint(executionID: executionID, reason: .failed)
        return .terminal
    }

    /// A flagged node's timeout, resolved rather than failed: `state[key]`
    /// reads back as `trueValue` when it already holds that value, `falseValue`
    /// otherwise — the safe default, covering both an actual rejection and
    /// nothing at all — and the result routes through the node's own edges
    /// exactly as a real completion would. `note` is left in
    /// `state["_timeoutFallbackNote"]` for the caller to surface; nothing here
    /// clears it, so it survives however many rounds follow.
    private func resolveTimeoutFallback(
        _ fallback: WorkflowNode.TimeoutFallback,
        execution: WorkflowExecution,
        executionID: String,
        graph: WorkflowGraph
    ) async throws -> TransitionResult {
        var execution = execution
        let resolved = execution.state[fallback.key]?.stringValue == fallback.trueValue
            ? fallback.trueValue : fallback.falseValue
        execution.state[fallback.key] = .string(resolved)
        execution.state["_timeoutFallbackNote"] = .string(fallback.note)
        if resolved == fallback.falseValue, let feedbackKey = fallback.feedbackKey {
            execution.state[feedbackKey] = .string(fallback.note)
        }
        executions[executionID] = execution

        let syntheticEvent = WorkflowEvent(
            executionID: executionID,
            nodeID: execution.currentNode,
            agentID: graph.nodes[execution.currentNode]?.agentID ?? "",
            type: .nodeCompleted,
            output: [fallback.key: .string(resolved)]
        )
        return try await routeFromCurrentNode(execution: execution, executionID: executionID, graph: graph, event: syntheticEvent)
    }

    // MARK: - Cancellation

    func cancel(executionID: String) async {
        guard var execution = executions[executionID], isActive(execution.status) else { return }
        execution.status = .cancelled
        executions[executionID] = execution
        releaseReservations(executionID: executionID)
        turnCounts.removeValue(forKey: executionID)
        nodeVisitCounts.removeValue(forKey: executionID)
        nodeEnteredAt.removeValue(forKey: executionID)
        await eventBridge?.workflowCancelled(executionID: executionID)
        await writeCheckpoint(executionID: executionID, reason: .cancelled)
    }

    // MARK: - File Loading

    func loadGraphs(from directory: URL) {
        let loader = WorkflowFileLoader(directory: directory)
        guard let results = try? loader.loadAll() else { return }
        for graph in results.loaded {
            registeredGraphs[graph.id] = graph
        }
        logRejected(results.errors)
    }

    func reloadGraphs(from directory: URL) {
        let loader = WorkflowFileLoader(directory: directory)
        guard let results = try? loader.loadAll() else { return }
        for graph in results.loaded {
            registeredGraphs[graph.id] = graph
        }
        logRejected(results.errors)
    }

    private func logRejected(_ errors: [(filename: String, error: Error)]) {
        for (filename, error) in errors {
            kiteloopLog("[workflow] rejected \(filename): \(error.localizedDescription)", category: "workflow", level: .error)
        }
    }

    private enum ConditionEvalResult {
        case satisfied
        case notSatisfied
        case awaitingApproval(question: String)
    }

    private func evaluateCondition(
        _ condition: EdgeCondition,
        state: [String: AnyCodable],
        event: WorkflowEvent
    ) -> ConditionEvalResult {
        switch condition {
        case .always:
            return .satisfied
        case .eventType(let expectedType):
            if event.type == .nodeCompleted {
                return .satisfied
            }
            if event.type == .eventEmitted,
               let emittedType = event.output?["_eventType"]?.stringValue,
               emittedType == expectedType {
                return .satisfied
            }
            return .notSatisfied
        case .outputMatch(let key, let value):
            if let output = event.output, output[key]?.stringValue == value {
                return .satisfied
            }
            if state[key]?.stringValue == value {
                return .satisfied
            }
            return .notSatisfied
        case .humanApproval(let question, _):
            return .awaitingApproval(question: question)
        case .allOf(let conditions):
            for cond in conditions {
                let result = evaluateCondition(cond, state: state, event: event)
                switch result {
                case .notSatisfied: return .notSatisfied
                case .awaitingApproval: return result
                case .satisfied: continue
                }
            }
            return .satisfied
        case .anyOf(let conditions):
            for cond in conditions {
                let result = evaluateCondition(cond, state: state, event: event)
                switch result {
                case .satisfied: return .satisfied
                case .awaitingApproval: return result
                case .notSatisfied: continue
                }
            }
            return .notSatisfied
        }
    }
}
