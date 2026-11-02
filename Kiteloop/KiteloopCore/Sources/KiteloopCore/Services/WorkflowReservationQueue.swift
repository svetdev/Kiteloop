import Foundation

package enum WorkflowReservationQueueError: Error, LocalizedError {
    case timeout(agents: Set<String>, executionID: String)

    package var errorDescription: String? {
        switch self {
        case .timeout(let agents, let execID):
            return "Timed out waiting for agents \(agents) for execution '\(execID)'"
        }
    }
}

package actor WorkflowReservationQueue {
    package init() {}

    private var holders: [String: String] = [:]   // agentID → executionID
    private var queues: [String: [String]] = [:]  // agentID → FIFO of waiting executionIDs
    private var pending: [String: PendingWaiter] = [:]  // executionID → waiter

    private struct PendingWaiter {
        let agents: Set<String>     // full set to claim once unblocked
        let continuation: CheckedContinuation<Void, Error>
    }

    package func acquire(agents: Set<String>, executionID: String, timeout: TimeInterval) async throws -> Bool {
        let blockedBy = Set(agents.filter { holders[$0] != nil && holders[$0] != executionID })

        if blockedBy.isEmpty {
            for agent in agents {
                holders[agent] = executionID
            }
            return true
        }

        // Must wait. The waiter is registered under `pending`, which is the
        // single source of truth for whether its continuation may still be
        // resumed: whoever removes the entry (release or timeout) resumes it,
        // exactly once. The timeout resumes the same continuation rather than
        // racing it in a task group — abandoning a checked continuation there
        // deadlocked the caller forever (the group awaits a child that never
        // finishes).
        //
        // The waiter queues under every agent it wants, not just the ones
        // that were held at the moment it asked: a third execution can take
        // an agent that was free at queue time, and only queuing under the
        // agents held at that instant would let this waiter be woken by an
        // unrelated release while that agent is still held elsewhere.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending[executionID] = PendingWaiter(
                agents: agents,
                continuation: continuation
            )
            for agent in agents {
                queues[agent, default: []].append(executionID)
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.timeoutWaiter(executionID: executionID)
            }
        }

        // Resumed without error: release() already claimed our agents.
        return true
    }

    package func release(executionID: String) {
        let releasedAgents = holders.filter { $0.value == executionID }.map(\.key)
        for agent in releasedAgents {
            holders.removeValue(forKey: agent)
        }

        for agent in releasedAgents {
            wakeNextWaiter(for: agent)
        }
    }

    /// Wakes the first eligible waiter in an agent's FIFO queue. A head-of-queue
    /// waiter that is still blocked on other agents keeps its place — skipping
    /// ahead would break FIFO fairness.
    private func wakeNextWaiter(for agent: String) {
        while let candidateID = queues[agent]?.first {
            guard let waiter = pending[candidateID] else {
                // Stale entry: the waiter already timed out. Drop and continue.
                queues[agent]?.removeFirst()
                if queues[agent]?.isEmpty == true { queues[agent] = nil }
                continue
            }

            let stillBlocked = waiter.agents.contains { holders[$0] != nil && holders[$0] != candidateID }
            if stillBlocked { return }

            // Claim on the waiter's behalf BEFORE resuming — the resumed task
            // runs later, and another release interleaving in between must see
            // these agents as held.
            pending.removeValue(forKey: candidateID)
            removeFromAllQueues(candidateID)
            for claimed in waiter.agents {
                holders[claimed] = candidateID
            }
            waiter.continuation.resume()
            return
        }
        if queues[agent]?.isEmpty == true { queues[agent] = nil }
    }

    private func timeoutWaiter(executionID: String) {
        // Already resumed by release()? Then this is a no-op.
        guard let waiter = pending.removeValue(forKey: executionID) else { return }
        removeFromAllQueues(executionID)
        waiter.continuation.resume(
            throwing: WorkflowReservationQueueError.timeout(agents: waiter.agents, executionID: executionID)
        )
    }

    private func removeFromAllQueues(_ executionID: String) {
        for (agent, queue) in queues {
            let filtered = queue.filter { $0 != executionID }
            queues[agent] = filtered.isEmpty ? nil : filtered
        }
    }

    package func currentHolders() -> [String: String] {
        holders
    }

    package func waitersCount(for agentID: String) -> Int {
        queues[agentID]?.count ?? 0
    }
}
