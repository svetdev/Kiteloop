import Foundation

/// Decodable subsets of the control API's payloads. Every field the phone does
/// not strictly need is optional, so a Mac running a newer build never breaks
/// the client — the OpenAPI document is the contract, this is the pocket copy.
struct Health: Decodable {
    var status: String?
    var version: String?
    /// The control API's version; absent from a Mac older than the number.
    var apiVersion: Int?
    var activeRuns: Int?
    var projectsOpen: Int?
    var uptimeSeconds: Int?
}

/// Whether this phone and the Mac it is talking to speak the same control
/// API, read off `/health`'s `apiVersion`. Neither mismatch stops the screens
/// that still work; it says which side to update instead of a bare 404.
enum APICompatibility: Equatable {
    case matched
    /// The Mac's API is older than this phone needs, or predates the number.
    case macOutdated
    /// The Mac's API is newer than this phone was built for.
    case phoneOutdated

    /// The control API this build calls — raised with the Mac's
    /// `ControlRouter.apiVersion` whenever an endpoint the phone calls is
    /// added or changes shape.
    static let phoneVersion = 2

    static func judge(macVersion: Int?) -> APICompatibility {
        guard let macVersion, macVersion >= phoneVersion else { return .macOutdated }
        return macVersion > phoneVersion ? .phoneOutdated : .matched
    }

    /// The banner to show, naming the Mac; nil when they match.
    func banner(macName: String) -> String? {
        switch self {
        case .matched: nil
        case .macOutdated: "Kiteloop on \(macName) is older than this app — update it there; some screens may not work until then."
        case .phoneOutdated: "Kiteloop on \(macName) is newer than this app — update the phone app for what it added."
        }
    }
}

struct ProjectsReply: Decodable { var projects: [Project]? }
struct Project: Decodable, Identifiable {
    var id: String
    var name: String
    var autopilotReady: Bool?
    /// Paused by priority on the Mac's fleet board.
    var paused: Bool?
    /// The item whose merge gate is verifying right now, if any.
    var gate: ProjectGate?
    var queue: QueueCounts?
    /// What the project's autopilot is running right now, as `/v1/projects`
    /// reports it; absent on a Mac build that predates the field.
    var run: ProjectRun?

    /// A project with a run up — what the Now tab spins for.
    var isRunning: Bool { run?.running == true }
}
/// One project's live run: the item, its title, and where in the pipeline it is.
struct ProjectRun: Decodable {
    var running: Bool?
    var item: String?
    var itemTitle: String?
    var startedAt: String?
    var phaseRail: PhaseRail?

    /// "worker", "verify", "review", "merge" — the step the phase rail is on.
    var step: String? { phaseRail?.currentStep }
}
struct PhaseRail: Decodable {
    var currentStep: String?
    var stepsDone: [String]?
    var attempt: Int?
    init(currentStep: String?, stepsDone: [String]? = nil, attempt: Int? = nil) {
        self.currentStep = currentStep
        self.stepsDone = stepsDone
        self.attempt = attempt
    }
}
struct QueueCounts: Decodable {
    var active: Int?
    var awaitingApproval: Int?
    var blocked: Int?
    var draft: Int?
    var ready: Int?
    /// Of the `ready` items, how many pass the Definition-of-Ready and so could
    /// start. Absent from an older Mac, which reads as every ready item.
    var runnable: Int?
}

struct BacklogReply: Decodable { var items: [BacklogItem]? }
struct BacklogItem: Decodable, Identifiable, Hashable {
    var id: String
    var title: String?
    var status: String?
    var epic: String?
    var size: String?
    /// `now` or `later` — `now` runs ahead of every `later` item. Absent from an
    /// older Mac, which read as `later`.
    var lane: String?
    /// At the gate: `verifying`, `waiting` or `refused` — the Mac's answer.
    var gate: GateInfo?
    /// Sent on a `ready` item only: whether the Mac would start it now. Absent
    /// from an older Mac, which reads as startable.
    var ready: Bool?
    /// Why the Mac would not start it, one phrase per unmet clause, in the gate's own words.
    var notReady: [String]?
    /// The retry ceiling has stopped autopilot starting it. Sent only when true.
    var retired: Bool?

    /// The Mac judged this item and would not start it.
    var cannotStart: Bool { ready == false }
    /// The Mac judged this item as of this refresh — its verdict outranks the grooming ledger.
    var isJudged: Bool { ready != nil }
    var isRetired: Bool { retired == true }
    /// Release lifts the retry ceiling, so it is offered only on a ready item the ceiling retired.
    var offersRelease: Bool { isRetired && status == "ready" }

