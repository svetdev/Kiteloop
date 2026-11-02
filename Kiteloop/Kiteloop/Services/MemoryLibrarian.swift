import Foundation
import KiteloopCore

/// The librarian: what a consolidation pass reads, what it is asked, and how its
/// answer becomes proposals.
///
/// Memory that only accretes goes stale and contradicts itself — duplicate facts,
/// assertions nothing ever invalidated, competing notes an agent then has to
/// choose between. Timers do not fix that: a TTL on prose deletes by age, which
/// is uncorrelated with whether a fact is still true. What does work is a
/// periodic pass that *reads* the corpus and *proposes* — merges of duplicates,
/// deletions of facts the current code contradicts, archival of what has gone
/// stale — and leaves every actual change to the human gate that already exists.
///
/// **The librarian applies nothing.** Everything it decides arrives as a
/// ``MemoryProposal`` in the Memory tab, approved or rejected exactly like an
/// agent's own `propose_memory` call. That is the whole safety story, and it is
/// why this file has no write path in it at all.
///
/// Pure and unit-testable: the corpus in, the prompt out, the reply parsed.
/// ``MemoryLibrarianPass`` owns the model call, the files and the ledger.
enum MemoryLibrarian {

    // MARK: - The corpus

    /// One agent's memory as the pass sees it: the injected index, and the topic
    /// bodies behind it.
    struct AgentCorpus: Equatable, Sendable {
        let agentID: String
        let agentName: String
        /// The index file's text — the lines that ride into every prompt.
        let index: String
        let topics: [MemoryTopic]

        var facts: [AgentMemoryIndex.Fact] { AgentMemoryIndex.parse(index) }
    }

    /// Everything one pass reads.
    ///
    /// `coordinatorKnowledge` is read-only context, not something the pass
    /// proposes against: it has its own cap and its own dedup
    /// (``CoordinatorKnowledge/merge(existing:newLearnings:)``), and the
    /// ``MemoryProposal`` gate applies to per-agent memory. It is here because a
    /// bullet in it is often exactly what contradicts a fact an agent is still
    /// being shown, and a librarian that could not see it would have to guess.
    struct Corpus: Equatable, Sendable {
        let agents: [AgentCorpus]
        let coordinatorKnowledge: String?

        /// A corpus with no facts in it is nothing to consolidate, whatever else
        /// is in the project — the pass reports that without calling a model.
        var isEmpty: Bool { factCount == 0 }
        var factCount: Int { agents.reduce(0) { $0 + $1.facts.count } }
    }

    // MARK: - Cadence

    /// How often a pass is worth making. Consolidation is a judgement over a
    /// corpus that changes a fact at a time, so a week is the grain: often
    /// enough that duplicates do not pile up, rare enough that the cost is
    /// noise. It is a prompt, not a timer — nothing here runs a pass, it only
    /// says when one is worth offering.
    static let interval: TimeInterval = 7 * 24 * 60 * 60

    /// Whether a pass is due. A corpus never consolidated is due as soon as it
    /// has facts in it; one consolidated within ``interval`` is not.
    static func isDue(lastPassAt: Date?, now: Date = Date()) -> Bool {
        guard let lastPassAt else { return true }
        return now.timeIntervalSince(lastPassAt) >= interval
    }

    // MARK: - What a pass reports

    /// What the pass is called when it has nothing to say. A clean corpus is a
    /// valid, cheap outcome — not a failure, and not silence.
    static let nothingToConsolidate = "Nothing to consolidate."

    /// The result of one pass, as the UI reads it.
    struct Outcome: Equatable, Sendable {
        let proposals: [MemoryProposal]
        let costUSD: Double
        /// One sentence for a human: what was proposed, or that nothing was.
        let summary: String
        /// What the pass declined to pass on, and why — a proposal naming a fact
        /// that isn't there, a deletion downgraded to an archival. Stated rather
        /// than dropped: a librarian that quietly discards half its own answer
        /// reads as one that found nothing.
        let notes: [String]

        static func nothing(costUSD: Double, notes: [String] = []) -> Outcome {
            Outcome(proposals: [], costUSD: costUSD, summary: nothingToConsolidate, notes: notes)
        }
    }

    // MARK: - The prompt

