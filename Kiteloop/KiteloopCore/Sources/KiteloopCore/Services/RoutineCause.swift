import Foundation

/// What set a routine's firing off, as far as the runner can tell.
package enum RoutineCause: Equatable, Sendable {
    /// Something outside the routines: the routine's schedule, a person
    /// pressing Run now, or its webhook.
    case outside
    /// An event or a folder's change that fell inside a routine's turn. The
    /// set is that turn's chain — the routines that led to it, its own
    /// included (`RoutineTurnWindows`).
    case chain(Set<String>)
    /// An event or a folder's change that fell inside no turn a routine is
    /// known to have started. A person may have made it, or something outside
    /// the app — or a routine's turn, by a path nobody followed: another
    /// agent it asked, a process it left running.
    case unattributed
}

/// What keeps routines from firing each other without end, through the
/// events their turns raise and the folders they write to.
///
/// It needs no count. A chain of routines is as long as the person made it,
/// and ends by itself when no routine comes round twice:
///
/// * **A routine is in a chain once.** A cause that fell inside a routine's
///   turn fires a routine that is not yet in that turn's chain, and the turn
///   it starts carries the chain with the routine added. One already in the
///   chain is refused, so A → B → C runs and A → B → A stops at the second A.
///   The longest chain is every routine once.
/// * **Where the chain is not known, everything since the last outside cause
///   is taken for one.** An unattributed cause may be a routine's doing, so
///   the routines that fired on a trigger in a project since a schedule, Run
///   now or a webhook last fired one there are treated as a single chain: a
///   routine that fired in it is refused once another routine has fired after
///   it. B → A → B stops at the second B whether or not anyone saw how B's
///   turn reached A. A routine fired again and again with no other between —
///   an inbox filling up — is one routine, not two firing each other, and is
///   not refused here; the budgets still bound it.
package struct RoutineLoopGuard: Sendable {
    /// Why a trigger's firing is refused.
    package enum Refusal: Equatable, Sendable {
        /// The cause fell inside a turn the routine started or led to.
        case inItsOwnChain
        /// The routine fired on a trigger, another did after it, and nothing
        /// from outside has fired a routine in the project since.
        case tookTurns
    }

    /// The routines that fired on a trigger in each project since an outside
    /// cause last fired one there, and the latest of them.
    private var stretches: [String: (fired: Set<String>, last: String)] = [:]

    package init() {}

    /// Why `routine` must not fire in `project` on `cause`; nil when it may.
    package func refusal(of routine: String, in project: String, cause: RoutineCause) -> Refusal? {
        switch cause {
        case .outside:
            return nil
        case .chain(let chain) where chain.contains(routine):
            return .inItsOwnChain
        case .chain, .unattributed:
            guard let stretch = stretches[project], stretch.fired.contains(routine), stretch.last != routine else {
                return nil
            }
            return .tookTurns
        }
    }

    /// `routine`'s prompt was sent in `project` on `cause` — started, or
    /// queued behind a turn. Returns the chain its turn carries.
    @discardableResult
    package mutating func sent(_ routine: String, in project: String, cause: RoutineCause) -> Set<String> {
        switch cause {
        case .outside:
            stretches[project] = nil
            return [routine]
        case .chain(let chain):
            note(routine, in: project)
            return chain.union([routine])
        case .unattributed:
            note(routine, in: project)
            return [routine]
        }
    }

    private mutating func note(_ routine: String, in project: String) {
        var fired = stretches[project]?.fired ?? []
        fired.insert(routine)
        stretches[project] = (fired, routine)
    }
}
