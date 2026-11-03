import CryptoKit
import Foundation
import KiteloopCore

/// How many times an item that produces nothing may be attempted — **ever**, not
/// per run.
///
/// Two correct behaviours compose into an unbounded retry loop. A run that
/// produced nothing returns its item to `ready`, which is right: nothing was
/// attempted on its merits, so the run is not a verdict on the work. And
/// `BacklogAutopilot.consecutiveNoWorkBlocks` stops a run after a few consecutive
/// empty items, which is also right. But that counter is an instance variable
/// reset at the start of every run, so a driver that starts a fresh run per item
/// resets the breaker every time and it never trips. On 2026-08-08
/// `control-openapi` was started **231 times**, 228 of them producing nothing,
/// and the only reason it cost nothing is that the sessions were dead and dead
/// sessions bill nothing. With healthy sessions the same loop spends real money
/// as fast as runs can start.
///
/// The ceiling that was missing is this one: a bound on the item, across runs.
///
/// **Counted from recorded history, not from memory.** Every attempt is already
/// on record — `TaskMetricRecord.itemID` names the item and `producedWork` says
/// whether it left anything behind — so the count survives an app restart, a new
/// driver process and a fresh run, which is precisely where the loop lives. An
/// in-memory counter cannot do that, which is how the existing one was defeated.
///
/// **Only no-work attempts count.** An item rejected on review has been attempted
/// on its merits and may be reworked; conflating the two would retire items that
/// are merely hard. A run that produced work clears the count outright, so an
/// item that delivered and was later reopened starts fresh.
///
/// **It takes evidence of work to clear the count, not the absence of evidence
/// of emptiness.** A stalled run used to clear it: nothing had measured what it
/// left, and `producedWork` read every outcome it didn't recognise as
/// productive. On 2026-08-08 travel's `test-useplanpolling` went empty, empty,
/// stalled — and the stall reset the streak to zero, so a fourth run started. A
/// run the ledger cannot vouch for is counted, not forgiven; the cost of being
/// wrong that way is one attempt, and the cost of the other way is unbounded.
///
/// **A ceiling with no release is a life sentence.** Retirement stops autopilot
/// from starting the item, so a retired item cannot produce work, so a rule that
/// only cleared on produced work could never clear — the note told a human to
/// re-groom the item and re-grooming it changed nothing. The only way out was to
/// rename the item, which buys a fresh id by severing the history the ceiling is
/// counted from. So two releases, both of them deliberate acts and neither of
/// them a timer:
///
/// - **The item was rewritten.** Every attempt records the fingerprint of the
///   spec it was made against (`TaskMetricRecord.specFingerprint`), and an
///   attempt made against a different spec is not evidence about *this* item. Re-
///   groom the What/How/Validation and the old attempts stop counting, which is
///   exactly what the note asks for.
/// - **A human said so.** `GroomingLedger` records the release, and attempts that
///   finished before it don't count.
///
/// Neither raises the ceiling: after a release the item gets `limit` attempts,
/// and three more empty ones retire it again.
///
/// Pure, like `RunEconomics` and `DefinitionOfReady`: it takes the ledger as a
/// value, so the whole rule is exercised without an app, a run or a repo.
enum RetryCeiling {

    /// No-work attempts an item gets before autopilot stops starting it.
    ///
    /// Small on purpose, and the same number as
    /// `BacklogAutopilot.noWorkBlockLimit` for the same reason: two attempts is
    /// enough to tell "that session had died" from "starting this item does not
    /// produce anything", and every attempt past that is spend buying nothing.
    /// Deliberately not configurable — a knob on a runaway-spend guard is a knob
    /// for turning the guard off.
    static let limit = 3

