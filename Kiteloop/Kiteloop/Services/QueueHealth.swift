import Foundation
import KiteloopCore

/// How much of a project's `ready` column anything could actually start, and —
/// when the two numbers differ — what is holding the rest.
///
/// A queue full of items that cannot run looks exactly like a healthy one. The
/// landing screen counted items at `ready` and stopped there, so a 20-deep queue
/// of which nothing was runnable read as the deepest queue in the portfolio; two
/// of three projects sat stalled for hours looking busy. The distinction already
/// existed on the API side (`GET /v1/projects` → `queue.runnable`) and nowhere in
/// the app. This is that computation, factored out so both read it.
///
/// **Three counts, and they mean different things.** Keeping them apart is the
/// point of the type:
///
/// * `runnable` is the Definition-of-Ready verdict, decidable right now from the
///   item and its detail file. It is the control API's `queue.runnable` — the
///   same derivation, not a second one, so the window and a headless driver
///   cannot come to disagree.
/// * `heldAtPickup` is what the *other* pre-run gates recorded the last time they
///   looked. `GroundingCheck` needs an index of every source file in the repo and
///   `RetryCeiling` needs the run history; neither is affordable on a landing
///   screen that lists every recent project, and neither is guessable. So they
///   are read from `GroomingLedger`, which already writes one line per refusal —
///   a measurement somebody took, phrased as one ("at last pickup") rather than
///   passed off as a live verdict.
/// * `startable` is the honest answer to "how many of these could run": the
///   runnable ones that nothing is on record as having refused. On 2026-08-11
///   that was 1 of 20 in this repo, and grounding was the whole of the gap.
///
/// Pure and free of run state, like `DefinitionOfReady` itself: a function of the
/// backlog, the detail files and the ledger. Nothing here relaxes a gate or
/// reorders a queue — a withheld item is withheld, and this only says so out loud.
struct QueueHealth: Sendable, Equatable {

    // MARK: - Clauses

    /// Why a ready item is not going to run, grouped to the level a human acts
    /// on. Declared in the order a summary lists them — what the item is missing,
    /// then what it is waiting for, then what a gate recorded about it — so two
    /// projects in the same state always read the same way.
    ///
    /// Several `DefinitionOfReady.Requirement` cases fold into one clause on
    /// purpose: "no What section" and "no detail file at all" are one errand for
    /// whoever has to groom the item, and listing them apart would make the
    /// breakdown longer without making it more actionable.
    enum Clause: String, Sendable, Equatable, CaseIterable {
        /// No groomed detail file, or one missing What / How / Validation.
        case notGroomed = "not groomed"
        case noVerify = "no verify: command"
        /// A title or a `verify:` holding the backlog line's own field separator,
        /// so what is on disk is shorter than what was written.
        case malformedLine = "line splits on its own separator"
        case unsized = "no size set"
        case tooBig = "too big for autopilot"
        /// Marked `flow:qa` in a project with no usable `kiteloop-qa.json`.
        case notOnboardedForQA = "project not onboarded for QA"
        /// A `needs:` naming an item that isn't `done`.
        case waiting = "waiting on another item"
        /// Recorded by `GroundingCheck` at the last pickup: the item cites a file
        /// or symbol the repo doesn't have.
        case notGrounded = "not grounded"
        /// Recorded by `RetryCeiling` at the last pickup: attempted its fill of
        /// times without producing anything.
        case retired = "retired by the retry ceiling"

        /// Whether the clause is a live verdict or a reading off the ledger. The
        /// two are phrased differently wherever they are shown together — a
        /// recorded refusal is a fact about the last time a gate looked, not
        /// about now.
        var isRecorded: Bool { self == .notGrounded || self == .retired }

        /// Which clause an unmet Definition-of-Ready requirement belongs to.
        init(_ requirement: DefinitionOfReady.Requirement) {
            switch requirement {
            case .detail, .what, .how, .validation: self = .notGroomed
            case .verify: self = .noVerify
            case .verifySeparator, .titleSeparator: self = .malformedLine
            case .size: self = .unsized
            case .sizeTooLarge: self = .tooBig
            case .qaProfile: self = .notOnboardedForQA
            case .dependency: self = .waiting
            }
        }

