import XCTest
@testable import Kiteloop

/// Covers the pure hybrid blend in `TaskScopingEngine.resolve` — which of the
/// two inputs (size-matched history, the LLM's rough guess) wins, and what
/// comes out when one or both are missing.
@MainActor
final class TaskScopingEngineTests: XCTestCase {

    private func summary(
        samples: Int,
        duration: Double = 600,
        cost: Double = 0.5,
        retries: Double = 1
    ) -> TaskMetricSummary {
        TaskMetricSummary(
            sampleCount: samples,
            avgDurationSeconds: duration,
            avgCostUSD: cost,
            avgReviewerRetries: retries
        )
    }

    // MARK: - History only

    /// Enough size-matched history and nothing from the LLM but a confidence:
    /// every number comes from the actuals, including a cost (which the LLM
    /// never supplies).
    func testHistoryOnlyUsesEmpiricalNumbers() {
        let resolved = TaskScopingEngine.resolve(
            llmConfidence: 0.6,
            roughMinutes: nil,
            llmRetries: nil,
            summary: summary(samples: 4, duration: 900, cost: 0.75, retries: 1.4),
            minSamples: 3
        )

        XCTAssertEqual(resolved.duration, 900, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(resolved.cost), 0.75, accuracy: 0.001)
        XCTAssertEqual(resolved.retries, 1)                        // 1.4 rounds down
        // sampleConfidence = 4/8 = 0.5, blended with the LLM's 0.6.
        XCTAssertEqual(resolved.confidence, 0.55, accuracy: 0.001)
    }

    /// History wins even when the LLM did offer numbers — the empirical average
    /// is never averaged with the guess.
    func testHistoryOverridesLLMNumbers() {
        let resolved = TaskScopingEngine.resolve(
            llmConfidence: 0.9,
            roughMinutes: 5,
            llmRetries: 4,
            summary: summary(samples: 3, duration: 1200, cost: 0.9, retries: 2),
            minSamples: 3
        )

        XCTAssertEqual(resolved.duration, 1200, accuracy: 0.001)   // not 5 * 60
        XCTAssertEqual(try XCTUnwrap(resolved.cost), 0.9, accuracy: 0.001)
        XCTAssertEqual(resolved.retries, 2)                        // not the LLM's 4
    }

    /// `minSamples` is the inclusive threshold: one sample short falls back to
    /// the LLM, exactly at the threshold uses history.
    func testSampleCountThresholdIsInclusive() {
        let sparse = TaskScopingEngine.resolve(
            llmConfidence: 0.5,
            roughMinutes: 10,
            llmRetries: 1,
            summary: summary(samples: 2, duration: 1200, cost: 0.9),
            minSamples: 3
        )
        XCTAssertEqual(sparse.duration, 600, accuracy: 0.001)      // the LLM's 10m
        XCTAssertNil(sparse.cost)

        let enough = TaskScopingEngine.resolve(
            llmConfidence: 0.5,
            roughMinutes: 10,
            llmRetries: 1,
            summary: summary(samples: 3, duration: 1200, cost: 0.9),
            minSamples: 3
        )
        XCTAssertEqual(enough.duration, 1200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(enough.cost), 0.9, accuracy: 0.001)
    }

    /// Sample confidence saturates at 8 samples, so a big history plus a
    /// certain LLM can reach 1.0 — and can't exceed it.
    func testSampleConfidenceSaturatesAtEightSamples() {
        let atCap = TaskScopingEngine.resolve(
            llmConfidence: 1.0, roughMinutes: nil, llmRetries: nil,
            summary: summary(samples: 8), minSamples: 3
        )
        let wellPast = TaskScopingEngine.resolve(
            llmConfidence: 1.0, roughMinutes: nil, llmRetries: nil,
            summary: summary(samples: 80), minSamples: 3
        )

        XCTAssertEqual(atCap.confidence, 1.0, accuracy: 0.001)
        XCTAssertEqual(wellPast.confidence, 1.0, accuracy: 0.001)
    }

    // MARK: - Estimate only

    /// No history at all: the LLM's rough guess is used verbatim, with no cost
    /// (there's nothing to base one on) and confidence discounted to 40%.
    func testEstimateOnlyUsesRoughMinutesAtReducedConfidence() {
        let resolved = TaskScopingEngine.resolve(
            llmConfidence: 0.75,
            roughMinutes: 20,
            llmRetries: 2,
            summary: nil,
            minSamples: 3
        )

        XCTAssertEqual(resolved.duration, 1200, accuracy: 0.001)   // 20m
        XCTAssertNil(resolved.cost)
        XCTAssertEqual(resolved.retries, 2)
        XCTAssertEqual(resolved.confidence, 0.3, accuracy: 0.001)  // 0.75 * 0.4
    }

    /// An empty summary (a size bucket with no records) is as good as no
    /// summary — it must not produce a zero-duration, zero-cost estimate.
    func testZeroSampleSummaryFallsBackToEstimate() {
        let resolved = TaskScopingEngine.resolve(
            llmConfidence: 0.5,
            roughMinutes: 8,
            llmRetries: 1,
            summary: summary(samples: 0, duration: 0, cost: 0, retries: 0),
            minSamples: 3
        )

        XCTAssertEqual(resolved.duration, 480, accuracy: 0.001)
        XCTAssertNil(resolved.cost)
    }

    /// An implausibly small guess is floored at a minute so callers never get a
    /// near-zero ETA.
    func testTinyRoughMinutesIsFlooredAtOneMinute() {
        for minutes in [0.0, 0.5, 1.0] {
            let resolved = TaskScopingEngine.resolve(
                llmConfidence: 0.5, roughMinutes: minutes, llmRetries: nil,
                summary: nil, minSamples: 3
            )
            XCTAssertEqual(resolved.duration, 60, accuracy: 0.001, "roughMinutes: \(minutes)")
        }
    }

    // MARK: - Empty

    /// Neither history nor a rough guess: a sane 15-minute default, no cost, no
    /// retry prediction, and near-zero confidence.
    func testEmptyInputsFallBackToFifteenMinuteDefault() {
        let resolved = TaskScopingEngine.resolve(
            llmConfidence: 0,
            roughMinutes: nil,
            llmRetries: nil,
            summary: nil,
            minSamples: 3
        )

        XCTAssertEqual(resolved.duration, 900, accuracy: 0.001)    // 15m
        XCTAssertNil(resolved.cost)
        XCTAssertNil(resolved.retries)
        XCTAssertEqual(resolved.confidence, 0, accuracy: 0.001)
    }

    /// The default duration is independent of the LLM's confidence — only the
    /// confidence field tracks it.
    func testEmptyDefaultIgnoresConfidence() {
        let unsure = TaskScopingEngine.resolve(
            llmConfidence: 0.1, roughMinutes: nil, llmRetries: nil, summary: nil, minSamples: 3
        )
        let certain = TaskScopingEngine.resolve(
            llmConfidence: 1.0, roughMinutes: nil, llmRetries: nil, summary: nil, minSamples: 3
        )

        XCTAssertEqual(unsure.duration, certain.duration, accuracy: 0.001)
        XCTAssertEqual(unsure.confidence, 0.04, accuracy: 0.001)
        XCTAssertEqual(certain.confidence, 0.4, accuracy: 0.001)
    }
}
