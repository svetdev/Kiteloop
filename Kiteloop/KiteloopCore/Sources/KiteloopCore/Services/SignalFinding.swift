import Foundation

/// One candidate the Planner did not have to imagine — a fact one of the repo's
/// own instruments already recorded: a test that flips outcome with no code
/// change, a function that is both complex and frequently changed, a backlog
/// item that escaped review, or a test the newest recorded suite row names as
/// not having passed. `SignalDrafting` turns a finding into an item; the
/// finding itself carries only what its instrument observed.
package struct SignalFinding: Sendable, Equatable {
    /// Which instrument produced this finding — what decides the item's kind
    /// and how its stable key is shaped.
    package enum Instrument: String, Sendable {
        case flake
        case hotspot
        case escapedDefect
        /// A test the newest row of `docs/suite-status.md` names as not having
        /// passed — read by `SuiteFailureReader`, which is a different reading
        /// of the same record `flake` comes from: a flip needs both verdicts at
        /// one commit, a red row needs only the one.
        case redSuite
    }

    /// bug or refactor — the shape `SignalDrafting` writes the item in.
    package enum Kind: String, Sendable {
        case bug
        case refactor
    }

    package let instrument: Instrument
    /// What makes two reads of the same instrument the same finding — a test's
    /// name, a function's `file:line`, or a backlog item's id. Two findings
    /// sharing an instrument and a key are the same finding, filed once.
    package let key: String
    /// A short label for the thing the finding is about — the test's name, the
    /// function's declaration, the item's id. Plain, not phrased as an item
    /// title: `SignalDrafting` owns that framing.
    package let title: String
    /// The lines a drafted item's body quotes verbatim — the flip count, the
    /// churn × complexity score, the reopen date.
    package let evidence: [String]

    package var kind: Kind { instrument == .hotspot ? .refactor : .bug }

    package init(instrument: Instrument, key: String, title: String, evidence: [String]) {
        self.instrument = instrument
        self.key = key
        self.title = title
        self.evidence = evidence
    }
}
