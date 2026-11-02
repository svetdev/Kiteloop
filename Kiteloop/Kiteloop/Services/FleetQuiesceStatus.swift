import Foundation

/// What the app shows about the fleet-wide hold, derived from one
/// `FleetQuiesce.Reading` and nothing else.
///
/// Quiescing — hold every advancing queue, gate new starts, drain — existed only
/// as `POST /v1/fleet/quiesce`. A headless driver could do it with one request
/// and the operator sitting in front of the app could not, so quitting relied on
/// termination cleanup rather than a drain, and an interrupted run came back
/// `ready` and re-ran from scratch.
///
/// Both surfaces read this one value: the sidebar footer's compact box and the
/// fleet drawer it opens. The drawer has the room to name each project and the
/// item it is on, the footer has a 240pt column and says the same thing in a
/// line — but neither derives anything of its own, so they cannot disagree
/// about what the fleet is doing.
///
/// Two properties are load-bearing:
///
/// * **It decides nothing.** Every field is read off the reading the seam
///   answered with. The semantics — which queues are held, when the fleet counts
///   as drained, what happens to a run already in flight — live in
///   `FleetQuiesce` and are restated nowhere here; `stateLine` says which of the
///   seam's own three states the reading is in and repeats the count it counted,
///   so the footer and the endpoint cannot come to disagree about what the fleet
///   is doing. Only the *words* belong to this type: the seam's `summary` is a
///   field of `GET /v1/fleet/quiesce`, a contract scripts read, so it keeps its
///   machine spelling while the footer speaks the operator's.
/// * **Reading it cannot do anything.** It holds values, not the seam, so there
///   is no path from drawing the footer to holding a queue.
struct FleetQuiesceStatus: Equatable, Sendable {

    /// Which control is on offer. Never both: a fleet that is taking work has
    /// nothing to resume, and a held one has nothing left to hold.
    ///
    /// The case names are the seam's, because that is what they name; the titles
    /// are what an operator reads. "Pause" carries its scope beside it — the
    /// Fleet badge in the footer, the word "fleet" in the help — because a
    /// project's own Pause is a weaker thing: it holds one queue but does not
    /// gate a new start, and the two must not read as the same control.
    enum Action: Equatable, Sendable {
        case quiesce
        case resume

        var title: String {
            switch self {
            case .quiesce: "Pause"
            case .resume: "Resume"
            }
        }
    }

    /// One open project, as the drawer lists it.
    ///
    /// The footer's `stillRunning` is the same projects joined into one capped
    /// sentence, because a 240pt column is all it has; this is the form the
    /// drawer has room to draw properly — a row each, the item as a mention that
    /// opens it, and the hold beside it. Both are read off the one reading, so
    /// the compact line and the list cannot come to disagree.
    struct ProjectRow: Equatable, Sendable, Identifiable {
        /// The canonical project id, which is what the reading keys on.
        let id: String
        /// The project's folder name — how it is named on screen, and how a
        /// mention in it addresses its project (`ItemLinkProject.name`).
        let name: String
        /// The item in flight, or nil when nothing is running here.
        let item: String?
        let isRunning: Bool
        /// Whether *this* pause is what holds the project's queue. A resume
        /// picks up exactly these and nothing an operator was holding for their
        /// own reasons, so it is the difference between "we did this" and "it
        /// was already like that".
        let heldByQuiesce: Bool
        /// Items its queue is holding back.
        let heldItems: Int
        /// What this project is doing, in the words the control is named in.
        let line: String
    }

    /// Where the fleet is, in the one word the box is coloured by.
    enum State: String, Equatable, Sendable {
        /// Not quiesced: new work is accepted, here and over the API.
        case takingWork
        /// Quiesced with runs still finishing — the only state that changes on
        /// its own, which is why the box re-reads.
        case draining
        /// Quiesced and drained. Nothing is mid-item, so a restart strands
        /// nothing: this is the state a quiesce is taken to reach.
        case held
    }

