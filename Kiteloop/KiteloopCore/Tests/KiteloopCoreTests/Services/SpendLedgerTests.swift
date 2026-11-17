import XCTest
@testable import KiteloopCore
import KiteloopTestSupport

final class SpendLedgerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ cost: Double, source: SpendRow.Source = .chat, project: String? = "/p/a",
                     agent: String? = "dev", routine: String? = nil, model: String? = "opus",
                     basis: SpendRow.Basis = .usd, ago: TimeInterval = 0) -> SpendRow {
        SpendRow(at: now.addingTimeInterval(-ago), source: source, project: project, agent: agent,
                 routine: routine, model: model, costUSD: cost, basis: basis)
    }

    // MARK: - The file

    func testRowsWrittenAreReadBackByAFreshLedger() throws {
        let url = try makeTemporaryDirectory().appending(path: "spend-ledger.jsonl")
        let written = [row(1.25), row(0.5, source: .routine, routine: "nightly", basis: .tokenEquivalent),
                       row(2, source: .autopilot, agent: nil, model: nil)]
        let ledger = SpendLedger(url: url)
        written.forEach(ledger.append)

        XCTAssertEqual(SpendLedger(url: url).rows(), written)
    }

    func testADamagedLineCostsOnlyThatLine() throws {
        let url = try makeTemporaryDirectory().appending(path: "spend-ledger.jsonl")
        let ledger = SpendLedger(url: url)
        ledger.append(row(1))
        try AtomicFileWriter.append(Data("{\"at\": not json\n".utf8), to: url)
        ledger.append(row(3))

        XCTAssertEqual(ledger.rows().map(\.costUSD), [1, 3])
    }

    func testAMissingFileIsAnEmptyLedger() throws {
        let url = try makeTemporaryDirectory().appending(path: "absent.jsonl")
        XCTAssertEqual(SpendLedger(url: url).rows(), [])
    }

    func testARowsDayIsTheLocalDayKeyOfItsMoment() {
        XCTAssertEqual(row(1).day, DayKey.string(for: now))
    }

    func testASubscriptionLoginSpendsTokenEquivalents() {
        XCTAssertEqual(SpendRow.Basis(auth: .subscription), .tokenEquivalent)
        XCTAssertEqual(SpendRow.Basis(auth: .apiKey), .usd)
        XCTAssertEqual(SpendRow.Basis(auth: .bedrock), .usd)
    }

    // MARK: - The breakdown

    private func breakdown(_ rows: [SpendRow], by grouping: SpendBreakdown.Grouping) -> SpendBreakdown {
        SpendBreakdown.make(rows: rows, by: grouping, from: now.addingTimeInterval(-86_400), to: now)
    }

    private func keyed(_ breakdown: SpendBreakdown) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: breakdown.rows.map { ($0.key, $0.costUSD) })
    }

    func testGroupsByAgent() {
        let result = breakdown([row(1, agent: "dev"), row(2, agent: "qa"), row(0.5, agent: "dev")], by: .agent)
        XCTAssertEqual(result.rows.map(\.key), ["qa", "dev"])
        XCTAssertEqual(result.rows.map(\.count), [1, 2])
        XCTAssertEqual(keyed(result), ["qa": 2, "dev": 1.5])
        XCTAssertEqual(result.totalUSD, 3.5)
    }

    func testGroupsByProject() {
        let result = breakdown([row(1, project: "/p/a"), row(4, project: "/p/b"), row(1, project: nil)], by: .project)
        XCTAssertEqual(result.rows.map(\.key), ["/p/b", "/p/a", "unknown"])
    }

    func testGroupsByRoutine() {
        let result = breakdown([row(1, source: .routine, routine: "nightly"), row(2, routine: nil)], by: .routine)
        XCTAssertEqual(keyed(result), ["nightly": 1, "unknown": 2])
    }

    func testGroupsByModelWithAMissingModelUnderUnknown() {
        let result = breakdown([row(1, model: "opus"), row(2, model: ""), row(3, model: nil)], by: .model)
        XCTAssertEqual(keyed(result), ["opus": 1, "unknown": 5])
        XCTAssertEqual(result.rows.first { $0.key == "unknown" }?.count, 2)
    }

    func testGroupsByDay() {
        func onDay(_ day: String, _ cost: Double) -> SpendRow {
            SpendRow(at: now, day: day, source: .chat, costUSD: cost, basis: .usd)
        }
        let result = breakdown([onDay("2026-11-15", 1), onDay("2026-11-16", 3), onDay("2026-11-15", 1)], by: .day)
        XCTAssertEqual(result.rows.map(\.key), ["2026-11-16", "2026-11-15"])
        XCTAssertEqual(keyed(result), ["2026-11-16": 3, "2026-11-15": 2])
    }

    func testRowsOutsideTheWindowAreExcluded() {
        let result = breakdown([row(1), row(5, ago: 2 * 86_400), row(7, ago: -60)], by: .agent)
        XCTAssertEqual(result.totalUSD, 1)
        XCTAssertEqual(result.rows.map(\.count), [1])
    }

    func testBasisIsUSDWhenEveryRowIsUSD() {
        XCTAssertEqual(breakdown([row(1), row(2)], by: .agent).basis, .usd)
    }

    func testBasisIsTokenEquivalentWhenEveryRowIs() {
        XCTAssertEqual(breakdown([row(1, basis: .tokenEquivalent), row(2, basis: .tokenEquivalent)],
                                 by: .agent).basis, .tokenEquivalent)
    }

    func testBasisIsMixedOtherwise() {
        XCTAssertEqual(breakdown([row(1), row(2, basis: .tokenEquivalent)], by: .agent).basis, .mixed)
    }
}
