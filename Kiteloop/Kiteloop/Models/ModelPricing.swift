import Foundation

/// What one model costs per million tokens, in the four categories the API bills
/// separately.
struct ModelPrice: Codable, Sendable, Equatable {
    let inputPerMTok: Double
    let outputPerMTok: Double
    /// Cache writes at the 5-minute TTL (1.25× base input). The CLI reports one
    /// `cache_creation_input_tokens` figure without saying which TTL wrote it,
    /// so a 1-hour write (2× base input) is priced here at the 5-minute rate and
    /// the derived cost runs low for it. That is a knowable gap between the
    /// derived figure and the CLI's, which is one of the reasons both are kept.
    let cacheWritePerMTok: Double
    /// Cache reads (0.1× base input).
    let cacheReadPerMTok: Double

    /// What `usage` costs at these rates.
    func cost(for usage: TokenUsage) -> Double {
        (Double(usage.inputTokens) * inputPerMTok
            + Double(usage.outputTokens) * outputPerMTok
            + Double(usage.cacheCreationTokens) * cacheWritePerMTok
            + Double(usage.cacheReadTokens) * cacheReadPerMTok) / 1_000_000
    }
}

/// A priced turn or run: the dollars, and everything needed to say how they were
/// arrived at.
struct PricedCost: Sendable, Equatable {
    let usd: Double
    /// The `ModelPriceTable.Revision.version` the rates came from. Without it a
    /// derived cost is just another un-analysable number — you cannot re-price
    /// history if you cannot say what it was priced at.
    let priceVersion: String
    /// The table key the reported model resolved to, e.g. `claude-opus-5`.
    let modelKey: String
}

/// The rate card, versioned by effective date.
///
/// Cost used to be whatever the CLI reported at the moment a turn ran, frozen.
/// A published rate change then made all history incomparable with everything
/// after it, silently. This table fixes the rates *and the date they took
/// effect*, so re-pricing an old run uses the card that applied then and
/// re-pricing at a newer card is a deliberate, visible act rather than a drift.
///
/// It does not replace the CLI's figure — `TraceSpan` keeps both. When the two
/// disagree, the disagreement is the finding: a model missing from the table, a
/// rate that moved, a cache write billed at the 1-hour TTL.
///
/// Rates are the published per-MTok Claude API prices
/// (<https://platform.claude.com/docs/en/about-claude/pricing>). Non-Claude
/// models — Ollama, the Copilot bridge — are deliberately absent: they have no
/// per-token dollar rate here, and inventing one would be worse than reporting
/// no derived cost.
struct ModelPriceTable: Sendable {

    /// One issue of the rate card.
    struct Revision: Sendable {
        /// Stamped onto every cost derived from it, and onto the metric record.
        let version: String
        /// The first instant these rates apply to.
        let effectiveFrom: Date
        let prices: [String: ModelPrice]
    }

    /// Ascending by `effectiveFrom`.
    let revisions: [Revision]

    // MARK: - Lookup

    /// The card in force on `date`.
    ///
    /// A date before the earliest revision gets that earliest revision rather
    /// than nothing: the app has history predating the day this table was first
    /// compiled, and pricing it at the oldest card on record is a stated
    /// approximation, where refusing to price it at all would just re-create the
    /// blind spot. Nil only for an empty table.
    func revision(on date: Date) -> Revision? {
        revisions.last { $0.effectiveFrom <= date } ?? revisions.first
    }

    /// The rates for `model` on `date`, or nil when the model is not priced here.
    func price(for model: String, on date: Date) -> (price: ModelPrice, revision: Revision, key: String)? {
        guard let revision = revision(on: date),
              let key = Self.key(for: model),
              let price = revision.prices[key] else { return nil }
        return (price, revision, key)
    }

    /// What `usage` costs for `model` at the card in force on `date`. Nil when
    /// the model is not in the table — an unpriced model reports no derived
    /// cost, never $0.
    func cost(of usage: TokenUsage, model: String, on date: Date) -> PricedCost? {
        guard let (price, revision, key) = self.price(for: model, on: date) else { return nil }
        return PricedCost(usd: price.cost(for: usage), priceVersion: revision.version, modelKey: key)
    }

    // MARK: - Model keys

    /// The table key a reported model string resolves to, or nil for a model
    /// this table does not price.
    ///
    /// The CLI reports a concrete id (`claude-opus-5`), Bedrock reports an
    /// inference profile (`us.anthropic.claude-opus-4-8-v1:0`), and an agent
    /// config may hold nothing but a family alias (`opus`). All three have to
    /// land on the same row.
    static func key(for model: String) -> String? {
        let lower = model.lowercased()
        if let claudeRange = lower.range(of: "claude") {
            let id = String(lower[claudeRange.lowerBound...])
            // Longest key first: `claude-opus-4` is a prefix of `claude-opus-4-8`,
            // and the more specific row is the right one.
            if let key = knownKeys.first(where: { id.hasPrefix($0) }) {
                return namesTheSameModel(after: id.dropFirst(key.count)) ? key : nil
            }
        }
        // A bare family alias ("opus", "sonnet") names a family, not a release —
        // price it at that family's current flagship, which is what the alias
        // launches today. Gated to the input actually *being* one of those
        // words: `ModelCatalog.familyAlias` matches any string that merely
        // contains a family word, which would otherwise price a concrete id
        // the table doesn't know — a retired legacy id, or any Claude released
        // after this table was compiled — at today's flagship rate, silently.
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard familyFlagship.keys.contains(trimmed) else { return nil }
        return familyFlagship[trimmed]
    }

