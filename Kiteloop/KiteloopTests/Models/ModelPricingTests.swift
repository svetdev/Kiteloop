import XCTest
@testable import Kiteloop

/// The price table exists so spend stops being a single frozen number. What is
/// worth pinning down is therefore every way it could quietly become one again:
/// a rate change that doesn't change the total, a model that resolves to the
/// wrong row, and an unpriced model reported as free rather than as unpriced.
final class ModelPricingTests: XCTestCase {

    /// Mid-August 2026 — inside the first revision's window.
    private let august = Date(timeIntervalSince1970: 1_786_000_000)   // 2026-08-14
    /// Mid-September 2026 — after Sonnet 5's introductory pricing ends.
    private let september = Date(timeIntervalSince1970: 1_789_000_000) // 2026-09-18

    private let usage = TokenUsage(inputTokens: 1_000, outputTokens: 2_000,
                                   cacheCreationTokens: 4_000, cacheReadTokens: 100_000)

    // MARK: - Model keys

    /// The same model reaches the table under every spelling it arrives in: the
    /// CLI's concrete id, a Bedrock inference profile, a dated full id, and the
    /// bare family alias an agent config holds.
    func testEverySpellingOfAModelResolvesToTheSameRow() {
        XCTAssertEqual(ModelPriceTable.key(for: "claude-opus-5"), "claude-opus-5")
        XCTAssertEqual(ModelPriceTable.key(for: "us.anthropic.claude-opus-4-8-v1:0"), "claude-opus-4-8")
        XCTAssertEqual(ModelPriceTable.key(for: "claude-haiku-4-5-20251001"), "claude-haiku-4-5")
        XCTAssertEqual(ModelPriceTable.key(for: "opus"), "claude-opus-5-5")
        XCTAssertEqual(ModelPriceTable.key(for: "sonnet"), "claude-sonnet-5")
    }

