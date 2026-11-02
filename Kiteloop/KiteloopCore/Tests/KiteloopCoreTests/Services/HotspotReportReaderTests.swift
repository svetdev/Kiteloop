import XCTest
@testable import KiteloopCore

/// `HotspotReportReader` parses exactly what `report(args:settings:)` in
/// `quality/bin/report-hotspots.py` prints.
final class HotspotReportReaderTests: XCTestCase {

    func testOneHotspotYieldsOneFinding() {
        let output = """
        42 function(s) measured, 10 touched in the last 90 day(s), top 5 by churn x complexity:
          Kiteloop/Foo.swift:12  hotspot 56 (churn 8 x cc 7)  func doThing()
        """
        let findings = HotspotReportReader.read(output)
        XCTAssertEqual(findings.count, 1)
        let finding = findings[0]
        XCTAssertEqual(finding.instrument, .hotspot)
        XCTAssertEqual(finding.kind, .refactor)
        XCTAssertEqual(finding.key, "Kiteloop/Foo.swift:12")
        XCTAssertEqual(finding.title, "func doThing()")
        XCTAssertEqual(finding.evidence, ["hotspot 56 (churn 8 x cc 7)"])
    }

    func testSeveralHotspotsYieldOneFindingEachInOrder() {
        let output = """
        2 function(s) measured, 2 touched in the last 90 day(s), top 2 by churn x complexity:
          Kiteloop/Foo.swift:12  hotspot 56 (churn 8 x cc 7)  func doThing()
          Kiteloop/Bar.swift:99  hotspot 20 (churn 4 x cc 5)  func doOther()
        """
        let findings = HotspotReportReader.read(output)
        XCTAssertEqual(findings.map(\.key), ["Kiteloop/Foo.swift:12", "Kiteloop/Bar.swift:99"])
    }

    /// The gate's ceiling is the bar: a function at or under it is compliant,
    /// and an item to bring a cc-7 function under a ceiling of 8 is dead work.
    func testRowsAtOrUnderTheCeilingAreNotFindings() {
        let output = """
        3 function(s) measured, 3 touched in the last 90 day(s), top 3 by churn x complexity:
          Kiteloop/A.swift:1  hotspot 90 (churn 10 x cc 9)  func a()
          Kiteloop/B.swift:2  hotspot 80 (churn 10 x cc 8)  func b()
          Kiteloop/C.swift:3  hotspot 70 (churn 10 x cc 7)  func c()
        """
        XCTAssertEqual(HotspotReportReader.read(output, ceiling: 8).map(\.key), ["Kiteloop/A.swift:1"])
        XCTAssertEqual(HotspotReportReader.read(output).count, 3, "no gate, so every row is a finding")
    }

    func testTheCeilingIsReadOffTheProjectsQualityConfig() throws {
        let dir = try makeTemporaryDirectory()
        XCTAssertNil(HotspotReportReader.complexityCeiling(repoRoot: dir), "no quality.json")
        try #"{"complexity": {"ceilings": {"cc": 8, "lines": 60}}}"#
            .write(to: dir.appending(path: "quality.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HotspotReportReader.complexityCeiling(repoRoot: dir), 8)
        try #"{"complexity": {}}"#
            .write(to: dir.appending(path: "quality.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(HotspotReportReader.complexityCeiling(repoRoot: dir), "a gate with no ceiling")
    }

    func testNoHotspotsYieldsNoFindings() {
        let output = "0 function(s) measured, 0 touched in the last 90 day(s), top 0 by churn x complexity:"
        XCTAssertEqual(HotspotReportReader.read(output), [])
    }

    func testEmptyInputYieldsNoFindings() {
        XCTAssertEqual(HotspotReportReader.read(""), [])
    }
}
