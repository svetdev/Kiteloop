import Foundation
import Observation

/// A device that sent a pairing code and is waiting for the person at the Mac
/// to allow it: the code it sent and the name it gave itself.
package struct PairingRequest: Equatable, Identifiable, Sendable {
    package let id: UUID
    package let code: String
    package let name: String

    package init(id: UUID = UUID(), code: String, name: String) {
        self.id = id
        self.code = code
        self.name = name
    }
}

/// The pairing codes a device has answered and the person has not.
///
/// A code alone pairs nothing. `POST /v1/pair` takes no bearer token, so
/// whatever holds the code — a process on this Mac included — can send it;
/// the token is issued only once the person allows the request on the sheet
/// that shows the code. A code answers to one device: a second request for
/// a code that already has one waiting ends both and marks the code
/// contested, so a caller that raced the phone cannot be allowed in its place.
///
/// Nothing here reads a clock: a request waits until the person answers, the
/// sheet closes or its caller hangs up (the pattern `HeldConfigChanges` set).
@MainActor
@Observable
package final class PairingRequests {

    /// What the waiting caller is told.
    package enum Outcome: Equatable, Sendable {
        case allowed
        case declined
        /// The sheet showing the code closed before the person answered.
        case withdrawn
        /// The caller hung up; nothing was paired.
        case callerGone
        /// More than one device sent the code; neither is paired.
        case contested
    }

    /// The request waiting on each code, by code.
    package private(set) var waiting: [String: PairingRequest] = [:]
    /// The codes more than one device sent, until their sheet closes.
    package private(set) var contested: Set<String> = []
    @ObservationIgnored private var callers: [UUID: CheckedContinuation<Outcome, Never>] = [:]

    package init() {}

    /// Files `request` and suspends until the person answers it, the sheet
    /// closes or its caller leaves. A second request for a code ends the one
    /// waiting and itself, both `.contested`.
    package func outcome(of request: PairingRequest) async -> Outcome {
        guard !contested.contains(request.code) else { return .contested }
        if let earlier = waiting.removeValue(forKey: request.code) {
            contested.insert(request.code)
            callers.removeValue(forKey: earlier.id)?.resume(returning: .contested)
            return .contested
        }
        waiting[request.code] = request
        return await withCheckedContinuation { callers[request.id] = $0 }
    }

    /// The person's answer to the request waiting on `code`; false when
    /// none is — its caller left, or the code was contested meanwhile.
    @discardableResult
    package func answer(code: String, allow: Bool) -> Bool {
        end(code, with: allow ? .allowed : .declined)
    }

    /// The sheet showing `code` closed: its request is over, and so is the
    /// record that the code was contested.
    package func withdraw(code: String) {
        end(code, with: .withdrawn)
        contested.remove(code)
    }

    /// The caller of `request` hung up. Only that request ends: one that
    /// replaced it on the same code is someone else's.
    package func callerLeft(_ request: PairingRequest) {
        guard waiting[request.code]?.id == request.id else { return }
        end(request.code, with: .callerGone)
    }

    @discardableResult
    private func end(_ code: String, with outcome: Outcome) -> Bool {
        guard let request = waiting.removeValue(forKey: code),
              let caller = callers.removeValue(forKey: request.id) else { return false }
        caller.resume(returning: outcome)
        return true
    }
}
