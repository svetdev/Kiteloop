import Foundation

/// Telling a worker, while it can still act, that it has changed nothing.
///
/// A worker can finish believing it is done having changed no files, and until
/// now nobody told it. On 2026-08-09 a run ended `produced no work — no branch`
/// with the closing message *"Done. ./scripts/ci-local.sh is green"*. The worker
/// ran the item's verify against an unchanged tree, watched it pass — which is
/// what that command does on a clean checkout — and reported success. There was
/// no branch, no diff and nothing delivered.
///
/// The emptiness was already known to the run: `RunWorkEvidence` computes it
/// from git. But it computes it *after* the worker's session has gone, so the
/// only party that could still do something about it never hears. The item
/// returns to `ready` and the next attempt repeats the whole thing —
/// `settings-checked-queries` did it five times, `small-routes` four.
///
/// So git is asked one turn earlier, at the moment the worker's node is about to
/// hand off to the reviewer, and an empty tree is said out loud to the worker.
/// It then does one of two things, and **both are useful**: it makes the change,
/// or it states that it believes the item is already implemented — which is the
/// outcome nobody could see before, and which rides out of the run as the
/// closing message `RunClosingMessage` keeps.
///
/// **Once, not in a loop.** A worker that is told and still changes nothing has
/// answered; asking again spends a second pass to learn the same thing. The
/// caller owns that flag — see `BacklogAutopilot.emptyDiffHandoff` — because
/// "once" is per item run, not per process.
///
/// This does not replace the post-run evidence check. That check is the backstop
/// and is unchanged; this is the one chance to act while there still is one.
enum EmptyDiffHandoff {

    /// Whether the worker should be told, given what git said about its worktree
    /// and whether it has already been told this run.
    ///
    /// Only `.noChanges` qualifies — the verdict `RunWorkEvidence.inspectBlocked`
    /// returns when the worktree is clean *and* the branch carries no commit,
    /// which is exactly the shape of a worker that did nothing. `.unknown` does
    /// not: "nobody could tell" is a different fact from "there is nothing
    /// there", and telling a worker it changed nothing on the strength of an
    /// unreadable git is how a run that did real work gets an accusing turn it
    /// has to argue with.
    static func shouldTell(verdict: RunWorkEvidence.Verdict, alreadyTold: Bool) -> Bool {
        guard !alreadyTold else { return false }
        return verdict == .noChanges
    }

    /// What the worker is told. Written to be actionable in one read: the fact,
    /// why the green verify it just ran is not an answer to it, the two things it
    /// may do, and that this is the only time it will be asked.
    ///
    /// It deliberately does not push toward making an edit. An item that really
    /// is already implemented should end saying so — a fabricated diff to make a
    /// run "count" is a worse outcome than an empty one, because it merges.
    ///
    /// And the second option is spelled out as a shape rather than left as
    /// prose, because prose had nowhere to go: a worker that said it in words
    /// was filed as a run that achieved nothing and counted against the item's
    /// retry ceiling. The object below is what `RunWorkEvidence
    /// .AlreadyImplementedClaim` reads, and the evidence list is what separates
    /// a claim from an excuse — so the prompt asks for it in the same breath as
    /// the claim, rather than leaving a worker to find out afterwards that a
    /// claim naming nothing counts like silence.
    static let prompt = """
        Before this hands off: git says you have changed no files — nothing \
        committed on this run's branch, and nothing uncommitted in the worktree.

        A passing verify does not answer that. The command passes on a clean \
        checkout — that is what it does — and a clean checkout is what it just \
        ran against, so a green result is not evidence that this item was built.

        Do one of three things now:
          • make the change the item asks for; or
          • if you checked the item's Premise and refuted a claim in it, restate \
        your premise report — one line per claim, `held`, `refuted: <measurement>` \
        or `unverifiable: <why>` — with the measurement that refuted it and what, \
        if anything, still qualifies. A refuted premise is a legitimate end to the \
        run, recorded as an investigation for a person to read; or
          • if you believe the item is already implemented, end your reply with \
        this object, naming the code that already does it — file and symbol, in \
        the spelling the item's Validation uses:

            {"outcome": "already-implemented",
             "evidence": ["Services/Foo.swift — `Foo.bar()` already does X",
                          "Views/Baz.swift — calls it on save"]}

        The evidence list is what makes it a claim, as the measurement is what \
        makes a refutation: with either, this run is recorded as its own outcome \
        and the item goes to a human to judge, rather than counting as an attempt \
        that produced nothing. Without it — an empty list, or no object at all — \
        the run counts exactly as a run that achieved nothing, because that is \
        all anyone can tell it apart from.

        Do not invent an edit to make this run count, and do not claim this to \
        get out of a hard item: a person reads the claim against the code. You \
        are being told this once; your next reply ends your part of the run \
        either way.
        """

    /// The run-log line for the moment it happens, so a transcript read later
    /// shows the prompt as a step the run took rather than as an unexplained
    /// extra worker turn.
    static let logLine = "Worker finished having changed no files — telling it once "
        + "before it hands off to the reviewer"
}
