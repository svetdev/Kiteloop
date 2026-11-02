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

    /// Runs one agent pass over `item` and checks what it proposes against the
    /// repo. Throws rather than returning a proposal there is no reason to
    /// preview: an empty reply or a reply with nothing `QueueRefill.Draft.parse`
    /// can use is not something to show for approval.
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
        let response = try await runOneShot(buildPrompt(item: item, detail: detail, backlog: backlog))
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GroomError.emptyResponse
        }
        guard var draft = QueueRefill.Draft.parse(response).first else {
            throw GroomError.noDraft
        }
        // The id and title are `item`'s, not whatever the model echoed back —
        // overriding is simpler than reconciling a mismatch, and it is what
        // keeps a proposal from ever landing on the wrong item: there is
        // nothing for a caller to compare against and get wrong.
        draft.id = item.id
        draft.title = item.title

        var groomedItem = item
        groomedItem.verify = draft.verify
        groomedItem.size = ItemSize(rawValue: draft.size.uppercased())

        let dependencies = DefinitionOfReady.Dependencies(file: backlog)
        let readiness = DefinitionOfReady.evaluate(item: groomedItem, detail: draft.detail,
                                                   dependencies: dependencies)
        let grounding = GroundingCheck.evaluate(item: groomedItem, detail: draft.detail, sources: sources)
        return Proposal(itemID: item.id, draft: draft, readiness: readiness, grounding: grounding)
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
