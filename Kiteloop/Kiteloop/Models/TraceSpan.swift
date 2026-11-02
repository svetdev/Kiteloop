import Foundation

struct TraceSpan: Codable, Identifiable, Sendable {
    let id: String
    let agentID: String
    let sessionID: String
    let startTime: Date
    var endTime: Date?
    let type: SpanType
    let metadata: [String: String]
    var children: [TraceSpan]

    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    enum SpanType: String, Codable, Sendable {
        case turn
        case toolCall
        case thinking
    }

    /// Metadata keys that carry a turn's *ownership* and what it consumed.
    /// Shared between the recorder that writes them and the readers that select
    /// on them, because a key that drifts on one side reads back as "this run
    /// cost nothing" rather than as an error.
    enum MetadataKey {
        /// The workflow execution the turn belongs to. Absent on a turn with no
        /// owning run — a human chatting to an agent — which is what keeps that
        /// turn out of every item's cost.
        static let executionID = "executionID"
        /// The workflow node that ran the turn: `worker`, `reviewer`, …
        static let role = "role"
        /// The cost the CLI reported for the turn. Kept as the reported figure —
        /// `derivedCostUSD` is the one computed from the counters, and the two
        /// are stored side by side so a disagreement stays visible.
        static let costUSD = "costUSD"
        /// What this turn actually added to its session's running total —
        /// `costUSD` minus the total that session had already reported before
        /// this turn. Absent on a span written before this was recorded; a
        /// reader sums this to get a run's true spend without re-deriving
        /// session grouping, and falls back to `costUSD` only for those older
        /// spans.
        static let costDeltaUSD = "costDeltaUSD"
        /// Prompt tokens billed at full price — the uncached remainder only.
        static let inputTokens = "inputTokens"
        static let outputTokens = "outputTokens"
        /// Tokens written to / served from the prompt cache. Cache reads are
        /// most of the prompt on a long run and are billed at a fraction of the
        /// rate, so dropping these made the largest lever on spend invisible.
        static let cacheCreationTokens = "cacheCreationTokens"
        static let cacheReadTokens = "cacheReadTokens"
        /// The model that ran the turn, as the CLI reported it — without it two
        /// runs' spend cannot be compared, because nothing says what produced it.
        static let model = "model"
        /// The turn's cost recomputed from its counters at the rate card in
        /// force. Absent when the model is not in the table.
        static let derivedCostUSD = "derivedCostUSD"
        /// Which `ModelPriceTable` revision `derivedCostUSD` came from, so old
        /// history can be re-priced against the card that applied then.
        static let priceVersion = "priceVersion"

        /// The three input counters of the turn's **first model call** — what
        /// the agent was sent before it had read a file or called a tool.
        ///
        /// Separate from the four above, which are the whole leg's: one turn is
        /// up to fifty model calls with their tool output summed in, so the
        /// leg's counters cannot say what its opening prompt cost. Absent on a
        /// span whose runtime reports no per-call usage, and on every span
        /// written before this was captured.
        static let openingInputTokens = "openingInputTokens"
        static let openingCacheCreationTokens = "openingCacheCreationTokens"
        static let openingCacheReadTokens = "openingCacheReadTokens"
    }

    // MARK: - Usage

    /// The turn's token counters, or nil when the span carries none — a span
    /// written before they were recorded, or a turn whose `result` never
    /// arrived. Nil rather than `.zero`: a turn that recorded nothing must not
    /// read as a turn that consumed nothing.
    var tokenUsage: TokenUsage? {
        let keys = [MetadataKey.inputTokens, MetadataKey.outputTokens,
                    MetadataKey.cacheCreationTokens, MetadataKey.cacheReadTokens]
        guard keys.contains(where: { metadata[$0] != nil }) else { return nil }
        return TokenUsage(
            inputTokens: int(MetadataKey.inputTokens),
            outputTokens: int(MetadataKey.outputTokens),
            cacheCreationTokens: int(MetadataKey.cacheCreationTokens),
            cacheReadTokens: int(MetadataKey.cacheReadTokens)
        )
    }

    /// What the turn's first model call was sent — the opening context, when the
    /// runtime reported it. Nil on a span that carries no per-call counters, and
    /// on one whose counters are all zero: neither is a call that was sent
    /// nothing, and only nil says so.
    var openingContext: OpeningContext? {
        let keys = [MetadataKey.openingInputTokens, MetadataKey.openingCacheCreationTokens,
                    MetadataKey.openingCacheReadTokens]
        guard keys.contains(where: { metadata[$0] != nil }) else { return nil }
        let context = OpeningContext(
            inputTokens: int(MetadataKey.openingInputTokens),
            cacheCreationTokens: int(MetadataKey.openingCacheCreationTokens),
            cacheReadTokens: int(MetadataKey.openingCacheReadTokens)
        )
        return context.isEmpty ? nil : context
    }

    /// The model that ran the turn. Nil on a span recorded before the model was
    /// carried, or on one whose runtime never named it.
    var model: String? { nonEmpty(MetadataKey.model) }

    /// The cost the CLI reported, as recorded. This is the session's running
    /// total at the time of the turn, not the turn's own contribution — see
    /// `costDeltaUSD` for that.
    var reportedCostUSD: Double? { nonEmpty(MetadataKey.costUSD).flatMap(Double.init) }

    /// What this turn actually added to its session's running total. Nil on a
    /// span written before this was recorded.
    var costDeltaUSD: Double? { nonEmpty(MetadataKey.costDeltaUSD).flatMap(Double.init) }

    /// The cost derived from the counters, as recorded.
    var derivedCostUSD: Double? { nonEmpty(MetadataKey.derivedCostUSD).flatMap(Double.init) }

    var priceVersion: String? { nonEmpty(MetadataKey.priceVersion) }

    private func int(_ key: String) -> Int { metadata[key].flatMap(Int.init) ?? 0 }

    private func nonEmpty(_ key: String) -> String? {
        guard let value = metadata[key], !value.isEmpty else { return nil }
        return value
    }

    init(agentID: String, sessionID: String, type: SpanType, metadata: [String: String] = [:]) {
        self.init(
            id: UUID().uuidString,
            agentID: agentID,
            sessionID: sessionID,
            startTime: Date(),
            endTime: nil,
            type: type,
            metadata: metadata
        )
    }

    init(
        id: String,
        agentID: String,
        sessionID: String,
        startTime: Date,
        endTime: Date?,
        type: SpanType,
        metadata: [String: String] = [:],
        children: [TraceSpan] = []
    ) {
        self.id = id
        self.agentID = agentID
        self.sessionID = sessionID
        self.startTime = startTime
        self.endTime = endTime
        self.type = type
        self.metadata = metadata
        self.children = children
    }
}
