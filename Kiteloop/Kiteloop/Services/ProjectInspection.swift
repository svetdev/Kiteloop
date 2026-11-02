import Foundation
import KiteloopCore

/// One project in full, fetched **because somebody asked about it**.
///
/// `PortfolioSnapshot` is the other half of this pair and the one that runs by
/// default: every open project, a sample of its named items, and nothing more —
/// because it is sent with every single message. This type is the exception. It
/// is built for one project, on demand, and it carries what the summary
/// deliberately leaves out: every item of every status, and the runs on record
/// with their outcomes, reasons, quality scores and cost.
///
/// Three properties are load-bearing:
///
/// * **It reads what the app already holds.** The project's `BacklogViewModel`
///   and the `TaskMetricStore` records for that project's path — the same two
///   sources the summary reads. No repository read, no shell, no second source
///   of truth to disagree with the portfolio.
/// * **An unknown name is refused, never resolved to the nearest project.**
///   `resolve` matches a project's own name (case-insensitively) or its path and
///   nothing else, so a name the model invented comes back as
///   `unknownProject` — with the open ones listed — rather than as a confident
///   answer about a project nobody asked about.
/// * **Paused is not a refusal.** Pausing stops *work*, not questions: a paused
///   project inspects like any other and says it is paused. The hard stop lives
///   where it always did, in `PortfolioSnapshot.selectableProjects`, which
///   refuses to *act* on one.
///
/// Read-only by construction, like the snapshot: plain values, no reference to
/// anything it read.
struct ProjectInspection: Sendable, Equatable {

    /// One item, as an inspection names it. Richer than
    /// `PortfolioSnapshot.Item` in one way only: a blocked item carries why —
    /// both the backlog line's own annotation and what the last recorded run
    /// ended as, which are different claims and are kept apart.
    struct Item: Sendable, Equatable {
        let id: String
        let title: String
        /// `ItemSize.rawValue`, or nil for an unsized item.
        let size: String?
        /// The backlog line's own `blocked:` note — what a human or an agent
        /// wrote next to the item. Carried for blocked items only.
        let blockedReason: String?
        /// What the last recorded run of this item ended as, from
        /// `TaskMetricStore`. Carried for blocked items only — for everything
        /// else `runs` is the fuller account. Nil means no run is on record,
        /// which is a fact in itself and never a guessed reason.
        let lastRun: PortfolioSnapshot.LastRun?
    }

    /// Every item of one status, capped — with the overflow counted rather than
    /// dropped. A status with no items is absent altogether.
    struct StatusGroup: Sendable, Equatable {
        let status: BacklogItemStatus
        let items: [Item]
        /// How many items of this status the cap left out.
        let omitted: Int
        var total: Int { items.count + omitted }
    }

    /// One run on record, newest first in `runs`.
    ///
    /// This is the half the portfolio summary cannot afford: what a run cost and
    /// what the judge thought of it, per item, for the project being asked
    /// about.
    struct Run: Sendable, Equatable {
        let itemID: String
        let title: String
        /// The outcome class — `done`, `awaiting-approval`, `blocked`, `cancelled`.
        let outcome: String
        /// The reason half of `blocked:<reason>`, when the outcome carried one.
        let reason: String?
        /// The judge's advisory score, where the run has one.
        let qualityScore: Double?
        let costUSD: Double
        let completedAt: Date
    }

    let name: String
    let path: String
    /// Whether a human has parked this project. Reported, not refused — see the
    /// type comment.
    let paused: Bool
    /// The human's statement of what this project is for. Nil when unstated.
    let goal: String?
    /// Both a worker and a reviewer assigned — the same condition the control
    /// API reports as `autopilotReady`.
    let autopilotReady: Bool
    /// Every status that has items, in the order an item moves through them.
    let groups: [StatusGroup]
    /// The runs on record for this project, newest first, capped.
    let runs: [Run]
    /// How many older runs the cap left out.
    let runsOmitted: Int

    var isPaused: Bool { paused }
    var totalItems: Int { groups.reduce(0) { $0 + $1.total } }
    /// Runs on record, including those the cap left out.
    var totalRuns: Int { runs.count + runsOmitted }
    func group(_ status: BacklogItemStatus) -> StatusGroup? {
        groups.first { $0.status == status }
    }

    // MARK: - Asking for one

    /// What came of asking to inspect a project by name.
    ///
    /// A separate type rather than an optional, because the two cases are told
    /// to the human differently: an inspection becomes prompt context and a
    /// badge on the answer, while an unknown name becomes a refusal that names
    /// the projects that *are* open.
    enum Outcome: Sendable, Equatable {
        case inspected(ProjectInspection)
        case unknownProject(name: String, open: [String])

        var inspection: ProjectInspection? {
            guard case .inspected(let inspection) = self else { return nil }
            return inspection
        }

        /// The project actually inspected, or nil when nothing was.
        var inspectedName: String? { inspection?.name }

