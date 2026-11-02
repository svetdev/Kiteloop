import Foundation
import KiteloopCore

/// The gate's retry half: whenever the project's base advances, a parked
/// merge failure is not necessarily final — a conflict a sibling's landing
/// caused can clear itself once this branch is rebased onto the new base,
/// which `WorktreeManager.mergeAndVerify` already tries on its own. This type
/// decides, from what is already on record, which item at `awaiting-approval`
/// is worth spending another merge attempt on.
///
/// Everything here is a value: no git, no backlog, no clock beyond what it is
/// handed. `BacklogAutopilot.retryGateMerges` is the half that observes and
/// applies — it gathers `Signals` from `TaskMetricStore`'s merge log and this
/// type's own `Ledger`, and only it ever calls `resolveGate`.
///
/// One property is load-bearing, for the same reason it is in `BlockedTriage`:
/// **a red verify is not retried.** A merge conflict or a base race says
/// nothing about the work — the tree it would have landed on moved, not the
/// diff — so trying again after that tree moves further is free ground. A
/// failing `verify:` on the merged tree says the work itself is wrong, and
/// running the same command again changes nothing about it; retrying it would
/// only spend the ceiling's attempts on an item that needs a person or a fix.
enum GateRetry {

    // MARK: - Signals

    /// What is known about one item sitting at the gate.
    struct Signals: Sendable, Equatable {
        let itemID: String
        /// The most recent merge attempt on record for this item — nil when
        /// none is, which reads as "never attempted" rather than as a
        /// failure. Read from `TaskMetricStore.mergeEvents`, which every
        /// merge attempt appends to whichever path made it: the run's own
        /// auto-merge, a human's `resolveGate`, or this loop's own retry.
        let lastAttempt: Attempt?
        /// How many times *this loop* has retried the item, read from
        /// `Ledger`. Lifetime, not per pass — a relaunch must not hand a
        /// fresh allowance to an item that already spent its ceiling.
        let attemptsByThisLoop: Int

        init(itemID: String, lastAttempt: Attempt? = nil, attemptsByThisLoop: Int = 0) {
            self.itemID = itemID
            self.lastAttempt = lastAttempt
            self.attemptsByThisLoop = attemptsByThisLoop
        }
    }

    /// One merge attempt, as `ItemMergeEvent` already holds it.
    struct Attempt: Sendable, Equatable {
        let merged: Bool
        let reason: String?
    }

    // MARK: - What went wrong

    /// The class of a failed attempt's reason — the whole retry/exclude
    /// boundary. See the type comment for why only one of these is
    /// re-runnable.
    enum Failure: Equatable, Sendable {
        /// A content conflict, or a race the base moving caused (a
        /// fast-forward or a compare-and-swap that lost) — see
        /// `WorktreeManager.conflictRefusal`, `.fastForwardCheckout` and
        /// `.updateBaseRef`. Retrying is exactly what a moved base can fix.
        case conflictOrRace
        /// The merged tree's own verify failed — see
        /// `WorktreeManager.verifyRefusal`. The work is what is wrong, not
        /// the base it landed on.
        case verifyRed
        /// Some other refusal (a dirty project checkout, no worktree, an
        /// unreadable repo) — not what this loop exists to recover from.
        case other

        var phrase: String {
            switch self {
            case .conflictOrRace: return "a merge conflict or a base race"
            case .verifyRed: return "the merged tree's own verify failing"
            case .other: return "a refusal outside a merge conflict or a base race"
            }
        }
    }