    /// Why some of an item's recorded attempts were not counted.
    ///
    /// Kept on the verdict rather than left implicit, because the question a
    /// release has to be able to answer afterwards is "why did this item run
    /// again" — and "it just did" is the answer the previous, timer-free-but
    /// also release-free design would have had to give.
    struct Release: Equatable, Sendable {
        /// When a human released it, if one did.
        var humanAt: Date?
        /// Whether attempts were discounted for having been made against a
        /// different version of the item's spec.
        var rewritten: Bool = false
        /// No-work attempts these discounted — the whole point of the release,
        /// and zero means nothing was released at all.
        var discountedAttempts: Int = 0

        /// One line naming the release, for the run log and the item's Notes.
        var explanation: String {
            let attempts = "\(discountedAttempts) earlier no-work attempt"
                + (discountedAttempts == 1 ? "" : "s")
            switch (humanAt, rewritten) {
            case (.some, true):
                return "released (rewritten, and released by hand) — \(attempts) no longer count"
            case (.some, false):
                return "released by hand — \(attempts) no longer count"
            default:
                return "released: the item has been rewritten since — \(attempts) no longer count"
            }
        }

        /// The release as a single log field, so a run stream can be grepped for
        /// how an item came back.
        var logValue: String {
            switch (humanAt, rewritten) {
            case (.some, true): return "human+rewritten"
            case (.some, false): return "human"
            default: return "rewritten"
            }
        }
    }

    /// What the history says about one item, at pickup.
    struct Verdict: Equatable, Sendable {
        /// No-work attempts since the last one that produced anything, counting
        /// only attempts a release hasn't discounted.
        let noWorkAttempts: Int
        /// The ceiling they are measured against — carried so every phrasing
        /// below states the rule rather than assuming the reader knows it.
        let limit: Int
        /// What was discounted, and why. Nil when nothing was — which is every
        /// item that has never been released or rewritten.
        var release: Release?

        /// Whether autopilot refuses to start the item.
        var isRetired: Bool { noWorkAttempts >= limit }

        /// The whole verdict on one line — what the skip log quotes and what the
        /// control API hands back as the 422 body.
        ///
        /// "Started" is load-bearing: a pickup refusal — the grounding check or
        /// `DefinitionOfReady` turning the item away before a run ever begins —
        /// sends the item to `draft` with the refusal as its reason instead of
        /// counting here, so every attempt this counts is one that actually ran
        /// and still came back empty.
        var summary: String {
            "retired: \(noWorkAttempts) attempt\(noWorkAttempts == 1 ? "" : "s") started and produced no work"
                + " (ceiling \(limit)) — re-groom it or release it before it runs again"
        }

        /// What goes in the item's `## Notes`, where a human will actually look.
        ///
        /// An item that quietly stops running is indistinguishable from one
        /// nobody has got to yet, so the file says what happened *and how to get
        /// out of it*. Both releases are named, because the note is the whole
        /// interface at the moment someone needs it: an instruction that only
        /// works if you already know the internals is the defect this replaced.
        /// Contains `noteMarker`, which is how the note is written once rather
        /// than on every pickup.
        var note: String {
            "\(RetryCeiling.noteMarker) — \(noWorkAttempts) attempts in a row started and produced no work"
                + " (ceiling \(limit)). Autopilot will not start it again until it is released,"
                + " and there are two ways to release it. **Re-groom it**: edit this item's"
                + " What / How / Validation, and the attempts made against the old wording stop"
                + " counting — a rewritten item is judged on its own attempts. Or **release it"
                + " as it stands**: \"Release for Autopilot\" in the item's ⋯ menu in the"
                + " backlog, or `POST /v1/backlog/release {\"project\": …, \"item\": …}`. Either"
                + " way the release is recorded in ~/.kiteloop/grooming.jsonl. Do not rename the"
                + " item to get it running — a new id starts with no history, including this."
                + " Three more attempts that produce nothing retire it again."
        }
    }

    /// What a release writes into the item's Notes, so the file says why the item
    /// started running again and not only that it did.
    static func releaseNote(source: String) -> String {
        "Released for autopilot (\(source)) — the retry ceiling's count starts fresh from here."
            + " Three attempts that produce no work will retire it again."
    }

