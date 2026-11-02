import XCTest
@testable import Kiteloop

@MainActor
final class TaskLearningEngineTests: XCTestCase {

    private func tempURLs() -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        return (dir.appendingPathComponent("metrics-\(id).jsonl"),
                dir.appendingPathComponent("estimates-\(id).jsonl"))
    }

    private func record(
        itemID: String = "t-1",
        project: String = "/tmp/proj",
        size: String? = "M",
        epic: String? = "Epic A",
        duration: Double = 480,
        cost: Double = 0.40,
        retries: Int = 1,
        outcome: String = "done"
    ) -> TaskMetricRecord {
        let start = Date()
        return TaskMetricRecord(
            projectPath: project, projectName: "proj", itemID: itemID, title: "Task \(itemID)",
            epic: epic, declaredSize: size, startedAt: start,
            completedAt: start.addingTimeInterval(duration), durationSeconds: duration,
            costUSD: cost, reviewerRetries: retries, outcome: outcome,
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "e-1", toolErrors: nil
        )
    }

    func testMetricStoreRoundTrip() {
        let (m, e) = tempURLs()
        defer { try? FileManager.default.removeItem(at: m); try? FileManager.default.removeItem(at: e) }

        let store = TaskMetricStore(metricsURL: m, estimatesURL: e)
        store.append(record(itemID: "round-1", duration: 600, cost: 0.5, retries: 2))

        // A fresh store over the same files must see the persisted record.
        let reloaded = TaskMetricStore(metricsURL: m, estimatesURL: e)
        XCTAssertEqual(reloaded.records.count, 1)
        let r = try! XCTUnwrap(reloaded.latestActual(itemID: "round-1"))
        XCTAssertEqual(r.durationSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(r.costUSD, 0.5, accuracy: 0.001)
        XCTAssertEqual(r.reviewerRetries, 2)
        XCTAssertEqual(r.declaredSize, "M")
    }

    func testSummariesBySizeAveraging() {
        let (m, e) = tempURLs()
        defer { try? FileManager.default.removeItem(at: m); try? FileManager.default.removeItem(at: e) }
        let store = TaskMetricStore(metricsURL: m, estimatesURL: e)

        store.append(record(itemID: "a", size: "M", duration: 400, cost: 0.2))
        store.append(record(itemID: "b", size: "M", duration: 600, cost: 0.4))
        store.append(record(itemID: "c", size: "S", duration: 120, cost: 0.1))

        let summaries = store.summariesBySize(projectPath: "/tmp/proj")
        // Sorted by size rank: S before M.
        XCTAssertEqual(summaries.map(\.size), ["S", "M"])
        let mSummary = try! XCTUnwrap(summaries.first { $0.size == "M" }?.summary)
        XCTAssertEqual(mSummary.sampleCount, 2)
        XCTAssertEqual(mSummary.avgDurationSeconds, 500, accuracy: 0.001)
        XCTAssertEqual(mSummary.avgCostUSD, 0.3, accuracy: 0.001)
    }

    func testSummaryPrefersProjectThenFallsBackGlobal() {
        let (m, e) = tempURLs()
        defer { try? FileManager.default.removeItem(at: m); try? FileManager.default.removeItem(at: e) }
        let store = TaskMetricStore(metricsURL: m, estimatesURL: e)

        // One M in project A, three M in project B.
        store.append(record(itemID: "a1", project: "/A", size: "M", duration: 1000))
        for i in 0..<3 { store.append(record(itemID: "b\(i)", project: "/B", size: "M", duration: 200)) }

        // Project A has < minProjectSamples (3) → global average over all 4.
        let a = try! XCTUnwrap(store.summary(forSize: "M", projectPath: "/A", minProjectSamples: 3))
        XCTAssertEqual(a.sampleCount, 4)

        // Project B has exactly 3 → uses its own.
        let b = try! XCTUnwrap(store.summary(forSize: "M", projectPath: "/B", minProjectSamples: 3))
        XCTAssertEqual(b.sampleCount, 3)
        XCTAssertEqual(b.avgDurationSeconds, 200, accuracy: 0.001)
    }

    func testCalibrationPairsEstimateWithActual() {
        let (m, e) = tempURLs()
        defer { try? FileManager.default.removeItem(at: m); try? FileManager.default.removeItem(at: e) }
        let store = TaskMetricStore(metricsURL: m, estimatesURL: e)

        store.appendEstimate(TaskEstimate(
            itemID: "cal-1", projectPath: "/tmp/proj", createdAt: Date(),
            estimatedSize: "M", predictedDurationSeconds: 300, predictedCostUSD: 0.2,
            predictedRetries: 1, confidence: 0.5, source: "hybrid", rationale: "test"
        ))
        store.append(record(itemID: "cal-1", duration: 360))

        let pairs = store.calibration(projectPath: "/tmp/proj")
        XCTAssertEqual(pairs.count, 1)
        let pair = try! XCTUnwrap(pairs.first)
        XCTAssertEqual(pair.estimate.predictedDurationSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(pair.actual.durationSeconds, 360, accuracy: 0.001)
    }

    func testResolveUsesEmpiricalWhenEnoughSamples() {
        let summary = TaskMetricSummary(sampleCount: 8, avgDurationSeconds: 720, avgCostUSD: 0.6, avgReviewerRetries: 2)
        let resolved = TaskScopingEngine.resolve(
            llmConfidence: 0.5, roughMinutes: 5, llmRetries: 0, summary: summary, minSamples: 3
        )
        XCTAssertEqual(resolved.duration, 720, accuracy: 0.001)   // empirical, not 5m
        XCTAssertEqual(resolved.cost ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(resolved.retries, 2)
        XCTAssertEqual(resolved.confidence, 0.75, accuracy: 0.001) // (1.0 + 0.5)/2
    }

    func testResolveFallsBackToLLMWhenSparse() {
        let resolved = TaskScopingEngine.resolve(
            llmConfidence: 0.5, roughMinutes: 10, llmRetries: 1, summary: nil, minSamples: 3
        )
        XCTAssertEqual(resolved.duration, 600, accuracy: 0.001)   // 10m fallback
        XCTAssertNil(resolved.cost)
        XCTAssertEqual(resolved.retries, 1)
        XCTAssertEqual(resolved.confidence, 0.2, accuracy: 0.001) // 0.5 * 0.4
    }
}