    /// Reads one recorded reason as a failure class.
    ///
    /// The conflict/race markers are asked first, and verify is read by the
    /// phrase `WorktreeManager.verifyRefusal` actually produces — both its
    /// spellings ("verify failed on merged tree (…)" and "verify timed out
    /// after Ns on merged tree (…)") end in "on merged tree" — rather than the
    /// bare word "verify". `WorktreeManager.conflictRefusal` names the
    /// conflicting paths in the reason it returns, and a path can itself
    /// contain "verify" (`Services/VerifyCoverage.swift`, `MergeVerifyPlan.swift`,
    /// `scripts/kiteloop-verify.py`), which the bare word would have misread
    /// as the one class this loop must never retry. An empty or missing
    /// reason answers `.other` — there is nothing here to read as a conflict.
    static func failure(of reason: String?) -> Failure {
        let text = (reason ?? "").lowercased()
        guard !text.isEmpty else { return .other }
        if text.contains("merge conflict") || text.contains("fast-forward")
            || text.contains("its tip moved") { return .conflictOrRace }
        if text.contains("on merged tree") { return .verifyRed }
        return .other
    }

    // MARK: - Policy

    struct Policy: Sendable, Equatable {
        /// How many times this loop may retry one item before it escalates to
        /// a human instead. Lifetime, per `Ledger` — see `Signals`.
        var maxAttempts: Int

        init(maxAttempts: Int = 3) { self.maxAttempts = maxAttempts }

        static let `default` = Policy()

        /// A negative ceiling reads as "never retry" rather than as an error.
        var sanitized: Policy { Policy(maxAttempts: max(0, maxAttempts)) }
    }

    // MARK: - Disposition

    enum Disposition: Sendable, Equatable {
        /// Worth another `resolveGate(approve: true, …)`.
        case retry
        /// Nothing to act on **yet**, and nothing to say about it: either no
        /// merge has ever been attempted for this item (it may still get one,
        /// from this run's own first attempt or a later trigger), or its last
        /// attempt landed. Silent and unrecorded — a `## Notes` line here
        /// would be noise on every item that simply hasn't failed, and
        /// recording it in `Ledger` would read as a permanent, terminal
        /// verdict on an item that was never actually judged.
        case skip
        /// Terminal: this loop will not retry the item again. `reason` is
        /// what the item's `## Notes` line says, and what `Ledger` records so
        /// the exclusion is said once, not on every later trigger.
        case exclude(reason: String)
    }

    struct Verdict: Sendable, Equatable, Identifiable {
        let itemID: String
        let disposition: Disposition
        var id: String { itemID }
    }

    /// Read one item's record into a disposition.
    ///
    /// The order of the gates is the point, the same way it is in
    /// `BlockedTriage.classify`:
    ///   1. **No failed attempt on record** — `.skip`, not `.exclude`: an
    ///      item can reach here before its own first merge was ever
    ///      attempted (the trigger this loop rides also fires the moment an
    ///      item reaches the gate, ahead of that item's own auto-merge), and
    ///      reading "hasn't failed yet" as a permanent exclusion would shut
    ///      every item out before it had a real failure to retry from — the
    ///      defect an earlier version of this loop shipped with. Also covers
    ///      an item whose last attempt landed.
    ///   2. **The failure class** — only a conflict or a base race is
    ///      re-runnable. A red verify is `.exclude`d here, permanently, since
    ///      the work itself is what is wrong and no retry fixes that. Any
    ///      other refusal (a dirty checkout, an unreadable repo) is `.skip`,
    ///      not `.exclude` — it may well clear up on its own by the next
    ///      trigger, and nothing here knows that it won't.
    ///   3. **The lifetime ceiling** — checked last because it only ever
    ///      bounds a retry, and only a retry-eligible failure gets this far.
    static func classify(_ signals: Signals, policy: Policy = .default) -> Verdict {
        let sane = policy.sanitized

        guard let last = signals.lastAttempt, !last.merged else {
            return Verdict(itemID: signals.itemID, disposition: .skip)
        }

        let cause = failure(of: last.reason)
        guard cause != .other else {
            return Verdict(itemID: signals.itemID, disposition: .skip)
        }
        guard cause == .conflictOrRace else {
            return Verdict(itemID: signals.itemID, disposition: .exclude(reason:
                "excluded from the gate's automatic retry: the last merge attempt failed on "
                + "\(cause.phrase), which another attempt cannot fix — \(last.reason ?? cause.phrase)"))
        }

        guard signals.attemptsByThisLoop < sane.maxAttempts else {
            return Verdict(itemID: signals.itemID, disposition: .exclude(reason:
                "excluded from the gate's automatic retry: retried \(signals.attemptsByThisLoop) time(s) "
                + "without landing, at the ceiling of \(sane.maxAttempts) — last attempt: "
                + (last.reason ?? cause.phrase)))
        }

        return Verdict(itemID: signals.itemID, disposition: .retry)
    }

