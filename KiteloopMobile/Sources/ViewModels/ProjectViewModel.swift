import Foundation
import Observation

/// One project at a time — the one the picker names — read as a person on a
/// phone wants it: is it running, what on, does it need me, and the one lever
/// that changes that. Everything refreshes together every few seconds while
/// the screen is up, so the spinner is never older than the numbers.
@Observable @MainActor
final class ProjectViewModel {
    var projects: [Project] = []
    var selected = ""
    var autopilot: AutopilotReply?
    var agents: [AgentInfo] = []
    /// Whether the last refresh worked, how old it is, and what failed if not.
    var freshness = RefreshState(interval: 10)
    /// A lever or a drag that failed — separate from the refresh, which is
    /// about reading; this is about a move that did not take.
    var error: String?
    var acting = false
    /// Whether the Mac speaks the API this phone calls; matched until `/health` says otherwise.
    var compatibility = APICompatibility.matched

    var project: Project? { projects.first { $0.name == selected } }
    var state: ProjectState { ProjectState(autopilot: autopilot, project: project) }

    func refresh(_ client: ControlClient) async {
        freshness.begin()
        do {
            let health: Health = try await client.get("/health")
            compatibility = .judge(macVersion: health.apiVersion)
            projects = (try await client.get("/v1/projects", as: ProjectsReply.self).projects) ?? []
            if !projects.contains(where: { $0.name == selected }) { selected = projects.first?.name ?? "" }
            if !selected.isEmpty {
                autopilot = try await client.get(client.query("/v1/autopilot", [("project", selected)]))
                agents = (try await client.get(client.query("/v1/agents", [("project", selected)]), as: AgentsReply.self).agents) ?? []
            }
            freshness.succeed(at: Date())
        } catch { freshness.fail(error, host: Self.host(of: client.baseURL)) }
    }

    /// The host a problem names — the address without its scheme.
    static func host(of baseURL: String) -> String {
        baseURL.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    /// Moves a project before another (or to the end, on nil) — locally at
    /// once, so the row settles under the finger, and on the Mac through the
    /// same move a tab drop makes there, so both surfaces keep one order. The
    /// next refresh reads the Mac's answer back.
    func reorder(_ client: ControlClient, project: String, before: String?) async {
        guard project != before, let from = projects.firstIndex(where: { $0.name == project }) else { return }
        let moving = projects.remove(at: from)
        if let before, let to = projects.firstIndex(where: { $0.name == before }) {
            projects.insert(moving, at: to)
        } else {
            projects.append(moving)
        }
        var body: [String: Any] = ["project": project]
        if let before { body["before"] = before }
        do {
            _ = try await client.post("/v1/projects/reorder", body)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// The one lever: pause after the item in flight, or resume. Which one is
    /// the state's to say (`ProjectState.action`), never both at once.
    func toggle(_ client: ControlClient) async {
        guard let action = state.action else { return }
        acting = true
        defer { acting = false }
        do {
            _ = try await client.post(action.resumes ? "/v1/autopilot/resume" : "/v1/autopilot/pause", ["project": selected])
            await refresh(client)
        } catch { self.error = error.localizedDescription }
    }
}

/// What the status card says and the one thing it offers, from the autopilot's
/// answer. Pure, so the phone's tests can pin every row of the table.
struct ProjectState: Equatable {
    struct Action: Equatable {
        let title: String
        let resumes: Bool
    }
    /// The colour family of the state — the view maps it to a tint.
    enum Tone: Equatable { case running, paused, recovering, idle, off }

    let label: String
    let detail: String?
    let running: Bool
    let action: Action?
    let tone: Tone

    init(autopilot: AutopilotReply?, project: Project?) {
        let run = autopilot?.run
        let held = run?.state == "held" || project?.paused == true
        let enabled = autopilot?.autonomousWorkEnabled ?? false
        switch run?.state {
        case "running":
            label = "Running"
            detail = [run?.itemTitle ?? run?.item ?? "", run?.step.map { "— \($0)" } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            running = true
            action = Action(title: "Pause after this item", resumes: false)
            tone = .running
        case "held":
            label = "Paused"
            detail = run?.detail ?? "Nothing starts until resumed."
            running = false
            action = Action(title: "Resume", resumes: true)
            tone = .paused
        case "inconsistent":
            label = "Recovering"
            detail = run?.detail
            running = false
            action = Action(title: "Resume", resumes: true)
            tone = .recovering
        default:
            if held {
                label = "Paused"; detail = "Nothing starts until resumed."; running = false
                action = Action(title: "Resume", resumes: true); tone = .paused
            } else if enabled {
                label = "Idle"; detail = "Picks up the next ready item on its own."; running = false
                action = Action(title: "Pause", resumes: false); tone = .idle
            } else {
                label = "Off"; detail = "Autonomous work is off for this project."; running = false
                action = nil; tone = .off
            }
        }
    }
}