        /// Which clause a `GroomingRecord.check` belongs to, or nil for one this
        /// type answers live.
        ///
        /// A recorded `definition-of-ready` refusal is deliberately dropped: the
        /// verdict is recomputed here from the item as it reads *now*, so an item
        /// refused last night and groomed this morning must not still be counted
        /// against the clause it no longer fails.
        init?(check: String?) {
            switch check {
            case GroomingRecord.Check.grounding: self = .notGrounded
            case GroomingRecord.Check.retryCeiling: self = .retired
            default: return nil
            }
        }
    }

    /// One clause and how many ready items it holds.
    ///
    /// Grouped by clause rather than listed per item for the reason
    /// `PortfolioReport.Cause` is: a clause list is bounded (there are eight), an
    /// item list is not, and "19 not grounded" is more useful than nineteen ids.
    struct Withholding: Sendable, Equatable, Identifiable {
        let clause: Clause
        let count: Int
        /// One verdict verbatim, so the reader has something to go and fix.
        let example: String?

        var id: String { clause.rawValue }

        /// e.g. `19 not grounded`.
        var text: String { "\(count) \(clause.rawValue)" }

        /// The same with its example, e.g.
        /// `19 not grounded — cites Services/Nope.swift, which doesn't exist`.
        var detailedText: String {
            example.map { "\(text) — \($0)" } ?? text
        }
    }

    // MARK: - Fields

    /// Items sitting at `ready`.
    let ready: Int
    /// Of those, the ones inside the Definition-of-Ready. The control API's
    /// `queue.runnable`, from the same derivation.
    let runnable: Int
    /// Of the runnable ones, how many a pre-run gate is on record as having
    /// refused. Never larger than `runnable`.
    let heldAtPickup: Int
    let awaitingApproval: Int
    /// Items in flight. `active` alone, as the control API counts it — an
    /// `in-review` item is a different stage and this pair of numbers is read
    /// against that endpoint.
    let active: Int
    /// Items sitting on the reviewer — the stage after `active`, counted apart
    /// from it for the reason above.
    let inReview: Int
    /// Items that landed at `blocked`. Orthogonal to the stages (see
    /// `BacklogItemStatus`): an item can reach it from anywhere, and it is the
    /// one state nothing gets out of without a person.
    let blocked: Int
    /// Items filed but not yet groomed. The control API's `queue.draft`, from the
    /// same statuses — this is the app-side counterpart of that count.
    ///
    /// None of these three is a `Withholding`: a draft, an item on the reviewer
    /// and a blocked item are not ready items, so they reconcile against nothing
    /// in the `ready` column. They are here because a backlog of sixty ungroomed
    /// drafts, one stuck behind a reviewer, one fourteen items deep in `blocked`
    /// and one that is finished are four different states, and all four used to
    /// render the same sentence.
    let drafts: Int
    /// Why the rest aren't running, most common first. Every withheld item is
    /// counted exactly once, under the first clause it fails, so the counts
    /// reconcile against `ready` rather than double-counting an item that misses
    /// several.
    let withheld: [Withholding]

    /// A project with no backlog at all — not a queue with nothing in it. The
    /// caller says which of the two it is; this is the shape for the former.
    static let empty = QueueHealth(ready: 0, runnable: 0, heldAtPickup: 0,
                                   awaitingApproval: 0, active: 0, inReview: 0, blocked: 0,
                                   drafts: 0, withheld: [])

    /// What could actually start: runnable, minus what a gate has refused.
    var startable: Int { max(0, runnable - heldAtPickup) }

    /// A queue with items in it that nothing could pick up. The state that used
    /// to read as the healthiest project in the portfolio.
    var isStalled: Bool { ready > 0 && startable == 0 }

    /// Whether the queue is entirely free of holds — every ready item could run.
    var isClear: Bool { ready > 0 && startable == ready }

    // MARK: - Phrasing

    /// How many clauses the one-line summary names before it stops counting. The
    /// line sits under a project name on a landing screen; the full list is
    /// rendered where there is room for it.
    static let summaryClauseLimit = 3

    /// One honest line: what the project's queue is, or the reason it isn't
    /// anything. This is the thing that was missing — not a dashboard.
    ///
    /// e.g. `20 ready, none can start — 19 not grounded, 1 no verify: command`,
    /// `12 ready, all runnable`, `Nothing ready · 3 awaiting your approval`,
    /// `Nothing ready · 60 ungroomed drafts`,
    /// `Nothing ready · 1 in review · 14 blocked`.
    var summary: String {
        var line = queueSummary
        if awaitingApproval > 0 {
            line += " · \(awaitingApproval) awaiting your approval"
        }
        return line
    }

