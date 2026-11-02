import Foundation

/// What an aggregate over the metric index is grouped by.
///
/// A closed set rather than a caller-supplied column, because the value is
/// interpolated into the `GROUP BY` — the enum *is* the whitelist.
enum MetricGrouping: String, Sendable, CaseIterable {
    /// One group per declared item size (`S`, `M`, …).
    case size
    case epic
    case outcome
    /// One group per project, keyed by its canonical root path.
    case project
    /// One group per calendar day the run *finished*, in the machine's own time
    /// zone — the day a human asking "what did last night cost" means.
    case day
    /// One group per model the run's turns ran on, as the CLI reported it.
    case model
    /// The whole selection as a single group. `GET /v1/metrics?aggregate=total`.
    case total
    /// One group per workflow role — `worker`, `reviewer`. Unlike every case
    /// above this aggregates **turns**, not runs: a role is a property of the
    /// turn that incurred the spend, and a run has several.
    case role

    /// Whether this dimension groups turns rather than runs — the two answer
    /// with different shapes, since a turn has no reviewer retries to count.
    var isTurnDimension: Bool { self == .role }

    /// The indexed column it groups on. Nil for `total`, which has no column.
    var column: String? {
        switch self {
        case .size: "declared_size"
        case .epic: "epic"
        case .outcome: "outcome"
        case .project: "project_id"
        case .day: "day"
        case .model: "model"
        case .role: "role"
        case .total: nil
        }
    }

    /// What a NULL in the grouped column is reported as. A run with no epic is a
    /// real group — dropping it would silently shrink the totals.
    static let unknownKey = "unknown"
}

/// One group of an aggregate over indexed runs.
///
/// Sums and counts only. Every field that can be "not recorded" stays optional,
/// for the reason `TaskMetricRecord` gives: a run whose usage never arrived must
/// not read as a run that consumed nothing.
struct RunAggregate: Sendable, Equatable {
    /// The grouped value — `MetricGrouping.unknownKey` when the column was NULL.
    let key: String
    let runs: Int
    /// Sum of the cost each run reported.
    let costUSD: Double
    /// Sum of the cost re-derived from token counters, over the runs that had
    /// them. Nil when no run in the group did.
    let derivedCostUSD: Double?
    let durationSeconds: Double
    let reviewerRetries: Int
    /// Runs whose work landed on main. `merged` is optional per record and an
    /// unknown counts as not merged, matching `PortfolioReport`.
    let merged: Int
    /// Runs that left work behind — the denominator any cost-per-item worth
    /// quoting is taken over.
    let producedWork: Int
    /// The four counters summed over the runs that recorded any. Nil when none did.
    let usage: TokenUsage?
    /// How many runs contributed to `usage` — the honest denominator for it,
    /// which is not `runs` whenever some runs predate token capture.
    let runsWithUsage: Int

    var avgCostUSD: Double? { runs == 0 ? nil : costUSD / Double(runs) }
    var avgDurationSeconds: Double? { runs == 0 ? nil : durationSeconds / Double(runs) }
    var avgReviewerRetries: Double? { runs == 0 ? nil : Double(reviewerRetries) / Double(runs) }

    /// Reported spend divided by the runs that actually produced work — the
    /// number "cost per item" means. Nil when nothing in the group produced any,
    /// because dividing by the runs that built nothing answers a different
    /// question than the one asked.
    var costPerProducedRunUSD: Double? {
        producedWork == 0 ? nil : costUSD / Double(producedWork)
    }
}

/// One group of an aggregate over indexed turns — the level spend is actually
/// incurred at, and the only level at which "what share of this went to review"
/// can be answered.
struct TurnAggregate: Sendable, Equatable {
    let key: String
    let turns: Int
    let costUSD: Double
    let derivedCostUSD: Double?
    let durationSeconds: Double
    let usage: TokenUsage?
    let turnsWithUsage: Int
}

/// One indexed line of a run's transcript.
///
/// The projection `MetricIndex` keeps of a `RunTranscriptStore.Record`: enough
/// to say what the record was, who produced it and when, without holding the
/// payload. `text` is the record's own words for the two kinds a diagnostic
/// query reads — an agent's message and an error — and nil for every other kind,
/// whose payload stays in the JSONL line the row was read from.
struct TranscriptEntry: Sendable, Equatable {
    /// The recorded message's own id, which is what makes replay idempotent.
    let id: String
    let projectID: String
    /// The run this record belongs to.
    let executionID: String
    /// The workflow node that produced it — `worker`, `reviewer`.
    let role: String
    let agentID: String
    let sender: Sender
    let kind: Kind
    /// The tool a call, an approval or a permission prompt names. Nil otherwise.
    let toolName: String?
    let recordedAt: Date
    /// The record's words, for the kinds that are indexed with them.
    let text: String?
    /// The size of the line in the log — what the payload left there costs.
    let byteCount: Int

    /// Who produced the record. The prompt that opened a run sits in the same
    /// file as the answer to it, and "the worker said nothing" is a statement
    /// about the answers only.
    enum Sender: String, Sendable, CaseIterable {
        case human
        case agent
        case system
    }

    /// The `Message.Content` case the record carried, flattened to a column so a
    /// query can filter on it without decoding the message.
    enum Kind: String, Sendable, CaseIterable {
        case text
        case thinking
        case toolCall
        case toolResult
        case approval
        case permissionPrompt
        case mcpAuthRequest
        case image
        case error
        case systemEvent
    }
}

/// A measured run joined to what its transcript says about it.
///
/// The shape both transcript-against-run questions answer in: "which runs this
/// week produced nothing, and what did the worker say as it finished" and "which
/// runs had a worker that said nothing at all". The counts are what separate
/// those two — a nil `closingMessage` with records behind it is a worker that
/// worked and never summed up, and a nil one with `agentRecordCount == 0` is a
/// session that died.
struct RunTranscriptSummary: Sendable, Equatable {
    let runID: String
    let projectID: String
    let itemID: String
    let title: String
    let executionID: String?
    let completedAt: Date
    let outcome: String
    /// `TaskMetricRecord.producedWork` as it was derived at ingest.
    let producedWork: Bool
    /// Indexed records for the run, across every role.
    let recordCount: Int
    /// Indexed records for the queried role.
    let roleRecordCount: Int
    /// Records the queried role's *agent* produced — its own output, not the
    /// prompt it was given.
    let agentRecordCount: Int
    /// The last thing the role's agent said, in full. `RunClosingMessage.condensed`
    /// is the one-line form a log or a note quotes it in.
    let closingMessage: String?
    let closingMessageAt: Date?

    /// Whether anything at all was indexed for this run. False means the
    /// transcript was never written or has been pruned — `RunTranscriptStore`
    /// is what tells those apart.
    var hasTranscript: Bool { recordCount > 0 }
}