    /// The phrase a written note is recognised by, so an item already retired
    /// isn't given the same note again every time it is selected.
    static let noteMarker = "Retired by the retry ceiling"

    /// Whether the retirement still has to be written to the item's Notes.
    ///
    /// A retired item is refused at *every* pickup, not once, so the note is
    /// keyed off what the file already says rather than off a run's memory —
    /// which is the same reason the count itself is. Nil notes (no `## Notes`
    /// section, or no detail file this app could read) means nothing is on
    /// record, so the note is written.
    static func needsNote(existingNotes: String?) -> Bool {
        !(existingNotes ?? "").contains(noteMarker)
    }

    /// Whether a record says nothing about the item either way — neither an
    /// attempt to be counted nor grounds to clear the streak — and so is
    /// skipped before either release is even considered.
    ///
    /// Four rows share this, each for its own reason spelled where the check
    /// used to live inline: a cancelled run was stopped before it could say
    /// anything about the item, by a human, a cost cap or a shutdown; a worker's
    /// evidenced claim that the item is already built is an answer *about* the
    /// item rather than an attempt *at* it, and counting it retired
    /// `wizard-hands-off-to-a-first-project` on 2026-08-21 for three workers
    /// each following CLAUDE.md's own instruction; a row this ceiling wrote
    /// itself, refusing to start an item it had already retired, is a
    /// consequence of the retirement rather than a fourth attempt at it — sixteen
    /// of them, on 2026-08-26, for three attempts that actually ran; and a
    /// grounding or readiness refusal sends the item back to `draft` with the
    /// refusal as its reason, so it is a citation waiting on an edit rather
    /// than an attempt that failed — before this, the same refused sentence
    /// retired three items with no run ever starting; and a run the account's
    /// usage limit stopped says nothing about the item at all.
    private static func isNotEvidence(_ record: TaskMetricRecord) -> Bool {
        record.outcome.hasPrefix("cancelled")
            || record.claimsAlreadyImplemented
            || record.isRetiredRefusal
            || record.isDraftedRefusal
            || record.isUsageLimitParked
    }

    /// Judges one item against its recorded history.
    ///
    /// - Parameters:
    ///   - itemID: the backlog id, as `TaskMetricRecord.itemID` holds it.
    ///   - projectPath: the project to scope to. Item ids are unique per project
    ///     and the ledger is portfolio-wide, so two projects sharing an id must
    ///     not accumulate each other's attempts. Nil counts every project.
    ///   - records: the run ledger, in the order it was written — appended at
    ///     completion, so file order is chronological, the same assumption
    ///     `TaskMetricStore.latestActual` reads on.
    ///   - releasedAt: when a human last released this item, from
    ///     `GroomingLedger.latestRelease`. Attempts that finished at or before it
    ///     are spent history and do not count. Nil = never released.
    ///   - specFingerprint: `specFingerprint(item:detail:)` for the item **as it
    ///     reads now**. Attempts recorded against a different fingerprint were
    ///     made against a different item and do not count. Nil — no detail file,
    ///     or a caller that can't be bothered to compute one — disables that
    ///     release rather than granting it: an unknown spec is not evidence of a
    ///     rewritten one.
    static func evaluate(itemID: String, projectPath: String?,
                         records: [TaskMetricRecord],
                         releasedAt: Date? = nil,
                         specFingerprint: String? = nil) -> Verdict {
        let canonical = projectPath.map(KiteloopProject.canonicalPath)
        var streak = 0
        var release = Release()
        for record in records {
            guard record.itemID == itemID else { continue }
            if let canonical, KiteloopProject.canonicalPath(record.projectPath) != canonical { continue }
            if isNotEvidence(record) { continue }

            // The two releases. Both *skip* the record rather than zeroing the
            // streak, so the rule doesn't depend on file order: an attempt a
            // release has discounted is not evidence about the item either way.
            if let releasedAt, record.completedAt <= releasedAt {
                release.humanAt = releasedAt
                if !record.producedWork { release.discountedAttempts += 1 }
                continue
            }
            // Only when both are known. A record written before fingerprints
            // existed says nothing about which wording it was attempted against,
            // and reading that silence as "rewritten" would release every item
            // in the old ledger at once.
            if let specFingerprint, let recorded = record.specFingerprint,
               recorded != specFingerprint {
                release.rewritten = true
                if !record.producedWork { release.discountedAttempts += 1 }
                continue
            }

            switch record.workEvidence {
            case .produced: streak = 0
            case .empty, .unknown: streak += 1
            }
        }
        // Reported only when it actually bought the item an attempt back. A
        // release that discounted nothing — released while already runnable,
        // rewritten after a run that delivered — is not why the item runs.
        return Verdict(noWorkAttempts: streak, limit: limit,
                       release: release.discountedAttempts > 0 ? release : nil)
    }