    var isGate: Bool { status == "awaiting-approval" }
    var isOpen: Bool { status != "done" }
    var isNow: Bool { lane == "now" }
    /// The lane a flip puts the item in.
    var flippedLane: String { isNow ? "later" : "now" }
    /// Waiting on a person — not a gate still verifying its merged tree.
    var needsPerson: Bool { isGate && gate?.state != "verifying" }
    var isVerifying: Bool { isGate && gate?.state == "verifying" }
}
struct GateInfo: Decodable, Hashable {
    var state: String?
    var since: String?
    var reason: String?
}

struct RefillReply: Decodable {
    var enabled: Bool?
    var budget: RefillBudget?
    var passes: [RefillPass]?
}
struct RefillBudget: Decodable {
    var day: String?
    var spentUSD: Double?
    var capUSD: Double?
    var passesUsed: Int?
    var maxPasses: Int?
    var exhausted: Bool?
    var exhaustionReason: String?
}
struct RefillPass: Decodable, Identifiable {
    var at: String?
    var detail: String?
    var outcome: String?
    var id: String { (at ?? UUID().uuidString) + (detail ?? "") }
}

/// `GET /v1/usage`: of the agents' rate limits, the one closest to its limit,
/// and the last day's spend per project. Null fields from the Mac decode as nil.
struct UsageReply: Decodable {
    struct RateLimit: Decodable, Equatable {
        var status: String?
        var window: String?
        var resetsAt: String?
        var utilization: Double?

        /// Not `allowed`: a warning, or the limit reached.
        var isWarning: Bool { status != nil && status != "allowed" }
    }

    struct ProjectSpend: Decodable, Hashable {
        var project: String
        var spendUSD: Double?
    }

    struct Spend: Decodable {
        var hours: Int?
        var totalUSD: Double?
        var projects: [ProjectSpend]?
    }

    var rateLimit: RateLimit?
    var agentsReporting: Int?
    var spend: Spend?

    /// The rate limit in a line, the way the Mac's chat words its notice.
    static func rateLimitLine(_ limit: RateLimit?, resetTime: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String {
        guard let limit, let status = limit.status else { return "No agent has reported a rate limit since the Mac started" }
        let headline = switch status {
        case "allowed": "Under the rate limit"
        case "rejected": "Rate limit reached"
        default: "Approaching the rate limit"
        }
        let window = limit.window.map { " (\($0.replacingOccurrences(of: "_", with: "-")) window)" } ?? ""
        let used = limit.utilization.map { " — \(Int(($0 * 100).rounded()))% used" } ?? ""
        let resets = limit.resetsAt.flatMap { try? Date($0, strategy: .iso8601) }.map { ", resets \(resetTime($0))" } ?? ""
        return headline + window + used + resets
    }
}

struct SchedulingReply: Decodable {
    var enabled: Bool?
    var budget: SchedulingBudget?
    var breaker: Breaker?
    var lastDecision: Decision?
    var starts: [RunStart]?
    /// How many runs the fleet may have in flight at once, 1…8, and how many
    /// it has right now. Optional: a Mac older than the fields sends neither,
    /// and the rest of the reply still decodes.
    var maxConcurrentRuns: Int?
    var startsInFlight: Int?

    /// The projects whose run is in flight, named. The Mac reports
    /// `startsInFlight` as a count, so the names come from the start history,
    /// where an entry stays `running` until its run ends. Empty when nothing
    /// is in flight — and on a Mac that reports no count at all.
    var startingProjects: [String] {
        guard (startsInFlight ?? 0) > 0 else { return [] }
        var named: [String] = []
        for start in starts ?? [] where start.outcome == "running" {
            if let project = start.project, !named.contains(project) { named.append(project) }
        }
        return named
    }
}
struct SchedulingBudget: Decodable {
    var budgetUSD: Double?
    var spentTodayUSD: Double?
    var remainingUSD: Double?
    var exhausted: Bool?
}
struct Breaker: Decodable { var open: Bool?; var reason: String? }
struct Decision: Decodable { var kind: String?; var detail: String? }
struct RunStart: Decodable, Identifiable {
    var at: String?
    var project: String?
    var item: String?
    var title: String?
    var outcome: String?
    var budget: String?
    var id: String { (at ?? UUID().uuidString) + (item ?? "") }
}

/// `GET /v1/quick-replies`: the one-tap replies the Mac keeps for the chat.
struct QuickRepliesReply: Decodable {
    let replies: [String]?
}

struct AgentsReply: Decodable { var agents: [AgentInfo]? }
struct AgentInfo: Decodable, Identifiable {
    var id: String
    var name: String?
    var model: String?
    var state: String?
    /// The agent's permission mode, as stored: `auto`, `acceptEdits`, …
    var mode: String?
}

/// The permission modes an agent can be moved to, as the Mac stores them,
/// with the names its pickers give them.
enum PermissionMode {
    static let all: [(id: String, name: String)] = [
        ("auto", "Auto"), ("acceptEdits", "Accept Edits"), ("plan", "Plan (read-only)"),
        ("default", "Ask"), ("dontAsk", "Don't Ask"), ("bypassPermissions", "Bypass All"),
    ]