    /// The queue half of `summary`, before the approval clause — the line for a
    /// surface that is already showing the gate.
    ///
    /// Inside an open project the Autopilot panel lists every item awaiting
    /// approval by name, with the buttons that resolve it, directly beneath this
    /// line; "· 2 awaiting your approval" above that box says nothing the reader
    /// cannot already see. The landing screen has no such box and reads
    /// `summary`.
    ///
    /// Same words either way, and the same derivation behind them. Two surfaces
    /// answering "how much of this could start?" in different words is how they
    /// come to be read as answering different questions.
    var queueSummary: String {
        guard ready > 0 else {
            // An empty ready column and a stalled one are opposite problems, and
            // both used to render as silence. A column emptied by grooming never
            // having happened is a third: a backlog of nothing but drafts read
            // exactly like a finished one, so it says which it is. Work sitting
            // on the reviewer, and work at `blocked`, are the fourth and fifth —
            // a backlog whose every item is stuck is the furthest thing from an
            // idle one, and it read as one until it named them too.
            var line = "Nothing ready"
            if active > 0 { line += " · \(active) in flight" }
            if inReview > 0 { line += " · \(inReview) in review" }
            if blocked > 0 { line += " · \(blocked) blocked" }
            if drafts > 0 {
                line += " · \(drafts) ungroomed draft\(drafts == 1 ? "" : "s")"
            }
            return line
        }
        if isClear { return "\(ready) ready, all runnable" }
        let head = startable == 0 ? "\(ready) ready, none can start"
                                  : "\(ready) ready, \(startable) can start"
        guard !withheld.isEmpty else { return head }
        return "\(head) — \(reasonsPhrase)"
    }

    /// The withheld clauses, most common first, capped — with the overflow named
    /// rather than dropped, so a capped list is never read as the whole of it.
    var reasonsPhrase: String {
        let shown = withheld.prefix(Self.summaryClauseLimit)
        var phrase = shown.map(\.text).joined(separator: ", ")
        let omitted = withheld.count - shown.count
        if omitted > 0 { phrase += ", +\(omitted) more" }
        return phrase
    }

    // MARK: - Build

    /// One recorded pre-run refusal, as the ledger wrote it.
    struct Refusal: Sendable, Equatable {
        let clause: Clause
        /// The verdict verbatim.
        let reason: String?
    }

    /// Judge a project's backlog.
    ///
    /// - Parameters:
    ///   - items: every item in the file, flattened across epics. All of them,
    ///     not just the ready ones: a `needs:` routinely names an item in another
    ///     epic, and a dependency resolved against a subset would report an item
    ///     as waiting on something that is in fact `done`.
    ///   - detail: the item's groomed `backlog/<id>.md`, or nil when it has none.
    ///     Called for ready items only — parsing a file per `done` item to answer
    ///     a question nobody asked about it is pure cost.
    ///   - refusals: what the pre-run gates recorded, by item id. Empty is a
    ///     legitimate input and means "nothing on record", never "nothing
    ///     refused" — see `recordedRefusals(_:projectPath:)`.
    static func make(items: [BacklogItem],
                     detail: (BacklogItem) -> BacklogItemDetail?,
                     refusals: [String: Refusal] = [:]) -> QueueHealth {
        let dependencies = DefinitionOfReady.Dependencies(items: items)
        let readyItems = items.filter { $0.status == .ready }

        var runnable = 0
        var heldAtPickup = 0
        // Counted per clause, keeping the first example each one produced — the
        // same "one verbatim verdict per cause" `PortfolioReport` reports.
        var counts: [Clause: (count: Int, example: String?)] = [:]
        func note(_ clause: Clause, _ reason: String?) {
            let existing = counts[clause]
            counts[clause] = (count: (existing?.count ?? 0) + 1,
                              example: existing?.example ?? reason)
        }

        for item in readyItems {
            let verdict = DefinitionOfReady.evaluate(item: item, detail: detail(item),
                                                     dependencies: dependencies)
            guard verdict.isReady else {
                // The first unmet clause only. An ungroomed item usually fails
                // several, and counting it once per clause would report more
                // withheld items than the column holds.
                if let requirement = verdict.unmet.first {
                    note(Clause(requirement), verdict.reasons.first)
                }
                continue
            }
            runnable += 1
            if let refusal = refusals[item.id] {
                heldAtPickup += 1
                note(refusal.clause, refusal.reason)
            }
        }

        var withheld = counts.map { Withholding(clause: $0.key, count: $0.value.count,
                                                example: $0.value.example) }
        withheld.sort { lhs, rhs in
            lhs.count == rhs.count ? order(lhs.clause) < order(rhs.clause) : lhs.count > rhs.count
        }

        return QueueHealth(
            ready: readyItems.count,
            runnable: runnable,
            heldAtPickup: heldAtPickup,
            awaitingApproval: items.count { $0.status == .awaitingApproval },
            active: items.count { $0.status == .active },
            inReview: items.count { $0.status == .inReview },
            blocked: items.count { $0.status == .blocked },
            drafts: items.count { $0.status == .draft },
            withheld: withheld)
    }

