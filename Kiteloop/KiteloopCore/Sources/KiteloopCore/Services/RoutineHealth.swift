import Foundation

/// Which routines last went badly, as `GET /health` reports them: **did a
/// routine lose its occurrence, or is one owed?** — answerable by a monitor
/// polling the unauthenticated probe, without a token.
///
/// A routine is listed when the newest entry in its ledger is `refused` (final:
/// the occurrence is lost), `waiting` (owed: its project is not open or the
/// fleet is held) or `skipped`. One whose last run started or queued, or which
/// has never run, is left out — so an app with nothing to report answers an
/// empty list, the healthy state and the shipped one.
package enum RoutineHealth {

    /// How loudly an entry asks to be acted on.
    package enum Severity: String, Sendable {
        case error, warning, info
    }

    /// One routine whose last run a monitor should see.
    package struct Entry: Equatable, Sendable {
        package let routine: String
        package let project: String
        package let outcome: RoutineRun.Outcome
        package let reason: String?
        package let at: Date
        package let severity: Severity

        /// The entry as `/health` returns it; `reason` only when the run has one.
        package var json: [String: Any] {
            var out: [String: Any] = ["routine": routine, "project": project, "outcome": outcome.rawValue,
                                      "at": ISO8601DateFormatter().string(from: at),
                                      "severity": severity.rawValue]
            if let reason { out["reason"] = reason }
            return out
        }
    }

    /// The severity an outcome is reported at; nil for one that is not reported.
    package static func severity(of outcome: RoutineRun.Outcome) -> Severity? {
        switch outcome {
        case .refused: return .error
        case .waiting: return .warning
        case .skipped: return .info
        case .started, .queued: return nil
        }
    }

    /// Every routine in `routines` whose newest run, read through `lastRun`,
    /// is one a monitor should act on — in the order the routines are kept.
    package static func attention(routines: [Routine], lastRun: (String) -> RoutineRun?) -> [Entry] {
        routines.compactMap { routine in
            guard let run = lastRun(routine.id), let severity = severity(of: run.outcome) else { return nil }
            return Entry(routine: routine.id, project: routine.project, outcome: run.outcome,
                         reason: run.reason, at: run.at, severity: severity)
        }
    }
}
