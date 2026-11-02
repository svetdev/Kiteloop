import Foundation
import XCTest
@testable import KiteloopCore

final class PairingReachabilityProbeTests: XCTestCase {
    func testReachableWhenTheCheckSucceeds() async {
        let probe = PairingReachabilityProbe(timeout: 0.05) { _ in true }

        let result = await probe.probe(address: "100.64.1.2", port: 4517)

        XCTAssertEqual(result, .reachable)
    }

    func testUnreachableWhenTheCheckFails() async {
        let probe = PairingReachabilityProbe(timeout: 0.05) { _ in false }

        let result = await probe.probe(address: "100.64.1.2", port: 4517)

        XCTAssertEqual(result, .unreachable)
    }

    /// Nothing answering reads the same as a slow answer that never arrives:
    /// the check outlives the deadline, so the deadline — not the check — is
    /// what ends the probe. The check only resumes once cancelled, the same
    /// way a real `URLSession` task resumes its continuation once its own
    /// cancellation handler fires; a check that never resumes at all would
    /// deadlock `withTaskGroup`, which waits for every child task, cancelled
    /// or not, before it returns.
    func testUnreachableWhenTheCheckNeverReturns() async {
        let box = UnresumedContinuationBox()
        let probe = PairingReachabilityProbe(timeout: 0.05) { _ in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { box.store($0) }
            } onCancel: {
                box.cancel()
            }
        }

        let result = await probe.probe(address: "100.64.1.2", port: 4517)

        XCTAssertEqual(result, .unreachable)
    }
}

/// Holds a continuation that the probe's check leaves open until cancelled,
/// so the cancellation handler above has somewhere to reach it from outside
/// the `async` closure that created it.
private final class UnresumedContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?

    func store(_ continuation: CheckedContinuation<Bool, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func cancel() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