    /// Whether what follows a matched key still names that key's model.
    ///
    /// A prefix match alone is not enough, because the row for a model is also a
    /// prefix of the row for its successor: `claude-opus-4-9` starts with
    /// `claude-opus-4`, and pricing it there charges a release this table has
    /// never seen at the rate of one it has. The two shapes that follow a key
    /// have to be told apart:
    ///
    /// - a **dated release** of that model — `-20250514`, `-20251001` — which is
    ///   that model, and resolves to its row;
    /// - a **further version segment** — `-9` in `claude-opus-4-9-v1:0` — which
    ///   is a different model. If this table knew it, it would have its own key
    ///   and the longest-first search would have found it; that it did not means
    ///   the release is unknown, and unknown must price as nothing rather than
    ///   as its predecessor.
    ///
    /// The two are separable by length: a date is eight digits, a version
    /// segment one or two. A suffix that is not all digits (`-v1:0`, Bedrock's
    /// profile tail) qualifies nothing and leaves the match standing.
    private static func namesTheSameModel(after rest: Substring) -> Bool {
        guard !rest.isEmpty else { return true }
        // No separator means the key merely ran into a longer word, not that a
        // suffix follows it — a different id, not a release of this one.
        guard rest.hasPrefix("-") else { return false }
        let segment = rest.dropFirst().prefix { $0 != "-" }
        guard segment.allSatisfy(\.isNumber) else { return true }
        return segment.count > 2
    }

    private static let knownKeys: [String] = allKeys.sorted { $0.count > $1.count }

    private static let allKeys = [
        "claude-fable-5-1", "claude-fable-5", "claude-mythos-5",
        "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
        "claude-opus-4-5", "claude-opus-4-1", "claude-opus-4",
        "claude-sonnet-5", "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4",
        "claude-haiku-4-5", "claude-haiku-3-5",
    ]

    private static let familyFlagship = [
        "fable": "claude-fable-5-1",
        "opus": "claude-opus-5-5",
        "sonnet": "claude-sonnet-5",
        "haiku": "claude-haiku-4-5",
    ]

    // MARK: - The card

    /// The table the app prices with.
    static let current = ModelPriceTable(revisions: [.published2026_08_08, .published2026_09_01])

    fileprivate static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }
}

extension ModelPriceTable.Revision {

    /// The published card as of 2026-08-08, when this table was compiled.
    static let published2026_08_08 = ModelPriceTable.Revision(
        version: "2026-08-08",
        effectiveFrom: ModelPriceTable.day(2026, 8, 8),
        prices: basePrices
    )

    /// Claude Sonnet 5's introductory pricing ($2/$10) ends 2026-08-31; standard
    /// pricing ($3/$15) applies from 2026-09-01. A scheduled, published change —
    /// and the reason the table is dated rather than a single frozen map.
    static let published2026_09_01 = ModelPriceTable.Revision(
        version: "2026-09-01",
        effectiveFrom: ModelPriceTable.day(2026, 9, 1),
        prices: basePrices.merging([
            "claude-sonnet-5": ModelPrice(inputPerMTok: 3, outputPerMTok: 15,
                                          cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.30),
        ]) { _, new in new }
    )

    private static let basePrices: [String: ModelPrice] = [
        "claude-fable-5-1": ModelPrice(inputPerMTok: 10, outputPerMTok: 50,
                                       cacheWritePerMTok: 12.50, cacheReadPerMTok: 0.25),
        "claude-fable-5": ModelPrice(inputPerMTok: 10, outputPerMTok: 50,
                                     cacheWritePerMTok: 12.50, cacheReadPerMTok: 1.00),
        "claude-mythos-5": ModelPrice(inputPerMTok: 10, outputPerMTok: 50,
                                      cacheWritePerMTok: 12.50, cacheReadPerMTok: 1.00),
        "claude-opus-5-5": ModelPrice(inputPerMTok: 4, outputPerMTok: 20,
                                      cacheWritePerMTok: 5.00, cacheReadPerMTok: 0.20),
        "claude-opus-5": opus4x,
        "claude-opus-4-8": opus4x,
        "claude-opus-4-7": opus4x,
        "claude-opus-4-6": opus4x,
        "claude-opus-4-5": opus4x,
        "claude-opus-4-1": opus4Legacy,
        "claude-opus-4": opus4Legacy,
        // Introductory pricing, in force through 2026-08-31.
        "claude-sonnet-5": ModelPrice(inputPerMTok: 2, outputPerMTok: 10,
                                      cacheWritePerMTok: 2.50, cacheReadPerMTok: 0.20),
        "claude-sonnet-4-6": sonnet,
        "claude-sonnet-4-5": sonnet,
        "claude-sonnet-4": sonnet,
        "claude-haiku-4-5": ModelPrice(inputPerMTok: 1, outputPerMTok: 5,
                                       cacheWritePerMTok: 1.25, cacheReadPerMTok: 0.10),
        "claude-haiku-3-5": ModelPrice(inputPerMTok: 0.80, outputPerMTok: 4,
                                       cacheWritePerMTok: 1.00, cacheReadPerMTok: 0.08),
    ]

    private static let opus4x = ModelPrice(inputPerMTok: 5, outputPerMTok: 25,
                                           cacheWritePerMTok: 6.25, cacheReadPerMTok: 0.50)
    private static let opus4Legacy = ModelPrice(inputPerMTok: 15, outputPerMTok: 75,
                                                cacheWritePerMTok: 18.75, cacheReadPerMTok: 1.50)
    private static let sonnet = ModelPrice(inputPerMTok: 3, outputPerMTok: 15,
                                           cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.30)
}
