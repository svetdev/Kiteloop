import Foundation

/// Whether an item may be marked done on a person's word — built and merged
/// by hand, outside any run — and what its Notes say when it is.
///
/// `POST /v1/backlog/groom` moves an item between `draft` and `ready` and
/// `POST /v1/backlog/approve` resolves one at its gate, so work merged by
/// hand left its item reading `draft` or `blocked` until a run was spent
/// confirming it. `"builtOutsideARun": true` on the approve call is the
/// person saying the work is in: it merges nothing and runs no verify, so
/// what it asks for instead is a reason, kept in the item's Notes.
///
/// It works from `draft`, `ready` or `blocked` only. An item a run holds —
/// `active`, `in-review` — or one at its gate has its own way to `done`, and
/// stamping over it would end a run's item underneath it. An item whose
/// branch carries commits the base does not hold is refused too: that work
/// is not merged, which is the one thing this call asserts.
package enum DoneOutsideARun {

    /// The body field that asks for this on `POST /v1/backlog/approve`.
    package static let field = "builtOutsideARun"

    /// What the response says was — and was not — done.
    package static let detail = "Marked done on your word that the work was built outside a run: "
        + "nothing was merged and no verify ran."

    package enum Verdict: Equatable, Sendable {
        /// The item may be marked done; `note` is the line for its Notes.
        case allowed(note: String)
        /// It may not, with the HTTP status and the words to answer with.
        case refused(status: Int, reason: String)
    }

    /// - Parameters:
    ///   - approve: the body's `approve`, when it sent one.
    ///   - unmergedBranch: the item's branch, when it has commits the base
    ///     branch does not hold; nil when there is no such branch.
    package static func decide(itemID: String, status: BacklogItemStatus, approve: Bool?, reason: String?,
                               unmergedBranch: String?) -> Verdict {
        if approve == false {
            return .refused(status: 400, reason: "\"\(field)\" marks an item done, so it cannot be sent "
                            + "with \"approve\": false")
        }
        let why = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else {
            return .refused(status: 400, reason: "\"\(field)\" needs a \"reason\" — how the work was built "
                            + "and where it landed; it is written to the item's Notes")
        }
        if let refusal = statusRefusal(itemID: itemID, status: status) {
            return .refused(status: 409, reason: refusal)
        }
        if let unmergedBranch {
            return .refused(status: 409, reason: "Item '\(itemID)' has work that is not merged: branch "
                            + "\(unmergedBranch) has commits the base branch does not hold. Merge or delete "
                            + "that branch first — marking an item done merges nothing")
        }
        return .allowed(note: "marked done by hand, built outside a run: \(why)")
    }

    /// Why an item in `status` is not this call's to mark done, or nil from
    /// `draft`, `ready` and `blocked`. Exhaustive, so a new status has to say
    /// which side it is on.
    static func statusRefusal(itemID: String, status: BacklogItemStatus) -> String? {
        let held = "Item '\(itemID)' is \(status.rawValue)"
        switch status {
        case .draft, .ready, .blocked:
            return nil
        case .active, .inReview:
            return "\(held) — a run holds it. Cancel the run with POST /v1/runs/{runId}/cancel, "
                + "or let it finish, before marking the item done"
        case .awaitingApproval:
            return "\(held) — it is at its gate. Approve or reject it there: "
                + "send this call without \"\(field)\""
        case .done:
            return "\(held) already"
        }
    }
}
