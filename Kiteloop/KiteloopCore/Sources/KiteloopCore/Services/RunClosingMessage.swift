import Foundation

/// The last thing an agent said before its node finished — kept, so a run that
/// produced no work says *why* it produced no work.
///
/// `RunWorkEvidence` answers whether a run left anything behind. It cannot
/// answer why not, and "why not" is three different situations wearing the same
/// sentence: a session that died and wrote nothing, a worker that investigated
/// and correctly declined to redo an item that was already implemented, and a
/// worker that ran for twenty minutes and gave up. On 2026-08-09, 66 of 105 runs
/// ended "produced no work" and separating those three took hours of reading
/// session files by hand — five of the diagnoses that came out of it were wrong.
///
/// The evidence was there the whole time and was thrown away at the end of every
/// run: the worker's own closing message. One recovered by hand read *"This is
/// the commit that actually implements the item — already merged into this
/// branch"*, which is the entire answer in one sentence.
///
/// So the words are recorded — **the words, not a category**. Reading "already
/// implemented" versus "gave up" out of free text is a judgement, and a
/// judgement that is wrong some of the time is worse than the raw sentence,
/// because a label is believed and a quotation is read. Nothing here classifies.
///
/// And when there is no closing message at all, that is said out loud rather
/// than left as a blank: `noOutput` is the most diagnostic answer available,
/// because it is exactly what a dead session looks like.
package enum RunClosingMessage {

    /// Where the text rides from the agent's turn to the run that reads it: a
    /// reserved key on the workflow node's completion output, so it lands on the
    /// `ExecutionStep` for that node. Underscore-prefixed like `_eventType` and
    /// `_failureReason` — the templater only substitutes keys a prompt names, so
    /// this one never reaches a model.
    package static let outputKey = "_closingMessage"

    /// The most of an agent's closing message that is ever *shown*. A signpost,
    /// not a transcript: it goes in a one-line note, a log field and a run
    /// record, and the whole transcript is a different problem. Long enough for
    /// the sentence that answers the question, short enough that a run log stays
    /// readable.
    package static let characterLimit = 300

    /// The most that is *kept*, on the step the run reads back.
    ///
    /// A separate, larger bound because the two are different questions, and
    /// applying the display one at capture answered the wrong one: the message
    /// is not only read by people. `RunWorkEvidence.AlreadyImplementedClaim`
    /// parses it for the worker's structured claim that the item was already
    /// built, and a claim naming three files clears 300 characters easily —
    /// truncated there, it arrives as JSON with no closing brace and parses as
    /// nothing at all, which is indistinguishable from a worker that never made
    /// a claim. Still bounded, because this rides in workflow state and is
    /// checkpointed with it; a transcript belongs in `RunTranscriptStore`.
    package static let captureLimit = 4_000

    /// What a run whose agent said nothing at all records. Not an empty string
    /// and not a missing field — those read as "nobody looked", and this is a
    /// finding.
    package static let noOutput = "no output from the worker"

    /// The closing message as it is recorded: one line, trimmed, bounded.
    ///
    /// Newlines collapse to spaces because every consumer is single-line — a
    /// markdown list item, a logfmt field. Nil when there is nothing left after
    /// trimming, which is the `noOutput` case and must not be confused with a
    /// message that happens to be short.
    package static func condensed(_ text: String?) -> String? {
        guard let text else { return nil }
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        guard oneLine.count > characterLimit else { return oneLine }
        let head = String(oneLine.prefix(characterLimit))
            .trimmingCharacters(in: .whitespaces)
        return head + "…"
    }

    /// The closing message as it is **kept** on the node's completion output:
    /// trimmed and bounded at `captureLimit`, with its line breaks intact.
    ///
    /// Deliberately not `condensed`. That one is the display form and every
    /// consumer that shows the message still goes through it — but it was being
    /// applied here, at capture, which threw the rest of the message away before
    /// anything could read it. Line breaks are kept for the same reason the
    /// bound is larger: what reads this rather than shows it is a JSON parser.
    ///
    /// Nil when there is nothing left after trimming — the `noOutput` case,
    /// which must not be confused with a message that happens to be short.
    package static func captured(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > captureLimit else { return trimmed }
        return String(trimmed.prefix(captureLimit))
    }

    /// The phrase the item's Notes, the run log and the run record all carry —
    /// the agent's words in quotes, or the fact that there were none.
    package static func phrase(_ message: String?) -> String {
        guard let message = condensed(message) else { return noOutput }
        return "worker's closing message: \"\(message)\""
    }

    /// The closing message a node last finished with, off the steps an execution
    /// recorded.
    ///
    /// The *last* step for the node, because a rejected worker runs again and it
    /// is the final attempt the run ended on. Nil when the node never completed
    /// a step — which is what an execution whose session died looks like, and is
    /// reported as `noOutput` rather than as a gap in the record.
    package static func lastMessage(in steps: [ExecutionStep], node: WorkflowGraph.NodeID) -> String? {
        condensed(rawLastMessage(in: steps, node: node))
    }

    /// The message as it was captured — `captured`'s form, not `condensed`'s.
    ///
    /// The display bound is exactly the wrong thing to hand a *parser*: JSON cut
    /// off at 300 characters is not JSON. So the captured text is available too,
    /// for the reader that looks for structure in it rather than showing it to a
    /// person — `RunWorkEvidence.AlreadyImplementedClaim`, which reads the
    /// worker's claim that the item was already built. Everything a human sees
    /// still goes through `phrase`, which condenses.
    package static func rawLastMessage(in steps: [ExecutionStep], node: WorkflowGraph.NodeID) -> String? {
        guard let step = steps.last(where: { $0.nodeID == node }) else { return nil }
        return step.output?[outputKey]?.stringValue
    }
}
