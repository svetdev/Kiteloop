import Foundation

/// Handing a grounding refusal back to the groomer that wrote the draft.
///
/// `GroundingCheck` refuses, at pickup, an item whose backticked paths and
/// symbols name nothing in the repo without a creation cue beside them, and the
/// item goes back to draft to wait for a person. The grooming pass computes the
/// same verdict while the model that wrote the citations is still at hand, so
/// the verdict is given back to it to reword — the rule is the check's own,
/// unchanged, and pickup still asks it.
package enum GroomingCorrection {

    /// How many times a refused grooming is handed back. The same bound a
    /// failing check gets when it is handed back to a worker
    /// (`PullRequestChecks.maxFixRounds`), rather than a number of its own: a
    /// groomer that words the same citation wrongly that many times with the
    /// refusal in front of it needs a person, as that worker does.
    package static let maxRounds = PullRequestChecks.maxFixRounds

    /// Whether a grooming judged `verdict` goes back for another round.
    package static func isOwed(after verdict: GroundingCheck.Verdict, roundsUsed: Int) -> Bool {
        !verdict.isGrounded && roundsUsed < maxRounds
    }

    /// `first`, handed back for rewording while the grounding check refuses it
    /// and a round is owed, ending at the first grounded proposal. The one loop
    /// every groomer runs — the Groom button's pass and the Planner's bulk
    /// grooming — so the bound and the stopping rule cannot differ between them.
    ///
    /// - Parameter grounding: the check's verdict on a proposal.
    /// - Parameter reword: one round — the refused proposal and the check's
    ///   summary of why, answered with the next proposal. Nil ends the rounds
    ///   and keeps the proposal that was refused: a round that produced nothing
    ///   usable, or one the caller could not afford.
    package static func settle<Proposal: Sendable>(
        _ first: Proposal,
        isolation: isolated (any Actor)? = #isolation,
        grounding: (Proposal) -> GroundingCheck.Verdict,
        reword: (Proposal, _ summary: String) async throws -> Proposal?
    ) async rethrows -> Proposal {
        var proposal = first
        var rounds = 0
        var verdict = grounding(proposal)
        while isOwed(after: verdict, roundsUsed: rounds) {
            rounds += 1
            guard let next = try await reword(proposal, verdict.summary) else { break }
            proposal = next
            verdict = grounding(proposal)
        }
        return proposal
    }

    /// The prompt for one correction round: the original request, the grooming
    /// that was refused, and the check's own words about it.
    ///
    /// - Parameter original: the prompt the refused grooming answered, whole —
    ///   the reply shape it asks for is the shape asked for again.
    /// - Parameter refused: the refused grooming, as the model proposed it.
    /// - Parameter summary: `GroundingCheck.Verdict.summary`, quoted verbatim so
    ///   the groomer reads the refusal pickup would have made.
    package static func prompt(original: String, refused: String, summary: String) -> String {
        """
        \(original)

        Your previous proposal was refused by the grounding check, which reads every \
        backticked path, symbol and `verify:` executable as a claim that it exists in the \
        repository today. The proposal:

        \(refused)

        The check's refusal, verbatim:

        \(summary)

        Return the same JSON shape again, with each refused citation reworded and \
        everything else kept. A path or symbol the item will create is introduced with \
        "add" or "create" in the same sentence as its backticked mention. A path that \
        exists is written in full from the repository root, as it is spelled on disk — \
        look it up rather than guess. Do not drop a citation the worker needs in order \
        to pass the check.
        """
    }
}
