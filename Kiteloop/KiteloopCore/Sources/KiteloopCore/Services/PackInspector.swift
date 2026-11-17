import Foundation

/// Why a pack folder could not be inspected. Each case names the file, and
/// where there is one the field, so the pack's author knows what to fix.
package enum PackInspectionError: Error, Equatable, LocalizedError {
    /// The folder has no `pack.json`.
    case missingManifest(folder: String)
    /// A file in the pack could not be read as what the manifest says it is.
    /// `field` is the key path inside the file, when the fault has one.
    case undecodable(file: String, field: String?, reason: String)
    /// `pack.json` lists, under `field`, a path the folder does not hold.
    case missingPath(path: String, field: String)
    /// `pack.json` lists, under `field`, a path that leaves the pack folder —
    /// absolute, through `..`, or through a symlink.
    case escapesPack(path: String, field: String)

    package var errorDescription: String? {
        switch self {
        case .missingManifest(let folder):
            return "\(folder) holds no \(PackManifest.fileName), so it is not a pack."
        case .undecodable(let file, let field, let reason):
            guard let field else { return "\(file) \(reason)." }
            return "\(file): `\(field)` \(reason)."
        case .missingPath(let path, let field):
            return "\(PackManifest.fileName): `\(field)` lists \(path), which is not in the pack."
        case .escapesPack(let path, let field):
            return "\(PackManifest.fileName): `\(field)` lists \(path), which is outside the pack folder."
        }
    }
}

/// What a pack would add and what it would be allowed to do, read off the
/// folder without changing anything.
package struct PackInspection: Equatable, Sendable {
    package struct Agent: Equatable, Sendable {
        /// The directory, as `pack.json` lists it.
        package let path: String
        package let handle: String
        package let name: String
        /// Nil when the agent leaves the mode to the app's default.
        package let permissionMode: String?
        /// Nil when the agent takes the app's default tools.
        package let tools: [String]?
        package let mcpServers: [String]
        /// Whether the agent asks for Operator tools: a control API credential
        /// in its environment.
        package let operatorTools: Bool
        /// Which credential that is; nil when the agent does not say.
        package let controlAccess: AgentControlAccess?
    }

    package struct RoutineEntry: Equatable, Sendable {
        package let path: String
        package let id: String
        package let name: String
        package let agent: String
        /// When it fires, in words: `at 08:30 on mon, fri`.
        package let trigger: String
        package let precheck: String?
        /// Whether the file marks it armed. Reported, never acted on.
        package let armed: Bool
    }

    package struct Connector: Equatable, Sendable {
        package let path: String
        package let name: String
        /// The command line, or the transport and endpoint of a remote server,
        /// through `SecretRedaction`.
        package let summary: String
        /// Names of the environment variables it expects. Never their values.
        package let envNames: [String]
        /// Names of the HTTP headers it sends. Never their values.
        package let headerNames: [String]
    }

    package struct Template: Equatable, Sendable {
        package let path: String
        package let fileName: String
        package let title: String
    }

    package let name: String
    package let version: String
    package let description: String?
    package let agents: [Agent]
    package let routines: [RoutineEntry]
    package let connectors: [Connector]
    package let templates: [Template]

    /// One line per thing the pack would be allowed to do: each agent's
    /// permission mode and tools, each connector's command line or endpoint
    /// with the names of the secrets it expects, each routine's agent, trigger
    /// and precheck command.
    package var permissions: [String] {
        agents.map(\.permissionLine) + connectors.map(\.permissionLine) + routines.map(\.permissionLine)
    }

    /// The whole inspection as text a person reads before deciding.
    package var account: String {
        var lines = ["\(name) \(version)"]
        if let description, !description.isEmpty { lines.append(description) }
        lines += Self.section("Agents", agents.map { "\($0.handle) — \($0.name)" })
        lines += Self.section("Routines", routines.map { "\($0.id) — \($0.name)" })
        lines += Self.section("Connectors", connectors.map(\.name))
        lines += Self.section("Templates", templates.map { "\($0.fileName) — \($0.title)" })
        lines += Self.section("What it would be allowed to do", permissions)
        return lines.joined(separator: "\n")
    }

    private static func section(_ title: String, _ rows: [String]) -> [String] {
        guard !rows.isEmpty else { return [] }
        return ["", "\(title) (\(rows.count))"] + rows.map { "• \($0)" }
    }
}

