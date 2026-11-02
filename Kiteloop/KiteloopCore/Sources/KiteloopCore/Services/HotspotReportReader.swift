import Foundation

/// Reads `quality/bin/report-hotspots.py`'s own report — `report(args:settings:)`
/// in that script — into one finding per ranked function: a function that is
/// both complex and frequently changed, ranked by churn × complexity.
///
/// The shape parsed is exactly what that script prints, one row per function:
/// ```
/// 42 function(s) measured, 10 touched in the last 90 day(s), top 5 by churn x complexity:
///   Kiteloop/Foo.swift:12  hotspot 56 (churn 8 x cc 7)  func doThing()
/// ```
package enum HotspotReportReader {
    /// `ceiling` is the complexity gate's own — `complexity.ceilings.cc` in
    /// the project's `quality.json` — and a row at or under it is not a
    /// finding: the report ranks churn × complexity over every measured
    /// function, and an item was filed to bring a cc-7 function under a
    /// ceiling of 8. Nil when the project has no such gate, and then every
    /// row is one.
    package static func read(_ output: String, ceiling: Int? = nil) -> [SignalFinding] {
        output.split(separator: "\n").compactMap { rawLine in
            parse(String(rawLine)).flatMap { row in
                if let ceiling, row.cc <= ceiling { return nil }
                let key = "\(row.file):\(row.line)"
                let evidence = "hotspot \(row.score) (churn \(row.churn) x cc \(row.cc))"
                return SignalFinding(instrument: .hotspot, key: key, title: row.text,
                                     evidence: [evidence])
            }
        }
    }

    /// The complexity ceiling the project's own gate holds functions to,
    /// read off `quality.json` at `repoRoot`; nil when there is no file, no
    /// gate, or no number there.
    package static func complexityCeiling(repoRoot: URL) -> Int? {
        let url = repoRoot.appending(path: "quality.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let complexity = json["complexity"] as? [String: Any],
              let ceilings = complexity["ceilings"] as? [String: Any] else { return nil }
        return ceilings["cc"] as? Int
    }

    private struct Row {
        let file: String
        let line: Int
        let score: Int
        let churn: Int
        let cc: Int
        let text: String
    }

    /// One row: `  <file>:<line>  hotspot <score> (churn <churn> x cc <cc>)  <text>`.
    /// Nil for anything else — the header line, a blank line, a malformed row.
    private static func parse(_ line: String) -> Row? {
        guard line.hasPrefix("  "),
              let markerRange = line.range(of: "  hotspot ") else { return nil }

        let location = line[line.startIndex..<markerRange.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let colon = location.lastIndex(of: ":"),
              let lineNumber = Int(location[location.index(after: colon)...]) else { return nil }
        let file = String(location[location.startIndex..<colon])

        let rest = line[markerRange.upperBound...]
        guard let parenOpen = rest.firstIndex(of: "("),
              let parenClose = rest.firstIndex(of: ")"), parenOpen < parenClose else { return nil }

        guard let score = Int(rest[rest.startIndex..<parenOpen].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        let inside = rest[rest.index(after: parenOpen)..<parenClose].split(separator: " ")
        guard inside.count == 5, inside[0] == "churn", inside[2] == "x", inside[3] == "cc",
              let churn = Int(inside[1]), let cc = Int(inside[4]) else { return nil }

        let text = rest[rest.index(after: parenClose)...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return Row(file: file, line: lineNumber, score: score, churn: churn, cc: cc, text: text)
    }
}
