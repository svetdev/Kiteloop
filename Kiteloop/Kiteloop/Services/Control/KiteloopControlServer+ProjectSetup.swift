import Foundation
import KiteloopCore

/// Closing a project, its settings, and changing or removing a backlog item.
@MainActor
struct ProjectSetupEndpoints {
    let server: KiteloopControlServer

    func answer(_ route: ManagementRoute, _ req: HTTPServer.Request) async throws -> HTTPServer.Response {
        switch route {
        case .closeProject: return try await closeProject(KiteloopControlServer.jsonBody(req.body))
        case .getProjectSettings: return .json(Self.settingsJSON(try server.openProject(req.query["project"]).session.project.loadConfig()))
        case .setProjectSettings: return try setProjectSettings(KiteloopControlServer.jsonBody(req.body))
        case .updateBacklogItem: return try updateBacklogItem(KiteloopControlServer.jsonBody(req.body))
        default: return try deleteBacklogItem(req.query)
        }
    }

    // MARK: - Closing a project

    private func closeProject(_ fields: [String: Any]) async throws -> HTTPServer.Response {
        let entry = try server.openProject(fields["project"])
        guard let close = server.registry.closeProject else {
            throw ControlRefusal("Project closing is unavailable — the app window isn't running", status: 503)
        }
        guard await entry.autopilot.inFlightRun() == nil else {
            throw ControlRefusal("This project's autopilot has a run in flight; cancel or finish it first", status: 409)
        }
        let id = entry.session.project.id
        await close(id)
        return .json(["closed": id])
    }

    // MARK: - Project settings

    private static func settingsJSON(_ config: ProjectConfig) -> [String: Any] {
        [
            "model": config.model ?? NSNull(),
            "permissionMode": config.permissionMode,
            "effort": config.effort ?? NSNull(),
            "maxBudgetUSD": config.maxBudgetUSD ?? NSNull(),
            "goal": config.goal ?? NSNull(),
            "companions": (config.companions ?? []).map { repo -> [String: Any] in
                var row: [String: Any] = ["name": repo.name, "path": repo.path]
                if let base = repo.baseBranch { row["base"] = base }
                return row
            }
        ]
    }

    private func setProjectSettings(_ fields: [String: Any]) throws -> HTTPServer.Response {
        let entry = try server.openProject(fields["project"])
        let project = entry.session.project
        var config = project.loadConfig()
        var edit = ProjectSettingsEdit(fields: fields)
        try edit.apply(to: &config)
        guard edit.changed else {
            throw ControlRefusal("Must include at least one of: \(ProjectSettingsEdit.fields.joined(separator: ", "))", status: 400)
        }
        try project.saveConfig(config)
        return .json(Self.settingsJSON(config))
    }

    // MARK: - Backlog items

    /// Statuses in which a run has the item: its line is the run's to write.
    private static let inARun: Set<BacklogItemStatus> = [.active, .inReview]

    /// The item a request names, in the open project it names — refused while
    /// a run has it.
    private func backlogItem(_ fields: [String: Any]) throws -> (entry: ControlSessionRegistry.Entry, item: BacklogItem) {
        guard let id = fields["item"] as? String, fields["project"] is String else {
            throw ControlRefusal.missing("\"project\" and \"item\"")
        }
        let entry = try server.openProject(fields["project"])
        guard let item = entry.session.backlogViewModel.item(withID: id) else {
            throw ControlRefusal("No item '\(id)' in the backlog", status: 404)
        }
        guard !Self.inARun.contains(item.status) else {
            throw ControlRefusal("A run is working on \(id); cancel it first", status: 409)
        }
        return (entry, item)
    }

    private static let itemFields = ["title", "verify", "size", "detail"]

    private func updateBacklogItem(_ fields: [String: Any]) throws -> HTTPServer.Response {
        let (entry, item) = try backlogItem(fields)
        let named = Self.itemFields.filter { fields[$0] != nil }
        // Checked whole before anything is written: a refused size must not
        // leave the title changed.
        let size = try Self.checkedSize(fields, named: named, hasDetailFile: item.detailPath != nil)
        let backlog = entry.session.backlogViewModel
        if let title = fields["title"] as? String { backlog.renameItem(itemID: item.id, to: title) }
        if let verify = fields["verify"] as? String { backlog.setItemVerify(itemID: item.id, to: verify) }
        if let size { backlog.updateItemSize(itemID: item.id, size: size) }
        if let detail = fields["detail"] as? String { backlog.overwriteDetail(for: item, content: detail) }
        return .json(["item": item.id, "title": backlog.item(withID: item.id)?.title ?? item.title, "changed": named])
    }