    /// The picker name of a stored mode; a mode this build has no name for
    /// reads as itself.
    static func name(_ id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }
}

struct AgentTasksReply: Decodable { var tasks: [AgentTaskInfo]? }
/// A subagent or background shell an agent's session has running.
struct AgentTaskInfo: Decodable, Identifiable, Equatable {
    var id: String
    /// `subagent`, `shell`, or the CLI's own name for another kind.
    var kind: String?
    var description: String?
    var subagent: String?

    /// What the row says: the words the task was started with, else its kind.
    var title: String {
        let words = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? (kind ?? id) : words
    }
}

struct TranscriptReply: Decodable { var messages: [TranscriptMessage]? }

/// One frame of `GET /v1/agents/events`: a transcript message that is new or
/// changed, or the agent starting or finishing a turn.
struct AgentEvent: Decodable {
    var type: String?
    var agent: String?
    var working: Bool?
    var message: TranscriptMessage?

    static func decode(_ line: String) -> AgentEvent? {
        try? JSONDecoder().decode(AgentEvent.self, from: Data(line.utf8))
    }
}
struct TranscriptMessage: Decodable, Identifiable {
    var id: String?
    var sender: String?
    var kind: String?
    var text: String?
    var at: String?
    /// On a `plan` message: whether it is still waiting, and what was chosen.
    var plan: PlanState?
    /// On a `question` message: the request it answers, and whether it is open.
    var question: QuestionState?
    /// On a `permission` message: the call waiting on leave to run.
    var permission: PermissionState?
    /// On a `choices` message: the model's questions and the options of each.
    var choices: ChoicesState?
    /// On a file tool's `tool` message: the whole path it touched.
    var path: String?
    var listID: String { (id ?? UUID().uuidString) }
}

struct WorkspaceChangesReply: Decodable {
    var files: [ChangedFile]?
    var patch: String?
    var truncated: Bool?
}
struct ChangedFile: Decodable, Identifiable {
    var status: String?
    var path: String
    var id: String { path }
}
struct WorkspaceFileReply: Decodable {
    var path: String?
    /// `file` or `directory`.
    var kind: String?
    var text: String?
    var entries: [FileEntry]?
}
struct FileEntry: Decodable, Identifiable {
    var name: String
    var directory: Bool?
    var id: String { name }
}

struct PlanState: Decodable {
    var open: Bool?
    /// `approveAuto`, `approveAcceptEdits` or `keepPlanning`, once answered.
    var answer: String?
}

struct QuestionState: Decodable {
    var request: String?
    var open: Bool?
}

struct PermissionState: Decodable, Equatable {
    var request: String?
    var open: Bool?
    var tool: String?
    /// What an Always answer can remember, by position.
    var always: [String]?
    /// `allowed`, `allowedAlways`, `denied` or `lapsed`, once answered.
    var answer: String?
    /// The task of the subagent whose call it is; nil for the agent's own.
    var subagent: String?
}

struct ChoicesState: Decodable, Equatable {
    var request: String?
    var open: Bool?
    var questions: [ChoiceQuestionInfo]?
    /// One per question, once answered.
    var answers: [String]?
}

struct ChoiceQuestionInfo: Decodable, Equatable {
    var question: String?
    var header: String?
    var multiSelect: Bool?
    var options: [ChoiceOptionInfo]?
}

struct ChoiceOptionInfo: Decodable, Equatable {
    var label: String?
    var description: String?
}

struct ItemDetailReply: Decodable {
    var id: String?
    var title: String?
    var status: String?
    var epic: String?
    var size: String?
    var verify: String?
    var what: String?
    var approach: String?
    var acceptanceCriteria: [String]?
    var outOfScope: [String]?
    var notes: String?
    var why: String?
}

struct DiffReply: Decodable {
    var item: String?
    var branch: String?
    var stat: String?
    var patch: String?
    var truncated: Bool?

