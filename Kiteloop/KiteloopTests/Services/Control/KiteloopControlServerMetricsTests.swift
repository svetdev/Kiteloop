import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/metrics` — the durable run log. `GET /v1/runs` only knows the runs
/// this process started and loses them on restart, so a driver scoring the SLOs
/// (duration, cost, rework loops, quality) needs the measured records the
/// learning engine persists. Exercised over a real loopback socket, like the
/// other control-API tests.
@MainActor
final class KiteloopControlServerMetricsTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var metricStore: TaskMetricStore!
    private var harness: ControlServerHarness!
    /// Extra servers a test started (e.g. one with no store attached), stopped in teardown.
    private var extraHarnesses: [ControlServerHarness] = []
    private let token = "control-metrics-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-metrics")
        registry = ControlSessionRegistry()
        // Pointed at the temp directory so the tests never read or append to the
        // developer's real ~/.kiteloop/task-metrics.jsonl.
        metricStore = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl")
        )
        harness = try await startServer(metricStore: metricStore)
    }

    override func tearDown() async throws {
        harness?.stop()
        extraHarnesses.forEach { $0.stop() }
        extraHarnesses = []
        harness = nil
        registry = nil
        metricStore = nil
    }

    // MARK: - Listing

    /// A fresh install has no measured runs, which is a normal state rather than
    /// a 404 — a poller can start reading before the first item ever finishes.
    func testEmptyListWhenNothingHasBeenMeasured() async throws {
        let (status, body) = try await harness.get("/v1/metrics")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 0)
        XCTAssertEqual((body["metrics"] as? [[String: Any]])?.count, 0)
    }

    /// The whole record, because each field is one of the things a caller scores:
    /// duration and cost (estimation accuracy), reviewer retries (rework), the
    /// outcome, and the advisory judge score.
    func testReportsTheFullRecordForAMeasuredRun() async throws {
        let started = Date(timeIntervalSince1970: 1_770_000_000)
        var record = makeRecord(
            projectPath: "/tmp/alpha", projectName: "alpha", itemID: "item-1", title: "Ship the thing",
            startedAt: started, durationSeconds: 942, costUSD: 1.25, reviewerRetries: 2, outcome: "done"
        )
        record.qualityScore = 0.87
        record.judgeDimensions = ["verify_passed": 1.0, "scope_respected": 0.75]
        record.qualityScoreDiffTruncated = true
        metricStore.append(record)

        let (status, body) = try await harness.get("/v1/metrics")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 1)
        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics[0]["item"] as? String, "item-1")
        XCTAssertEqual(metrics[0]["title"] as? String, "Ship the thing")
        XCTAssertEqual(metrics[0]["project"] as? String, "alpha")
        XCTAssertEqual(metrics[0]["epic"] as? String, "Work")
        XCTAssertEqual(metrics[0]["size"] as? String, "M")
        XCTAssertEqual(metrics[0]["runId"] as? String, "exec-item-1")
        XCTAssertEqual(metrics[0]["startedAt"] as? String, ISO8601DateFormatter().string(from: started))
        XCTAssertEqual(metrics[0]["completedAt"] as? String,
                       ISO8601DateFormatter().string(from: started.addingTimeInterval(942)))
        XCTAssertEqual(metrics[0]["durationSec"] as? Int, 942)
        XCTAssertEqual(metrics[0]["costUSD"] as? Double, 1.25)
        XCTAssertEqual(metrics[0]["reviewerRetries"] as? Int, 2)
        XCTAssertEqual(metrics[0]["outcome"] as? String, "done")
        XCTAssertEqual(metrics[0]["worker"] as? String, "Builder")
        XCTAssertEqual(metrics[0]["reviewer"] as? String, "Reviewer")
        XCTAssertEqual(metrics[0]["qualityScore"] as? Double, 0.87)
        XCTAssertEqual((metrics[0]["judgeDimensions"] as? [String: Double])?["verify_passed"], 1.0)
        XCTAssertEqual(metrics[0]["qualityScoreDiffTruncated"] as? Bool, true)
    }

    /// Newest first: the run that just finished — the one a driver is waiting on —
    /// is at index 0, matching how `GET /v1/runs` orders.
    func testOrdersNewestFirst() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        metricStore.append(makeRecord(itemID: "older", startedAt: base))
        metricStore.append(makeRecord(itemID: "newer", startedAt: base.addingTimeInterval(3_600)))

        let (_, body) = try await harness.get("/v1/metrics")

        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["item"] as? String }, ["newer", "older"])
    }

    /// A record whose run was never scored reports `null` rather than a zero that
    /// would read as a terrible run.
    func testUnscoredRunReportsNullQuality() async throws {
        metricStore.append(makeRecord(itemID: "item-1"))

        let (_, body) = try await harness.get("/v1/metrics")

        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        XCTAssertTrue(metrics[0]["qualityScore"] is NSNull)
        XCTAssertTrue(metrics[0]["judgeDimensions"] is NSNull)
        XCTAssertTrue(metrics[0]["qualityScoreDiffTruncated"] is NSNull)
    }

    /// The per-item cost cap is advisory — an overrun lets the run finish — so
    /// the only thing that makes it a measurement rather than a log line is
    /// reading it back here, beside the forecast it overran. Either number alone
    /// is unreadable: an overrun says nothing about how far the estimate was
    /// out, and a prediction says nothing about whether it held.
    func testReportsTheCapOverrunBesideThePredictionItOverran() async throws {
        var record = makeRecord(itemID: "item-1", costUSD: 12.40)
        record.predictedCostUSD = 4.0
        record.overItemCap = true
        metricStore.append(record)

        let (status, body) = try await harness.get("/v1/metrics")

        XCTAssertEqual(status, 200)
        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics[0]["predictedCostUSD"] as? Double, 4.0)
        XCTAssertEqual(metrics[0]["overItemCap"] as? Bool, true)
        XCTAssertEqual(metrics[0]["costUSD"] as? Double, 12.40)
    }

    /// A run that stayed inside its ceiling reports `false`, and a record from
    /// before either was captured reports `null`. Collapsing the two would make
    /// every line already on disk look like a run measured and found within
    /// budget, which is the reading that would inflate the denominator.
    func testARunWithinItsCapIsFalseAndAnUnmeasuredOneIsNull() async throws {
        var within = makeRecord(itemID: "within",
                                startedAt: Date(timeIntervalSince1970: 1_770_003_600))
        within.predictedCostUSD = 4.0
        within.overItemCap = false
        metricStore.append(within)
        metricStore.append(makeRecord(itemID: "unmeasured"))

        let (_, body) = try await harness.get("/v1/metrics")

        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["item"] as? String }, ["within", "unmeasured"])
        XCTAssertEqual(metrics[0]["overItemCap"] as? Bool, false)
        XCTAssertEqual(metrics[0]["predictedCostUSD"] as? Double, 4.0)
        XCTAssertTrue(metrics[1]["overItemCap"] is NSNull)
        XCTAssertTrue(metrics[1]["predictedCostUSD"] is NSNull)
    }

    /// A run whose diff fit whole reports `false`, and a record from before the
    /// field existed (or one the judge was never asked about) reports `null` —
    /// collapsing the two would make every old line look like a diff measured
    /// and found to fit, which is the reading that would hide a truncated score
    /// inside a clean-looking average.
    func testADiffThatFitWholeIsFalseAndAnUnmeasuredOneIsNull() async throws {
        var whole = makeRecord(itemID: "whole")
        whole.qualityScoreDiffTruncated = false
        metricStore.append(whole)
        metricStore.append(makeRecord(itemID: "unmeasured"))

        let (_, body) = try await harness.get("/v1/metrics")

        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        let byItem = Dictionary(uniqueKeysWithValues: metrics.map { ($0["item"] as? String ?? "", $0) })
        XCTAssertEqual(byItem["whole"]?["qualityScoreDiffTruncated"] as? Bool, false)
        XCTAssertTrue(byItem["unmeasured"]?["qualityScoreDiffTruncated"] is NSNull)
    }

    // MARK: - Escaped defects (metric #3b)

    /// The rate has to be readable next to the runs it scores, or the SLO that
    /// says whether review works has no number behind it.
    func testReportsTheEscapedDefectRate() async throws {
        let approvedAt = Date(timeIntervalSince1970: 1_770_000_000)
        approve("item-1", at: approvedAt)
        reopen("item-1", approvedAt: approvedAt, at: approvedAt.addingTimeInterval(2 * 86_400))
        approve("item-2", at: approvedAt)

        let (status, body) = try await harness.get("/v1/metrics")

        XCTAssertEqual(status, 200)
        let escaped = try XCTUnwrap(body["escapedDefects"] as? [String: Any])
        XCTAssertEqual(escaped["windowDays"] as? Int, 7)
        XCTAssertEqual(escaped["approvals"] as? Int, 2)
        XCTAssertEqual(escaped["reopened"] as? Int, 1)
        XCTAssertEqual(escaped["lateReopened"] as? Int, 0)
        XCTAssertEqual(escaped["rate"] as? Double, 0.5)
    }

    /// Day 30 is new work, not a defect this review let through — it's reported
    /// separately so a 0% rate can't be mistaken for "nothing ever came back".
    func testReopenOutsideTheWindowIsReportedButNotCounted() async throws {
        let approvedAt = Date(timeIntervalSince1970: 1_770_000_000)
        approve("item-1", at: approvedAt)
        reopen("item-1", approvedAt: approvedAt, at: approvedAt.addingTimeInterval(30 * 86_400))

        let (_, body) = try await harness.get("/v1/metrics")

        let escaped = try XCTUnwrap(body["escapedDefects"] as? [String: Any])
        XCTAssertEqual(escaped["reopened"] as? Int, 0)
        XCTAssertEqual(escaped["lateReopened"] as? Int, 1)
        XCTAssertEqual(escaped["rate"] as? Double, 0.0)
    }

    /// Before anything has been approved the rate is `null`, not `0` — 0/0 is
    /// "not measured yet", and a driver must not read it as a perfect score.
    func testRateIsNullBeforeAnythingHasBeenApproved() async throws {
        let (_, body) = try await harness.get("/v1/metrics")

        let escaped = try XCTUnwrap(body["escapedDefects"] as? [String: Any])
        XCTAssertEqual(escaped["approvals"] as? Int, 0)
        XCTAssertTrue(escaped["rate"] is NSNull)
    }

    /// Scoped like the records above it: `?project=` reports that project's rate.
    func testEscapedDefectRateIsScopedByProject() async throws {
        let alpha = try registerProject(named: "alpha")
        try registerProject(named: "beta")
        let approvedAt = Date(timeIntervalSince1970: 1_770_000_000)
        approve("item-1", projectPath: alpha, at: approvedAt)
        reopen("item-1", projectPath: alpha, approvedAt: approvedAt,
               at: approvedAt.addingTimeInterval(86_400))
        approve("item-2", projectPath: "/elsewhere/beta", at: approvedAt)

        let (_, body) = try await harness.get("/v1/metrics?project=alpha")

        let escaped = try XCTUnwrap(body["escapedDefects"] as? [String: Any])
        XCTAssertEqual(escaped["approvals"] as? Int, 1)
        XCTAssertEqual(escaped["rate"] as? Double, 1.0)
    }

    /// The rate spans the whole history, not the page of records `limit` cut it
    /// down to — it's about every approval, not the last few runs.
    func testRateIgnoresTheRecordLimit() async throws {
        let approvedAt = Date(timeIntervalSince1970: 1_770_000_000)
        for i in 0..<5 { approve("item-\(i)", at: approvedAt) }

        let (_, body) = try await harness.get("/v1/metrics?limit=1")

        let escaped = try XCTUnwrap(body["escapedDefects"] as? [String: Any])
        XCTAssertEqual(escaped["approvals"] as? Int, 5)
    }

    // MARK: - First pass (metric #3a)

    /// The other half of #3: whether review passes the work the first time it is
    /// handed one. It was recorded on every run since the store existed and
    /// reported nowhere, which is what this reads.
    func testReportsTheFirstPassRate() async throws {
        metricStore.append(makeRecord(itemID: "a", reviewerRetries: 0, outcome: "done"))
        metricStore.append(makeRecord(itemID: "b", reviewerRetries: 0, outcome: "awaiting-approval"))
        metricStore.append(makeRecord(itemID: "c", reviewerRetries: 2, outcome: "done"))
        metricStore.append(makeRecord(itemID: "d", reviewerRetries: 0,
                                      outcome: "blocked:review did not pass"))

        let (status, body) = try await harness.get("/v1/metrics")

        XCTAssertEqual(status, 200)
        let firstPass = try XCTUnwrap(body["firstPassRate"] as? [String: Any])
        XCTAssertEqual(firstPass["judged"] as? Int, 4)
        XCTAssertEqual(firstPass["firstPass"] as? Int, 2)
        XCTAssertEqual(firstPass["rate"] as? Double, 0.5)
    }

    /// A human stopped the run, so it says nothing about whether review works —
    /// counting it either way would move a number nobody's work moved.
    func testACancelledRunIsInNeitherHalfOfTheFirstPassRate() async throws {
        metricStore.append(makeRecord(itemID: "a", reviewerRetries: 0, outcome: "done"))
        metricStore.append(makeRecord(itemID: "b", reviewerRetries: 0, outcome: "cancelled"))

        let (_, body) = try await harness.get("/v1/metrics")

        let firstPass = try XCTUnwrap(body["firstPassRate"] as? [String: Any])
        XCTAssertEqual(firstPass["judged"] as? Int, 1)
        XCTAssertEqual(firstPass["firstPass"] as? Int, 1)
        XCTAssertEqual(firstPass["rate"] as? Double, 1.0)
    }

    /// Before anything has been judged the rate is `null`, not `0` — 0/0 is "not
    /// measured yet", and a driver must not read it as a loop that never passes.
    func testFirstPassRateIsNullBeforeAnythingHasBeenJudged() async throws {
        let (_, body) = try await harness.get("/v1/metrics")

        let firstPass = try XCTUnwrap(body["firstPassRate"] as? [String: Any])
        XCTAssertEqual(firstPass["judged"] as? Int, 0)
        XCTAssertTrue(firstPass["rate"] is NSNull)
    }

    /// Whole-history like the defect rate, not the page `limit` cut it down to.
    func testFirstPassRateIgnoresTheRecordLimit() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        for i in 0..<5 {
            metricStore.append(makeRecord(itemID: "item-\(i)",
                                          startedAt: base.addingTimeInterval(Double(i) * 60)))
        }

        let (_, body) = try await harness.get("/v1/metrics?limit=1")

        XCTAssertEqual(body["count"] as? Int, 1)
        let firstPass = try XCTUnwrap(body["firstPassRate"] as? [String: Any])
        XCTAssertEqual(firstPass["judged"] as? Int, 5)
    }

    /// Scoped like the records above it: `?project=` reports that project's rate.
    func testFirstPassRateIsScopedByProject() async throws {
        let alpha = try registerProject(named: "alpha")
        try registerProject(named: "beta")
        metricStore.append(makeRecord(projectPath: alpha, projectName: "alpha", itemID: "a",
                                      reviewerRetries: 0, outcome: "done"))
        metricStore.append(makeRecord(projectPath: "/elsewhere/beta", projectName: "beta",
                                      itemID: "b", reviewerRetries: 3, outcome: "done"))

        let (_, body) = try await harness.get("/v1/metrics?project=alpha")

        let firstPass = try XCTUnwrap(body["firstPassRate"] as? [String: Any])
        XCTAssertEqual(firstPass["judged"] as? Int, 1)
        XCTAssertEqual(firstPass["rate"] as? Double, 1.0)
    }

    // MARK: - Filtering

    func testProjectFilterNarrowsToThatProjectsRuns() async throws {
        let alpha = try registerProject(named: "alpha")
        try registerProject(named: "beta")
        metricStore.append(makeRecord(projectPath: alpha, projectName: "alpha", itemID: "item-1"))
        metricStore.append(makeRecord(projectPath: "/elsewhere/beta", projectName: "beta", itemID: "item-2"))

        let (status, body) = try await harness.get("/v1/metrics?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["item"] as? String }, ["item-1"])
    }

    /// Records keep the raw root path while the registry keys on the canonical
    /// one, so a trailing slash must not hide a project's own runs.
    func testProjectFilterMatchesDespiteATrailingSlash() async throws {
        let alpha = try registerProject(named: "alpha")
        metricStore.append(makeRecord(projectPath: alpha + "/", projectName: "alpha", itemID: "item-1"))

        let (_, body) = try await harness.get("/v1/metrics?project=alpha")

        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["item"] as? String }, ["item-1"])
    }

    /// Same contract as the other project-scoped reads: a project that isn't open
    /// is a 409, not an empty list a caller could mistake for "no runs yet".
    func testProjectFilterRequiresAnOpenProject() async throws {
        let (status, body) = try await harness.get("/v1/metrics?project=ghost")

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: ghost")
    }

    // MARK: - Limit

    func testLimitCapsHowManyRecordsComeBack() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        for i in 0..<5 {
            metricStore.append(makeRecord(itemID: "item-\(i)", startedAt: base.addingTimeInterval(Double(i) * 60)))
        }

        let (status, body) = try await harness.get("/v1/metrics?limit=2")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 2)
        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["item"] as? String }, ["item-4", "item-3"])
    }

    /// Without a limit the default keeps a long history from arriving all at once.
    func testDefaultLimitIsTwenty() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        for i in 0..<25 {
            metricStore.append(makeRecord(itemID: "item-\(i)", startedAt: base.addingTimeInterval(Double(i) * 60)))
        }

        let (_, body) = try await harness.get("/v1/metrics")

        XCTAssertEqual(body["count"] as? Int, 20)
    }

    /// A limit that isn't a number in range is a caller bug, so it's rejected
    /// rather than silently rounded into the default.
    func testRejectsAnUnusableLimit() async throws {
        for raw in ["0", "999", "abc", "-3"] {
            let (status, body) = try await harness.get("/v1/metrics?limit=\(raw)")
            XCTAssertEqual(status, 400, "limit=\(raw)")
            XCTAssertEqual(body["error"] as? String, "\"limit\" must be an integer in 1...200", "limit=\(raw)")
        }
    }

    // MARK: - Errors

    /// With no store attached there is no history to report — say so instead of
    /// answering an empty list that reads as "this app has never run anything".
    func testUnavailableWhenNoStoreIsAttached() async throws {
        let detached = try await startServer(metricStore: nil)
        extraHarnesses.append(detached)

        let (status, body) = try await detached.get("/v1/metrics")

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String, "Metrics are unavailable — no metric store attached")
    }

    func testRequiresBearerToken() async throws {
        let (status, body) = try await harness.get("/v1/metrics", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - The retry ceiling, on GET /v1/backlog
    //
    // `ready` used to answer for grooming alone, so a groomed item the retry
    // ceiling had retired came back runnable and a headless driver kept posting
    // runs autopilot silently refused at pickup — the "find out by starting it"
    // loop the readiness fields exist to remove. These live here rather than
    // beside the other backlog tests because this is the only control-server
    // harness that attaches a `TaskMetricStore`, and the ceiling is counted from
    // nothing else.

    /// The defect: `RetryCeiling.limit` attempts that produced nothing, and the
    /// item still reported runnable.
    func testARetiredItemIsReportedNotReadyWithTheCeilingsOwnReason() async throws {
        let root = try registerProject(named: "alpha", readyItem: "item-1")
        appendNoWorkAttempts(RetryCeiling.limit, itemID: "item-1", projectPath: root)

        let (status, body) = try await harness.get("/v1/backlog?project=alpha")

        XCTAssertEqual(status, 200)
        let item = try XCTUnwrap(backlogItem("item-1", body))
        XCTAssertEqual(item["ready"] as? Bool, false)
        XCTAssertEqual(item["retired"] as? Bool, true)
        XCTAssertEqual(item["noWorkAttempts"] as? Int, RetryCeiling.limit)
        // Quoting the ceiling's own verdict, so the phrase a driver reads is the
        // one the run log and the item's Notes carry.
        let expected = RetryCeiling.Verdict(noWorkAttempts: RetryCeiling.limit,
                                            limit: RetryCeiling.limit).summary
        XCTAssertEqual(item["notReady"] as? [String], [expected])
    }

    /// One attempt short of the ceiling is still runnable — and the count is
    /// reported anyway, so a driver can see the streak building rather than only
    /// the moment it lands.
    func testAStreakBelowTheCeilingIsStillReadyAndCarriesItsCount() async throws {
        let root = try registerProject(named: "alpha", readyItem: "item-1")
        appendNoWorkAttempts(RetryCeiling.limit - 1, itemID: "item-1", projectPath: root)

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let item = try XCTUnwrap(backlogItem("item-1", body))
        XCTAssertEqual(item["ready"] as? Bool, true)
        XCTAssertNil(item["retired"])
        XCTAssertEqual(item["noWorkAttempts"] as? Int, RetryCeiling.limit - 1)
        XCTAssertNil(item["notReady"])
    }

    /// A later attempt that left work behind clears the streak outright — the
    /// ceiling is a streak, not a retirement age, and the endpoint reads it the
    /// same way `RetryCeiling.noWorkAttempts` defines it.
    func testAnAttemptThatProducedWorkClearsTheRetirement() async throws {
        let root = try registerProject(named: "alpha", readyItem: "item-1")
        appendNoWorkAttempts(RetryCeiling.limit, itemID: "item-1", projectPath: root)
        metricStore.append(makeRecord(
            projectPath: root, itemID: "item-1",
            startedAt: streakStart.addingTimeInterval(Double(RetryCeiling.limit) * 3_600),
            outcome: "done", changedFileCount: 4))

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let item = try XCTUnwrap(backlogItem("item-1", body))
        XCTAssertEqual(item["ready"] as? Bool, true)
        XCTAssertNil(item["retired"])
        XCTAssertEqual(item["noWorkAttempts"] as? Int, 0)
        XCTAssertNil(item["notReady"])
    }

    /// Item ids are unique per project and the ledger is portfolio-wide, so two
    /// projects sharing an id must not accumulate each other's attempts.
    func testNoWorkAttemptsInAnotherProjectDoNotRetireTheItem() async throws {
        try registerProject(named: "alpha", readyItem: "item-1")
        let beta = try registerProject(named: "beta", readyItem: "item-1")
        appendNoWorkAttempts(RetryCeiling.limit, itemID: "item-1", projectPath: beta)

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let item = try XCTUnwrap(backlogItem("item-1", body))
        XCTAssertEqual(item["ready"] as? Bool, true)
        XCTAssertNil(item["retired"])
        XCTAssertEqual(item["noWorkAttempts"] as? Int, 0)
    }

    /// Retirement is named as its own clause rather than folded into the grooming
    /// ones: an item can be both ungroomed and going nowhere, and the two ask for
    /// different work — a section to write, or a release.
    func testAnUngroomedRetiredItemReportsBothReasons() async throws {
        let root = try registerProject(named: "alpha", readyItem: "item-1", groomed: false)
        appendNoWorkAttempts(RetryCeiling.limit, itemID: "item-1", projectPath: root)

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let item = try XCTUnwrap(backlogItem("item-1", body))
        XCTAssertEqual(item["ready"] as? Bool, false)
        XCTAssertEqual(item["retired"] as? Bool, true)
        let reasons = try XCTUnwrap(item["notReady"] as? [String])
        XCTAssertTrue(reasons.contains { $0.hasPrefix("no groomed detail file") }, "\(reasons)")
        // Last, after everything the groomer could act on.
        XCTAssertEqual(reasons.last, RetryCeiling.Verdict(noWorkAttempts: RetryCeiling.limit,
                                                          limit: RetryCeiling.limit).summary)
    }

    /// Pickup readiness is a meaningless question for an item that isn't `ready`,
    /// and so is the ceiling's verdict on it: neither field appears, however much
    /// history the ledger holds for that id.
    func testAnItemThatIsNotReadyCarriesNoCeilingFields() async throws {
        let root = try registerProject(named: "alpha", readyItem: "item-1", status: "done")
        appendNoWorkAttempts(RetryCeiling.limit, itemID: "item-1", projectPath: root)

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let item = try XCTUnwrap(backlogItem("item-1", body))
        XCTAssertEqual(item["status"] as? String, "done")
        XCTAssertNil(item["ready"])
        XCTAssertNil(item["retired"])
        XCTAssertNil(item["noWorkAttempts"])
    }

    /// With no store attached nothing has recorded an attempt this server can
    /// see, so the endpoint answers exactly what it always did rather than
    /// reporting a clean history it never read.
    func testWithNoMetricStoreTheBacklogAnswersAsItAlwaysHas() async throws {
        let root = try registerProject(named: "alpha", readyItem: "item-1")
        appendNoWorkAttempts(RetryCeiling.limit, itemID: "item-1", projectPath: root)
        let detached = try await startServer(metricStore: nil)
        extraHarnesses.append(detached)

        let (status, body) = try await detached.get("/v1/backlog?project=alpha")

        XCTAssertEqual(status, 200)
        let item = try XCTUnwrap(backlogItem("item-1", body))
        XCTAssertEqual(item["ready"] as? Bool, true)
        XCTAssertNil(item["retired"])
        XCTAssertNil(item["noWorkAttempts"])
    }

    // MARK: - Helpers

    private func makeRecord(
        projectPath: String = "/tmp/alpha",
        projectName: String = "alpha",
        itemID: String = "item-1",
        title: String = "Ship the thing",
        startedAt: Date = Date(timeIntervalSince1970: 1_770_000_000),
        durationSeconds: Double = 60,
        costUSD: Double = 0.5,
        reviewerRetries: Int = 0,
        outcome: String = "done",
        changedFileCount: Int? = nil
    ) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: projectPath,
            projectName: projectName,
            itemID: itemID,
            title: title,
            epic: "Work",
            declaredSize: "M",
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(durationSeconds),
            durationSeconds: durationSeconds,
            costUSD: costUSD,
            reviewerRetries: reviewerRetries,
            outcome: outcome,
            workerAgent: "Builder",
            reviewerAgent: "Reviewer",
            executionID: "exec-\(itemID)",
            toolErrors: nil
        )
        record.changedFileCount = changedFileCount
        return record
    }

    /// Where the fixture streaks start, so a record appended after one is
    /// unambiguously later than every attempt in it.
    private let streakStart = Date(timeIntervalSince1970: 1_770_000_000)

    /// `count` attempts that left nothing behind, an hour apart — what the retry
    /// ceiling counts. `changedFileCount: 0` is the measurement the ceiling reads
    /// first, so these are `.empty` rather than the `.unknown` an unmeasured run
    /// would be.
    private func appendNoWorkAttempts(_ count: Int, itemID: String, projectPath: String) {
        for i in 0..<count {
            metricStore.append(makeRecord(
                projectPath: projectPath, itemID: itemID,
                startedAt: streakStart.addingTimeInterval(Double(i) * 3_600),
                outcome: "blocked:\(RunWorkEvidence.noWorkPrefix) — no commits and an unchanged worktree",
                changedFileCount: 0))
        }
    }

    private func backlogItem(_ id: String, _ body: [String: Any]) -> [String: Any]? {
        (body["items"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    /// A groomed `backlog/<id>.md` — What, How, Validation, a size and a
    /// `verify:`, the whole of what the Definition-of-Ready gate reads out of a
    /// detail file, so nothing but the retry ceiling can make the item unready.
    private func groomedDetail(id: String) -> String {
        """
        ---
        id: \(id)
        title: Ship the thing
        size: S
        verify:
          - name: build
            cmd: "true"
        ---

        ## What

        The outcome this item delivers.

        ## How

        Touch these files, follow this pattern.

        ## Validation

        - [ ] The observable behaviour that proves it works

        ## Out of Scope

        - Anything else
        """
    }

    private func approve(_ itemID: String, projectPath: String = "/tmp/alpha", at: Date) {
        metricStore.appendApprovalEvent(ItemApprovalEvent(
            projectPath: projectPath, projectName: "alpha", itemID: itemID, kind: .approved, at: at
        ))
    }

    private func reopen(_ itemID: String, projectPath: String = "/tmp/alpha",
                        approvedAt: Date, at: Date) {
        metricStore.appendApprovalEvent(ItemApprovalEvent(
            projectPath: projectPath, projectName: "alpha", itemID: itemID, kind: .reopened,
            at: at, approvedAt: approvedAt, toStatus: "ready"
        ))
    }

    /// Builds a real `ProjectSession` over a throwaway directory and registers it.
    /// Returns the project's root path — what a metric record stores.
    ///
    /// `readyItem` writes a BACKLOG.md holding that one item, at `status`, and —
    /// unless `groomed` is false — the `backlog/<id>.md` the Definition-of-Ready
    /// gate reads, so the item is runnable on grooming alone and whatever the
    /// endpoint then says about it is the retry ceiling's doing. Written before
    /// the session exists, so it is parsed on init the way the app does.
    @discardableResult
    private func registerProject(named name: String, readyItem: String? = nil,
                                 status: String = "ready", groomed: Bool = true) throws -> String {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        if let readyItem {
            let detailLink = groomed ? " → [detail](backlog/\(readyItem).md)" : ""
            let backlogFile = "# \(name) Backlog\n\n## Now\n\n"
                + "- [ ] \(readyItem) | Ship the thing | \(status)\(detailLink)\n"
            try backlogFile.write(to: root.appending(path: "BACKLOG.md"),
                                  atomically: true, encoding: .utf8)
            if groomed {
                let backlogDir = root.appendingPathComponent("backlog", isDirectory: true)
                try FileManager.default.createDirectory(at: backlogDir, withIntermediateDirectories: true)
                try groomedDetail(id: readyItem)
                    .write(to: backlogDir.appending(path: "\(readyItem).md"),
                           atomically: true, encoding: .utf8)
            }
        }

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
        return rootURL.path(percentEncoded: false)
    }

    /// All stores are pointed at the temp directory so the tests never read or
    /// write the developer's real global config.
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }

    /// The port is picked at random and probed, since NWListener reports a bind
    /// conflict asynchronously rather than throwing from start().
    private func startServer(metricStore: TaskMetricStore?) async throws -> ControlServerHarness {
        try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0, metricStore: metricStore)
        }
    }
}
