import Foundation
import os.log

private let fleetLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "fleet-quiesce")

/// "Stop taking new work everywhere, and tell me when the last run has finished."
///
/// Restarting Kiteloop safely means reaching a state where nothing is mid-item: an
/// interrupted run returns to `ready` at the next launch and re-runs from scratch,
/// losing the few minutes it had already spent. Reaching that state by hand meant
/// killing every external driver and then polling `GET /v1/projects` until no
/// project reported a run — 120–520 seconds of it, six times on 2026-08-10/11, and
/// twice the idle window closed before it could be used, because the drivers start
/// the next item within seconds of one ending.
///
/// This is the fleet-level verb over the per-project `pause()` that already exists,
/// plus the two things polling could not give: a gate, so the window cannot close
/// behind the operator, and one answer to "is it drained yet?".
///
/// **The gate is the load-bearing half.** Pausing alone does not stop new work:
/// `POST /v1/runs` never consults `status`, and `BacklogAutopilot.start()`
/// *discards* a paused queue and runs anyway ("this run replaces it"). A driver on
/// its usual cadence would therefore start a fresh run into a fleet that was
/// supposedly held — which is exactly how the hand-run window kept closing. While
/// `isQuiesced` is set a run request is refused and the autonomous scheduler holds,
/// so the fleet drains monotonically instead of racing its drivers.
///
/// Nothing here is persisted, deliberately. A restart clears the flag and leaves
/// every autopilot idle, which is the state a restart is *for*. A quiesce that
/// survived one would leave the fleet silently refusing work after a crash with
/// nothing on screen to explain it, and a ledger restored across one would name
/// projects the restart had already released. So `resume` after a restart finds an
/// empty ledger and says so, rather than depending on state the restart destroyed.
@MainActor
@Observable
final class FleetQuiesce {

    /// What a quiesce did to one project.
    enum Action: String {
        /// This call paused it. It is in the ledger, so `resume` picks it back up.
        case held
        /// Already paused when the call arrived: left alone, and left *out* of the
        /// ledger, so resuming does not start a queue somebody else was holding.
        case alreadyHeld
        /// Nothing to hold. An idle autopilot has no queue, and pausing one would
        /// manufacture precisely the `inconsistent` state `reconcileStatus` exists
        /// to clear — a status claiming a run with nothing behind it. The gate is
        /// what stops an idle project taking new work.
        case idle
    }

    /// One project's line in a reading.
    struct ProjectReading {
        let id: String
        let name: String
        /// What the autopilot's own `status` reads.
        let status: String
        /// `RunState.Phase` — the derived answer `status` was checked against.
        let state: String
        let running: Bool
        let item: String?
        let heldItems: Int
        /// Whether this project is in the ledger, i.e. whether `resume` will pick
        /// it up.
        let heldByQuiesce: Bool
        /// What the quiesce call did, on the response to that call only. Nil on a
        /// plain reading, which reports state rather than a decision.
        let action: Action?
    }

    /// The whole fleet in one answer — the thing that replaces a poll per project.
    struct Reading {
        let quiesced: Bool
        /// No run in flight anywhere. The operator's restart is safe exactly when
        /// this and `quiesced` are both true.
        let drained: Bool
        /// How many projects still have a run finishing.
        let running: Int
        let projects: [ProjectReading]

        /// The one-line form, so a log or a refusal can say it without rebuilding
        /// the sentence.
        var summary: String {
            let gate = quiesced ? "quiesced" : "not quiesced"
            guard !drained else { return "\(gate), drained" }
            return "\(gate), \(running) run(s) still finishing"
        }
    }

    /// What a resume did. Skips are reported rather than swallowed: a project that
    /// is no longer paused is the normal post-restart case, and reporting it as
    /// resumed would be a lie about what is now running.
    struct ResumeOutcome {
        struct Skipped {
            let project: String
            let reason: String
        }
        let resumed: [String]
        let skipped: [Skipped]
    }

    /// Whether the fleet is refusing new work. Read by `POST /v1/runs` and by the
    /// autonomous scheduler — the two things that start runs from inside the app.
    private(set) var isQuiesced = false

    /// Canonical project ids this quiesce paused, and only those. A project that
    /// was already paused never enters, so `resume` restores exactly what it took
    /// and nothing an operator was holding for their own reasons.
    private(set) var ledger: Set<String> = []

    private let registry: ControlSessionRegistry

    /// How often `awaitDrained` looks. The same cadence `startRun` waits out a busy
    /// tail on, and far finer than the 5.3-minute median run it is watching for.
    static let drainPollMilliseconds = 500