    /// No-work attempts since the item last produced something.
    ///
    /// A streak rather than a lifetime total, because "a successful attempt
    /// clears the count" is the difference between a ceiling and a retirement
    /// age: an item that delivered, was reopened and is being worked again has
    /// earned its attempts back.
    ///
    /// "Successful" means `WorkEvidence.produced` — the file count says the run
    /// left something, or the outcome is one that could only have been reached
    /// with a diff in hand. A run nobody measured counts like an empty one: it
    /// is the run the ceiling cannot see, and letting it clear the streak is how
    /// the loop this bounds stayed unbounded.
    static func noWorkAttempts(itemID: String, projectPath: String?,
                               records: [TaskMetricRecord],
                               releasedAt: Date? = nil,
                               specFingerprint: String? = nil) -> Int {
        evaluate(itemID: itemID, projectPath: projectPath, records: records,
                 releasedAt: releasedAt, specFingerprint: specFingerprint).noWorkAttempts
    }

    /// Every item's streak in one pass over the ledger, ignoring both releases.
    ///
    /// For a caller that needs to ask about a whole backlog at once — the UI
    /// marks retired items in a list — where the per-item form would re-scan and
    /// re-canonicalise the ledger once per row. Deliberately the *unreleased*
    /// count: it is a cheap first pass, and an item it flags is then judged in
    /// full, with its release date and its fingerprint. It can say "possibly
    /// retired", never "retired".
    static func noWorkAttemptsByItem(projectPath: String?,
                                     records: [TaskMetricRecord]) -> [String: Int] {
        let canonical = projectPath.map(KiteloopProject.canonicalPath)
        var streaks: [String: Int] = [:]
        for record in records {
            if let canonical, KiteloopProject.canonicalPath(record.projectPath) != canonical { continue }
            // Skipped here for the same reason `evaluate` skips it, via the same
            // predicate — this is what marks an item as possibly retired in a
            // list, and a row that does not count towards retirement must not
            // be what puts the mark there.
            if isNotEvidence(record) { continue }
            switch record.workEvidence {
            case .produced: streaks[record.itemID] = 0
            case .empty, .unknown: streaks[record.itemID, default: 0] += 1
            }
        }
        return streaks
    }

    // MARK: - The attempt that never started

    /// Which pickup gate turned the item away, as the record spells it.
    ///
    /// The ceiling counts attempts that leave nothing behind, and a refusal is
    /// one: the item was selected, it did not advance, and starting it again
    /// buys the same answer. Until a refusal was recorded only half the
    /// population was bounded — a run that spawned a session and produced an
    /// empty diff was counted, while an item the gate refused wrote no row at
    /// all. `memory-proposals-cannot-be-answered-headlessly` was selected and
    /// refused three times on 2026-08-21 with zero rows in `task-metrics.jsonl`;
    /// the reason existed each time, in prose, in a different ledger.
    ///
    /// One case per gate rather than one flag, because the clause is the fix:
    /// `not-grounded` is a citation to correct, `not-ready` a section to write,
    /// and reading either back must not mean re-parsing a sentence.
    enum PickupRefusal: String, CaseIterable, Sendable {
        /// The item's status is not one the project's flow picks up.
        case wrongStatus = "wrong-status"
        /// `DefinitionOfReady` refused it — for something about the item itself.
        /// See `refusal(for:)`: a `needs:` deferral is not this.
        case notReady = "not-ready"
        /// This ceiling refused it. Recorded so a retired item's re-selection
        /// stays visible in the ledger — but unlike the other clauses it is not
        /// counted: it is a consequence of the retirement, not evidence about
        /// the item, so it neither adds to the streak nor is lifted by a
        /// release. See `TaskMetricRecord.isRetiredRefusal`.
        case retired
        /// `GroundingCheck` refused it — the item cites something the repo does
        /// not have.
        case notGrounded = "not-grounded"

