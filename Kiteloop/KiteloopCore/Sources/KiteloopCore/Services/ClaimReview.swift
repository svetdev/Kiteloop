import Foundation

/// A worker's claim that an item is already built, put to the reviewer.
///
/// A run that changes no files and ends on the worker's already-implemented
/// claim used to stop before the reviewer and park the item at the approval
/// gate, saying that nothing had verified the claim. On a project that lands
/// review-passed work there is nobody at that gate, so the item waited for a
/// person to do what the reviewer is there to do: check each Validation line
/// against the code.
///
/// So on such a project the claim goes to the reviewer — as a claim. The
/// reviewer is told the diff is empty on purpose and what the worker named,
/// and is asked to check every criterion against the code as it stands. A
/// pass marks the item done; anything else sends it back with the findings.
///
/// One review, not a loop: a rejected claim ends the run. The worker has
/// already said it would change nothing, the findings are on the item for the
/// next run to read, and that run counts against the item's retry ceiling like
/// any other that changed no files — the bound on a worker that keeps
/// claiming.
package enum ClaimReview: Equatable, Sendable {
    /// No claim is before the reviewer — every run but the one this is for.
    case none
    /// The reviewer has been handed the claim and has not been heard to
    /// reject it. Carries the evidence the worker named.
    case underReview(evidence: [String])
    /// The reviewer sent the claim back, and the run ended there.
    case rejected

    /// The execution-state key the reviewer's prompt reads the claim from.
    package static let stateKey = "alreadyImplementedClaim"

    /// The `cause` a run ended by a rejected claim is logged with.
    package static let rejectedCause = "claim-rejected"

    /// The evidence to hand the reviewer, or nil when the claim is not
    /// reviewed and the run ends as it always has.
    ///
    /// Three things have to hold. The project lands review-passed work —
    /// where it only proposes, a person is at the gate and the claim waits
    /// for them. The worker made a claim that names evidence. And the worker
    /// did not also refute the item's premise: that is the more specific
    /// finding, and it is a person's to read.
    package static func evidenceToReview(landsReviewPassedWork: Bool,
                                         claimedEvidence: [String]?,
                                         premiseRefuted: Bool) -> [String]? {
        guard landsReviewPassedWork, !premiseRefuted,
              let claimedEvidence, !claimedEvidence.isEmpty else { return nil }
        return claimedEvidence
    }

    /// What is written under `stateKey`: the worker's evidence as a list.
    package static func promptBlock(evidence: [String]) -> String {
        evidenceList(evidence)
    }

    /// How a run whose claim went to the reviewer ended.
    package enum Ending: Equatable, Sendable {
        /// The reviewer passed it and the run left nothing behind: done.
        case verified(evidence: [String])
        /// The reviewer sent it back: the item returns to Ready.
        case rejected
        /// The item's own verify was red on the unchanged tree, so the
        /// reviewer never ran. Carries the verify's signal.
        case verifyFailed(signal: String)
    }

    /// The ending this state amounts to, or nil when the run ends by the
    /// rules every other run ends by.
    ///
    /// `runWasEmpty` is git's answer after the run: a claim review that
    /// passed over a tree that did change is an ordinary reviewed diff.
    /// `gateClosedSignal` is what the pre-review gate shut on, if it did —
    /// with a claim under review that can only be the verify. A review that
    /// never reached a verdict — a stall, a cancel, an unreadable answer — is
    /// none of the three, and the claim is then still unverified.
    package func ending(reviewPassed: Bool, runWasEmpty: Bool, gateClosedSignal: String?) -> Ending? {
        switch self {
        case .none:
            return nil
        case .rejected:
            return .rejected
        case .underReview(let evidence):
            if let gateClosedSignal { return .verifyFailed(signal: gateClosedSignal) }
            return reviewPassed && runWasEmpty ? .verified(evidence: evidence) : nil
        }
    }

    /// The item's note when the reviewer passed the claim. It says who checked
    /// and that nobody else did, because the item reads Done with no diff.
    package static func verifiedNote(evidence: [String]) -> String {
        "Already implemented — verified by the reviewer. This run changed no files: the worker said "
            + "the item was already built, and the reviewer checked that claim against each Validation "
            + "line and the item's verify on the code as it stands, and passed it. Marked done because "
            + "this project lands review-passed work. No human accepted this item. "
            + "Evidence the worker named:\n\(evidenceList(evidence))"
    }

    /// The item's note when the reviewer sent the claim back. `feedback` is
    /// the reviewer's reason and findings, in the form a rejected round hands
    /// the worker.
    package static func rejectedNote(feedback: String) -> String {
        let said = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Already-implemented claim rejected by the reviewer — this run changed no files. The "
            + "worker said the item was already built; the reviewer checked the claim against the "
            + "Validation and did not pass it, so the item is back in Ready. The reviewer said:\n"
            + (said.isEmpty ? "(no reason given)" : said)
    }

    /// The item's note when the verify was red before the reviewer could run.
    package static func verifyFailedNote(signal: String) -> String {
        "Already-implemented claim not reviewed — this run changed no files and the worker said the "
            + "item was already built, but the item's verify is red on the unchanged tree (\(signal)), "
            + "so the reviewer did not run and nothing has verified the claim."
    }

    private static func evidenceList(_ evidence: [String]) -> String {
        evidence.map { "  - \($0)" }.joined(separator: "\n")
    }
}
