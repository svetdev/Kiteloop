import Foundation

/// The Dismiss and Dismiss All presses on the Interrupted Runs sheet: each
/// either removes a run's checkpoints or says why it could not — the contract
/// `Orchestrator.attemptResume` already keeps on that sheet.
///
/// A type of its own, rather than these methods living on `Orchestrator`, for
/// the reason `Orchestrator+PendingAgentLaunch.swift` gives: that class's own
/// file already carries more than the complexity ratchet's baseline recorded on
/// adoption day, so the lines this needs cannot go there.
@MainActor
struct WorkflowDismiss {
    let orchestrator: Orchestrator

    /// Dismisses one run. The row is dropped only when its checkpoints actually
    /// went; a dismiss that did not happen leaves it in the list and reports.
    func one(executionID: String) async -> Orchestrator.ResumeReport {
        let label = orchestrator.incompleteExecutions.first { $0.id == executionID }?.displayName ?? executionID

        if let failure = await failure(executionID: executionID, label: label) {
            return orchestrator.record(.init(executionID: executionID, message: failure, succeeded: false))
        }

        orchestrator.incompleteExecutions.removeAll { $0.id == executionID }
        // Don't leave a resume failure on screen for a row that's gone.
        if orchestrator.lastResumeReport?.executionID == executionID {
            orchestrator.lastResumeReport = nil
        }
        return .init(executionID: executionID, message: "Dismissed \"\(label)\".", succeeded: true)
    }

    /// Dismisses every listed run, keeping the rows whose checkpoints did not go
    /// and reporting the first refusal rather than emptying the list regardless.
    func all() async -> Orchestrator.ResumeReport {
        var failures: [(id: String, message: String)] = []
        for row in orchestrator.incompleteExecutions {
            if let failure = await failure(executionID: row.id, label: row.displayName) {
                failures.append((row.id, failure))
            }
        }

        let failed = Set(failures.map(\.id))
        orchestrator.incompleteExecutions.removeAll { !failed.contains($0.id) }

        guard let first = failures.first else {
            orchestrator.lastResumeReport = nil
            return .init(executionID: "", message: "Dismissed the interrupted runs.", succeeded: true)
        }
        return orchestrator.record(.init(executionID: first.id, message: first.message, succeeded: false))
    }

    /// Why this run's checkpoints are still there, or nil once they are gone.
    private func failure(executionID: String, label: String) async -> String? {
        guard let service = orchestrator.workflowResumeService else {
            return "Can't dismiss \"\(label)\": workflow checkpointing isn't configured for this project."
        }
        do {
            try await service.dismiss(executionID: executionID)
            return nil
        } catch {
            return "Can't dismiss \"\(label)\": \(error.localizedDescription)"
        }
    }
}
