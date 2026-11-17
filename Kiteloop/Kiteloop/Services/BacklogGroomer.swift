import Foundation
import KiteloopCore

/// One agent pass that turns a draft item into something an unattended worker
/// could run: a `verify:`, a size, and a detail file's What / How / Validation
/// / Out of Scope — checked against the repo before a human ever sees it.
///
/// Pure apart from the one-shot runner it is handed: everything else it reads
/// is a value — the item, its (possibly absent) detail, the rest of the
/// backlog the Definition-of-Ready's dependency clause needs, and a
/// `GroundingCheck.Sources` the caller already built. Two earlier attempts at
/// this item reached for `BacklogViewModel` directly instead and were both
/// refused by `check-layering.py` (Services may not depend on ViewModels); this
/// stays a value in, value out function so that mistake cannot recur here.
enum BacklogGroomer {

    /// One proposed grooming, plus what the repo says about it — read once,
    /// before the preview is shown, rather than trusted after the fact.
    struct Proposal: Sendable, Equatable {
        /// The item this proposal is about. Forced onto the draft after
        /// parsing rather than trusted from the model's reply — see `propose`
        /// — so a proposal can never be mistaken for one about a different
        /// item, however it is carried.
        let itemID: String
        let draft: QueueRefill.Draft
        let readiness: DefinitionOfReady.Verdict
        let grounding: GroundingCheck.Verdict
    }

    enum GroomError: LocalizedError, Equatable {
        case emptyResponse
        case noDraft

