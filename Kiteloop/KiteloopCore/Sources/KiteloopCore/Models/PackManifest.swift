import Foundation

/// What a pack says it holds: the `pack.json` at the root of a pack folder.
///
/// A pack is a folder that carries a team's setup in one piece — agents,
/// routines, connectors (MCP servers) and templates. The manifest names each
/// by a path relative to the pack folder, so nothing in a pack is found by
/// scanning and nothing outside the folder is part of it.
package struct PackManifest: Codable, Equatable, Sendable {
    /// The file every pack folder holds at its root.
    package static let fileName = "pack.json"

    package var name: String
    package var version: String
    package var description: String?
    /// Directories, each holding an `agent.json`.
    package var agents: [String]?
    /// Files, each one routine.
    package var routines: [String]?
    /// Files, each a map of server name to MCP server entry.
    package var connectors: [String]?
    /// Files, listed by name and title.
    package var templates: [String]?

    package init(name: String, version: String, description: String? = nil,
                 agents: [String]? = nil, routines: [String]? = nil,
                 connectors: [String]? = nil, templates: [String]? = nil) {
        self.name = name
        self.version = version
        self.description = description
        self.agents = agents
        self.routines = routines
        self.connectors = connectors
        self.templates = templates
    }
}
