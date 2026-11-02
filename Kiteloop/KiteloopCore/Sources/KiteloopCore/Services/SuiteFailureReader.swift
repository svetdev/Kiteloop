import Foundation

/// Reads `./scripts/run-unit-suite.sh --last`'s own readout — `show_last` in
/// that script — into one finding per test the newest recorded row names as not
/// having passed. The flake ledger only ever names a test that decided both
/// ways at one commit, so a test that simply fails, run after run, was recorded
/// by the suite and read by nobody:
/// `KiteloopTests.ClaudeCodeCLIRuntimeTests.testReleasingARuntimeUnderABusyReaderNeverDeadlocks`
/// was named failing in four consecutive rows and drafted by no instrument,
/// while a test that flipped once got an item automatically.
///
/// The shape parsed is exactly what `show_last` prints — one cell per line, its
/// label at two spaces of indent and its value beside it:
/// ```
/// run-unit-suite: last recorded run
///   when    2026-09-10T07:57:43Z
///   commit  445afbbd (dirty tree)
///   tally   ✘ 4194 tests, 1 failing
///   failing FooTests.testA, BarTests.testB
/// ```
/// The names are comma-separated, and `show_last` prints them under `hung`
/// instead of `failing` on a row whose tally says this script ended the run at
/// its ceiling — those cases never came back, which is a different fact about
/// them than having been reported as failures, and the finding's evidence says
/// which of the two it read. The newest row is read whatever its tree cell
/// says; `when`, `commit` and `tally` ride along as evidence so a worker sees
/// the tree the reading was taken against rather than this reader guessing at
/// it for them.
package enum SuiteFailureReader {

    /// The cells carried onto every finding, in the order `show_last` prints
    /// them. `commit` brings its own `(dirty tree)` / `(clean tree)` note, so
    /// the tree the measurement describes is quoted rather than judged here.
    private static let contextLabels = ["when", "commit", "tally"]

    /// What the finding's first evidence line says the readout said. The two
    /// are not the same claim: a `failing` name was reported as a failure, a
    /// `hung` name is a case the run never got an answer for.
    private static let failingEvidence =
        "named in the failing cell of the newest row of docs/suite-status.md"
    private static let hungEvidence =
        "named in the newest row of docs/suite-status.md as a case that never came back — "
        + "the run was ended at its ceiling rather than this test reporting a failure"

    package static func read(_ output: String) -> [SignalFinding] {
        let cells = cells(in: output)
        guard let (evidence, named) = namedTests(in: cells) else { return [] }
        let context = contextLabels.compactMap { label in cells[label].map { "\(label) \($0)" } }
        return named.map { test in
            SignalFinding(instrument: .redSuite, key: test, title: test,
                          evidence: [evidence] + context)
        }
    }

    /// The tests the readout names, and which line named them. `hung` wins when
    /// both are somehow present: it is the more specific reading of the same
    /// recorded cell, and `show_last` prints one or the other, never both.
    /// Nil when neither line is there at all, and when the line is there but
    /// names nothing — a row that failed no tests carries `failing —`.
    private static func namedTests(in cells: [String: String]) -> (evidence: String, tests: [String])? {
        for (label, evidence) in [("hung", hungEvidence), ("failing", failingEvidence)] {
            guard let value = cells[label] else { continue }
            let tests = testNames(in: value)
            return tests.isEmpty ? nil : (evidence, tests)
        }
        return nil
    }

    /// A cell's comma-separated names, with the dash a row that named no test
    /// carries dropped rather than read as a test called `—`.
    private static func testNames(in value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "—" }
    }

    /// The readout's labelled cells. A cell sits at exactly two spaces of
    /// indent with its label first and its value padded out beside it; the
    /// header and the "no suite run has been recorded yet" lines sit at no
    /// indent and carry no cell. The first line to claim a label keeps it, so
    /// nothing later in the readout can overwrite a cell that was printed.
    private static func cells(in output: String) -> [String: String] {
        var cells: [String: String] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard rawLine.hasPrefix("  "), !rawLine.hasPrefix("   ") else { continue }
            let parts = rawLine.dropFirst(2).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let label = String(parts[0])
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if cells[label] == nil, !value.isEmpty { cells[label] = value }
        }
        return cells
    }
}