        var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "The assistant returned an empty reply."
            case .noDraft:
                return "The assistant didn't propose a usable grooming."
            }
        }
    }

    /// How many times a proposal the grounding check refuses is handed back
    /// to the model to reword — `GroomingCorrection.maxRounds`, the bound a
    /// failing check already gets when it goes back to a worker.
    static let maxGroundingCorrections = GroomingCorrection.maxRounds

    /// Runs an agent pass over `item` and checks what it proposes against the
    /// repo. Throws rather than returning a proposal there is no reason to
    /// preview: an empty reply or a reply with nothing `QueueRefill.Draft.parse`
    /// can use is not something to show for approval.
    ///
    /// A proposal the grounding check refuses goes back to the model with the
    /// check's own summary, up to `maxGroundingCorrections` times, and the
    /// pass ends at the first grounded one. Pickup refuses the same citations
    /// and parks the item for a person; here the model that wrote them is
    /// still at hand to reword them. A correction reply that is empty or holds
    /// no usable draft ends the rounds and keeps the last proposal, with its
    /// own verdicts — `BacklogViewModel.writeGrooming` refuses to write one
    /// that is still ungrounded.
    ///
    /// - Parameter sources: what the repo actually contains, built once by the
    ///   caller (`GroundingCheck.Sources.repository(root:vault:)`) rather than
    ///   here — building it walks the tree, and this stays pure.
    /// - Parameter runOneShot: the model call itself, already scoped to this
    ///   project by the caller.
    ///
    /// `@MainActor` because its one caller (`BacklogItemDetailViewModel.groom()`)
    /// and the `BacklogAIEditor` its closure calls into both already are — a
    /// `runOneShot` that crossed an actor boundary would have to be `@Sendable`,
    /// and the view model it closes over is not.
    @MainActor
    static func propose(
        item: BacklogItem,
        detail: BacklogItemDetail?,
        backlog: BacklogFile,
        sources: GroundingCheck.Sources,
        runOneShot: (String) async throws -> String
    ) async throws -> Proposal {
        let prompt = buildPrompt(item: item, detail: detail, backlog: backlog)
        let response = try await runOneShot(prompt)
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GroomError.emptyResponse
        }
        guard let draft = QueueRefill.Draft.parse(response).first else {
            throw GroomError.noDraft
        }
        let subject = Subject(item: item, repos: detail?.repos,
                              dependencies: DefinitionOfReady.Dependencies(file: backlog), sources: sources)
        var proposal = subject.proposal(from: draft)
        var rounds = 0
        while GroomingCorrection.isOwed(after: proposal.grounding, roundsUsed: rounds) {
            rounds += 1
            let reply = try await runOneShot(correctionPrompt(original: prompt, refused: proposal.draft,
                                                              summary: proposal.grounding.summary))
            guard let corrected = QueueRefill.Draft.parse(reply).first else { break }
            proposal = subject.proposal(from: corrected)
        }
        return proposal
    }

    /// The item a pass is about and what its proposals are judged against —
    /// the same for the first proposal and every correction of it.
    private struct Subject {
        let item: BacklogItem
        let repos: [String]?
        let dependencies: DefinitionOfReady.Dependencies
        let sources: GroundingCheck.Sources

        /// One parsed reply as a proposal about `item`, with both gates' verdicts.
        func proposal(from parsed: QueueRefill.Draft) -> Proposal {
            var draft = parsed
            // The id and title are `item`'s, not whatever the model echoed back —
            // overriding is simpler than reconciling a mismatch, and it is what
            // keeps a proposal from ever landing on the wrong item: there is
            // nothing for a caller to compare against and get wrong.
            draft.id = item.id
            draft.title = item.title
            // And the repositories it spans: the model is not asked for them, and
            // a rewrite that dropped the line would make the item single-repository.
            draft.repos = repos

            var groomedItem = item
            groomedItem.verify = draft.verify
            groomedItem.size = ItemSize(rawValue: draft.size.uppercased())

            let readiness = DefinitionOfReady.evaluate(item: groomedItem, detail: draft.detail,
                                                       dependencies: dependencies)
            let grounding = GroundingCheck.evaluate(item: groomedItem, detail: draft.detail, sources: sources)
            return Proposal(itemID: item.id, draft: draft, readiness: readiness, grounding: grounding)
        }
    }

    /// The prompt for one correction round: `original`, the proposal the
    /// grounding check refused, and the check's `summary` of why, verbatim.
    static func correctionPrompt(original: String, refused: QueueRefill.Draft, summary: String) -> String {
        var proposal = "verify: \(refused.verify)\nSize: \(refused.size.uppercased())\n"
            + "\nWhat:\n\(refused.what)\n\nHow:\n\(refused.how)\n"
            + "\nValidation:\n" + refused.validation.map { "- \($0)" }.joined(separator: "\n")
        if !refused.outOfScope.isEmpty {
            proposal += "\n\nOut of Scope:\n" + refused.outOfScope.map { "- \($0)" }.joined(separator: "\n")
        }
        return GroomingCorrection.prompt(original: original, refused: proposal, summary: summary)
    }

    /// The one-shot's system prompt, appended after whatever persona and repo
    /// access the caller already composed (`RepoRead.contract(for:)`) — this is
    /// only what is specific to grooming, not the reading rules, which the
    /// caller states once for every Planner-style pass.
    static let personaPrompt = """
        You groom one draft backlog item into something an unattended worker \
        can run: a `verify:` command, a size, and a detail with What, How, \
        Validation and Out of Scope. Respond with JSON only — no prose, no \
        code fences.
        """

    static func buildPrompt(item: BacklogItem, detail: BacklogItemDetail?, backlog: BacklogFile) -> String {
        var current = "Item id: \(item.id)\nTitle: \(item.title)\n"
        if let verify = item.verify, !verify.isEmpty { current += "Current verify: \(verify)\n" }
        if let size = item.size { current += "Current size: \(size.rawValue)\n" }
        current += existingDetailSection(detail)

        return """
        Groom this draft backlog item for the "\(backlog.project)" project, so an unattended \
        worker could pick it up. Read the repository first — a `verify:` that names a path or \
        an executable nothing in the repo has will be refused before anyone runs it. Propose a \
        `verify:` that actually runs from the project root, a size (XS, S or M — autopilot \
        cannot pick up L or XL), and a detail with What, How, Validation and Out of Scope.

        \(current)
        Return ONLY JSON, no prose, no code fences, in this shape:
        {"items": [{"id": "\(item.id)", "title": "\(item.title)", "size": "M",
                    "verify": "cd … && …", "what": "…", "how": "…",
                    "validation": ["…", "…"], "outOfScope": ["…"]}]}
        """
    }

    /// The "Existing …" block `buildPrompt` folds into the prompt for a
    /// re-groom — empty for a draft with no detail file yet.
    private static func existingDetailSection(_ detail: BacklogItemDetail?) -> String {
        guard let detail else { return "" }
        var section = ""
        if let what = detail.what, !what.isEmpty { section += "\nExisting What:\n\(what)\n" }
        if let approach = detail.approach, !approach.isEmpty {
            section += "\nExisting How:\n\(approach)\n"
        }
        if !detail.acceptanceCriteria.isEmpty {
            section += "\nExisting Validation:\n"
                + detail.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !detail.outOfScope.isEmpty {
            section += "\nExisting Out of Scope:\n"
                + detail.outOfScope.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !detail.premise.isEmpty {
            section += "\nExisting Premise:\n"
                + detail.premise.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return section
    }
}