    /// The releases the CLI's aliases launch today have rows of their own: Opus
    /// 5.5 and Fable 5.1 are not priced as the Opus 5 and Fable 5 they follow,
    /// and a bare alias prices at what it launches.
    func testTheCurrentOpusAndFableHaveTheirOwnRows() throws {
        XCTAssertEqual(ModelPriceTable.key(for: "claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertEqual(ModelPriceTable.key(for: "claude-fable-5-1"), "claude-fable-5-1")
        XCTAssertEqual(ModelPriceTable.key(for: "claude-fable-5"), "claude-fable-5")
        XCTAssertEqual(ModelPriceTable.key(for: "fable"), "claude-fable-5-1")
        let cost = try XCTUnwrap(ModelPriceTable.current.cost(
            of: TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheCreationTokens: 0, cacheReadTokens: 0),
            model: "claude-opus-5-5", on: august))
        XCTAssertEqual(cost.usd, 24.0, accuracy: 0.000_001, "$4 in + $20 out per million")
    }

    /// `claude-opus-4` is a prefix of `claude-opus-4-8`. The longer row has to
    /// win, or every Opus 4.x turn would be priced at the retired Opus 4 rate —
    /// three times too high, and silently.
    func testTheMoreSpecificRowWinsOverItsPrefix() throws {
        XCTAssertEqual(ModelPriceTable.key(for: "claude-opus-4-8"), "claude-opus-4-8")
        XCTAssertEqual(ModelPriceTable.key(for: "claude-opus-4-20250514"), "claude-opus-4")

        let table = ModelPriceTable.current
        let modern = try XCTUnwrap(table.cost(of: usage, model: "claude-opus-4-8", on: august))
        let legacy = try XCTUnwrap(table.cost(of: usage, model: "claude-opus-4-20250514", on: august))
        XCTAssertEqual(legacy.usd, modern.usd * 3, accuracy: 0.000_001)
    }

    /// A local model has no per-token dollar rate here. It resolves to no row,
    /// and so to no derived cost — reporting $0.00 would claim it was free.
    func testAnUnpricedModelYieldsNoDerivedCostRatherThanZero() {
        XCTAssertNil(ModelPriceTable.key(for: "llama3.1"))
        XCTAssertNil(ModelPriceTable.key(for: "qwen2.5-coder"))
        XCTAssertNil(ModelPriceTable.current.cost(of: usage, model: "llama3.1", on: august))
        XCTAssertNil(ModelPriceTable.current.cost(of: usage, model: "", on: august))
    }

    /// A concrete id the table has no row for must resolve to no row at all —
    /// not to the family's current flagship. `claude-3-opus-20240229` mentions
    /// "opus" but is a retired model with its own, much lower rate; a release
    /// newer than every row (`us.anthropic.claude-opus-4-9-v1:0`, say) is
    /// simply unknown. Both must report no derived cost, not today's flagship
    /// rate mispriced as if it were theirs.
    func testAConcreteIdMissingFromTheTableIsUnpricedNotFlagship() {
        XCTAssertNil(ModelPriceTable.key(for: "claude-3-opus-20240229"))
        XCTAssertNil(ModelPriceTable.key(for: "us.anthropic.claude-opus-4-9-v1:0"))
        XCTAssertNil(ModelPriceTable.current.cost(of: usage, model: "claude-3-opus-20240229", on: august))
        XCTAssertNil(ModelPriceTable.current.cost(of: usage, model: "us.anthropic.claude-opus-4-9-v1:0", on: august))
    }

    // MARK: - Deriving the cost

    /// The arithmetic, category by category. Cache reads dominate the token
    /// count here and are the smallest share of the bill — which is the whole
    /// reason the counters are kept apart instead of summed into one "input".
    func testCostIsDerivedPerBillingCategory() throws {
        let priced = try XCTUnwrap(ModelPriceTable.current.cost(of: usage, model: "claude-opus-5", on: august))
        // 1k @ $5 + 2k @ $25 + 4k @ $6.25 + 100k @ $0.50, per MTok.
        let input: Double = 1_000 * 5
        let output: Double = 2_000 * 25
        let cacheWrite: Double = 4_000 * 6.25
        let cacheRead: Double = 100_000 * 0.50
        let expected = (input + output + cacheWrite + cacheRead) / 1_000_000
        XCTAssertEqual(priced.usd, expected, accuracy: 0.000_001)
        XCTAssertEqual(priced.modelKey, "claude-opus-5")
        XCTAssertEqual(priced.priceVersion, "2026-08-08")
    }

    /// Cache reads are billed at a tenth of base input. A run that reads its
    /// context from cache instead of paying full price for it costs materially
    /// less for identical token counts — the lever the hit rate exposes.
    func testCacheReadsCostAFractionOfUncachedInput() throws {
        let cached = TokenUsage(inputTokens: 1_000, cacheReadTokens: 100_000)
        let uncached = TokenUsage(inputTokens: 101_000)
        let table = ModelPriceTable.current

        let cachedCost = try XCTUnwrap(table.cost(of: cached, model: "claude-opus-5", on: august)).usd
        let uncachedCost = try XCTUnwrap(table.cost(of: uncached, model: "claude-opus-5", on: august)).usd
        XCTAssertLessThan(cachedCost, uncachedCost / 3)
    }

    // MARK: - Effective dates

    /// The property the version exists for: the same usage, priced against the
    /// card in force on two different dates, gives two different totals — and
    /// each says which card it used. Without this, a published rate change makes
    /// all history incomparable with everything after it, silently.
    func testRepricingAtAChangedRateProducesADifferentTotal() throws {
        let table = ModelPriceTable.current
        let intro = try XCTUnwrap(table.cost(of: usage, model: "claude-sonnet-5", on: august))
        let standard = try XCTUnwrap(table.cost(of: usage, model: "claude-sonnet-5", on: september))

        XCTAssertEqual(intro.priceVersion, "2026-08-08")
        XCTAssertEqual(standard.priceVersion, "2026-09-01")
        XCTAssertGreaterThan(standard.usd, intro.usd)
        // Sonnet 5's standard card is 1.5× its introductory one across the board.
        XCTAssertEqual(standard.usd, intro.usd * 1.5, accuracy: 0.000_001)
    }

    /// A model whose rate did not move prices identically on both sides of the
    /// revision boundary — a new revision re-issues the whole card, and must not
    /// perturb the rows it did not change.
    func testARevisionOnlyMovesTheRatesItChanges() throws {
        let table = ModelPriceTable.current
        let before = try XCTUnwrap(table.cost(of: usage, model: "claude-opus-5", on: august))
        let after = try XCTUnwrap(table.cost(of: usage, model: "claude-opus-5", on: september))
        XCTAssertEqual(before.usd, after.usd, accuracy: 0.000_001)
        XCTAssertNotEqual(before.priceVersion, after.priceVersion)
    }

    /// History predates the day this table was compiled. Such a run is priced at
    /// the earliest card on record — a stated approximation — rather than left
    /// unpriced, which would just re-create the blind spot the table is for.
    func testARunPredatingTheTableIsPricedAtTheEarliestCard() throws {
        let ancient = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11
        let priced = try XCTUnwrap(ModelPriceTable.current.cost(of: usage, model: "claude-opus-5", on: ancient))
        XCTAssertEqual(priced.priceVersion, "2026-08-08")
    }

    /// The boundary is inclusive of its own effective date.
    func testARevisionAppliesFromItsEffectiveDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let effective = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))

        let table = ModelPriceTable.current
        XCTAssertEqual(try XCTUnwrap(table.revision(on: effective)).version, "2026-09-01")
        XCTAssertEqual(try XCTUnwrap(table.revision(on: effective.addingTimeInterval(-1))).version, "2026-08-08")
    }

    // MARK: - TokenUsage

    /// `input_tokens` is the uncached remainder only, so the hit rate is taken
    /// over all three input counters. Over `inputTokens` alone a well-cached run
    /// would read as a near-100% miss.
    func testCacheHitRateIsTakenOverTheWholePrompt() {
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 9_999,
                               cacheCreationTokens: 1_000, cacheReadTokens: 8_000)
        XCTAssertEqual(usage.promptTokens, 10_000)
        XCTAssertEqual(try XCTUnwrap(usage.cacheHitRate), 0.8, accuracy: 0.000_001)
        XCTAssertEqual(usage.cacheHitRateText, "80%")
        // Output is not part of the prompt and must not dilute the rate.
        XCTAssertEqual(usage.totalTokens, 19_999)
    }

    /// No prompt token observed is "not measured", not a 0% cache — the two read
    /// identically on a dashboard and mean opposite things.
    func testCacheHitRateIsUnmeasuredRatherThanZeroWithNoPromptTokens() {
        XCTAssertNil(TokenUsage.zero.cacheHitRate)
        XCTAssertEqual(TokenUsage.zero.cacheHitRateText, "not measured")
        XCTAssertNotNil(TokenUsage(cacheCreationTokens: 1).cacheHitRate)
    }

    func testUsagesSumCounterByCounter() {
        let total = TokenUsage(inputTokens: 1, outputTokens: 2, cacheCreationTokens: 3, cacheReadTokens: 4)
            + TokenUsage(inputTokens: 10, outputTokens: 20, cacheCreationTokens: 30, cacheReadTokens: 40)
        XCTAssertEqual(total, TokenUsage(inputTokens: 11, outputTokens: 22,
                                         cacheCreationTokens: 33, cacheReadTokens: 44))
    }
}
