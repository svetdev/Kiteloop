import Foundation
import KiteloopCore

/// The app's own settings: its MCP servers and its defaults.
@MainActor
struct AppSettingsEndpoints {
    let server: KiteloopControlServer

    func answer(_ route: ManagementRoute, _ req: HTTPServer.Request) throws -> HTTPServer.Response {
        guard let settings = server.settings else { throw ControlRefusal("This Kiteloop has no settings store attached", status: 503) }
        switch route {
        case .listMCPServers:
            let servers = settings.config.mcpServers ?? [:]
            return .json(["servers": servers.keys.sorted().map {
                Self.serverJSON($0, servers[$0] ?? ClaudeMCPServerEntry(), status: newestStatus(of: $0))
            }])
        case .putMCPServer(let name): return try putMCPServer(name, body: req.body, in: settings)
        case .deleteMCPServer(let name): return try deleteMCPServer(name, in: settings)
        case .getSettings: return .json(settingsJSON(settings))
        default: return try setSettings(KiteloopControlServer.jsonBody(req.body), in: settings)
        }
    }

    // MARK: - MCP servers

    /// A server as the API shows it. The values of its environment are left
    /// out: they are where its credentials are. What looks like a credential
    /// in its command line or URL is replaced, best effort (`SecretRedaction`).
    private static func serverJSON(_ name: String, _ entry: ClaudeMCPServerEntry) -> [String: Any] {
        var row: [String: Any] = ["name": name, "summary": entry.redactedSummary, "env": (entry.env ?? [:]).keys.sorted()]
        if let command = entry.command { row["command"] = SecretRedaction.text(command) }
        if let args = entry.args { row["args"] = SecretRedaction.commandLine(args) }
        return row
    }

    /// The listed row, with what the last session to start reported of the
    /// server: `unknown` and no tools when none has.
    private static func serverJSON(_ name: String, _ entry: ClaudeMCPServerEntry, status: ConnectorStatus?) -> [String: Any] {
        var row = serverJSON(name, entry)
        row["status"] = status?.state ?? "unknown"
        row["tools"] = status?.tools ?? []
        row["reportedAt"] = status.map { iso.string(from: $0.reportedAt) } ?? NSNull()
        return row
    }

    private static let iso = ISO8601DateFormatter()

    /// The newest report of a server across every open project's sessions.
    private func newestStatus(of name: String) -> ConnectorStatus? {
        server.registry.entries.values
            .compactMap { $0.session.orchestrator.connectorStatus(named: name) }
            .max { $0.reportedAt < $1.reportedAt }
    }

    private func putMCPServer(_ name: String, body: Data, in settings: GlobalConfigStore) throws -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], !json.isEmpty else {
            throw ControlRefusal("Body must be the server's entry: command, args and env, or type and url", status: 400)
        }
        // The decoder keeps a key it cannot read as given, so the three it
        // models are checked here: an `args` that is one string is a mistake.
        let wellTyped = (json["command"].map { $0 is String } ?? true)
            && (json["args"].map { $0 is [String] } ?? true)
            && (json["env"].map { $0 is [String: String] } ?? true)
        guard wellTyped, let entry = try? JSONDecoder().decode(ClaudeMCPServerEntry.self, from: body) else {
            throw ControlRefusal("\"command\" is a string, \"args\" an array of strings and \"env\" an object of strings", status: 400)
        }
        var servers = settings.config.mcpServers ?? [:]
        servers[name] = entry
        settings.setMCPServers(servers)
        return .json(["server": Self.serverJSON(name, entry)])
    }

    private func deleteMCPServer(_ name: String, in settings: GlobalConfigStore) throws -> HTTPServer.Response {
        var servers = settings.config.mcpServers ?? [:]
        guard servers.removeValue(forKey: name) != nil else { throw ControlRefusal("No MCP server '\(name)'", status: 404) }
        settings.setMCPServers(servers.isEmpty ? nil : servers)
        return .json(["removed": name])
    }

    // MARK: - Settings

    private func settingsJSON(_ settings: GlobalConfigStore) -> [String: Any] {
        var json: [String: Any] = [
            "defaultModel": settings.config.defaultModel ?? NSNull(),
            "defaultEffort": settings.config.defaultEffort ?? NSNull(),
            "soundTheme": SoundTheme(stored: server.defaults.string(forKey: SoundTheme.defaultsKey)).rawValue,
            "agentAPIChangesNeedApproval": settings.config.agentAPIChangesNeedApproval ?? true
        ]
        if let updater = server.updater { json["automaticUpdateChecks"] = updater.automaticallyChecksForUpdates }
        return json
    }

    private func setSettings(_ fields: [String: Any], in settings: GlobalConfigStore) throws -> HTTPServer.Response {
        let edit = try AppSettingsEdit(fields: fields, canSetUpdateChecks: server.updater != nil)
        if let model = edit.defaultModel { settings.setDefaultModel(model) }
        if let effort = edit.defaultEffort { settings.setDefaultEffort(effort) }
        if let theme = edit.soundTheme { server.defaults.set(theme.rawValue, forKey: SoundTheme.defaultsKey) }
        if let checks = edit.automaticUpdateChecks { server.updater?.automaticallyChecksForUpdates = checks }
        if let held = edit.agentAPIChangesNeedApproval { settings.setAgentAPIChangesNeedApproval(held) }
        return .json(settingsJSON(settings))
    }
}

