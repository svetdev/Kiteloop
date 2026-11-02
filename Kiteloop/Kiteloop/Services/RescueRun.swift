import Foundation
import KiteloopCore

/// Whether a merge-gate exclusion — `GateRetry.classify` giving up on a content
/// conflict or a red merged-tree verify — is worth spending one capped,
/// measured agent run on before the item is left for a human.
///
/// `GateRetry` already tried everything mechanical: a rebase onto the moved
/// base, and (for a conflict) a ceiling of retries. What is left, once it
/// excludes an item, is exactly what an operator does by hand today — hand the
/// rejection reason to an agent in a fresh worktree and ask it to integrate.
/// This type decides only whether that is worth doing *again* for this item;
/// `BacklogAutopilot`'s rescue extension is the half that gathers `Signals`,
/// prepares the worktree, runs the agent and records what happened.
///
/// Everything here is a value: no git, no agent, no clock beyond what it is
/// handed. Two properties are load-bearing:
///
/// * **A rescue is unattended work**, and nothing may start it without the
///   project's own consent to unattended work — `autonomousWorkEnabled` is
///   consulted here, not left to the caller, so a rescue can never be spawned
///   by an app that has been told this project's queue is a human's to drive.
/// * **One rescue per item, ever**, tracked in `Ledger` rather than reset each
///   pass: a rescue that failed already said what a human needs to know, and a
///   second one on the same exclusion would spend without new ground to try.
enum RescueRun {

    // MARK: - Signals

    /// What is known about one item a gate exclusion could be rescued from.
    struct Signals: Sendable, Equatable {
        let itemID: String
        /// The project's consent to unattended work — see the type comment.
        let autonomousWorkEnabled: Bool
        /// Whether this loop has ever rescued this item before, read from
        /// `Ledger`. Lifetime, not per pass or per exclusion.
        let alreadyRescued: Bool

        init(itemID: String, autonomousWorkEnabled: Bool, alreadyRescued: Bool) {
            self.itemID = itemID
            self.autonomousWorkEnabled = autonomousWorkEnabled
            self.alreadyRescued = alreadyRescued
        }
    }

    // MARK: - Disposition

    enum Disposition: Sendable, Equatable {
        /// Worth one capped agent run.
        case spawn
        /// Not worth it, and why — written to the item's `## Notes` alongside
        /// the exclusion itself rather than raising it to its own sentence:
        /// the exclusion is the news, this is only the reason nothing further
        /// was tried.
        case skip(reason: String)
    }

    /// Read one item's exclusion into a disposition.
    ///
    /// Consent is asked first: an item with no rescue on record yet is still
    /// refused outright when the project has not agreed to unattended work,
    /// rather than being told it only has one rescue left it will never spend.
    static func classify(_ signals: Signals) -> Disposition {
        guard signals.autonomousWorkEnabled else {
            return .skip(reason: "autonomous work is off for this project — a rescue is unattended "
                        + "work, and nothing here may start it without that consent")
        }
        guard !signals.alreadyRescued else {
            return .skip(reason: "already spent this item's one rescue — a second attempt on the "
                        + "same exclusion would spend without new ground to try")
        }
        return .spawn
    }

    // MARK: - Outcome vocabulary

    /// The outcome `TaskMetricStore` records for a rescue that resolved the
    /// exclusion and landed on the base — distinguishable from an ordinary
    /// `done`/`awaiting-approval` run so a human rescue and a machine one
    /// never share a bucket in the success metrics.
    static let rescuedOutcome = "rescued"

    /// The reason half of `blocked:<reason>` for a rescue that did not land —
    /// the review never passed, or it did and the merge still failed. Follows
    /// the same `blocked:<reason>` shape every other refusal uses, so nothing
    /// downstream that reads the `blocked` prefix has to special-case it,
    /// while the reason itself says this was a rescue, not an ordinary run.
    static let rescueFailedReason = "rescue-failed"
    static var rescueFailedOutcome: String { "blocked:\(rescueFailedReason)" }

    // MARK: - Ledger

    /// Whether an item has ever been rescued — the one fact `classify` needs
    /// that a single pass cannot know on its own.
    ///
    /// Append-only JSONL beside `GateRetry.Ledger` and `BlockedTriage.Ledger`,
    /// for the same reason: the count has to survive a relaunch, or "one
    /// rescue per item" would reset every time the app restarted.
    struct Ledger: Sendable, Equatable {
        private(set) var entries: [Entry]

        struct Entry: Codable, Sendable, Equatable {
            let at: Date
            let project: String
            let itemID: String
            /// `"rescued"` or `"failed"` — what the rescue run itself ended as.
            let outcome: String
            let reason: String
        }

        init(entries: [Entry] = []) {
            self.entries = entries
        }

        /// Whether this project has ever rescued this item — landed or not:
        /// a failed rescue still spent the one attempt `classify` allows.
        /// Canonicalised on both sides, so an entry recorded under the
        /// folder's other spelling still counts against the one-rescue cap —
        /// see `GateRetry.Ledger.attempts`.
        func hasRescued(project key: String, itemID: String) -> Bool {
            let canonical = KiteloopProject.canonicalPath(key)
            return entries.contains {
                KiteloopProject.canonicalPath($0.project) == canonical && $0.itemID == itemID
            }
        }

        mutating func record(project: String, itemID: String, outcome: String, reason: String, at: Date = Date()) {
            entries.append(Entry(at: at, project: project, itemID: itemID, outcome: outcome, reason: reason))
        }

        // MARK: Persistence

        static func defaultURL(home: URL = KiteloopHome.url) -> URL {
            home.appending(path: ".kiteloop").appending(path: "rescue-run.jsonl")
        }

        static func load(from url: URL) -> Ledger {
            Ledger(entries: AtomicFileWriter.loadLines(from: url, as: Entry.self))
        }

        static func append(_ entry: Entry, to url: URL) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entry),
                  let line = String(data: data, encoding: .utf8) else { return }
            try? AtomicFileWriter.append(Data((line + "\n").utf8), to: url)
        }
    }
}
