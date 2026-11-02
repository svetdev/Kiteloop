import Foundation
import Observation

/// The controls, apart from the dashboards on purpose: reading state is
/// routine, moving a lever is a decision. Pass ceiling, the two switches,
/// pause/resume, and the fleet-wide stop.
@Observable @MainActor
final class LeversViewModel {
    var refill: RefillReply?
    var scheduling: SchedulingReply?
    var fleet: FleetReply?
    /// Nil from a Mac older than `GET /v1/usage`, which the rest still reads past.
    var usage: UsageReply?
    var project = "kiteloop"
    var projects: [String] = []
    var freshness = RefreshState(interval: 15)
    /// A lever that did not take — apart from the refresh, which is reading.
    var error: String?
    var confirmation: String?

    func refresh(_ client: ControlClient) async {
        freshness.begin()
        do {
            (projects, project) = try await client.projectsAndSelection(holding: project)
            refill = try await client.get("/v1/coordinator/refill")
            scheduling = try await client.get("/v1/coordinator/scheduling")
            fleet = try await client.get("/v1/fleet/quiesce")
            usage = try? await client.get("/v1/usage")
            freshness.succeed(at: Date())
        } catch { freshness.fail(error, host: ProjectViewModel.host(of: client.baseURL)) }
    }

    func setPassCeiling(_ client: ControlClient, _ ceiling: Int) async {
        do {
            _ = try await client.put("/v1/coordinator/refill", ["maxPasses": max(1, ceiling)])
            confirmation = "Pass ceiling → \(ceiling)"
            await refresh(client)
        } catch { self.error = error.localizedDescription }
    }

    /// How many projects the fleet may run at once. The Mac clamps to 1…8 and
    /// refuses anything outside it, so the step is bounded here too; the next
    /// refresh reads back what the Mac settled on.
    func setRunsAtOnce(_ client: ControlClient, _ count: Int) async {
        let bounded = min(max(count, 1), 8)
        do {
            _ = try await client.put("/v1/coordinator/scheduling", ["maxConcurrentRuns": bounded])
            confirmation = "Runs at once → \(bounded)"
            await refresh(client)
        } catch { self.error = error.localizedDescription }
    }

    func autopilot(_ client: ControlClient, resume: Bool) async {
        do {
            _ = try await client.post(resume ? "/v1/autopilot/resume" : "/v1/autopilot/pause", ["project": project])
            confirmation = resume ? "Autopilot resumed" : "Autopilot paused after the item in flight"
        } catch { self.error = error.localizedDescription }
    }

    func fleet(_ client: ControlClient, resume: Bool) async {
        do {
            _ = try await client.post(resume ? "/v1/fleet/resume" : "/v1/fleet/quiesce", [:])
            confirmation = resume ? "Fleet resumed" : "Fleet quiescing — draining the run in flight"
            await refresh(client)
        } catch { self.error = error.localizedDescription }
    }
}