extension PackInspection.Agent {
    package var permissionLine: String {
        let mode = permissionMode.map { "permission mode \($0)" } ?? "the app's default permission mode"
        let allowed = tools.map { $0.isEmpty ? "no tools" : "tools \($0.joined(separator: ", "))" }
            ?? "the app's default tools"
        let servers = mcpServers.isEmpty ? "" : ", and uses connectors \(mcpServers.joined(separator: ", "))"
        let operatorTools = credential.map { ", and holds Operator tools (\($0))" } ?? ""
        return "Agent \(handle) (\(name)) runs in \(mode) with \(allowed)\(servers)\(operatorTools)."
    }

    /// The control API credential the agent asks for, in words; nil for an
    /// agent that asks for none.
    package var credential: String? {
        guard operatorTools else { return nil }
        switch controlAccess ?? .whenUnstated {
        case .operatorToken: return "the control API's operator token"
        case .readOnly: return "a read-only control API token"
        }
    }
}

extension PackInspection.Connector {
    package var permissionLine: String {
        var line = "Connector \(name) " + (summary.isEmpty ? "declares nothing to run" : "runs `\(summary)`")
        if !envNames.isEmpty { line += "; expects env \(envNames.joined(separator: ", "))" }
        if !headerNames.isEmpty { line += "; expects headers \(headerNames.joined(separator: ", "))" }
        return line + "."
    }
}

extension PackInspection.RoutineEntry {
    package var permissionLine: String {
        var line = "Routine \(id) prompts agent \(agent) \(trigger)"
        if let precheck { line += ", after running the shell command `\(precheck)`" }
        if armed { line += "; the pack marks it armed" }
        return line + "."
    }
}

