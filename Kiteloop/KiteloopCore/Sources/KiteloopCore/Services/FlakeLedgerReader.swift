import Foundation

/// Reads `./scripts/run-unit-suite.sh --flakes`'s own report — `show_flakes` in
/// that script — into one finding per test it names: a test that has recorded
/// both a failing and a passing run at the same commit, which is the one shape
/// that script calls a flake without guessing.
///
/// The shape parsed is exactly what `show_flakes` prints:
/// ```
/// run-unit-suite: flake ledger
///   SomeTests.testThing
///     3 flips at abc123, def456 — 2026-08-01T00:00:00Z .. 2026-08-10T00:00:00Z
/// ```
/// A test name sits at two spaces of indent; its flip line sits at four. Anything
/// else — the header, a blank line, the "none —" line when the ledger is empty —
/// is not a finding.
package enum FlakeLedgerReader {
    package static func read(_ output: String) -> [SignalFinding] {
        var findings: [SignalFinding] = []
        var pendingTest: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("    "), let test = pendingTest {
                let detail = line.trimmingCharacters(in: .whitespaces)
                findings.append(SignalFinding(instrument: .flake, key: test, title: test,
                                              evidence: [detail]))
                pendingTest = nil
            } else if line.hasPrefix("  "), !line.hasPrefix("    ") {
                let name = line.trimmingCharacters(in: .whitespaces)
                pendingTest = (name.isEmpty || name.hasPrefix("none —")) ? nil : name
            } else {
                pendingTest = nil
            }
        }
        return findings
    }
}
