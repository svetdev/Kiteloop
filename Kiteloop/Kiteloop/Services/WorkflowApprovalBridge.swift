import Foundation
import KiteloopCore
import Combine

struct PendingApproval: Identifiable, Sendable {
    let id: String
    let executionID: String
    let question: String
    let edgeIndex: Int
    let requestedAt: Date

    init(executionID: String, question: String, edgeIndex: Int, requestedAt: Date = Date()) {
        self.id = executionID
        self.executionID = executionID
        self.question = question
        self.edgeIndex = edgeIndex
        self.requestedAt = requestedAt
    }
}

actor WorkflowApprovalBridge {
    private let engine: WorkflowEngine
    private(set) var pendingApprovals: [PendingApproval] = []

    // Combine subjects synchronize internally, so this is safe to touch from
    // outside the actor — which the nonisolated publisher below must do.
    private nonisolated(unsafe) let _approvalsChanged = PassthroughSubject<[PendingApproval], Never>()
    nonisolated var approvalsPublisher: AnyPublisher<[PendingApproval], Never> {
        _approvalsChanged.eraseToAnyPublisher()
    }

    init(engine: WorkflowEngine) {
        self.engine = engine
    }

    func registerPendingApproval(executionID: String, question: String, edgeIndex: Int) {
        let approval = PendingApproval(executionID: executionID, question: question, edgeIndex: edgeIndex)
        pendingApprovals.append(approval)
        _approvalsChanged.send(pendingApprovals)
    }

    func resolve(executionID: String, approved: Bool, reason: String?) async throws -> TransitionResult {
        guard let index = pendingApprovals.firstIndex(where: { $0.executionID == executionID }) else {
            throw WorkflowEngineError.notAwaitingApproval
        }
        let approval = pendingApprovals[index]

        let result = try await engine.resolveHumanApproval(
            executionID: executionID,
            edgeIndex: approval.edgeIndex,
            approved: approved,
            reason: reason
        )

        pendingApprovals.remove(at: index)
        _approvalsChanged.send(pendingApprovals)

        return result
    }

    func clearAll() {
        pendingApprovals.removeAll()
        _approvalsChanged.send(pendingApprovals)
    }
}
