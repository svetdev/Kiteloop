// Kiteloop/KiteloopTests/Models/TaskMetricCodableTests.swift
import XCTest
import KiteloopCore
@testable import Kiteloop

/// `TaskMetricRecord` and `TaskEstimate` are the on-disk format of
/// `~/.kiteloop/task-metrics.jsonl` and `task-estimates.jsonl` — append-only logs the
/// learning engine, Insights and the control server read back on every launch.
/// `TaskMetricStore.load` decodes leniently (`try?` per line), so any Codable change
/// that breaks an existing line silently *drops* that history instead of failing loudly.
/// These tests pin the round-trip guarantees, the key names, and which fields older
/// lines are allowed to be missing — with the judge fields (`qualityScore` /
/// `judgeDimensions`, added after the first metrics were written) called out explicitly.
final class TaskMetricCodableTests: XCTestCase {

    // MARK: - Helpers

    /// Mirrors `TaskMetricStore.makeEncoder/makeDecoder` — the coders that touch disk.
    private func storeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func storeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The store's encoder emits keys in an unspecified order (no `.sortedKeys`), so
    /// byte-level comparisons need a canonicalised form.
    private func canonicalEncoder() -> JSONEncoder {
        let encoder = storeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try storeDecoder().decode(T.self, from: storeEncoder().encode(value))
    }

