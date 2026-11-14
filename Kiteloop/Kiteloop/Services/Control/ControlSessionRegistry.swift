import Foundation
import KiteloopCore

/// App-level directory of open projects, so the local control API can find a
/// project's session and its autopilot without reaching into SwiftUI view state.
/// `MainWindow` registers an entry when a project opens and drops it on close.
@MainActor
@Observable
final class ControlSessionRegistry {
    struct Entry {
        let session: ProjectSession
        let autopilot: BacklogAutopilot
    }

    /// Keyed by canonical project path (== `ProjectSession.project.id`).
    private(set) var entries: [String: Entry] = [:]

    /// What opening a project actually did. A driver's one lever on an
    /// already-running app is "open this project", so the answer has to
    /// distinguish a fresh session from a re-read of one that was already there
    /// — reporting `opened` for a call that changed nothing is how a stale
    /// backlog stays invisible.
    enum OpenOutcome {
        case opened      // a new session was booted and registered
        case reloaded    // already open; its backlog was re-read from disk
        case failed
    }

    /// Set by `MainWindow` so the control API can open a project (which owns
    /// session state). Reports what it did once the project is registered.
    var openProject: (@MainActor (URL) async -> OpenOutcome)?

    /// The window's portfolio-level refill loop, so the control API can report
    /// what its passes did. Weak, and for the same reason as `openProject` being
    /// a closure: the window owns this, the app owns the registry, and a window
    /// that has gone must not leave the API serving a dead loop's history.
    weak var queueRefill: CoordinatorQueueRefill?

    /// Set by `KiteloopControlServer`, for the same reason `openProject` is a
    /// closure the window sets: the call has to cross a layer the registry knows
    /// nothing about. Run in `unregister` while the entry is still here, because
    /// once it is gone the server can never inspect that project's runs again —
    /// their records would stay open and read `interrupted` at the next launch.
    var finalizeRuns: (@MainActor () async -> Void)?

    /// Set by `KiteloopControlServer` on the same terms as `finalizeRuns`, and
    /// called by `MainWindow` when an autopilot starts an execution nothing else
    /// recorded — the Autopilot tab's Start button calls `BacklogAutopilot.start`
    /// directly, so its runs reached neither `POST /v1/runs` nor the scheduler and
    /// left no durable record at all. Adopting one here is what makes a run's
    /// history independent of which surface launched it.
    ///
    /// Idempotent on the server's side: a run already tracked under this execution
    /// id — which is what a control-API run is, since it is handed that same id —
    /// is not tracked a second time.
    var adoptRun: (@MainActor (_ projectID: String, _ itemID: String, _ title: String,
                               _ executionID: String, _ startedAt: Date) -> Void)?

    /// Called once a project is registered — a routine that was waiting on
    /// this project to open can run now.
    var projectOpened: (@MainActor () -> Void)?

    func register(session: ProjectSession, autopilot: BacklogAutopilot) {
        entries[session.project.id] = Entry(session: session, autopilot: autopilot)
        projectOpened?()
    }

    /// Drops a project, after giving the control server its last chance to write
    /// down how this project's runs ended — the entry is still in place for that
    /// call, and never again afterwards.
    func unregister(projectID: String) async {
        await finalizeRuns?()
        entries.removeValue(forKey: projectID)
    }

    /// The entry registered under exactly this project id, with none of
    /// `entry(forProject:)`'s fallbacks — a window adopting a live session must
    /// not pick up a different project that merely shares its folder name.
    func registeredEntry(projectID: String) -> Entry? {
        entries[projectID]
    }

    /// Resolve by canonical path, by raw path, or by trailing folder name.
    func entry(forProject key: String) -> Entry? {
        if let hit = entries[KiteloopProject.canonicalPath(key)] { return hit }
        if let hit = entries[key] { return hit }
        return entries.values.first { $0.session.project.rootURL.lastPathComponent == key }
    }

    /// Project ids in the order the window shows its tabs. The window sets it
    /// whenever that order changes — load, open, close, a tab drop — so a
    /// phone reading `GET /v1/projects` sees the same order a person sees on
    /// the Mac. Empty until the window has said, when the list falls back to
    /// name order; an id the window has not named sorts after the ones it has.
    var projectOrder: [String] = []

    /// Moves one open project before another (or to the end, on nil) the way
    /// a tab drop does — the window installs this beside `openProject`, so the
    /// control API and the drag share one code path and one saved order.
    var reorderProject: (@MainActor (_ projectID: String, _ beforeProjectID: String?) async -> Void)?

    var openProjects: [Entry] {
        let rank = Dictionary(uniqueKeysWithValues: projectOrder.enumerated().map { ($1, $0) })
        return entries.values.sorted { a, b in
            let ra = rank[a.session.project.id] ?? Int.max
            let rb = rank[b.session.project.id] ?? Int.max
            if ra != rb { return ra < rb }
            return a.session.project.rootURL.lastPathComponent < b.session.project.rootURL.lastPathComponent
        }
    }
}