        /// The `TaskMetricRecord.outcome` the refusal is filed under.
        var outcome: String { TaskMetricRecord.didNotRunPrefix + rawValue }
    }

    /// Whether a Definition-of-Ready verdict is an attempt at the item or a
    /// deferral of it — nil when nothing here should be counted against it.
    ///
    /// Every clause of the gate but one describes how the item is *written*, and
    /// an item refused for one of those has failed to advance on its own
    /// account. `needs:` is the exception and must stay one: an item withheld
    /// because a prerequisite isn't `done` is the sequencing gate working
    /// exactly as designed, and counting that would retire items for the crime
    /// of being second in a chain — a queue built as a chain would retire its
    /// own tail before the head had shipped.
    ///
    /// An item failing *both* is still counted. It is refused for its own
    /// wording whether or not it is also waiting, and the deferral doesn't
    /// launder that.
    static func refusal(for verdict: DefinitionOfReady.Verdict) -> PickupRefusal? {
        verdict.unmet.contains { $0 != .dependency } ? .notReady : nil
    }

    /// The row a refusal writes, so the count comes off the same ledger as the
    /// runs it sits beside.
    ///
    /// Zero cost and zero duration, and both are measurements rather than
    /// placeholders: no session was spawned, so a refusal must move neither the
    /// day's spend nor the session's. `changedFileCount` is `0` for the same
    /// reason, which is also what makes `TaskMetricRecord.workEvidence` answer
    /// `.empty` from its primary path rather than falling through to guessing
    /// from the outcome string.
    ///
    /// `specFingerprint` is what makes the note's "re-groom it" mean something
    /// here too: a grounding or readiness refusal *is* fixed by editing the
    /// item, and an edit changes the fingerprint, so the refusals made against
    /// the old wording stop counting the moment the wording changes.
    static func refusalRecord(item: BacklogItem,
                              refusal: PickupRefusal,
                              projectPath: String,
                              projectName: String,
                              epic: String? = nil,
                              specFingerprint: String? = nil,
                              at: Date = Date()) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: projectPath,
            projectName: projectName,
            itemID: item.id,
            title: item.title,
            epic: epic,
            declaredSize: item.size?.rawValue,
            startedAt: at,
            completedAt: at,
            durationSeconds: 0,
            costUSD: 0,
            reviewerRetries: 0,
            outcome: refusal.outcome,
            // No session was spawned, so no agent ran. Named agents here would
            // file the refusal against a worker that never saw the item.
            workerAgent: nil,
            reviewerAgent: nil,
            executionID: nil,
            toolErrors: nil
        )
        record.changedFileCount = 0
        record.specFingerprint = specFingerprint
        return record
    }

    // MARK: - What version of the item an attempt was made against

    /// A stable fingerprint of the item's *specification* — what the worker is
    /// asked to build, not what has happened to it since.
    ///
    /// Notes and status are excluded on purpose. Both change without the item
    /// changing: the retirement note is itself appended to the detail file, so a
    /// fingerprint that covered Notes would be invalidated by the very act of
    /// recording the retirement, and every retired item would release itself on
    /// the next pickup. The title is excluded for the same reason the id is not
    /// the release path — a rename is not a rewrite.
    ///
    /// Nil without a detail file: there is no spec to fingerprint, and a
    /// fingerprint of nothing would make every detail-less item look identical.
    ///
    /// SHA-256 rather than `Hasher`, which is seeded per process — a fingerprint
    /// that changed at every launch would release every item at every launch.
    static func specFingerprint(item: BacklogItem, detail: BacklogItemDetail?) -> String? {
        guard let detail else { return nil }
        let fields: [String] = [
            detail.what ?? "",
            detail.approach ?? "",
            detail.why ?? "",
            detail.context ?? "",
            detail.acceptanceCriteria.joined(separator: "\n"),
            detail.outOfScope.joined(separator: "\n"),
            detail.verifyCommands
                .map { "\($0.name)\u{1}\($0.cmd)\u{1}\($0.expect ?? "")" }
                .joined(separator: "\n"),
            detail.size ?? item.size?.rawValue ?? "",
        ]
        // Whitespace-normalised, so a reflowed paragraph is not a rewrite: the
        // question is whether what the item *asks for* changed.
        let canonical = fields
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "\u{2}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Performing a human release, in the one place both callers reach it from.
///
/// `RetryCeiling` itself stays a pure judgement on values; this is the act. It is
/// kept together because a release that is recorded in the ledger but not in the
/// item's own file is half a release: the ledger answers "why did this run again"
/// for whoever thinks to look in `~/.kiteloop/grooming.jsonl`, and the note
/// answers it for whoever opens the item — which is where the retirement they are
/// reacting to was written.
@MainActor
enum RetryCeilingRelease {

    /// What a release did, so the caller can report it rather than assert it.
    struct Outcome: Equatable, Sendable {
        /// When it took effect — attempts finishing at or before this stop counting.
        let at: Date
        /// Whether the item was actually retired. A release of a runnable item is
        /// allowed and harmless, but it is not the same event and shouldn't be
        /// reported as one.
        let wasRetired: Bool
        /// The no-work count before and after. `after` is what the next pickup
        /// will read; it is 0 unless attempts are still to come.
        let noWorkAttemptsBefore: Int
        let noWorkAttemptsAfter: Int
    }

    /// Releases an item from the retry ceiling on a human's say-so.
    ///
    /// - Parameters:
    ///   - source: where the release came from, in words — it lands verbatim in
    ///     the ledger and in the item's Notes, and "who did this" is most of what
    ///     makes a release auditable.
    ///   - reason: an optional note from whoever released it.
    @discardableResult
    static func apply(itemID: String, projectPath: String, projectName: String,
                      source: String, reason: String? = nil,
                      ledger: GroomingLedger, backlog: BacklogViewModel?,
                      records: [TaskMetricRecord], at: Date = Date()) -> Outcome {
        let item = backlog?.item(withID: itemID)
        let fingerprint = item.flatMap {
            RetryCeiling.specFingerprint(item: $0, detail: backlog?.loadDetail(for: $0))
        }
        func verdict(releasedAt: Date?) -> RetryCeiling.Verdict {
            RetryCeiling.evaluate(itemID: itemID, projectPath: projectPath, records: records,
                                  releasedAt: releasedAt, specFingerprint: fingerprint)
        }
        let before = verdict(releasedAt: ledger.latestRelease(itemID: itemID, projectPath: projectPath))

        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recorded = "released by hand (\(source))"
            + ((trimmed?.isEmpty ?? true) ? "" : ": \(trimmed!)")
        ledger.recordRelease(itemID: itemID, projectPath: projectPath, projectName: projectName,
                             reason: recorded, at: at)
        // In the item too, directly under the retirement note it answers.
        backlog?.appendNote(itemID: itemID, RetryCeiling.releaseNote(source: source))

        return Outcome(at: at, wasRetired: before.isRetired,
                       noWorkAttemptsBefore: before.noWorkAttempts,
                       noWorkAttemptsAfter: verdict(releasedAt: at).noWorkAttempts)
    }
}
