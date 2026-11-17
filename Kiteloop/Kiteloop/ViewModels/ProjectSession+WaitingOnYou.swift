import Foundation
import KiteloopCore

extension ProjectSession {

    /// This project, read down to what `WaitingOnYou` needs: its gated items,
    /// the agents holding something only a person can answer, its stale flags
    /// and the inbox notices that dress them.
    ///
    /// The one place that reading is built — the waiting drawer and
    /// `GET /v1/attention` both call it, so the two cannot disagree about
    /// which rows exist. `pending` is passed in rather than read here: the
    /// store is an actor, and the drawer reads this on `body`'s path.
    func waitingReading(pending: [NotificationItem]) -> WaitingOnYou.ProjectReading {
        let agents = orchestrator.agents
        return WaitingOnYou.ProjectReading(
            id: project.id,
            name: project.rootURL.lastPathComponent,
            path: project.rootURL.path(percentEncoded: false),
            gatedItems: backlogViewModel.gatedItemsForDrawer,
            // An agent holding an `ask_human`, an unanswered plan card or
            // a card its session is stopped on — the same flags its chat
            // draws the answer box and the cards' buttons from, so the
            // row goes the moment each is answered.
            askingAgents: chatViewModels
                .filter { $0.value.pendingHumanToolCallID != nil || $0.value.hasOpenPlanCard || $0.value.openPromptCount > 0 }
                .map { agentID, _ in
                    .init(id: agentID,
                          name: agents.first { $0.id == agentID }?.name ?? agentID)
                },
            // Read from the cache `refreshStaleFlags` keeps current, not
            // recomputed here: the drawer reads this on `body`'s own path, and
            // a live git log per open item is exactly the synchronous I/O it
            // must never do.
            staleItems: backlogViewModel.staleFlags.map { flag in
                .init(id: flag.itemID, title: flag.title, status: flag.status, lastTouched: flag.lastTouched)
            },
            pending: pending
        )
    }
}