    init(registry: ControlSessionRegistry) {
        self.registry = registry
    }

    // MARK: - Quiesce

    /// Close the gate, hold every queue that is advancing, and report where that
    /// left the fleet.
    ///
    /// Idempotent: calling it again finds everything already held, adds nothing to
    /// the ledger, and returns the current reading — so a driver retrying after a
    /// dropped connection cannot end up resuming projects it never paused.
    ///
    /// Each project is reconciled first. A stale `running` claim with no run behind
    /// it would otherwise be paused into a queue nobody can start, which is the one
    /// failure this verb must not introduce: `reconcileStatus` clears such a claim
    /// to idle, and an idle project is then left alone rather than pinned.
    func quiesce() async -> Reading {
        isQuiesced = true
        var actions: [String: Action] = [:]

        for entry in registry.openProjects {
            let autopilot = entry.autopilot
            let id = entry.session.project.id
            await autopilot.reconcileStatus(reason: "fleet quiesce")

            switch autopilot.status {
            case .idle:
                actions[id] = .idle
            case .paused:
                actions[id] = .alreadyHeld
            case .running, .reviewing:
                autopilot.pause()
                ledger.insert(id)
                actions[id] = .held
            }
        }

        let reading = await reading(actions: actions)
        fleetLog.info("Quiesced: \(reading.summary, privacy: .public)")
        return reading
    }

    /// Reopen the gate and pick back up exactly the queues this quiesce held.
    ///
    /// A ledgered project that is no longer paused is skipped with the reason —
    /// after a restart that is every one of them, since the ledger is in memory and
    /// the autopilots come back idle. Resuming is the per-project `resume()`, which
    /// opens a fresh session budget for a queue the session cost cap stopped rather
    /// than leaving it held on a spent one, so this inherits the property that
    /// pausing must not wedge anything.
    @discardableResult
    func resume() async -> ResumeOutcome {
        isQuiesced = false
        var resumed: [String] = []
        var skipped: [ResumeOutcome.Skipped] = []

        for id in ledger.sorted() {
            guard let entry = registry.entry(forProject: id) else {
                skipped.append(.init(project: id, reason: "project is no longer open"))
                continue
            }
            let name = entry.session.project.rootURL.lastPathComponent
            let autopilot = entry.autopilot
            guard autopilot.status == .paused else {
                skipped.append(.init(
                    project: name,
                    reason: "no longer paused (status: \(autopilot.status.label)) — nothing to pick up"
                ))
                continue
            }
            // Backgrounded for the same reason POST /v1/autopilot/resume backgrounds
            // it: the rest of the queue is minutes of work, and the caller asked to
            // be let go, not to be held until the fleet finishes.
            Task { await autopilot.resume() }
            resumed.append(name)
        }

        ledger.removeAll()
        fleetLog.info("Resumed \(resumed.count, privacy: .public) project(s), skipped \(skipped.count, privacy: .public)")
        return ResumeOutcome(resumed: resumed, skipped: skipped)
    }

    // MARK: - Drained

    /// Where the fleet is right now. Read from each autopilot's `runState()` — the
    /// same call `GET /v1/projects` and the run guard make — so this and they
    /// cannot come to disagree about what is running.
    func reading(actions: [String: Action] = [:]) async -> Reading {
        var projects: [ProjectReading] = []
        for entry in registry.openProjects {
            let id = entry.session.project.id
            let state = await entry.autopilot.runState()
            projects.append(ProjectReading(
                id: id,
                name: entry.session.project.rootURL.lastPathComponent,
                status: state.statusLabel,
                state: state.phase.rawValue,
                running: state.isRunning,
                item: state.inFlight?.itemID,
                heldItems: state.heldItems,
                heldByQuiesce: ledger.contains(id),
                action: actions[id]
            ))
        }
        let running = projects.filter(\.running).count
        return Reading(quiesced: isQuiesced, drained: running == 0, running: running, projects: projects)
    }

    /// Block until nothing is running, or until `timeout` elapses — the wait the
    /// operator was doing by hand with a poll loop.
    ///
    /// Returns whether it drained. A timeout is not an error and is not reported as
    /// one: the caller gets a reading that says how many are still finishing, which
    /// is a true answer to a bounded question. Answering "drained" on a timeout is
    /// the only outcome that would cost anything — that is the restart that strands
    /// an item.
    func awaitDrained(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if await reading().drained { return true }
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: UInt64(Self.drainPollMilliseconds) * 1_000_000)
        }
    }
}