        /// Why nothing was inspected, in the app's own words — nil when
        /// something was. Names the open projects, because a name that missed
        /// is usually a name that was nearly right.
        var refusal: String? {
            guard case .unknownProject(let name, let open) = self else { return nil }
            guard !open.isEmpty else {
                return "Couldn't look into “\(name)” — no project is open at all."
            }
            return "Couldn't look into “\(name)” — that isn't an open project. "
                + "The open ones are: \(open.joined(separator: ", "))."
        }
    }

    // MARK: - Bounds

    /// How many items **per status** an inspection names. Far larger than the
    /// summary's cap — the whole point of an inspection is the full picture —
    /// but still a cap: the result is prompt text, and a backlog with a thousand
    /// `done` items would push out what was being asked about. What it leaves
    /// out is counted (`StatusGroup.omitted`), never silently dropped.
    static let itemLimit = 40

    /// How many runs an inspection carries, newest first. Enough to see a
    /// pattern in what a project's runs cost and score without turning the
    /// prompt into the metric store.
    static let runLimit = 20

    // MARK: - Capture

    /// Inspect one open project by name.
    ///
    /// Reads only: the project's loaded backlog, its `.kiteloop/config.json` and
    /// the metric records for its path. Nothing here mutates a session, a
    /// backlog or an autopilot.
    @MainActor
    static func capture(registry: ControlSessionRegistry,
                        projectNamed name: String,
                        metrics: TaskMetricStore? = nil,
                        itemLimit: Int = itemLimit,
                        runLimit: Int = runLimit) -> Outcome {
        let asked = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let open = registry.openProjects
        guard let entry = resolve(asked, in: open) else {
            return .unknownProject(name: asked,
                                   open: open.map { $0.session.project.rootURL.lastPathComponent })
        }
        let path = entry.session.project.rootURL.path(percentEncoded: false)
        let config = entry.session.project.loadConfig()
        return .inspected(project(
            name: entry.session.project.rootURL.lastPathComponent,
            path: path,
            autopilotReady: entry.autopilot.workerAgentID != nil
                && entry.autopilot.reviewerAgentID != nil,
            backlog: entry.session.backlogViewModel.backlogFile,
            paused: config.paused ?? false,
            goal: KiteloopProject.normalizedStatement(config.goal),
            records: records(metrics: metrics, projectPath: path),
            lastRun: PortfolioSnapshot.lastRunLookup(metrics: metrics, projectPath: path),
            itemLimit: itemLimit,
            runLimit: runLimit
        ))
    }

    /// Name first, path second — and nothing else. No prefix match, no nearest
    /// neighbour: substituting a project for the one that was asked about is the
    /// failure this whole path exists to avoid.
    static func resolve(_ name: String,
                        in open: [ControlSessionRegistry.Entry]) -> ControlSessionRegistry.Entry? {
        guard !name.isEmpty else { return nil }
        if let hit = open.first(where: {
            $0.session.project.rootURL.lastPathComponent.compare(name,
                                                                 options: .caseInsensitive) == .orderedSame
        }) { return hit }
        let canonical = KiteloopProject.canonicalPath(name)
        return open.first { $0.session.project.id == canonical }
    }

    /// This project's metric records, newest first. Scoped by canonical path for
    /// the same reason `PortfolioSnapshot.lastRunLookup` is: records are global
    /// and keyed by item id, so an unscoped read would hand one project's runs
    /// to another project's identically-named item.
    @MainActor
    static func records(metrics: TaskMetricStore?, projectPath: String) -> [TaskMetricRecord] {
        guard let metrics else { return [] }
        let canonical = KiteloopProject.canonicalPath(projectPath)
        return metrics.records
            .filter { KiteloopProject.canonicalPath($0.projectPath) == canonical }
            .sorted { $0.completedAt > $1.completedAt }
    }

    /// The assembly, split from `capture` so it is exercised without a live
    /// registry or a metric store on disk. `records` must already be scoped to
    /// this project and sorted newest first.
    static func project(name: String, path: String, autopilotReady: Bool,
                        backlog: BacklogFile?,
                        paused: Bool = false, goal: String? = nil,
                        records: [TaskMetricRecord] = [],
                        lastRun: PortfolioSnapshot.LastRunLookup = { _ in nil },
                        itemLimit: Int = itemLimit,
                        runLimit: Int = runLimit) -> ProjectInspection {
        let shown = records.prefix(max(0, runLimit))
        return ProjectInspection(
            name: name,
            path: path,
            paused: paused,
            goal: goal,
            autopilotReady: autopilotReady,
            groups: groups(backlog, limit: itemLimit, lastRun: lastRun),
            runs: shown.map { record in
                let split = PortfolioSnapshot.splitOutcome(record.outcome)
                return Run(itemID: record.itemID,
                           title: PortfolioSnapshot.statementLine(record.title,
                                                                  limit: PortfolioSnapshot.itemTextLimit),
                           outcome: split.outcome,
                           reason: split.reason,
                           qualityScore: record.qualityScore,
                           costUSD: record.costUSD,
                           completedAt: record.completedAt)
            },
            runsOmitted: records.count - shown.count
        )
    }