    // MARK: - Ledger

    /// What this loop has already decided about each item — and, load-bearing,
    /// how many times each one has been retried **ever**.
    ///
    /// Append-only JSONL, following `BlockedTriage.Ledger`: the count has to
    /// survive a relaunch, or the ceiling would reset every time the app
    /// started and the loop would retry the same doomed merge forever.
    struct Ledger: Sendable, Equatable {
        private(set) var entries: [Entry]

        struct Entry: Codable, Sendable, Equatable {
            let at: Date
            let project: String
            let itemID: String
            /// `retry` for an attempt this loop made (landed or not),
            /// `excluded` for a disposition that stopped without one.
            let disposition: String
            let reason: String

            static let retryDisposition = "retry"
            static let excludedDisposition = "excluded"
        }

        init(entries: [Entry] = []) {
            self.entries = entries
        }

        /// How many merge attempts this loop has ever made for the item —
        /// landed or not; a landed one still counts, since it is still one
        /// attempt spent. Canonicalised on both sides, the way every other
        /// reader of a project-keyed ledger is (`TaskMetricStore.latestApproval`,
        /// `EscapedDefectReader.read`): an entry recorded under the folder's
        /// other spelling still counts against the same ceiling.
        func attempts(project key: String, itemID: String) -> Int {
            let canonical = KiteloopProject.canonicalPath(key)
            return entries.filter {
                KiteloopProject.canonicalPath($0.project) == canonical
                    && $0.itemID == itemID && $0.disposition == Entry.retryDisposition
            }.count
        }

        /// Whether this loop has already excluded the item and said so — the
        /// dedup that keeps a permanently-excluded item from getting a fresh
        /// `## Notes` line on every trigger.
        func isExcluded(project key: String, itemID: String) -> Bool {
            let canonical = KiteloopProject.canonicalPath(key)
            return entries.contains {
                KiteloopProject.canonicalPath($0.project) == canonical
                    && $0.itemID == itemID && $0.disposition == Entry.excludedDisposition
            }
        }

        /// `disposition` is one of `Entry.retryDisposition` or
        /// `Entry.excludedDisposition` — a raw string, the way
        /// `BlockedTriage.Ledger.record` also takes one, so one call covers
        /// both cases the caller already builds the matching `Entry` for
        /// when it also appends to disk.
        mutating func record(project: String, itemID: String, disposition: String,
                             reason: String, at: Date = Date()) {
            entries.append(Entry(at: at, project: project, itemID: itemID,
                                 disposition: disposition, reason: reason))
        }

        // MARK: Persistence

        static func defaultURL(home: URL = KiteloopHome.url) -> URL {
            home.appending(path: ".kiteloop").appending(path: "gate-retry.jsonl")
        }

        /// Reads what's there, through `AtomicFileWriter.loadLines` — the read
        /// side of the same append-only JSONL shape `BlockedTriage.Ledger` and
        /// `QueueRefill.Ledger` also keep. A corrupt line is skipped rather
        /// than failing the load: a half-written record must not reset every
        /// item's attempt count.
        static func load(from url: URL) -> Ledger {
            Ledger(entries: AtomicFileWriter.loadLines(from: url, as: Entry.self))
        }

        static func append(_ entry: Entry, to url: URL) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entry),
                  let line = String(data: data, encoding: .utf8) else { return }
            // Through `AtomicFileWriter.append`, which makes the directory
            // when it is missing and starts a new line first when the ledger
            // doesn't end in one — see `BlockedTriage.Ledger.append` for why
            // a plain seek-to-end is not safe here either.
            try? AtomicFileWriter.append(Data((line + "\n").utf8), to: url)
        }
    }
}
