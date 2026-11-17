import Foundation

/// The one project a pack is being installed into, as it stands now: where
/// its files go and every name already taken there.
package struct PackInstallTarget {
    /// The project as a routine names it.
    package var projectName: String
    /// The mode a new agent in the project starts in.
    package var defaultPermissionMode: String
    /// Every permission mode the app knows.
    package var permissionModes: [String]
    /// Where the project keeps its own agent packages.
    package var agentsDirectory: URL
    /// Where a template is copied to.
    package var templatesDirectory: URL
    /// Every directory the project's templates are read from.
    package var templateSearchDirectories: [URL]
    /// The names and ids of the agents on the project's team.
    package var agentNames: [String]
    package var routineIDs: [String]
    /// The names of the app's MCP servers.
    package var connectorNames: [String]

    package init(projectName: String, defaultPermissionMode: String, permissionModes: [String],
                 agentsDirectory: URL, templatesDirectory: URL, templateSearchDirectories: [URL],
                 agentNames: [String], routineIDs: [String], connectorNames: [String]) {
        self.projectName = projectName
        self.defaultPermissionMode = defaultPermissionMode
        self.permissionModes = permissionModes
        self.agentsDirectory = agentsDirectory
        self.templatesDirectory = templatesDirectory
        self.templateSearchDirectories = templateSearchDirectories
        self.agentNames = agentNames
        self.routineIDs = routineIDs
        self.connectorNames = connectorNames
    }
}

/// Why a plan's files were not copied.
package enum PackInstallError: Error, Equatable, LocalizedError {
    /// The plan refuses an entry, so nothing of it is installed.
    case refused([String])
    /// Something appeared where a file was to be copied after the plan was made.
    case destinationExists(String)
    /// The pack or the project is not what the person read about.
    case changedSinceRead

    package var errorDescription: String? {
        switch self {
        case .refused(let reasons):
            return "Nothing was installed: " + reasons.joined(separator: " ")
        case .destinationExists(let path):
            return "Nothing was installed: \(path) already exists."
        case .changedSinceRead:
            return "Nothing was installed: the pack or the project changed since this was shown. Read it again."
        }
    }
}

