import Foundation

/// The four token counters the CLI reports for a turn, kept as one value.
///
/// Dollars are derived; these are what was actually consumed. Carrying the two
/// cache counters beside input/output is what makes the cache hit rate visible:
/// on a long agent run cache reads are most of the prompt and are billed at a
/// tenth of the base input rate, so a run whose cache stops hitting is a cost
/// regression that a single dollar figure cannot show.
struct TokenUsage: Codable, Sendable, Equatable {
    /// Prompt tokens processed at full price — the *uncached remainder only*,
    /// not the whole prompt. See `promptTokens`.
    var inputTokens: Int
    var outputTokens: Int
    /// Tokens written to the cache this turn (billed at a premium over input).
    var cacheCreationTokens: Int
    /// Tokens served from the cache this turn (billed at a fraction of input).
    var cacheReadTokens: Int

    static let zero = TokenUsage()

    init(inputTokens: Int = 0, outputTokens: Int = 0,
         cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    /// Everything that went into the prompt. `input_tokens` alone understates it
    /// badly — a turn reading 200k from cache reports a few thousand there — so
    /// every share and rate below is taken over the sum of the three input
    /// counters, never over `inputTokens`.
    var promptTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }

    var totalTokens: Int { promptTokens + outputTokens }

    /// Share of the prompt served from cache, 0…1. Nil when no prompt token was
    /// observed: 0/0 is "not measured", not "the cache never hit".
    var cacheHitRate: Double? {
        promptTokens > 0 ? Double(cacheReadTokens) / Double(promptTokens) : nil
    }

    /// `87%`, or the plain statement that nothing was measured — a rate over
    /// zero prompt tokens is not 0%.
    var cacheHitRateText: String {
        guard let rate = cacheHitRate else { return "not measured" }
        return "\(Int((rate * 100).rounded()))%"
    }

    /// True when every counter is zero. A turn that reported nothing and a turn
    /// that genuinely consumed nothing are indistinguishable here, which is why
    /// callers carry `TokenUsage?` and reserve nil for "no counter was recorded".
    var isEmpty: Bool { totalTokens == 0 }

    /// A token count compact enough for a caption: `450`, `10.0k`, `3.4M`.
    static func compactCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens
        )
    }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }
}

/// What one run consumed, rolled up from the turn spans it owns.
///
/// Every field is optional, and nil means *no turn recorded it* rather than
/// zero. That distinction is the point: a run whose usage never arrived — spans
/// written before these counters existed, a turn that died before its `result`
/// event — must not read as a run that consumed nothing, which is what a `0`
/// here would claim.
struct RunTokenUsage: Sendable, Equatable {
    /// The four counters summed over the run's turns.
    let usage: TokenUsage?
    /// Cost recomputed from those counters at the rate card each turn was priced
    /// at. Nil when no turn could be priced — an unknown model, or a span
    /// predating the price table.
    let derivedCostUSD: Double?
    /// The model the turns ran on, as the CLI reported it. Several joined by `+`
    /// when the worker and reviewer ran on different models.
    let model: String?
    /// Which `ModelPriceTable` revision `derivedCostUSD` came from; joined the
    /// same way when a run straddled a rate change.
    let priceVersion: String?

    /// Nothing recorded — what a run with no priced, counted turn rolls up to.
    static let none = RunTokenUsage(usage: nil, derivedCostUSD: nil, model: nil, priceVersion: nil)

    var cacheHitRate: Double? { usage?.cacheHitRate }

    /// Rolls up the turn spans of one run. `spans` is expected to be already
    /// scoped to the run — this sums whatever it is given.
    static func rollUp(_ spans: [TraceSpan]) -> RunTokenUsage {
        let usages = spans.compactMap(\.tokenUsage)
        let derived = spans.compactMap(\.derivedCostUSD)
        return RunTokenUsage(
            usage: usages.isEmpty ? nil : usages.reduce(.zero, +),
            derivedCostUSD: derived.isEmpty ? nil : derived.reduce(0, +),
            model: joined(spans.compactMap(\.model)),
            priceVersion: joined(spans.compactMap(\.priceVersion))
        )
    }

    /// The distinct values as one field, in a stable order. Nil when there are
    /// none, so an absent model never reads as an empty string.
    private static func joined(_ values: [String]) -> String? {
        let distinct = Set(values.filter { !$0.isEmpty })
        return distinct.isEmpty ? nil : distinct.sorted().joined(separator: "+")
    }
}