/// Reads a pack folder and says what is in it. It opens files for reading
/// only, inside the folder only, and it never carries a connector's
/// environment or header *values* into what it returns — only their names.
package struct PackInspector {
    package init() {}

    package func inspect(folder: URL) throws -> PackInspection {
        let manifestURL = folder.appendingPathComponent(PackManifest.fileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PackInspectionError.missingManifest(folder: folder.path)
        }
        let manifest = try decode(PackManifest.self, file: PackManifest.fileName, at: manifestURL)
        return PackInspection(
            name: manifest.name,
            version: manifest.version,
            description: manifest.description,
            agents: try (manifest.agents ?? []).map { try agent(at: $0, in: folder) },
            routines: try (manifest.routines ?? []).map { try routine(at: $0, in: folder) },
            connectors: try (manifest.connectors ?? []).flatMap { try connectors(at: $0, in: folder) },
            templates: try (manifest.templates ?? []).map { try template(at: $0, in: folder) }
        )
    }

    // MARK: - One function per kind

    /// Only what the inspection reports of an `agent.json`; the app's
    /// `AgentPackage` decodes the rest when a pack is installed.
    private struct AgentFile: Decodable {
        struct Template: Decodable {
            let name: String
            let permissionMode: String?
            let tools: [String]?
            let mcpServers: [String]?
            let operatorToolsEnabled: Bool?
            let controlAccess: AgentControlAccess?
        }
        let handle: String
        let template: Template
    }

    private func agent(at listed: String, in folder: URL) throws -> PackInspection.Agent {
        _ = try resolve(listed, field: "agents", in: folder)
        let file = (listed as NSString).appendingPathComponent("agent.json")
        let url = try resolve(file, field: "agents", in: folder)
        let decoded = try decode(AgentFile.self, file: file, at: url)
        return PackInspection.Agent(path: listed, handle: decoded.handle, name: decoded.template.name,
                                    permissionMode: decoded.template.permissionMode,
                                    tools: decoded.template.tools,
                                    mcpServers: decoded.template.mcpServers ?? [],
                                    operatorTools: decoded.template.operatorToolsEnabled ?? false,
                                    controlAccess: decoded.template.controlAccess)
    }

    private func routine(at listed: String, in folder: URL) throws -> PackInspection.RoutineEntry {
        let url = try resolve(listed, field: "routines", in: folder)
        let routine = try decode(Routine.self, file: listed, at: url)
        return PackInspection.RoutineEntry(path: listed, id: routine.id, name: routine.name,
                                           agent: routine.agent, trigger: Self.words(for: routine.trigger),
                                           precheck: routine.precheck, armed: routine.armed)
    }

    private func connectors(at listed: String, in folder: URL) throws -> [PackInspection.Connector] {
        let url = try resolve(listed, field: "connectors", in: folder)
        let servers = try decode([String: ClaudeMCPServerEntry].self, file: listed, at: url)
        return servers.keys.sorted().compactMap { name in
            servers[name].map { entry in
                PackInspection.Connector(path: listed, name: name, summary: entry.redactedSummary,
                                         envNames: Self.envNames(of: entry),
                                         headerNames: Self.keys(of: entry.extras["headers"]))
            }
        }
    }

    private func template(at listed: String, in folder: URL) throws -> PackInspection.Template {
        let url = try resolve(listed, field: "templates", in: folder)
        guard let data = try? Data(contentsOf: url) else {
            throw PackInspectionError.undecodable(file: listed, field: nil, reason: "cannot be read")
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return PackInspection.Template(path: listed, fileName: url.lastPathComponent,
                                       title: Self.title(in: data) ?? stem)
    }

    // MARK: - Reading

    /// The names under `env`, whether it decoded as plain strings or — being
    /// some richer shape — was kept in `extras`.
    private static func envNames(of entry: ClaudeMCPServerEntry) -> [String] {
        Set((entry.env ?? [:]).keys).union(keys(of: entry.extras["env"])).sorted()
    }

    private static func keys(of value: AnyCodable?) -> [String] {
        guard case .dictionary(let pairs)? = value else { return [] }
        return pairs.keys.sorted()
    }

    /// A template's title: the `title` or `name` of a JSON object, otherwise
    /// the first Markdown heading. Nil when the file offers neither.
    private static func title(in data: Data) -> String? {
        if let object = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
            return object["title"]?.stringValue ?? object["name"]?.stringValue
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let heading = text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("# ") }
        return heading.map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
    }

    private static func words(for trigger: Routine.Trigger) -> String {
        var parts: [String] = []
        if let at = trigger.at { parts.append("at \(at)") }
        if let every = trigger.every { parts.append("every \(every) min") }
        if let from = trigger.from { parts.append("from \(from)") }
        if let until = trigger.until { parts.append("until \(until)") }
        if let days = trigger.days, !days.isEmpty { parts.append("on \(days.joined(separator: ", "))") }
        return parts.isEmpty ? "on no schedule" : parts.joined(separator: " ")
    }

    /// The file a manifest path names, refused unless it exists and stays
    /// inside the pack folder once every symlink on the way is followed.
    func resolve(_ listed: String, field: String, in folder: URL) throws -> URL {
        let escape = PackInspectionError.escapesPack(path: listed, field: field)
        guard !listed.hasPrefix("/"), !listed.split(separator: "/").contains("..") else { throw escape }
        let url = folder.appendingPathComponent(listed)
        guard !listed.isEmpty, FileManager.default.fileExists(atPath: url.path) else {
            throw PackInspectionError.missingPath(path: listed, field: field)
        }
        let root = folder.resolvingSymlinksInPath().path
        guard url.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw escape }
        return url
    }

    func decode<T: Decodable>(_ type: T.Type, file: String, at url: URL) throws -> T {
        guard let data = try? Data(contentsOf: url) else {
            throw PackInspectionError.undecodable(file: file, field: nil, reason: "cannot be read")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            let fault = Self.fault(in: error)
            throw PackInspectionError.undecodable(file: file, field: fault.field, reason: fault.reason)
        }
    }

    /// Where a decoding error points and what is wrong there, in fixed words:
    /// the decoder's own description can quote the file, and a pack's files
    /// may hold values that must not be repeated.
    private static func fault(in error: DecodingError) -> (field: String?, reason: String) {
        switch error {
        case .keyNotFound(let key, let context):
            return (path(context.codingPath + [key]), "is missing")
        case .typeMismatch(_, let context):
            return (path(context.codingPath), "has the wrong type")
        case .valueNotFound(_, let context):
            return (path(context.codingPath), "is null")
        case .dataCorrupted(let context):
            return (path(context.codingPath), "is not valid JSON")
        @unknown default:
            return (nil, "could not be decoded")
        }
    }

    private static func path(_ keys: [CodingKey]) -> String? {
        keys.isEmpty ? nil : keys.map(\.stringValue).joined(separator: ".")
    }
}