    static let systemPrompt = """
        You are a librarian for a team of AI agents. You read what the agents have \
        been told to remember and you propose how to tidy it. You never change \
        anything: every proposal you make is reviewed by a human, who approves or \
        rejects it one at a time.

        Memory that only grows goes stale and contradicts itself. Your job is to \
        find three things and nothing else:

        1. DUPLICATES — two or more facts saying the same thing. Propose a MERGE: \
           one fact that says everything they said, replacing them.
        2. CONTRADICTED FACTS — a fact the current code disproves. Propose a \
           DELETE, and name the evidence: the file, symbol or command you checked \
           and what you found instead. A deletion destroys the fact's full text, \
           so it needs a reason you actually verified.
        3. STALE FACTS — about work that is finished, a file that is gone, a \
           decision since reversed, where you cannot point at what disproves it. \
           Propose an ARCHIVE. Archiving keeps the text and stops injecting it.

        "It seems old" is a reason to archive, never to delete. If you are not \
        sure a fact is wrong, archive it or leave it alone.

        Read the code before claiming it contradicts something — you have the \
        repository. Do not propose against a body that was shown to you truncated \
        on the strength of the part you could not see.

        A tidy corpus is a normal answer. If nothing needs consolidating, return \
        an empty list. Do not invent work.
        """

    /// The JSON the reply has to be. Kept beside the parser so the two cannot
    /// drift into describing different shapes.
    static let replyContract = """
        Reply with one JSON object and nothing else:

        {"proposals": [
          {"kind": "merge", "agent": "<agent id>", "topics": ["<topic>", "<topic>"],
           "content": "<the one fact that replaces them — first line is the headline>",
           "reason": "<why these are the same fact>"},
          {"kind": "delete", "agent": "<agent id>", "topic": "<topic>",
           "reason": "<why this is wrong>",
           "evidence": "<what you checked and what you found>"},
          {"kind": "archive", "agent": "<agent id>", "topic": "<topic>",
           "reason": "<why this no longer applies>"}
        ]}

        `agent` is an agent id exactly as printed below. `topics`/`topic` are topic \
        names exactly as printed in square brackets. A merge names at least two. \
        Nothing to consolidate is {"proposals": []}.
        """

    /// How much of a topic body goes into the prompt. Bodies are approved prose
    /// and can run long; a corpus of them unbounded is a prompt nobody budgeted.
    /// What is cut is marked, and the system prompt forbids judging on the part
    /// that was cut.
    static let maxBodyLength = 1200

    /// How many topic bodies go into one agent's slice of the prompt.
    ///
    /// `maxBodyLength` bounds what one body costs, not how many a corpus can
    /// produce — the topics directory has no cap of its own: a fact displaced
    /// from the index keeps its body, and a legacy `memory.md` migration writes
    /// one body per block. Left unbounded, a long-lived project builds a single
    /// prompt of hundreds of bodies. This is the other half of that budget,
    /// same in spirit as ``AgentMemoryIndex/maxFacts``.
    static let maxBodiesPerAgent = 50

    /// The topic bodies one agent's slice of the prompt shows, and how many were
    /// left out.
    ///
    /// Ordered so that a topic the index still names — the only kind ``parse``
    /// can ever file a proposal against — is never bumped by one whose fact has
    /// aged out of the index but whose body is still on disk. Below the cap
    /// nothing is reordered at all, so a corpus under it renders exactly as
    /// today.
    static func selectedBodies(for agent: AgentCorpus) -> (shown: [MemoryTopic], withheld: Int) {
        guard agent.topics.count > maxBodiesPerAgent else { return (agent.topics, 0) }
        let known = Set(agent.facts.map(\.topic))
        let ordered = agent.topics.sorted { a, b in
            known.contains(a.id) && !known.contains(b.id)
        }
        let shown = Array(ordered.prefix(maxBodiesPerAgent))
        return (shown, agent.topics.count - shown.count)
    }

    /// How many topic bodies the whole corpus left out of the prompt, across
    /// every agent — what ``MemoryLibrarianPass`` reports as a note beside
    /// whatever a pass proposed.
    static func totalWithheldBodies(corpus: Corpus) -> Int {
        corpus.agents.reduce(0) { $0 + selectedBodies(for: $1).withheld }
    }