    let state: State
    /// The line under the control — "pausing — 2 run(s) finishing".
    ///
    /// Written here rather than taken from `reading.summary`: that sentence is a
    /// field of the fleet endpoints, read by scripts and the runbook, so it keeps
    /// saying "quiesced" while the footer says what the control is called. The
    /// facts are still the reading's — which state, and how many are finishing.
    let stateLine: String
    /// The projects still finishing, named with the item each is on. Nil when
    /// nothing is running, so a drained fleet shows one line rather than an
    /// empty second one.
    let stillRunning: String?
    /// Every open project, in the order the reading listed them. Empty where the
    /// fleet has no project open — which is a fleet, just an empty one, and the
    /// drawer says so rather than drawing a blank list.
    let projects: [ProjectRow]
    let action: Action
    /// A quiesce or resume in flight. The control is disabled while one is, so a
    /// second click cannot start a hold on top of a hold.
    let isBusy: Bool
    /// A quit waiting on the drain, or the drain having finished under one. Nil
    /// when no quit is pending — the ordinary case.
    let quitNotice: String?
    /// The tooltip: what pressing the control would do, in a sentence.
    let help: String

    /// - Parameters:
    ///   - reading: what `FleetQuiesce` last answered.
    ///   - isBusy: whether a quiesce or resume this app started is still running.
    ///   - isQuittingWhenDrained: whether the operator chose, at the quit offer,
    ///     to quit once the fleet drains.
    init(reading: FleetQuiesce.Reading, isBusy: Bool = false, isQuittingWhenDrained: Bool = false) {
        self.state = reading.quiesced ? (reading.drained ? .held : .draining) : .takingWork
        self.stateLine = Self.stateLine(reading)
        self.stillRunning = Self.stillRunning(reading)
        self.projects = reading.projects.map(Self.row)
        self.action = reading.quiesced ? .resume : .quiesce
        self.isBusy = isBusy
        self.quitNotice = isQuittingWhenDrained
            ? (reading.drained ? "all quiet — quitting" : "quitting once it's quiet")
            : nil
        self.help = Self.help(reading)
    }

    /// Whether the control accepts a click. False only while this app's own
    /// quiesce or resume is still running — the state, on its own, never
    /// disables it.
    var canAct: Bool { !isBusy }

    /// Where the fleet is, in the words the control is named in: what it is
    /// doing, then whether anything is left.
    ///
    /// "All quiet" rather than "drained" for the same reason the button no longer
    /// says "quiesce" — the state that matters here is the one where a restart
    /// strands nothing, and an operator should be able to recognise it without
    /// knowing the word the mechanism goes by.
    private static func stateLine(_ reading: FleetQuiesce.Reading) -> String {
        guard reading.quiesced else {
            return reading.drained
                ? "taking work — all quiet"
                : "taking work — \(reading.running) run(s) in flight"
        }
        guard !reading.drained else { return "paused — all quiet" }
        return "pausing — \(reading.running) run(s) finishing"
    }

    /// The projects still finishing, named with the item each is on — the answer
    /// to "what is still running?" that a bare count cannot give.
    ///
    /// Capped, and it says what the cap dropped: the footer is a 240pt column,
    /// and a fleet of a dozen busy projects would otherwise write a paragraph
    /// into it.
    static func stillRunning(_ reading: FleetQuiesce.Reading, limit: Int = 3) -> String? {
        let running = reading.projects.filter(\.running)
        guard !running.isEmpty else { return nil }
        let named = running.prefix(limit).map { project in
            project.item.map { "\(project.name) (\($0))" } ?? project.name
        }
        let omitted = running.count - named.count
        return named.joined(separator: ", ") + (omitted > 0 ? ", +\(omitted) more" : "")
    }

