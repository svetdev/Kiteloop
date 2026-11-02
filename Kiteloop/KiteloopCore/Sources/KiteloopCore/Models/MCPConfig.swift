import Foundation

/// One server in an agent's `mcp.json`.
///
/// Kiteloop reads these files to change one part of them — a credential, a
/// newly authorized server — and writes the rest back, so the entry has to be
/// lossless. It is not the only writer: a server can be written for a transport
/// Kiteloop does not model (a `type`/`url` entry carries no `command` at all),
/// and can carry keys this struct never declares. So `command` and `args` are
/// optional, and every unrecognised key is kept in `extras` and re-emitted on
/// encode. A required `command` used to make one such entry fail to decode,
/// which made `ClaudeMCPConfig.load(from:)` answer nil for the whole file.
package struct ClaudeMCPServerEntry: Codable {
    package var command: String?
    package var args: [String]?
    package var env: [String: String]?
    /// Every key Kiteloop does not model, kept verbatim so a read-modify-write
    /// hands the file back the way it came in.
    package var extras: [String: AnyCodable]

    package init(
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        extras: [String: AnyCodable] = [:]
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.extras = extras
    }

    /// What to show for an entry: its command line when it has one, otherwise
    /// what it does carry — the transport and endpoint of a remote server, or
    /// failing that the names of the keys it holds. Empty only for an entry
    /// with nothing in it at all.
    package var displaySummary: String {
        if let command {
            return ([command] + (args ?? [])).joined(separator: " ")
        }
        let type = extras["type"]?.stringValue
        let url = extras["url"]?.stringValue
        switch (type, url) {
        case let (type?, url?): return "\(type): \(url)"
        case let (nil, url?): return url
        case let (type?, nil): return type
        case (nil, nil): return extras.keys.sorted().joined(separator: ", ")
        }
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var command: String?
        var args: [String]?
        var env: [String: String]?
        var extras: [String: AnyCodable] = [:]

        for key in container.allKeys {
            // A modelled key whose value is not the shape Kiteloop models —
            // an explicit null, a richer `env` — falls through to `extras`
            // rather than being dropped or failing the whole file.
            switch key.stringValue {
            case "command":
                if let value = try? container.decode(String.self, forKey: key) { command = value; continue }
            case "args":
                if let value = try? container.decode([String].self, forKey: key) { args = value; continue }
            case "env":
                if let value = try? container.decode([String: String].self, forKey: key) { env = value; continue }
            default:
                break
            }
            extras[key.stringValue] = try container.decode(AnyCodable.self, forKey: key)
        }

        self.command = command
        self.args = args
        self.env = env
        self.extras = extras
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encodeIfPresent(command, forKey: DynamicKey("command"))
        try container.encodeIfPresent(args, forKey: DynamicKey("args"))
        try container.encodeIfPresent(env, forKey: DynamicKey("env"))
        for (key, value) in extras {
            try container.encode(value, forKey: DynamicKey(key))
        }
    }
}

package struct ClaudeMCPConfig: Codable {
    package var mcpServers: [String: ClaudeMCPServerEntry]

    package var hasEmptyEnvVars: Bool {
        mcpServers.values.contains { entry in
            entry.env?.values.contains(where: { $0.isEmpty }) ?? false
        }
    }

    package static func load(from path: String) -> ClaudeMCPConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(ClaudeMCPConfig.self, from: data)
    }

    /// Reads the file at `path`, telling a file that is not there apart from
    /// one that is there but cannot be used: nil when no file exists, the read
    /// or decode error when one exists and does not yield a config.
    package static func loadIfPresent(from path: String) throws -> ClaudeMCPConfig? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(ClaudeMCPConfig.self, from: data)
    }

    package func save(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = URL(fileURLWithPath: path)
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".mcp-\(UUID().uuidString).json")
        try data.write(to: tempURL)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    package func writeToTempFile() throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiteloop-mcp-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: tempURL)
        return tempURL
    }

    package mutating func addServer(name: String, entry: ClaudeMCPServerEntry) {
        mcpServers[name] = entry
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(mcpServers: [String: ClaudeMCPServerEntry]) {
        self.mcpServers = mcpServers
    }
}

package struct MCPCatalogEntry: Codable {
    package let command: String
    package let args: [String]
    package let env: [String: String]?
    package let description: String
    package let requiresAuth: Bool
    package let authType: String?
    package let authKeys: [String]?

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(command: String, args: [String], env: [String: String]?, description: String, requiresAuth: Bool, authType: String?, authKeys: [String]?) {
        self.command = command
        self.args = args
        self.env = env
        self.description = description
        self.requiresAuth = requiresAuth
        self.authType = authType
        self.authKeys = authKeys
    }
}

package struct MCPCatalog: Codable {
    package var servers: [String: MCPCatalogEntry]

    package static func load(from url: URL) -> MCPCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MCPCatalog.self, from: data)
    }

    package func entry(for serverName: String) -> MCPCatalogEntry? {
        servers.first { $0.key.caseInsensitiveCompare(serverName) == .orderedSame }?.value
    }

    package func toServerEntry(_ catalogEntry: MCPCatalogEntry, envOverrides: [String: String]) -> ClaudeMCPServerEntry {
        var env = catalogEntry.env ?? [:]
        for (key, value) in envOverrides { env[key] = value }
        return ClaudeMCPServerEntry(command: catalogEntry.command, args: catalogEntry.args, env: env)
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(servers: [String: MCPCatalogEntry]) {
        self.servers = servers
    }
}
