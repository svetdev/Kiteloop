import Foundation

/// Reads a run's review rounds off its workflow steps — a mapping, not a
/// second judgement: every verdict and count here is what the reviewer or the
/// worker already wrote to the step's own output.
package enum ReviewRounds {

    /// `BacklogAutopilot.reviewerClarifyNodeID`'s raw value. Duplicated rather
    /// than imported — the app owns that constant, and this package cannot
    /// depend on it — but the two name the same node, and `nodeID` there is
    /// documented as the log's own contract, so this string is exactly as
    /// stable as that one.
    private static let clarifyNodeID = "reviewer-clarify"

    /// The node whose output carries a `passed`/`false` review verdict.
    private static let reviewNodeID = "reviewer"

    /// This run's rounds, in the order they happened.
    ///
    /// `reviewer-clarify` is not a round of its own — it is a second question
    /// about the review that just ran, not a second review — so a clarify step
    /// immediately following a review step replaces that round's verdict
    /// rather than adding one.
    package static func rounds(steps: [ExecutionStep]) -> [ReviewRound] {
        var rounds: [ReviewRound] = []
        var reviewIndex = 0
        var index = 0
        while index < steps.count {
            let step = steps[index]
            if step.nodeID == reviewNodeID {
                reviewIndex += 1
                var output = step.output ?? [:]
                if index + 1 < steps.count, steps[index + 1].nodeID == clarifyNodeID {
                    output = steps[index + 1].output ?? [:]
                    index += 1
                }
                rounds.append(reviewRound(label: "review \(reviewIndex)", output: output))
            }
            index += 1
        }
        return rounds
    }

    private static func reviewRound(label: String, output: [String: AnyCodable]) -> ReviewRound {
        let findings = ReviewFindings.findings(in: output)
        let blocking = findings.filter { $0.severity == .blocking }.count
        let advisory = findings.filter { $0.severity == .advisory }.count
        switch output[ReviewFindings.verdictKey]?.stringValue {
        case "true":
            return ReviewRound(label: label, verdict: .passed, blockingCount: blocking, advisoryCount: advisory)
        case "false":
            return ReviewRound(label: label, verdict: .rejected, blockingCount: blocking, advisoryCount: advisory)
        default:
            return ReviewRound(label: label, verdict: .unreadable)
        }
    }
}
