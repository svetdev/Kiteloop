import Foundation

/// The two transcripts the Autopilot's one pane switches between.
package enum AutopilotTranscriptTab: String, CaseIterable, Sendable {
    case worker
    case reviewer

    /// The tab of the agent that runs `nodeID` — nil for a node no agent runs
    /// (the QA flow's `clean` and `harden` commands) and for the terminal nodes,
    /// which leave the pane where it was. The QA flow's `specify` and `qa`
    /// stages are run by the worker agent (`QAFlowStages.apply`), so they show
    /// Worker; `reviewer-clarify` is `BacklogAutopilot.reviewerClarifyNodeID`,
    /// the reviewer asked again for its verdict.
    package static func owner(ofNode nodeID: String) -> AutopilotTranscriptTab? {
        switch nodeID {
        case QAFlowStages.specifyNodeID, QAFlowStages.workerNodeID, QAFlowStages.qaNodeID:
            return .worker
        case "reviewer", "reviewer-clarify":
            return .reviewer
        default:
            return nil
        }
    }
}

/// Which transcript the Autopilot's pane shows, and which tab carries a dot.
///
/// The pane follows the run: entering a node shows the tab of the agent that
/// runs it. A tab the person picks during a run holds until that run ends,
/// whatever stage comes next. A tab whose transcript grows while it is not
/// shown carries a dot until it is shown.
package struct AutopilotTranscriptTabs: Equatable, Sendable {
    package private(set) var shown: AutopilotTranscriptTab = .worker
    package private(set) var isPinned = false
    package private(set) var unseen: Set<AutopilotTranscriptTab> = []

    package init() {}

    /// The run entered `nodeID`. A pinned pane stays where the person put it.
    package mutating func enter(node nodeID: String) {
        guard !isPinned, let owner = AutopilotTranscriptTab.owner(ofNode: nodeID) else { return }
        show(owner)
    }

    /// The person clicked `tab` — the shown one included. While a run is going
    /// that pins the pane for the rest of it.
    package mutating func pick(_ tab: AutopilotTranscriptTab, duringRun: Bool) {
        show(tab)
        if duringRun { isPinned = true }
    }

    /// New messages landed in `tab`'s transcript. When the worker and the
    /// reviewer are one agent the two transcripts are the same messages, so
    /// neither is unseen.
    package mutating func output(on tab: AutopilotTranscriptTab, sameAgent: Bool) {
        guard tab != shown, !sameAgent else { return }
        unseen.insert(tab)
    }

    /// A run started: no pin carries over from before it, and the transcripts
    /// it clears have nothing unseen in them.
    package mutating func startRun() {
        isPinned = false
        unseen = []
    }

    /// The run ended, and with it the person's pick.
    package mutating func endRun() {
        isPinned = false
    }

    private mutating func show(_ tab: AutopilotTranscriptTab) {
        shown = tab
        unseen.remove(tab)
    }
}
