import Foundation
import os.log

private let signalSourcesLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "signal-sources")

/// Gathers one `[SignalFinding]` for a project by running the instruments
/// `FlakeLedgerReader`, `SuiteFailureReader` and `HotspotReportReader` parse
/// and reading the approvals ledger `EscapedDefectReader` parses — the piece
/// that was missing between the readers and
/// `SignalDrafting.drafts(for:existingIDs:)`, which none of them had ever been
/// handed an instrument's actual output.
///
/// Each source is independent: a script that exits non-zero, one that times
/// out, or a ledger that exists and cannot be read costs only that source's
/// findings, logged and swallowed rather than thrown, so one broken instrument
/// never hides what the others found. A ledger that is simply not there is not
/// a failure at all — a project that has approved nothing has escaped nothing —
/// so it yields no findings and logs nothing.
package enum SignalSources {
    /// `./scripts/run-unit-suite.sh --flakes` reads `docs/suite-status.md` and
    /// starts no build, so this is generous only against a slow disk, not
    /// against real work the way a build's timeout would need to be.
    package static let flakeTimeout: TimeInterval = 120
    /// `quality/bin/report-hotspots.py` shells out to SwiftLint over
    /// `crap.sources` and to `git log` — more than the flake ledger's plain
    /// read, less than a build.
    package static let hotspotTimeout: TimeInterval = 180
    /// `./scripts/run-unit-suite.sh --last` reads the newest row of
    /// `docs/suite-status.md` and asks git two rev-list questions — the same
    /// shape of read as `--flakes`, starting no build, and generous for the
    /// same reason.
    package static let redSuiteTimeout: TimeInterval = 120

    /// The environment every child is spawned with. Inheriting Kiteloop's
    /// own is not enough: a Kiteloop launched from Finder or the Dock carries
    /// `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, with no Homebrew on it, and
    /// `report-hotspots.py` fails its SwiftLint lookup and exits 2 before
    /// measuring anything — an empty hotspot list, indistinguishable from a
    /// repository with no hotspots, on a machine where SwiftLint is installed.
    /// `RunEnvironment` is the app's one answer to where a child looks for a
    /// tool; `gather` reads it once and hands it to every spawn, so they cannot
    /// drift apart.
    package static func childEnvironment() -> [String: String] {
        RunEnvironment.environment(projectRoot: nil)
    }

    /// - Parameters:
    ///   - repoRoot: where `scripts/run-unit-suite.sh` and
    ///     `quality/bin/report-hotspots.py` are run from — each is written to
    ///     resolve its own paths from the project root.
    ///   - approvalsLedgerURL: the JSONL ledger `TaskMetricStore.appendApprovalEvent`
    ///     writes — shared across every project the app has open.
    ///   - projectPath: which project's reopens count — passed straight through
    ///     to `EscapedDefectReader.read(_:projectPath:)`.
    package static func gather(repoRoot: URL, approvalsLedgerURL: URL, projectPath: String) -> [SignalFinding] {
        let environment = childEnvironment()
        return flakeFindings(repoRoot: repoRoot, environment: environment)
            + redSuiteFindings(repoRoot: repoRoot, environment: environment)
            + hotspotFindings(repoRoot: repoRoot, environment: environment)
            + escapedDefectFindings(approvalsLedgerURL: approvalsLedgerURL, projectPath: projectPath)
    }

    private static func flakeFindings(repoRoot: URL, environment: [String: String]) -> [SignalFinding] {
        let script = repoRoot.appending(path: "scripts/run-unit-suite.sh")
        let result = SubprocessOutput.runWithDeadline(
            executable: script.path(percentEncoded: false),
            arguments: ["--flakes"],
            directory: repoRoot,
            environment: environment,
            timeout: flakeTimeout
        )
        guard !result.timedOut, result.status == 0 else {
            signalSourcesLog.error("""
                run-unit-suite.sh --flakes \
                \(result.timedOut ? "timed out" : "exited \(result.status)", privacy: .public) — \
                no flake findings this pass
                """)
            return []
        }
        return FlakeLedgerReader.read(result.output)
    }

    private static func redSuiteFindings(repoRoot: URL, environment: [String: String]) -> [SignalFinding] {
        let script = repoRoot.appending(path: "scripts/run-unit-suite.sh")
        let result = SubprocessOutput.runWithDeadline(
            executable: script.path(percentEncoded: false),
            arguments: ["--last"],
            directory: repoRoot,
            environment: environment,
            timeout: redSuiteTimeout
        )
        guard !result.timedOut, result.status == 0 else {
            signalSourcesLog.error("""
                run-unit-suite.sh --last \
                \(result.timedOut ? "timed out" : "exited \(result.status)", privacy: .public) — \
                no red-suite findings this pass
                """)
            return []
        }
        return SuiteFailureReader.read(result.output)
    }

    private static func hotspotFindings(repoRoot: URL, environment: [String: String]) -> [SignalFinding] {
        let script = repoRoot.appending(path: "quality/bin/report-hotspots.py")
        let result = SubprocessOutput.runWithDeadline(
            executable: script.path(percentEncoded: false),
            arguments: [],
            directory: repoRoot,
            environment: environment,
            timeout: hotspotTimeout
        )
        guard !result.timedOut, result.status == 0 else {
            signalSourcesLog.error("""
                report-hotspots.py \
                \(result.timedOut ? "timed out" : "exited \(result.status)", privacy: .public) — \
                no hotspot findings this pass
                """)
            return []
        }
        return HotspotReportReader.read(result.output, ceiling: HotspotReportReader.complexityCeiling(repoRoot: repoRoot))
    }

    /// The approvals ledger's bytes — empty for a ledger that is not there,
    /// `nil` only for one that is there and could not be read.
    ///
    /// The two are different failures and only one of them is a failure. A
    /// project the app has never approved anything in has no ledger, has
    /// escaped nothing, and announcing that as a read error trains the reader
    /// to ignore the line that means a real one.
    ///
    /// Bytes rather than a string: the ledger is appended to while the app can
    /// be killed mid-write, and a last line cut part-way through a multi-byte
    /// character is not valid UTF-8. Reading the file as one string failed
    /// outright on that byte and cost the pass every escaped defect the
    /// complete lines before it carried; `EscapedDefectReader` decodes each
    /// line on its own, so only the cut line is lost.
    package static func approvalsLedgerBytes(at url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return Data() }
        return try? Data(contentsOf: url)
    }

    private static func escapedDefectFindings(approvalsLedgerURL: URL, projectPath: String) -> [SignalFinding] {
        guard let jsonl = approvalsLedgerBytes(at: approvalsLedgerURL) else {
            signalSourcesLog.error("""
                approvals ledger unreadable at \(approvalsLedgerURL.path(percentEncoded: false), privacy: .public) — \
                no escaped-defect findings this pass
                """)
            return []
        }
        return EscapedDefectReader.read(jsonl, projectPath: projectPath)
    }
}