    /// Every status that has items, in the order an item moves through them.
    static func groups(_ backlog: BacklogFile?, limit: Int = itemLimit,
                       lastRun: PortfolioSnapshot.LastRunLookup = { _ in nil }) -> [StatusGroup] {
        let all = (backlog?.sections ?? []).flatMap(\.items)
        return BacklogItemStatus.allCases.compactMap { status in
            let matching = all.filter { $0.status == status }
            guard !matching.isEmpty else { return nil }
            let shown = matching.prefix(max(0, limit))
            return StatusGroup(
                status: status,
                items: shown.map { item in
                    // Why an item is stuck is the question an inspection is
                    // usually asked to answer, so a blocked item carries its
                    // reasons; everything else is named, and `runs` is the
                    // fuller account of what has happened to it.
                    let blocked = status == .blocked
                    return Item(
                        id: item.id,
                        title: PortfolioSnapshot.statementLine(item.title,
                                                               limit: PortfolioSnapshot.itemTextLimit),
                        size: item.size?.rawValue,
                        blockedReason: blocked
                            ? item.blockedReason.flatMap(nonEmptyStatement)
                            : nil,
                        lastRun: blocked ? lastRun(item.id) : nil
                    )
                },
                omitted: matching.count - shown.count
            )
        }
    }

    private static func nonEmptyStatement(_ raw: String) -> String? {
        let line = PortfolioSnapshot.statementLine(raw, limit: PortfolioSnapshot.itemTextLimit)
        return line.isEmpty ? nil : line
    }

    // MARK: - Prompt rendering

    /// The inspection as a section of the chat prompt.
    ///
    /// Headed by what it is, so an answer built on it can say so — the reader of
    /// a reply has to be able to tell a full look at one project from a glance
    /// at the summary of all of them.
    var promptSection: String {
        var out = "## Inspected: \(name) (the full picture of this one project)\n"
        out += "You asked to look into this project, and this is everything the app holds "
            + "about it. The portfolio summary above is unchanged — it is still a summary.\n"
        out += "autopilot \(autopilotReady ? "ready" : "not ready")"
        if let goal { out += " | goal: \(PortfolioSnapshot.statementLine(goal))" }
        out += "\n"
        if isPaused {
            out += "This project is paused — the human stopped work on it. Answer the question "
                + "about it, say it is paused, and propose no work for it.\n"
        }
        out += "Items (\(totalItems) in total)\n"
        if groups.isEmpty {
            out += "  (this project's backlog has no items)\n"
        }
        for group in groups {
            out += "  \(group.status.rawValue) \(Self.sampleNote(group)):\n"
            for item in group.items {
                out += "    - \(Self.itemPhrase(item))\n"
            }
        }
        out += "Runs on record \(Self.runsNote(shown: runs.count, omitted: runsOmitted))\n"
        if runs.isEmpty {
            out += "  (no run of this project has been recorded)\n"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        for run in runs {
            out += "  - \(formatter.string(from: run.completedAt)) \(run.itemID) "
                + "“\(run.title)”: \(run.outcome)"
            if let reason = run.reason { out += " — \(reason)" }
            out += String(format: " ($%.2f", run.costUSD)
            if let score = run.qualityScore { out += String(format: ", quality %.2f", score) }
            out += ")\n"
        }
        return out
    }

    /// What was fetched, in one line — for the note the app writes beside an
    /// inspected answer.
    var summaryLine: String {
        "\(name): \(totalItems) item\(totalItems == 1 ? "" : "s"), "
            + "\(totalRuns) run\(totalRuns == 1 ? "" : "s") on record"
    }

    private static func itemPhrase(_ item: Item) -> String {
        var phrase = "\(item.id) “\(item.title)”"
        if let size = item.size { phrase += " [\(size)]" }
        if let reason = item.blockedReason { phrase += " — blocked: \(reason)" }
        if let run = item.lastRun {
            phrase += " — last run \(run.outcome)"
            if let reason = run.reason { phrase += ": \(reason)" }
            if let score = run.qualityScore { phrase += String(format: " (quality %.2f)", score) }
        } else if item.blockedReason == nil {
            phrase += " — no recorded run"
        }
        return phrase
    }

    /// Says the list is a sample whenever it is one — the same rule the summary
    /// follows, and for the same reason: a capped list read as a complete one
    /// turns "40 done" into "12 done" the moment anybody counts the lines.
    private static func sampleNote(_ group: StatusGroup) -> String {
        group.omitted == 0
            ? "(all \(group.items.count))"
            : "(\(group.items.count) of \(group.total), \(group.omitted) not shown)"
    }

    private static func runsNote(shown: Int, omitted: Int) -> String {
        omitted == 0
            ? "(all \(shown), newest first)"
            : "(\(shown) of \(shown + omitted), newest first)"
    }
}