    private func keys<T: Encodable>(of value: T) throws -> Set<String> {
        let data = try storeEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    /// A fully-populated record: every optional set, judge fields included.
    private func fullRecord(
        startedAt: Date = Date(timeIntervalSince1970: 1_785_846_896) // 2026-08-04T12:34:56Z
    ) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: "/Users/dev/proj",
            projectName: "proj",
            itemID: "test-taskmetric-codable",
            title: "Unit test TaskMetricRecord Codable",
            epic: "Quality",
            declaredSize: "M",
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(480),
            durationSeconds: 480,
            costUSD: 0.42,
            reviewerRetries: 1,
            outcome: "done",
            workerAgent: "worker",
            reviewerAgent: "reviewer",
            executionID: "exec-1",
            toolErrors: 3
        )
        record.qualityScore = 0.87
        record.judgeDimensions = [
            "verify_passed": 1.0,
            "scope_respected": 0.9,
            "tests_meaningful": 0.8,
            "conventions": 0.75
        ]
        record.qualityScoreDiffTruncated = false
        return record
    }

    /// The same record as a real autopilot writes it before the judge runs:
    /// every optional nil.
    private func minimalRecord() -> TaskMetricRecord {
        TaskMetricRecord(
            projectPath: "/Users/dev/proj",
            projectName: "proj",
            itemID: "t-1",
            title: "Task",
            epic: nil,
            declaredSize: nil,
            startedAt: Date(timeIntervalSince1970: 1_785_846_896),
            completedAt: Date(timeIntervalSince1970: 1_785_847_000),
            durationSeconds: 104,
            costUSD: 0,
            reviewerRetries: 0,
            outcome: "failed",
            workerAgent: nil,
            reviewerAgent: nil,
            executionID: nil,
            toolErrors: nil
        )
    }

    private func fullEstimate(
        createdAt: Date = Date(timeIntervalSince1970: 1_785_846_896)
    ) -> TaskEstimate {
        TaskEstimate(
            itemID: "test-taskmetric-codable",
            projectPath: "/Users/dev/proj",
            createdAt: createdAt,
            estimatedSize: "M",
            predictedDurationSeconds: 540,
            predictedCostUSD: 0.35,
            predictedRetries: 1,
            confidence: 0.66,
            source: "hybrid",
            rationale: "3 comparable M tasks in this project"
        )
    }

    // MARK: - TaskMetricRecord round-trip

    func testRecordRoundTripPreservesEveryField() throws {
        let record = fullRecord()

        let decoded = try roundTrip(record)

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.projectPath, "/Users/dev/proj")
        XCTAssertEqual(decoded.projectName, "proj")
        XCTAssertEqual(decoded.itemID, "test-taskmetric-codable")
        XCTAssertEqual(decoded.title, "Unit test TaskMetricRecord Codable")
        XCTAssertEqual(decoded.epic, "Quality")
        XCTAssertEqual(decoded.declaredSize, "M")
        XCTAssertEqual(decoded.startedAt, record.startedAt)
        XCTAssertEqual(decoded.completedAt, record.completedAt)
        XCTAssertEqual(decoded.durationSeconds, 480, accuracy: 0.000_001)
        XCTAssertEqual(decoded.costUSD, 0.42, accuracy: 0.000_001)
        XCTAssertEqual(decoded.reviewerRetries, 1)
        XCTAssertEqual(decoded.outcome, "done")
        XCTAssertEqual(decoded.workerAgent, "worker")
        XCTAssertEqual(decoded.reviewerAgent, "reviewer")
        XCTAssertEqual(decoded.executionID, "exec-1")
        XCTAssertEqual(decoded.toolErrors, 3)
        XCTAssertEqual(try XCTUnwrap(decoded.qualityScore), 0.87, accuracy: 0.000_001)
        XCTAssertEqual(decoded.judgeDimensions, record.judgeDimensions)
        XCTAssertEqual(decoded.qualityScoreDiffTruncated, false)
    }

    func testRecordRoundTripKeepsNilOptionalsNil() throws {
        let decoded = try roundTrip(minimalRecord())

        XCTAssertNil(decoded.epic)
        XCTAssertNil(decoded.declaredSize)
        XCTAssertNil(decoded.workerAgent)
        XCTAssertNil(decoded.reviewerAgent)
        XCTAssertNil(decoded.executionID)
        XCTAssertNil(decoded.toolErrors)
        // A run the judge skipped must stay "unscored", not become 0.
        XCTAssertNil(decoded.qualityScore)
        XCTAssertNil(decoded.judgeDimensions)
        XCTAssertNil(decoded.qualityScoreDiffTruncated)
    }

    func testRecordRoundTripDistinguishesEmptyJudgeDimensionsFromNil() throws {
        // `RunQualityJudge.parse` can return an `overall` with no per-dimension scores.
        var record = fullRecord()
        record.judgeDimensions = [:]

        let decoded = try roundTrip(record)

        XCTAssertEqual(decoded.judgeDimensions, [:])
        XCTAssertNotNil(decoded.judgeDimensions)
    }

    func testRecordRoundTripPreservesJudgeScorePrecisionAndBounds() throws {
        // `overall` is often a mean of the dimensions, so it is rarely a round number.
        var record = fullRecord()
        record.qualityScore = 2.0 / 3.0
        record.judgeDimensions = ["verify_passed": 1.0, "scope_respected": 0.0, "conventions": 1.0 / 3.0]

        let decoded = try roundTrip(record)

        XCTAssertEqual(try XCTUnwrap(decoded.qualityScore), 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(decoded.judgeDimensions?["verify_passed"]), 1.0, accuracy: 1e-12)
        // The 0 lower bound must survive as 0, not vanish into nil.
        XCTAssertEqual(try XCTUnwrap(decoded.judgeDimensions?["scope_respected"]), 0.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(decoded.judgeDimensions?["conventions"]), 1.0 / 3.0, accuracy: 1e-12)
    }

    func testRecordRoundTripPreservesUnknownJudgeDimensionKeys() throws {
        // `judgeDimensions` is an open map — adding a rubric dimension must not need a
        // model change, and old readers must keep the ones they don't know about.
        var record = fullRecord()
        record.judgeDimensions = ["conventions": 0.5, "docs_updated": 0.25]

        let decoded = try roundTrip(record)

        XCTAssertEqual(decoded.judgeDimensions, ["conventions": 0.5, "docs_updated": 0.25])
    }

    func testRecordCarriesJudgeVerdictDimensionsUnchanged() throws {
        // End-to-end shape check: what `RunQualityJudge.parse` produces is what
        // `BacklogAutopilot` assigns and the store persists.
        // `parse` returns a `Judgement` — a verdict *or* the reason there isn't
        // one — so the score is read off `.verdict`.
        let verdict = try XCTUnwrap(RunQualityJudge.parse("""
        {"verify_passed": 1, "scope_respected": 0.9, "tests_meaningful": 0.8,
         "conventions": 0.7, "overall": 0.85, "rationale": "solid"}
        """).verdict)
        var record = minimalRecord()
        record.qualityScore = verdict.overall
        record.judgeDimensions = verdict.dimensions

        let decoded = try roundTrip(record)

        XCTAssertEqual(try XCTUnwrap(decoded.qualityScore), 0.85, accuracy: 1e-12)
        XCTAssertEqual(decoded.judgeDimensions, verdict.dimensions)
        XCTAssertEqual(
            Set(try XCTUnwrap(decoded.judgeDimensions).keys),
            ["verify_passed", "scope_respected", "tests_meaningful", "conventions"]
        )
    }

    func testRecordRoundTripPreservesDatesToTheSecondUnderISO8601() throws {
        // `.iso8601` drops fractional seconds — durations are stored explicitly rather
        // than recomputed from the timestamps, so only second-accuracy is guaranteed here.
        let now = Date()
        var record = fullRecord(startedAt: now)
        record.qualityScore = nil

        let decoded = try roundTrip(record)

        XCTAssertLessThan(abs(decoded.startedAt.timeIntervalSince(now)), 1.0)
        XCTAssertLessThan(abs(decoded.completedAt.timeIntervalSince(now.addingTimeInterval(480))), 1.0)
        // The recorded duration itself keeps full precision.
        XCTAssertEqual(decoded.durationSeconds, record.durationSeconds, accuracy: 0.000_001)
    }

    func testRecordRoundTripIsStableAcrossRepeatedEncodes() throws {
        let once = try roundTrip(fullRecord())
        let twice = try roundTrip(once)

        XCTAssertEqual(twice.id, once.id)
        XCTAssertEqual(twice.startedAt, once.startedAt)
        XCTAssertEqual(twice.completedAt, once.completedAt)
        XCTAssertEqual(twice.qualityScore, once.qualityScore)
        XCTAssertEqual(twice.judgeDimensions, once.judgeDimensions)
        XCTAssertEqual(try canonicalEncoder().encode(twice), try canonicalEncoder().encode(once))
    }

    // MARK: - TaskMetricRecord on-disk format

    func testEncodedRecordUsesExpectedKeys() throws {
        XCTAssertEqual(
            try keys(of: fullRecord()),
            [
                "id", "projectPath", "projectName", "itemID", "title", "epic", "declaredSize",
                "startedAt", "completedAt", "durationSeconds", "costUSD", "reviewerRetries",
                "outcome", "workerAgent", "reviewerAgent", "executionID", "toolErrors",
                "qualityScore", "judgeDimensions", "qualityScoreDiffTruncated"
            ]
        )
    }

    func testEncodedRecordOmitsNilOptionals() throws {
        XCTAssertEqual(
            try keys(of: minimalRecord()),
            [
                "id", "projectPath", "projectName", "itemID", "title",
                "startedAt", "completedAt", "durationSeconds", "costUSD", "reviewerRetries", "outcome"
            ]
        )
    }

    func testEncodedRecordFitsOnOneJSONLLine() throws {
        // `TaskMetricStore.appendLine` appends "\n" and `load` splits on newlines, so a
        // literal newline in an encoded record would corrupt the log from that point on.
        var record = fullRecord()
        record = TaskMetricRecord(
            projectPath: record.projectPath,
            projectName: record.projectName,
            itemID: record.itemID,
            title: "Fix crash\nin parser\r\nand log it",
            epic: "Bugs\nand chores",
            declaredSize: record.declaredSize,
            startedAt: record.startedAt,
            completedAt: record.completedAt,
            durationSeconds: record.durationSeconds,
            costUSD: record.costUSD,
            reviewerRetries: record.reviewerRetries,
            outcome: record.outcome,
            workerAgent: record.workerAgent,
            reviewerAgent: record.reviewerAgent,
            executionID: record.executionID,
            toolErrors: record.toolErrors
        )

        let line = try XCTUnwrap(String(data: storeEncoder().encode(record), encoding: .utf8))

        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))

        let decoded = try storeDecoder().decode(TaskMetricRecord.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.title, "Fix crash\nin parser\r\nand log it")
        XCTAssertEqual(decoded.epic, "Bugs\nand chores")
    }

    func testEncodedRecordPreservesUnicodeTitles() throws {
        var record = minimalRecord()
        record = TaskMetricRecord(
            projectPath: "/Users/dev/proj — café", projectName: "café ☕️", itemID: "t-1",
            title: #"Ship "it" \ now — 完了"#, epic: nil, declaredSize: nil,
            startedAt: record.startedAt, completedAt: record.completedAt,
            durationSeconds: record.durationSeconds, costUSD: record.costUSD,
            reviewerRetries: record.reviewerRetries, outcome: record.outcome,
            workerAgent: nil, reviewerAgent: nil, executionID: nil, toolErrors: nil
        )

        let decoded = try roundTrip(record)

        XCTAssertEqual(decoded.title, #"Ship "it" \ now — 完了"#)
        XCTAssertEqual(decoded.projectName, "café ☕️")
        XCTAssertEqual(decoded.projectPath, "/Users/dev/proj — café")
    }

    func testDecodesLegacyRecordWrittenBeforeTheJudgeExisted() throws {
        // A line as it appears in an existing `~/.kiteloop/task-metrics.jsonl`, written
        // before `qualityScore` / `judgeDimensions` were added. It must still load.
        let json = """
        {"id":"7A1F0000-0000-0000-0000-000000000001","projectPath":"/Users/dev/proj",\
        "projectName":"proj","itemID":"legacy-1","title":"Old task","epic":"Epic A",\
        "declaredSize":"S","startedAt":"2026-08-04T12:34:56Z","completedAt":"2026-08-04T12:40:56Z",\
        "durationSeconds":360,"costUSD":0.12,"reviewerRetries":0,"outcome":"done",\
        "workerAgent":"worker","reviewerAgent":"reviewer","executionID":"exec-legacy"}
        """

        let decoded = try storeDecoder().decode(TaskMetricRecord.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, "7A1F0000-0000-0000-0000-000000000001")
        XCTAssertEqual(decoded.itemID, "legacy-1")
        XCTAssertEqual(decoded.declaredSize, "S")
        XCTAssertEqual(decoded.startedAt, Date(timeIntervalSince1970: 1_785_846_896))
        XCTAssertEqual(decoded.durationSeconds, 360, accuracy: 0.000_001)
        XCTAssertEqual(decoded.costUSD, 0.12, accuracy: 0.000_001)
        XCTAssertNil(decoded.toolErrors)
        XCTAssertNil(decoded.qualityScore)
        XCTAssertNil(decoded.judgeDimensions)
    }

    func testDecodeRejectsRecordMissingRequiredField() {
        // Dropping `costUSD` from the payload — the store would skip such a line.
        let json = """
        {"id":"m1","projectPath":"/p","projectName":"p","itemID":"i","title":"t",\
        "startedAt":"2026-08-04T12:34:56Z","completedAt":"2026-08-04T12:35:56Z",\
        "durationSeconds":60,"reviewerRetries":0,"outcome":"done"}
        """

        XCTAssertThrowsError(try storeDecoder().decode(TaskMetricRecord.self, from: Data(json.utf8)))
    }

    func testDecodeRequiresIDDespiteItsDefaultValue() {
        // Swift's synthesized `init(from:)` does not fall back to property defaults, so
        // `id` is effectively required on the wire — a line without it is dropped by
        // `TaskMetricStore.load` rather than getting a fresh UUID.
        let json = """
        {"projectPath":"/p","projectName":"p","itemID":"i","title":"t",\
        "startedAt":"2026-08-04T12:34:56Z","completedAt":"2026-08-04T12:35:56Z",\
        "durationSeconds":60,"costUSD":0.1,"reviewerRetries":0,"outcome":"done"}
        """

        XCTAssertThrowsError(try storeDecoder().decode(TaskMetricRecord.self, from: Data(json.utf8)))
    }

    func testEncodingNonFiniteQualityScoreThrows() throws {
        // `RunQualityJudge`'s clamp propagates NaN rather than rejecting it; JSON has no
        // NaN, so such a record would fail to encode and never reach disk.
        var record = fullRecord()
        record.qualityScore = .nan

        XCTAssertThrowsError(try storeEncoder().encode(record))
    }

    // MARK: - Forecast beside actual, and whether the run produced anything

    func testPredictionAndFileCountRoundTripAndAreOmittedWhenUnset() throws {
        var record = minimalRecord()
        record.predictedCostUSD = 2.50
        record.predictionSource = "size band p50"
        record.changedFileCount = 12

        let decoded = try roundTrip(record)
        XCTAssertEqual(try XCTUnwrap(decoded.predictedCostUSD), 2.50, accuracy: 1e-12)
        XCTAssertEqual(decoded.predictionSource, "size band p50")
        XCTAssertEqual(decoded.changedFileCount, 12)
        XCTAssertTrue(try keys(of: record)
            .isSuperset(of: ["predictedCostUSD", "predictionSource", "changedFileCount"]))

        // Unset they stay off the wire, so every line written before this
        // existed keeps its shape.
        XCTAssertTrue(try keys(of: minimalRecord())
            .isDisjoint(with: ["predictedCostUSD", "predictionSource", "changedFileCount"]))
    }

    func testTheCapOverrunRoundTripsAndIsOmittedWhenUnset() throws {
        var over = minimalRecord()
        over.overItemCap = true
        XCTAssertEqual(try roundTrip(over).overItemCap, true)
        XCTAssertTrue(try keys(of: over).contains("overItemCap"))

        // `false` is a measurement too — a run that stayed inside its ceiling —
        // so it goes on the wire rather than being collapsed into the absence
        // that means nobody looked.
        var under = minimalRecord()
        under.overItemCap = false
        XCTAssertEqual(try roundTrip(under).overItemCap, false)
        XCTAssertTrue(try keys(of: under).contains("overItemCap"))

        XCTAssertTrue(try keys(of: minimalRecord()).isDisjoint(with: ["overItemCap"]))
    }

    func testQualityScoreDiffTruncatedRoundTripsAndIsOmittedWhenUnset() throws {
        var truncated = minimalRecord()
        truncated.qualityScoreDiffTruncated = true
        XCTAssertEqual(try roundTrip(truncated).qualityScoreDiffTruncated, true)
        XCTAssertTrue(try keys(of: truncated).contains("qualityScoreDiffTruncated"))

        // `false` is a measurement too — a diff that fit whole — so it goes on
        // the wire rather than being collapsed into the absence that means the
        // judge was never asked.
        var whole = minimalRecord()
        whole.qualityScoreDiffTruncated = false
        XCTAssertEqual(try roundTrip(whole).qualityScoreDiffTruncated, false)
        XCTAssertTrue(try keys(of: whole).contains("qualityScoreDiffTruncated"))

        XCTAssertTrue(try keys(of: minimalRecord()).isDisjoint(with: ["qualityScoreDiffTruncated"]))
    }

    func testALineWithoutTheCapOverrunDecodesAsNilRatherThanFalse() throws {
        // Every line already on disk. Nil is "this run was never asked", which
        // must not read as "this run stayed inside its cap" — the whole point of
        // the field is counting the ones that didn't.
        let json = """
        {"id":"m1","projectPath":"/p","projectName":"p","itemID":"i","title":"t",\
        "startedAt":"2026-08-04T12:34:56Z","completedAt":"2026-08-04T12:35:56Z",\
        "durationSeconds":60,"costUSD":3.5,"reviewerRetries":0,"outcome":"done"}
        """

        let decoded = try storeDecoder().decode(TaskMetricRecord.self, from: Data(json.utf8))
        XCTAssertNil(decoded.overItemCap)
    }

    func testTheWorkersTurnsAndCutShortFlagRoundTrip() throws {
        var record = minimalRecord()
        record.workerTurns = 50
        record.workerCutShort = true
        let decoded = try roundTrip(record)
        XCTAssertEqual(decoded.workerTurns, 50)
        XCTAssertEqual(decoded.workerCutShort, true)
    }

    func testOlderLinesWithoutTheseFieldsStillDecode() throws {
        // The ~280 lines already on disk. They must decode with the new fields
        // nil — an unmeasured forecast, not a forecast of zero.
        let json = """
        {"id":"m1","projectPath":"/p","projectName":"p","itemID":"i","title":"t",\
        "startedAt":"2026-08-04T12:34:56Z","completedAt":"2026-08-04T12:35:56Z",\
        "durationSeconds":60,"costUSD":3.5,"reviewerRetries":0,"outcome":"done"}
        """

        let decoded = try storeDecoder().decode(TaskMetricRecord.self, from: Data(json.utf8))
        XCTAssertNil(decoded.predictedCostUSD)
        XCTAssertNil(decoded.predictionSource)
        XCTAssertNil(decoded.changedFileCount)
        XCTAssertNil(decoded.costPredictionErrorUSD)
        XCTAssertNil(decoded.costPredictionErrorRatio)
        XCTAssertNil(decoded.qualityScoreDiffTruncated)
        XCTAssertNil(decoded.workerTurns)
        XCTAssertNil(decoded.workerCutShort)
        // No file count, and an outcome that says the run finished: still
        // evidence about what its size costs.
        XCTAssertTrue(decoded.producedWork)
    }

    func testTheForecastErrorIsTheActualMinusThePrediction() throws {
        var record = minimalRecord()
        record = try roundTrip(record)
        XCTAssertNil(record.costPredictionErrorUSD, "no forecast ⇒ no error, not an error of 0")

        var forecast = fullRecord()          // costUSD 0.42
        forecast.predictedCostUSD = 0.30
        XCTAssertEqual(try XCTUnwrap(forecast.costPredictionErrorUSD), 0.12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(forecast.costPredictionErrorRatio), 0.4, accuracy: 1e-9)

        // A $0 forecast can't be wrong by a share of itself.
        forecast.predictedCostUSD = 0
        XCTAssertEqual(try XCTUnwrap(forecast.costPredictionErrorUSD), 0.42, accuracy: 1e-9)
        XCTAssertNil(forecast.costPredictionErrorRatio)
    }

    // MARK: - TaskEstimate round-trip

    func testEstimateRoundTripPreservesEveryField() throws {
        let estimate = fullEstimate()

        let decoded = try roundTrip(estimate)

        XCTAssertEqual(decoded.id, estimate.id)
        XCTAssertEqual(decoded.itemID, "test-taskmetric-codable")
        XCTAssertEqual(decoded.projectPath, "/Users/dev/proj")
        XCTAssertEqual(decoded.createdAt, estimate.createdAt)
        XCTAssertEqual(decoded.estimatedSize, "M")
        XCTAssertEqual(decoded.predictedDurationSeconds, 540, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(decoded.predictedCostUSD), 0.35, accuracy: 0.000_001)
        XCTAssertEqual(decoded.predictedRetries, 1)
        XCTAssertEqual(decoded.confidence, 0.66, accuracy: 0.000_001)
        XCTAssertEqual(decoded.source, "hybrid")
        XCTAssertEqual(decoded.rationale, "3 comparable M tasks in this project")
    }

    func testEstimateRoundTripKeepsNilOptionalsNil() throws {
        // A cold-start estimate has no cost/retry prediction — "unknown", not zero.
        let estimate = TaskEstimate(
            itemID: "t-1", projectPath: "/p", createdAt: Date(timeIntervalSince1970: 1_785_846_896),
            estimatedSize: "L", predictedDurationSeconds: 1800, predictedCostUSD: nil,
            predictedRetries: nil, confidence: 0, source: "heuristic", rationale: ""
        )

        let decoded = try roundTrip(estimate)

        XCTAssertNil(decoded.predictedCostUSD)
        XCTAssertNil(decoded.predictedRetries)
        XCTAssertEqual(decoded.confidence, 0, accuracy: 0.000_001)
        XCTAssertEqual(decoded.rationale, "")
    }

    func testEstimateRoundTripPreservesConfidencePrecision() throws {
        var estimate = fullEstimate()
        estimate = TaskEstimate(
            itemID: estimate.itemID, projectPath: estimate.projectPath, createdAt: estimate.createdAt,
            estimatedSize: estimate.estimatedSize, predictedDurationSeconds: 1234.5678,
            predictedCostUSD: 0.123_456_789, predictedRetries: 0, confidence: 1.0 / 3.0,
            source: estimate.source, rationale: estimate.rationale
        )

        let decoded = try roundTrip(estimate)

        XCTAssertEqual(decoded.predictedDurationSeconds, 1234.5678, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(decoded.predictedCostUSD), 0.123_456_789, accuracy: 1e-12)
        XCTAssertEqual(decoded.confidence, 1.0 / 3.0, accuracy: 1e-12)
    }

    func testEstimateRoundTripPreservesCreatedAtToTheSecondUnderISO8601() throws {
        let now = Date()

        let decoded = try roundTrip(fullEstimate(createdAt: now))

        XCTAssertLessThan(abs(decoded.createdAt.timeIntervalSince(now)), 1.0)
    }

    func testEstimateRoundTripIsStableAcrossRepeatedEncodes() throws {
        let once = try roundTrip(fullEstimate())
        let twice = try roundTrip(once)

        XCTAssertEqual(twice.id, once.id)
        XCTAssertEqual(twice.createdAt, once.createdAt)
        XCTAssertEqual(try canonicalEncoder().encode(twice), try canonicalEncoder().encode(once))
    }

    // MARK: - TaskEstimate on-disk format

    func testEncodedEstimateUsesExpectedKeys() throws {
        XCTAssertEqual(
            try keys(of: fullEstimate()),
            [
                "id", "itemID", "projectPath", "createdAt", "estimatedSize",
                "predictedDurationSeconds", "predictedCostUSD", "predictedRetries",
                "confidence", "source", "rationale"
            ]
        )
    }

    func testEncodedEstimateOmitsNilOptionals() throws {
        let estimate = TaskEstimate(
            itemID: "t-1", projectPath: "/p", createdAt: Date(), estimatedSize: "S",
            predictedDurationSeconds: 120, predictedCostUSD: nil, predictedRetries: nil,
            confidence: 0.1, source: "heuristic", rationale: "no history"
        )

        XCTAssertEqual(
            try keys(of: estimate),
            [
                "id", "itemID", "projectPath", "createdAt", "estimatedSize",
                "predictedDurationSeconds", "confidence", "source", "rationale"
            ]
        )
    }

    func testEncodedEstimateFitsOnOneJSONLLine() throws {
        // Rationales come from an LLM and routinely contain newlines and quotes.
        let estimate = TaskEstimate(
            itemID: "t-1", projectPath: "/p", createdAt: Date(timeIntervalSince1970: 1_785_846_896),
            estimatedSize: "M", predictedDurationSeconds: 300, predictedCostUSD: 0.2,
            predictedRetries: 1, confidence: 0.5, source: "hybrid",
            rationale: "Similar to \"t-0\"\nwhich took 5m\r\n— café ☕️"
        )

        let line = try XCTUnwrap(String(data: storeEncoder().encode(estimate), encoding: .utf8))

        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))

        let decoded = try storeDecoder().decode(TaskEstimate.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.rationale, "Similar to \"t-0\"\nwhich took 5m\r\n— café ☕️")
    }

    func testDecodesHandWrittenEstimateLine() throws {
        // A line as it appears in an existing `~/.kiteloop/task-estimates.jsonl`.
        let json = """
        {"id":"7A1F0000-0000-0000-0000-000000000002","itemID":"legacy-1","projectPath":"/Users/dev/proj",\
        "createdAt":"2026-08-04T12:34:56Z","estimatedSize":"M","predictedDurationSeconds":480,\
        "predictedCostUSD":0.3,"predictedRetries":1,"confidence":0.75,"source":"hybrid",\
        "rationale":"4 comparable tasks"}
        """

        let decoded = try storeDecoder().decode(TaskEstimate.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, "7A1F0000-0000-0000-0000-000000000002")
        XCTAssertEqual(decoded.itemID, "legacy-1")
        XCTAssertEqual(decoded.createdAt, Date(timeIntervalSince1970: 1_785_846_896))
        XCTAssertEqual(decoded.estimatedSize, "M")
        XCTAssertEqual(decoded.predictedDurationSeconds, 480, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(decoded.predictedCostUSD), 0.3, accuracy: 0.000_001)
        XCTAssertEqual(decoded.predictedRetries, 1)
        XCTAssertEqual(decoded.confidence, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(decoded.source, "hybrid")
    }

    func testDecodeRejectsEstimateMissingRequiredField() {
        // Dropping `confidence` — the estimate is unusable for calibration without it.
        let json = """
        {"id":"e1","itemID":"t-1","projectPath":"/p","createdAt":"2026-08-04T12:34:56Z",\
        "estimatedSize":"M","predictedDurationSeconds":480,"source":"hybrid","rationale":"x"}
        """

        XCTAssertThrowsError(try storeDecoder().decode(TaskEstimate.self, from: Data(json.utf8)))
    }

    func testEachConstructedRecordAndEstimateGetsADistinctID() {
        XCTAssertNotEqual(fullRecord().id, fullRecord().id)
        XCTAssertNotEqual(fullEstimate().id, fullEstimate().id)
    }

    // MARK: - The attempt that never started

    /// A refusal at pickup is written to the same log as the runs, so its
    /// outcome spelling has to survive the round trip the retry ceiling reads it
    /// back through — `didNotRun` and `workEvidence` are both read off decoded
    /// lines, one at every pickup.
    func testARefusalRecordRoundTrips() throws {
        let at = Date(timeIntervalSince1970: 1_785_846_896)
        let item = BacklogItem(id: "memory-proposals-cannot-be-answered-headlessly",
                               title: "Answer memory proposals headlessly", verify: "swift build",
                               status: .ready, type: .local, size: .s, queries: nil, cost: nil,
                               completedDate: nil, blockedReason: nil, jiraKey: nil, team: nil,
                               detailPath: "backlog/memory-proposals.md")
        let record = RetryCeiling.refusalRecord(
            item: item, refusal: .notGrounded, projectPath: "/Users/dev/proj",
            projectName: "proj", epic: "Autonomy", specFingerprint: "a1b2c3d4", at: at)

        let decoded = try roundTrip(record)

        XCTAssertEqual(decoded.outcome, "did-not-run:not-grounded")
        XCTAssertTrue(decoded.didNotRun)
        XCTAssertEqual(decoded.itemID, record.itemID)
        XCTAssertEqual(decoded.changedFileCount, 0)
        XCTAssertEqual(decoded.workEvidence, .empty)
        XCTAssertEqual(decoded.specFingerprint, "a1b2c3d4")
        XCTAssertEqual(decoded.costUSD, 0)
        XCTAssertEqual(decoded.durationSeconds, 0)
        XCTAssertEqual(decoded.completedAt, at)
    }

    /// A line written by a build that knows a clause this one doesn't still
    /// decodes, and still reads as an attempt that never ran: the clause travels
    /// inside the outcome string precisely so a new one can't fail a decode and
    /// drop the row — a dropped row is an attempt the ceiling stops counting.
    func testAnUnknownRefusalClauseStillDecodesAsAnAttemptThatDidNotRun() throws {
        let json = """
        {"id":"7A1F0000-0000-0000-0000-000000000003","projectPath":"/Users/dev/proj",\
        "projectName":"proj","itemID":"legacy-1","title":"An item","startedAt":"2026-08-04T12:34:56Z",\
        "completedAt":"2026-08-04T12:34:56Z","durationSeconds":0,"costUSD":0,"reviewerRetries":0,\
        "outcome":"did-not-run:a-clause-no-build-here-writes","changedFileCount":0}
        """

        let decoded = try storeDecoder().decode(TaskMetricRecord.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.didNotRun)
        XCTAssertEqual(decoded.workEvidence, .empty)
    }

    /// And the discrimination the flag exists for: a real run is never one.
    func testARunIsNotReadAsAnAttemptThatDidNotRun() {
        XCTAssertFalse(fullRecord().didNotRun)
        let at = Date(timeIntervalSince1970: 1_785_846_896)
        for outcome in ["done", "awaiting-approval", "blocked:review did not pass",
                        "cancelled:stopped by user"] {
            let record = TaskMetricRecord(
                projectPath: "/Users/dev/proj", projectName: "proj", itemID: "t-1", title: "An item",
                epic: nil, declaredSize: "M", startedAt: at, completedAt: at.addingTimeInterval(60),
                durationSeconds: 60, costUSD: 1.5, reviewerRetries: 0, outcome: outcome,
                workerAgent: "worker", reviewerAgent: "reviewer", executionID: "exec-1",
                toolErrors: nil)
            XCTAssertFalse(record.didNotRun, outcome)
        }
    }
}