    /// Refuses a change that cannot be made whole, and reads the size it names.
    private static func checkedSize(_ fields: [String: Any], named: [String], hasDetailFile: Bool) throws -> ItemSize? {
        guard !named.isEmpty else {
            throw ControlRefusal("Must include at least one of: \(itemFields.joined(separator: ", "))", status: 400)
        }
        guard hasDetailFile || !named.contains("detail") else {
            throw ControlRefusal("The item has no detail file to write; groom it first", status: 400)
        }
        if let wrong = named.first(where: { !(fields[$0] is String) }) {
            throw ControlRefusal("\"\(wrong)\" must be a string", status: 400)
        }
        for key in ["title", "verify"] { try (fields[key] as? String).map { try lineField(key, $0) } }
        return try (fields["size"] as? String).map(size)
    }

    /// A title or a verify sits on the backlog line, between its separators.
    private static func lineField(_ key: String, _ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ControlRefusal("\"\(key)\" can't be empty", status: 400)
        }
        guard !text.contains(DefinitionOfReady.fieldSeparator) else {
            throw ControlRefusal("\"\(key)\" can't contain “\(DefinitionOfReady.fieldSeparator)”, the backlog line's field separator",
                                 status: 400)
        }
    }

    private static func size(_ text: String) throws -> ItemSize {
        guard let size = ItemSize(rawValue: text.uppercased()) else {
            throw ControlRefusal("\"size\" must be one of: \(ItemSize.allCases.map(\.rawValue).joined(separator: ", "))", status: 400)
        }
        return size
    }

    private func deleteBacklogItem(_ query: [String: String]) throws -> HTTPServer.Response {
        let (entry, item) = try backlogItem(query)
        guard item.status != .awaitingApproval else {
            throw ControlRefusal("\(item.id) has work waiting at its gate; approve or reject it first", status: 409)
        }
        entry.session.backlogViewModel.removeItem(itemID: item.id)
        return .json(["removed": item.id])
    }
}

/// The fields of a project's settings a request names, checked and applied.
struct ProjectSettingsEdit {
    static let fields = ["model", "permissionMode", "effort", "maxBudgetUSD", "goal", "companions"]

    let fields: [String: Any]
    private(set) var changed = false

    /// A field that holds text or null; nil when the request does not name it.
    private func optionalText(_ key: String) throws -> String?? {
        guard let value = fields[key] else { return nil }
        if value is NSNull { return .some(nil) }
        guard let text = value as? String else { throw ControlRefusal("\"\(key)\" must be a string or null", status: 400) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .some(trimmed.isEmpty ? nil : trimmed)
    }

    mutating func apply(to config: inout ProjectConfig) throws {
        if let model = try optionalText("model") { config.model = model; changed = true }
        if let goal = try optionalText("goal") { config.goal = goal; changed = true }
        if let effort = try optionalText("effort") {
            guard effort.map(AgentEdit.effortLevels.contains) ?? true else {
                throw ControlRefusal("\"effort\" must be null or one of: \(AgentEdit.effortLevels.joined(separator: ", "))", status: 400)
            }
            config.effort = effort
            changed = true
        }
        try applyMode(to: &config)
        try applyBudget(to: &config)
        try applyCompanions(to: &config)
    }

    private mutating func applyMode(to config: inout ProjectConfig) throws {
        guard let value = fields["permissionMode"] else { return }
        guard let mode = (value as? String).flatMap({ mode in Agent.permissionModes.first { $0 == mode } }) else {
            throw ControlRefusal("\"permissionMode\" must be auto, acceptEdits, plan, default, dontAsk or bypassPermissions", status: 400)
        }
        config.permissionMode = mode
        changed = true
    }

    private mutating func applyBudget(to config: inout ProjectConfig) throws {
        guard let value = fields["maxBudgetUSD"] else { return }
        if value is NSNull {
            config.maxBudgetUSD = nil
        } else {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue > 0 else {
                throw ControlRefusal("\"maxBudgetUSD\" must be a number above zero, or null for no ceiling", status: 400)
            }
            config.maxBudgetUSD = number.doubleValue
        }
        changed = true
    }

    private mutating func applyCompanions(to config: inout ProjectConfig) throws {
        guard let value = fields["companions"] else { return }
        guard let rows = value as? [[String: Any]] else {
            throw ControlRefusal("\"companions\" must be an array of {name, path, base}", status: 400)
        }
        let repos = try rows.map { row -> CompanionRepo in
            guard let name = row["name"] as? String, let path = row["path"] as? String, !name.isEmpty, !path.isEmpty else {
                throw ControlRefusal("Each companion needs a \"name\" and a \"path\"", status: 400)
            }
            return CompanionRepo(name: name, path: path, baseBranch: row["base"] as? String)
        }
        config.companions = repos.isEmpty ? nil : repos
        changed = true
    }
}
