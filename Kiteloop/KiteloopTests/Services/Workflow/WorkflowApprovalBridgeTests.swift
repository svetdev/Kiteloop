import XCTest
import KiteloopCore
import Combine
@testable import Kiteloop

final class WorkflowApprovalBridgeTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    func testPendingApprovalPublished() async throws {
        let engine = WorkflowEngine()
        let bridge = WorkflowApprovalBridge(engine: engine)

        let graph = WorkflowGraph(
            id: "approval-test", name: "Approval", version: 1,
            nodes: [
                "draft": WorkflowNode(id: "draft", agentID: "writer", prompt: "Write"),
                "publish": WorkflowNode(id: "publish", agentID: "publisher", prompt: "Publish")
            ],
            edges: [WorkflowEdge(from: "draft", to: "publish", condition: .humanApproval(question: "Ship it?", deniedEdge: nil))],
            entryNode: "draft", terminalNodes: ["publish"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "approval-test", initialState: [:])

        let event = WorkflowEvent(executionID: execID, nodeID: "draft", agentID: "writer", type: .nodeCompleted)
        let result = try await engine.handleEvent(event)

        guard case .awaitingApproval(let question, let edgeID) = result else {
            XCTFail("Expected awaitingApproval"); return
        }

        await bridge.registerPendingApproval(
            executionID: execID,
            question: question,
            edgeIndex: edgeID
        )

        let pending = await bridge.pendingApprovals
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.question, "Ship it?")
        XCTAssertEqual(pending.first?.executionID, execID)
    }

    func testApproveRemovesPending() async throws {
        let engine = WorkflowEngine()
        let bridge = WorkflowApprovalBridge(engine: engine)

        let graph = WorkflowGraph(
            id: "approval-test", name: "Approval", version: 1,
            nodes: [
                "draft": WorkflowNode(id: "draft", agentID: "writer", prompt: "Write"),
                "publish": WorkflowNode(id: "publish", agentID: "publisher", prompt: "Publish")
            ],
            edges: [WorkflowEdge(from: "draft", to: "publish", condition: .humanApproval(question: "Ship it?", deniedEdge: nil))],
            entryNode: "draft", terminalNodes: ["publish"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "approval-test", initialState: [:])

        let event = WorkflowEvent(executionID: execID, nodeID: "draft", agentID: "writer", type: .nodeCompleted)
        let result = try await engine.handleEvent(event)
        guard case .awaitingApproval(let question, let edgeID) = result else {
            XCTFail("Expected awaitingApproval"); return
        }

        await bridge.registerPendingApproval(executionID: execID, question: question, edgeIndex: edgeID)
        let transitionResult = try await bridge.resolve(executionID: execID, approved: true, reason: "LGTM")

        if case .transitioned(let toNode) = transitionResult {
            XCTAssertEqual(toNode, "publish")
        } else { XCTFail("Expected transition after approval") }

        let pending = await bridge.pendingApprovals
        XCTAssertTrue(pending.isEmpty)
    }

    func testDenyWithNoDeniedEdgeFails() async throws {
        let engine = WorkflowEngine()
        let bridge = WorkflowApprovalBridge(engine: engine)

        let graph = WorkflowGraph(
            id: "approval-test", name: "Approval", version: 1,
            nodes: [
                "draft": WorkflowNode(id: "draft", agentID: "writer", prompt: "Write"),
                "publish": WorkflowNode(id: "publish", agentID: "publisher", prompt: "Publish")
            ],
            edges: [WorkflowEdge(from: "draft", to: "publish", condition: .humanApproval(question: "Ship?", deniedEdge: nil))],
            entryNode: "draft", terminalNodes: ["publish"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "approval-test", initialState: [:])

        let event = WorkflowEvent(executionID: execID, nodeID: "draft", agentID: "writer", type: .nodeCompleted)
        let result = try await engine.handleEvent(event)
        guard case .awaitingApproval(let question, let edgeID) = result else {
            XCTFail("Expected awaitingApproval"); return
        }

        await bridge.registerPendingApproval(executionID: execID, question: question, edgeIndex: edgeID)
        let transitionResult = try await bridge.resolve(executionID: execID, approved: false, reason: "Not ready")

        if case .noMatchingEdge = transitionResult { } else {
            XCTFail("Expected noMatchingEdge (failed) after denial with no deniedEdge")
        }
    }

    // MARK: - registerPendingApproval

    func testRegisterPendingApprovalStoresAllFields() async throws {
        let bridge = WorkflowApprovalBridge(engine: WorkflowEngine())
        let before = Date()

        await bridge.registerPendingApproval(executionID: "exec-1", question: "Deploy?", edgeIndex: 3)

        let pending = await bridge.pendingApprovals
        XCTAssertEqual(pending.count, 1)
        let approval = try XCTUnwrap(pending.first)
        XCTAssertEqual(approval.executionID, "exec-1")
        XCTAssertEqual(approval.id, "exec-1", "id is derived from executionID")
        XCTAssertEqual(approval.question, "Deploy?")
        XCTAssertEqual(approval.edgeIndex, 3)
        XCTAssertGreaterThanOrEqual(approval.requestedAt, before)
        XCTAssertLessThanOrEqual(approval.requestedAt, Date())
    }

    func testRegisterPendingApprovalAppendsInOrder() async throws {
        let bridge = WorkflowApprovalBridge(engine: WorkflowEngine())

        await bridge.registerPendingApproval(executionID: "exec-1", question: "First?", edgeIndex: 0)
        await bridge.registerPendingApproval(executionID: "exec-2", question: "Second?", edgeIndex: 1)
        await bridge.registerPendingApproval(executionID: "exec-3", question: "Third?", edgeIndex: 2)

        let pending = await bridge.pendingApprovals
        XCTAssertEqual(pending.map(\.executionID), ["exec-1", "exec-2", "exec-3"])
        XCTAssertEqual(pending.map(\.edgeIndex), [0, 1, 2])
    }

    func testRegisterPendingApprovalPublishesGrowingSnapshots() async throws {
        let bridge = WorkflowApprovalBridge(engine: WorkflowEngine())
        let collector = SnapshotCollector()

        let expectation = expectation(description: "two snapshots published")
        expectation.expectedFulfillmentCount = 2
        bridge.approvalsPublisher
            .sink { snapshot in
                collector.append(snapshot)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        await bridge.registerPendingApproval(executionID: "exec-1", question: "First?", edgeIndex: 0)
        await bridge.registerPendingApproval(executionID: "exec-2", question: "Second?", edgeIndex: 1)

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(collector.snapshots.map(\.count), [1, 2])
        XCTAssertEqual(collector.snapshots.last?.map(\.executionID), ["exec-1", "exec-2"])
    }

    // MARK: - resolve uses the stored edgeIndex

    /// The approval edge is the *second* outgoing edge, so resolving against a
    /// hardcoded index 0 would route to `rework` instead of `publish`.
    func testResolveUsesStoredEdgeIndexRatherThanFirstEdge() async throws {
        let engine = WorkflowEngine()
        let bridge = WorkflowApprovalBridge(engine: engine)
        let execID = try await startAwaitingApproval(engine: engine, graphID: "multi-edge-approval")

        await bridge.registerPendingApproval(executionID: execID, question: "Ship it?", edgeIndex: 1)
        let transitionResult = try await bridge.resolve(executionID: execID, approved: true, reason: "LGTM")

        guard case .transitioned(let toNode) = transitionResult else {
            XCTFail("Expected transition after approval"); return
        }
        XCTAssertEqual(toNode, "publish", "stored edgeIndex 1 must select the approval edge, not edge 0")
        let pending = await bridge.pendingApprovals
        XCTAssertTrue(pending.isEmpty)
    }

    /// Registering a different index than the engine reported proves the bridge
    /// forwards the *stored* value verbatim instead of re-deriving one.
    func testResolveForwardsStoredEdgeIndexVerbatim() async throws {
        let engine = WorkflowEngine()
        let bridge = WorkflowApprovalBridge(engine: engine)
        let execID = try await startAwaitingApproval(engine: engine, graphID: "multi-edge-approval")

        // Engine reported edgeIndex 1; deliberately store 0.
        await bridge.registerPendingApproval(executionID: execID, question: "Ship it?", edgeIndex: 0)
        let transitionResult = try await bridge.resolve(executionID: execID, approved: true, reason: nil)

        guard case .transitioned(let toNode) = transitionResult else {
            XCTFail("Expected transition after approval"); return
        }
        XCTAssertEqual(toNode, "rework", "resolve must use the edgeIndex stored at registration")
    }

    func testResolveWithOutOfRangeStoredEdgeIndexThrowsAndKeepsPending() async throws {
        let engine = WorkflowEngine()
        let bridge = WorkflowApprovalBridge(engine: engine)
        let execID = try await startAwaitingApproval(engine: engine, graphID: "multi-edge-approval")

        await bridge.registerPendingApproval(executionID: execID, question: "Ship it?", edgeIndex: 99)

        do {
            _ = try await bridge.resolve(executionID: execID, approved: true, reason: nil)
            XCTFail("Expected invalidEdgeIndex to propagate from the engine")
        } catch WorkflowEngineError.invalidEdgeIndex {
            // expected
        }

        let pending = await bridge.pendingApprovals
        XCTAssertEqual(pending.count, 1, "a failed resolve must leave the approval pending")
        XCTAssertEqual(pending.first?.edgeIndex, 99)
    }

    func testResolveUnknownExecutionThrowsNotAwaitingApproval() async throws {
        let bridge = WorkflowApprovalBridge(engine: WorkflowEngine())
        await bridge.registerPendingApproval(executionID: "exec-1", question: "Ship?", edgeIndex: 0)

        do {
            _ = try await bridge.resolve(executionID: "exec-unknown", approved: true, reason: nil)
            XCTFail("Expected notAwaitingApproval for an unregistered execution")
        } catch WorkflowEngineError.notAwaitingApproval {
            // expected
        }

        let pending = await bridge.pendingApprovals
        XCTAssertEqual(pending.count, 1, "unrelated approvals must be untouched")
    }

    func testResolveRemovesOnlyTheMatchingApproval() async throws {
        let engine = WorkflowEngine()
        let bridge = WorkflowApprovalBridge(engine: engine)
        let execID = try await startAwaitingApproval(engine: engine, graphID: "multi-edge-approval")

        await bridge.registerPendingApproval(executionID: "other-before", question: "A?", edgeIndex: 0)
        await bridge.registerPendingApproval(executionID: execID, question: "Ship it?", edgeIndex: 1)
        await bridge.registerPendingApproval(executionID: "other-after", question: "B?", edgeIndex: 0)

        _ = try await bridge.resolve(executionID: execID, approved: true, reason: nil)

        let pending = await bridge.pendingApprovals
        XCTAssertEqual(pending.map(\.executionID), ["other-before", "other-after"])
    }

    // MARK: - clearAll

    func testClearAllRemovesEveryPendingApproval() async throws {
        let bridge = WorkflowApprovalBridge(engine: WorkflowEngine())
        await bridge.registerPendingApproval(executionID: "exec-1", question: "A?", edgeIndex: 0)
        await bridge.registerPendingApproval(executionID: "exec-2", question: "B?", edgeIndex: 1)

        await bridge.clearAll()

        let pending = await bridge.pendingApprovals
        XCTAssertTrue(pending.isEmpty)
    }

    func testClearAllPublishesEmptySnapshot() async throws {
        let bridge = WorkflowApprovalBridge(engine: WorkflowEngine())
        await bridge.registerPendingApproval(executionID: "exec-1", question: "A?", edgeIndex: 0)

        let collector = SnapshotCollector()
        let expectation = expectation(description: "clearAll publishes")
        bridge.approvalsPublisher
            .sink { snapshot in
                collector.append(snapshot)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        await bridge.clearAll()

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(collector.snapshots.count, 1)
        XCTAssertEqual(collector.snapshots.first?.isEmpty, true)
    }

    func testClearAllOnEmptyBridgeIsANoOp() async throws {
        let bridge = WorkflowApprovalBridge(engine: WorkflowEngine())

        await bridge.clearAll()

        let pending = await bridge.pendingApprovals
        XCTAssertTrue(pending.isEmpty)
    }

    func testRegisterAfterClearAllStartsFresh() async throws {
        let bridge = WorkflowApprovalBridge(engine: WorkflowEngine())
        await bridge.registerPendingApproval(executionID: "exec-1", question: "A?", edgeIndex: 0)
        await bridge.clearAll()

        await bridge.registerPendingApproval(executionID: "exec-2", question: "B?", edgeIndex: 5)

        let pending = await bridge.pendingApprovals
        XCTAssertEqual(pending.map(\.executionID), ["exec-2"])
        XCTAssertEqual(pending.first?.edgeIndex, 5)
    }

    // MARK: - Helpers

    /// Starts an execution whose `draft` node has two outgoing edges: an
    /// unsatisfied `outputMatch` at index 0 (→ `rework`) and the human-approval
    /// edge at index 1 (→ `publish`). Returns the execution ID, parked in
    /// `awaitingApproval`.
    private func startAwaitingApproval(engine: WorkflowEngine, graphID: String) async throws -> String {
        let graph = WorkflowGraph(
            id: graphID, name: "Multi Edge Approval", version: 1,
            nodes: [
                "draft": WorkflowNode(id: "draft", agentID: "writer", prompt: "Write"),
                "rework": WorkflowNode(id: "rework", agentID: "editor", prompt: "Rework"),
                "publish": WorkflowNode(id: "publish", agentID: "publisher", prompt: "Publish")
            ],
            edges: [
                WorkflowEdge(from: "draft", to: "rework", condition: .outputMatch(key: "status", value: "rejected"), priority: 0),
                WorkflowEdge(from: "draft", to: "publish", condition: .humanApproval(question: "Ship it?", deniedEdge: nil), priority: 1)
            ],
            entryNode: "draft", terminalNodes: ["publish"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: graphID, initialState: [:])

        let event = WorkflowEvent(executionID: execID, nodeID: "draft", agentID: "writer", type: .nodeCompleted)
        let result = try await engine.handleEvent(event)
        guard case .awaitingApproval(_, let edgeID) = result else {
            XCTFail("Expected awaitingApproval to park the execution")
            throw ApprovalTestError.notAwaitingApproval
        }
        XCTAssertEqual(edgeID, 1, "approval edge is the second outgoing edge")
        return execID
    }
}

private enum ApprovalTestError: Error {
    case notAwaitingApproval
}

/// Thread-safe sink target — the bridge publishes from inside its actor, so
/// snapshots can arrive on any executor.
private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[PendingApproval]] = []

    var snapshots: [[PendingApproval]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ snapshot: [PendingApproval]) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(snapshot)
    }
}