    /// What the pre-run gates last recorded about each of a project's items.
    ///
    /// The ledger is portfolio-wide and item ids are only unique within a
    /// project, so it is scoped by canonical path — the same attribution
    /// `PortfolioReport` and `RetryCeiling` use. The *latest* record per item
    /// wins, and a human's release wins over the refusal it lifted: an item
    /// released last night is one the ceiling no longer refuses, and reporting it
    /// as still held would contradict the pickup that is about to run it.
    ///
    /// - Parameter detailModified: the item's groomed detail file's last-edited
    ///   date, by item id. `GroundingCheck`'s live path already recomputes a
    ///   `definition-of-ready` refusal against the item as it reads now (see
    ///   `Clause.init(check:)`) — but a `grounding-check` or `retry-ceiling`
    ///   refusal is only ever read back from here, so without this a refusal
    ///   recorded the night before a regroom outlives the edit that fixed it. A
    ///   refusal older than the item's last edit is dropped; nil for an item
    ///   means no date is known, and the refusal is kept exactly as before —
    ///   absence of evidence is not evidence the item changed.
    static func recordedRefusals(_ records: [GroomingRecord], projectPath: String,
                                 detailModified: (String) -> Date? = { _ in nil }) -> [String: Refusal] {
        let canonical = KiteloopProject.canonicalPath(projectPath)
        var latest: [String: GroomingRecord] = [:]
        for record in records
        where record.event == .checkFailed || record.event == .released {
            guard KiteloopProject.canonicalPath(record.projectPath) == canonical else { continue }
            if let existing = latest[record.itemID], existing.at > record.at { continue }
            latest[record.itemID] = record
        }
        var refusals: [String: Refusal] = [:]
        for (itemID, record) in latest {
            guard record.event == .checkFailed, let clause = Clause(check: record.check) else { continue }
            if let modified = detailModified(itemID), record.at < modified { continue }
            refusals[itemID] = Refusal(clause: clause, reason: record.reason)
        }
        return refusals
    }

    /// Declaration order, for breaking a tie between two clauses of equal count
    /// so the same queue always renders the same way.
    private static func order(_ clause: Clause) -> Int {
        Clause.allCases.firstIndex(of: clause) ?? Clause.allCases.count
    }
}

// MARK: - Fleet

extension QueueHealth {

    /// The whole portfolio in one line — the failure was a fleet-level one, and
    /// per-project cards each say only their own half of it.
    ///
    /// Named projects rather than a total, because a total hides exactly what
    /// went wrong on 2026-08-11: two of three projects stalled for different
    /// reasons while the third was fine, and "32 ready across 3 projects" would
    /// have read as the healthiest the portfolio had ever been.
    ///
    /// Nil when nothing is stalled — there is no line to draw for a fleet that is
    /// simply working.
    static func fleetStallLine(_ stalled: [(name: String, queue: QueueHealth)],
                               nameLimit: Int = 3) -> String? {
        guard !stalled.isEmpty else { return nil }
        let shown = stalled.prefix(max(1, nameLimit))
        var names = shown.map(\.name).joined(separator: ", ")
        let omitted = stalled.count - shown.count
        if omitted > 0 { names += " +\(omitted) more" }
        let held = stalled.reduce(0) { $0 + $1.queue.ready }
        let projects = stalled.count == 1 ? "project" : "projects"
        return "\(held) ready in \(stalled.count) \(projects) that can't start — \(names)"
    }
}
