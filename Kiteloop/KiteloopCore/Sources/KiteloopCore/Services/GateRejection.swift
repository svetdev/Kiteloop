import Foundation

/// A person's own verdict at the approval gate — the one rejection in the
/// system that used to go nowhere. A reviewer's blocking findings already
/// reach the next worker pass, in the run still in flight
/// (`ReviewFindings.feedbackKey`), and a check-fix round carries its own
/// failure forward the same way. A human rejecting a finished run had no such
/// channel: the reason landed in the item's `## Notes` and stayed there,
/// unread by the next run's worker or reviewer, both of which start from a
/// freshly deleted branch (`WorktreeSession.startRefusal`) with no memory of
/// what a person already found wrong.
///
/// This is that channel. Recorded here, a rejection is read back at the next
/// pickup and opens both the worker's and the reviewer's prompt, verbatim,
/// until a run of the item passes review. The quality judge's blocking
/// verdict once travelled the same channel, under its own heading: see
/// `Kind.judgeBlocked`.
///
/// Project-local, JSONL-backed at `<project>/.kiteloop/gate-rejections.jsonl`
/// — the same neighbourhood and shape as `FindingOverrideLedger`. "Is this
/// item's rejection still outstanding" is answered by reading the log back
/// (`outstanding`) rather than trusting a mutable flag some path forgot to
/// clear: the same reasoning `RetryCeiling` is built on.
package enum GateRejection {

    /// One entry in the log — a rejection, or the review pass that answers it.
    package enum Kind: String, Codable, Sendable {
        case rejected
        /// The quality judge's own blocking verdict — no longer written, since
        /// the judge scores a run and never blocks one, and kept so an entry
        /// already on disk still reads. Reached only after a run's review already
        /// passed, so it is never a reviewer's own rejection wearing a
        /// different name. Recorded and read back the same way `.rejected`
        /// is: `outstanding` and `promptBlock` treat the two alike, and a
        /// `.cleared` entry answers either.
        case judgeBlocked
        case cleared
    }

    package struct Record: Codable, Sendable, Equatable {
        package let itemID: String
        package let kind: Kind
        /// The reason, verbatim. Set for `.rejected` and `.judgeBlocked`; nil
        /// for `.cleared`.
        package let reason: String?
        /// The ref the rejected run's branch tip was tagged at
        /// (`WorktreeManager.markRejected`) — nil when the item never ran
        /// isolated and so had no branch to preserve, and always nil for
        /// `.cleared`.
        package let ref: String?
        package let at: Date

        package init(itemID: String, kind: Kind, reason: String?, ref: String?, at: Date) {
            self.itemID = itemID
            self.kind = kind
            self.reason = reason
            self.ref = ref
            self.at = at
        }
    }

    /// The ref name a rejected item's branch tip is tagged at — outside
    /// `refs/heads/`, so the next pickup's unconditional `git branch -D`
    /// (`WorktreeSession.startRefusal`, via `WorktreeManager.removeWorktree
    /// (keepBranch: false)`) never touches it.
    package static func ref(itemID: String) -> String {
        "refs/kiteloop/rejected/\(itemID)"
    }

    /// Where a project's rejection log lives.
    package static func url(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appending(path: ".kiteloop")
            .appending(path: "gate-rejections.jsonl")
    }

    /// Appends one entry, making the `.kiteloop` directory on a project's
    /// first one — through `AtomicFileWriter`, so a kill mid-append costs at
    /// most this line rather than corrupting the log.
    package static func append(_ record: Record, to url: URL) {
        guard let line = encode(record) else { return }
        try? AtomicFileWriter.append(Data(line.utf8), to: url)
    }

    /// Every entry on record, oldest first — empty for a project that has
    /// never rejected this item, or any item, and empty for a missing file.
    /// Read through `AtomicFileWriter.loadLines`, the read side of the
    /// `append` above: the bytes are split on the newline and each line is
    /// decoded on its own, so a line that fails to decode costs only itself
    /// and every complete record before it is still read back. That includes
    /// the truncation `append` is written to survive — a kill part-way through
    /// a multi-byte character leaves a last line that is not valid UTF-8, and
    /// reading the file as one string used to lose the whole log to it. A
    /// blank line contributes no entry and is not an error.
    package static func read(from url: URL) -> [Record] {
        AtomicFileWriter.loadLines(from: url, as: Record.self)
    }

    /// The item's outstanding rejection — the most recent entry on record for
    /// it, if that entry is a `.rejected` or `.judgeBlocked` no later
    /// `.cleared` has answered. Nil for an item that was never rejected or
    /// judge-blocked, and nil again from the run after the one that gets it
    /// past review.
    package static func outstanding(itemID: String, entries: [Record]) -> Record? {
        guard let last = entries.last(where: { $0.itemID == itemID }),
              last.kind == .rejected || last.kind == .judgeBlocked else {
            return nil
        }
        return last
    }

    /// The heading and opening sentence `promptBlock` renders for each kind
    /// worth showing — nil for `.cleared`, which never reaches a prompt.
    private static func headingAndIntro(for kind: Kind) -> (heading: String, intro: String)? {
        switch kind {
        case .rejected:
            return ("## Rejected last time",
                    "A person rejected the previous run of this item, for this reason — read it before doing anything else:")
        case .judgeBlocked:
            return ("## Blocked by the quality judge last time",
                    "The quality judge blocked the previous run of this item, for this reason — read it before doing anything else:")
        case .cleared:
            return nil
        }
    }

    /// The text both the worker and the reviewer prompts carry — the same
    /// text on both, by construction, rather than two wordings a later edit
    /// could drift apart. Nil for a `.cleared` record, or one with no reason
    /// to show.
    package static func promptBlock(_ record: Record) -> String? {
        guard let (heading, intro) = headingAndIntro(for: record.kind),
              let reason = record.reason,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let refLine = record.ref.map { ref in
            "\n\nThe previous run's branch tip is kept at `\(ref)` — worth a look before rebuilding "
            + "from nothing; `git cherry-pick` pulls over anything there worth keeping (tests, in particular)."
        } ?? ""
        return """
            \(heading)
            \(intro)

            \(reason)\(refLine)
            """
    }

    private static func encode(_ record: Record) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return line + "\n"
    }
}
