import XCTest
@testable import KiteloopCore

final class WorkflowReservationQueueTests: XCTestCase {

    func testImmediateAcquisitionWhenFree() async throws {
        let queue = WorkflowReservationQueue()
        let agents: Set<String> = ["agent-a", "agent-b"]

        let result = try await queue.acquire(agents: agents, executionID: "exec-1", timeout: 5.0)
        XCTAssertTrue(result)

        let holders = await queue.currentHolders()
        XCTAssertEqual(holders["agent-a"], "exec-1")
        XCTAssertEqual(holders["agent-b"], "exec-1")
    }

    func testQueuedAcquisitionAfterRelease() async throws {
        let queue = WorkflowReservationQueue()
        let agents: Set<String> = ["agent-a"]

        _ = try await queue.acquire(agents: agents, executionID: "exec-1", timeout: 5.0)

        let task = Task<Bool, Error> {
            try await queue.acquire(agents: agents, executionID: "exec-2", timeout: 5.0)
        }

        try await eventually("exec-2 queued behind agent-a") { await queue.waitersCount(for: "agent-a") == 1 }

        let waiters = await queue.waitersCount(for: "agent-a")
        XCTAssertEqual(waiters, 1)

        await queue.release(executionID: "exec-1")

        let result = try await task.value
        XCTAssertTrue(result)

        let holders = await queue.currentHolders()
        XCTAssertEqual(holders["agent-a"], "exec-2")
    }

    func testTimeoutReturnsFailure() async throws {
        let queue = WorkflowReservationQueue()
        let agents: Set<String> = ["agent-a"]

        _ = try await queue.acquire(agents: agents, executionID: "exec-1", timeout: 5.0)

        do {
            _ = try await queue.acquire(agents: agents, executionID: "exec-2", timeout: 0.1)
            XCTFail("Expected timeout error")
        } catch {
            guard case WorkflowReservationQueueError.timeout = error else {
                XCTFail("Expected timeout error, got \(error)")
                return
            }
        }
    }

    func testFIFOOrdering() async throws {
        let queue = WorkflowReservationQueue()
        let agents: Set<String> = ["agent-a"]

        _ = try await queue.acquire(agents: agents, executionID: "exec-1", timeout: 5.0)

        // Appended on the waiting tasks, read back on the test's.
        let completionOrder = OrderRecorder()

        let task2 = Task {
            _ = try await queue.acquire(agents: agents, executionID: "exec-2", timeout: 5.0)
            completionOrder.record("exec-2")
        }

        try await eventually("exec-2 queued behind agent-a") { await queue.waitersCount(for: "agent-a") == 1 }
        let task3 = Task {
            _ = try await queue.acquire(agents: agents, executionID: "exec-3", timeout: 5.0)
            completionOrder.record("exec-3")
        }

        try await eventually("exec-3 queued behind exec-2") { await queue.waitersCount(for: "agent-a") == 2 }

        await queue.release(executionID: "exec-1")
        try await eventually("exec-2 acquired and recorded") { completionOrder.values == ["exec-2"] }

        await queue.release(executionID: "exec-2")

        _ = await task2.result
        _ = await task3.result

        XCTAssertEqual(completionOrder.values, ["exec-2", "exec-3"])
    }

    func testReleaseNonexistentIsNoop() async {
        let queue = WorkflowReservationQueue()
        await queue.release(executionID: "nonexistent")
    }

    func testPartialOverlapQueues() async throws {
        let queue = WorkflowReservationQueue()

        _ = try await queue.acquire(agents: ["agent-a", "agent-b"], executionID: "exec-1", timeout: 5.0)

        let task = Task<Bool, Error> {
            try await queue.acquire(agents: ["agent-b", "agent-c"], executionID: "exec-2", timeout: 5.0)
        }

        try await eventually("exec-2 queued behind agent-b") { await queue.waitersCount(for: "agent-b") == 1 }
        let waiters = await queue.waitersCount(for: "agent-b")
        XCTAssertEqual(waiters, 1)

        await queue.release(executionID: "exec-1")
        let result = try await task.value
        XCTAssertTrue(result)
    }

    func testThirdExecutionHoldingAgentBlocksQueuedWaiter() async throws {
        let queue = WorkflowReservationQueue()

        _ = try await queue.acquire(agents: ["agent-a", "agent-b"], executionID: "exec-1", timeout: 5.0)

        let task = Task<Bool, Error> {
            try await queue.acquire(agents: ["agent-b", "agent-c"], executionID: "exec-2", timeout: 5.0)
        }

        try await eventually("exec-2 queued behind agent-b") { await queue.waitersCount(for: "agent-b") == 1 }
        let waiters = await queue.waitersCount(for: "agent-b")
        XCTAssertEqual(waiters, 1)

        // exec-3 takes agent-c out from under the still-queued exec-2 while
        // it was free.
        _ = try await queue.acquire(agents: ["agent-c"], executionID: "exec-3", timeout: 5.0)

        await queue.release(executionID: "exec-1")
        try await Task.sleep(for: .milliseconds(50))

        // exec-2 must still be waiting: agent-c is held by exec-3, which has
        // not released, so exec-2's holders must not have changed.
        XCTAssertFalse(task.isCancelled)
        var holders = await queue.currentHolders()
        XCTAssertEqual(holders["agent-a"], nil)
        XCTAssertEqual(holders["agent-b"], nil)
        XCTAssertEqual(holders["agent-c"], "exec-3")

        await queue.release(executionID: "exec-3")
        let result = try await task.value
        XCTAssertTrue(result)

        holders = await queue.currentHolders()
        XCTAssertEqual(holders["agent-b"], "exec-2")
        XCTAssertEqual(holders["agent-c"], "exec-2")
    }

    private final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var order: [String] = []

        func record(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            order.append(value)
        }

        var values: [String] {
            lock.lock(); defer { lock.unlock() }
            return order
        }
    }

}
