import Foundation

/// One MCP server as a session last saw it: whether it started, needs a
/// sign-in or failed, and which tools it offers. Read off the `system`/`init`
/// line the Claude CLI emits at session start — not a live probe.
package struct ConnectorStatus: Equatable, Sendable {
    package let name: String
    /// `connected`, `failed`, `needs-auth`, `pending` — or whatever else the
    /// CLI said, kept as given.
    package let state: String
    /// The server's tool names without the `mcp__<server>__` prefix, sorted.
    package let tools: [String]
    package let reportedAt: Date

    package init(name: String, state: String, tools: [String], reportedAt: Date) {
        self.name = name
        self.state = state
        self.tools = tools
        self.reportedAt = reportedAt
    }

    /// Every server the init line names in `mcp_servers`, each with the tools
    /// in `tools` that carry its prefix. A server named only by a tool is not
    /// invented; a missing or malformed `mcp_servers` gives nothing.
    package static func fromInitPayload(_ payload: [String: Any], at date: Date) -> [ConnectorStatus] {
        guard let servers = payload["mcp_servers"] as? [[String: Any]] else { return [] }
        let toolNames = payload["tools"] as? [String] ?? []
        return servers.compactMap { server in
            guard let name = server["name"] as? String, !name.isEmpty else { return nil }
            let prefix = "mcp__\(name)__"
            let tools = toolNames.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
            return ConnectorStatus(name: name, state: server["status"] as? String ?? "unknown",
                                   tools: tools, reportedAt: date)
        }
    }
}
