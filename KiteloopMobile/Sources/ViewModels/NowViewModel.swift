import Foundation
import Observation

/// The home tab's one question: does Kiteloop need me? Gates first, then what
/// is running, then the Planner's state. Everything refreshes together — a
/// half-updated dashboard is a wrong dashboard.
@Observable @MainActor
final class NowViewModel {
    struct Gate: Identifiable, Hashable {
        let project: String
        let item: BacklogItem
        var id: String { project + "/" + item.id }
    }

    var health: Health?
    var projects: [Project] = []
    var gates: [Gate] = []
    var refill: RefillReply?
    var scheduling: SchedulingReply?
    var report: ReportReply?
    var error: String?
    var loading = false

    func refresh(_ client: ControlClient) async {
        loading = true
        defer { loading = false }
        do {
            health = try await client.get("/health")
            projects = (try await client.get("/v1/projects", as: ProjectsReply.self).projects) ?? []
            refill = try await client.get("/v1/coordinator/refill")
            scheduling = try await client.get("/v1/coordinator/scheduling")
            var found: [Gate] = []
            for project in projects where (project.queue?.awaitingApproval ?? 0) > 0 {
                let items = (try await client.get(client.query("/v1/backlog", [("project", project.name)]), as: BacklogReply.self).items) ?? []
                found += items.filter(\.needsPerson).map { Gate(project: project.name, item: $0) }
            }
            gates = found
            report = try await client.get("/v1/report?hours=24")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// What the Mac did with a decision: the item left the gate (merged, or
    /// resolved without a merge and the Mac's note on why), or it refused and
    /// the item is still at the gate.
    enum ApprovalOutcome: Equatable {
        case resolved
        case resolvedWithoutMerge(String)
        case refused(String)

        var leftGate: Bool {
            if case .refused = self { return false }
            return true
        }
    }

    func approve(_ client: ControlClient, project: String, item: String, approve: Bool, reason: String? = nil) async -> ApprovalOutcome {
        do {
            let body = Self.approvalBody(project: project, item: item, approve: approve, reason: reason)
            let reply = try await client.post("/v1/backlog/approve", body, timeout: ControlClient.approvalTimeout)
            await refresh(client)
            if approve, reply["merged"] as? Bool == false, let note = reply["mergeSkipped"] as? String {
                return .resolvedWithoutMerge(note)
            }
            return .resolved
        } catch {
            return .refused(Self.refusalText(error))
        }
    }

    /// The `/v1/backlog/approve` body. A rejection carries `reason` — written
    /// to the item's Notes for the next run — only when it says something; an
    /// approval never does.
    nonisolated static func approvalBody(project: String, item: String, approve: Bool, reason: String?) -> [String: Any] {
        var body: [String: Any] = ["project": project, "item": item, "approve": approve]
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !approve, !trimmed.isEmpty { body["reason"] = trimmed }
        return body
    }

    /// The Mac's own words for a refusal: an `.http` body's JSON `reason`,
    /// else its `error`, else the body as written. Anything else is described
    /// the way the error describes itself.
    nonisolated static func refusalText(_ error: Error) -> String {
        guard case ControlClient.ClientError.http(_, let body) = error else { return error.localizedDescription }
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        return json?["reason"] as? String ?? json?["error"] as? String ?? body
    }

    /// Only a 404 from the diff endpoint means "no branch"; anything else —
    /// unreachable, timed out, project not open, a server error — is a fetch
    /// that failed, described in the Mac's own words where it gave any.
    nonisolated static func diffFailure(_ error: Error) -> DiffOutcome {
        if case ControlClient.ClientError.http(404, _) = error { return .noBranch }
        return .failed(refusalText(error))
    }

    struct LoadFailure: Error, Equatable {
        let reason: String
    }

    /// What the gate's diff fetch came back with: the diff, the Mac's word
    /// that there is no branch to diff, or a failure and its reason.
    enum DiffOutcome {
        case loaded(DiffReply)
        case noBranch
        case failed(String)
    }

    /// The item's What/Validation/Notes, or why they could not be loaded.
    func detail(_ client: ControlClient, _ gate: Gate) async -> Result<ItemDetailReply, LoadFailure> {
        do {
            let reply: ItemDetailReply = try await client.get(client.query("/v1/backlog/detail", [("project", gate.project), ("item", gate.item.id)]))
            return .success(reply)
        } catch {
            return .failure(LoadFailure(reason: Self.refusalText(error)))
        }
    }

    func diff(_ client: ControlClient, _ gate: Gate) async -> DiffOutcome {
        do {
            let reply: DiffReply = try await client.get(client.query("/v1/backlog/diff", [("project", gate.project), ("item", gate.item.id)]))
            return .loaded(reply)
        } catch {
            return Self.diffFailure(error)
        }
    }
}
