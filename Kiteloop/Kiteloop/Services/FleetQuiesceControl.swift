import Foundation
import os.log

private let fleetControlLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "fleet-quiesce")

/// The app's own caller of `FleetQuiesce` — the footer's Quiesce/Resume control
/// and the quit offer, driving the same seam `POST /v1/fleet/quiesce` drives.
///
/// One implementation, two callers: nothing here decides which queues are held,
/// what counts as drained, or what happens to a run already in flight. It calls
/// `quiesce()`, `resume()` and `reading()` and keeps the last answer, because a
/// SwiftUI body cannot await one — the reading crosses an actor hop per project.
/// That is the whole of this type's job: hold the latest reading, say whether a
/// call of its own is in flight, and wait out a drain a quit is pending on.
@MainActor
@Observable
final class FleetQuiesceControl {

    private let fleet: FleetQuiesce

    /// The last reading taken. Nil until the first one lands, which is what the
    /// footer draws nothing on — an unread fleet is not a fleet taking work, and
    /// saying so for the two seconds before the first reading would be a state
    /// nobody is in.
    private(set) var reading: FleetQuiesce.Reading?

    /// A quiesce or resume this app started, still running.
    private(set) var isBusy = false

    /// Whether a quit is waiting on the drain. Set by the quit offer, cleared by
    /// a resume or by the drain arriving.
    private(set) var isQuittingWhenDrained = false

    /// Called on the main actor once the fleet has drained with a quit pending.
    /// The app delegate puts the terminate here rather than this type calling
    /// `NSApp` itself, so nothing in Services reaches for AppKit.
    var onDrainedForQuit: (() -> Void)?

    init(fleet: FleetQuiesce) {
        self.fleet = fleet
    }

    /// Whether the fleet is refusing new work right now — the same flag
    /// `POST /v1/runs` and the scheduler read directly from `FleetQuiesce`.
    /// Exposed here so the app's own Start button can read it too, rather
    /// than being the third caller `FleetQuiesce`'s own doc comment already
    /// names two of.
    var isQuiesced: Bool { fleet.isQuiesced }

    /// What the footer draws, or nil before the first reading.
    var status: FleetQuiesceStatus? {
        reading.map {
            FleetQuiesceStatus(reading: $0, isBusy: isBusy, isQuittingWhenDrained: isQuittingWhenDrained)
        }
    }

    /// Take a fresh reading. Starts and stops nothing — safe to call on a
    /// cadence, which is how the footer tracks a drain it is not driving.
    func refresh() async {
        reading = await fleet.reading()
    }

    /// Hold every advancing queue and close the gate.
    func quiesce() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            reading = await fleet.quiesce()
            isBusy = false
        }
    }

    /// Lift the hold and pick back up exactly the queues the quiesce held.
    ///
    /// Also cancels a quit that was waiting on the drain: asking the fleet to
    /// take work again is the opposite of leaving, and a quit that fired anyway
    /// once the last run landed would be a shutdown nobody asked for.
    func resume() {
        guard !isBusy else { return }
        isQuittingWhenDrained = false
        isBusy = true
        Task {
            await fleet.resume()
            await refresh()
            isBusy = false
        }
    }

    /// The quit offer's first choice: hold the fleet now, then quit once the
    /// last run has finished at its own gate.
    ///
    /// The wait is here rather than inside `applicationShouldTerminate` so the
    /// app stays alive and answering while it runs — the footer shows what is
    /// still finishing, and the operator can call it off with Resume. A quit
    /// parked inside a `terminateLater` would show them a beachball instead.
    func quiesceAndQuitWhenDrained() {
        isQuittingWhenDrained = true
        isBusy = true
        Task {
            reading = await fleet.quiesce()
            isBusy = false
            while isQuittingWhenDrained {
                await refresh()
                if reading?.drained == true { break }
                try? await Task.sleep(for: .milliseconds(FleetQuiesce.drainPollMilliseconds))
            }
            // Cancelled by a resume while we were waiting: the operator has said
            // the fleet should take work again, so there is no quit left to make.
            guard isQuittingWhenDrained else { return }
            isQuittingWhenDrained = false
            fleetControlLog.info("Fleet drained with a quit pending — quitting")
            onDrainedForQuit?()
        }
    }
}