    /// The note a pass adds when the corpus it read was cut, or nil when it
    /// wasn't — nothing to prepend for a corpus under the cap.
    static func withheldBodiesNote(corpus: Corpus) -> String? {
        let total = totalWithheldBodies(corpus: corpus)
        guard total > 0 else { return nil }
        let noun = total == 1 ? "topic body" : "topic bodies"
        let verb = total == 1 ? "was" : "were"
        return "\(total) \(noun) did not fit this pass's per-agent cap and \(verb) not sent."
    }

    static func prompt(corpus: Corpus) -> String {
        var parts: [String] = []
        parts.append("Consolidate the memory below. \(corpus.factCount) fact(s) across \(corpus.agents.count) agent(s).")

        if let knowledge = corpus.coordinatorKnowledge?.trimmingCharacters(in: .whitespacesAndNewlines),
           !knowledge.isEmpty {
            parts.append("""
                # What this project has learned (context only — do not propose against it)

                \(knowledge)
                """)
        }

        for agent in corpus.agents {
            parts.append(render(agent: agent))
        }
        parts.append(replyContract)
        return parts.joined(separator: "\n\n---\n\n")
    }

    static func render(agent: AgentCorpus) -> String {
        var out = "# Agent \(agent.agentName) (id: \(agent.agentID))\n\n## Index — injected into every prompt\n\n"
        let facts = agent.facts
        out += facts.isEmpty ? "(no facts)\n" : facts.map { $0.rendered() }.joined(separator: "\n") + "\n"

        guard !agent.topics.isEmpty else { return out }
        out += "\n## Topic bodies\n"
        let (shown, withheld) = selectedBodies(for: agent)
        for topic in shown {
            let body = topic.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyShown = body.count > maxBodyLength
                ? String(body.prefix(maxBodyLength)) + "\n… (truncated — do not judge on what is missing)"
                : body
            out += "\n### \(topic.id)\n\n\(bodyShown)\n"
        }
        if withheld > 0 {
            let noun = withheld == 1 ? "topic body" : "topic bodies"
            let verb = withheld == 1 ? "is" : "are"
            out += "\n(\(withheld) further \(noun) \(verb) not shown here — over this agent's per-pass cap.)\n"
        }
        return out
    }

    // MARK: - Reading the reply