/// The app settings a request names, checked before any of them is written.
struct AppSettingsEdit {
    static let fields = ["defaultModel", "defaultEffort", "soundTheme", "automaticUpdateChecks",
                         "agentAPIChangesNeedApproval"]

    /// `.some(nil)` clears the default.
    var defaultModel: String??
    var defaultEffort: String??
    var soundTheme: SoundTheme?
    var automaticUpdateChecks: Bool?
    /// Whether an agent's configuration changes over the API wait on a person.
    var agentAPIChangesNeedApproval: Bool?

    init(fields: [String: Any], canSetUpdateChecks: Bool) throws {
        guard Self.fields.contains(where: { fields[$0] != nil }) else {
            throw ControlRefusal("Must include at least one of: \(Self.fields.joined(separator: ", "))", status: 400)
        }
        defaultModel = try Self.optionalText(fields, "defaultModel")
        defaultEffort = try Self.optionalText(fields, "defaultEffort")
        if case .some(.some(let effort)) = defaultEffort, !AgentEdit.effortLevels.contains(effort) {
            throw ControlRefusal("\"defaultEffort\" must be null or one of: \(AgentEdit.effortLevels.joined(separator: ", "))", status: 400)
        }
        soundTheme = try Self.theme(fields["soundTheme"])
        automaticUpdateChecks = try Self.updateChecks(fields, canSet: canSetUpdateChecks)
        agentAPIChangesNeedApproval = try Self.flag(fields, "agentAPIChangesNeedApproval")
    }

    private static func flag(_ fields: [String: Any], _ key: String) throws -> Bool? {
        guard let value = fields[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ControlRefusal("\"\(key)\" must be true or false", status: 400)
        }
        return number.boolValue
    }

    private static func optionalText(_ fields: [String: Any], _ key: String) throws -> String?? {
        guard let value = fields[key] else { return nil }
        if value is NSNull { return .some(nil) }
        guard let text = value as? String else { throw ControlRefusal("\"\(key)\" must be a string or null", status: 400) }
        return .some(text.isEmpty ? nil : text)
    }

    private static func theme(_ value: Any?) throws -> SoundTheme? {
        guard let value else { return nil }
        guard let theme = (value as? String).flatMap(SoundTheme.init(rawValue:)) else {
            throw ControlRefusal("\"soundTheme\" must be one of: \(SoundTheme.allCases.map(\.rawValue).joined(separator: ", "))", status: 400)
        }
        return theme
    }

    private static func updateChecks(_ fields: [String: Any], canSet: Bool) throws -> Bool? {
        guard let checks = try flag(fields, "automaticUpdateChecks") else { return nil }
        guard canSet else { throw ControlRefusal("This Kiteloop has no updater attached", status: 503) }
        return checks
    }
}
