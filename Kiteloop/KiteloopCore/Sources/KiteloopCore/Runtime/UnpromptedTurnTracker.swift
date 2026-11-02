import Foundation

/// What one line of a session's stdout is, as far as the time between turns
/// is concerned.
///
/// A turn Kiteloop prompted ends at its `result`. The CLI can then start a
/// turn of its own — when a background shell or subagent it launched
/// finishes, it tells the model and lets it answer — which opens with a
/// `system`/`init` line (or, from a CLI that sends none, the first assistant
/// line) and ends at a `result` like any other.
package enum BetweenTurnsLine: Equatable, Sendable {
    /// A notice about background work (`AgentActivityEvent.subtypes`).
    case activityNotice
    /// The first line of a turn: `system`/`init`, or anything the assistant
    /// said.
    case turnOpener
    /// The line that ends a turn.
    case result
    /// Anything else: a hook line, a `user` line, a notice nothing reads.
    case other

    /// The kind of a line, from its top-level `type` and, for a `system`
    /// line, its `subtype`. A `rate_limit_event` arrives as its own type and
    /// is a notice like the `system` ones.
    package static func of(type: String, subtype: String?) -> BetweenTurnsLine {
        switch type {
        case "system":
            if subtype == "init" { return .turnOpener }
            return AgentActivityEvent.subtypes.contains(subtype ?? "") ? .activityNotice : .other
        case AgentActivityEvent.rateLimitType:
            return .activityNotice
        case "assistant":
            return .turnOpener
        case "result":
            return .result
        default:
            return .other
        }
    }
}

/// Whether a session is in a turn nobody prompted, and what to do with a
/// line that arrives while no prompted turn is listening.
///
/// The runtime asks this only for a line with no turn to go to. It never
/// reorders anything: a line either goes to the unprompted turn's own stream,
/// waits for the next turn (a notice), or is dropped.
package struct UnpromptedTurnTracker: Equatable, Sendable {

    /// What the runtime does with the line.
    package enum Action: Equatable, Sendable {
        /// Keep it for whichever turn opens next.
        case hold
        /// A turn opens with this line: give it a stream of its own, handed to
        /// whoever listens for unprompted turns.
        case open
        /// The unprompted turn ended with this line: sends waiting for it go.
        case close
        /// Nothing to do with it.
        case drop
    }

    /// True from an unprompted turn's opening line to its `result`, whether
    /// or not anyone is listening to it. A send made while it is open waits:
    /// the CLI answers one prompt at a time, and a send registered now would
    /// be handed the rest of this turn and end at its `result`.
    package private(set) var isOpen = false

    package init() {}

    /// Routes a line that arrived with no turn listening. `canDeliver` is
    /// whether anyone listens for unprompted turns on this session; a turn
    /// that opens unheard is still open until its `result`, so sends still
    /// wait for it, but its lines go nowhere.
    ///
    /// An open turn with no listening stream is one whose consumer went away
    /// or that nobody heard from the start: its notices are held for the next
    /// turn as they would be between turns, and its `result` closes it.
    package mutating func route(_ line: BetweenTurnsLine, canDeliver: Bool) -> Action {
        switch line {
        case .activityNotice:
            return .hold
        case .turnOpener where !isOpen:
            isOpen = true
            return canDeliver ? .open : .drop
        case .result where isOpen:
            isOpen = false
            return .close
        default:
            return .drop
        }
    }

    /// A `result` was handed to a listening stream. True when that ended an
    /// unprompted turn, which is when the sends waiting for it may go.
    package mutating func resultDelivered() -> Bool {
        defer { isOpen = false }
        return isOpen
    }
}