    /// One project's row, read off its line of the reading and nothing else.
    ///
    /// The line states the two facts the count above it cannot: whether this
    /// project is what the fleet is still waiting on, and whether its queue is
    /// held by *this* pause — a project that was already paused reads as quiet
    /// rather than as something the resume will pick back up, which is exactly
    /// the distinction the ledger keeps.
    private static func row(_ project: FleetQuiesce.ProjectReading) -> ProjectRow {
        var parts = [project.running ? "running" : "quiet"]
        if project.heldByQuiesce { parts.append("queue held by this pause") }
        if project.heldItems > 0 { parts.append("\(project.heldItems) item(s) waiting") }
        return ProjectRow(
            id: project.id,
            name: project.name,
            item: project.item,
            isRunning: project.running,
            heldByQuiesce: project.heldByQuiesce,
            heldItems: project.heldItems,
            line: parts.joined(separator: " · ")
        )
    }

    /// What the control would do, stated as its consequence rather than its
    /// mechanism — the hover is where an operator finds out whether pressing it
    /// costs them the run in flight, and the answer is that it never does.
    ///
    /// It also carries the one distinction the name cannot: this Pause holds
    /// every advancing queue *and* refuses new runs, where a project's Pause
    /// holds its queue and lets a fresh start through.
    private static func help(_ reading: FleetQuiesce.Reading) -> String {
        guard reading.quiesced else {
            return "Pause the fleet — hold every advancing queue and, unlike a project's Pause, "
                + "refuse new runs as well: autonomous starts and the control API alike. "
                + "Runs already in flight finish at their own gate."
        }
        let base = "Resume — lift the hold and pick back up exactly the queues this pause held."
        guard !reading.drained else {
            return "\(base) The fleet is quiet: nothing is mid-item, so quitting or restarting now strands nothing."
        }
        return "\(base) \(reading.running) run(s) are still finishing at their own gate."
    }
}

/// The offer a quit makes when the fleet is not drained.
///
/// Quitting with a run in flight is not free: the run is interrupted, its item
/// returns to `ready` at the next launch and re-runs from scratch, losing the
/// minutes it had already spent. That was the only behaviour the app had — the
/// drain existed solely as an API call — so this is the choice, put in front of
/// the operator at the moment it matters.
///
/// A value rather than an `NSAlert`: what the offer says has to be assertable
/// without putting a window on screen.
struct FleetQuitPrompt: Equatable, Sendable {

    /// What the operator picked, in the order the buttons are offered — the
    /// first is the default, the last is the escape.
    enum Choice: String, Equatable, Sendable {
        /// Hold the fleet now and quit once the last run has reached its gate.
        case quiesceThenQuit
        /// Today's behaviour, unchanged: quit immediately and interrupt them.
        case quitNow
        case cancel

        /// Title case, like the two buttons beside it — the words are the
        /// footer's, the capitalisation is the alert's.
        var title: String {
            switch self {
            case .quiesceThenQuit: "Pause the Fleet and Quit When It's Quiet"
            case .quitNow: "Quit Now"
            case .cancel: "Cancel"
            }
        }
    }

    let message: String
    let detail: String
    /// Button order, default first.
    let choices: [Choice] = [.quiesceThenQuit, .quitNow, .cancel]

    /// Nil when there is nothing to offer. A drained fleet quits without a word:
    /// asking about a drain that has already happened would be a dialog between
    /// the operator and their own Cmd-Q.
    init?(reading: FleetQuiesce.Reading) {
        guard !reading.drained else { return nil }
        let count = reading.running
        self.message = count == 1 ? "1 run is still in flight" : "\(count) runs are still in flight"
        var detail = ""
        if let running = FleetQuiesceStatus.stillRunning(reading, limit: 5) {
            detail += "Finishing now: \(running).\n\n"
        }
        detail += "Quitting now interrupts them — an interrupted run returns to Ready and "
            + "re-runs from scratch at the next launch. Pausing the fleet holds every queue and "
            + "refuses new work, then quits once the last run has finished at its own gate."
        self.detail = detail
    }
}
