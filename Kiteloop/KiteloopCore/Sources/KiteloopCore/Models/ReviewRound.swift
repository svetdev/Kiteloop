import Foundation

/// One reviewer round inside a run — reject, pass, made readable without
/// opening the transcript.
///
/// Findings counts are recorded only where they mean something: a `rejected`
/// round carries what the reviewer raised, and every other verdict leaves it
/// at zero rather than inventing a count nothing measured.
package struct ReviewRound: Codable, Equatable, Sendable {
    package enum Verdict: String, Codable, Sendable {
        case passed
        case rejected
        /// The reviewer answered without a machine-readable verdict, and the
        /// one follow-up ask (`reviewer-clarify`) got no readable answer either.
        case unreadable
    }

    /// `"review 1"`, `"review 2"` — what the round is labelled with.
    package let label: String
    package let verdict: Verdict
    /// Blocking findings a rejecting review raised. Zero for every verdict but `.rejected`.
    package let blockingCount: Int
    /// Advisory findings raised alongside. Zero where none were.
    package let advisoryCount: Int

    package init(label: String, verdict: Verdict,
                blockingCount: Int = 0, advisoryCount: Int = 0) {
        self.label = label
        self.verdict = verdict
        self.blockingCount = blockingCount
        self.advisoryCount = advisoryCount
    }

    /// The compact line the page shows: `"review 1 · rejected · 2 blocking"`,
    /// `"review 2 · passed"`.
    package var summary: String {
        switch verdict {
        case .passed: return "\(label) · passed"
        case .unreadable: return "\(label) · unreadable"
        case .rejected:
            guard blockingCount > 0 else { return "\(label) · rejected" }
            return "\(label) · rejected · \(blockingCount) blocking"
        }
    }
}
