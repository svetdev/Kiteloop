import Foundation

/// What "at the gate" means right now for one item — three states that one
/// status used to hide: the gate is **verifying** the merged tree, the gate
/// went green (or was never run) and is **waiting** on a person, or the gate
/// **refused** and the reason is on record. Pure, so the item page, the
/// control API and the phone all read the same answer from the same facts.
package struct GateState: Equatable, Sendable {
    package enum Kind: String, Sendable {
        case verifying
        case waiting
        case refused
    }

    package let kind: Kind
    /// When the verifying began, or when the refusal was recorded; nil while
    /// waiting with nothing on record.
    package let since: Date?
    /// The refusal, verbatim from the merge record; nil otherwise.
    package let reason: String?

    package init(kind: Kind, since: Date? = nil, reason: String? = nil) {
        self.kind = kind
        self.since = since
        self.reason = reason
    }

    /// The last merge attempt on record for the item, as the ledger has it.
    package struct LastMerge: Equatable, Sendable {
        package let merged: Bool
        package let at: Date
        package let reason: String?

        package init(merged: Bool, at: Date, reason: String?) {
            self.merged = merged
            self.at = at
            self.reason = reason
        }
    }

    /// The state for an item at `awaiting-approval`; nil for any other status.
    ///
    /// - Parameters:
    ///   - isAwaitingApproval: the item's status is the gate.
    ///   - verifyingSince: when a gate began verifying this item and has not
    ///     returned yet; nil when no gate is running for it.
    ///   - lastMerge: the newest merge record for the item, if any.
    ///   - gateOpenedAt: when the item reached the gate, when known — a
    ///     refusal older than that belongs to an earlier visit and no longer
    ///     describes this one.
    package static func resolve(
        isAwaitingApproval: Bool,
        verifyingSince: Date?,
        lastMerge: LastMerge?,
        gateOpenedAt: Date? = nil
    ) -> GateState? {
        guard isAwaitingApproval else { return nil }
        if let verifyingSince { return GateState(kind: .verifying, since: verifyingSince) }
        if let lastMerge, !lastMerge.merged, lastMerge.at >= (gateOpenedAt ?? .distantPast) {
            return GateState(kind: .refused, since: lastMerge.at, reason: lastMerge.reason)
        }
        return GateState(kind: .waiting)
    }

    /// The one line a person reads: what the gate is doing and, for a
    /// refusal, why.
    package func line(now: Date) -> String {
        switch kind {
        case .verifying:
            let seconds = since.map { Int(now.timeIntervalSince($0).rounded(.down)) } ?? 0
            return "At gate — verifying the merged tree (\(Self.elapsed(seconds)))"
        case .waiting:
            return "At gate — waiting on you"
        case .refused:
            return "At gate — refused: \(reason ?? "no reason recorded")"
        }
    }

    private static func elapsed(_ seconds: Int) -> String {
        seconds < 60 ? "\(max(0, seconds))s" : "\(seconds / 60) min"
    }
}
