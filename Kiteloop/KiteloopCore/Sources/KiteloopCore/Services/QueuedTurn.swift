import Foundation

/// Follows a message that waited in a chat's queue into the turn it gets, for
/// whoever asked to be told when that turn begins and ends.
///
/// A queued message is replayed after the turn it waited behind, and only
/// then does it start a turn of its own — or none, when it is a command the
/// chat answers itself. The chat says which message it is replaying, and that
/// a turn began or ended; the observer of the message being replayed is told
/// of the turn that begins next, and of no other.
package struct QueuedTurn {
    /// Told `true` when the message's turn begins and `false` when it ends.
    package typealias Observer = @MainActor (Bool) -> Void

    /// The observer of the message being replayed, until its turn begins.
    private var replayed: Observer?
    /// The observer of the turn that is running.
    private var running: Observer?

    package init() {}

    /// The chat is replaying a queued message `observer` asked about; nil
    /// when nobody asked, or once the replay is over.
    package mutating func replaying(_ observer: Observer?) {
        replayed = observer
    }

    /// A turn began: the replayed message's, if one is being replayed.
    @MainActor
    package mutating func began() {
        running = replayed
        replayed = nil
        running?(true)
    }

    /// The running turn ended.
    @MainActor
    package mutating func ended() {
        let observer = running
        running = nil
        observer?(false)
    }
}