    /// What the gate screen can show of this patch, or nothing when there is
    /// no patch to show.
    var preview: DiffPreview? {
        guard let patch, !patch.isEmpty else { return nil }
        return DiffPreview(patch: patch, truncated: truncated)
    }
}

/// The part of a patch the phone draws: the lines it keeps, and whether
/// anything was cut — either by the Mac's character cap before sending, or by
/// the row cap here. Both leave the reader short of the diff, so the screen
/// folds them into one flag and one header.
struct DiffPreview {
    /// Rows the gate screen draws; past this the patch is cut on the phone.
    static let lineCap = 1200
    static let plainHeader = "Diff"
    static let cutHeader = "Diff (truncated by the Mac or by this screen — read the rest on the Mac)"

    /// The lines the screen draws, at most `lineCap` of them.
    let lines: [String]
    /// Whether anything of the patch is missing from `lines`.
    let cut: Bool

    init(patch: String, truncated: Bool?) {
        let all = patch.split(separator: "\n", omittingEmptySubsequences: false)
        lines = all.prefix(Self.lineCap).map(String.init)
        cut = truncated == true || all.count > Self.lineCap
    }

    /// The section header the gate screen draws — it says so when cut.
    var header: String { cut ? Self.cutHeader : Self.plainHeader }
}

struct RunsReply: Decodable { var runs: [RunRow]? }
struct RunRow: Decodable, Identifiable {
    var runId: String
    var item: String?
    var title: String?
    var project: String?
    var startedAt: String?
    var state: String?
    var historical: Bool?
    var costUSD: Double?
    var id: String { runId }
}

struct ReportReply: Decodable {
    var summary: String?
    var period: ReportPeriod?
    var rows: [ReportRow]?
    var total: ReportRow?
    struct ReportPeriod: Decodable { var label: String? }
    struct ReportRow: Decodable {
        var project: String?
        var text: String?
        var merged: Int?
        var filed: Int?
        var spendUSD: Double?
    }
}

struct GroomingReply: Decodable { var grooming: [GroomingRecord]? }
struct GroomingRecord: Decodable, Identifiable {
    var at: String?
    var event: String?
    var item: String?
    var check: String?
    var reason: String?
    var id: String { (at ?? UUID().uuidString) + (item ?? "") + (event ?? "") }
}

/// `GET /v1/autopilot?project=`: the run the project's autopilot has up and the
/// switches a phone reads its state from. Memberwise so a test can build one.
struct AutopilotReply: Decodable {
    var run: AutopilotRun?
    var autonomousWorkEnabled: Bool?
    var sessionSpendUSD: Double?
    var sessionCostCapUSD: Double?

    init(run: AutopilotRun?, autonomousWorkEnabled: Bool?, sessionSpendUSD: Double? = nil, sessionCostCapUSD: Double? = nil) {
        self.run = run
        self.autonomousWorkEnabled = autonomousWorkEnabled
        self.sessionSpendUSD = sessionSpendUSD
        self.sessionCostCapUSD = sessionCostCapUSD
    }
}
struct AutopilotRun: Decodable {
    /// `idle`, `running`, `held` or `inconsistent`.
    var state: String?
    var item: String?
    var itemTitle: String?
    var detail: String?
    var phaseRail: PhaseRail?

    var step: String? { phaseRail?.currentStep }

    init(state: String?, item: String? = nil, itemTitle: String? = nil, detail: String? = nil, phaseRail: PhaseRail? = nil) {
        self.state = state
        self.item = item
        self.itemTitle = itemTitle
        self.detail = detail
        self.phaseRail = phaseRail
    }
}
/// `GET /v1/fleet/quiesce`: is the fleet taking work.
struct FleetReply: Decodable {
    var quiesced: Bool?
    var drained: Bool?
    var running: Int?
    var summary: String?
}
/// `GET /v1/projects` → `gate`: a merge gate verifying right now.
struct ProjectGate: Decodable {
    var item: String?
    var since: String?
    var state: String?
}
