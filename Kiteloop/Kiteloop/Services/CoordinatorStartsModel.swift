import Foundation

/// What the Coordinator drawer's Starts section shows, as a value: the runs the
/// scheduler started by itself, and the decision it is standing on right now.
///
/// `CoordinatorRunScheduler` already records every autonomous start three ways —
/// `startHistory`, `~/.kiteloop/coordinator-starts.jsonl`, and a run record for
/// the control server — and `GET /v1/coordinator/scheduling` serves all of it.
/// Nothing in the app read any of it: the only way to learn what ran overnight,
/// or why nothing is running now, was to curl the endpoint or open the JSONL.
/// This is that same account, in the drawer.
///
/// Two properties are the reason it is a value rather than logic in a view body:
///
/// * **It derives nothing the scheduler doesn't already hold.** `make` takes the
///   records and the last decision and rearranges them; it reads no file, keeps
///   no second history, and cannot start anything. The list the drawer shows and
///   the list the endpoint serves are the same records in the same order.
/// * **The list is bounded at construction.** `startHistory` holds up to
///   `CoordinatorRunScheduler.maxStartHistory` runs and the drawer sits beside a
///   conversation, so the bound is applied here — and says what it cost, because
///   a truncated list that looks complete is worse than a short one.
struct CoordinatorStartsModel: Sendable, Equatable {

    // MARK: - One start

    /// One autonomous start as a row: when it went, what it picked, why, and how
    /// it ended.
    struct Row: Sendable, Equatable, Identifiable {

        /// The outcome as something to draw. The string is kept verbatim beside
        /// it — this is a reading of it, not a replacement for it, so an outcome
        /// nobody anticipated still shows what it actually said.
        enum Kind: String, Sendable {
            case running
            case done
            /// Finished, and waiting on a person at the merge gate.
            case awaitingApproval
            case blocked
            case cancelled
            /// The start was made and the run produced no result for the item.
            case didNotRun
            /// In flight when the app went away.
            case interrupted
            /// An outcome this reading doesn't know. Drawn plainly rather than
            /// filed under one of the above, which would be a guess.
            case other
        }

        let id: String
        let at: Date
        let finishedAt: Date?
        let project: String
        let itemID: String
        let itemTitle: String
        /// Exactly what the record says, e.g. `awaiting-approval`.
        let outcome: String
        let kind: Kind
        /// Why this project and item were chosen, and the day's budget as it
        /// stood — `RunScheduling.Target.reason` and `DailyBudget.text`, as the
        /// record kept them.
        let why: String
        let budgetText: String

        /// The item as a reader knows it. Its title when it has one, its id when
        /// it doesn't — a start read back from an older log can carry an empty
        /// title, and an empty line would be worse than the id.
        var headline: String {
            itemTitle.isEmpty ? itemID : itemTitle
        }

        /// `alpha · autonomous-run-ledger` — which project, and which item in it.
        var subtitle: String {
            "\(project) · \(itemID)"
        }

        /// The choice and the ceiling it was made under, on one line.
        var detail: String {
            "\(why) · budget \(budgetText)"
        }

        /// What an outcome means when the outcome alone doesn't say it.
        ///
        /// Both cases here are ones a reader stops at. A `did-not-run` looks like
        /// a fault and is a *refusal*: the scheduler committed to the start and
        /// the run came back with no result for the item — which is what the
        /// pickup gates rejecting it, or there being no agent session, looks like
        /// from here. The record keeps no reason of its own, so this names the
        /// possibilities rather than inventing which one it was.
        var note: String? {
            switch kind {
            case .didNotRun:
                return "Refused downstream — the run produced no result for this item. "
                    + "The pickup gates rejected it, or there was no agent session."
            case .interrupted:
                return "The app went away while this was running, so nobody saw it end."
            default:
                return nil
            }
        }
    }

    // MARK: - Where it stands

    /// The scheduler's last decision, as the line that answers "why is nothing
    /// happening right now?".
    ///
    /// Standing rather than historical: `lastDecision` is replaced on every look,
    /// so this is the current answer, not an entry in the list above.
    struct Standing: Sendable, Equatable {
        enum Kind: String, Sendable {
            case started
            case held
            /// The scheduler hasn't reached a decision since launch. Named for
            /// what it is rather than `none`, which would read as `Optional`'s
            /// wherever the kind is itself optional.
            case noDecision
        }

        let kind: Kind
        let text: String
    }

    // MARK: - Bounds

    /// Enough rows to read back an unattended night without the drawer becoming
    /// a log. The rest are not lost — `startHistory` keeps
    /// `CoordinatorRunScheduler.maxStartHistory`, the JSONL keeps far more, and
    /// `GET /v1/coordinator/scheduling` serves them.
    static let rowLimit = 10