/// What installing a pack into one project would write, worked out without
/// writing anything: the files to copy, the routines, connectors and agents
/// to add, what a person must be told first and what is refused.
///
/// Installing is all or nothing — one refused entry and nothing is installed
/// — and it never arms a routine, never takes a connector's env or header
/// value from the pack, and never links to the pack folder: every file is
/// read inside the folder, as `PackInspector` resolves it, and copied.
package struct PackInstallPlan {
    /// One file read in the pack and written in the project.
    package struct FileCopy: Equatable {
        package let source: URL
        package let destination: URL
    }

    /// One agent package: its directory copied whole under the project's own
    /// agents, and the mode it joins the team in.
    package struct AgentInstall {
        package let agent: PackInspection.Agent
        /// The handle without its `@`: the name of the copied directory.
        package let handle: String
        /// The pack's mode for the agent, else the project's default.
        package let permissionMode: String
        package let destination: URL
        package let files: [FileCopy]
    }

    package let pack: PackInspection
    package let folder: URL
    package let projectName: String
    package let agents: [AgentInstall]
    /// Every one disarmed and in the target project.
    package let routines: [Routine]
    /// Every env and header name kept, every value empty.
    package let connectors: [String: ClaudeMCPServerEntry]
    package let templates: [FileCopy]
    /// What a person is told, each on its own line, before deciding.
    package let callouts: [String]
    /// Why the pack cannot be installed as it is. Empty for one that can.
    package let refusals: [String]

    package var canInstall: Bool { refusals.isEmpty }

    // MARK: - Planning

    /// The plan for the pack in `folder`. Throws what `PackInspector` throws
    /// for a folder that is not a readable pack.
    package static func make(folder: URL, target: PackInstallTarget) throws -> PackInstallPlan {
        var draft = Draft(folder: folder, target: target)
        let pack = try draft.inspector.inspect(folder: folder)
        let agents = try pack.agents.map { try draft.agent($0) }
        let routines = try pack.routines.map { try draft.routine($0, packAgents: pack.agents) }
        let connectors = try draft.connectors(listed: Set(pack.connectors.map(\.path)).sorted())
        let templates = try pack.templates.map { try draft.template($0) }
        draft.refuseRepeats("agent", pack.agents.map { $0.handle.lowercased() })
        draft.refuseRepeats("routine", pack.routines.map(\.id))
        draft.refuseRepeats("connector", pack.connectors.map(\.name))
        draft.refuseRepeats("template", pack.templates.map(\.fileName))
        return PackInstallPlan(pack: pack, folder: folder, projectName: target.projectName, agents: agents,
                               routines: routines, connectors: connectors, templates: templates,
                               callouts: draft.callouts, refusals: draft.refusals)
    }

    // MARK: - What a person reads

    /// What was added, in one line: the change log's account of the install.
    package var added: String {
        let parts = [("agents", agents.map(\.agent.name)), ("routines", routines.map(\.id)),
                     ("connectors", connectors.keys.sorted()),
                     ("templates", templates.map(\.destination.lastPathComponent))]
        let named = parts.filter { !$0.1.isEmpty }.map { "\($0.0) \($0.1.joined(separator: ", "))" }
        return named.isEmpty ? "nothing" : named.joined(separator: "; ")
    }

    /// The whole plan as text a person reads before answering: the
    /// inspection's account, then what needs their eye, how it is installed
    /// and what is refused.
    package var account: String {
        var lines = ["Install into \(projectName):", "", pack.account]
        lines += Self.section("Read before you install", callouts)
        lines += Self.section("How it is installed", manner)
        lines += Self.section("Refused", refusals)
        if !canInstall { lines += ["", "Nothing is installed while an entry is refused."] }
        return lines.joined(separator: "\n")
    }

    private var manner: [String] {
        var lines = ["Nothing is started and nothing is armed."]
        if !agents.isEmpty {
            lines.append("Agents join the team stopped; each package is copied to "
                         + agents.map(\.destination.path).joined(separator: ", ") + ".")
        }
        if !routines.isEmpty { lines.append("Routines are added disarmed, for you to arm in Routines.") }
        if !connectors.isEmpty {
            lines.append("Connectors are added to the app's MCP servers with every env and header value empty.")
        }
        if !templates.isEmpty {
            lines.append("Templates are copied to " + templates.map(\.destination.path).joined(separator: ", ") + ".")
        }
        return lines
    }

    private static func section(_ title: String, _ rows: [String]) -> [String] {
        guard !rows.isEmpty else { return [] }
        return ["", "\(title) (\(rows.count))"] + rows.map { "• \($0)" }
    }

    /// The line the configuration change log keeps of the install.
    package func logRecord(at moment: Date) -> ConfigChangeLog.Record {
        ConfigChangeLog.Record(requestedBy: "person", kind: "pack", tool: "Install Pack", before: "",
                               after: "\(pack.name) \(pack.version) from \(folder.path): \(added)",
                               decision: .approved, at: moment)
    }

    // MARK: - Copying

    /// Copies every agent package and template into the project. A failure
    /// part-way removes what this call copied and leaves the rest alone.
    package func copyFiles() throws {
        guard canInstall else { throw PackInstallError.refused(refusals) }
        var made: [URL] = []
        do {
            for agent in agents { try Self.copy(agent.files, under: agent.destination, made: &made) }
            for template in templates { try Self.copy([template], under: template.destination, made: &made) }
        } catch {
            Self.remove(made)
            throw error
        }
    }

    /// Takes back what `copyFiles` copied, for an install that failed after it.
    package func removeCopiedFiles() {
        Self.remove(agents.map(\.destination) + templates.map(\.destination))
    }

    private static func copy(_ files: [FileCopy], under top: URL, made: inout [URL]) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: top.path) else { throw PackInstallError.destinationExists(top.path) }
        made.append(top)
        for file in files {
            try manager.createDirectory(at: file.destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            try manager.copyItem(at: file.source, to: file.destination)
        }
    }

    private static func remove(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Working a plan out

extension PackInstallPlan {
    /// The plan while it is being made: the notes it gathers on the way.
    private struct Draft {
        let folder: URL
        let target: PackInstallTarget
        let inspector = PackInspector()
        var callouts: [String] = []
        var refusals: [String] = []

        init(folder: URL, target: PackInstallTarget) {
            self.folder = folder
            self.target = target
        }

        /// The pack folder with every symlink followed: what a copied file
        /// must sit under.
        private var root: String { folder.resolvingSymlinksInPath().path }

        mutating func refuseRepeats(_ kind: String, _ names: [String]) {
            let repeated = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            refusals += repeated.map { "The pack names the \(kind) \($0) more than once." }
        }

        // MARK: Agents

        mutating func agent(_ agent: PackInspection.Agent) throws -> AgentInstall {
            let handle = agent.handle.hasPrefix("@") ? String(agent.handle.dropFirst()) : agent.handle
            let source = try inspector.resolve(agent.path, field: "agents", in: folder).resolvingSymlinksInPath()
            let destination = target.agentsDirectory.appendingPathComponent(handle)
            refuseTakenAgent(agent, handle: handle, destination: destination)
            callOut(agent)
            return AgentInstall(agent: agent, handle: handle,
                                permissionMode: agent.permissionMode ?? target.defaultPermissionMode,
                                destination: destination,
                                files: copies(under: source, to: destination, listed: agent.path))
        }

        private mutating func refuseTakenAgent(_ agent: PackInspection.Agent, handle: String, destination: URL) {
            if !Self.namesOneFolder(handle) {
                refusals.append("Agent \(agent.name) (\(agent.path)) has a handle that cannot name a folder.")
            } else if FileManager.default.fileExists(atPath: destination.path) {
                refusals.append("The project already holds an agent package named \(handle).")
            }
            if target.agentNames.contains(where: { Self.same($0, agent.name) || Self.same($0, handle) }) {
                refusals.append("The project's team already has an agent named \(agent.name).")
            }
            if let mode = agent.permissionMode, !target.permissionModes.contains(mode) {
                refusals.append("Agent \(agent.name) asks for a permission mode the app does not know.")
            }
        }

        /// What an agent would be allowed beyond a new agent of the project:
        /// a control API credential, or a mode that is not the project's.
        private mutating func callOut(_ agent: PackInspection.Agent) {
            if let credential = agent.credential {
                callouts.append("Agent \(agent.name) asks for Operator tools: it would hold \(credential).")
            }
            if let mode = agent.permissionMode, mode != target.defaultPermissionMode {
                callouts.append("Agent \(agent.name) asks for permission mode \(mode); "
                                + "this project's default is \(target.defaultPermissionMode).")
            }
        }

        private static func namesOneFolder(_ name: String) -> Bool {
            !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
        }

        private static func same(_ a: String, _ b: String) -> Bool {
            a.caseInsensitiveCompare(b) == .orderedSame
        }

        // MARK: Files

        /// What a path under an agent's directory is, once its link, if it is
        /// one, has been followed.
        private enum Entry {
            case directory
            case file(URL)
            case refused(String)
        }

        /// Every file under `source`, each to be copied to the same place
        /// under `destination`. A link is followed and its file copied; one
        /// that leaves the pack, or names a folder, is refused.
        private mutating func copies(under source: URL, to destination: URL, listed: String) -> [FileCopy] {
            let paths = (try? FileManager.default.subpathsOfDirectory(atPath: source.path)) ?? []
            var files: [FileCopy] = []
            for path in paths.sorted() {
                switch entry(at: source.appendingPathComponent(path)) {
                case .directory: continue
                case .file(let url): files.append(FileCopy(source: url, destination: destination.appendingPathComponent(path)))
                case .refused(let reason): refusals.append("\(listed)/\(path) \(reason).")
                }
            }
            return files
        }

        private func entry(at url: URL) -> Entry {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink == true else {
                return values?.isDirectory == true ? .directory : .file(url)
            }
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root + "/") else { return .refused("is a link that leaves the pack folder") }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return .refused("is a link to a folder, or to nothing") }
            return .file(resolved)
        }

        // MARK: Routines

        /// The routine as it is installed: in the target project and never
        /// armed, whatever its file says.
        mutating func routine(_ entry: PackInspection.RoutineEntry,
                              packAgents: [PackInspection.Agent]) throws -> Routine {
            let url = try inspector.resolve(entry.path, field: "routines", in: folder)
            var routine = try inspector.decode(Routine.self, file: entry.path, at: url)
            routine.project = target.projectName
            routine.armed = false
            routine.armedAt = nil
            if entry.armed {
                callouts.append("Routine \(entry.id) is marked armed by the pack; that is ignored and it is installed disarmed.")
            }
            let known = target.agentNames + packAgents.flatMap { [$0.name, $0.handle] }
            if !known.contains(where: { Self.same($0, routine.agent) }) {
                callouts.append("Routine \(entry.id) prompts agent \(routine.agent), which is neither in the pack nor on the team.")
            }
            if target.routineIDs.contains(routine.id) {
                refusals.append("A routine with the id \(routine.id) already exists.")
            }
            refusals += routine.problems.map { "Routine \(entry.id) (\(entry.path)): \($0)." }
            return routine
        }

        // MARK: Connectors

        mutating func connectors(listed: [String]) throws -> [String: ClaudeMCPServerEntry] {
            var out: [String: ClaudeMCPServerEntry] = [:]
            for path in listed {
                let url = try inspector.resolve(path, field: "connectors", in: folder)
                let servers = try inspector.decode([String: ClaudeMCPServerEntry].self, file: path, at: url)
                for name in servers.keys.sorted() {
                    guard let entry = servers[name] else { continue }
                    out[name] = connector(entry, named: name)
                }
            }
            return out
        }

        private mutating func connector(_ entry: ClaudeMCPServerEntry, named name: String) -> ClaudeMCPServerEntry {
            if name.isEmpty {
                refusals.append("A connector in the pack has no name.")
            } else if target.connectorNames.contains(name) {
                refusals.append("An MCP server named \(name) already exists.")
            }
            let emptied = PackInstallPlan.withoutSecretValues(entry)
            let names = (emptied.env ?? [:]).keys.sorted() + Self.keys(of: emptied.extras["headers"])
            if !names.isEmpty {
                callouts.append("Connector \(name) expects \(names.joined(separator: ", ")): the values are not "
                                + "taken from the pack — fill them in Settings before an agent uses it.")
            }
            return emptied
        }

        private static func keys(of value: AnyCodable?) -> [String] {
            guard case .dictionary(let pairs)? = value else { return [] }
            return pairs.keys.sorted()
        }

        // MARK: Templates

        mutating func template(_ template: PackInspection.Template) throws -> FileCopy {
            let url = try inspector.resolve(template.path, field: "templates", in: folder)
            let source = url.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            let stem = url.deletingPathExtension().lastPathComponent
            if url.pathExtension.lowercased() != "md" {
                refusals.append("Template \(template.path) is not a .md file, which is what a project's templates are.")
            } else if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
                refusals.append("Template \(template.path) is a folder.")
            } else if target.templateSearchDirectories.contains(where: { Self.holdsTemplate($0, named: stem) }) {
                refusals.append("The project already has a template named \(stem).")
            }
            return FileCopy(source: source, destination: target.templatesDirectory.appendingPathComponent(template.fileName))
        }

        private static func holdsTemplate(_ directory: URL, named stem: String) -> Bool {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return files.contains { same(($0 as NSString).deletingPathExtension, stem) && $0.lowercased().hasSuffix(".md") }
        }
    }

    /// The connector with every env and header name kept and no value: an
    /// `env` of any shape becomes its names, and `headers` likewise.
    package static func withoutSecretValues(_ entry: ClaudeMCPServerEntry) -> ClaudeMCPServerEntry {
        var emptied = entry
        var names = Set((entry.env ?? [:]).keys)
        if case .dictionary(let pairs)? = entry.extras["env"] { names.formUnion(pairs.keys) }
        emptied.extras["env"] = nil
        emptied.env = names.isEmpty ? nil : Dictionary(uniqueKeysWithValues: names.map { ($0, "") })
        if case .dictionary(let headers)? = entry.extras["headers"] {
            emptied.extras["headers"] = .dictionary(headers.mapValues { _ in AnyCodable.string("") })
        } else {
            emptied.extras["headers"] = nil
        }
        return emptied
    }
}