    /// Turns a reply into proposals, dropping anything it cannot ground in
    /// `corpus` and saying so.
    ///
    /// Three rules do the grounding, and each one exists because the alternative
    /// is a proposal a human cannot act on:
    ///
    /// - an `agent` the corpus does not hold is dropped — approving it would
    ///   write memory for an agent nobody has;
    /// - a `topic` that names no fact in that agent's index is dropped — the
    ///   librarian invented it, or the fact moved since the corpus was read;
    /// - a `delete` with no evidence becomes an `archive`. That is the item's
    ///   rule made mechanical: "seems old" is archival, and a deletion that
    ///   cannot say what disproves the fact has not earned the destructive one.
    static func parse(_ reply: String, corpus: Corpus) -> (proposals: [MemoryProposal], notes: [String]) {
        guard let object = jsonObject(in: reply) else {
            return ([], ["The librarian's reply was not the JSON object it was asked for, so nothing was proposed."])
        }
        guard let raw = object["proposals"] as? [[String: Any]] else {
            return ([], ["The librarian's reply carried no `proposals` list, so nothing was proposed."])
        }

        var proposals: [MemoryProposal] = []
        var notes: [String] = []

        for entry in raw {
            let kind = (entry["kind"] as? String)?.lowercased() ?? ""
            let agentID = (entry["agent"] as? String) ?? ""
            let reason = ((entry["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let evidence = ((entry["evidence"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            guard let agent = corpus.agents.first(where: { $0.agentID == agentID }) else {
                notes.append("Dropped a \(kind.isEmpty ? "proposal" : kind) for \(agentID.isEmpty ? "an unnamed agent" : agentID) — no such agent in this project.")
                continue
            }
            let known = Set(agent.facts.map(\.topic))

            switch kind {
            case "merge":
                let topics = (entry["topics"] as? [String]) ?? []
                let content = ((entry["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let unknown = topics.filter { !known.contains($0) }
                guard unknown.isEmpty else {
                    notes.append("Dropped a merge for \(agent.agentName) — \(unknown.joined(separator: ", ")) names no fact in its index.")
                    continue
                }
                // Counted raw, a topic named twice reads as two facts and the
                // merge is filed — so what reaches the gate is a consolidation
                // of one fact with itself.
                var seen = Set<String>()
                let named = topics.filter { seen.insert($0).inserted }
                guard named.count >= 2 else {
                    let twice = named.count < topics.count ? ", and this one names the same fact twice" : ""
                    notes.append("Dropped a merge for \(agent.agentName) — a merge has to name at least two facts\(twice).")
                    continue
                }
                guard !content.isEmpty else {
                    notes.append("Dropped a merge for \(agent.agentName) — it proposed no merged text.")
                    continue
                }
                proposals.append(MemoryProposal(
                    agentID: agent.agentID, proposedContent: content,
                    operation: .merge(topics: topics), source: .librarian,
                    rationale: reason.isEmpty ? nil : reason
                ))

            case "delete", "archive":
                guard let topic = entry["topic"] as? String, known.contains(topic) else {
                    let named = (entry["topic"] as? String) ?? "an unnamed topic"
                    notes.append("Dropped a \(kind) for \(agent.agentName) — \(named) names no fact in its index.")
                    continue
                }
                // The one downgrade: a deletion is destructive, so it only stays
                // a deletion when the librarian said what disproves the fact.
                let destructive = kind == "delete" && !evidence.isEmpty
                if kind == "delete" && evidence.isEmpty {
                    notes.append("Turned a delete of \(topic) (\(agent.agentName)) into an archive — it named no evidence.")
                }
                proposals.append(MemoryProposal(
                    agentID: agent.agentID,
                    proposedContent: reason.isEmpty ? "\(destructive ? "Delete" : "Archive") \(topic)." : reason,
                    operation: destructive ? .delete(topic: topic) : .archive(topic: topic),
                    source: .librarian,
                    rationale: reason.isEmpty ? nil : reason,
                    evidence: destructive ? evidence : nil
                ))

            default:
                notes.append("Dropped a proposal for \(agent.agentName) — `\(kind)` is not one of merge, delete or archive.")
            }
        }

        return (proposals, notes)
    }

    /// The proposals object in a reply, decoded. Models fence JSON, preface it,
    /// or both; the contract asks for the object alone and this is what tolerates
    /// them not quite giving it.
    ///
    /// The scan is `StructuredOutputExtractor.balancedSlices`, which walks the
    /// characters tracking depth, `inString` and `escaped` — so a brace in the
    /// prose around the object no longer widens the slice. It used to run from
    /// the first `{` to the last `}`, and one sentence like *"the merge rule
    /// (see {merge}) applies"* before the object made the decode fail, so a pass
    /// that had been paid for in full reported nothing at all.
    ///
    /// Balanced isn't enough on its own — `{merge}` in the prose is balanced and
    /// isn't JSON — so the first slice carrying a `proposals` list wins, falling
    /// back to the first slice that decodes at all so a reply that really did
    /// answer with an object missing that key still reads as such.
    static func jsonObject(in reply: String) -> [String: Any]? {
        var firstDecoded: [String: Any]?
        for slice in StructuredOutputExtractor.balancedSlices(in: reply, open: "{", close: "}") {
            guard let data = slice.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["proposals"] is [Any] { return object }
            if firstDecoded == nil { firstDecoded = object }
        }
        return firstDecoded
    }

    // MARK: - Saying what happened

    /// The one sentence the Memory tab shows after a pass.
    static func summary(for proposals: [MemoryProposal]) -> String {
        guard !proposals.isEmpty else { return nothingToConsolidate }
        var counts: [String: Int] = [:]
        for proposal in proposals {
            counts[proposal.operation.label.lowercased(), default: 0] += 1
        }
        let order = ["merge", "delete", "archive", "add"]
        let parts = order.compactMap { label -> String? in
            guard let n = counts[label] else { return nil }
            return "\(n) \(label)\(n == 1 ? "" : "s")"
        }
        return "Proposed \(parts.joined(separator: ", ")) — waiting for your approval."
    }
}