    // MARK: - Fields

    /// Newest first — the opposite order to `startHistory`, which appends.
    let rows: CoordinatorPanelModel.BoundedList<Row>
    let standing: Standing

    // MARK: - Build

    /// Turn the scheduler's own state into the section.
    ///
    /// - Parameters:
    ///   - history: `CoordinatorRunScheduler.startHistory`, oldest first, exactly
    ///     as the scheduler keeps it — including the runs it read back from the
    ///     log at launch, which is what makes the list survive a restart.
    ///   - lastDecision: the decision the scheduler is standing on, or nil when
    ///     it hasn't looked yet.
    ///   - isSchedulingOn: the kill switch, which is only consulted when there is
    ///     no decision — see `standing(for:isSchedulingOn:)`.
    static func make(history: [CoordinatorRunScheduler.StartRecord],
                     lastDecision: RunScheduling.Decision?,
                     isSchedulingOn: Bool) -> CoordinatorStartsModel {
        CoordinatorStartsModel(
            rows: CoordinatorPanelModel.BoundedList(history.reversed().map(Row.init),
                                                   limit: rowLimit),
            standing: standing(for: lastDecision, isSchedulingOn: isSchedulingOn)
        )
    }

    /// The one line the drawer shows whether or not the list is unfolded.
    ///
    /// A decision, when there is one, is reported and nothing else. There often
    /// isn't: a switched-off scheduler has no timer at all, so it never reaches a
    /// decision to report, and "no decision yet" would be a poor answer to "why
    /// is nothing happening" when the answer is that it is off. So the switch is
    /// read in that one case — and said in `RunScheduling.Hold.disabled`'s own
    /// words, which is the decision a tick would return if one were asked for,
    /// rather than a second wording of the same state.
    private static func standing(for decision: RunScheduling.Decision?,
                                 isSchedulingOn: Bool) -> Standing {
        guard let decision else {
            guard isSchedulingOn else {
                return Standing(kind: .held, text: "Held — \(RunScheduling.Hold.disabled.reason)")
            }
            return Standing(kind: .noDecision,
                            text: "No decision yet — the scheduler hasn't taken a look since launch.")
        }
        switch decision {
        case .start(let target):
            return Standing(kind: .started, text: "Started \(target.project)/\(target.itemID)")
        case .hold(let hold):
            return Standing(kind: .held, text: "Held — \(hold.reason)")
        }
    }
}

// MARK: - From the record

extension CoordinatorStartsModel.Row {

    /// One start record as a row. A rearrangement and nothing else: every field
    /// comes from the record, and the outcome string is carried through beside
    /// the reading of it.
    init(_ record: CoordinatorRunScheduler.StartRecord) {
        self.init(id: record.id,
                  at: record.at,
                  finishedAt: record.finishedAt,
                  project: record.project,
                  itemID: record.itemID,
                  itemTitle: record.itemTitle,
                  outcome: record.outcome,
                  kind: Self.kind(of: record.outcome),
                  why: record.why,
                  budgetText: record.budgetText)
    }

    /// The outcome string as a case. The spellings are the ones the scheduler
    /// writes — `CoordinatorRunScheduler.StartRecord`'s own constants and
    /// `PortfolioSnapshot.outcomeName` — and anything else is `other` rather than
    /// the nearest guess.
    static func kind(of outcome: String) -> Kind {
        switch outcome {
        case CoordinatorRunScheduler.StartRecord.running: return .running
        case CoordinatorRunScheduler.StartRecord.didNotRun: return .didNotRun
        case CoordinatorRunScheduler.StartRecord.interrupted: return .interrupted
        case "done": return .done
        case "awaiting-approval": return .awaitingApproval
        case "blocked": return .blocked
        case "cancelled": return .cancelled
        default: return .other
        }
    }
}

// MARK: - Capture

extension CoordinatorStartsModel {

    /// Read the live scheduler into the section. The one place this touches
    /// `CoordinatorRunScheduler`, and it only reads.
    ///
    /// Nil when no scheduler is wired into this window — the drawer then says so,
    /// rather than drawing an empty list that reads as "nothing ever ran".
    ///
    /// A scheduler that *is* wired but has nothing else attached still has a
    /// section: its history was read back from the log at launch and is real
    /// history, and its standing line says `.unwired` in as many words.
    @MainActor
    static func capture(_ scheduler: CoordinatorRunScheduler?) -> CoordinatorStartsModel? {
        guard let scheduler else { return nil }
        return make(history: scheduler.startHistory,
                    lastDecision: scheduler.lastDecision,
                    isSchedulingOn: scheduler.enabled)
    }
}
