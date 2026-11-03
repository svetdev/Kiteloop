import KiteloopCore

/// What the leading glyph on a project tab says the project is doing.
///
/// The rule used to be "is a model emitting tokens", which answers a different
/// question than the one a person reading the tab is asking. A run spends most
/// of its wall clock inside a tool call — an `xcodebuild` is minutes of silence
/// with nothing streaming — so the tab went dark for exactly the stretch where
/// "is this still moving?" is worth asking, while the Autopilot panel next to it
/// read `Running 1/1`.
///
/// So `isRunning` comes from the project's run state (`BacklogAutopilot`'s
/// in-flight run, the same answer the run-busy guard and `GET /v1/projects`
/// give), and streaming stays in the union rather than being replaced: someone
/// chatting to an agent outside a run is activity too. A project whose run state
/// isn't known is not running — unknown reads as idle, never as busy.
enum ProjectTabIndicator: Equatable {
    /// Something here is waiting on a person: an item at the approval gate, or
    /// an agent holding a question or plan. Shown as a raised hand.
    case waitingOnYou
    /// Something is happening in this project: a run in flight, a live turn, or
    /// both. Shown as a spinner.
    case busy
    /// Nothing is happening, but a turn finished here while you were elsewhere.
    case unread
    /// Nothing to say — the plain folder.
    case idle

    /// Waiting on you wins over everything: an agent stopped on a question is
    /// mid-turn, so it would otherwise read as busy — a project getting on with
    /// its work. Busy wins over unread for the same reason it always has: a
    /// project that is still working hasn't finished anything for you to have
    /// missed yet.
    static func forProject(isRunning: Bool, isStreaming: Bool, isUnread: Bool,
                           isWaitingOnYou: Bool = false) -> ProjectTabIndicator {
        if isWaitingOnYou { return .waitingOnYou }
        if isRunning || isStreaming { return .busy }
        if isUnread { return .unread }
        return .idle
    }
}

extension ProjectTabIndicator {
    /// The projects with a gate a person clears: an approval or a question.
    /// A stale item is not one — nothing on the tab clears it.
    static func waitingProjectIDs(in waiting: WaitingOnYou) -> Set<String> {
        Set(waiting.rows.filter(\.clearedByAPerson).map(\.projectID))
    }
}

private extension WaitingOnYou.Row {
    var clearedByAPerson: Bool {
        switch gate {
        case .approval, .question: return true
        case .stale: return false
        }
    }
}

/// Which project tab a keyboard shortcut lands on: ⌘1…⌘9 by position, ⌘⇧[ /
/// ⌘⇧] by neighbour. Pure over the ids in tab-strip order, so the rule is
/// testable without a window.
enum ProjectTabNavigation {
    /// The id at 1-based `number`, or nil when no tab sits there.
    static func project(atShortcut number: Int, in ids: [String]) -> String? {
        ids.indices.contains(number - 1) ? ids[number - 1] : nil
    }

    /// The id `offset` tabs from `activeID`, wrapping at both ends. Nothing
    /// open is nil; an active id that is nil or not in the list falls back to
    /// the first tab.
    static func neighbour(of activeID: String?, in ids: [String], offset: Int) -> String? {
        guard let first = ids.first else { return nil }
        guard let activeID, let index = ids.firstIndex(of: activeID) else { return first }
        let count = ids.count
        return ids[((index + offset) % count + count) % count]
    }
}

/// Whether closing a project tab asks first, and what the question says. The
/// same spinner that says a run is in flight is the thing a close would tear
/// down, so a close then asks; a project with nothing in flight closes at once.
enum ProjectClosePrompt {
    /// The confirmation's message, or nil when the close needs no confirmation.
    /// `item` is the in-flight item for this project, when one is known.
    static func message(isRunning: Bool, item: ActiveOrchestratorTracker.InFlightItem?) -> String? {
        guard isRunning else { return nil }
        guard let item else {
            return "A run is in flight in this project. Closing it stops every agent working on it."
        }
        return "A run is in flight on “\(item.headline)”. Closing the project stops every agent working on it."
    }
}
