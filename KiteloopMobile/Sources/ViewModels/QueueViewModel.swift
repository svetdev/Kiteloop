import Foundation
import Observation

/// One project's backlog, in the document order that *is* its priority, with
/// the verbs the API offers: approve, groom both ways, move to top, release.
@Observable @MainActor
final class QueueViewModel {
    var project = "kiteloop"
    var projects: [String] = []
    var items: [BacklogItem] = []
    var refusals: [GroomingRecord] = []
    var error: String?
    var loading = false

    func refresh(_ client: ControlClient) async {
        loading = true
        defer { loading = false }
        do {
            (projects, project) = try await client.projectsAndSelection(holding: project)
            items = (try await client.get(client.query("/v1/backlog", [("project", project)]), as: BacklogReply.self).items) ?? []
            let groomingPath = client.query("/v1/grooming", [("project", project), ("limit", "200")])
            refusals = ((try await client.get(groomingPath, as: GroomingReply.self).grooming) ?? [])
                .filter { $0.event == "check-failed" }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func act(_ client: ControlClient, _ path: String, _ body: [String: Any]) async {
        do {
            _ = try await client.post(path, body)
            await refresh(client)
        } catch { self.error = error.localizedDescription }
    }

    func moveToTop(_ client: ControlClient, _ item: BacklogItem) async {
        await act(client, "/v1/backlog/move", ["project": project, "item": item.id])
    }
    func groom(_ client: ControlClient, _ item: BacklogItem, to status: String) async {
        await act(client, "/v1/backlog/groom", ["project": project, "item": item.id, "status": status])
    }
    /// Flips the item between the lanes; it keeps its place in its epic.
    func flipLane(_ client: ControlClient, _ item: BacklogItem) async {
        await act(client, "/v1/backlog/lane",
                  ["project": project, "item": item.id, "lane": item.flippedLane])
    }
    func release(_ client: ControlClient, _ item: BacklogItem) async {
        await act(client, "/v1/backlog/release", ["project": project, "item": item.id])
    }

    /// Files an idea as a draft (`POST /v1/backlog/items`), groomed on the
    /// Mac afterwards when asked. The item shows at once, ahead of the
    /// refresh that brings its line as the Mac wrote it. Nil when filed,
    /// else the Mac's reason.
    func file(_ client: ControlClient, title: String, note: String, groom: Bool) async -> String? {
        do {
            let reply = try await client.post("/v1/backlog/items", Self.filingBody(project: project, title: title, note: note, groom: groom))
            if let item = Self.filedItem(reply, title: title) { items.append(item) }
            await refresh(client)
            return nil
        } catch {
            return NowViewModel.refusalText(error)
        }
    }

    /// The body: the note and the groom flag only when they say something.
    nonisolated static func filingBody(project: String, title: String, note: String, groom: Bool) -> [String: Any] {
        var body: [String: Any] = ["project": project, "title": title.trimmingCharacters(in: .whitespacesAndNewlines)]
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { body["note"] = note }
        if groom { body["groom"] = true }
        return body
    }

    /// The item the Mac's answer names, as the list shows one.
    nonisolated static func filedItem(_ reply: [String: Any], title: String) -> BacklogItem? {
        guard let id = reply["item"] as? String else { return nil }
        return BacklogItem(id: id, title: title, status: reply["status"] as? String ?? "draft", epic: reply["epic"] as? String)
    }

    func refusal(for item: BacklogItem) -> GroomingRecord? {
        refusals.first { $0.item == item.id }
    }

    /// The `now` items across every epic, in document order — the order they
    /// run in, ahead of everything else.
    var nowItems: [BacklogItem] { items.filter(\.isNow) }

    /// The epics in document order — which is their priority — each with its
    /// `later` items in theirs. A `now` item is listed under Now instead.
    var epics: [(name: String, items: [BacklogItem])] {
        var order: [String] = []
        var grouped: [String: [BacklogItem]] = [:]
        for item in items where !item.isNow {
            let epic = item.epic ?? "Ungrouped"
            if grouped[epic] == nil { order.append(epic) }
            grouped[epic, default: []].append(item)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// The item's groomed detail, or why it could not be read — handed back to
    /// the item page, which covers the list that shows `error`.
    func detail(_ client: ControlClient, _ item: BacklogItem) async -> Result<ItemDetailReply, NowViewModel.LoadFailure> {
        do {
            return .success(try await client.get(client.query("/v1/backlog/detail", [("project", project), ("item", item.id)]), as: ItemDetailReply.self))
        } catch {
            return .failure(NowViewModel.LoadFailure(reason: NowViewModel.refusalText(error)))
        }
    }
}
